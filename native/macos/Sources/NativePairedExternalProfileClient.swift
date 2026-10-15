import Foundation

// Metadata-only paired preparation. It cannot construct an actual signed session.
struct NativePairedExternalPreparation: Sendable, CustomReflectable {
    let original: HomeExternalProfileOriginal, identity: HomeControllerIdentity
    let paired: NativePairedAuthoringBasis
    let draft: NativeExternalProfileDraft?
    var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
}
enum NativePairedExternalProfileClient {
    private static func scoped<Value>(_ basis: NativePairedAuthoringBasis, credential: Data, enrollment: Bool,
                                      _ operation: () throws -> Value) throws -> Value {
        guard credential.count == 32, basis.association.verifier == LocalHealthClient.profileSHA(credential),
              let transport = NativeDomainTransportScope.current else { throw NativePendingError.unavailable }
        try NativePairedSessionCorrespondence.check(basis.scope, association: basis.association)
        try NativePairedSessionCorrespondence.checkProfileScope(basis.scope, context: basis.context)
        guard !enrollment || basis.scope.permissions.contains("enroll:review") else { throw NativePairedSessionError.scopeConflict }
        let guarded = try NativePairedProfileTransport.guarding(transport, association: basis.association, credential: credential,
            context: basis.context, originalScope: basis.scope, requiresEnrollment: enrollment)
        return try NativeDomainTransportScope.$current.withValue(guarded, operation: operation)
    }
    static func catalogue(_ basis: NativePairedAuthoringBasis, credential: Data) throws -> HomeExternalProfileCatalogue {
        try scoped(basis, credential: credential, enrollment: false) { try NativeExternalProfileClient.catalogue(socketPath: "", credential: credential) }
    }
    static func original(_ basis: NativePairedAuthoringBasis, credential: Data, kind: HomeExternalProfileOriginalKind,
                         epoch: Int64, operation: String) throws -> HomeExternalProfileOriginalRead? {
        guard epoch > 0, LocalHealthClient.profileID(operation) else { throw LocalHealthError.invalidProfileRequest }
        return try scoped(basis, credential: credential, enrollment: kind == .target) {
            try NativeExternalProfileClient.original(socketPath: "", credential: credential, kind: kind, epoch: epoch, operation: operation)
        }
    }
    static func sources(_ basis: NativePairedAuthoringBasis, credential: Data) throws -> HomeExternalSourceCatalogue {
        try scoped(basis, credential: credential, enrollment: true) {
            try NativeExternalGuidedWorkflow.sourceChoices(socket: "", credential: credential) { try identity($0, basis: basis) }
        }
    }
    static func prepare(_ basis: NativePairedAuthoringBasis, credential: Data, draft: NativeExternalProfileDraft) throws -> NativePairedExternalPreparation {
        try draft.validate()
        return try scoped(basis, credential: credential, enrollment: draft.kind == .target) {
            let value = try NativeExternalGuidedWorkflow.prepare(draft, socket: "", credential: credential) { try identity($0, basis: basis) }
            return NativePairedExternalPreparation(original: value.original, identity: value.identity, paired: basis, draft: draft)
        }
    }
    static func prepare(_ basis: NativePairedAuthoringBasis, credential: Data, kind: HomeExternalProfileOriginalKind,
                        original: () throws -> HomeExternalProfileOriginal) throws -> NativePairedExternalPreparation {
        try scoped(basis, credential: credential, enrollment: kind == .target) {
            let value = try original()
            guard value.kind == kind else { throw LocalHealthError.invalidProfileRequest }
            let current = try NativeExternalGuidedWorkflow.complete(value, socket: "", credential: credential) { try identity($0, basis: basis) }
            return NativePairedExternalPreparation(original: value, identity: current, paired: basis, draft: nil)
        }
    }
    static func validate(_ original: HomeExternalProfileOriginal, draft: NativeExternalProfileDraft?,
                         reviewed: NativePairedAuthoringBasis, identity expected: HomeControllerIdentity,
                         fresh: NativePairedAuthoringBasis, credential: Data) throws {
        try reviewed.check(fresh.scope, association: fresh.association, identity: expected)
        let value: NativePairedExternalPreparation
        if let draft { value = try prepare(fresh, credential: credential, draft: draft) }
        else { value = try prepare(fresh, credential: credential, kind: original.kind) { original } }
        guard value.original == original, value.identity.matchesAuthority(expected), value.identity.revision == expected.revision else { throw LocalHealthError.nativeGuardConflict }
    }
    private static func identity(_ current: HomeControllerIdentity, basis: NativePairedAuthoringBasis) throws {
        guard basis.context.matches(current), current.revision >= basis.scope.identity.revision else { throw NativePairedSessionError.scopeConflict }
    }
}
