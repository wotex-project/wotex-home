import Foundation

@main
struct LocalOverridesSmoke {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else { exit(2) }
        let path = CommandLine.arguments[1]
        let mode = CommandLine.arguments[2]
        let credential = Data(repeating: 7, count: 32)

        if mode == "invalid-input" {
            do {
                _ = try LocalHealthClient.fetchOverrides(
                    socketPath: path, credential: credential,
                    targetIDs: ["light:desk", "light:desk"]
                )
                exit(1)
            } catch LocalHealthError.invalidReceiptRequest {
                return
            }
        }

        do {
            let overrides = try LocalHealthClient.fetchOverrides(
                socketPath: path, credential: credential, targetIDs: ["light:desk"]
            )
            guard (mode == "valid" || mode == "unowned"), overrides.count == 1,
                  overrides[0].targetID == "light:desk",
                  overrides[0].operatorID == "operator:1",
                  overrides[0].authorityEpoch == 3,
                  overrides[0].basisRevision == 5,
                  overrides[0].remainingMilliseconds == 4_500,
                  overrides[0].operationID == (mode == "valid" ? "override:17" : nil) else { exit(1) }
        } catch LocalHealthError.invalidResponse where mode == "invalid" {
            return
        }
    }
}
