import Foundation

@main
struct NativeAuthoringContractLiveSmoke {
    static func main() throws {
        guard CommandLine.arguments.count == 4,
              let encoded = String(data: try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])), encoding: .utf8),
              let credential = Data(base64Encoded: encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "=") else { exit(2) }
        let expected = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]))) as! [String: Any]
        let result = try NativeAuthoringContractClient.fetch(socketPath: CommandLine.arguments[1], credential: credential)
        let summary = expected["summary"] as! [String: Any]
        let body = expected["contract_base64"] as! String
        let bytes = Data(base64Encoded: body.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + String(repeating: "=", count: (4 - body.utf8.count % 4) % 4))!
        guard result.contractBytes() == bytes, result.contractSHA == summary["contract_sha256"] as? String,
              result.rawSHA == summary["contract_raw_sha256"] as? String, result.basisSHA == summary["basis_sha256"] as? String,
              result.principal == expected["principal_id"] as? String, result.epoch == LocalHealthClient.profileInteger(expected["authority_epoch"]).map(Int64.init),
              result.revision == LocalHealthClient.profileInteger(expected["store_revision"]).map(Int64.init) else { exit(1) }
        guard case .runtime(let revision, let core, let runtime, let profiles) = result.producer,
              let producer = summary["producer"] as? [String: Any],
              revision == producer["source_revision"] as? String,
              core == producer["core_runtime_sha256"] as? String,
              runtime == producer["runtime_runtime_sha256"] as? String,
              profiles == producer["profiles_runtime_sha256"] as? String else { exit(1) }
    }
}
