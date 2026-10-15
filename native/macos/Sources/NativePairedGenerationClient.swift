import Foundation

// Public metadata cannot create an authenticated session or publication.
struct NativePairedGenerationContext: Sendable, CustomReflectable {
    let options: HomeGenerationOptions, contract: HomeAuthoringContractRead, identity: HomeControllerIdentity
    let paired: NativePairedAuthoringBasis
    var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
}
struct NativePairedGenerationAttempt: Sendable, CustomReflectable {
    let context: NativePairedGenerationContext, original: HomeGenerationOriginal
    let feedbackDraft: String?, feedbackAssessment: HomeGenerationAssessment?
    var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
}

// Fixed read-only preparation. No mutation, bearer or reusable lease is returned.
enum NativePairedGenerationClient {
    static func context(_ basis: NativePairedAuthoringBasis, credential: Data) throws -> NativePairedGenerationContext {
        try NativePairedAuthoringClient.scoped(basis, credential: credential) { try readContext(basis, credential) }
    }
    private static func readContext(_ basis: NativePairedAuthoringBasis, _ credential: Data) throws -> NativePairedGenerationContext {
        let before = try LocalHealthClient.fetchControllerIdentity(socketPath: "", credential: credential)
        let contract = try NativeAuthoringContractClient.fetch(socketPath: "", credential: credential)
        let options = try NativeGenerationClient.fetchOptions(socketPath: "", credential: credential)
        let after = try LocalHealthClient.fetchControllerIdentity(socketPath: "", credential: credential)
        guard basis.context.matches(before), before.revision >= basis.scope.identity.revision,
              after.matchesAuthority(before), after.revision == before.revision,
              contract.epoch == after.authorityEpoch, contract.principal == after.principalID, contract.revision == after.revision,
              options.epoch == after.authorityEpoch, options.principal == after.principalID, options.revision == after.revision else { throw LocalHealthError.nativeGuardConflict }
        return NativePairedGenerationContext(options: options, contract: contract, identity: after, paired: basis)
    }
    static func matches(_ entry: NativeGenerationWorkspaceEntry, basis: NativePairedAuthoringBasis) throws {
        _ = try entry.checked()
        guard entry.custody.isPaired, entry.custody.matches(association: basis.association, context: entry.context),
              entry.context == basis.context else { throw NativePendingError.unavailable }
    }
    static func attempt(_ basis: NativePairedAuthoringBasis, credential: Data, entry: NativeGenerationWorkspaceEntry,
                        operation: String, feedbackConsent: Bool) throws -> NativePairedGenerationAttempt {
        try matches(entry, basis: basis)
        guard !entry.cancellationPending else { throw NativePendingError.conflict }
        return try NativePairedAuthoringClient.scoped(basis, credential: credential) {
            let context = try readContext(basis, credential), fields = try entry.preparation.fields()
            let policies = try context.options.fields()["policies"] as! [[String: Any]]
            guard context.contract.basisSHA == entry.basisSHA,
                  let policy = policies.first(where: { $0["policy_sha256"] as? String == fields["policy_sha256"] as? String }),
                  policy["provider_sha256"] as? String == fields["provider_sha256"] as? String, policy["provider_present"] as? Bool == true,
                  let root = try NativeGenerationClient.status(socketPath: "", credential: credential, kind: .preparation,
                    epoch: entry.preparation.epoch, operation: entry.preparation.operation, original: entry.preparation), root.state == "prepared" else { throw LocalHealthError.server("generation_unavailable") }
            let previous = entry.attempts.last, index = entry.attempts.count + 1, budget = fields["budget"] as! [String: Any]
            guard index <= LocalHealthClient.profileInteger(budget["attempts"])! else { throw LocalHealthError.invalidProfileRequest }
            var feedbackDraft: String?, feedbackAssessment: HomeGenerationAssessment?
            if let previous {
                guard feedbackConsent, let status = try NativeGenerationClient.status(socketPath: "", credential: credential, kind: .attempt,
                    epoch: previous.epoch, operation: previous.operation, original: previous), status.state == "candidate",
                      let result = status.result, let assessment = result.assessment, assessment.disposition == "invalid" else { throw LocalHealthError.invalidProfileRequest }
                let draft = try result.fields()["draft_ref"] as! [String: Any]
                guard let object = try NativeAuthoringReadClient.fetchObject(socketPath: "", credential: credential, digest: draft["object_digest"] as! String),
                      object.summary.kind == "draft", object.firstRevision == Int64(LocalHealthClient.profileInteger(draft["first_revision"])!),
                      object.summary.payloadSHA == assessment.draftSHA, let text = String(data: object.payload, encoding: .utf8) else { throw LocalHealthError.invalidResponse }
                feedbackDraft = text; feedbackAssessment = assessment
            }
            let after = try LocalHealthClient.fetchControllerIdentity(socketPath: "", credential: credential)
            guard after.matchesAuthority(context.identity), after.revision == context.identity.revision else { throw LocalHealthError.nativeGuardConflict }
            let original = try NativeGenerationOriginalWire.encode(["authority_epoch": after.authorityEpoch, "expected_revision": after.revision,
                "operation_id": operation, "preparation_operation_id": entry.preparation.operation, "preparation_sha256": entry.preparation.sha,
                "attempt": index, "previous_operation_id": previous.map { $0.operation as Any } ?? NSNull(), "repair_export": previous != nil], kind: .attempt)
            _ = try entry.appending(original)
            return NativePairedGenerationAttempt(context: context, original: original, feedbackDraft: feedbackDraft, feedbackAssessment: feedbackAssessment)
        }
    }
    static func validate(_ reviewed: NativePairedGenerationContext, fresh: NativePairedAuthoringBasis, credential: Data,
                         original: HomeGenerationOriginal, previous: NativeGenerationWorkspaceEntry?) throws {
        try reviewed.paired.check(fresh.scope, association: fresh.association, identity: reviewed.identity)
        if let previous { try matches(previous, basis: fresh); _ = try previous.appending(original) }
        else { guard original.kind == .preparation else { throw LocalHealthError.invalidProfileRequest } }
        guard original.epoch == reviewed.identity.authorityEpoch, original.expectedRevision == reviewed.identity.revision else { throw LocalHealthError.nativeGuardConflict }
        let current = try context(fresh, credential: credential)
        guard current.identity == reviewed.identity, current.contract.basisSHA == reviewed.contract.basisSHA,
              current.options == reviewed.options else { throw LocalHealthError.nativeGuardConflict }
    }
}
