import Foundation

@main
struct LiveCLIParitySmoke {
    static func main() throws {
        guard CommandLine.arguments.count == 3,
              let encoded = readLine(strippingNewline: true),
              let credential = Data(base64Encoded: encoded
                  .replacingOccurrences(of: "-", with: "+")
                  .replacingOccurrences(of: "_", with: "/") + "="),
              credential.count == 32 else {
            exit(2)
        }

        let socket = CommandLine.arguments[1]
        let mode = CommandLine.arguments[2]
        if mode == "stage" {
            let receipt = try LocalHealthClient.submitPower(
                socketPath: socket, credential: credential,
                targetID: "light:parity", expectedRevision: 0,
                authorityEpoch: 1, operationID: "op:parity:1", on: true
            )
            guard receipt.disposition == "held" else { exit(1) }
            printReceipt(receipt)
        } else if mode == "status" {
            let lookup = try LocalHealthClient.fetchReceiptStatus(
                socketPath: socket, credential: credential,
                authorityEpoch: 1, operationID: "op:parity:1"
            )
            guard case .found(let receipt) = lookup else { exit(1) }
            printReceipt(receipt)
        } else {
            exit(2)
        }
    }

    private static func printReceipt(_ receipt: HomeReceipt) {
        let record: [String: Any] = [
            "authority_epoch": receipt.authorityEpoch,
            "operation_id": receipt.operationID,
            "disposition": receipt.disposition,
            "reason": receipt.reason as Any? ?? NSNull(),
            "revision": receipt.revision,
        ]
        guard let bytes = try? JSONSerialization.data(withJSONObject: record),
              let line = String(data: bytes, encoding: .utf8) else { exit(1) }
        print(line)
    }
}
