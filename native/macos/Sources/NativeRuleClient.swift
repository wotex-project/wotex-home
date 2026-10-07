import Foundation

struct HomeExplicitRulePreview: Sendable {
    let rule: HomeExplicitPowerRule
    let decision: String, reason: String, ruleDigest: String, registryDigest: String
    let revision: Int64
    let hasProposalBasis: Bool
}

struct HomeRecordedRuleReview: Sendable {
    let revision: Int64, artifactDigest: String, decision: String, reason: String
}

enum HomeExplicitRuleReceipt: Sendable {
    case review(HomeRecordedRuleReview), admission(HomeRuleAdmission), activation(HomeRuleActivation), invocation(HomeReceipt), notFound
}

struct HomeExplicitRuleResult: Sendable {
    let original: HomeExplicitRuleOperation
    let principal: String
    let receipt: HomeExplicitRuleReceipt
    fileprivate init(original: HomeExplicitRuleOperation, principal: String, receipt: HomeExplicitRuleReceipt) {
        self.original = original; self.principal = principal; self.receipt = receipt
    }
    func verify(original: HomeExplicitRuleOperation, principal: String) throws {
        guard self.original == original, self.principal == principal else { throw LocalHealthError.invalidResponse }
    }
}

enum NativeRuleClient {
    static func preview(socketPath: String, credential: Data, rule: HomeExplicitPowerRule) throws -> HomeExplicitRulePreview {
        let response = try LocalHealthClient.ruleTransport(socketPath: socketPath, credential: credential, operation: "review_rules", fields: ["rules": [rule.source()]])
        guard Set(response.keys) == Set(["api_version", "outcome", "review"]), let review = response["review"] as? [String: Any],
              Set(review.keys) == Set(["decision", "reason", "profile", "rule_digest", "registry_digest", "proposal_basis", "watermark"]),
              review["profile"] as? String == "home-draft-review-v1", let decision = decision(review["decision"]),
              let reason = reason(review["reason"]), let ruleDigest = digest(review["rule_digest"]), let registry = digest(review["registry_digest"]),
              let revision = integer(review["watermark"]), revision >= 0 else { throw LocalHealthError.invalidResponse }
        let proposal: Bool
        if review["proposal_basis"] is NSNull { proposal = false }
        else {
            guard decision == "pending_positive_basis", let basis = review["proposal_basis"] as? [String: Any],
                  Set(basis.keys) == Set(["profile", "scope", "target_id", "rule_digest", "registry_digest", "runtime_digest", "compiler_profile", "source_digest", "ir_digest", "obligations"]),
                  basis["profile"] as? String == "explicit-boolean-light-v3", basis["scope"] as? String == "proposal_generation_only",
                  basis["target_id"] as? String == rule.target, basis["compiler_profile"] as? String == "home-rule-ir-v1",
                  let obligations = basis["obligations"] as? [String], obligations == ["closed_rule", "closed_source_bound_ir", "compiler_correspondence", "ordinary_light_power", "single_explicit_trigger", "literal_predicate", "one_writer", "no_feedback", "one_effect_per_root", "runtime_correspondence", "pure_gate_precedence", "blocked_root_preservation"],
                  ["rule_digest", "registry_digest", "runtime_digest", "source_digest", "ir_digest"].allSatisfy({ digest(basis[$0]) != nil }) else { throw LocalHealthError.invalidResponse }
            proposal = true
        }
        return HomeExplicitRulePreview(rule: rule, decision: decision, reason: reason, ruleDigest: ruleDigest, registryDigest: registry, revision: revision, hasProposalBasis: proposal)
    }

    static func deliver(socketPath: String, credential: Data, original: HomeExplicitRuleOperation,
                        principal: String, lookup: Bool) throws -> HomeExplicitRuleResult {
        let record = try NativeRuleOperationWire.record(original)
        guard NativeRuleOperationWire.identifier(principal) else { throw LocalHealthError.invalidRuleRequest }
        let response: [String: Any]
        if lookup {
            response = try LocalHealthClient.ruleTransport(socketPath: socketPath, credential: credential,
                operation: "rule_original_status", fields: ["original": record], allowNotFound: true)
            if response["outcome"] as? String == "not_found" {
                return HomeExplicitRuleResult(original: original, principal: principal, receipt: .notFound)
            }
            guard Set(response.keys) == Set(["api_version", "outcome", "rule_original"]),
                  let result = response["rule_original"] as? [String: Any], Set(result.keys) == Set(["kind", "input_digest", "result"]),
                  result["kind"] as? String == original.kind, result["input_digest"] as? String == (try NativeRuleOperationWire.digest(original)),
                  let item = result["result"] as? [String: Any] else { throw LocalHealthError.invalidResponse }
            return try decode(item, original: original, principal: principal, status: true)
        }
        var fields: [String: Any] = ["authority_epoch": original.epoch, "operation_id": original.operationID]
        let operation: String, key: String
        switch original {
        case .review(_, _, let expected, let rule): operation = "record_rule_review"; key = "rule_review_receipt"; fields["expected_revision"] = expected; fields["rules"] = [try rule.source()]
        case .admit(_, _, let expected, let rule): operation = "admit_rule"; key = "rule_receipt"; fields["expected_revision"] = expected; fields["rules"] = [try rule.source()]
        case .activate(_, _, let expected, let admission): operation = "activate_rule"; key = "rule_receipt"; fields["expected_revision"] = expected; fields["admission_revision"] = admission
        case .invoke(_, _, let generation, let rule): operation = "invoke_rule"; key = "receipt"; fields["rule_generation"] = generation; fields["rule_id"] = rule
        }
        response = try LocalHealthClient.ruleTransport(socketPath: socketPath, credential: credential, operation: operation, fields: fields)
        guard Set(response.keys) == Set(["api_version", "outcome", key]), let item = response[key] as? [String: Any] else { throw LocalHealthError.invalidResponse }
        return try decode(item, original: original, principal: principal, status: false)
    }

