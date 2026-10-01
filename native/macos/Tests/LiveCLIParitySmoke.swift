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
        if mode == "stage" || mode == "stage-maintenance" {
            let receipt = try LocalHealthClient.submitPower(
                socketPath: socket, credential: credential,
                targetID: "light:parity", expectedRevision: 0,
                authorityEpoch: 1, operationID: mode == "stage" ? "op:parity:1" : "op:parity:2", on: true
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
        } else if mode == "suspend-rules" {
            let health = try LocalHealthClient.fetch(socketPath: socket, credential: credential)
            let receipt = try LocalHealthClient.suspendRules(socketPath: socket, credential: credential,
                authorityEpoch: health.authorityEpoch, operationID: "rule:parity:1", expectedRevision: health.revision)
            printRule(receipt)
        } else if mode == "rule-receipt" {
            let lookup = try LocalHealthClient.fetchRuleOperationStatus(socketPath: socket, credential: credential,
                authorityEpoch: 1, operationID: "rule:parity:1")
            guard case .activation(let receipt) = lookup else { exit(1) }
            printRule(receipt)
        } else if mode == "rule-policy" {
            let status = try LocalHealthClient.fetchRuleStatus(socketPath: socket, credential: credential)
            printJSON(["authority_epoch": status.authorityEpoch, "rule_generation": status.generation,
                "admission_revision": status.admissionRevision, "state": status.state,
                "reason": status.reason as Any? ?? NSNull()])
        } else if mode == "maintenance-status" {
            let status = try LocalHealthClient.fetchMaintenanceStatus(socketPath: socket, credential: credential)
            printJSON(["authority_epoch": status.authorityEpoch, "store_revision": status.storeRevision,
                "rule_generation": status.generation, "begin_revision": status.beginRevision, "state": status.state])
        } else if mode == "maintenance-begin" {
            let status = try LocalHealthClient.fetchMaintenanceStatus(socketPath: socket, credential: credential)
            let receipt = try LocalHealthClient.beginMaintenance(socketPath: socket, credential: credential,
                authorityEpoch: status.authorityEpoch, operationID: "maintenance:parity:begin", expectedRevision: status.storeRevision)
            printMaintenance(receipt)
        } else if mode == "maintenance-end" {
            let status = try LocalHealthClient.fetchMaintenanceStatus(socketPath: socket, credential: credential)
            let receipt = try LocalHealthClient.endMaintenance(socketPath: socket, credential: credential,
                authorityEpoch: status.authorityEpoch, operationID: "maintenance:parity:end",
                expectedRevision: status.storeRevision, beginRevision: status.beginRevision)
            printMaintenance(receipt)
        } else if mode == "maintenance-receipt" {
            let lookup = try LocalHealthClient.fetchMaintenanceOperationStatus(socketPath: socket, credential: credential,
                authorityEpoch: 1, operationID: "maintenance:parity:begin")
            guard case .found(let receipt) = lookup else { exit(1) }
            printMaintenance(receipt)
        } else if mode == "maintenance-blocked" {
            do {
                _ = try LocalHealthClient.submitPower(socketPath: socket, credential: credential,
                    targetID: "light:parity", expectedRevision: 0, authorityEpoch: 1,
                    operationID: "op:parity:3", on: true)
                exit(1)
            } catch LocalHealthError.server(let reason) where reason == "maintenance_active" {
                printJSON(["blocked": true])
            }
        } else {
            exit(2)
        }
    }

    private static func printMaintenance(_ receipt: HomeMaintenanceReceipt) {
        printJSON(["principal_id": receipt.principalID, "authority_epoch": receipt.authorityEpoch,
            "operation_id": receipt.operationID, "action": receipt.action,
            "begin_revision": receipt.beginRevision, "revision": receipt.revision,
            "rule_generation": receipt.generation, "affected_requests": receipt.affectedRequests,
            "unknown_outcomes": receipt.unknownOutcomes, "state": receipt.state])
    }

    private static func printRule(_ receipt: HomeRuleActivation) {
        printJSON(["admission_revision": receipt.admissionRevision, "rule_generation": receipt.generation,
            "revision": receipt.revision, "store_revision": receipt.storeRevision,
            "affected_requests": receipt.affectedRequests, "unknown_outcomes": receipt.unknownOutcomes])
    }

    private static func printJSON(_ record: [String: Any]) {
        guard let bytes = try? JSONSerialization.data(withJSONObject: record),
              let line = String(data: bytes, encoding: .utf8) else { exit(1) }
        print(line)
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
