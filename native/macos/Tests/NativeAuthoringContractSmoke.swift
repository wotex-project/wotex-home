import Foundation

@main
struct NativeAuthoringContractSmoke {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else { exit(2) }
        let socket = CommandLine.arguments[1], mode = CommandLine.arguments[2]
        do {
            let result = try NativeAuthoringContractClient.fetch(socketPath: socket, credential: Data(repeating: 7, count: 32))
            guard mode.hasPrefix("valid"), result.epoch == 1, result.revision == 10, result.principal == "author:fixture",
                  result.limits.reader.count == 8, result.limits.authoring.count == 4,
                  !result.contractBytes().isEmpty, !String(reflecting: result).contains("contract_base64"),
                  !String(reflecting: result).contains("document:") else { exit(1) }
        } catch LocalHealthError.invalidResponse where mode.hasPrefix("invalid") { return }
        catch LocalHealthError.server("permission_denied") where mode == "refused" { return }
        catch where mode == "lost" { return }
    }
}
