import Foundation
import SwiftUI

enum NativeControllerDriverError: LocalizedError {
    case unavailable, clockUnavailable
    var errorDescription: String? {
        switch self {
        case .unavailable: "Reload controller selection before making another request."
        case .clockUnavailable: "Paired requests need a trusted certificate clock. This controller remains selected."
        }
    }
}

struct NativeControllerLocalReadClient: Sendable {
    let capture: @Sendable () throws -> LocalCredentialCapture
    let socket: @Sendable () -> String
    init(capture: @escaping @Sendable () throws -> LocalCredentialCapture = { try OperatorCredential.captureOriginal() },
         socket: @escaping @Sendable () -> String = { LocalHealthClient.defaultSocketPath() }) {
        self.capture = capture; self.socket = socket
    }
}

// This fence contains public selection metadata only. It never opens custody
// and is not the paired session's authorization seal.
private final class ControllerSelectionFence: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: NativeControllerAssociationSnapshot?
    private var generation = UUID()
    private let check: @Sendable (NativeControllerAssociationSnapshot) throws -> Void
    init(check: @escaping @Sendable (NativeControllerAssociationSnapshot) throws -> Void) { self.check = check }
    func update(_ value: NativeControllerAssociationSnapshot?) {
        lock.lock(); snapshot = value; generation = UUID(); lock.unlock()
    }
    func beginLocal() throws -> @Sendable () throws -> Void {
        lock.lock(); let original = snapshot, originalGeneration = generation; lock.unlock()
        guard let original, original.document.selection == .local else { throw NativeControllerDriverError.unavailable }
        try check(original)
        return { [self] in
            lock.lock(); let current = snapshot, currentGeneration = generation; lock.unlock()
            guard current == original, currentGeneration == originalGeneration else { throw LocalHealthError.sessionChanged }
            try check(original)
        }
    }
}

// One owner for window/menu selection. Construction and metadata loading do
// not acquire a credential, start a controller, or issue an API/device request.
@MainActor
final class NativeControllerSessionDriver: ObservableObject {
    private struct Persistence: Sendable {
        let load: @Sendable () throws -> NativeControllerAssociationSnapshot
        let check: @Sendable (NativeControllerAssociationSnapshot) throws -> Void
        let select: @Sendable (NativeControllerSelection, NativeControllerAssociationSnapshot) throws -> NativeControllerAssociationSnapshot
    }
    private let persistence: Persistence
    nonisolated private let fence: ControllerSelectionFence
    private let certificateClock: (@Sendable () throws -> NativeControllerCertificateClock)?
    private let local: NativeControllerLocalReadClient
    @Published private(set) var snapshot: NativeControllerAssociationSnapshot?
    @Published private(set) var busy = false
    @Published private(set) var needsReload = false
    @Published private(set) var error: String?
    private var generation: UInt64 = 0
    var changesAllowed: () -> Bool = { true }
    var selectionChanged: () -> Void = {}

