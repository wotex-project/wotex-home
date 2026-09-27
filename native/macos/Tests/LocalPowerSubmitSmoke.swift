import Foundation

@main
struct LocalPowerSubmitSmoke {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else { exit(2) }
        let path = CommandLine.arguments[1]
        let mode = CommandLine.arguments[2]
        let credential = Data(repeating: 7, count: 32)

        if mode == "invalid-input" {
            do {
                _ = try LocalHealthClient.submitPower(
                    socketPath: path, credential: credential,
                    targetID: "bad id", expectedRevision: 0,
                    authorityEpoch: 3, operationID: "op:17", on: true
                )
                exit(1)
            } catch LocalHealthError.invalidReceiptRequest {
                return
            }
        }

        do {
            let receipt = try LocalHealthClient.submitPower(
                socketPath: path, credential: credential,
                targetID: "light:desk", expectedRevision: 5,
                authorityEpoch: 3, operationID: "op:17", on: true
            )
            guard mode == "valid", receipt.authorityEpoch == 3,
                  receipt.operationID == "op:17", receipt.disposition == "held",
                  receipt.reason == nil, receipt.revision == 19 else { exit(1) }
        } catch LocalHealthError.invalidResponse where mode == "invalid" {
            return
        }
    }
}
