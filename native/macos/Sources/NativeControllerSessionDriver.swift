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
            guard !busy, !needsReload, let original = snapshot else { throw NativeControllerDriverError.unavailable }
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

    func prepareManualDraftImport(_ url: URL) async throws -> NativeAuthoringPreparedDecision {
        try await metadataChecked {
            guard !busy, !needsReload, let selected = snapshot, selected.document.selection == .local else { throw NativeControllerDriverError.unavailable }
            busy = true; defer { busy = false }
            let capturedGeneration = generation, completion = try fence.beginLocal(), local = local
            let decision = try await Task.detached {
                let payload = try NativeAuthoringFiles.read(url, maximum: 262144)
                let capture = try local.capture()
                let (identity, contract) = try Self.manualBasis(socket: local.socket(), capture: capture)
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
        guard candidateEpoch > 0, LocalHealthClient.profileID(candidateOperation) else { throw LocalHealthError.invalidProfileRequest }
        return try await metadataChecked {
            guard !busy, !needsReload, let selected = snapshot, selected.document.selection == .local else { throw NativeControllerDriverError.unavailable }
            busy = true; defer { busy = false }
            let capturedGeneration = generation, completion = try fence.beginLocal(), local = local
            let prepared = try await Task.detached {
                let bytes = try NativeAuthoringFiles.read(evidenceURL, maximum: 131072)
                try StrictLocalJSON.check(bytes, maximumKeyBytes: 4096, maximumDepth: 8)
                guard let content = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                      Set(content.keys) == Set(["mode", "evidence", "unresolved_paths", "envelope_ref"]) else { throw LocalHealthError.invalidProfileRequest }
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

struct NativeAuthoringObjectHandle: Sendable {
    let digest: String, firstRevision: Int
    var fields: [String: Any] { ["object_digest": digest, "first_revision": firstRevision] }
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
    fileprivate static let initialRefusals: Set<String> = ["permission_denied", "unauthorized", "invalid_credential", "stale_authority_epoch", "resnapshot_required", "maintenance_active", "authoring_unavailable", "profiles_producer_unavailable", "authoring_limit", "authoring_object_capacity", "authoring_candidate_capacity", "authoring_review_capacity", "stale_authoring_reference", "stale_authoring_basis", "revision_exhausted", "authoring_operation_conflict", "invalid_authoring_import", "invalid_authoring_candidate", "invalid_authoring_review"]
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