    init(certificateClock: (@Sendable () throws -> NativeControllerCertificateClock)? = nil, directory: URL? = nil,
         local: NativeControllerLocalReadClient = NativeControllerLocalReadClient()) {
        let persistence: Persistence
        if let directory {
            // Foreground fixture metadata only; this cannot create a signed
            // paired session or redirect the production custody factory.
            persistence = Persistence(load: { try NativeControllerAssociationStorage.load(directory: directory) },
                check: { try NativeControllerAssociationStorage.check($0, directory: directory) },
                select: { try NativeControllerAssociationStorage.selecting($0, directory: directory, expected: $1) })
        } else {
            persistence = Persistence(load: { try NativeControllerAssociationStorage.load() },
                check: { try NativeControllerAssociationStorage.check($0) },
                select: { try NativeControllerAssociationStorage.selecting($0, expected: $1) })
        }
        self.persistence = persistence; fence = ControllerSelectionFence(check: persistence.check)
        self.certificateClock = certificateClock
        self.local = local
    }
    var selection: NativeControllerSelection? { snapshot?.document.selection }
    var records: [NativeControllerPublicAssociation] { snapshot?.document.records ?? [] }
    var localSelected: Bool { selection == .local && !needsReload }
    var pairedRecoveryAvailable: Bool { certificateClock != nil && snapshot != nil && !needsReload }
    var label: String {
        guard let snapshot, !needsReload else { return "Controller selection unavailable" }
        switch snapshot.document.selection {
        case .local: return "This Mac"
        case .remote(let id): return snapshot.document.records.first(where: { $0.id == id })?.label ?? "Paired controller unavailable"
        }
    }
    var status: String {
        if needsReload || snapshot == nil { return "Reload saved controller metadata before making requests." }
        if localSelected { return "Local session on this Mac." }
        return certificateClock == nil ? "Selected paired controller · Trusted certificate clock unavailable" : "Selected paired controller · Refresh to authenticate current access"
    }
    nonisolated func installLocalFence() {
        NativeLocalControllerRequestGuard.install { [fence] in try fence.beginLocal() }
    }
    func loadIfNeeded() async { if snapshot == nil && !needsReload { await reload() } }
    func reload() async {
        guard !busy else { return }
        busy = true; error = nil; generation &+= 1; fence.update(nil); selectionChanged()
        defer { busy = false }
        do {
            let persistence = persistence
            let value = try await Task.detached { try persistence.load() }.value
            guard !Task.isCancelled else { throw NativeControllerDriverError.unavailable }
            snapshot = value; needsReload = false; fence.update(value)
        } catch { fail(error) }
    }
    func select(_ selection: NativeControllerSelection) async {
        guard !busy, !needsReload, changesAllowed(), let original = snapshot else { return }
        busy = true; error = nil; generation &+= 1; fence.update(nil); selectionChanged()
        defer { busy = false }
        do {
            let persistence = persistence
            let value = try await Task.detached { try persistence.select(selection, original) }.value
            guard !Task.isCancelled else { throw NativeControllerDriverError.unavailable }
            snapshot = value; fence.update(value)
        } catch { fail(error) }
    }
    private func fail(_ error: Error) {
        needsReload = true; fence.update(nil); self.error = error.localizedDescription
    }
    private func current(_ original: NativeControllerAssociationSnapshot, generation: UInt64, checkMetadata: Bool = true) throws {
        guard !Task.isCancelled, !needsReload, self.generation == generation, snapshot == original else { throw LocalHealthError.sessionChanged }
        if checkMetadata { try persistence.check(original) }
    }
    private func selected(_ original: NativeControllerAssociationSnapshot) async throws -> NativePairedControllerSession {
        guard let certificateClock else { throw NativeControllerDriverError.clockUnavailable }
        return try await NativePairedControllerSession.selected(expected: original, clock: certificateClock)
    }
    func readHome() async throws -> NativeHomeRead {
        try await metadataChecked { try await homeForSelection() }
    }
    private func metadataChecked<Value: Sendable>(_ read: () async throws -> Value) async throws -> Value {
        do { return try await read() }
        catch {
            if error is NativeControllerAssociationError { fail(error); selectionChanged() }
            throw error
        }
    }
    private func homeForSelection() async throws -> NativeHomeRead {
        guard !busy, !needsReload, let original = snapshot else { throw NativeControllerDriverError.unavailable }
        busy = true; defer { busy = false }
        let generation = generation
        let result: NativeHomeRead
        var paired: NativePairedControllerSession?
        switch original.document.selection {
        case .local:
            let completion = try fence.beginLocal()
            let local = local
            result = try await Task.detached {
                let capture = try local.capture()
                let result = try Self.home(socket: local.socket(), credential: capture.bytes, local: true, reference: capture.nativeReference)
                try completion(); return result
            }.value
        case .remote:
            let session = try await selected(original)
            paired = session
            result = try await session.perform { credential in
                try Self.home(socket: "", credential: credential, local: false, identity: session.scope.identity)
            }
        }
        if let paired { try await paired.current() }
        try current(original, generation: generation, checkMetadata: paired == nil)
        try paired?.deliveryCurrent()
        if let paired {
            let basis = try NativePairedPowerViewBasis.deriving(paired, associations: original, view: result.view, generation: generation)
            return NativeHomeRead(health: result.health, view: result.view, overrides: result.overrides, localCredential: nil, pairedPower: basis)
        }
        return result
    }
    nonisolated private static func home(socket: String, credential: Data, local: Bool,
                                        identity: HomeControllerIdentity? = nil, reference: Data? = nil) throws -> NativeHomeRead {
        let before = try LocalHealthClient.fetchControllerIdentity(socketPath: socket, credential: credential)
        try nativeCapture(reference, credential: credential, identity: before)
        if let identity {
            guard before.matchesAuthority(identity), before.revision >= identity.revision else { throw LocalHealthError.nativeGuardConflict }
        }
        let health = try LocalHealthClient.fetch(socketPath: socket, credential: credential)
        let view = try LocalHealthClient.fetchReadView(socketPath: socket, credential: credential)
        let overrides = try LocalHealthClient.fetchOverrides(socketPath: socket, credential: credential, targetIDs: view.catalogue.things.map(\.id))
        let after = try LocalHealthClient.fetchControllerIdentity(socketPath: socket, credential: credential)
        guard before.matchesAuthority(after), health.authorityEpoch == before.authorityEpoch,
              view.catalogue.authorityEpoch == before.authorityEpoch, after.revision >= view.catalogue.watermark else {
            throw LocalHealthError.nativeGuardConflict
        }
        return NativeHomeRead(health: health, view: view, overrides: overrides, localCredential: local ? credential : nil)
    }
    func readThing(target: String, probe: Bool) async throws -> (HomeThingInspection, HomeThingRefresh?) {
        try await metadataChecked { try await thingForSelection(target: target, probe: probe) }
    }
    private func thingForSelection(target: String, probe: Bool) async throws -> (HomeThingInspection, HomeThingRefresh?) {
        guard !busy, !needsReload, let original = snapshot else { throw NativeControllerDriverError.unavailable }
        busy = true; defer { busy = false }
        let generation = generation
        let result: (HomeThingInspection, HomeThingRefresh?)
        var paired: NativePairedControllerSession?
        switch original.document.selection {
        case .local:
            let completion = try fence.beginLocal()
            let local = local
            result = try await Task.detached {
                let capture = try local.capture()
                let result = try Self.thing(target: target, probe: probe, socket: local.socket(), credential: capture.bytes, reference: capture.nativeReference)
                try completion(); return result
            }.value
        case .remote:
            let session = try await selected(original)
            paired = session
            result = try await session.perform { credential in
                try Self.thing(target: target, probe: probe, socket: "", credential: credential, identity: session.scope.identity)
            }
        }
        if let paired { try await paired.current() }
        try current(original, generation: generation, checkMetadata: paired == nil)
        try paired?.deliveryCurrent()
        return result
    }
    nonisolated private static func thing(target: String, probe: Bool, socket: String, credential: Data,
                                         identity: HomeControllerIdentity? = nil, reference: Data? = nil) throws -> (HomeThingInspection, HomeThingRefresh?) {
        let before = try LocalHealthClient.fetchControllerIdentity(socketPath: socket, credential: credential)
        try nativeCapture(reference, credential: credential, identity: before)
        if let identity {
            guard before.matchesAuthority(identity), before.revision >= identity.revision else { throw LocalHealthError.nativeGuardConflict }
        }
        let refreshed = probe ? try NativeThingClient.refresh(socketPath: socket, credential: credential, target: target) : nil
        let view = try NativeThingClient.fetch(socketPath: socket, credential: credential, target: target)
        let after = try LocalHealthClient.fetchControllerIdentity(socketPath: socket, credential: credential)
        guard before.matchesAuthority(after), view.thingID == target, view.principal == before.principalID,
              view.epoch == before.authorityEpoch, view.revision >= before.revision, after.revision >= view.revision,
              refreshed == nil || refreshed?.target == target else { throw LocalHealthError.nativeGuardConflict }
        return (view, refreshed)
    }
    func readExternalReport(target: String, key: String) async throws -> HomeExternalReport {
        try await metadataChecked {
            guard !busy, !needsReload, let original = snapshot else { throw NativeControllerDriverError.unavailable }
            busy = true; defer { busy = false }
            let originalGeneration = generation
            let result: HomeExternalReport
            var paired: NativePairedControllerSession?
            switch original.document.selection {
            case .local:
                let completion = try fence.beginLocal(), local = local
                result = try await Task.detached {
                    let capture = try local.capture()
                    let value = try Self.externalReport(target: target, key: key, socket: local.socket(), credential: capture.bytes, reference: capture.nativeReference)
                    try completion(); return value
                }.value
            case .remote:
                let session = try await selected(original)
                paired = session
                result = try await session.perform { credential in
                    try Self.externalReport(target: target, key: key, socket: "", credential: credential, identity: session.scope.identity)
                }
            }
            if let paired { try await paired.current() }
            try current(original, generation: originalGeneration, checkMetadata: paired == nil)
            try paired?.deliveryCurrent()
            return result
        }
    }
    nonisolated private static func externalReport(target: String, key: String, socket: String, credential: Data,
                                                 identity: HomeControllerIdentity? = nil, reference: Data? = nil) throws -> HomeExternalReport {
        let before = try LocalHealthClient.fetchControllerIdentity(socketPath: socket, credential: credential)
        try nativeCapture(reference, credential: credential, identity: before)
        if let identity {
            guard before.matchesAuthority(identity), before.revision >= identity.revision else { throw LocalHealthError.nativeGuardConflict }
        }
        let value = try NativeExternalReportClient.fetch(socketPath: socket, credential: credential, target: target, key: key)
        let after = try LocalHealthClient.fetchControllerIdentity(socketPath: socket, credential: credential)
        guard before.matchesAuthority(after), value.epoch == before.authorityEpoch,
              value.revision >= before.revision, after.revision >= value.revision else { throw LocalHealthError.nativeGuardConflict }
        return value
    }
    func readAuthoring(_ request: HomeAuthoringReadRequest) async throws -> HomeAuthoringReadResult {
        guard request.valid else { throw LocalHealthError.invalidProfileRequest }
        return try await metadataChecked {
            guard !busy, !needsReload, let original = snapshot, !(request.localOnly && original.document.selection != .local) else { throw NativeControllerDriverError.unavailable }
            busy = true; defer { busy = false }
            let originalGeneration = generation
            let result: HomeAuthoringReadResult
            var paired: NativePairedControllerSession?
            switch original.document.selection {
            case .local:
                let completion = try fence.beginLocal(), local = local
                result = try await Task.detached {
                    let capture = try local.capture()
                    let value = try Self.authoring(request, socket: local.socket(), credential: capture.bytes, reference: capture.nativeReference)
                    try completion(); return value
                }.value
            case .remote:
                let session = try await selected(original)
                paired = session
                result = try await session.perform { credential in
                    try Self.authoring(request, socket: "", credential: credential, identity: session.scope.identity)
                }
            }
            if let paired { try await paired.current() }
            try current(original, generation: originalGeneration, checkMetadata: paired == nil)
            try paired?.deliveryCurrent()
            return result
        }
    }
    func readAuthoringContract() async throws -> HomeAuthoringContractRead {
        try await metadataChecked {
            guard !busy, !needsReload, let original = snapshot else { throw NativeControllerDriverError.unavailable }
            busy = true; defer { busy = false }
            let originalGeneration = generation
            let result: HomeAuthoringContractRead
            var paired: NativePairedControllerSession?
            switch original.document.selection {
            case .local:
                let completion = try fence.beginLocal(), local = local
                result = try await Task.detached {
                    let capture = try local.capture()
                    let value = try Self.authoringContract(socket: local.socket(), credential: capture.bytes, reference: capture.nativeReference)
                    try completion(); return value
                }.value
            case .remote:
                let session = try await selected(original)
                paired = session
                result = try await session.perform { credential in
                    try Self.authoringContract(socket: "", credential: credential, identity: session.scope.identity)
                }
            }
            if let paired { try await paired.current() }
            try current(original, generation: originalGeneration, checkMetadata: paired == nil)
            try paired?.deliveryCurrent()
            return result
        }
    }

