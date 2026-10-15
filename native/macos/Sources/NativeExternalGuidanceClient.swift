import Foundation

struct HomeExternalGuidanceBasis: Sendable, NativeExternalProfileMetadata {
    let principal: String
    let epoch: Int64, revision: Int64, policyGeneration: Int64
}
struct HomeExternalProfileContext: Sendable, NativeExternalProfileMetadata {
    let basis: HomeExternalGuidanceBasis
    let maintenance: Bool, maintenanceRevision: Int64
    let readerBasis: String?, readerReason: String?
}
struct HomeExternalSourceChoice: Sendable, NativeExternalProfileMetadata {
    let reference: String, selectionSHA: String, readerBasis: String, epoch: String
    let generation: Int64
    let method: String, trust: String, policySHA: String
}
struct HomeExternalSourceCatalogue: Sendable, NativeExternalProfileMetadata {
    let basis: HomeExternalGuidanceBasis
    let ownerEpoch: String?, reason: String?
    let sources: [HomeExternalSourceChoice]
}
struct HomeExternalTargetBasis: Sendable, NativeExternalProfileMetadata {
    let basis: HomeExternalGuidanceBasis
    let target: String, state: String, artifact: String?
    let selectionRevision: Int64, generation: Int64, resourceRevision: Int64, bindingRevision: Int64, trustRevision: Int64
}
struct HomeExternalInspectionReference: Sendable, Equatable, NativeExternalProfileMetadata {
    let epoch: Int64, operation: String, revision: Int64, inputSHA: String, resultSHA: String
    func fields() -> [String: Any] {
        ["authority_epoch": epoch, "operation_id": operation, "revision": revision, "input_sha256": inputSHA, "result_sha256": resultSHA]
    }
}
struct HomeExternalArtifactObject: Sendable, NativeExternalProfileMetadata {
    let kind: String, objectSHA: String, payloadSHA: String
    let payloadBytes: Int64
    let referenceID: String?, referenceVersion: String?, referenceSHA: String?
}
struct HomeExternalInspectionArtifact: Sendable, NativeExternalProfileMetadata {
    let basis: HomeExternalGuidanceBasis, reference: HomeExternalInspectionReference
    let digest: String, id: String, version: String
    let canonical: Data
    let objects: [HomeExternalArtifactObject]
}

