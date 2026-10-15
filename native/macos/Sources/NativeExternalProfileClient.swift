import Foundation

protocol NativeExternalProfileMetadata: CustomReflectable {}
extension NativeExternalProfileMetadata {
    var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
}

struct HomeExternalProfileItem: Sendable, NativeExternalProfileMetadata {
    let artifact: String, id: String, version: String, author: String, state: String, readerBasis: String?
    let trustRevision: Int64, trustGeneration: Int64
}
struct HomeExternalProfileCatalogue: Sendable, CustomReflectable {
    let epoch: Int64, revision: Int64, policyGeneration: Int64
    let items: [HomeExternalProfileItem]
    var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
}
enum HomeExternalProfileOriginalKind: String, CaseIterable, Sendable {
    case inspection, trust, target
    var operation: String { "external_\(rawValue)_status" }
    var member: String { "external_\(rawValue)_receipt" }
}
struct HomeExternalInspectionDetail: Sendable, NativeExternalProfileMetadata {
    let readerBasis: String, resultSHA: String, capture: String, envelope: String
}
struct HomeExternalTrustDetail: Sendable, NativeExternalProfileMetadata {
    let action: String, artifact: String, outcomeSHA: String, readerBasis: String?
    let previousRevision: Int64, generation: Int64, policyGeneration: Int64, firstApprovalRevision: Int64
}
struct HomeExternalTargetDetail: Sendable, NativeExternalProfileMetadata {
    let action: String, target: String, artifact: String, sourceSelection: String, outcomeSHA: String
    let previousRevision: Int64, generation: Int64, resourceRevision: Int64, bindingRevision: Int64
    let trustRevision: Int64, policyGeneration: Int64, withdrawnGrants: Int64
}
enum HomeExternalProfileReceiptDetail: Sendable, NativeExternalProfileMetadata {
    case inspection(HomeExternalInspectionDetail), trust(HomeExternalTrustDetail), target(HomeExternalTargetDetail)
}
struct HomeExternalProfileOriginalRead: Sendable, CustomReflectable {
    let kind: HomeExternalProfileOriginalKind, epoch: Int64, operation: String, revision: Int64, inputSHA: String
    let detail: HomeExternalProfileReceiptDetail
    var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
}