    func prepareAuthoringDataImport(kind: HomeAuthoringObjectKind, url: URL) async throws -> NativeAuthoringPreparedDecision {
        try await metadataChecked {
            guard !busy, !needsReload, let selected = snapshot, selected.document.selection == .local else { throw NativeControllerDriverError.unavailable }
            busy = true; defer { busy = false }
            let capturedGeneration = generation, completion = try fence.beginLocal(), local = local
            let decision = try await Task.detached {
                let payload = try NativeAuthoringFiles.read(url, maximum: kind.maximumBytes)
                let capture = try local.capture(), socket = local.socket()
                let before = try LocalHealthClient.fetchControllerIdentity(socketPath: socket, credential: capture.bytes)
                try Self.nativeCapture(capture.nativeReference, credential: capture.bytes, identity: before)
                let profiles = try LocalHealthClient.fetchProfiles(socketPath: socket, credential: capture.bytes)
                let after = try LocalHealthClient.fetchControllerIdentity(socketPath: socket, credential: capture.bytes)
                try Self.nativeCapture(capture.nativeReference, credential: capture.bytes, identity: after)
                guard before.matchesAuthority(after), profiles.authorityEpoch == after.authorityEpoch,
                      before.revision == profiles.storeRevision, profiles.storeRevision == after.revision else { throw LocalHealthError.nativeGuardConflict }
                let summary = try NativeAuthoringReadClient.objectSummary(kind: kind.rawValue, payload: payload)
                let original = try NativeAuthoringOriginalWire.encode([
                    "authority_epoch": after.authorityEpoch, "expected_revision": after.revision,
                    "operation_id": "authoring:data:" + UUID().uuidString.lowercased(),
                    "object": ["kind": kind.rawValue, "object_digest": summary.digest, "payload_sha256": summary.payloadSHA, "payload_bytes": summary.size]
                ], kind: .import)
                _ = try NativePendingAuthoring.checked(original, payload: payload)
                try completion()
                return NativeAuthoringPreparedDecision(original: original, payload: payload, capture: capture, identity: after,
                    selection: selected, generation: capturedGeneration)
            }.value
            try current(selected, generation: capturedGeneration)
            return decision
        }
    }

