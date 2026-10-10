import Foundation

enum NativePairedSessionError: Error, Sendable {
    case invalidSelection, selectionChanged, originalChanged, scopeConflict, expired
    case custody(NativePairedKeychainError)
}

// Pure refusal/correspondence only. A decoded scope cannot create a session.
enum NativePairedSessionCorrespondence {
    static func check(_ scope: HomeControllerScope, association: NativeControllerPublicAssociation) throws {
        _ = try association.encoded()
        let identity = scope.identity, original = association.scope
        guard identity.deploymentID == original.deployment, identity.ownerID == original.owner,
              Int64(identity.authorityEpoch) == original.epoch, identity.principalID == original.principal,
              Int64(identity.revision) >= original.creationRevision,
              !scope.permissions.isEmpty, scope.permissions == scope.permissions.sorted(),
              Set(scope.permissions).count == scope.permissions.count,
              scope.targetIDs == scope.targetIDs.sorted(), Set(scope.targetIDs).count == scope.targetIDs.count,
              Set(scope.permissions).isSubset(of: Set(association.access.permissions)),
              Set(scope.targetIDs).isSubset(of: Set(association.access.targets)) else {
            throw NativePairedSessionError.scopeConflict
        }
    }
}

// Actual signed app -> original account CAS -> existing SecItem -> pinned live
// scope. No raw-key, scope, fixture directory or backend can initialize this.
struct NativePairedControllerSession: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private enum Purpose: Equatable, Sendable {
        case selected
        case original(entry: NativePendingEntry, action: NativePendingRecoveryAction, pending: NativePendingSnapshot)
    }
    let association: NativeControllerPublicAssociation
    let scope: HomeControllerScope
    private let snapshot: NativeControllerAssociationSnapshot
    private let custody: NativePairedKeychainCredential
    private let bearer: Data
    private let deadline: ContinuousClock.Instant
    private let clock: @Sendable () throws -> NativeControllerCertificateClock
    private let purpose: Purpose
    fileprivate var ownerDeadline: ContinuousClock.Instant { deadline }
    var description: String { "private_paired_controller_session" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }

    private init(association: NativeControllerPublicAssociation, scope: HomeControllerScope,
                 snapshot: NativeControllerAssociationSnapshot, material: PairedSessionMaterial,
                 deadline: ContinuousClock.Instant, purpose: Purpose,
                 clock: @escaping @Sendable () throws -> NativeControllerCertificateClock) {
        self.association = association; self.scope = scope; self.snapshot = snapshot
        custody = material.custody; bearer = material.bearer; self.deadline = deadline; self.clock = clock; self.purpose = purpose
    }

    static func selected(expected: NativeControllerAssociationSnapshot,
                         clock: @escaping @Sendable () throws -> NativeControllerCertificateClock) async throws -> Self {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        guard !Task.isCancelled else { throw NativeControllerTLSError.cancelled }
        guard case .remote(let id) = expected.document.selection,
              let association = expected.document.records.first(where: { $0.id == id }) else {
            throw NativePairedSessionError.invalidSelection
        }
        return try await acquire(association: association, expected: expected, purpose: .selected, deadline: deadline, clock: clock)
    }

    static func recovering(_ entry: NativePendingEntry, action: NativePendingRecoveryAction,
                           pending: NativePendingSnapshot, associations: NativeControllerAssociationSnapshot,
                           clock: @escaping @Sendable () throws -> NativeControllerCertificateClock) async throws -> NativePairedControllerRecovery {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        guard !Task.isCancelled else { throw NativeControllerTLSError.cancelled }
        let association = try NativePairedRecoveryCorrespondence.association(for: entry, action: action,
            pending: pending, associations: associations)
        let session = try await acquire(association: association, expected: associations,
            purpose: .original(entry: entry, action: action, pending: pending), deadline: deadline, clock: clock)
        return NativePairedControllerRecovery(session: session, entry: entry, action: action, pending: pending)
    }

    private static func acquire(association: NativeControllerPublicAssociation,
                                expected: NativeControllerAssociationSnapshot, purpose: Purpose,
                                deadline: ContinuousClock.Instant,
                                clock: @escaping @Sendable () throws -> NativeControllerCertificateClock) async throws -> Self {
        _ = try association.encoded()
        let slot = PairedSessionMaterialSlot(deadline: deadline)
        defer { slot.stop() }
        return try await withTaskCancellationHandler {
            let acquisition = NativeControllerExchangeGuard { _ in
                do {
                    try lifetime(deadline)
                    // Actual signing fails before account inspection or SecItem
                    // in unsigned/ad-hoc fixtures. No successful gate is injected.
                    let access = try SignedSetupPeer.pairedKeychainAccess()
                    try snapshots(expected, purpose: purpose)
                    let custody = try NativePairedKeychainCustodian().existing(association: association, access: access)
                    let bearer = try custody.credential(for: association)
                    try snapshots(expected, purpose: purpose)
                    try lifetime(deadline)
                    try slot.publish(PairedSessionMaterial(custody: custody, bearer: bearer))
                } catch {
                    slot.reject(reduced(error))
                    throw NativeControllerTLSError.invalidRecord
                }
            }
            do { try await acquisition.validate(.opening, until: deadline) }
            catch {
                guard !Task.isCancelled else { throw NativeControllerTLSError.cancelled }
                try lifetime(deadline)
                throw slot.failure() ?? NativePairedSessionError.expired
            }
            guard !Task.isCancelled else { throw NativeControllerTLSError.cancelled }
            let material = try slot.take()
            let exchangeGuard = currentGuard(expected: expected, association: association,
                custody: material.custody, deadline: deadline, purpose: purpose)
            let scope = try await NativeControllerDomainClient.perform(association.peer, credential: material.bearer,
                clock: clock, exchangeGuard: exchangeGuard, deadline: deadline) {
                try LocalHealthClient.fetchControllerScope(socketPath: "", credential: material.bearer)
            }
            try NativePairedSessionCorrespondence.check(scope, association: association)
            // Correspondence work also belongs to the original owner lifetime.
            try await exchangeGuard.validate(.decoded, until: deadline)
            guard !Task.isCancelled else { throw NativeControllerTLSError.cancelled }
            try lifetime(deadline)
            return Self(association: association, scope: scope, snapshot: expected,
                material: material, deadline: deadline, purpose: purpose, clock: clock)
        } onCancel: { slot.stop() }
    }

    func perform<Value: Sendable>(_ operation: @escaping @Sendable (Data) throws -> Value) async throws -> Value {
        guard purpose == .selected else { throw NativePendingError.unavailable }
        guard !Task.isCancelled else { throw NativeControllerTLSError.cancelled }
        let exchangeGuard = Self.currentGuard(expected: snapshot, association: association,
            custody: custody, deadline: deadline, purpose: purpose)
        try await exchangeGuard.validate(.opening, until: deadline)
        guard !Task.isCancelled else { throw NativeControllerTLSError.cancelled }
        try Self.lifetime(deadline)
        return try await NativeControllerDomainClient.perform(association.peer, credential: bearer,
            clock: clock, exchangeGuard: exchangeGuard, deadline: deadline) { [bearer] in try operation(bearer) }
    }

    fileprivate func currentOriginal(_ entry: NativePendingEntry, action: NativePendingRecoveryAction,
                                     pending: NativePendingSnapshot) async throws {
        guard purpose == .original(entry: entry, action: action, pending: pending) else { throw NativePendingError.conflict }
        guard !Task.isCancelled else { throw NativeControllerTLSError.cancelled }
        try await Self.currentGuard(expected: snapshot, association: association, custody: custody,
            deadline: deadline, purpose: purpose).validate(.opening, until: deadline)
        guard !Task.isCancelled else { throw NativeControllerTLSError.cancelled }
        try Self.lifetime(deadline)
    }

    fileprivate func performOriginal(_ entry: NativePendingEntry, action: NativePendingRecoveryAction,
                                     pending: NativePendingSnapshot) async throws -> NativePendingRecoveryOutcome {
        guard action != .cancelReview || entry.phase.isCancellation else { throw NativePendingError.invalidRecord }
        try await currentOriginal(entry, action: action, pending: pending)
        let exchangeGuard = Self.currentGuard(expected: snapshot, association: association,
            custody: custody, deadline: deadline, purpose: purpose)
        return try await NativeControllerDomainClient.perform(association.peer, credential: bearer,
            clock: clock, exchangeGuard: exchangeGuard, deadline: deadline) { [association, bearer] in
            try NativePendingRecoveryOperations.executePaired(entry, association: association, credential: bearer, action: action)
        }
    }

    fileprivate func continuingCancellation(_ entry: NativePendingEntry, action: NativePendingRecoveryAction,
                                            pending: NativePendingSnapshot, next: NativePendingSnapshot) async throws -> (Self, NativePendingEntry) {
        guard purpose == .original(entry: entry, action: action, pending: pending) else { throw NativePendingError.conflict }
        let updated = try NativePairedRecoveryCorrespondence.cancellation(of: entry, action: action, before: pending, after: next)
        let continued = Purpose.original(entry: updated, action: action, pending: next)
        guard !Task.isCancelled else { throw NativeControllerTLSError.outcomeUnknown }
        // Old journal CAS intentionally no longer matches after publication.
        // Verify only the exact permitted successor, keeping original custody,
        // association snapshot and deadline; no acquisition/renewal runs here.
        try await Self.currentGuard(expected: snapshot, association: association, custody: custody,
            deadline: deadline, purpose: continued).validate(.opening, until: deadline)
        guard !Task.isCancelled else { throw NativeControllerTLSError.outcomeUnknown }
        try Self.lifetime(deadline)
        let result = Self(association: association, scope: scope, snapshot: snapshot,
            material: PairedSessionMaterial(custody: custody, bearer: bearer), deadline: deadline, purpose: continued, clock: clock)
        return (result, updated)
    }

    fileprivate func publishing(_ entry: NativePendingEntry, action: NativePendingRecoveryAction,
                                 pending: NativePendingSnapshot, outcome: NativePendingRecoveryOutcome) async throws -> (NativePendingSnapshot, NativePendingEntry) {
        guard purpose == .original(entry: entry, action: action, pending: pending) else { throw NativePendingError.conflict }
        let next = try await NativePendingPublicationOwner.perform(until: deadline) { [self] in
            try Self.validateCurrent(expected: snapshot, association: association, custody: custody,
                deadline: deadline, purpose: purpose)
            let next: NativePendingSnapshot
            switch outcome {
            case .retained: try NativePendingStorage.check(pending); next = pending
            case .review(let token, let digest):
                next = try NativePendingStorage.changingPhase(of: entry, to: .review(token: token, digest: digest), expected: pending)
            case .resolved: next = try NativePendingStorage.resolving(entry, expected: pending)
            }
            let updated = try NativePairedRecoveryCorrespondence.publication(of: entry, outcome: outcome, before: pending, after: next)
            try Self.validateCurrent(expected: snapshot, association: association, custody: custody,
                deadline: deadline, purpose: .original(entry: updated, action: action, pending: next))
            return next
        }
        let updated = try NativePairedRecoveryCorrespondence.publication(of: entry, outcome: outcome, before: pending, after: next)
        guard !Task.isCancelled else { throw NativePendingError.outcomeUnknown }
        try await Self.currentGuard(expected: snapshot, association: association, custody: custody,
            deadline: deadline, purpose: .original(entry: updated, action: action, pending: next)).validate(.decoded, until: deadline)
        guard !Task.isCancelled else { throw NativePendingError.outcomeUnknown }
        try Self.lifetime(deadline)
        return (next, updated)
    }

    fileprivate func publishingCancellation(_ entry: NativePendingEntry, action: NativePendingRecoveryAction,
                                             pending: NativePendingSnapshot) async throws -> NativePendingSnapshot {
        guard purpose == .original(entry: entry, action: action, pending: pending), action == .cancelReview,
              case .review(let token, let digest) = entry.phase else { throw NativePendingError.conflict }
        return try await NativePendingPublicationOwner.perform(until: deadline) { [self] in
            try Self.validateCurrent(expected: snapshot, association: association, custody: custody,
                deadline: deadline, purpose: purpose)
            return try NativePendingStorage.changingPhase(of: entry, to: .cancelPending(token: token, digest: digest), expected: pending)
        }
    }

    private static func currentGuard(expected: NativeControllerAssociationSnapshot,
        association: NativeControllerPublicAssociation, custody: NativePairedKeychainCredential,
        deadline: ContinuousClock.Instant, purpose: Purpose) -> NativeControllerExchangeGuard {
        NativeControllerExchangeGuard { _ in
            try validateCurrent(expected: expected, association: association, custody: custody, deadline: deadline, purpose: purpose)
        }
    }
    private static func validateCurrent(expected: NativeControllerAssociationSnapshot,
        association: NativeControllerPublicAssociation, custody: NativePairedKeychainCredential,
        deadline: ContinuousClock.Instant, purpose: Purpose) throws {
        try lifetime(deadline)
        try snapshots(expected, purpose: purpose)
        _ = try custody.credential(for: association)
        try snapshots(expected, purpose: purpose)
        try lifetime(deadline)
    }
    private static func snapshots(_ expected: NativeControllerAssociationSnapshot, purpose: Purpose) throws {
        do { try NativeControllerAssociationStorage.check(expected) }
        catch { throw NativePairedSessionError.selectionChanged }
        if case .original(_, _, let pending) = purpose {
            do { try NativePendingStorage.check(pending) }
            catch { throw NativePairedSessionError.originalChanged }
        }
    }
    private static func lifetime(_ deadline: ContinuousClock.Instant) throws {
        guard ContinuousClock.now < deadline else { throw NativePairedSessionError.expired }
    }
    private static func reduced(_ error: any Error) -> NativePairedSessionError {
        if let error = error as? NativePairedSessionError { return error }
        if let error = error as? NativePairedKeychainError { return .custody(error) }
        if let error = error as? NativeSetupPeerError, case .expired = error { return .expired }
        return .custody(.denied)
    }
}

