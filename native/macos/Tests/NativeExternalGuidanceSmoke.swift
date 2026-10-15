import Foundation

@main
struct NativeExternalGuidanceSmoke {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else { exit(2) }
        let parts = CommandLine.arguments[2].split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4 else { exit(2) }
        let live = parts[0].hasPrefix("live-"), kind = parts[0].replacingOccurrences(of: "live-", with: ""), expected = parts[1], family = parts[2]
        let socket = CommandLine.arguments[1]
        var credential = Data(repeating: 7, count: 32)
        let inspections = try fixture("external-inspections")[family] as! [String: Any]
        var receipt = inspections["receipt"] as! [String: Any]
        if live {
            guard let line = readLine(), let bytes = Data(base64Encoded: line), bytes.count == 32,
                  let refLine = readLine(), let ref = try JSONSerialization.jsonObject(with: Data(refLine.utf8)) as? [String: Any] else { exit(2) }
            credential = bytes; receipt = ref
        }
        var reference = HomeExternalInspectionReference(epoch: (receipt["authority_epoch"] as! NSNumber).int64Value,
            operation: receipt["operation_id"] as! String, revision: (receipt["revision"] as! NSNumber).int64Value,
            inputSHA: receipt["input_sha256"] as! String, resultSHA: receipt["result_sha256"] as! String)
        if parts[3] == "bad-ref" { reference = HomeExternalInspectionReference(epoch: 0, operation: "bad/id", revision: 0, inputSHA: "bad", resultSHA: "bad") }
        if parts[3] == "bad-credential" { credential = Data() }
        do {
            switch kind {
            case "context":
                let value = try NativeExternalGuidanceClient.context(socketPath: socket, credential: credential)
                guard expected == "valid", Mirror(reflecting: value).children.isEmpty, Mirror(reflecting: value.basis).children.isEmpty,
                      parts[3] != "unavailable" || value.readerBasis == nil,
                      parts[3] != "maintenance" || value.maintenance,
                      live || checkBasis(value.basis) else { exit(1) }
                if live, let readerBasis = value.readerBasis {
                    let source = try fixture("external-source-selections")[family] as! [String: Any], data = source["data"] as! [String: Any]
                    guard readerBasis == data["reader_basis_sha256"] as? String else { exit(1) }
                }
            case "sources":
                let value = try NativeExternalGuidanceClient.sources(socketPath: socket, credential: credential)
                guard expected == "valid", Mirror(reflecting: value).children.isEmpty, value.sources.allSatisfy({ Mirror(reflecting: $0).children.isEmpty }),
                      live || checkBasis(value.basis), parts[3] != "32" || value.sources.count == 32 else { exit(1) }
                if parts[3] == "unavailable" { guard value.ownerEpoch == nil, value.sources.isEmpty else { exit(1) } }
                if parts[3] == "one" {
                    let source = try fixture("external-source-selections")[family] as! [String: Any], data = source["data"] as! [String: Any]
                    guard value.sources.count == 1, let row = value.sources.first,
                          row.reference == data["source_ref"] as? String, row.selectionSHA == source["sha256"] as? String,
                          row.readerBasis == data["reader_basis_sha256"] as? String, row.epoch == data["source_epoch"] as? String,
                          row.generation == (data["source_generation"] as! NSNumber).int64Value,
                          row.method == data["method"] as? String, row.trust == data["trust"] as? String,
                          row.policySHA == data["policy_sha256"] as? String else { exit(1) }
                }
            case "target":
                let value = try NativeExternalGuidanceClient.target(socketPath: socket, credential: credential, target: parts[3] == "bad-id" ? "bad/id" : "sensor:external")
                guard expected == "valid", value.state == parts[3], Mirror(reflecting: value).children.isEmpty,
                      live || checkBasis(value.basis) else { exit(1) }
                if !live {
                    guard value.selectionRevision == (parts[3] == "absent" ? 0 : 80), value.generation == (parts[3] == "absent" ? 0 : 2),
                          value.resourceRevision == (parts[3] == "absent" ? 0 : 1), value.trustRevision == (parts[3] == "absent" ? 0 : 90),
                          value.bindingRevision == (parts[3] == "absent" ? 0 : parts[3] == "selected" ? 80 : 70),
                          value.artifact == (parts[3] == "absent" ? nil : String(repeating: "e", count: 64)) else { exit(1) }
                }
            case "artifact":
                let value = try NativeExternalGuidanceClient.artifact(socketPath: socket, credential: credential, reference: reference)
                if expected == "missing" { guard value == nil else { exit(1) }; return }
                let frozen = try fixture("external-trust")[family] as! [String: Any]
                guard expected == "valid", let value, value.reference == reference,
                      value.digest == frozen["artifact_digest"] as? String, Mirror(reflecting: value).children.isEmpty,
                      live || checkBasis(value.basis),
                      Mirror(reflecting: value.reference).children.isEmpty,
                      value.objects.allSatisfy({ Mirror(reflecting: $0).children.isEmpty }),
                      String(data: value.canonical, encoding: .utf8) == frozen["artifact_document"] as? String else { exit(1) }
            default: exit(2)
            }
        } catch LocalHealthError.invalidProfileRequest where expected == "input" { return }
        catch LocalHealthError.invalidResponse where expected == "invalid" { return }
        catch LocalHealthError.nativeGuardConflict where expected == "guard" { return }
        catch LocalHealthError.server("permission_denied") where expected == "refused" { return }
        catch LocalHealthError.server("unauthorized") where expected == "unauthorized" { return }
        catch LocalHealthError.server("external_reader_unavailable") where expected == "reader" { return }
        catch where expected == "lost" { return }
        catch { FileHandle.standardError.write(Data("unexpected guidance read failure: \(error)\n".utf8)); exit(1) }
    }
    private static func checkBasis(_ value: HomeExternalGuidanceBasis) -> Bool {
        value.epoch == 2 && value.revision == 100 && value.policyGeneration == 1 && value.principal == "operator:read"
    }
    private static func fixture(_ name: String) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "test/fixtures/profiles/\(name).json"))) as! [String: Any]
    }
}
