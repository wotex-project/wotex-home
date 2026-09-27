import Foundation

@main
struct LocalOverrideMutationSmoke {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else { exit(2) }
        let path = CommandLine.arguments[1]
        let mode = CommandLine.arguments[2]
        let credential = Data(repeating: 7, count: 32)

        if mode == "invalid-input" {
            do {
                _ = try LocalHealthClient.issueOverride(
                    socketPath: path, credential: credential, targetID: "bad id",
                    basisRevision: 5, authorityEpoch: 3,
                    operationID: "override:17", durationMilliseconds: 900_000
                )
                exit(1)
            } catch LocalHealthError.invalidOverrideRequest {
                return
            }
        }

        if mode.hasPrefix("issue") {
            do {
                let receipt = try LocalHealthClient.issueOverride(
                    socketPath: path, credential: credential, targetID: "light:desk",
                    basisRevision: 5, authorityEpoch: 3,
                    operationID: "override:17", durationMilliseconds: 900_000
                )
                guard mode == "issue-valid", receipt.active,
                      receipt.issueRevision == 19,
                      receipt.remainingMilliseconds == 899_000 else { exit(1) }
            } catch LocalHealthError.invalidResponse where mode == "issue-invalid" {
                return
            }
            return
        }

        let result: HomeOverrideLookup
        if mode == "status-valid" {
            result = try LocalHealthClient.fetchOverrideStatus(
                socketPath: path, credential: credential,
                authorityEpoch: 3, operationID: "override:17"
            )
        } else if mode == "revoke-valid" {
            result = try LocalHealthClient.revokeOverride(
                socketPath: path, credential: credential,
                authorityEpoch: 3, operationID: "override:17"
            )
        } else {
            exit(2)
        }

        guard case .found(let receipt) = result,
              receipt.operatorID == "operator:1", receipt.issueRevision == 19,
              receipt.revokeRevision == (mode == "revoke-valid" ? 20 : nil),
              receipt.active == (mode == "status-valid") else { exit(1) }
    }
}
