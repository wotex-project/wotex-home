import Foundation
// Pure metadata correspondence, never a selected-session constructor.
enum NativePairedPowerCorrespondence {
    static func permits(_ thing: HomeThing, scope: HomeControllerScope, things: [HomeThing]) -> Bool {
        scope.permissions.contains("read") && scope.permissions.contains("control:ordinary") &&
            scope.targetIDs.contains(thing.id) && thing.role == "Light" && thing.powerWritable &&
            things.contains { $0.id == thing.id && $0.resourceRevision == thing.resourceRevision &&
                $0.profileRef == thing.profileRef && $0.role == thing.role && $0.powerWritable }
    }
    static func check(_ current: HomeControllerScope, original: HomeControllerScope,
                      thing: HomeThing, things: [HomeThing]) throws {
        guard current.identity.matchesAuthority(original.identity), current.identity.revision >= original.identity.revision,
              current.permissions == original.permissions, current.targetIDs == original.targetIDs,
              permits(thing, scope: current, things: things) else { throw NativePairedSessionError.scopeConflict }
    }
}


enum NativePairedSessionError: Error, Sendable {
    case invalidSelection, selectionChanged, originalChanged, scopeConflict, expired
    case custody(NativePairedKeychainError)
}

// Pure refusal/correspondence only. A decoded scope cannot create a session.
enum NativePairedSessionCorrespondence {
    static func checkProfileScope(_ scope: HomeControllerScope, entry: NativePendingEntry) throws {
        guard entry.category == .authoring || entry.category == .generation else { return }
        try checkProfileScope(scope, context: entry.context)
    }
    static func checkProfileScope(_ scope: HomeControllerScope, context: NativePendingContext) throws {
        guard context.matches(scope.identity), scope.permissions.contains("profile:manage") else { throw NativePairedSessionError.scopeConflict }
    }
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
        case generationOriginal(entry: NativePendingEntry, action: NativePendingRecoveryAction,
                                pending: NativePendingSnapshot, workspace: NativeGenerationWorkspaceSnapshot)
        var generationWitness: NativeGenerationWorkspaceSnapshot? {
            if case .generationOriginal(_, _, _, let workspace) = self { return workspace }; return nil
        }
        func matches(_ entry: NativePendingEntry, action: NativePendingRecoveryAction, pending: NativePendingSnapshot) -> Bool {
            switch self {
            case .original(let fixed, let fixedAction, let fixedPending), .generationOriginal(let fixed, let fixedAction, let fixedPending, _):
                return fixed == entry && fixedAction == action && fixedPending == pending
            default: return false
            }
        }
        func continuing(_ entry: NativePendingEntry, action: NativePendingRecoveryAction, pending: NativePendingSnapshot) throws -> Self {
            switch self {
            case .original(let fixed, let fixedAction, _):
                guard fixed.context == entry.context, fixed.custody == entry.custody, fixed.input == entry.input, fixedAction == action else { throw NativePendingError.conflict }
                return .original(entry: entry, action: action, pending: pending)
            case .generationOriginal(let fixed, let fixedAction, _, let workspace):
                guard fixed == entry, fixedAction == action else { throw NativePendingError.conflict }
                return .generationOriginal(entry: entry, action: action, pending: pending, workspace: workspace)
            default: throw NativePendingError.conflict
            }
        }
        case workspace(entry: NativeGenerationWorkspaceEntry, action: NativePairedWorkspaceAction,
                       workspace: NativeGenerationWorkspaceSnapshot, pending: NativePendingSnapshot)
    }
    let association: NativeControllerPublicAssociation
    let scope: HomeControllerScope
    private let snapshot: NativeControllerAssociationSnapshot
    private let custody: NativePairedKeychainCredential
    private let bearer: Data
    private let deadline: ContinuousClock.Instant
    private let clock: @Sendable () throws -> NativeControllerCertificateClock
    private let purpose: Purpose
    private let scopeRevisions: NativePairedScopeRevision
    fileprivate var ownerDeadline: ContinuousClock.Instant { deadline }
    // Public timing metadata for final view delivery; it carries no credential
    // or authority and cannot renew this selected session.
    var viewDeliveryDeadline: ContinuousClock.Instant { deadline }
    var description: String { "private_paired_controller_session" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }

    private init(association: NativeControllerPublicAssociation, scope: HomeControllerScope,
                 snapshot: NativeControllerAssociationSnapshot, material: PairedSessionMaterial,
                 deadline: ContinuousClock.Instant, purpose: Purpose,
                 clock: @escaping @Sendable () throws -> NativeControllerCertificateClock,
                 revisions: NativePairedScopeRevision? = nil) {
        self.association = association; self.scope = scope; self.snapshot = snapshot
        custody = material.custody; bearer = material.bearer; self.deadline = deadline; self.clock = clock; self.purpose = purpose
        scopeRevisions = revisions ?? NativePairedScopeRevision(initial: scope.identity.revision)
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
                           workspace: NativeGenerationWorkspaceSnapshot? = nil,
                           clock: @escaping @Sendable () throws -> NativeControllerCertificateClock) async throws -> NativePairedControllerRecovery {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        guard !Task.isCancelled else { throw NativeControllerTLSError.cancelled }
        let association = try NativePairedRecoveryCorrespondence.association(for: entry, action: action,
            pending: pending, associations: associations)
        let purpose: Purpose
        if entry.category == .generation && action == .retry {
            guard let workspace else { throw NativePendingError.conflict }
            try NativePairedGenerationOriginalCorrespondence.check(entry, workspace: workspace)
            purpose = .generationOriginal(entry: entry, action: action, pending: pending, workspace: workspace)
        } else { purpose = .original(entry: entry, action: action, pending: pending) }
        let session = try await acquire(association: association, expected: associations,
            purpose: purpose, deadline: deadline, clock: clock)
        return NativePairedControllerRecovery(session: session, entry: entry, action: action, pending: pending)
    }

    static func generationWorkspace(_ entry: NativeGenerationWorkspaceEntry, action: NativePairedWorkspaceAction,
                                    workspace: NativeGenerationWorkspaceSnapshot, pending: NativePendingSnapshot,
                                    associations: NativeControllerAssociationSnapshot,
                                    clock: @escaping @Sendable () throws -> NativeControllerCertificateClock) async throws -> NativePairedGenerationWorkspaceSession {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        guard !Task.isCancelled else { throw NativeControllerTLSError.cancelled }
        let association = try NativePairedWorkspaceCorrespondence.association(entry, action: action,
            workspace: workspace, pending: pending, associations: associations)
        let session = try await acquire(association: association, expected: associations,
            purpose: .workspace(entry: entry, action: action, workspace: workspace, pending: pending), deadline: deadline, clock: clock)
        return NativePairedGenerationWorkspaceSession(session: session, entry: entry, action: action, workspace: workspace, pending: pending)
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
            switch purpose {
            case .original(let entry, _, _), .generationOriginal(let entry, _, _, _):
                try NativePairedSessionCorrespondence.checkProfileScope(scope, entry: entry)
            default: break
            }
            if case .workspace(let entry, _, _, _) = purpose {
                try NativePairedSessionCorrespondence.checkProfileScope(scope,
                    entry: NativePendingEntry(context: entry.context, custody: entry.custody, input: .generation(entry.preparation), phase: .pending))
            }
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
            clock: clock, exchangeGuard: exchangeGuard, deadline: deadline) { [bearer, scopeRevisions] in
                try NativePairedProfileTransport.$revisions.withValue(scopeRevisions) { try operation(bearer) }
            }
    }

    func current() async throws {
        guard purpose == .selected else { throw NativePendingError.unavailable }
        let exchangeGuard = Self.currentGuard(expected: snapshot, association: association,
            custody: custody, deadline: deadline, purpose: purpose)
        try await exchangeGuard.validate(.decoded, until: deadline)
        try deliveryCurrent()
    }
    func deliveryCurrent() throws {
        guard purpose == .selected, !Task.isCancelled else { throw NativePendingError.outcomeUnknown }
        try Self.lifetime(deadline)
    }

    func original(input: NativePendingInput, pending: NativePendingSnapshot) throws -> NativePendingEntry {
        guard purpose == .selected else { throw NativePendingError.unavailable }
        guard !Task.isCancelled else { throw NativePendingError.outcomeUnknown }
        try Self.lifetime(deadline)
        return try NativePairedCaptureCorrespondence.entry(input: input, scope: scope, association: association, pending: pending)
    }

    func capturing(_ entry: NativePendingEntry, pending: NativePendingSnapshot) async throws -> NativePairedControllerRecovery {
        guard entry.category != .generation else { throw NativePendingError.conflict }
        return try await capturingOriginal(entry, pending: pending, workspace: nil)
    }

    func publishingGenerationWorkspace(_ entry: NativeGenerationWorkspaceEntry, previous: NativeGenerationWorkspaceEntry?,
                                       workspace: NativeGenerationWorkspaceSnapshot) async throws -> NativePairedGenerationWorkspaceCapture {
        guard purpose == .selected, entry.custody.matches(association: association, context: entry.context),
              entry.context.matches(scope.identity), !entry.cancellationPending else { throw NativePendingError.conflict }
        let original = entry.attempts.last ?? entry.preparation
        if let previous {
            guard entry == (try previous.appending(original)), workspace.document.entries.contains(previous) else { throw NativePendingError.conflict }
        } else { guard entry.attempts.isEmpty else { throw NativePendingError.conflict } }
        let pending = try self.original(input: .generation(original), pending: .empty)
        try await profileScope(pending, purpose: purpose)
        let next = try await NativePendingPublicationOwner.performValue(until: deadline) { [self] in
            try Self.validateCurrent(expected: snapshot, association: association, custody: custody, deadline: deadline, purpose: purpose)
            try NativeGenerationWorkspaceStorage.check(workspace)
            guard let directory = try NativePrivateDocuments.directory(create: true) else { throw NativePendingError.unavailable }
            let next: NativeGenerationWorkspaceSnapshot
            if let previous { next = try NativeGenerationWorkspaceStorage.replacing(previous, with: entry, directory: directory, expected: workspace) }
            else { next = try NativeGenerationWorkspaceStorage.retaining(entry, directory: directory, expected: workspace) }
            try Self.validateCurrent(expected: snapshot, association: association, custody: custody, deadline: deadline, purpose: purpose)
            try NativeGenerationWorkspaceStorage.check(next)
            return next
        }
        try await profileScope(pending, purpose: purpose)
        try NativeGenerationWorkspaceStorage.check(next)
        let result = NativePairedGenerationWorkspaceCapture(entry: entry, workspace: next, deadline: deadline)
        try result.deliveryCurrent(); return result
    }
    func capturingGeneration(_ entry: NativePendingEntry, pending: NativePendingSnapshot,
                             workspace: NativeGenerationWorkspaceSnapshot) async throws -> NativePairedControllerRecovery {
        guard entry.category == .generation else { throw NativePendingError.conflict }
        try NativePairedGenerationOriginalCorrespondence.check(entry, workspace: workspace)
        return try await capturingOriginal(entry, pending: pending, workspace: workspace)
    }
    private func capturingOriginal(_ entry: NativePendingEntry, pending: NativePendingSnapshot,
                                   workspace: NativeGenerationWorkspaceSnapshot?) async throws -> NativePairedControllerRecovery {
        guard entry == (try original(input: entry.input, pending: pending)) else { throw NativePendingError.conflict }
        try await profileScope(entry, purpose: purpose)
        let next = try await NativePendingPublicationOwner.perform(until: deadline) { [self] in
            try Self.validateCurrent(expected: snapshot, association: association, custody: custody, deadline: deadline, purpose: purpose)
            if let workspace { try NativeGenerationWorkspaceStorage.check(workspace) }
            try NativePendingStorage.check(pending)
            let next = try NativePendingStorage.retaining(entry, expected: pending)
            try NativePairedCaptureCorrespondence.publication(of: entry, before: pending, after: next)
            let continued: Purpose = workspace.map { .generationOriginal(entry: entry, action: .retry, pending: next, workspace: $0) }
                ?? .original(entry: entry, action: .retry, pending: next)
            try Self.validateCurrent(expected: snapshot, association: association, custody: custody, deadline: deadline, purpose: continued)
            return next
        }
        let continued: Purpose = workspace.map { .generationOriginal(entry: entry, action: .retry, pending: next, workspace: $0) }
            ?? .original(entry: entry, action: .retry, pending: next)
        try await profileScope(entry, purpose: continued)
        try await Self.currentGuard(expected: snapshot, association: association, custody: custody,
            deadline: deadline, purpose: continued).validate(.decoded, until: deadline)
        guard !Task.isCancelled else { throw NativePendingError.outcomeUnknown }
        try Self.lifetime(deadline)
        let session = Self(association: association, scope: scope, snapshot: snapshot,
            material: PairedSessionMaterial(custody: custody, bearer: bearer), deadline: deadline, purpose: continued, clock: clock, revisions: scopeRevisions)
        let result = NativePairedControllerRecovery(session: session, entry: entry, action: .retry, pending: next)
        try result.deliveryCurrent()
        return result
    }

    fileprivate func currentOriginal(_ entry: NativePendingEntry, action: NativePendingRecoveryAction,
                                     pending: NativePendingSnapshot) async throws {
        guard purpose.matches(entry, action: action, pending: pending) else { throw NativePendingError.conflict }
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
        let workspace = purpose.generationWitness
        return try await NativeControllerDomainClient.perform(association.peer, credential: bearer,
            clock: clock, exchangeGuard: exchangeGuard, deadline: deadline) { [association, bearer, scopeRevisions] in
            try NativePairedProfileTransport.$revisions.withValue(scopeRevisions) {
                try NativePendingRecoveryOperations.executePaired(entry, association: association, credential: bearer, action: action, workspace: workspace)
            }
        }
    }

    fileprivate func performAuthoring(_ entry: NativePendingEntry, action: NativePendingRecoveryAction,
                                     pending: NativePendingSnapshot) async throws -> NativeAuthoringRecoveryResult {
        guard entry.category == .authoring else { throw NativePendingError.conflict }
        try await currentOriginal(entry, action: action, pending: pending)
        let exchangeGuard = Self.currentGuard(expected: snapshot, association: association, custody: custody, deadline: deadline, purpose: purpose)
        return try await NativeControllerDomainClient.perform(association.peer, credential: bearer, clock: clock,
            exchangeGuard: exchangeGuard, deadline: deadline) { [association, bearer, scopeRevisions] in
            try NativePairedProfileTransport.$revisions.withValue(scopeRevisions) {
                try NativePendingRecoveryOperations.executePairedAuthoring(entry, association: association, credential: bearer, action: action)
            }
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
            material: PairedSessionMaterial(custody: custody, bearer: bearer), deadline: deadline, purpose: continued, clock: clock, revisions: scopeRevisions)
        return (result, updated)
    }

    fileprivate func publishing(_ entry: NativePendingEntry, action: NativePendingRecoveryAction,
                                 pending: NativePendingSnapshot, outcome: NativePendingRecoveryOutcome) async throws -> (NativePendingSnapshot, NativePendingEntry) {
        guard purpose.matches(entry, action: action, pending: pending) else { throw NativePendingError.conflict }
        try await profileScope(entry, purpose: purpose)
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
                deadline: deadline, purpose: purpose.continuing(updated, action: action, pending: next))
            return next
        }
        let updated = try NativePairedRecoveryCorrespondence.publication(of: entry, outcome: outcome, before: pending, after: next)
        try await profileScope(updated, purpose: purpose.continuing(updated, action: action, pending: next))
        guard !Task.isCancelled else { throw NativePendingError.outcomeUnknown }
        try await Self.currentGuard(expected: snapshot, association: association, custody: custody,
            deadline: deadline, purpose: purpose.continuing(updated, action: action, pending: next)).validate(.decoded, until: deadline)
        guard !Task.isCancelled else { throw NativePendingError.outcomeUnknown }
        try Self.lifetime(deadline)
        return (next, updated)
    }

    // Reuse this actual seal and deadline around private publication; fetching
    // current grants must never acquire another session after a possible send.
    private func profileScope(_ entry: NativePendingEntry, purpose checkedPurpose: Purpose) async throws {
        guard entry.category == .authoring || entry.category == .generation else { return }
        let exchangeGuard = Self.currentGuard(expected: snapshot, association: association,
            custody: custody, deadline: deadline, purpose: checkedPurpose)
        let live = try await NativeControllerDomainClient.perform(association.peer, credential: bearer,
            clock: clock, exchangeGuard: exchangeGuard, deadline: deadline) { [bearer] in
            try LocalHealthClient.fetchControllerScope(socketPath: "", credential: bearer)
        }
        try NativePairedSessionCorrespondence.check(live, association: association)
        try NativePairedSessionCorrespondence.checkProfileScope(live, entry: entry)
        try scopeRevisions.check(live.identity.revision)
        guard live.permissions == scope.permissions, live.targetIDs == scope.targetIDs,
              live.identity.revision >= scope.identity.revision else { throw NativePairedSessionError.scopeConflict }
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

    fileprivate func performWorkspace(_ entry: NativeGenerationWorkspaceEntry, action: NativePairedWorkspaceAction,
                                      workspace: NativeGenerationWorkspaceSnapshot, pending: NativePendingSnapshot) async throws -> NativePairedWorkspacePublication {
        guard purpose == .workspace(entry: entry, action: action, workspace: workspace, pending: pending) else { throw NativePendingError.conflict }
        try await workspaceScope(entry, purpose: purpose)
        let read = try await workspaceDomain {
            try NativePairedGenerationWorkspaceOperations.read(entry, association: association, credential: bearer)
        }
        var current = self, retained = entry, nextWorkspace = workspace, nextPending = pending
        var assessment: NativePairedGeneratedAssessment?, finalRead = read, archived = false
        switch action {
        case .status: break
        case .lookupCancellation:
            if read.root?.state == "cancelled" {
                let updated = try entry.cancellation(false)
                (current, nextWorkspace) = try await workspaceWrite(entry, replacement: updated, action: action, workspace: workspace, pending: pending)
                retained = updated
            }
        case .cancel:
            guard read.root != nil else { throw NativePendingError.conflict }
            if !entry.cancellationPending {
                let updated = try entry.cancellation(true)
                (current, nextWorkspace) = try await workspaceWrite(entry, replacement: updated, action: action, workspace: workspace, pending: pending)
                retained = updated
            }
            let checkedEntry = retained
            let result = try await current.workspaceDomain {
                try NativePairedGenerationWorkspaceOperations.cancel(checkedEntry, association: association, credential: bearer)
            }
            finalRead = try await current.workspaceDomain {
                try NativePairedGenerationWorkspaceOperations.read(checkedEntry, association: association, credential: bearer)
            }
            if result?.state == "cancelled" {
                let updated = try retained.cancellation(false)
                (current, nextWorkspace) = try await current.workspaceWrite(retained, replacement: updated, action: action, workspace: nextWorkspace, pending: pending)
                retained = updated
            }
        case .restorePending:
            guard !entry.cancellationPending, read.root != nil || entry.attempts.isEmpty,
                  !pending.document.entries.contains(where: { NativePairedWorkspaceCorrespondence.sameOwner($0.context, entry.context) }) else { throw NativePendingError.conflict }
            let original = try NativePairedWorkspaceCorrespondence.restoredOriginal(entry)
            try await workspaceScope(entry, purpose: purpose)
            nextPending = try await NativePendingPublicationOwner.perform(until: deadline) { [self] in
                try Self.validateCurrent(expected: snapshot, association: association, custody: custody, deadline: deadline, purpose: purpose)
                let next = try NativePendingStorage.retaining(original, expected: pending)
                try NativePairedCaptureCorrespondence.publication(of: original, before: pending, after: next)
                return next
            }
            current = workspaceContinuation(entry, action: action, workspace: workspace, pending: nextPending)
        case .assessDraft(let operation, let instruction):
            assessment = try await workspaceDomain {
                try NativePairedGenerationWorkspaceOperations.assess(entry, association: association, credential: bearer, operation: operation, instruction: instruction)
            }
        case .archive(let acceptUncertainty):
            try NativePairedWorkspaceCorrespondence.permitsArchive(entry, read: read, acceptUncertainty: acceptUncertainty)
            (current, nextWorkspace) = try await workspaceWrite(entry, replacement: nil, action: action, workspace: workspace, pending: pending)
            archived = true
        }
        try await current.workspaceScope(retained, purpose: current.purpose)
        let result = NativePairedWorkspacePublication(entry: retained, workspace: nextWorkspace, pending: nextPending,
            read: finalRead, assessment: assessment, archived: archived, association: association, scope: scope, deadline: deadline)
        try result.deliveryCurrent(); return result
    }

    private func workspaceScope(_ entry: NativeGenerationWorkspaceEntry, purpose: Purpose) async throws {
        try await profileScope(NativePendingEntry(context: entry.context, custody: entry.custody, input: .generation(entry.preparation), phase: .pending), purpose: purpose)
        try await Self.currentGuard(expected: snapshot, association: association, custody: custody, deadline: deadline, purpose: purpose).validate(.decoded, until: deadline)
    }
    private func workspaceDomain<Value: Sendable>(_ operation: @escaping @Sendable () throws -> Value) async throws -> Value {
        guard case .workspace = purpose else { throw NativePendingError.unavailable }
        return try await NativeControllerDomainClient.perform(association.peer, credential: bearer, clock: clock,
            exchangeGuard: Self.currentGuard(expected: snapshot, association: association, custody: custody, deadline: deadline, purpose: purpose),
            deadline: deadline) { [scopeRevisions] in
                try NativePairedProfileTransport.$revisions.withValue(scopeRevisions, operation: operation)
            }
    }
    private func workspaceContinuation(_ entry: NativeGenerationWorkspaceEntry, action: NativePairedWorkspaceAction,
                                       workspace: NativeGenerationWorkspaceSnapshot, pending: NativePendingSnapshot) -> Self {
        Self(association: association, scope: scope, snapshot: snapshot, material: PairedSessionMaterial(custody: custody, bearer: bearer),
            deadline: deadline, purpose: .workspace(entry: entry, action: action, workspace: workspace, pending: pending), clock: clock, revisions: scopeRevisions)
    }
    private func workspaceWrite(_ entry: NativeGenerationWorkspaceEntry, replacement: NativeGenerationWorkspaceEntry?,
                                action: NativePairedWorkspaceAction, workspace: NativeGenerationWorkspaceSnapshot,
                                pending: NativePendingSnapshot) async throws -> (Self, NativeGenerationWorkspaceSnapshot) {
        try await workspaceScope(entry, purpose: purpose)
        let next = try await NativePendingPublicationOwner.performValue(until: deadline) { [self] in
            try Self.validateCurrent(expected: snapshot, association: association, custody: custody, deadline: deadline, purpose: purpose)
            guard let directory = try NativePrivateDocuments.directory(create: false) else { throw NativePendingError.unavailable }
            let next: NativeGenerationWorkspaceSnapshot
            if let replacement { next = try NativeGenerationWorkspaceStorage.replacing(entry, with: replacement, directory: directory, expected: workspace) }
            else { next = try NativeGenerationWorkspaceStorage.removing(entry, directory: directory, expected: workspace) }
            try NativePairedWorkspaceCorrespondence.publication(entry, replacement: replacement, before: workspace, after: next)
            return next
        }
        let continued = workspaceContinuation(replacement ?? entry, action: action, workspace: next, pending: pending)
        try await continued.workspaceScope(replacement ?? entry, purpose: continued.purpose)
        return (continued, next)
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
        if case .generationOriginal(_, _, let pending, let workspace) = purpose {
            do { try NativeGenerationWorkspaceStorage.check(workspace); try NativePendingStorage.check(pending) }
            catch { throw NativePairedSessionError.originalChanged }
        }
        if case .workspace(_, _, let workspace, let pending) = purpose {
            do { try NativeGenerationWorkspaceStorage.check(workspace); try NativePendingStorage.check(pending) }
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

struct NativePairedGenerationWorkspaceSession: Sendable, CustomReflectable {
    private let session: NativePairedControllerSession
    let entry: NativeGenerationWorkspaceEntry, action: NativePairedWorkspaceAction
    let workspace: NativeGenerationWorkspaceSnapshot, pending: NativePendingSnapshot
    var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
    fileprivate init(session: NativePairedControllerSession, entry: NativeGenerationWorkspaceEntry, action: NativePairedWorkspaceAction,
                     workspace: NativeGenerationWorkspaceSnapshot, pending: NativePendingSnapshot) {
        self.session = session; self.entry = entry; self.action = action; self.workspace = workspace; self.pending = pending
    }
    func perform() async throws -> NativePairedWorkspacePublication {
        try await session.performWorkspace(entry, action: action, workspace: workspace, pending: pending)
    }
}
struct NativePairedGenerationWorkspaceCapture: Sendable, CustomReflectable {
    let entry: NativeGenerationWorkspaceEntry, workspace: NativeGenerationWorkspaceSnapshot
    private let deadline: ContinuousClock.Instant
    var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
    fileprivate init(entry: NativeGenerationWorkspaceEntry, workspace: NativeGenerationWorkspaceSnapshot, deadline: ContinuousClock.Instant) {
        self.entry = entry; self.workspace = workspace; self.deadline = deadline
    }
    func deliveryCurrent() throws {
        guard !Task.isCancelled, ContinuousClock.now < deadline else { throw NativePendingError.outcomeUnknown }
    }
}

struct NativePairedWorkspacePublication: Sendable, CustomReflectable {
    let entry: NativeGenerationWorkspaceEntry, workspace: NativeGenerationWorkspaceSnapshot, pending: NativePendingSnapshot
    let read: NativePairedWorkspaceRead, assessment: NativePairedGeneratedAssessment?, archived: Bool
    let association: NativeControllerPublicAssociation, scope: HomeControllerScope
    private let deadline: ContinuousClock.Instant
    var viewDeliveryDeadline: ContinuousClock.Instant { deadline }
    var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
    fileprivate init(entry: NativeGenerationWorkspaceEntry, workspace: NativeGenerationWorkspaceSnapshot, pending: NativePendingSnapshot,
                     read: NativePairedWorkspaceRead, assessment: NativePairedGeneratedAssessment?, archived: Bool,
                     association: NativeControllerPublicAssociation, scope: HomeControllerScope, deadline: ContinuousClock.Instant) {
        self.entry = entry; self.workspace = workspace; self.pending = pending; self.read = read; self.assessment = assessment
        self.archived = archived; self.association = association; self.scope = scope; self.deadline = deadline
    }
    func deliveryCurrent() throws {
        guard !Task.isCancelled, ContinuousClock.now < deadline else { throw NativePendingError.outcomeUnknown }
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
    func deliveryCurrent() throws {
        guard !Task.isCancelled, ContinuousClock.now < session.ownerDeadline else { throw NativePendingError.outcomeUnknown }
    }
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
        let outcome: NativePendingRecoveryOutcome, authoringReceipt: HomeAuthoringOriginalRead?
        if entry.category == .authoring {
            let result = try await current.session.performAuthoring(current.entry, action: action, pending: current.pending)
            outcome = result.outcome; authoringReceipt = result.receipt
        } else { outcome = try await current.perform(); authoringReceipt = nil }
        let (next, updated) = try await current.session.publishing(current.entry, action: action, pending: current.pending, outcome: outcome)
        let publication = NativePairedRecoveryPublication(entry: updated, pending: next, outcome: outcome,
            authoringReceipt: authoringReceipt, deadline: current.session.ownerDeadline)
        try publication.deliveryCurrent()
        return publication
    }
}

struct NativePairedRecoveryPublication: Sendable, CustomReflectable {
    let entry: NativePendingEntry
    let pending: NativePendingSnapshot
    let outcome: NativePendingRecoveryOutcome
    let authoringReceipt: HomeAuthoringOriginalRead?
    private let deadline: ContinuousClock.Instant
    var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
    fileprivate init(entry: NativePendingEntry, pending: NativePendingSnapshot, outcome: NativePendingRecoveryOutcome,
                     authoringReceipt: HomeAuthoringOriginalRead? = nil, deadline: ContinuousClock.Instant) {
        self.entry = entry; self.pending = pending; self.outcome = outcome; self.authoringReceipt = authoringReceipt; self.deadline = deadline
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
