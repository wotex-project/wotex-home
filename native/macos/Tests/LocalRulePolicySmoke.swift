import Foundation

@main
struct LocalRulePolicySmoke {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else { exit(2) }
        let path = CommandLine.arguments[1]
        let mode = CommandLine.arguments[2]
        let credential = Data(repeating: 7, count: 32)
        if mode == "invalid-input" {
            do {
                _ = try LocalHealthClient.suspendRules(socketPath: path, credential: credential,
                    authorityEpoch: 3, operationID: "bad id", expectedRevision: 5)
                exit(1)
            } catch LocalHealthError.invalidRuleRequest { return }
        }
        do {
            if mode.hasPrefix("status-") {
                let status = try LocalHealthClient.fetchRuleStatus(socketPath: path, credential: credential)
                guard mode == "status-" + status.state, status.authorityEpoch == 3,
                      status.generation == 2 else { exit(1) }
            } else if mode.hasPrefix("suspend-") {
                let receipt = try LocalHealthClient.suspendRules(socketPath: path, credential: credential,
                    authorityEpoch: 3, operationID: "rule:17", expectedRevision: 5)
                guard mode == "suspend-valid", receipt.generation == 2,
                      receipt.admissionRevision == 0, receipt.storeRevision == 8,
                      receipt.unknownOutcomes == 1 else { exit(1) }
            } else {
                let receipt = try LocalHealthClient.fetchRuleOperationStatus(socketPath: path,
                    credential: credential, authorityEpoch: 3, operationID: "rule:17")
                switch receipt {
                case .notFound: guard mode == "operation-missing" else { exit(1) }
                case .admission(let admission):
                    guard mode == "operation-admission", admission.operationID == "rule:17",
                          admission.revision == 4 else { exit(1) }
                case .activation(let activation):
                    guard mode == "operation-activation", activation.generation == 2,
                          activation.unknownOutcomes == 1 else { exit(1) }
                }
            }
        } catch LocalHealthError.invalidResponse where mode.contains("invalid") {
            return
        }
    }
}