    func loadGenerationContext() async throws -> NativeGenerationContext {
        try await metadataChecked {
            guard !busy, !needsReload, let selected = snapshot, selected.document.selection == .local else { throw NativeControllerDriverError.unavailable }
            busy = true; defer { busy = false }
            let capturedGeneration = generation, completion = try fence.beginLocal(), local = local
            let value = try await Task.detached {
                let capture = try local.capture()
                let (identity, contract, options) = try Self.generationBasis(socket: local.socket(), capture: capture)
                try completion()
                return NativeGenerationContext(options: options, contract: contract, identity: identity,
                    capture: capture, selection: selected, generation: capturedGeneration)
            }.value
            try current(selected, generation: capturedGeneration); return value
        }
    }
    func prepareGeneration(_ context: NativeGenerationContext, fields: NativeGenerationDraftFields) async throws -> NativeGenerationDecision {
        guard !busy, !needsReload, snapshot == context.selection, generation == context.generation else { throw NativeControllerDriverError.unavailable }
        let original = try fields.original(context, operation: "generation:prepare:" + UUID().uuidString.lowercased())
        return NativeGenerationDecision(original: original, context: context, previous: nil)
    }
    func loadGenerationWorkspace(_ entries: [NativeGenerationWorkspaceEntry]) async throws -> NativeGenerationWorkspaceEntry? {
        try await metadataChecked {
            guard !busy, !needsReload, let selected = snapshot, selected.document.selection == .local else { throw NativeControllerDriverError.unavailable }
            busy = true; defer { busy = false }
            let capturedGeneration = generation, completion = try fence.beginLocal(), local = local
            let entry = try await Task.detached {
                let capture = try local.capture(), identity = try LocalHealthClient.fetchControllerIdentity(socketPath: local.socket(), credential: capture.bytes)
                try Self.nativeCapture(capture.nativeReference, credential: capture.bytes, identity: identity)
                let entry = entries.first { $0.context.matches(identity) && $0.custody.matches(capture.bytes) }
                if let entry { try Self.workspaceCapture(entry, capture, identity) }
                try completion(); return entry
            }.value
            try current(selected, generation: capturedGeneration); return entry
        }
    }
    nonisolated private static func generationBasis(socket: String, capture: LocalCredentialCapture) throws -> (HomeControllerIdentity, HomeAuthoringContractRead, HomeGenerationOptions) {
        let (before, contract) = try manualBasis(socket: socket, capture: capture)
        let options = try NativeGenerationClient.fetchOptions(socketPath: socket, credential: capture.bytes)
        let after = try LocalHealthClient.fetchControllerIdentity(socketPath: socket, credential: capture.bytes)
        try nativeCapture(capture.nativeReference, credential: capture.bytes, identity: after)
        guard before.matchesAuthority(after), before.revision == after.revision, Int64(after.revision) == options.revision,
              options.epoch == after.authorityEpoch, options.principal == after.principalID else { throw LocalHealthError.nativeGuardConflict }
        return (after, contract, options)
    }
    nonisolated private static func generationCustody(_ context: NativeGenerationContext) throws -> NativePendingCustody {
        if let reference = context.capture.nativeReference {
            guard case .recover(let original) = try NativeBrokerWire.request(reference), original.receipt.role == .operator else { throw LocalHealthError.nativeGuardConflict }
            return .native(role: .operator, creationRevision: original.receipt.revision, verifier: context.capture.verifier)
        }
        return .manual(verifier: context.capture.verifier)
    }
    nonisolated private static func workspaceCapture(_ entry: NativeGenerationWorkspaceEntry, _ capture: LocalCredentialCapture,
                                                    _ identity: HomeControllerIdentity) throws {
        _ = try entry.checked()
        guard entry.context.matches(identity), entry.custody.matches(capture.bytes) else { throw LocalHealthError.nativeGuardConflict }
        try nativeCapture(capture.nativeReference, credential: capture.bytes, identity: identity)
        if case .native = entry.custody {
            guard let reference = capture.nativeReference,
                  case .recover(let original) = try NativeBrokerWire.request(reference),
                  try entry.custody.nativeOriginal(context: entry.context) == original else { throw LocalHealthError.nativeGuardConflict }
        } else { guard capture.nativeReference == nil else { throw LocalHealthError.nativeGuardConflict } }
    }
    func readGeneration(_ entry: NativeGenerationWorkspaceEntry) async throws -> (HomeGenerationStatus?, HomeGenerationStatus?) {
        try await metadataChecked {
            guard !busy, !needsReload, let selected = snapshot, selected.document.selection == .local else { throw NativeControllerDriverError.unavailable }
            busy = true; defer { busy = false }
            let capturedGeneration = generation, completion = try fence.beginLocal(), local = local
            let value = try await Task.detached {
                let capture = try local.capture(), before = try LocalHealthClient.fetchControllerIdentity(socketPath: local.socket(), credential: capture.bytes)
                try Self.workspaceCapture(entry, capture, before)
                let root = try NativeGenerationClient.status(socketPath: local.socket(), credential: capture.bytes, kind: .preparation,
                    epoch: entry.preparation.epoch, operation: entry.preparation.operation, original: entry.preparation)
                let attempt: HomeGenerationStatus?
                if let original = entry.attempts.last {
                    attempt = try NativeGenerationClient.status(socketPath: local.socket(), credential: capture.bytes, kind: .attempt,
                        epoch: original.epoch, operation: original.operation, original: original)
                } else { attempt = nil }
                let after = try LocalHealthClient.fetchControllerIdentity(socketPath: local.socket(), credential: capture.bytes)
                try Self.workspaceCapture(entry, capture, after)
                guard after.revision >= before.revision, Int64(after.revision) >= max(root?.knownRevision ?? 0, attempt?.knownRevision ?? 0) else { throw LocalHealthError.nativeGuardConflict }
                try completion(); return (root, attempt)
            }.value
            try current(selected, generation: capturedGeneration); return value
        }
    }
    func prepareGenerationAttempt(_ entry: NativeGenerationWorkspaceEntry, feedbackConsent: Bool) async throws -> NativeGenerationDecision {
        try await metadataChecked {
            guard !busy, !needsReload, let selected = snapshot, selected.document.selection == .local, !entry.cancellationPending else { throw NativeControllerDriverError.unavailable }
            busy = true; defer { busy = false }
            let capturedGeneration = generation, completion = try fence.beginLocal(), local = local
            let decision = try await Task.detached {
                let capture = try local.capture()
                let (identity, contract, options) = try Self.generationBasis(socket: local.socket(), capture: capture)
                try Self.workspaceCapture(entry, capture, identity)
                guard entry.basisSHA == contract.basisSHA else { throw LocalHealthError.nativeGuardConflict }
                let fields = try entry.preparation.fields()
                let policies = try options.fields()["policies"] as! [[String: Any]]
                guard let policy = policies.first(where: { $0["policy_sha256"] as? String == fields["policy_sha256"] as? String }),
                      policy["provider_present"] as? Bool == true,
                      let root = try NativeGenerationClient.status(socketPath: local.socket(), credential: capture.bytes, kind: .preparation,
                        epoch: entry.preparation.epoch, operation: entry.preparation.operation, original: entry.preparation), root.state == "prepared" else { throw LocalHealthError.server("generation_unavailable") }
                let previous = entry.attempts.last, index = entry.attempts.count + 1
                let budget = fields["budget"] as! [String: Any]
                guard index <= LocalHealthClient.profileInteger(budget["attempts"])! else { throw LocalHealthError.invalidProfileRequest }
                var feedbackDraft: String?, feedbackAssessment: HomeGenerationAssessment?
                if let previous {
                    guard feedbackConsent, let status = try NativeGenerationClient.status(socketPath: local.socket(), credential: capture.bytes, kind: .attempt,
                        epoch: previous.epoch, operation: previous.operation, original: previous), status.state == "candidate",
                          let result = status.result, result.assessment?.disposition == "invalid" else { throw LocalHealthError.invalidProfileRequest }
                    let resultFields = try result.fields(), draft = resultFields["draft_ref"] as! [String: Any]
                    guard let object = try NativeAuthoringReadClient.fetchObject(socketPath: local.socket(), credential: capture.bytes, digest: draft["object_digest"] as! String),
                          object.summary.kind == "draft", object.firstRevision == Int64(LocalHealthClient.profileInteger(draft["first_revision"])!),
                          object.summary.payloadSHA == result.assessment?.draftSHA, let text = String(data: object.payload, encoding: .utf8) else { throw LocalHealthError.invalidResponse }
                    feedbackDraft = text; feedbackAssessment = result.assessment
                }
                let after = try LocalHealthClient.fetchControllerIdentity(socketPath: local.socket(), credential: capture.bytes)
                guard after.matchesAuthority(identity), after.revision == identity.revision else { throw LocalHealthError.nativeGuardConflict }
                let original = try NativeGenerationOriginalWire.encode(["authority_epoch": identity.authorityEpoch,
                    "operation_id": "generation:attempt:" + UUID().uuidString.lowercased(), "expected_revision": identity.revision,
                    "preparation_operation_id": entry.preparation.operation, "preparation_sha256": entry.preparation.sha,
                    "attempt": index, "previous_operation_id": previous.map { $0.operation as Any } ?? NSNull(), "repair_export": previous != nil], kind: .attempt)
                _ = try entry.appending(original)
                try completion()
                return NativeGenerationDecision(original: original, context: NativeGenerationContext(options: options, contract: contract,
                    identity: identity, capture: capture, selection: selected, generation: capturedGeneration), previous: entry, feedbackDraft: feedbackDraft, feedbackAssessment: feedbackAssessment)
            }.value
            try current(selected, generation: capturedGeneration); return decision
        }
    }
    func submitGeneration(_ decision: NativeGenerationDecision, workspace: NativeGenerationWorkspaceCoordinator,
                          journal: NativePendingCoordinator) async throws -> NativeGenerationWorkspaceEntry {
        try await metadataChecked {
            let context = decision.context
            guard !busy, !needsReload, snapshot == context.selection, generation == context.generation, journal.canStart else { throw NativeControllerDriverError.unavailable }
            busy = true; defer { busy = false }
            let local = local, completion = try fence.beginLocal()
            let capture = try await Task.detached {
                let fresh = try local.capture()
                guard fresh.bytes == context.capture.bytes, fresh.nativeReference == context.capture.nativeReference else { throw LocalHealthError.sessionChanged }
                let (identity, contract, options) = try Self.generationBasis(socket: local.socket(), capture: fresh)
                guard identity.matchesAuthority(context.identity), identity.revision == context.identity.revision,
                      contract.basisSHA == context.contract.basisSHA, options == context.options else { throw LocalHealthError.nativeGuardConflict }
                try completion(); return fresh
            }.value
            try current(context.selection, generation: context.generation)
            let entry: NativeGenerationWorkspaceEntry
            if let previous = decision.previous {
                try workspace.current(previous); entry = try previous.appending(decision.original)
                try await workspace.replace(previous, with: entry)
            } else {
                entry = try NativeGenerationWorkspaceEntry(context: NativePendingContext(deployment: context.identity.deploymentID,
                    owner: context.identity.ownerID, epoch: Int64(context.identity.authorityEpoch), principal: context.identity.principalID),
                    custody: Self.generationCustody(context), basisSHA: context.contract.basisSHA,
                    preparation: decision.original, attempts: [], cancellationPending: false).checked()
                try await workspace.retain(entry)
            }
            try current(context.selection, generation: context.generation); try workspace.current(entry)
            let pending = try await journal.begin(.generation(decision.original), authorityEpoch: Int(decision.original.epoch),
                expectedController: context.identity, expectedCapture: capture)
            let currentOriginal = try journal.currentOriginal(pending)
            _ = try await Task.detached {
                try completion()
                let receipt = try NativeGenerationClient.submit(socketPath: local.socket(), credential: currentOriginal.bytes, original: decision.original)
                let after = try LocalHealthClient.fetchControllerIdentity(socketPath: local.socket(), credential: currentOriginal.bytes)
                guard after.matchesAuthority(context.identity), Int64(after.revision) >= receipt.revision else { throw LocalHealthError.nativeGuardConflict }
                try completion(); return receipt
            }.value
            try current(context.selection, generation: context.generation); try workspace.current(entry)
            if decision.original.kind == .preparation { try await journal.resolving(currentOriginal) }
            return entry
        }
    }
    func cancelGeneration(_ entry: NativeGenerationWorkspaceEntry, workspace: NativeGenerationWorkspaceCoordinator, retry: Bool) async throws -> NativeGenerationWorkspaceEntry {
        try await metadataChecked {
            guard !busy, !needsReload, let selected = snapshot, selected.document.selection == .local else { throw NativeControllerDriverError.unavailable }
            busy = true; defer { busy = false }
            let capturedGeneration = generation, completion = try fence.beginLocal(), local = local
            let capture = try await Task.detached {
                let capture = try local.capture(), identity = try LocalHealthClient.fetchControllerIdentity(socketPath: local.socket(), credential: capture.bytes)
                try Self.workspaceCapture(entry, capture, identity); try completion(); return capture
            }.value
            try current(selected, generation: capturedGeneration); try workspace.current(entry)
            var retained = entry
            if retry {
                retained = try entry.cancellation(true); try await workspace.replace(entry, with: retained)
            }
            let root = try await Task.detached {
                try completion()
                let result = try retry ? NativeGenerationClient.cancel(socketPath: local.socket(), credential: capture.bytes, original: entry.preparation) :
                    NativeGenerationClient.status(socketPath: local.socket(), credential: capture.bytes, kind: .preparation,
                        epoch: entry.preparation.epoch, operation: entry.preparation.operation, original: entry.preparation)
                let after = try LocalHealthClient.fetchControllerIdentity(socketPath: local.socket(), credential: capture.bytes)
                try Self.workspaceCapture(entry, capture, after)
                guard Int64(after.revision) >= (result?.knownRevision ?? 0) else { throw LocalHealthError.nativeGuardConflict }
                try completion(); return result
            }.value
            try current(selected, generation: capturedGeneration)
            if root?.state == "cancelled" && retained.cancellationPending {
                let cleared = try retained.cancellation(false); try await workspace.replace(retained, with: cleared); return cleared
            }
            return retained
        }
    }