// Fixed authenticated metadata reads. This client owns no capture, mutation or custody.
enum NativeExternalProfileClient {
    static func catalogue(socketPath: String, credential: Data) throws -> HomeExternalProfileCatalogue {
        guard credential.count == 32 else { throw LocalHealthError.invalidProfileRequest }
        let before = try identity(socketPath: socketPath, credential: credential)
        let value = try decodeCatalogue(LocalHealthClient.externalProfileReadTransport(socketPath: socketPath, credential: credential,
            operation: "external_profiles", fields: [:]))
        let after = try identity(socketPath: socketPath, credential: credential)
        guard after.matchesAuthority(before), after.revision == before.revision,
              value.epoch == after.authorityEpoch, value.revision == after.revision else { throw LocalHealthError.nativeGuardConflict }
        return value
    }
    static func original(socketPath: String, credential: Data, kind: HomeExternalProfileOriginalKind,
                         epoch: Int64, operation: String, expectedInputSHA: String? = nil) throws -> HomeExternalProfileOriginalRead? {
        guard credential.count == 32, epoch > 0, LocalHealthClient.profileID(operation),
              expectedInputSHA == nil || LocalHealthClient.profileDigest(expectedInputSHA!) else { throw LocalHealthError.invalidProfileRequest }
        let before = try identity(socketPath: socketPath, credential: credential)
        let result = try decodeOriginal(LocalHealthClient.externalProfileReadTransport(socketPath: socketPath, credential: credential,
            operation: kind.operation, fields: ["authority_epoch": epoch, "operation_id": operation]), kind: kind, epoch: epoch,
            operation: operation, expectedInputSHA: expectedInputSHA)
        let after = try identity(socketPath: socketPath, credential: credential)
        guard after.matchesAuthority(before), after.revision >= before.revision,
              Int64(after.revision) >= (result?.revision ?? 0) else { throw LocalHealthError.nativeGuardConflict }
        return result
    }
    static func decodeCatalogue(_ response: [String: Any]) throws -> HomeExternalProfileCatalogue {
        guard keys(response, "api_version outcome external_profile_catalogue"), integer(response["api_version"]) == 1,
              response["outcome"] as? String == "ok", let raw = response["external_profile_catalogue"] as? [String: Any],
              keys(raw, "authority_epoch store_revision policy_generation items"), let epoch = positive(raw["authority_epoch"]),
              let revision = integer(raw["store_revision"]), revision >= 0, let policy = integer(raw["policy_generation"]),
              (0...1024).contains(policy), policy <= revision, let rows = raw["items"] as? [[String: Any]], rows.count <= 64 else { throw LocalHealthError.invalidResponse }
        var previous: (String, String)?, digests: Set<String> = []
        let items = try rows.map { row in
            guard keys(row, "artifact_digest id version trust_revision trust_generation trust_author state reader_basis_sha256"),
                  let artifact = digest(row["artifact_digest"]), digests.insert(artifact).inserted,
                  let id = identifier(row["id"]), let version = row["version"] as? String, validVersion(version),
                  previous.map({ $0.0 < id || ($0.0 == id && $0.1 < version) }) ?? true,
                  let author = identifier(row["trust_author"]), let state = row["state"] as? String,
                  ["approved", "revoked", "author_unavailable"].contains(state), let trust = positive(row["trust_revision"]), trust <= revision,
                  let generation = positive(row["trust_generation"]), generation <= policy else { throw LocalHealthError.invalidResponse }
            let basis = digest(row["reader_basis_sha256"])
            guard state == "revoked" ? row["reader_basis_sha256"] is NSNull : basis != nil else { throw LocalHealthError.invalidResponse }
            previous = (id, version)
            return HomeExternalProfileItem(artifact: artifact, id: id, version: version, author: author, state: state,
                readerBasis: basis, trustRevision: trust, trustGeneration: generation)
        }
        return HomeExternalProfileCatalogue(epoch: epoch, revision: revision, policyGeneration: policy, items: items)
    }
    static func decodeOriginal(_ response: [String: Any], kind: HomeExternalProfileOriginalKind, epoch: Int64,
                               operation: String, expectedInputSHA: String? = nil) throws -> HomeExternalProfileOriginalRead? {
        guard epoch > 0, LocalHealthClient.profileID(operation), expectedInputSHA == nil || LocalHealthClient.profileDigest(expectedInputSHA!) else { throw LocalHealthError.invalidProfileRequest }
        if keys(response, "api_version outcome"), integer(response["api_version"]) == 1, response["outcome"] as? String == "not_found" { return nil }
        guard Set(response.keys) == Set(["api_version", "outcome", kind.member]), integer(response["api_version"]) == 1,
              response["outcome"] as? String == "ok", let r = response[kind.member] as? [String: Any],
              positive(r["authority_epoch"]) == epoch, r["operation_id"] as? String == operation,
              let revision = positive(r["revision"]), let input = digest(r["input_sha256"]),
              expectedInputSHA == nil || input == expectedInputSHA else { throw LocalHealthError.invalidResponse }
        let detail: HomeExternalProfileReceiptDetail
        switch kind {
        case .inspection:
            guard keys(r, "authority_epoch operation_id revision input_sha256 reader_basis_sha256 result_sha256 capture_digest envelope_sha256 home_consumption"),
                  let basis = digest(r["reader_basis_sha256"]), let result = digest(r["result_sha256"]), let capture = digest(r["capture_digest"]),
                  let envelope = digest(r["envelope_sha256"]), r["home_consumption"] as? String == "matched" else { throw LocalHealthError.invalidResponse }
            detail = .inspection(HomeExternalInspectionDetail(readerBasis: basis, resultSHA: result, capture: capture, envelope: envelope))
        case .trust:
            guard keys(r, "authority_epoch operation_id revision input_sha256 action artifact_digest previous_trust_revision trust_generation policy_generation artifact_first_approval_revision reader_basis_sha256 outcome_sha256"),
                  let action = r["action"] as? String, ["approve", "revoke"].contains(action), let artifact = digest(r["artifact_digest"]),
                  let outcome = digest(r["outcome_sha256"]), let previous = integer(r["previous_trust_revision"]), previous >= 0, previous < revision,
                  let generation = positive(r["trust_generation"]), let policy = positive(r["policy_generation"]), generation <= policy,
                  let first = positive(r["artifact_first_approval_revision"]), first <= revision else { throw LocalHealthError.invalidResponse }
            let basis = digest(r["reader_basis_sha256"])
            guard action == "approve" ? basis != nil : r["reader_basis_sha256"] is NSNull,
                  generation == 1 ? (action == "approve" && previous == 0 && first == revision) : (previous > 0 && first < revision) else { throw LocalHealthError.invalidResponse }
            detail = .trust(HomeExternalTrustDetail(action: action, artifact: artifact, outcomeSHA: outcome, readerBasis: basis,
                previousRevision: previous, generation: generation, policyGeneration: policy, firstApprovalRevision: first))
        case .target:
            guard keys(r, "authority_epoch operation_id revision input_sha256 action target_id artifact_digest previous_selection_revision selection_generation resource_revision binding_revision trust_revision policy_generation source_selection_sha256 outcome_sha256 withdrawn_grants"),
                  let action = r["action"] as? String, ["select", "revoke"].contains(action), let target = identifier(r["target_id"]),
                  let artifact = digest(r["artifact_digest"]), let source = digest(r["source_selection_sha256"]), let outcome = digest(r["outcome_sha256"]),
                  let previous = integer(r["previous_selection_revision"]), previous >= 0, previous < revision,
                  let generation = positive(r["selection_generation"]), let resource = integer(r["resource_revision"]), resource >= 0,
                  let binding = positive(r["binding_revision"]), binding <= revision, let trust = positive(r["trust_revision"]), trust < revision,
                  let policy = positive(r["policy_generation"]), let withdrawn = integer(r["withdrawn_grants"]), (0...4096).contains(withdrawn),
                  generation == 1 ? (action == "select" && previous == 0 && resource == 0 && binding == revision && withdrawn == 0) :
                    (previous > 0 && resource == generation - 1 && (action == "select" ? binding == revision : binding <= previous)) else { throw LocalHealthError.invalidResponse }
            detail = .target(HomeExternalTargetDetail(action: action, target: target, artifact: artifact, sourceSelection: source, outcomeSHA: outcome,
                previousRevision: previous, generation: generation, resourceRevision: resource, bindingRevision: binding,
                trustRevision: trust, policyGeneration: policy, withdrawnGrants: withdrawn))
        }
        return HomeExternalProfileOriginalRead(kind: kind, epoch: epoch, operation: operation, revision: revision, inputSHA: input, detail: detail)
    }
    static func identity(socketPath: String, credential: Data) throws -> HomeControllerIdentity {
        do { return try LocalHealthClient.fetchControllerIdentity(socketPath: socketPath, credential: credential) }
        catch LocalHealthError.server(let reason) {
            let bytes = Array(reason.utf8)
            guard (1...128).contains(bytes.count), (97...122).contains(bytes[0]),
                  bytes.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }) else { throw LocalHealthError.invalidResponse }
            throw LocalHealthError.server(reason)
        }
    }
    private static func keys(_ value: [String: Any], _ fields: String) -> Bool { Set(value.keys) == Set(fields.split(separator: " ").map(String.init)) }
    private static func integer(_ value: Any?) -> Int64? { LocalHealthClient.profileInteger(value).map(Int64.init) }
    private static func positive(_ value: Any?) -> Int64? { integer(value).flatMap { $0 > 0 ? $0 : nil } }
    private static func digest(_ value: Any?) -> String? { (value as? String).flatMap { LocalHealthClient.profileDigest($0) ? $0 : nil } }
    private static func identifier(_ value: Any?) -> String? { (value as? String).flatMap { LocalHealthClient.profileID($0) ? $0 : nil } }
    private static func validVersion(_ value: String) -> Bool {
        value.utf8.count <= 17 && value.range(of: "^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)$", options: .regularExpression) != nil &&
            value.split(separator: ".").allSatisfy { UInt16($0) != nil }
    }
}
