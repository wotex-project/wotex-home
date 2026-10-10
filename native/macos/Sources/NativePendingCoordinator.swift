import Foundation
import SwiftUI

// Only an actual selected session can derive this presentation metadata. It
// contains no bearer, renews no lease and authorizes no later request itself.
struct NativePairedPowerViewBasis: Sendable, CustomReflectable {
    let associations: NativeControllerAssociationSnapshot
    let scope: HomeControllerScope
    let things: [HomeThing]
    let generation: UInt64
    private let deliveryDeadline: ContinuousClock.Instant
    var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
    private init(associations: NativeControllerAssociationSnapshot, scope: HomeControllerScope, things: [HomeThing], generation: UInt64,
                 deliveryDeadline: ContinuousClock.Instant) {
        self.associations = associations; self.scope = scope; self.things = things; self.generation = generation
        self.deliveryDeadline = deliveryDeadline
    }
    static func deriving(_ session: NativePairedControllerSession, associations: NativeControllerAssociationSnapshot,
                         view: HomeReadView, generation: UInt64) throws -> Self {
        try session.deliveryCurrent()
        guard associations.document.selection == .remote(session.association.id),
              associations.document.records.contains(session.association),
              view.catalogue.authorityEpoch == session.scope.identity.authorityEpoch,
              view.catalogue.watermark >= session.scope.identity.revision,
              view.catalogue.things.allSatisfy({ session.scope.targetIDs.contains($0.id) }) else {
            throw NativePairedSessionError.scopeConflict
        }
        let basis = Self(associations: associations, scope: session.scope, things: view.catalogue.things, generation: generation,
            deliveryDeadline: session.viewDeliveryDeadline)
        try basis.deliveryCurrent()
        return basis
    }
    func permits(_ thing: HomeThing) -> Bool { NativePairedPowerCorrespondence.permits(thing, scope: scope, things: things) }
    func deliveryCurrent() throws {
        guard !Task.isCancelled, ContinuousClock.now < deliveryDeadline else { throw NativePendingError.outcomeUnknown }
    }
}

struct NativePendingPersistence: Sendable {
    private let directory: URL?
    init() { directory = nil }
    // A private foreground fixture cannot supply an authenticated custody seal.
    init(directory: URL) { self.directory = directory }
    func load() throws -> NativePendingSnapshot {
        if let directory { return try NativePendingStorage.load(directory: directory) }
        return try NativePendingStorage.load()
    }
    func retain(_ entry: NativePendingEntry, expected: NativePendingSnapshot) throws -> NativePendingSnapshot {
        if let directory { return try NativePendingStorage.retaining(entry, directory: directory, expected: expected) }
        return try NativePendingStorage.retaining(entry, expected: expected)
    }
    func phase(_ entry: NativePendingEntry, _ phase: NativePendingPhase, expected: NativePendingSnapshot) throws -> NativePendingSnapshot {
        if let directory { return try NativePendingStorage.changingPhase(of: entry, to: phase, directory: directory, expected: expected) }
        return try NativePendingStorage.changingPhase(of: entry, to: phase, expected: expected)
    }
    func resolve(_ entry: NativePendingEntry, expected: NativePendingSnapshot) throws -> NativePendingSnapshot {
        if let directory { return try NativePendingStorage.confirmingResolution(entry, directory: directory, expected: expected) }
        return try NativePendingStorage.confirmingResolution(entry, expected: expected)
    }
}

struct NativePendingOriginal: Sendable, CustomReflectable {
    let bytes: Data
    let entry: NativePendingEntry
    var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
}