// One actual private original purpose, with no generic mutation/credential
// interface. Only the production factory and exact cancellation continuation
// can create one. Public metadata cannot initialize this value.
struct NativePairedControllerRecovery: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private let session: NativePairedControllerSession
    let entry: NativePendingEntry
    let action: NativePendingRecoveryAction
    let pending: NativePendingSnapshot
    var association: NativeControllerPublicAssociation { session.association }
    var scope: HomeControllerScope { session.scope }
    var description: String { "private_original_paired_controller_recovery" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
    fileprivate init(session: NativePairedControllerSession, entry: NativePendingEntry,
                     action: NativePendingRecoveryAction, pending: NativePendingSnapshot) {
        self.session = session; self.entry = entry; self.action = action; self.pending = pending
    }
    func current() async throws { try await session.currentOriginal(entry, action: action, pending: pending) }
    func perform() async throws -> NativePendingRecoveryOutcome {
        try await session.performOriginal(entry, action: action, pending: pending)
    }
    func continuingCancellation(pending next: NativePendingSnapshot) async throws -> Self {
        let (continued, updated) = try await session.continuingCancellation(entry, action: action, pending: pending, next: next)
        return Self(session: continued, entry: updated, action: action, pending: next)
    }
    // No caller-supplied receipt or publisher: only this actual sealed purpose
    // can perform its closed runner and confirm the matching fixed-file result.
    func performAndPublish() async throws -> NativePairedRecoveryPublication {
        var current = self
        if action == .cancelReview, case .review = entry.phase {
            let next = try await session.publishingCancellation(entry, action: action, pending: pending)
            current = try await continuingCancellation(pending: next)
        }
        let outcome = try await current.perform()
        let (next, updated) = try await current.session.publishing(current.entry, action: action, pending: current.pending, outcome: outcome)
        let publication = NativePairedRecoveryPublication(entry: updated, pending: next, outcome: outcome,
            deadline: current.session.ownerDeadline)
        try publication.deliveryCurrent()
        return publication
    }
}