    // Restore only retained bytes. Mutation and existing-only lookup remain
    // separate, explicit actions in the shared pending recovery panel.
    func restoreGenerationPending(_ entry: NativeGenerationWorkspaceEntry, workspace: NativeGenerationWorkspaceCoordinator,
                                  journal: NativePendingCoordinator) async throws {
        try await metadataChecked {
            guard !busy, !needsReload, let selected = snapshot, selected.document.selection == .local,
                  journal.canStart, !entry.cancellationPending else { throw NativeControllerDriverError.unavailable }
            busy = true; defer { busy = false }
            let capturedGeneration = generation, completion = try fence.beginLocal(), local = local
            try workspace.current(entry)
            let (capture, identity, original) = try await Task.detached {
                let capture = try local.capture(), before = try LocalHealthClient.fetchControllerIdentity(socketPath: local.socket(), credential: capture.bytes)
                try Self.workspaceCapture(entry, capture, before)
                let root = try NativeGenerationClient.status(socketPath: local.socket(), credential: capture.bytes, kind: .preparation,
                    epoch: entry.preparation.epoch, operation: entry.preparation.operation, original: entry.preparation)
                guard root != nil || entry.attempts.isEmpty else { throw LocalHealthError.nativeGuardConflict }
                let original = entry.attempts.last ?? entry.preparation
                var knownRevision = root?.knownRevision ?? 0
                if original.kind == .attempt {
                    let status = try NativeGenerationClient.status(socketPath: local.socket(), credential: capture.bytes, kind: .attempt,
                        epoch: original.epoch, operation: original.operation, original: original)
                    knownRevision = max(knownRevision, status?.knownRevision ?? 0)
                }
                let after = try LocalHealthClient.fetchControllerIdentity(socketPath: local.socket(), credential: capture.bytes)
                try Self.workspaceCapture(entry, capture, after)
                guard after.revision >= before.revision, Int64(after.revision) >= knownRevision else { throw LocalHealthError.nativeGuardConflict }
                try completion(); return (capture, after, original)
            }.value
            try current(selected, generation: capturedGeneration); try workspace.current(entry)
            _ = try await journal.begin(.generation(original), authorityEpoch: Int(original.epoch), expectedController: identity, expectedCapture: capture)
            try current(selected, generation: capturedGeneration); try workspace.current(entry)
        }
    }

    func prepareGeneratedDraftAssessment(_ entry: NativeGenerationWorkspaceEntry, instruction: String) async throws -> NativeAuthoringPreparedDecision {
        try await metadataChecked {
            guard !busy, !needsReload, let selected = snapshot, selected.document.selection == .local,
                  let attempt = entry.attempts.last else { throw NativeControllerDriverError.unavailable }
            busy = true; defer { busy = false }
            let capturedGeneration = generation, completion = try fence.beginLocal(), local = local
            let decision = try await Task.detached {
                let capture = try local.capture(), initial = try LocalHealthClient.fetchControllerIdentity(socketPath: local.socket(), credential: capture.bytes)
                try Self.workspaceCapture(entry, capture, initial)
                guard let status = try NativeGenerationClient.status(socketPath: local.socket(), credential: capture.bytes, kind: .attempt,
                    epoch: attempt.epoch, operation: attempt.operation, original: attempt), let result = status.result,
                      result.disposition == "candidate", let assessment = result.assessment else { throw LocalHealthError.invalidProfileRequest }
                let resultFields = try result.fields(), draft = resultFields["draft_ref"] as! [String: Any]
                let digest = draft["object_digest"] as! String, first = LocalHealthClient.profileInteger(draft["first_revision"])!
                let bytes = try JSONSerialization.data(withJSONObject: [entry.context.principal, attempt.epoch, attempt.operation, "draft"], options: [.withoutEscapingSlashes])
                let importID = "ga:" + LocalHealthClient.profileSHA(Data("wotex-home.generation-object-operation@1\n".utf8) + bytes)
                guard let imported = try NativeAuthoringReadClient.fetchOriginal(socketPath: local.socket(), credential: capture.bytes, kind: .import,
                    epoch: attempt.epoch, operation: importID), imported.object?.kind == "draft", imported.object?.digest == digest,
                      imported.firstRevision == Int64(first), imported.object?.payloadSHA == assessment.draftSHA,
                      let object = try NativeAuthoringReadClient.fetchObject(socketPath: local.socket(), credential: capture.bytes, digest: digest),
                      object.summary == imported.object, object.firstRevision == Int64(first) else { throw LocalHealthError.invalidResponse }
                let projection = try entry.preparation.fields()["projection"] as! [String: Any]
                var sources: [String: NativeAuthoringObjectHandle] = [:]
                for row in projection["passages"] as! [[String: Any]] {
                    let ref = row["reference"] as! [String: Any], digest = ref["object_digest"] as! String
                    sources[digest] = NativeAuthoringObjectHandle(digest: digest, firstRevision: LocalHealthClient.profileInteger(ref["first_revision"])!)
                }
                let fixtures = (projection["examples"] as! [[String: Any]]).map {
                    NativeAuthoringObjectHandle(digest: $0["object_digest"] as! String, firstRevision: LocalHealthClient.profileInteger($0["first_revision"])!)
                }
                let selections = NativeAuthoringSelections(sources: sources.values.sorted { $0.digest < $1.digest }, fixtures: fixtures)
                let (identity, contract) = try Self.manualBasis(socket: local.socket(), capture: capture, selections: selections)
                try Self.workspaceCapture(entry, capture, identity)
                var limits: [String: Any] = contract.limits.authoring.mapValues { Int($0) as Any }
                limits["reader"] = contract.limits.reader.mapValues(Int.init)
                let original = try NativeAuthoringOriginalWire.encode(["authority_epoch": identity.authorityEpoch, "expected_revision": identity.revision,
                    "operation_id": "authoring:generated-assess:" + UUID().uuidString.lowercased(),
                    "request": ["mode": "manual", "contract_digest": contract.contractSHA,
                        "base_draft_ref": ["object_digest": digest, "first_revision": first], "source_refs": selections.sources.map(\.fields),
                        "fixture_refs": selections.fixtures.map(\.fields), "instruction": instruction, "limits": limits]], kind: .candidate)
                try completion()
                return NativeAuthoringPreparedDecision(original: original, payload: nil, capture: capture, identity: identity,
                    selection: selected, generation: capturedGeneration, manualBasis: contract.basisSHA)
            }.value
            try current(selected, generation: capturedGeneration); return decision
        }
    }

    func loadMappingEditorContext() async throws -> NativeMappingEditorContext {
        try await metadataChecked {
            guard !busy, !needsReload, let selected = snapshot, selected.document.selection == .local else { throw NativeControllerDriverError.unavailable }
            busy = true; defer { busy = false }
            let capturedGeneration = generation, completion = try fence.beginLocal(), local = local
            let context = try await Task.detached {
                let capture = try local.capture()
                let (identity, contract) = try Self.manualBasis(socket: local.socket(), capture: capture)
                let grammar = try HomeMappingGrammar.parse(contract)
                try completion()
                return NativeMappingEditorContext(grammar: grammar, contract: contract, identity: identity, selection: selected, generation: capturedGeneration)
            }.value
            try current(selected, generation: capturedGeneration); return context
        }
    }
    func prepareManualDraftImport(_ url: URL) async throws -> NativeAuthoringPreparedDecision {
        try await prepareManualDraftImport(context: nil, payloadLoader: { try NativeAuthoringFiles.read(url, maximum: 262144) })
    }
    func prepareMappingDraftImport(context: NativeMappingEditorContext, fields: NativeMappingDraftFields) async throws -> NativeAuthoringPreparedDecision {
        try await prepareManualDraftImport(context: context, payloadLoader: { try fields.payload(grammar: context.grammar) })
    }
    private func prepareManualDraftImport(context: NativeMappingEditorContext?, payloadLoader: @escaping @Sendable () throws -> Data) async throws -> NativeAuthoringPreparedDecision {
        try await metadataChecked {
            guard !busy, !needsReload, let selected = snapshot, selected.document.selection == .local else { throw NativeControllerDriverError.unavailable }
            if let context {
                guard context.selection == selected, context.generation == generation else { throw NativeControllerDriverError.unavailable }
            }
            busy = true; defer { busy = false }
            let capturedGeneration = generation, completion = try fence.beginLocal(), local = local
            let decision = try await Task.detached {
                let payload = try payloadLoader()
                let capture = try local.capture()
                let (identity, contract) = try Self.manualBasis(socket: local.socket(), capture: capture)
                if let context {
                    guard identity.matchesAuthority(context.identity), contract.basisSHA == context.grammar.basis else { throw LocalHealthError.nativeGuardConflict }
                }
                let summary = try NativeAuthoringReadClient.objectSummary(kind: "draft", payload: payload)
                let original = try NativeAuthoringOriginalWire.encode([
                    "authority_epoch": identity.authorityEpoch, "expected_revision": identity.revision,
                    "operation_id": "authoring:draft:" + UUID().uuidString.lowercased(),
                    "object": ["kind": "draft", "object_digest": summary.digest, "payload_sha256": summary.payloadSHA, "payload_bytes": summary.size]
                ], kind: .import)
                _ = try NativePendingAuthoring.checked(original, payload: payload)
                try completion()
                return NativeAuthoringPreparedDecision(original: original, payload: payload, capture: capture, identity: identity,
                    selection: selected, generation: capturedGeneration, manualBasis: contract.basisSHA)
            }.value
            try current(selected, generation: capturedGeneration)
            return decision
        }
    }

