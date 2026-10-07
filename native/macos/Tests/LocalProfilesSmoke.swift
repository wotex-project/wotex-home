import Foundation

@main
struct LocalProfilesSmoke {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else { exit(2) }
        let path = CommandLine.arguments[1]
        let mode = CommandLine.arguments[2]
        let credential = Data(repeating: 7, count: 32)
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { root.deleteLastPathComponent() }
        let bytes = try Data(contentsOf: root.appendingPathComponent("test/support/profiles/lifx-power.json"))
        let digest = LocalHealthClient.profileSHA(bytes)
        var fields: [String: Any] = ["action": "approve", "authority_epoch": 3, "operation_id": "profile:native", "expected_revision": 5, "artifact_digest": digest, "expected_trust_revision": 0]
        if mode.hasPrefix("prepare") || mode.hasPrefix("review") || mode.hasPrefix("select") {
            fields["action"] = "select"
            fields["expected_trust_revision"] = 4
            fields.merge(["target_id": "light:fixture", "expected_resource_revision": 0, "expected_binding_revision": 0, "expected_selection_generation": 0, "expected_policy_generation": 1, "expected_rule_generation": 1, "session_ref": "capture:native", "candidate_ref": "candidate:native", "review_ref": "review:native"]) { _, new in new }
        }
        if mode.hasPrefix("prepare-replacement") { fields["expected_binding_revision"] = 2 }
        let input = try HomeProfileOperation(fields)
        if mode == "invalid-input" {
            for value in [fields.merging(["principal_id": "caller:fake"]) { _, new in new }, fields.merging(["authority_epoch": true]) { _, new in new }, fields.merging(["expected_revision": 1.0]) { _, new in new }] {
                do { _ = try HomeProfileOperation(value); exit(1) } catch LocalHealthError.invalidProfileRequest {}
            }
            for raw in ["{\"key\":1,\"key\":2}", "{\"key\":1,\"k\\u0065y\":2}", String(repeating: "[", count: 17) + "0" + String(repeating: "]", count: 17)] {
                do { try StrictLocalJSON.check(Data(raw.utf8)); exit(1) } catch {}
            }
            try StrictLocalJSON.check(Data(#"{"key":"{[\\\"nested","other":{"key":2}}"#.utf8))
            do { _ = try LocalHealthClient.importProfile(socketPath: path, credential: credential, bytes: Data()); exit(1) } catch LocalHealthError.invalidProfileRequest {}
            do { _ = try LocalHealthClient.prepareProfile(socketPath: path, credential: credential, input: input); exit(1) } catch LocalHealthError.invalidProfileRequest {}
            return
        }
        do {
            if mode.hasPrefix("import") {
                let artifact = try LocalHealthClient.importProfile(socketPath: path, credential: credential, bytes: bytes)
                guard artifact.artifactDigest == digest else { exit(1) }
            } else if mode.hasPrefix("catalogue") {
                let catalogue = try LocalHealthClient.fetchProfiles(socketPath: path, credential: credential)
                guard catalogue.items.count == 1, catalogue.items[0].artifact.artifactDigest == digest else { exit(1) }
            } else if mode.hasPrefix("target") {
                let target = try LocalHealthClient.fetchProfileTarget(socketPath: path, credential: credential, targetID: "light:fixture")
                guard target.targetID == "light:fixture" else { exit(1) }
            } else if mode.hasPrefix("prepare") {
                let result = try LocalHealthClient.prepareProfile(socketPath: path, credential: credential, input: input)
                if mode == "prepare-committed" { guard case .committed(let receipt) = result, receipt.action == "select" else { exit(1) } }
                else { guard case .review(let review) = result, (review.prior != nil) == mode.hasPrefix("prepare-replacement"), review.captured.firmware == "1.22" else { exit(1) } }
            } else if mode.hasPrefix("review-status") {
                let result = try LocalHealthClient.fetchProfileReview(socketPath: path, credential: credential, token: "review-token:native", input: mode.contains("firmware") ? nil : input)
                if mode == "review-status-missing" { guard case .notFound = result else { exit(1) } }
                else { guard case .found(let review) = result, review.token == "review-token:native" else { exit(1) } }
            } else if mode.hasPrefix("review-cancel") {
                let cancelled = try LocalHealthClient.cancelProfileReview(socketPath: path, credential: credential, token: "review-token:native")
                guard cancelled == (mode != "review-cancel-missing") else { exit(1) }
            } else if mode.hasPrefix("operation") {
                let result = try LocalHealthClient.fetchProfileOperation(socketPath: path, credential: credential, authorityEpoch: 3, operationID: "profile:native", input: input)
                if mode == "operation-missing" { guard case .notFound = result else { exit(1) } }
                else { guard case .found(let receipt) = result, receipt.action == "approve" else { exit(1) } }
            } else if mode.hasPrefix("collect") {
                let result = try LocalHealthClient.collectProfiles(socketPath: path, credential: credential)
                guard result.removedObjects == 1 else { exit(1) }
            } else if mode.hasPrefix("change") || mode.hasPrefix("select") {
                if mode == "change-retry" {
                    do { _ = try LocalHealthClient.changeProfile(socketPath: path, credential: credential, input: input); exit(1) } catch LocalHealthError.transport {}
                    guard case .notFound = try LocalHealthClient.fetchProfileOperation(socketPath: path, credential: credential, authorityEpoch: 3, operationID: "profile:native", input: input) else { exit(1) }
                }
                let receipt = try LocalHealthClient.changeProfile(socketPath: path, credential: credential, input: input)
                guard receipt.inputDigest == input.inputDigest else { exit(1) }
            } else { exit(2) }
            if mode.contains("invalid") || mode.contains("rejected") || mode.contains("unknown") { exit(1) }
        } catch LocalHealthError.invalidResponse {
            guard mode.contains("invalid") else { throw LocalHealthError.invalidResponse }
        } catch LocalHealthError.server(let reason) {
            guard (mode.contains("rejected") && reason == "resnapshot_required") || (mode.contains("unknown") && reason == "outcome_unknown") else { throw LocalHealthError.server(reason) }
        }
    }
}
