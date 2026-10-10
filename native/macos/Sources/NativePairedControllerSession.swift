import Foundation

enum NativePairedSessionError: Error, Sendable {
    case invalidSelection, selectionChanged, scopeConflict, expired
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
    let association: NativeControllerPublicAssociation
    let scope: HomeControllerScope
    private let snapshot: NativeControllerAssociationSnapshot
    private let custody: NativePairedKeychainCredential
    private let bearer: Data
    private let deadline: ContinuousClock.Instant
    private let clock: @Sendable () throws -> NativeControllerCertificateClock
    var description: String { "private_paired_controller_session" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }

    private init(association: NativeControllerPublicAssociation, scope: HomeControllerScope,
                 snapshot: NativeControllerAssociationSnapshot, material: PairedSessionMaterial,
                 deadline: ContinuousClock.Instant,
                 clock: @escaping @Sendable () throws -> NativeControllerCertificateClock) {
        self.association = association; self.scope = scope; self.snapshot = snapshot
        custody = material.custody; bearer = material.bearer; self.deadline = deadline; self.clock = clock
    }

    static func selected(expected: NativeControllerAssociationSnapshot,
                         clock: @escaping @Sendable () throws -> NativeControllerCertificateClock) async throws -> Self {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        guard !Task.isCancelled else { throw NativeControllerTLSError.cancelled }
        guard case .remote(let id) = expected.document.selection,
              let association = expected.document.records.first(where: { $0.id == id }) else {
            throw NativePairedSessionError.invalidSelection
        }
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
                    try selection(expected)
                    let custody = try NativePairedKeychainCustodian().existing(association: association, access: access)
                    let bearer = try custody.credential(for: association)
                    try selection(expected)
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
                custody: material.custody, deadline: deadline)
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
                material: material, deadline: deadline, clock: clock)
        } onCancel: { slot.stop() }
    }

    func perform<Value: Sendable>(_ operation: @escaping @Sendable (Data) throws -> Value) async throws -> Value {
        guard !Task.isCancelled else { throw NativeControllerTLSError.cancelled }
        let exchangeGuard = Self.currentGuard(expected: snapshot, association: association,
            custody: custody, deadline: deadline)
        try await exchangeGuard.validate(.opening, until: deadline)
        guard !Task.isCancelled else { throw NativeControllerTLSError.cancelled }
        try Self.lifetime(deadline)
        return try await NativeControllerDomainClient.perform(association.peer, credential: bearer,
            clock: clock, exchangeGuard: exchangeGuard, deadline: deadline) { [bearer] in try operation(bearer) }
    }

    private static func currentGuard(expected: NativeControllerAssociationSnapshot,
        association: NativeControllerPublicAssociation, custody: NativePairedKeychainCredential,
        deadline: ContinuousClock.Instant) -> NativeControllerExchangeGuard {
        NativeControllerExchangeGuard { _ in
            try lifetime(deadline)
            try selection(expected)
            _ = try custody.credential(for: association)
            try selection(expected)
            try lifetime(deadline)
        }
    }
    private static func selection(_ expected: NativeControllerAssociationSnapshot) throws {
        do { try NativeControllerAssociationStorage.check(expected) }
        catch { throw NativePairedSessionError.selectionChanged }
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
