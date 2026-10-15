import Foundation

// Read metadata only: it cannot construct a signing/custody/session seal.
struct NativePairedPowerReceiptRead: Sendable, CustomReflectable {
    let entry: NativePendingEntry
    let result: HomeReceiptLookup
    let deadline: ContinuousClock.Instant
    var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
    func deliveryCurrent() throws {
        guard !Task.isCancelled, ContinuousClock.now < deadline else { throw NativePairedSessionError.expired }
    }
}

enum NativePairedPowerReceiptCorrespondence {
    static func checkEntry(_ entry: NativePendingEntry) throws {
        guard entry.custody.isPaired, entry.category == .power, entry.phase == .pending else { throw NativePendingError.conflict }
        switch entry.input { case .power, .cancel: break; default: throw NativePendingError.conflict }
        _ = try NativePendingDocument(revision: 1, entries: [entry]).encoded()
    }
    static func association(_ entry: NativePendingEntry, associations: NativeControllerAssociationSnapshot) throws -> NativeControllerPublicAssociation {
        try checkEntry(entry)
        guard case .paired(let id, _, _, _) = entry.custody,
              let association = associations.document.records.first(where: { $0.id == id }),
              entry.custody.matches(association: association, context: entry.context) else { throw NativePendingError.conflict }
        return association
    }
    static func scope(_ scope: HomeControllerScope, entry: NativePendingEntry, association: NativeControllerPublicAssociation) throws {
        try checkEntry(entry)
        try NativePairedSessionCorrespondence.check(scope, association: association)
        guard entry.custody.matches(association: association, context: entry.context),
              entry.context.matches(scope.identity), scope.permissions.contains("read") else {
            throw NativePairedSessionError.scopeConflict
        }
    }
    static func result(_ result: HomeReceiptLookup, entry: NativePendingEntry, association: NativeControllerPublicAssociation,
                       before: HomeControllerScope, after: HomeControllerScope) throws {
        try scope(before, entry: entry, association: association); try scope(after, entry: entry, association: association)
        guard before.identity.matchesAuthority(after.identity), after.identity.revision >= before.identity.revision,
              after.permissions == before.permissions, after.targetIDs == before.targetIDs else { throw NativePairedSessionError.scopeConflict }
        if case .found(let receipt) = result {
            guard Int64(receipt.authorityEpoch) == entry.context.epoch, receipt.operationID == entry.input.operationID,
                  receipt.revision >= 0, receipt.revision <= after.identity.revision else { throw LocalHealthError.invalidResponse }
        }
    }
    // Fixed raw transport seam for independent TLS fixtures; no session seal.
    static func read(_ entry: NativePendingEntry, association: NativeControllerPublicAssociation,
                     scope: HomeControllerScope, credential: Data) throws -> HomeReceiptLookup {
        try self.scope(scope, entry: entry, association: association)
        guard let transport = NativeDomainTransportScope.current, entry.custody.matches(credential) else { throw NativePendingError.unavailable }
        let checked = PairedOriginalReplyTransport(base: transport, principal: entry.context.principal)
        return try NativeDomainTransportScope.$current.withValue(checked) {
            let result = try LocalHealthClient.fetchReceiptStatus(socketPath: "", credential: credential,
                authorityEpoch: Int(entry.context.epoch), operationID: entry.input.operationID)
            let after = try LocalHealthClient.fetchControllerScope(socketPath: "", credential: credential)
            try self.result(result, entry: entry, association: association, before: scope, after: after)
            return result
        }
    }
}