    func submitManualDraftImport(_ prepared: NativeAuthoringPreparedDecision, journal: NativePendingCoordinator) async throws -> NativeOwnedManualDraft {
        guard prepared.original.kind == .import, prepared.manualBasis != nil,
              let object = (try prepared.original.fields())["object"] as? [String: Any], object["kind"] as? String == "draft" else { throw LocalHealthError.invalidProfileRequest }
        let receipt = try await submitAuthoring(prepared, journal: journal)
        guard receipt.kind == .import, receipt.object?.kind == "draft", receipt.firstRevision != nil else { throw LocalHealthError.invalidResponse }
        return NativeOwnedManualDraft(receipt: receipt, identity: prepared.identity, selection: prepared.selection, generation: prepared.generation)
    }

    func prepareManualDraftAssessment(_ owned: NativeOwnedManualDraft, instruction: String, selectionURL: URL? = nil) async throws -> NativeAuthoringPreparedDecision {
        try await metadataChecked {
            guard !busy, !needsReload, let selected = snapshot, selected.document.selection == .local,
                  owned.selection == selected, owned.generation == generation,
                  let summary = owned.receipt.object, summary.kind == "draft", let first = owned.receipt.firstRevision else { throw NativeControllerDriverError.unavailable }
            busy = true; defer { busy = false }
            let capturedGeneration = generation, completion = try fence.beginLocal(), local = local
            let decision = try await Task.detached {
                let selections = try NativeAuthoringSelections.read(selectionURL)
                let capture = try local.capture()
                let (identity, contract) = try Self.manualBasis(socket: local.socket(), capture: capture, selections: selections)
                guard identity.matchesAuthority(owned.identity), owned.receipt.epoch == identity.authorityEpoch else { throw LocalHealthError.nativeGuardConflict }
                var limits: [String: Any] = contract.limits.authoring.mapValues { Int($0) as Any }
                limits["reader"] = contract.limits.reader.mapValues(Int.init)
                let original = try NativeAuthoringOriginalWire.encode([
                    "authority_epoch": identity.authorityEpoch, "expected_revision": identity.revision,
                    "operation_id": "authoring:assess:" + UUID().uuidString.lowercased(),
                    "request": ["mode": "manual", "contract_digest": contract.contractSHA,
                        "base_draft_ref": ["object_digest": summary.digest, "first_revision": Int(first)],
                        "source_refs": selections.sources.map(\.fields), "fixture_refs": selections.fixtures.map(\.fields), "instruction": instruction, "limits": limits]
                ], kind: .candidate)
                _ = try NativePendingAuthoring.checked(original, payload: nil)
                try completion()
                return NativeAuthoringPreparedDecision(original: original, payload: nil, capture: capture, identity: identity,
                    selection: selected, generation: capturedGeneration, manualBasis: contract.basisSHA)
            }.value
            try current(selected, generation: capturedGeneration)
            return decision
        }
    }

    nonisolated private static func manualBasis(socket: String, capture: LocalCredentialCapture, selections: NativeAuthoringSelections? = nil) throws -> (HomeControllerIdentity, HomeAuthoringContractRead) {
        let before = try LocalHealthClient.fetchControllerIdentity(socketPath: socket, credential: capture.bytes)
        try nativeCapture(capture.nativeReference, credential: capture.bytes, identity: before)
        let contract = try NativeAuthoringContractClient.fetch(socketPath: socket, credential: capture.bytes)
        try selections?.verify(socket: socket, credential: capture.bytes)
        let after = try LocalHealthClient.fetchControllerIdentity(socketPath: socket, credential: capture.bytes)
        try nativeCapture(capture.nativeReference, credential: capture.bytes, identity: after)
        guard before.matchesAuthority(after), contract.principal == after.principalID, contract.epoch == after.authorityEpoch,
              before.revision == contract.revision, contract.revision == after.revision else { throw LocalHealthError.nativeGuardConflict }
        return (after, contract)
    }

    func prepareAuthoringReview(candidateEpoch: Int64, candidateOperation: String, evidenceURL: URL) async throws -> NativeAuthoringPreparedDecision {
        try await prepareAuthoringReview(candidateEpoch: candidateEpoch, candidateOperation: candidateOperation, contentLoader: {
            let bytes = try NativeAuthoringFiles.read(evidenceURL, maximum: 131072)
            try StrictLocalJSON.check(bytes, maximumKeyBytes: 4096, maximumDepth: 8)
            guard let content = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  Set(content.keys) == Set(["mode", "evidence", "unresolved_paths", "envelope_ref"]) else { throw LocalHealthError.invalidProfileRequest }
            return content
        })
    }
    func prepareAuthoringReview(candidateEpoch: Int64, candidateOperation: String, content: NativeAuthoringReviewContent) async throws -> NativeAuthoringPreparedDecision {
        try await prepareAuthoringReview(candidateEpoch: candidateEpoch, candidateOperation: candidateOperation, contentLoader: { try content.checkedFields() })
    }
    private func prepareAuthoringReview(candidateEpoch: Int64, candidateOperation: String,
                                       contentLoader: @escaping @Sendable () throws -> [String: Any]) async throws -> NativeAuthoringPreparedDecision {
        guard candidateEpoch > 0, LocalHealthClient.profileID(candidateOperation) else { throw LocalHealthError.invalidProfileRequest }
        return try await metadataChecked {
            guard !busy, !needsReload, let selected = snapshot, selected.document.selection == .local else { throw NativeControllerDriverError.unavailable }
            busy = true; defer { busy = false }
            let capturedGeneration = generation, completion = try fence.beginLocal(), local = local
            let prepared = try await Task.detached {
                let content = try contentLoader()
                try NativeAuthoringReviewContent.validateFields(content)
                let capture = try local.capture(), socket = local.socket()
                let before = try LocalHealthClient.fetchControllerIdentity(socketPath: socket, credential: capture.bytes)
                try Self.nativeCapture(capture.nativeReference, credential: capture.bytes, identity: before)
                let contract = try NativeAuthoringContractClient.fetch(socketPath: socket, credential: capture.bytes)
                guard let candidate = try NativeAuthoringReadClient.fetchOriginal(socketPath: socket, credential: capture.bytes,
                    kind: .candidate, epoch: candidateEpoch, operation: candidateOperation) else { throw LocalHealthError.server("candidate_unavailable") }
                guard candidate.disposition == "compatible" else { throw LocalHealthError.server("candidate_incompatible") }
                guard let input = candidate.inputSHA, let assessment = candidate.resultSHA,
                      candidate.basisSHA == contract.basisSHA else { throw LocalHealthError.nativeGuardConflict }
                let after = try LocalHealthClient.fetchControllerIdentity(socketPath: socket, credential: capture.bytes)
                try Self.nativeCapture(capture.nativeReference, credential: capture.bytes, identity: after)
                guard before.matchesAuthority(after), contract.principal == after.principalID, contract.epoch == after.authorityEpoch,
                      before.revision == contract.revision, contract.revision == after.revision else { throw LocalHealthError.nativeGuardConflict }
                guard candidate.revision <= after.revision else { throw LocalHealthError.invalidResponse }
                var review = content
                review["candidate_ref"] = ["authority_epoch": Int(candidate.epoch), "operation_id": candidate.operation,
                    "revision": Int(candidate.revision), "input_sha256": input, "assessment_sha256": assessment]
                let original = try NativeAuthoringOriginalWire.encode(["authority_epoch": after.authorityEpoch,
                    "operation_id": "authoring:review:" + UUID().uuidString.lowercased(), "expected_revision": after.revision, "review": review], kind: .review)
                _ = try NativePendingAuthoring.checked(original, payload: nil)
                try completion()
                return NativeAuthoringPreparedDecision(original: original, payload: nil, capture: capture, identity: after,
                    selection: selected, generation: capturedGeneration, manualBasis: contract.basisSHA)
            }.value
            try current(selected, generation: capturedGeneration)
            return prepared
        }
    }

