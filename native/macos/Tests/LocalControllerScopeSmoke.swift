import Foundation

@main
struct LocalControllerScopeSmoke {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else { exit(2) }
        let path = CommandLine.arguments[1], mode = CommandLine.arguments[2]
        do {
            let scope = try LocalHealthClient.fetchControllerScope(socketPath: path, credential: Data(repeating: 7, count: 32))
            guard mode == "valid", scope.identity.deploymentID == String(repeating: "a", count: 64),
                  scope.identity.ownerID == String(repeating: "b", count: 64), scope.identity.authorityEpoch == 7,
                  scope.identity.revision == 9, scope.identity.principalID == "operator:scope",
                  scope.permissions == ["control:ordinary", "read"], scope.targetIDs == ["light:a", "light:b"] else { exit(1) }
        } catch LocalHealthError.invalidResponse {
            guard mode == "invalid" else { exit(1) }
        }
    }
}
