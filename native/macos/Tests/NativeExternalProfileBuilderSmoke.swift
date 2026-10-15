import Foundation

@main
struct NativeExternalProfileBuilderSmoke {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { exit(2) }
        if CommandLine.arguments[1] == "--build" {
            guard let line = readLine(), line.utf8.count <= 262144 else { exit(2) }
            let value = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
            let original = try construct(value)
            let output: [String: Any] = ["kind": original.kind.rawValue, "document": String(data: original.canonical, encoding: .utf8)!,
                "input": try original.fields(), "sha256": original.sha]
            FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: output, options: .withoutEscapingSlashes)); return
        }
        for value in [Int64.min, Int64.max, Int64(0), Int64(-1), Int64(1)] {
            guard LocalHealthClient.profileInteger(value) == Int(exactly: value) else { fail(["id": "native S64"]) }
        }
        let refused = try JSONSerialization.jsonObject(with: Data("[true,false,1.0,1e0,\"1\",9223372036854775808]".utf8)) as! [Any]
        guard refused.allSatisfy({ LocalHealthClient.profileInteger($0) == nil }) else { fail(["id": "strict wire integer"]) }
        let corpus = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String: Any]
        for vector in corpus["valid"] as! [[String: Any]] {
            let original: HomeExternalProfileOriginal
            do { original = try construct(vector) } catch { FileHandle.standardError.write(Data("builder error: \(error)\n".utf8)); fail(vector) }
            guard original.kind.rawValue == vector["kind"] as? String, String(data: original.canonical, encoding: .utf8) == vector["document"] as? String,
                  original.sha == vector["sha256"] as? String, Mirror(reflecting: original).children.isEmpty else { fail(vector) }
            let actual = NSDictionary(dictionary: try original.fields()), expected = NSDictionary(dictionary: vector["expected"] as! [String: Any])
            guard actual == expected else { fail(vector) }
        }
        for vector in corpus["invalid"] as! [[String: Any]] {
            do { _ = try construct(vector); fail(vector) }
            catch LocalHealthError.nativeGuardConflict where vector["error"] as? String == "guard" {}
            catch LocalHealthError.invalidProfileRequest where vector["error"] as? String == "input" {}
            catch { fail(vector) }
        }
        for vector in corpus["objects_valid"] as! [[String: Any]] {
            let value = try NativeExternalProfileObjects.checked(vector["fields"] as! [String: Any])
            guard String(data: value.canonical, encoding: .utf8) == vector["document"] as? String,
                  try NativeExternalProfileObjects.decode(value.canonical) == value, Mirror(reflecting: value).children.isEmpty,
                  NSDictionary(dictionary: try value.fields()) == NSDictionary(dictionary: vector["fields"] as! [String: Any]) else { fail(vector) }
        }
        for fields in corpus["objects_invalid"] as! [[String: Any]] {
            do { _ = try NativeExternalProfileObjects.checked(fields); fail(["id": "malformed objects"]) }
            catch LocalHealthError.invalidProfileRequest {} catch { fail(["id": "objects error"]) }
        }
        for wire in corpus["objects_wire_invalid"] as! [String] {
            do { _ = try NativeExternalProfileObjects.decode(Data(wire.utf8)); fail(["id": "malformed object wire"]) }
            catch LocalHealthError.invalidProfileRequest {} catch { fail(["id": "objects wire error"]) }
        }
        print("native external builders passed independent corpus")
    }
    static func construct(_ vector: [String: Any]) throws -> HomeExternalProfileOriginal {
        let input = vector["inputs"] as! [String: Any], operation = input["operation"] as! String
        let contextRaw = input["context"] as! [String: Any], reader = contextRaw["reader"] as! [String: Any]
        let context = HomeExternalProfileContext(basis: basis(contextRaw), maintenance: contextRaw["maintenance"] as? String == "maintenance",
            maintenanceRevision: integer(contextRaw["maintenance_revision"]), readerBasis: reader["basis_sha256"] as? String, readerReason: reader["reason"] as? String)
        let raw = input["catalogue"] as! [String: Any]
        let catalogue = HomeExternalProfileCatalogue(epoch: integer(raw["authority_epoch"]), revision: integer(raw["store_revision"]),
            policyGeneration: integer(raw["policy_generation"]), items: (raw["items"] as! [[String: Any]]).map { row in
                HomeExternalProfileItem(artifact: row["artifact_digest"] as! String, id: row["id"] as! String, version: row["version"] as! String,
                    author: row["trust_author"] as! String, state: row["state"] as! String, readerBasis: row["reader_basis_sha256"] as? String,
                    trustRevision: integer(row["trust_revision"]), trustGeneration: integer(row["trust_generation"]))
            })
        switch vector["method"] as! String {
        case "inspection": return try NativeExternalProfileBuilder.inspection(context: context, operation: operation,
            objects: NativeExternalProfileObjects.checked(input["objects"] as! [String: Any]))
        case "approve":
            let receipt = input["inspection"] as! [String: Any]
            let inspection = HomeExternalProfileOriginalRead(kind: .inspection, epoch: integer(receipt["authority_epoch"]), operation: receipt["operation_id"] as! String,
                revision: integer(receipt["revision"]), inputSHA: receipt["input_sha256"] as! String,
                detail: .inspection(HomeExternalInspectionDetail(readerBasis: receipt["reader_basis_sha256"] as! String, resultSHA: receipt["result_sha256"] as! String,
                    capture: receipt["capture_digest"] as! String, envelope: receipt["envelope_sha256"] as! String)))
            return try NativeExternalProfileBuilder.approve(context: context, operation: operation, catalogue: catalogue, inspection: inspection,
                artifact: artifact(input["artifact"] as! [String: Any]))
        case "revokeTrust": return try NativeExternalProfileBuilder.revokeTrust(context: context, operation: operation, catalogue: catalogue, artifact: input["chosen_artifact"] as! String)
        case "select":
            let source = input["sources"] as! [String: Any]
            let sources = HomeExternalSourceCatalogue(basis: basis(source), ownerEpoch: source["owner_epoch"] as? String, reason: source["reason"] as? String,
                sources: (source["sources"] as! [[String: Any]]).map { row in
                    HomeExternalSourceChoice(reference: row["source_ref"] as! String, selectionSHA: row["source_selection_sha256"] as! String,
                        readerBasis: row["reader_basis_sha256"] as! String, epoch: row["source_epoch"] as! String, generation: integer(row["source_generation"]),
                        method: row["method"] as! String, trust: row["trust"] as! String, policySHA: row["policy_sha256"] as! String)
                })
            return try NativeExternalProfileBuilder.select(context: context, operation: operation, catalogue: catalogue, target: target(input["target"] as! [String: Any]),
                sources: sources, source: input["source"] as! String, objects: NativeExternalProfileObjects.checked(input["objects"] as! [String: Any]),
                artifact: artifact(input["artifact"] as! [String: Any]))
        case "revokeTarget": return try NativeExternalProfileBuilder.revokeTarget(context: context, operation: operation, catalogue: catalogue, target: target(input["target"] as! [String: Any]))
        default: throw LocalHealthError.invalidProfileRequest
        }
    }
    private static func target(_ value: [String: Any]) -> HomeExternalTargetBasis {
        HomeExternalTargetBasis(basis: basis(value), target: value["target_id"] as! String, state: value["state"] as! String, artifact: value["artifact_digest"] as? String,
            selectionRevision: integer(value["selection_revision"]), generation: integer(value["selection_generation"]), resourceRevision: integer(value["resource_revision"]),
            bindingRevision: integer(value["binding_revision"]), trustRevision: integer(value["trust_revision"]))
    }
    private static func artifact(_ value: [String: Any]) throws -> HomeExternalInspectionArtifact {
        let manifest = value["artifact"] as! [String: Any], ref = value["inspection_ref"] as! [String: Any], rows = manifest["objects"] as! [[String: Any]]
        let arrays: [[Any]] = rows.map { row in
            let ref = row["reference"] as? [String: Any]
            return [row["kind"]!, ref.map { [$0["id"]!, $0["version"]!, $0["sha256"]!] } as Any? ?? NSNull(), row["object_digest"]!, row["payload_sha256"]!, row["payload_bytes"]!]
        }
        let canonical = try JSONSerialization.data(withJSONObject: [manifest["format"]!, manifest["id"]!, manifest["version"]!, arrays], options: .withoutEscapingSlashes)
        return HomeExternalInspectionArtifact(basis: basis(value), reference: HomeExternalInspectionReference(epoch: integer(ref["authority_epoch"]), operation: ref["operation_id"] as! String,
            revision: integer(ref["revision"]), inputSHA: ref["input_sha256"] as! String, resultSHA: ref["result_sha256"] as! String), digest: value["artifact_digest"] as! String,
            id: manifest["id"] as! String, version: manifest["version"] as! String, canonical: canonical, objects: rows.map { row in
                let ref = row["reference"] as? [String: Any]
                return HomeExternalArtifactObject(kind: row["kind"] as! String, objectSHA: row["object_digest"] as! String, payloadSHA: row["payload_sha256"] as! String,
                    payloadBytes: integer(row["payload_bytes"]), referenceID: ref?["id"] as? String, referenceVersion: ref?["version"] as? String, referenceSHA: ref?["sha256"] as? String)
            })
    }
    private static func basis(_ value: [String: Any]) -> HomeExternalGuidanceBasis {
        HomeExternalGuidanceBasis(principal: value["principal_id"] as! String, epoch: integer(value["authority_epoch"]), revision: integer(value["store_revision"]), policyGeneration: integer(value["policy_generation"]))
    }
    private static func integer(_ value: Any?) -> Int64 { (value as! NSNumber).int64Value }
    private static func fail(_ vector: [String: Any]) -> Never {
        FileHandle.standardError.write(Data("external builder case failed: \(vector["id"] as? String ?? "unknown")\n".utf8)); exit(1)
    }
}