    func prepareAuthoring(kind: HomeAuthoringOriginalKind, originalURL: URL, payloadURL: URL?) async throws -> NativeAuthoringPreparedDecision {
        try await metadataChecked {
            guard !busy, !needsReload, let selected = snapshot, selected.document.selection == .local else { throw NativeControllerDriverError.unavailable }
            busy = true; defer { busy = false }
            let capturedGeneration = generation, completion = try fence.beginLocal(), local = local
            let prepared = try await Task.detached {
                let maximum = kind == .import ? 4096 : kind == .candidate ? 65_536 : 262_144
                let original = try NativeAuthoringOriginalWire.nativeJSON(NativeAuthoringFiles.read(originalURL, maximum: maximum), kind: kind)
                let payload: Data?
                if kind == .import {
                    guard let payloadURL else { throw NativeAuthoringFileError.invalidFile }
                    payload = try NativeAuthoringFiles.read(payloadURL, maximum: 262_144)
                } else {
                    guard payloadURL == nil else { throw NativeAuthoringFileError.invalidFile }; payload = nil
                }
                _ = try NativePendingAuthoring.checked(original, payload: payload)
                let capture = try local.capture(), socket = local.socket()
                let before = try LocalHealthClient.fetchControllerIdentity(socketPath: socket, credential: capture.bytes)
                try Self.nativeCapture(capture.nativeReference, credential: capture.bytes, identity: before)
                let profiles = try LocalHealthClient.fetchProfiles(socketPath: socket, credential: capture.bytes)
                let after = try LocalHealthClient.fetchControllerIdentity(socketPath: socket, credential: capture.bytes)
                guard before.matchesAuthority(after), profiles.authorityEpoch == after.authorityEpoch,
                      profiles.storeRevision == before.revision, after.revision == profiles.storeRevision,
                      original.epoch == after.authorityEpoch, original.expectedRevision == after.revision else { throw LocalHealthError.nativeGuardConflict }
                try completion()
                return NativeAuthoringPreparedDecision(original: original, payload: payload, capture: capture, identity: after,
                    selection: selected, generation: capturedGeneration)
            }.value
            try current(selected, generation: capturedGeneration)
            return prepared
        }
    }
    func submitAuthoring(_ prepared: NativeAuthoringPreparedDecision, journal: NativePendingCoordinator) async throws -> HomeAuthoringOriginalRead {
        try await metadataChecked {
            guard !busy, !needsReload, let selected = snapshot, selected.document.selection == .local,
                  prepared.selection == selected, prepared.generation == generation, journal.canStart else { throw NativeControllerDriverError.unavailable }
            busy = true; defer { busy = false }
            let completion = try fence.beginLocal(), local = local
            let capture = try await Task.detached {
                let fresh = try local.capture()
                guard fresh.bytes == prepared.capture.bytes, fresh.nativeReference == prepared.capture.nativeReference else { throw LocalHealthError.sessionChanged }
                let identity = try LocalHealthClient.fetchControllerIdentity(socketPath: local.socket(), credential: fresh.bytes)
                try Self.nativeCapture(fresh.nativeReference, credential: fresh.bytes, identity: identity)
                guard identity.matchesAuthority(prepared.identity), identity.revision == prepared.identity.revision else { throw LocalHealthError.nativeGuardConflict }
                if let reviewedBasis = prepared.manualBasis {
                    let (after, contract) = try Self.manualBasis(socket: local.socket(), capture: fresh)
                    guard after.matchesAuthority(identity), after.revision == identity.revision, contract.basisSHA == reviewedBasis else { throw LocalHealthError.nativeGuardConflict }
                }
                try completion(); return fresh
            }.value
            try current(selected, generation: prepared.generation)
            let retained = try await journal.begin(.authoring(prepared.original, prepared.payload), authorityEpoch: Int(prepared.original.epoch),
                expectedController: prepared.identity, expectedCapture: capture)
            do {
                try current(selected, generation: prepared.generation)
                let currentOriginal = try journal.currentOriginal(retained)
                let value = try await Task.detached {
                    try completion()
                    let result = try NativeAuthoringMutationClient.deliver(socketPath: local.socket(), credential: currentOriginal.bytes,
                        original: prepared.original, payload: prepared.payload, lookup: false)
                    guard let result else { throw LocalHealthError.invalidResponse }
                    let after = try LocalHealthClient.fetchControllerIdentity(socketPath: local.socket(), credential: currentOriginal.bytes)
                    guard after.matchesAuthority(prepared.identity), after.revision >= result.revision else { throw LocalHealthError.nativeGuardConflict }
                    try completion(); return result
                }.value
                try current(selected, generation: prepared.generation)
                try await journal.resolving(currentOriginal)
                return value
            } catch LocalHealthError.server(let reason) {
                if NativeAuthoringPreparedDecision.initialRefusals.contains(reason) {
                    try current(selected, generation: prepared.generation)
                    try await journal.resolving(retained)
                }
                throw LocalHealthError.server(reason)
            }
        }
    }
    nonisolated private static func authoring(_ request: HomeAuthoringReadRequest, socket: String, credential: Data,
                                            identity: HomeControllerIdentity? = nil, reference: Data? = nil) throws -> HomeAuthoringReadResult {
        let before = try LocalHealthClient.fetchControllerIdentity(socketPath: socket, credential: credential)
        try nativeCapture(reference, credential: credential, identity: before)
        if let identity {
            guard before.matchesAuthority(identity), before.revision >= identity.revision else { throw LocalHealthError.nativeGuardConflict }
        }
        let value = try NativeAuthoringReadClient.fetch(socketPath: socket, credential: credential, request: request)
        let after = try LocalHealthClient.fetchControllerIdentity(socketPath: socket, credential: credential)
        guard before.matchesAuthority(after), after.revision >= before.revision,
              after.revision >= value.revision else { throw LocalHealthError.nativeGuardConflict }
        return value
    }
    nonisolated private static func nativeCapture(_ reference: Data?, credential: Data, identity: HomeControllerIdentity) throws {
        guard let reference else { return }
        guard case .recover(let original) = try NativeBrokerWire.request(reference), original.valid,
              original.verifier == LocalHealthClient.profileSHA(credential),
              original.receipt.deployment == identity.deploymentID, original.receipt.owner == identity.ownerID,
              original.receipt.epoch == identity.authorityEpoch, original.receipt.principal == identity.principalID,
              identity.revision >= original.receipt.revision else { throw LocalHealthError.nativeGuardConflict }
    }

