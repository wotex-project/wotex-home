import Foundation

@main
struct LocalReceiptSmoke {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else { exit(2) }
        let path = CommandLine.arguments[1]
        let mode = CommandLine.arguments[2]
        let credential = Data(repeating: 7, count: 32)

        if mode == "invalid-input" {
            do {
                _ = try LocalHealthClient.fetchReceiptStatus(
                    socketPath: path, credential: credential,
                    authorityEpoch: 0, operationID: "bad id"
                )
                exit(1)
            } catch LocalHealthError.invalidReceiptRequest {
                return
            }
        }

        do {
            let result = try LocalHealthClient.fetchReceiptStatus(
                socketPath: path, credential: credential,
                authorityEpoch: 3, operationID: "op:17"
            )
            switch (mode, result) {
            case ("valid", .found(let receipt)):
                guard receipt.authorityEpoch == 3,
                      receipt.operationID == "op:17",
                      receipt.disposition == "outcome_unknown",
                      receipt.reason == "crash_after_handoff",
                      receipt.revision == 19 else { exit(1) }
            case ("not-found", .notFound):
                return
            default:
                exit(1)
            }
        } catch LocalHealthError.invalidResponse where mode == "invalid" {
            return
        }
    }
}
