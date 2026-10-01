import Foundation

@main
struct LocalMaintenanceSmoke {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else { exit(2) }
        let path = CommandLine.arguments[1]
        let mode = CommandLine.arguments[2]
        let credential = Data(repeating: 7, count: 32)
        if mode == "invalid-input" {
            let attempts: [() throws -> Void] = [
                { _ = try LocalHealthClient.beginMaintenance(socketPath: path, credential: credential,
                    authorityEpoch: 0, operationID: "maintenance:18", expectedRevision: 5) },
                { _ = try LocalHealthClient.beginMaintenance(socketPath: path, credential: credential,
                    authorityEpoch: 3, operationID: "bad id", expectedRevision: 5) },
                { _ = try LocalHealthClient.beginMaintenance(socketPath: path, credential: credential,
                    authorityEpoch: 3, operationID: "maintenance:18", expectedRevision: Int.max) },
                { _ = try LocalHealthClient.endMaintenance(socketPath: path, credential: credential,
                    authorityEpoch: 3, operationID: "maintenance:18", expectedRevision: 5, beginRevision: 6) },
                { _ = try LocalHealthClient.endMaintenance(socketPath: path, credential: credential,
                    authorityEpoch: 3, operationID: "maintenance:18", expectedRevision: 0, beginRevision: 0) },
            ]
            for attempt in attempts {
                do { try attempt(); exit(1) }
                catch LocalHealthError.invalidMaintenanceRequest { }
            }
            return
        }
        do {
            if mode.hasPrefix("status-") {
                let status = try LocalHealthClient.fetchMaintenanceStatus(socketPath: path, credential: credential)
                guard mode == "status-" + status.state, status.authorityEpoch == 3,
                      status.generation == 2, status.storeRevision == 10 else { exit(1) }
            } else if mode.hasPrefix("begin-") {
                if mode == "begin-retry" {
                    do { _ = try begin(path, credential); exit(1) }
                    catch LocalHealthError.transport { }
                }
                let receipt = try begin(path, credential)
                guard ["begin-valid", "begin-retry"].contains(mode), receipt.action == "begin",
                      receipt.beginRevision == 9, receipt.revision == 9,
                      receipt.affectedRequests == 2, receipt.unknownOutcomes == 1 else { exit(1) }
            } else if mode.hasPrefix("end-") {
                let receipt = try LocalHealthClient.endMaintenance(socketPath: path, credential: credential,
                    authorityEpoch: 3, operationID: "maintenance:18", expectedRevision: 10, beginRevision: 9)
                guard mode == "end-valid", receipt.action == "end", receipt.revision == 11,
                      receipt.beginRevision == 9, receipt.unknownOutcomes == 0 else { exit(1) }
            } else {
                let result = try LocalHealthClient.fetchMaintenanceOperationStatus(socketPath: path,
                    credential: credential, authorityEpoch: 3, operationID: "maintenance:18")
                switch result {
                case .notFound: guard mode == "operation-missing" else { exit(1) }
                case .found(let receipt):
                    guard mode == "operation-" + receipt.action, receipt.beginRevision == 9,
                          receipt.generation == 2 else { exit(1) }
                }
            }
        } catch LocalHealthError.invalidResponse where mode.contains("invalid") {
            return
        } catch LocalHealthError.server(let reason) {
            guard (mode == "begin-rejected" && reason == "resnapshot_required") ||
                  (mode == "begin-unknown" && reason == "outcome_unknown") else { exit(1) }
        }
    }

    private static func begin(_ path: String, _ credential: Data) throws -> HomeMaintenanceReceipt {
        try LocalHealthClient.beginMaintenance(socketPath: path, credential: credential,
            authorityEpoch: 3, operationID: "maintenance:18", expectedRevision: 5)
    }
}
