import Foundation

extension NativePendingRecoveryOperations {
    // A transport adapter, never a signed session constructor. The production
    // original-purpose session fixes this runner and its exact retained input.
    static func executePaired(_ entry: NativePendingEntry, association: NativeControllerPublicAssociation,
                              credential: Data, action: NativePendingRecoveryAction,
                              workspace: NativeGenerationWorkspaceSnapshot? = nil) throws -> NativePendingRecoveryOutcome {
        if entry.category == .externalProfile {
            return try executePairedExternal(entry, association: association, credential: credential, action: action).outcome
        }
        if entry.category == .authoring {
            return try executePairedAuthoring(entry, association: association, credential: credential, action: action).outcome
        }
        guard let transport = NativeDomainTransportScope.current else { throw NativePendingError.unavailable }
        guard entry.custody.isPaired, entry.category != .access, action.permits(entry),
              entry.custody.matches(association: association, context: entry.context),
              entry.custody.matches(credential),
              action != .cancelReview || entry.phase.isCancellation else { throw NativePendingError.invalidRecord }
        _ = try NativePendingDocument(revision: 1, entries: [entry]).encoded()
        if entry.category == .generation && action == .retry {
            guard let workspace else { throw NativePendingError.conflict }
            try NativePairedGenerationOriginalCorrespondence.check(entry, workspace: workspace)
        }
        let replies = PairedOriginalReplyTransport(base: transport, principal: entry.context.principal)
        let guarded: any NativeDomainTransport
        if entry.category == .authoring || entry.category == .generation {
            guarded = try NativePairedProfileTransport.guarding(replies, association: association, credential: credential, entry: entry)
        } else { guarded = replies }
        return try NativeDomainTransportScope.$current.withValue(guarded) {
            try executeOrdinary(entry, credential: credential, socketPath: "", action: action,
                nativeAccess: { _, _ in throw NativePendingError.unavailable })
        }
    }
    static func executePairedExternal(_ entry: NativePendingEntry, association: NativeControllerPublicAssociation,
                                     credential: Data, action: NativePendingRecoveryAction) throws -> NativeExternalProfileRecoveryResult {
        guard let transport = NativeDomainTransportScope.current else { throw NativePendingError.unavailable }
        guard entry.category == .externalProfile, entry.custody.isPaired, action.permits(entry),
              entry.custody.matches(association: association, context: entry.context), entry.custody.matches(credential) else { throw NativePendingError.invalidRecord }
        _ = try NativePendingDocument(revision: 1, entries: [entry]).encoded()
        let guarded = try NativePairedProfileTransport.guarding(transport, association: association, credential: credential, entry: entry)
        return try NativeDomainTransportScope.$current.withValue(guarded) {
            try external(entry, credential: credential, socketPath: "", action: action)
        }
    }
    static func executePairedAuthoring(_ entry: NativePendingEntry, association: NativeControllerPublicAssociation,
                                      credential: Data, action: NativePendingRecoveryAction) throws -> NativeAuthoringRecoveryResult {
        guard let transport = NativeDomainTransportScope.current else { throw NativePendingError.unavailable }
        guard entry.category == .authoring, entry.custody.isPaired, action.permits(entry),
              entry.custody.matches(association: association, context: entry.context), entry.custody.matches(credential) else { throw NativePendingError.invalidRecord }
        _ = try NativePendingDocument(revision: 1, entries: [entry]).encoded()
        let guarded = try NativePairedProfileTransport.guarding(transport, association: association, credential: credential, entry: entry)
        return try NativeDomainTransportScope.$current.withValue(guarded) {
            try authoring(entry, credential: credential, socketPath: "", action: action, verifyLookup: true)
        }
    }
}

enum NativePairedProfileTransport {
    @TaskLocal static var revisions: NativePairedScopeRevision?
    static func guarding(_ base: any NativeDomainTransport, association: NativeControllerPublicAssociation,
                         credential: Data, entry: NativePendingEntry) throws -> any NativeDomainTransport {
        guard entry.category == .authoring || entry.category == .generation || entry.category == .externalProfile else { throw NativePendingError.invalidRecord }
        return try guarding(base, association: association, credential: credential, context: entry.context,
            requiresEnrollment: entry.category == .externalProfile && entry.externalProfileOperation().kind == .target)
    }
    static func guarding(_ base: any NativeDomainTransport, association: NativeControllerPublicAssociation,
                         credential: Data, context: NativePendingContext, originalScope: HomeControllerScope? = nil, requiresEnrollment: Bool = false) throws -> any NativeDomainTransport {
        let scope = try NativeDomainTransportScope.$current.withValue(base) {
            try LocalHealthClient.fetchControllerScope(socketPath: "", credential: credential)
        }
        try NativePairedSessionCorrespondence.check(scope, association: association)
        try NativePairedSessionCorrespondence.checkProfileScope(scope, context: context)
        guard !requiresEnrollment || scope.permissions.contains("enroll:review") else { throw NativePairedSessionError.scopeConflict }
        if let originalScope {
            guard scope.identity.matchesAuthority(originalScope.identity), scope.identity.revision >= originalScope.identity.revision,
                  scope.permissions == originalScope.permissions, scope.targetIDs == originalScope.targetIDs else { throw NativePairedSessionError.scopeConflict }
        }
        let revisions = revisions ?? NativePairedScopeRevision(initial: scope.identity.revision)
        try revisions.check(scope.identity.revision)
        return PairedProfileOriginalTransport(base: base, credential: credential, association: association, context: context,
            initial: scope, revisions: revisions, requiresEnrollment: requiresEnrollment)
    }
}

// Read live scope through the same finite TLS owner around every closed SDK
// exchange, including upload chunks and status. Store repeats its own grants.
private struct PairedProfileOriginalTransport: NativeDomainTransport, CustomReflectable {
    let base: any NativeDomainTransport
    let credential: Data
    let association: NativeControllerPublicAssociation
    let context: NativePendingContext
    let initial: HomeControllerScope
    let revisions: NativePairedScopeRevision
    let requiresEnrollment: Bool
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
        try NativePairedSessionCorrespondence.checkProfileScope(scope, context: context)
        guard !requiresEnrollment || scope.permissions.contains("enroll:review") else { throw NativePairedSessionError.scopeConflict }
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
