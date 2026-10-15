import Foundation

enum NativeExternalProfileDeliveryError: LocalizedError {
    case outcomeUnknown
    var errorDescription: String? { "External profile delivery is unconfirmed. Look up the retained original before retrying." }
}

// Fixed complete-original consumer. Custody/publication and fresh human decisions
// belong to the caller; this client cannot capture or replace either identity.
enum NativeExternalProfileMutationClient {
    static func deliver(socketPath: String, credential: Data, original: HomeExternalProfileOriginal,
                        expectedController: HomeControllerIdentity, lookup: Bool) throws -> HomeExternalProfileOriginalRead? {
        let fields = try original.fields()
        guard credential.count == 32 else { throw LocalHealthError.invalidCredential }
        guard LocalHealthClient.profileDigest(expectedController.deploymentID), LocalHealthClient.profileDigest(expectedController.ownerID),
              expectedController.authorityEpoch > 0, expectedController.revision >= 0,
              LocalHealthClient.profileID(expectedController.principalID) else { throw LocalHealthError.invalidProfileRequest }
        let operation = original.kind == .inspection ? "external_profile_inspect" : "external_\(original.kind.rawValue)_change"
        let wrapper: [String: Any] = [original.kind == .inspection ? "inspection" : "change": fields]
        if !lookup { try LocalHealthClient.externalProfileMutationPreflight(credential: credential, operation: operation, fields: wrapper) }
        var possibleMutation = false
        var awaitingMutationReply = false
        do {
            let before = try NativeExternalProfileClient.identity(socketPath: socketPath, credential: credential)
            guard before.matchesAuthority(expectedController), before.revision >= expectedController.revision else { throw LocalHealthError.nativeGuardConflict }
            var result = try NativeExternalProfileClient.decodeOriginal(
                LocalHealthClient.externalProfileReadTransport(socketPath: socketPath, credential: credential, operation: original.kind.operation,
                    fields: ["authority_epoch": original.epoch, "operation_id": original.operation]),
                kind: original.kind, epoch: original.epoch, operation: original.operation, expectedInputSHA: original.sha)
            if let result { try verify(result, original: original) }
            if !lookup && result == nil {
                guard Int64(before.authorityEpoch) == original.epoch else { throw LocalHealthError.nativeGuardConflict }
                possibleMutation = true
                awaitingMutationReply = true
                result = try NativeExternalProfileClient.decodeOriginal(
                    LocalHealthClient.externalProfileMutationTransport(socketPath: socketPath, credential: credential, operation: operation, fields: wrapper),
                    kind: original.kind, epoch: original.epoch, operation: original.operation, expectedInputSHA: original.sha)
                awaitingMutationReply = false
                guard let result else { throw LocalHealthError.invalidResponse }
                try verify(result, original: original)
            }
            let after = try NativeExternalProfileClient.identity(socketPath: socketPath, credential: credential)
            guard after.matchesAuthority(before), after.revision >= before.revision,
                  Int64(after.revision) >= (result?.revision ?? 0) else { throw LocalHealthError.nativeGuardConflict }
            return result
        } catch LocalHealthError.server(let reason) {
            if possibleMutation && (!awaitingMutationReply || reason == "outcome_unknown") { throw NativeExternalProfileDeliveryError.outcomeUnknown }
            throw LocalHealthError.server(reason)
        } catch {
            if possibleMutation { throw NativeExternalProfileDeliveryError.outcomeUnknown }
            throw error
        }
    }

    static func verify(_ receipt: HomeExternalProfileOriginalRead, original: HomeExternalProfileOriginal) throws {
        let fields = try original.fields()
        guard receipt.kind == original.kind, receipt.epoch == original.epoch, receipt.operation == original.operation,
              receipt.inputSHA == original.sha, receipt.revision == (try increment(original.expectedRevision)) else { throw LocalHealthError.invalidResponse }
        switch (original.kind, receipt.detail) {
        case (.inspection, .inspection(let detail)):
            guard let inspection = fields["inspection"] as? [String: Any], detail.readerBasis == inspection["reader_basis_sha256"] as? String else { throw LocalHealthError.invalidResponse }
        case (.trust, .trust(let detail)):
            guard detail.action == fields["action"] as? String, detail.artifact == fields["artifact_digest"] as? String,
                  detail.previousRevision == (try integer(fields, "expected_trust_revision")),
                  detail.policyGeneration == (try increment(integer(fields, "expected_policy_generation"))) else { throw LocalHealthError.invalidResponse }
        case (.target, .target(let detail)):
            let previous = try integer(fields, "expected_selection_revision"), resource = try integer(fields, "expected_resource_revision")
            guard detail.action == fields["action"] as? String, detail.target == fields["target_id"] as? String,
                  detail.artifact == fields["artifact_digest"] as? String, detail.previousRevision == previous,
                  detail.trustRevision == (try integer(fields, "expected_trust_revision")),
                  detail.policyGeneration == (try integer(fields, "expected_policy_generation")) else { throw LocalHealthError.invalidResponse }
            if previous == 0 {
                guard resource == 0, detail.resourceRevision == 0 else { throw LocalHealthError.invalidResponse }
            } else { guard detail.resourceRevision == (try increment(resource)) else { throw LocalHealthError.invalidResponse } }
            if detail.action == "select" {
                guard detail.sourceSelection == fields["source_selection_sha256"] as? String, detail.bindingRevision == receipt.revision else { throw LocalHealthError.invalidResponse }
            }
        default: throw LocalHealthError.invalidResponse
        }
    }
    private static func integer(_ fields: [String: Any], _ key: String) throws -> Int64 {
        guard let value = LocalHealthClient.profileInteger(fields[key]), value >= 0 else { throw LocalHealthError.invalidResponse }; return Int64(value)
    }
    private static func increment(_ value: Int64) throws -> Int64 {
        guard value >= 0, value < Int64.max else { throw LocalHealthError.invalidResponse }; return value + 1
    }
}