struct NativePairedRecoveryPublication: Sendable, CustomReflectable {
    let entry: NativePendingEntry
    let pending: NativePendingSnapshot
    let outcome: NativePendingRecoveryOutcome
    private let deadline: ContinuousClock.Instant
    var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
    fileprivate init(entry: NativePendingEntry, pending: NativePendingSnapshot, outcome: NativePendingRecoveryOutcome,
                     deadline: ContinuousClock.Instant) {
        self.entry = entry; self.pending = pending; self.outcome = outcome; self.deadline = deadline
    }
    // Repeat the original lifetime after hopping to the presentation actor.
    // The caller consumes this value synchronously before changing memory/UI.
    func deliveryCurrent() throws {
        guard !Task.isCancelled, ContinuousClock.now < deadline else { throw NativePendingError.outcomeUnknown }
    }
}

private struct PairedSessionMaterial: Sendable, CustomReflectable {
    let custody: NativePairedKeychainCredential
    let bearer: Data
    var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
}

// Late platform completion cannot return a credential to an expired/cancelled
// owner. Only private material or a reduced closed refusal occupies this slot.
private final class PairedSessionMaterialSlot: @unchecked Sendable, CustomReflectable {
    private let lock = NSLock()
    private let deadline: ContinuousClock.Instant
    private var material: PairedSessionMaterial?
    private var refusal: NativePairedSessionError?
    private var stopped = false
    init(deadline: ContinuousClock.Instant) { self.deadline = deadline }
    var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
    func publish(_ value: PairedSessionMaterial) throws {
        lock.lock(); defer { lock.unlock() }
        guard !stopped, ContinuousClock.now < deadline, material == nil, refusal == nil else {
            throw NativePairedSessionError.expired
        }
        material = value
    }
    func reject(_ error: NativePairedSessionError) {
        lock.lock(); defer { lock.unlock() }
        guard !stopped, ContinuousClock.now < deadline, material == nil, refusal == nil else { return }
        refusal = error
    }
    func failure() -> NativePairedSessionError? {
        lock.lock(); defer { lock.unlock() }
        return stopped ? nil : refusal
    }
    func take() throws -> PairedSessionMaterial {
        lock.lock(); defer { lock.unlock() }
        guard !stopped, ContinuousClock.now < deadline, let value = material else { throw NativePairedSessionError.expired }
        material = nil; stopped = true
        return value
    }
    func stop() {
        lock.lock(); defer { lock.unlock() }
        stopped = true; material = nil; refusal = nil
    }
}