    nonisolated private static func authoringContract(socket: String, credential: Data,
                                                    identity: HomeControllerIdentity? = nil, reference: Data? = nil) throws -> HomeAuthoringContractRead {
        let before = try LocalHealthClient.fetchControllerIdentity(socketPath: socket, credential: credential)
        try nativeCapture(reference, credential: credential, identity: before)
        if let identity {
            guard before.matchesAuthority(identity), before.revision >= identity.revision else { throw LocalHealthError.nativeGuardConflict }
        }
        let value = try NativeAuthoringContractClient.fetch(socketPath: socket, credential: credential)
        let after = try LocalHealthClient.fetchControllerIdentity(socketPath: socket, credential: credential)
        try nativeCapture(reference, credential: credential, identity: after)
        guard before.matchesAuthority(after), value.principal == before.principalID, value.epoch == before.authorityEpoch,
              value.revision >= before.revision, after.revision >= value.revision else { throw LocalHealthError.nativeGuardConflict }
        return value
    }
    func recover(_ entry: NativePendingEntry, action: NativePendingRecoveryAction, journal: NativePendingCoordinator) async {
        guard pairedRecoveryAvailable, let snapshot, let certificateClock else { return }
        await journal.recoverPaired(entry, action: action, associations: snapshot, clock: certificateClock)
    }
    func submitPower(view: NativePairedPowerViewBasis, thing: HomeThing, on: Bool, operation: String,
                     journal: NativePendingCoordinator) async throws -> NativePairedRecoveryPublication {
        guard !busy, !needsReload, let original = snapshot, original == view.associations,
              generation == view.generation, view.permits(thing) else { throw NativeControllerDriverError.unavailable }
        busy = true; defer { busy = false }
        let session = try await selected(original)
        do { try NativePairedPowerCorrespondence.check(session.scope, original: view.scope, thing: thing, things: view.things) }
        catch { selectionChanged(); throw error }
        try current(original, generation: view.generation, checkMetadata: false)
        let input = NativePendingInput.power(operation: operation, target: thing.id, revision: Int64(thing.resourceRevision), on: on)
        let publication = try await journal.submittingPaired(input, session: session)
        do {
            try current(original, generation: view.generation, checkMetadata: false)
            try publication.deliveryCurrent()
            return publication
        } catch {
            journal.pairedDeliveryUnconfirmed(publication)
            throw error
        }
    }
}

struct NativeAuthoringSelections: Sendable {
    let sources: [NativeAuthoringObjectHandle], fixtures: [NativeAuthoringObjectHandle]
    static func read(_ url: URL?) throws -> Self {
        guard let url else { return Self(sources: [], fixtures: []) }
        let bytes = try NativeAuthoringFiles.read(url, maximum: 16384)
        try StrictLocalJSON.check(bytes, maximumDepth: 3)
        guard let root = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              Set(root.keys) == Set(["source_refs", "fixture_refs"]) else { throw LocalHealthError.invalidProfileRequest }
        func handles(_ value: Any?) throws -> [NativeAuthoringObjectHandle] {
            guard let list = value as? [[String: Any]], list.count <= 32 else { throw LocalHealthError.invalidProfileRequest }
            var previous = ""
            return try list.map { item in
                guard Set(item.keys) == Set(["object_digest", "first_revision"]),
                      let digest = item["object_digest"] as? String, LocalHealthClient.profileDigest(digest), digest > previous,
                      let first = LocalHealthClient.profileInteger(item["first_revision"]), first > 0 else { throw LocalHealthError.invalidProfileRequest }
                previous = digest; return NativeAuthoringObjectHandle(digest: digest, firstRevision: first)
            }
        }
        return try Self(sources: handles(root["source_refs"]), fixtures: handles(root["fixture_refs"]))
    }
    func verify(socket: String, credential: Data) throws {
        var frameBytes = 0
        for (kind, handles) in [("source", sources), ("fixture", fixtures)] {
            for handle in handles {
                guard let object = try NativeAuthoringReadClient.fetchObject(socketPath: socket, credential: credential, digest: handle.digest) else {
                    throw LocalHealthError.server("authoring_object_unavailable")
                }
                guard object.summary.kind == kind, object.firstRevision == Int64(handle.firstRevision) else {
                    throw LocalHealthError.server("stale_authoring_reference")
                }
                frameBytes += object.summary.size + 42
                guard frameBytes <= 4194304 else { throw LocalHealthError.server("authoring_limit") }
            }
        }
    }
}

struct NativeMappingEditorContext: Sendable, CustomReflectable {
    let grammar: HomeMappingGrammar
    fileprivate let contract: HomeAuthoringContractRead, identity: HomeControllerIdentity
    fileprivate let selection: NativeControllerAssociationSnapshot, generation: UInt64
    var details: [String] { ["Installed mapping contract: \(contract.contractSHA)", "Current authoring basis: \(grammar.basis)", "Available bindings: \(grammar.bindings.count)"] }
    var customMirror: Mirror { Mirror(self, children: ["details": details]) }
}

struct NativeOwnedManualDraft: Sendable, CustomReflectable {
    let receipt: HomeAuthoringOriginalRead
    fileprivate let identity: HomeControllerIdentity, selection: NativeControllerAssociationSnapshot, generation: UInt64
    var customMirror: Mirror { Mirror(self, children: ["receipt": receipt]) }
}

struct NativeAuthoringPreparedDecision: Sendable, CustomReflectable {
    fileprivate let original: HomeAuthoringOriginal, payload: Data?, capture: LocalCredentialCapture
    fileprivate let identity: HomeControllerIdentity, selection: NativeControllerAssociationSnapshot, generation: UInt64
    fileprivate let manualBasis: String?
    fileprivate init(original: HomeAuthoringOriginal, payload: Data?, capture: LocalCredentialCapture, identity: HomeControllerIdentity,
                     selection: NativeControllerAssociationSnapshot, generation: UInt64, manualBasis: String? = nil) {
        self.original = original; self.payload = payload; self.capture = capture; self.identity = identity
        self.selection = selection; self.generation = generation; self.manualBasis = manualBasis
    }
    var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
    var details: [String] {
        var rows = ["\(original.kind.rawValue.capitalized) · Authority \(original.epoch) · \(original.operation)",
            "Store basis: \(original.expectedRevision)", "Principal: \(identity.principalID)", "Owner: \(identity.ownerID)", "Original SHA: \(original.sha)"]
        if let manualBasis { rows.append("Installed authoring basis: \(manualBasis)") }
        guard let fields = try? original.fields() else { return [] }
        if let object = fields["object"] as? [String: Any] {
            rows += ["Object: \(object["kind"]!) · \(object["payload_bytes"]!) bytes", "Object digest: \(object["object_digest"]!)", "Payload SHA: \(object["payload_sha256"]!)"]
        } else if let request = fields["request"] as? [String: Any] {
            rows += ["Contract SHA: \(request["contract_digest"]!)", "Sources: \((request["source_refs"] as? [Any])?.count ?? 0) · Fixtures: \((request["fixture_refs"] as? [Any])?.count ?? 0)"]
        } else if let review = fields["review"] as? [String: Any], let candidate = review["candidate_ref"] as? [String: Any] {
            rows += ["Review: \(review["mode"]!) · Candidate revision \(candidate["revision"]!)", "Evidence: \((review["evidence"] as? [Any])?.count ?? 0) · Unresolved: \((review["unresolved_paths"] as? [Any])?.count ?? 0)"]
        }
        return rows
    }
    fileprivate static let initialRefusals: Set<String> = ["permission_denied", "unauthorized", "invalid_credential", "stale_authority_epoch", "resnapshot_required", "maintenance_active", "authoring_unavailable", "authoring_capture_unavailable", "profiles_producer_unavailable", "authoring_limit", "authoring_object_capacity", "authoring_candidate_capacity", "authoring_review_capacity", "stale_authoring_reference", "stale_authoring_basis", "revision_exhausted", "authoring_operation_conflict", "invalid_authoring_import", "invalid_authoring_candidate", "invalid_authoring_review"]
}

struct NativeControllerSelectionPanel: View {
    @ObservedObject var controller: NativeControllerSessionDriver
    var changesAllowed: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Controller", selection: Binding(get: { controller.needsReload ? nil : controller.selection }, set: { selection in
                if let selection { Task { await controller.select(selection) } }
            })) {
                if controller.needsReload || controller.snapshot == nil { Text("Unavailable").tag(Optional<NativeControllerSelection>.none) }
                Text("This Mac").tag(Optional(NativeControllerSelection.local))
                ForEach(controller.records, id: \.id) { record in Text(record.label).tag(Optional(NativeControllerSelection.remote(record.id))) }
            }.pickerStyle(.menu).disabled(!changesAllowed || controller.busy || controller.needsReload || controller.snapshot == nil)
            Text(controller.status).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error = controller.error { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            if controller.needsReload { Button("Reload Controller Selection") { Task { await controller.reload() } }.disabled(!changesAllowed || controller.busy) }
        }
    }
}
