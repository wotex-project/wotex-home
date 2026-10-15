import Foundation

private enum ExternalSDKFailure: Error { case failed }

@main
struct NativeExternalProfileMutationSmoke {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else { exit(2) }
        let socket = CommandLine.arguments[1], mode = CommandLine.arguments[2]
        let corpus = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "test/fixtures/profiles/native-external-profile-sdk.json"))) as! [String: Any]
        let cases = corpus["cases"] as! [[String: Any]]
        if mode == "corpus" {
            guard cases.count == 176 else { throw ExternalSDKFailure.failed }
            for vector in cases {
                let original = try original(vector)
                do {
                    let response: [String: Any] = ["api_version": 1, "outcome": "ok", original.kind.member: vector["receipt"]!]
                    guard let receipt = try NativeExternalProfileClient.decodeOriginal(response, kind: original.kind, epoch: original.epoch, operation: original.operation) else { throw ExternalSDKFailure.failed }
                    try NativeExternalProfileMutationClient.verify(receipt, original: original)
                    guard vector["accepted"] as? Bool == true else { throw ExternalSDKFailure.failed }
                } catch LocalHealthError.invalidResponse where vector["accepted"] as? Bool == false { continue }
            }
            return
        }
        let parts = mode.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, let vector = cases.first(where: { $0["name"] as? String == parts[0] }) else { exit(2) }
        let original = try original(vector), expected = parts[2]
        let controller = HomeControllerIdentity(deploymentID: String(repeating: "a", count: 64), ownerID: expected == "input" ? "bad" : String(repeating: "b", count: 64),
            authorityEpoch: parts[1] == "retry-old" ? 2 : 1, revision: 90, principalID: "operator:sdk")
        do {
            let receipt = try NativeExternalProfileMutationClient.deliver(socketPath: socket, credential: Data(repeating: 7, count: 32),
                original: original, expectedController: controller, lookup: parts[1] == "lookup")
            if expected == "missing" { guard receipt == nil else { throw ExternalSDKFailure.failed } }
            else { guard expected == "valid", let receipt, Mirror(reflecting: receipt).children.isEmpty else { throw ExternalSDKFailure.failed }; try NativeExternalProfileMutationClient.verify(receipt, original: original) }
        } catch NativeExternalProfileDeliveryError.outcomeUnknown where expected == "unknown" { return }
        catch LocalHealthError.nativeGuardConflict where expected == "guard" { return }
        catch LocalHealthError.invalidResponse where expected == "invalid" { return }
        catch LocalHealthError.invalidProfileRequest where expected == "input" { return }
        catch LocalHealthError.server("permission_denied") where expected == "refused" { return }
        catch let error as LocalHealthError where expected == "lost" {
            guard !error.localizedDescription.contains(original.operation) else { throw ExternalSDKFailure.failed }; return
        }
        catch { FileHandle.standardError.write(Data("external SDK expectation failed\n".utf8)); exit(1) }
    }
    private static func original(_ row: [String: Any]) throws -> HomeExternalProfileOriginal {
        guard let kind = HomeExternalProfileOriginalKind(rawValue: row["kind"] as! String) else { throw ExternalSDKFailure.failed }
        return try NativeExternalProfileOriginalWire.decode(Data((row["document"] as! String).utf8), kind: kind)
    }
}