@MainActor
final class NativePendingCoordinator: ObservableObject, CustomReflectable {
    static let shared = NativePendingCoordinator()
    nonisolated var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
    nonisolated private let persistence: NativePendingPersistence
    nonisolated private let capture: @Sendable () throws -> LocalCredentialCapture
    nonisolated let socketPath: @Sendable () -> String
    @Published private(set) var snapshot: NativePendingSnapshot?
    @Published private(set) var busy = false
    @Published private(set) var needsReload = true
    @Published private(set) var status = "Load pending operations before starting new work."
    @Published private(set) var error: String?
    @Published private(set) var owner: NativeControllerScope?
    private var known: [NativePendingOriginal] = [] // At most sixteen original captures, never serialized as secrets.
    private var knownPaired: [NativePendingEntry] = [] // Metadata only, no paired bearer.
    private var knownCount: Int { known.count + knownPaired.count }
    var didResolve: ((NativePendingEntry) -> Void)?
    var entries: [NativePendingEntry] {
        let stored = snapshot?.document.entries ?? []
        return NativePendingDocument.sorted(stored + (known.map(\.entry) + knownPaired).filter { original in
            !stored.contains { Self.sameOriginal($0, original) }
        })
    }
    nonisolated private static func sameOriginal(_ left: NativePendingEntry, _ right: NativePendingEntry) -> Bool {
        left.context == right.context && left.custody == right.custody && left.input == right.input
    }
    private func remember(_ original: NativePendingOriginal) throws {
        guard !original.entry.custody.isPaired, original.entry.custody.matches(original.bytes) else { throw NativePendingError.invalidRecord }
        _ = try NativePendingDocument(revision: 1, entries: [original.entry]).encoded()
        if let index = known.firstIndex(where: { Self.sameOriginal($0.entry, original.entry) }) { known[index] = original }
        else { guard knownCount < 16 else { throw NativePendingError.capacity }; known.append(original) }
    }
    private func rememberPaired(_ entry: NativePendingEntry) throws {
        guard entry.custody.isPaired, entry.category != .access else { throw NativePendingError.invalidRecord }
        _ = try NativePendingDocument(revision: 1, entries: [entry]).encoded()
        if let index = knownPaired.firstIndex(where: { Self.sameOriginal($0, entry) }) { knownPaired[index] = entry }
        else { guard knownCount < 16 else { throw NativePendingError.capacity }; knownPaired.append(entry) }
    }
    var hasCurrentOriginal: Bool {
        guard let owner else { return !entries.isEmpty }
        return entries.contains { $0.context.deployment == owner.deployment && $0.context.owner == owner.owner && $0.context.epoch == owner.epoch }
    }
    var canStart: Bool { snapshot != nil && !busy && !needsReload && !hasCurrentOriginal }
    init(persistence: NativePendingPersistence = NativePendingPersistence(),
         capture: @escaping @Sendable () throws -> LocalCredentialCapture = { try OperatorCredential.captureOriginal() },
         socketPath: @escaping @Sendable () -> String = { LocalHealthClient.defaultSocketPath() }) {
        self.persistence = persistence; self.capture = capture; self.socketPath = socketPath
    }

