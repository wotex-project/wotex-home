import Foundation

@main
struct LocalHealthSmoke {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else { exit(2) }
        let path = CommandLine.arguments[1]
        let mode = CommandLine.arguments[2]
        let credential = Data(repeating: 7, count: 32)

        if mode == "valid" {
            let health = try LocalHealthClient.fetch(socketPath: path, credential: credential)
            guard health.revision == 12,
                  health.authorityEpoch == 1,
                  health.ruleGeneration == 4,
                  health.heldRequests == 2,
                  health.queuedRequests == 1,
                  health.claimedRequests == 1,
                  health.unknownOutcomes == 1,
                  health.activeThings == 3,
                  health.activePrincipals == 1,
                  health.writable,
                  !health.dispatchEnabled else {
                exit(1)
            }
        } else if mode == "invalid" {
            do {
                _ = try LocalHealthClient.fetch(socketPath: path, credential: credential)
                exit(1)
            } catch LocalHealthError.invalidResponse {
                return
            }
        } else {
            exit(2)
        }
    }
}