    private static func decode(_ item: [String: Any], original: HomeExplicitRuleOperation, principal: String, status: Bool) throws -> HomeExplicitRuleResult {
        func identity() -> Bool { item["principal_id"] as? String == principal && integer(item["authority_epoch"]) == original.epoch && item["operation_id"] as? String == original.operationID }
        let result: HomeExplicitRuleReceipt
        switch original {
        case .review(_, _, let expected, _):
            guard Set(item.keys) == Set(["principal_id", "authority_epoch", "operation_id", "expected_revision", "revision", "artifact_digest", "decision", "reason", "profile", "rule_digest", "registry_digest", "checker_receipt_digest", "proposal_basis_digest"]), identity(),
                  integer(item["expected_revision"]) == expected, integer(item["revision"]) == expected + 1,
                  let artifact = digest(item["artifact_digest"]), let decision = decision(item["decision"]), let reason = reason(item["reason"]),
                  item["profile"] as? String == "home-draft-review-v1", digest(item["rule_digest"]) != nil, digest(item["registry_digest"]) != nil,
                  ["checker_receipt_digest", "proposal_basis_digest"].allSatisfy({ item[$0] is NSNull || digest(item[$0]) != nil }) else { throw LocalHealthError.invalidResponse }
            result = .review(HomeRecordedRuleReview(revision: expected + 1, artifactDigest: artifact, decision: decision, reason: reason))
        case .admit(_, _, let expected, _):
            var keys: Set<String> = ["principal_id", "authority_epoch", "operation_id", "revision", "artifact_digest", "profile", "state"]
            if status { keys.insert("kind") }
            guard Set(item.keys) == keys, !status || item["kind"] as? String == "admission", identity(), integer(item["revision"]) == expected + 1,
                  let artifact = digest(item["artifact_digest"]), item["profile"] as? String == "home-explicit-light-admission-v1", item["state"] as? String == "admitted" else { throw LocalHealthError.invalidResponse }
            result = .admission(HomeRuleAdmission(operationID: original.operationID, revision: Int(expected + 1), artifactDigest: artifact))
        case .activate(_, _, let expected, let admission):
            var keys: Set<String> = ["admission_revision", "previous_generation", "rule_generation", "revision", "store_revision", "affected_requests", "unknown_outcomes", "state"]
            if status { keys.insert("kind") }
            guard Set(item.keys) == keys, !status || item["kind"] as? String == "activation", integer(item["admission_revision"]) == admission,
                  integer(item["revision"]) == expected + 1, let previous = integer(item["previous_generation"]), previous >= 0, previous < Int64.max,
                  let generation = integer(item["rule_generation"]), generation == previous + 1,
                  let final = integer(item["store_revision"]), let affected = integer(item["affected_requests"]), (0...1024).contains(affected),
                  let unknown = integer(item["unknown_outcomes"]), (0...affected).contains(unknown), final >= expected + 1, final - (expected + 1) == affected,
                  item["state"] as? String == (admission == 0 ? "inactive" : "active") else { throw LocalHealthError.invalidResponse }
            result = .activation(HomeRuleActivation(admissionRevision: Int(admission), generation: Int(generation), revision: Int(expected + 1), storeRevision: Int(final), affectedRequests: Int(affected), unknownOutcomes: Int(unknown)))
        case .invoke:
            guard Set(item.keys) == Set(["principal_id", "authority_epoch", "operation_id", "disposition", "reason", "revision"]), identity(),
                  let disposition = item["disposition"] as? String, ["held", "rejected", "queued", "claimed", "dispatching", "protocol_accepted", "observed", "contradicted", "failed", "outcome_unknown"].contains(disposition),
                  let revision = integer(item["revision"]), revision > 0, item["reason"] is NSNull || reason(item["reason"]) != nil else { throw LocalHealthError.invalidResponse }
            result = .invocation(HomeReceipt(authorityEpoch: Int(original.epoch), operationID: original.operationID, disposition: disposition, reason: item["reason"] as? String, revision: Int(revision)))
        }
        return HomeExplicitRuleResult(original: original, principal: principal, receipt: result)
    }
    private static func integer(_ value: Any?) -> Int64? { LocalHealthClient.profileInteger(value).map(Int64.init) }
    private static func digest(_ value: Any?) -> String? {
        guard let value = value as? String, value.utf8.count == 64, value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }; return value
    }
    private static func decision(_ value: Any?) -> String? {
        guard let value = value as? String, ["rejected", "pending_positive_basis", "pending_composed_proof"].contains(value) else { return nil }; return value
    }
    private static func reason(_ value: Any?) -> String? {
        guard let value = value as? String, NativeRuleOperationWire.identifier(value) else { return nil }; return value
    }
}