// Explicit reads only. The caller owns socket/credential selection and any later review.
enum NativeExternalGuidanceClient {
    static func context(socketPath: String, credential: Data) throws -> HomeExternalProfileContext {
        try read(socketPath, credential, operation: "external_profile_context", fields: [:], decode: decodeContext)
    }
    static func sources(socketPath: String, credential: Data) throws -> HomeExternalSourceCatalogue {
        try read(socketPath, credential, operation: "external_source_catalogue", fields: [:], decode: decodeSources)
    }
    static func target(socketPath: String, credential: Data, target: String) throws -> HomeExternalTargetBasis {
        guard LocalHealthClient.profileID(target) else { throw LocalHealthError.invalidProfileRequest }
        return try read(socketPath, credential, operation: "external_target_basis", fields: ["target_id": target]) {
            try decodeTarget($0, target: target)
        }
    }
    static func artifact(socketPath: String, credential: Data, reference: HomeExternalInspectionReference) throws -> HomeExternalInspectionArtifact? {
        guard validReference(reference) else { throw LocalHealthError.invalidProfileRequest }
        return try read(socketPath, credential, operation: "external_inspection_artifact", fields: ["inspection_ref": reference.fields()]) {
            try decodeArtifact($0, reference: reference)
        }
    }
    private static func read<T>(_ socket: String, _ credential: Data, operation: String, fields: [String: Any],
                                decode: ([String: Any]) throws -> (T, HomeExternalGuidanceBasis?)) throws -> T {
        guard credential.count == 32 else { throw LocalHealthError.invalidProfileRequest }
        let before = try NativeExternalProfileClient.identity(socketPath: socket, credential: credential)
        let (result, basis) = try decode(LocalHealthClient.externalProfileReadTransport(socketPath: socket, credential: credential,
            operation: operation, fields: fields))
        let after = try NativeExternalProfileClient.identity(socketPath: socket, credential: credential)
        guard after.matchesAuthority(before), after.revision == before.revision,
              basis.map({ $0.principal == after.principalID && $0.epoch == after.authorityEpoch && $0.revision == after.revision }) ?? true else {
            throw LocalHealthError.nativeGuardConflict
        }
        return result
    }
    static func decodeContext(_ response: [String: Any]) throws -> (HomeExternalProfileContext, HomeExternalGuidanceBasis?) {
        let (body, basis) = try body(response, operation: "external_profile_context", extra: "maintenance maintenance_revision reader", maximum: 4096)
        guard let maintenance = body["maintenance"] as? String, ["normal", "maintenance"].contains(maintenance),
              let revision = number(body["maintenance_revision"]), revision <= basis.revision,
              maintenance == "normal" ? revision == 0 : revision > 0,
              let reader = body["reader"] as? [String: Any], exact(reader, "state basis_sha256 reason") else { throw LocalHealthError.invalidResponse }
        let readerBasis: String?, reason: String?
        if reader["state"] as? String == "available", let digest = digest(reader["basis_sha256"]), reader["reason"] is NSNull {
            readerBasis = digest; reason = nil
        } else if reader["state"] as? String == "unavailable", reader["basis_sha256"] is NSNull,
                  let value = reader["reason"] as? String, ["external_reader_unavailable", "profiles_producer_unavailable"].contains(value) {
            readerBasis = nil; reason = value
        } else { throw LocalHealthError.invalidResponse }
        return (HomeExternalProfileContext(basis: basis, maintenance: maintenance == "maintenance", maintenanceRevision: revision,
            readerBasis: readerBasis, readerReason: reason), basis)
    }
    static func decodeSources(_ response: [String: Any]) throws -> (HomeExternalSourceCatalogue, HomeExternalGuidanceBasis?) {
        let (body, basis) = try body(response, operation: "external_source_catalogue", extra: "state owner_epoch sources reason", maximum: 32768)
        guard let rows = body["sources"] as? [[String: Any]], rows.count <= 32 else { throw LocalHealthError.invalidResponse }
        if body["state"] as? String == "unavailable" {
            guard body["owner_epoch"] is NSNull, rows.isEmpty, body["reason"] as? String == "external_source_unavailable" else { throw LocalHealthError.invalidResponse }
            return (HomeExternalSourceCatalogue(basis: basis, ownerEpoch: nil, reason: "external_source_unavailable", sources: []), basis)
        }
        guard body["state"] as? String == "available", let owner = epoch(body["owner_epoch"]), body["reason"] is NSNull else { throw LocalHealthError.invalidResponse }
        var previous: String?
        let sources = try rows.map { row -> HomeExternalSourceChoice in
            guard exact(row, "source_ref source_selection_sha256 reader_basis_sha256 source_epoch source_generation method trust policy_sha256"),
                  let ref = identifier(row["source_ref"]), previous.map({ $0 < ref }) ?? true,
                  let selection = digest(row["source_selection_sha256"]), let reader = digest(row["reader_basis_sha256"]),
                  let sourceEpoch = epoch(row["source_epoch"]), let generation = number(row["source_generation"], minimum: 1),
                  let method = row["method"] as? String, ["operator_configured", "legacy_tofu", "physical_button", "qr_install_code"].contains(method),
                  let trust = row["trust"] as? String, ["unauthenticated_local", "authenticated_device", "bridge_attested", "synthetic_lab"].contains(trust),
                  let policy = digest(row["policy_sha256"]) else { throw LocalHealthError.invalidResponse }
            previous = ref
            return HomeExternalSourceChoice(reference: ref, selectionSHA: selection, readerBasis: reader, epoch: sourceEpoch,
                generation: generation, method: method, trust: trust, policySHA: policy)
        }
        return (HomeExternalSourceCatalogue(basis: basis, ownerEpoch: owner, reason: nil, sources: sources), basis)
    }
    static func decodeTarget(_ response: [String: Any], target: String) throws -> (HomeExternalTargetBasis, HomeExternalGuidanceBasis?) {
        let (body, basis) = try body(response, operation: "external_target_basis", extra: "target_id state selection_revision selection_generation resource_revision binding_revision artifact_digest trust_revision", maximum: 8192)
        guard body["target_id"] as? String == target, LocalHealthClient.profileID(target), let state = body["state"] as? String,
              let selection = number(body["selection_revision"]), selection <= basis.revision,
              let generation = number(body["selection_generation"]), let resource = number(body["resource_revision"]),
              let binding = number(body["binding_revision"]), let trust = number(body["trust_revision"]), trust <= basis.revision else { throw LocalHealthError.invalidResponse }
        let artifact = digest(body["artifact_digest"])
        if state == "absent" {
            guard selection == 0, generation == 0, resource == 0, binding == 0, trust == 0, body["artifact_digest"] is NSNull else { throw LocalHealthError.invalidResponse }
        } else {
            guard ["selected", "revoked"].contains(state), selection > 0, generation > 0, generation <= selection, resource == generation - 1,
                  binding > 0, binding <= selection, trust > 0, artifact != nil,
                  state != "selected" || binding == selection else { throw LocalHealthError.invalidResponse }
        }
        return (HomeExternalTargetBasis(basis: basis, target: target, state: state, artifact: artifact, selectionRevision: selection,
            generation: generation, resourceRevision: resource, bindingRevision: binding, trustRevision: trust), basis)
    }
    static func decodeArtifact(_ response: [String: Any], reference: HomeExternalInspectionReference) throws -> (HomeExternalInspectionArtifact?, HomeExternalGuidanceBasis?) {
        guard validReference(reference) else { throw LocalHealthError.invalidProfileRequest }
        if exact(response, "api_version outcome"), number(response["api_version"]) == 1, response["outcome"] as? String == "not_found" { return (nil, nil) }
        let (body, basis) = try body(response, operation: "external_inspection_artifact", extra: "inspection_ref artifact_digest artifact", maximum: 65536)
        guard let ref = body["inspection_ref"] as? [String: Any], exact(ref, "authority_epoch operation_id revision input_sha256 result_sha256"),
              number(ref["authority_epoch"], minimum: 1) == reference.epoch, ref["operation_id"] as? String == reference.operation,
              number(ref["revision"], minimum: 1) == reference.revision, ref["input_sha256"] as? String == reference.inputSHA,
              ref["result_sha256"] as? String == reference.resultSHA, reference.revision <= basis.revision,
              let digest = digest(body["artifact_digest"]), let artifact = body["artifact"] as? [String: Any], exact(artifact, "format id version objects"),
              artifact["format"] as? String == "wotex-home.external-artifact@1", let id = identifier(artifact["id"]),
              let version = artifact["version"] as? String, validVersion(version), let rows = artifact["objects"] as? [[String: Any]],
              (2...34).contains(rows.count) else { throw LocalHealthError.invalidResponse }
        var arrays: [[Any]] = [], digests: Set<String> = [], previous: (String, String)?, identifiers: Set<String> = [], total: Int64 = 0
        let objects = try rows.enumerated().map { index, row -> HomeExternalArtifactObject in
            let expected = index == 0 ? "envelope" : index == 1 ? "profile" : "definition"
            guard exact(row, "kind object_digest payload_sha256 payload_bytes reference"), row["kind"] as? String == expected,
                  let object = self.digest(row["object_digest"]), digests.insert(object).inserted, let payload = self.digest(row["payload_sha256"]),
                  let bytes = number(row["payload_bytes"], minimum: 1), bytes <= 65536 else { throw LocalHealthError.invalidResponse }
            var refID: String?, refVersion: String?, refSHA: String?, encodedRef: Any = NSNull()
            if index == 0 { guard row["reference"] is NSNull else { throw LocalHealthError.invalidResponse } }
            else {
                guard let ref = row["reference"] as? [String: Any], exact(ref, "id version sha256"), let uri = ref["id"] as? String,
                      ExternalOriginalURI.valid(uri), let version = ref["version"] as? String, validVersion(version), let sha = self.digest(ref["sha256"]) else { throw LocalHealthError.invalidResponse }
                if index > 1 {
                    guard identifiers.insert(uri).inserted, previous.map({ $0.0 < uri || ($0.0 == uri && $0.1 < version) }) ?? true else { throw LocalHealthError.invalidResponse }
                    previous = (uri, version)
                }
                refID = uri; refVersion = version; refSHA = sha; encodedRef = [uri, version, sha]
                total += bytes
            }
            arrays.append([expected, encodedRef, object, payload, bytes])
            return HomeExternalArtifactObject(kind: expected, objectSHA: object, payloadSHA: payload, payloadBytes: bytes,
                referenceID: refID, referenceVersion: refVersion, referenceSHA: refSHA)
        }
        let canonical = try json(["wotex-home.external-artifact@1", id, version, arrays])
        guard total <= 262144, canonical.count <= 32768,
              LocalHealthClient.profileSHA(Data("wotex-home.external-artifact@1\n".utf8) + (try json(arrays))) == digest else { throw LocalHealthError.invalidResponse }
        return (HomeExternalInspectionArtifact(basis: basis, reference: reference, digest: digest, id: id, version: version, canonical: canonical, objects: objects), basis)
    }
    private static func body(_ response: [String: Any], operation: String, extra: String, maximum: Int) throws -> ([String: Any], HomeExternalGuidanceBasis) {
        guard Set(response.keys) == Set(["api_version", "outcome", operation]), number(response["api_version"]) == 1,
              response["outcome"] as? String == "ok", let body = response[operation] as? [String: Any],
              exact(body, "format principal_id authority_epoch store_revision policy_generation " + extra),
              body["format"] as? String == "wotex-home." + operation.replacingOccurrences(of: "_", with: "-") + "@1",
              let principal = identifier(body["principal_id"]), let epoch = number(body["authority_epoch"], minimum: 1),
              let revision = number(body["store_revision"]), let policy = number(body["policy_generation"]), policy <= 1024, policy <= revision,
              (try json(body)).count <= maximum else { throw LocalHealthError.invalidResponse }
        return (body, HomeExternalGuidanceBasis(principal: principal, epoch: epoch, revision: revision, policyGeneration: policy))
    }
    private static func validReference(_ ref: HomeExternalInspectionReference) -> Bool {
        ref.epoch > 0 && ref.revision > 0 && LocalHealthClient.profileID(ref.operation) && LocalHealthClient.profileDigest(ref.inputSHA) && LocalHealthClient.profileDigest(ref.resultSHA)
    }
    private static func exact(_ value: [String: Any], _ fields: String) -> Bool { Set(value.keys) == Set(fields.split(separator: " ").map(String.init)) }
    private static func number(_ value: Any?, minimum: Int64 = 0) -> Int64? { LocalHealthClient.profileInteger(value).map(Int64.init).flatMap { $0 >= minimum ? $0 : nil } }
    private static func digest(_ value: Any?) -> String? { (value as? String).flatMap { LocalHealthClient.profileDigest($0) ? $0 : nil } }
    private static func identifier(_ value: Any?) -> String? { (value as? String).flatMap { LocalHealthClient.profileID($0) ? $0 : nil } }
    private static func epoch(_ value: Any?) -> String? { (value as? String).flatMap { $0.utf8.count == 32 && $0.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) ? $0 : nil } }
    private static func validVersion(_ value: String) -> Bool {
        value.utf8.count <= 17 && value.range(of: "^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)$", options: .regularExpression) != nil && value.split(separator: ".").allSatisfy { UInt16($0) != nil }
    }
    private static func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: .withoutEscapingSlashes) }
}
