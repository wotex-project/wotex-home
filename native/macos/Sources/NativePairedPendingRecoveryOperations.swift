import Foundation

extension NativePendingRecoveryOperations {
    // A transport adapter, never a signed session constructor. The production
    // original-purpose session fixes this runner and its exact retained input.
    static func executePaired(_ entry: NativePendingEntry, association: NativeControllerPublicAssociation,
                              credential: Data, action: NativePendingRecoveryAction) throws -> NativePendingRecoveryOutcome {
        guard let transport = NativeDomainTransportScope.current else { throw NativePendingError.unavailable }
        guard entry.custody.isPaired, entry.category != .access, action.permits(entry),
              entry.custody.matches(association: association, context: entry.context),
              entry.custody.matches(credential),
              action != .cancelReview || entry.phase.isCancellation else { throw NativePendingError.invalidRecord }
        _ = try NativePendingDocument(revision: 1, entries: [entry]).encoded()
        let replies = PairedOriginalReplyTransport(base: transport, principal: entry.context.principal)
        let guarded: any NativeDomainTransport
        if entry.category == .authoring {
            guarded = try NativePairedProfileTransport.guarding(replies, association: association, credential: credential, entry: entry)
        } else { guarded = replies }
        return try NativeDomainTransportScope.$current.withValue(guarded) {
            try executeOrdinary(entry, credential: credential, socketPath: "", action: action,
                nativeAccess: { _, _ in throw NativePendingError.unavailable })
        }
    }
}

enum NativePairedProfileTransport {
    @TaskLocal static var revisions: NativePairedScopeRevision?
    static func guarding(_ base: any NativeDomainTransport, association: NativeControllerPublicAssociation,
                         credential: Data, entry: NativePendingEntry) throws -> any NativeDomainTransport {
        let scope = try NativeDomainTransportScope.$current.withValue(base) {
            try LocalHealthClient.fetchControllerScope(socketPath: "", credential: credential)
        }
        try NativePairedSessionCorrespondence.check(scope, association: association)
        try NativePairedSessionCorrespondence.checkProfileScope(scope, entry: entry)
        let revisions = revisions ?? NativePairedScopeRevision(initial: scope.identity.revision)
        try revisions.check(scope.identity.revision)
        return PairedProfileOriginalTransport(base: base, credential: credential, association: association, entry: entry,
            initial: scope, revisions: revisions)
    }
}

// Read live scope through the same finite TLS owner around every closed SDK
// exchange, including upload chunks and status. Store repeats its own grants.
private struct PairedProfileOriginalTransport: NativeDomainTransport, CustomReflectable {
    let base: any NativeDomainTransport
    let credential: Data
    let association: NativeControllerPublicAssociation
    let entry: NativePendingEntry
    let initial: HomeControllerScope
    let revisions: NativePairedScopeRevision
    var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }

    func request(body: Data, allowNotFound: Bool) throws -> Data {
        let before = try currentScope()
        let response = try base.request(body: body, allowNotFound: allowNotFound)
        let after = try currentScope()
        guard after.identity.revision >= before.identity.revision else { throw NativePairedSessionError.scopeConflict }
        return response
    }

    private func currentScope() throws -> HomeControllerScope {
        let scope = try NativeDomainTransportScope.$current.withValue(base) {
            try LocalHealthClient.fetchControllerScope(socketPath: "", credential: credential)
        }
        try NativePairedSessionCorrespondence.check(scope, association: association)
        try NativePairedSessionCorrespondence.checkProfileScope(scope, entry: entry)
        guard scope.permissions == initial.permissions, scope.targetIDs == initial.targetIDs,
              scope.identity.revision >= initial.identity.revision else { throw NativePairedSessionError.scopeConflict }
        try revisions.check(scope.identity.revision)
        return scope
    }
}

final class NativePairedScopeRevision: @unchecked Sendable {
    private let lock = NSLock()
    private var maximum: Int
    init(initial: Int) { maximum = initial }
    func check(_ revision: Int) throws {
        lock.lock(); defer { lock.unlock() }
        guard revision >= maximum else { throw NativePairedSessionError.scopeConflict }
        maximum = revision
    }
}

// The ordinary power DTO intentionally omits receipt principal. Check it before
// passing unchanged bytes to that existing decoder; no reply is normalized.
private struct PairedOriginalReplyTransport: NativeDomainTransport, CustomReflectable {
    let base: any NativeDomainTransport
    let principal: String
    var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
    func request(body: Data, allowNotFound: Bool) throws -> Data {
        let bytes = try base.request(body: body, allowNotFound: allowNotFound)
        guard let response = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            throw LocalHealthError.invalidResponse
        }
        if let receipt = response["receipt"] as? [String: Any] {
            guard receipt["principal_id"] as? String == principal else { throw LocalHealthError.invalidResponse }
        }
        return bytes
    }
}
