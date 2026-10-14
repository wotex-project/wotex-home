import Foundation

@main
struct NativeAuthoringReadClientSmoke {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else { exit(2) }
        let socket = CommandLine.arguments[1], mode = CommandLine.arguments[2]
        let parts = mode.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        let credential = Data(repeating: 7, count: 32)
        do {
            if parts.count == 3 {
                let value = try NativeAuthoringReadClient.fetchObject(socketPath: socket, credential: credential, digest: parts[2])
                guard parts[0] == "object", let value, value.summary.kind == parts[1],
                      value.payload.count == value.summary.size, value.payload.allSatisfy({ $0 == 255 }),
                      !String(reflecting: value).contains("payload:") else { exit(1) }
                return
            }
            let kind = HomeAuthoringOriginalKind(rawValue: parts[1])!
            let value = try NativeAuthoringReadClient.fetchOriginal(socketPath: socket, credential: credential, kind: kind, epoch: 1, operation: "operation:1")
            if parts[0] == "missing" { guard value == nil else { exit(1) }; return }
            guard parts[0] == "valid", let value, value.kind == kind, value.epoch == 1,
                  value.operation == "operation:1", value.revision > 0 else { exit(1) }
            if kind == .review { guard value.sourceReview != nil, value.fixtureStatus != nil, value.proposalStatus != nil else { exit(1) } }
        } catch LocalHealthError.invalidResponse where parts[0].hasPrefix("invalid") { return }
        catch LocalHealthError.server("permission_denied") where parts[0] == "refused" { return }
        catch where parts[0] == "lost" { return }
    }
}