// Public candidate/transition comparison only. Actual selected custody is
// required to publish and transfer into an original-purpose consumer.
enum NativePairedCaptureCorrespondence {
    static func entry(input: NativePendingInput, scope: HomeControllerScope,
                      association: NativeControllerPublicAssociation, pending: NativePendingSnapshot) throws -> NativePendingEntry {
        try NativePairedSessionCorrespondence.check(scope, association: association)
        let identity = scope.identity
        let context = NativePendingContext(deployment: identity.deploymentID, owner: identity.ownerID,
            epoch: Int64(identity.authorityEpoch), principal: identity.principalID)
        guard pending.document.entries.count < 16 else { throw NativePendingError.capacity }
        guard input.category != .access, !pending.document.entries.contains(where: {
            $0.context.deployment == context.deployment && $0.context.owner == context.owner && $0.context.epoch == context.epoch
        }) else { throw NativePendingError.conflict }
        let entry = NativePendingEntry(context: context, custody: try .paired(from: association), input: input, phase: .pending)
        guard NativePendingRecoveryAction.retry.permits(entry) else { throw NativePendingError.unavailable }
        try NativePairedSessionCorrespondence.checkProfileScope(scope, entry: entry)
        _ = try NativePendingDocument(revision: 1, entries: [entry]).encoded()
        return entry
    }
    static func publication(of entry: NativePendingEntry, before: NativePendingSnapshot, after: NativePendingSnapshot) throws {
        guard entry.custody.isPaired, entry.category != .access, entry.phase == .pending,
              before.document.revision < Int64.max,
              after.document.version == NativePendingVersion.requiring(before.document.entries + [entry], keeping: before.document.version),
              after.document.revision == before.document.revision + 1,
              !before.document.entries.contains(where: {
                $0.context.deployment == entry.context.deployment && $0.context.owner == entry.context.owner && $0.context.epoch == entry.context.epoch
              }),
              after.document.entries == NativePendingDocument.sorted(before.document.entries + [entry]) else { throw NativePendingError.conflict }
        _ = try after.document.encoded()
    }
}

// Public metadata correspondence only, never a credential or session seal.
enum NativePairedRecoveryCorrespondence {
    static func association(for entry: NativePendingEntry, action: NativePendingRecoveryAction,
                            pending: NativePendingSnapshot,
                            associations: NativeControllerAssociationSnapshot) throws -> NativeControllerPublicAssociation {
        guard entry.custody.isPaired, entry.category != .access, action.permits(entry),
              pending.document.entries.contains(entry),
              case .paired(let id, _, _, _) = entry.custody,
              let association = associations.document.records.first(where: { $0.id == id }),
              entry.custody.matches(association: association, context: entry.context) else {
            throw NativePendingError.conflict
        }
        _ = try NativePendingDocument(revision: 1, entries: [entry]).encoded()
        if entry.category == .authoring || entry.category == .generation || entry.category == .externalProfile {
            guard association.access.permissions.contains("profile:manage") else { throw NativePairedSessionError.scopeConflict }
            if case .externalProfile(let original) = entry.input, original.kind == .target {
                guard association.access.permissions.contains("enroll:review") else { throw NativePairedSessionError.scopeConflict }
            }
        }
        return association
    }

    static func cancellation(of entry: NativePendingEntry, action: NativePendingRecoveryAction,
                             before: NativePendingSnapshot, after: NativePendingSnapshot) throws -> NativePendingEntry {
        guard action == .cancelReview, entry.custody.isPaired, before.document.entries.contains(entry),
              case .review(let token, let digest) = entry.phase,
              before.document.version.supportsPaired, after.document.version == before.document.version,
              before.document.revision > 0, before.document.revision < Int64.max,
              after.document.revision == before.document.revision + 1 else { throw NativePendingError.conflict }
        let next = try entry.changingPhase(.cancelPending(token: token, digest: digest))
        guard after.document.entries == before.document.entries.map({ $0 == entry ? next : $0 }) else {
            throw NativePendingError.conflict
        }
        _ = try after.document.encoded()
        return next
    }

    static func publication(of entry: NativePendingEntry, outcome: NativePendingRecoveryOutcome,
                            before: NativePendingSnapshot, after: NativePendingSnapshot) throws -> NativePendingEntry {
        guard entry.custody.isPaired, entry.category != .access, before.document.entries.contains(entry),
              before.document.version.supportsPaired, after.document.version == before.document.version else { throw NativePendingError.conflict }
        let updated: NativePendingEntry, entries: [NativePendingEntry]
        switch outcome {
        case .retained:
            guard after == before else { throw NativePendingError.conflict }
            return entry
        case .review(let token, let digest):
            let phase = NativePendingPhase.review(token: token, digest: digest)
            guard NativePendingStorage.permitsTransition(from: entry.phase, to: phase) else { throw NativePendingError.conflict }
            updated = try entry.changingPhase(phase)
            entries = before.document.entries.map { $0 == entry ? updated : $0 }
        case .resolved:
            updated = entry; entries = before.document.entries.filter { $0 != entry }
        }
        if entries == before.document.entries {
            guard after == before else { throw NativePendingError.conflict }
        } else {
            guard before.document.revision > 0, before.document.revision < Int64.max,
                  after.document.revision == before.document.revision + 1,
                  after.document.entries == NativePendingDocument.sorted(entries) else { throw NativePendingError.conflict }
        }
        _ = try after.document.encoded()
        return updated
    }
}