    // Startup is private-file read only. It never captures a credential or
    // invokes a broker, API, driver or automatic recovery action.
    func loadIfNeeded() async { if snapshot == nil || needsReload { await reload() } }
    func reload() async {
        guard !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            snapshot = try await Task.detached(priority: .userInitiated) { try self.persistence.load() }.value
            needsReload = false
            status = entries.isEmpty ? "No pending operations." : "Recover the original pending operation before new work."
        } catch { needsReload = true; status = "Pending operations unavailable."; self.error = error.localizedDescription }
    }
    // Only call with scope obtained by an actual signed broker status or an
    // authenticated identity read. Metadata decoded from a file supplies none.
    func observedOwner(_ scope: NativeControllerScope) {
        guard NativeCoreWire.valid(scope), !busy else { return }
        owner = scope
    }
    func begin(_ input: NativePendingInput, authorityEpoch: Int, expectedCredential: Data? = nil,
               expectedNativeReference: Data? = nil, expectedController: HomeControllerIdentity? = nil,
               expectedCapture: LocalCredentialCapture? = nil) async throws -> NativePendingOriginal {
        guard canStart, knownCount < 16, let expected = snapshot else { throw LocalHealthError.server("resolve_original_operation") }
        busy = true; error = nil
        defer { busy = false }
        let captured = try await Task.detached(priority: .userInitiated) { try self.capture() }.value
        if let expectedCapture {
            guard expectedCapture.bytes == captured.bytes, expectedCapture.nativeReference == captured.nativeReference else { throw LocalHealthError.sessionChanged }
        }
        guard expectedCredential == nil || expectedCredential == captured.bytes else { throw LocalHealthError.sessionChanged }
        guard expectedNativeReference == nil || expectedNativeReference == captured.nativeReference else { throw LocalHealthError.sessionChanged }
        let identity = try await Task.detached(priority: .userInitiated) {
            try LocalHealthClient.fetchControllerIdentity(socketPath: self.socketPath(), credential: captured.bytes)
        }.value
        guard identity.authorityEpoch == authorityEpoch else { throw LocalHealthError.sessionChanged }
        guard expectedController.map({ identity.matchesAuthority($0) }) != false else { throw LocalHealthError.sessionChanged }
        let context = NativePendingContext(deployment: identity.deploymentID, owner: identity.ownerID,
            epoch: Int64(identity.authorityEpoch), principal: identity.principalID)
        let custody: NativePendingCustody
        if let reference = captured.nativeReference {
            guard case .recover(let original) = try NativeBrokerWire.request(reference), original.verifier == captured.verifier,
                  original.receipt.deployment == context.deployment, original.receipt.owner == context.owner,
                  original.receipt.epoch == context.epoch, original.receipt.principal == context.principal,
                  identity.revision >= original.receipt.revision else { throw LocalHealthError.nativeGuardConflict }
            custody = .native(role: original.receipt.role, creationRevision: original.receipt.revision, verifier: captured.verifier)
        } else { custody = .manual(verifier: captured.verifier) }
        guard custody.valid(context: context) else { throw LocalHealthError.nativeGuardConflict }
        guard !expected.document.entries.contains(where: { $0.context.deployment == context.deployment &&
            $0.context.owner == context.owner && $0.context.epoch == context.epoch }) else {
            throw LocalHealthError.server("resolve_original_operation")
        }
        let entry = NativePendingEntry(context: context, custody: custody, input: input, phase: .pending)
        _ = try NativePendingDocument(revision: 1, entries: [entry]).encoded()
        let original = NativePendingOriginal(bytes: captured.bytes, entry: entry)
        try remember(original)
        owner = NativeControllerScope(deployment: context.deployment, owner: context.owner, epoch: context.epoch, revision: Int64(identity.revision))
        do {
            snapshot = try await Task.detached(priority: .userInitiated) { try self.persistence.retain(entry, expected: expected) }.value
        } catch {
            needsReload = true; self.error = error.localizedDescription
            status = "Original publication not confirmed. Reload before sending any request."
            throw error
        }
        status = "Original operation retained before submission."
        return original
    }
    func changingPhase(_ original: NativePendingOriginal, to phase: NativePendingPhase) async throws -> NativePendingOriginal {
        guard !busy, !needsReload, let expected = snapshot,
              NativePendingStorage.permitsTransition(from: original.entry.phase, to: phase),
              let current = expected.document.entries.first(where: { $0.context == original.entry.context &&
                  $0.custody == original.entry.custody && $0.input == original.entry.input }),
              knownCount < 16 || known.contains(where: { Self.sameOriginal($0.entry, current) }) else {
            throw NativePendingError.conflict
        }
        busy = true; defer { busy = false }
        try remember(original)
        do {
            snapshot = try await Task.detached(priority: .userInitiated) { try self.persistence.phase(current, phase, expected: expected) }.value
            let retained = NativePendingOriginal(bytes: original.bytes, entry: try current.changingPhase(phase))
            try remember(retained)
            return retained
        } catch { needsReload = true; self.error = error.localizedDescription; throw error }
    }
    func beginPaired(_ input: NativePendingInput, session: NativePairedControllerSession) async throws -> NativePairedControllerRecovery {
        guard canStart, knownCount < 16, let expected = snapshot else { throw LocalHealthError.server("resolve_original_operation") }
        busy = true; error = nil
        defer { busy = false }
        return try await capturePaired(input, session: session, expected: expected)
    }
    // Capture, the fixed first retry, receipt publication and actor delivery
    // share one reservation. No caller-supplied runner or successful outcome.
    func submittingPaired(_ input: NativePendingInput, session: NativePairedControllerSession) async throws -> NativePairedRecoveryPublication {
        guard canStart, knownCount < 16, let expected = snapshot else { throw LocalHealthError.server("resolve_original_operation") }
        busy = true; error = nil
        defer { busy = false }
        do {
            let original = try await capturePaired(input, session: session, expected: expected)
            let publication = try await original.performAndPublish()
            try consumePaired(publication)
            return publication
        } catch {
            needsReload = true; self.error = error.localizedDescription
            status = "Original submission not confirmed. Reload its records before continuing."
            throw error
        }
    }
    private func capturePaired(_ input: NativePendingInput, session: NativePairedControllerSession,
                               expected: NativePendingSnapshot) async throws -> NativePairedControllerRecovery {
        let entry = try session.original(input: input, pending: expected)
        try rememberPaired(entry)
        owner = NativeControllerScope(deployment: entry.context.deployment, owner: entry.context.owner,
            epoch: entry.context.epoch, revision: Int64(session.scope.identity.revision))
        do {
            let original = try await session.capturing(entry, pending: expected)
            try original.deliveryCurrent()
            snapshot = original.pending
            status = "Original operation retained before submission."
            return original
        } catch {
            needsReload = true; self.error = error.localizedDescription
            status = "Original publication not confirmed. Reload before sending any request."
            throw error
        }
    }
    func currentOriginal(_ original: NativePendingOriginal) throws -> NativePendingOriginal {
        guard !original.entry.custody.isPaired, !busy, !needsReload, original.entry.custody.matches(original.bytes),
              let entry = entries.first(where: { Self.sameOriginal($0, original.entry) }) else { throw NativePendingError.conflict }
        return NativePendingOriginal(bytes: original.bytes, entry: entry)
    }
    // The caller has already verified its original Authority result or definite
    // first-attempt refusal. Publication must finish before it clears memory/UI.
    func resolving(_ original: NativePendingOriginal) async throws {
        guard !busy, !needsReload, let expected = snapshot else {
            throw NativePendingError.conflict
        }
        busy = true; defer { busy = false }
        try remember(original)
        do {
            snapshot = try await Task.detached(priority: .userInitiated) { try self.persistence.resolve(original.entry, expected: expected) }.value
            known.removeAll { Self.sameOriginal($0.entry, original.entry) }
            didResolve?(original.entry)
            status = entries.isEmpty ? "No pending operations." : "Other original operations remain unresolved."
        } catch { needsReload = true; self.error = error.localizedDescription; throw error }
    }
    // This entry point never reads general selection. Its caller supplies an
    // existing-only custody opener and the fixed typed original-operation runner.
    func recover(_ entry: NativePendingEntry, action: NativePendingRecoveryAction,
                 custody: @escaping @Sendable (NativePendingEntry) throws -> Data,
                 execute: @escaping @Sendable (NativePendingEntry, Data, String, NativePendingRecoveryAction) throws -> NativePendingRecoveryOutcome) async {
        guard !entry.custody.isPaired, action.permits(entry), !busy, !needsReload, let loaded = snapshot, entries.contains(entry),
              knownCount < 16 || known.contains(where: { Self.sameOriginal($0.entry, entry) }) else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            let bytes = try await Task.detached(priority: .userInitiated) { try custody(entry) }.value
            guard entry.custody.matches(bytes) else { throw LocalHealthError.nativeGuardConflict }
            let identity = try await Task.detached(priority: .userInitiated) {
                try NativeLocalControllerRequestGuard.withOriginal {
                    try LocalHealthClient.fetchControllerIdentity(socketPath: self.socketPath(), credential: bytes)
                }
            }.value
            guard entry.context.matches(identity) else { throw LocalHealthError.nativeGuardConflict }
            if case .native(_, let creation, _) = entry.custody, identity.revision < creation { throw LocalHealthError.nativeGuardConflict }
            var original = NativePendingOriginal(bytes: bytes, entry: entry)
            try remember(original)
            var expected = loaded
            // An original remembered before a failed publication must publish
            // its same closed input before the runner can send any mutation.
            if action != .lookup && !expected.document.entries.contains(entry) {
                do {
                    expected = try await Task.detached(priority: .userInitiated) { try self.persistence.retain(entry, expected: loaded) }.value
                    snapshot = expected
                } catch { needsReload = true; throw error }
            }
            if action == .cancelReview, case .review(let token, let digest) = entry.phase {
                let before = expected
                let phase = NativePendingPhase.cancelPending(token: token, digest: digest)
                do {
                    expected = try await Task.detached(priority: .userInitiated) { try self.persistence.phase(entry, phase, expected: before) }.value
                    snapshot = expected
                } catch { needsReload = true; throw error }
                original = NativePendingOriginal(bytes: bytes, entry: try entry.changingPhase(phase))
                try remember(original)
            }
            let current = original.entry
            let result = try await Task.detached(priority: .userInitiated) {
                try NativeLocalControllerRequestGuard.withOriginal { try execute(current, bytes, self.socketPath(), action) }
            }.value
            switch result {
            case .retained(let detail): status = detail
            case .review(let token, let digest):
                let phase = NativePendingPhase.review(token: token, digest: digest), before = expected
                do {
                    snapshot = try await Task.detached(priority: .userInitiated) { try self.persistence.phase(current, phase, expected: before) }.value
                    try remember(NativePendingOriginal(bytes: bytes, entry: current.changingPhase(phase)))
                } catch { needsReload = true; throw error }
                status = "Original review recovered. Look up or cancel it; a retained review cannot create a new approval."
            case .resolved(let detail):
                let before = expected
                do { snapshot = try await Task.detached(priority: .userInitiated) { try self.persistence.resolve(current, expected: before) }.value }
                catch { needsReload = true; throw error }
                known.removeAll { Self.sameOriginal($0.entry, current) }
                didResolve?(current)
                status = detail
            }
        } catch { self.error = error.localizedDescription; status = "Original recovery not confirmed. Its custody and input remain unchanged." }
    }

    // Separate actual signed original entry. There is no injected successful
    // custody/runner, selected mutation session or fixture publication backend.
    func recoverPaired(_ entry: NativePendingEntry, action: NativePendingRecoveryAction,
                       associations: NativeControllerAssociationSnapshot,
                       clock: @escaping @Sendable () throws -> NativeControllerCertificateClock) async {
        guard entry.custody.isPaired, entry.category != .access, action.permits(entry),
              !busy, !needsReload, let loaded = snapshot, entries.contains(entry),
              knownCount < 16 || knownPaired.contains(where: { Self.sameOriginal($0, entry) }) else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            try rememberPaired(entry)
            var expected = loaded
            // A previous publication may have completed after its owner ended.
            // Restore only the same remembered input on an explicit action;
            // this private metadata write conveys no remote authority.
            if !expected.document.entries.contains(entry) {
                expected = try await NativePendingPublicationOwner.perform(until: ContinuousClock.now.advanced(by: .seconds(5))) {
                    try self.persistence.retain(entry, expected: loaded)
                }
                snapshot = expected
            }
            let recovery = try await NativePairedControllerSession.recovering(entry, action: action,
                pending: expected, associations: associations, clock: clock)
            let publication = try await recovery.performAndPublish()
            try consumePaired(publication)
        } catch {
            needsReload = true; self.error = error.localizedDescription
            status = "Original recovery not confirmed. Reload its records before continuing."
        }
    }
    private func consumePaired(_ publication: NativePairedRecoveryPublication) throws {
        try publication.deliveryCurrent()
        snapshot = publication.pending
        switch publication.outcome {
        case .retained(let detail): status = detail
        case .review:
            try rememberPaired(publication.entry)
            status = "Original review recovered. Look up or cancel it; a retained review cannot create a new approval."
        case .resolved(let detail):
            knownPaired.removeAll { Self.sameOriginal($0, publication.entry) }
            didResolve?(publication.entry)
            status = detail
        }
    }
    // A higher presentation hop can expire after this owner consumed a valid
    // publication. Preserve its exact metadata for explicit reconciliation;
    // this neither republishes a file nor sends a request or renews custody.
    func pairedDeliveryUnconfirmed(_ publication: NativePairedRecoveryPublication) {
        do { try rememberPaired(publication.entry) }
        catch { self.error = "Original recovery memory is full. Reload its records before continuing." }
        needsReload = true
        status = "Original result delivery was not confirmed. Reload its records before continuing."
    }
}
