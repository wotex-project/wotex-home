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
        } else if mode.hasPrefix("profile-") {
            var root = URL(fileURLWithPath: #filePath)
            for _ in 0..<4 { root.deleteLastPathComponent() }
            let bytes = try Data(contentsOf: root.appendingPathComponent("test/support/profiles/lifx-power.json"))
            let digest = LocalHealthClient.profileSHA(bytes)
            if mode == "profile-import" {
                let artifact = try LocalHealthClient.importProfile(socketPath: socket, credential: credential, bytes: bytes)
                printJSON(["artifact_digest": artifact.artifactDigest, "projection_digest": artifact.projectionDigest, "registry_digest": artifact.registryDigest, "id": artifact.id, "version": artifact.version, "profile_ref": artifact.profileRef, "binding": artifact.binding, "authority_changed": false])
            } else if mode == "profile-maintenance" {
                let status = try LocalHealthClient.fetchMaintenanceStatus(socketPath: socket, credential: credential)
                let receipt = try LocalHealthClient.beginMaintenance(socketPath: socket, credential: credential, authorityEpoch: status.authorityEpoch, operationID: "maintenance:parity:profiles", expectedRevision: status.storeRevision)
                printMaintenance(receipt)
            } else if mode == "profile-approve" || mode == "profile-revoke" {
                let catalogue = try LocalHealthClient.fetchProfiles(socketPath: socket, credential: credential)
                let action = mode == "profile-approve" ? "approve" : "revoke"
                let previous = catalogue.items.first { $0.artifact.artifactDigest == digest }?.trustRevision ?? 0
                let input = try HomeProfileOperation(["action": action, "authority_epoch": catalogue.authorityEpoch, "operation_id": "profile:parity:" + action, "expected_revision": catalogue.storeRevision, "artifact_digest": digest, "expected_trust_revision": previous])
                let receipt = try LocalHealthClient.changeProfile(socketPath: socket, credential: credential, input: input)
                printProfileReceipt(receipt)
            } else if mode == "profile-receipt" {
                let result = try LocalHealthClient.fetchProfileOperation(socketPath: socket, credential: credential, authorityEpoch: 1, operationID: "profile:parity:approve")
                guard case .found(let receipt) = result else { exit(1) }
                printProfileReceipt(receipt)
            } else if mode == "profile-catalogue" {
                let catalogue = try LocalHealthClient.fetchProfiles(socketPath: socket, credential: credential)
                let items: [[String: Any]] = catalogue.items.map { item in ["artifact_digest": item.artifact.artifactDigest, "projection_digest": item.artifact.projectionDigest, "registry_digest": item.artifact.registryDigest, "id": item.artifact.id, "version": item.artifact.version, "binding": item.artifact.binding, "trust_revision": item.trustRevision, "trust_generation": item.trustGeneration, "trust_author": item.trustAuthor, "state": item.state, "byte_availability": item.byteAvailability, "qualification_status": "pending_physical_evidence"] }
                printJSON(["authority_epoch": catalogue.authorityEpoch, "store_revision": catalogue.storeRevision, "policy_generation": catalogue.policyGeneration, "items": items])
            } else if mode == "profile-target" {
                let target = try LocalHealthClient.fetchProfileTarget(socketPath: socket, credential: credential, targetID: "light:profile:parity")
                guard target.status == "absent", target.bindingRevision == 0 else { exit(1) }
                printJSON(["target_id": target.targetID, "store_revision": target.storeRevision, "authority_epoch": target.authorityEpoch, "policy_generation": target.policyGeneration, "rule_generation": target.ruleGeneration, "status": target.status, "profile_ref": NSNull(), "declaration": NSNull(), "resource_revision": target.resourceRevision, "binding_revision": target.bindingRevision as Any? ?? NSNull(), "identity": NSNull(), "identity_status": target.identityStatus, "selection_revision": target.selectionRevision, "selection_generation": target.selectionGeneration, "selection_state": target.selectionState, "artifact_digest": NSNull(), "current_use": target.currentUse, "qualification_head": NSNull()])
            } else if mode == "profile-collect" {
                let result = try LocalHealthClient.collectProfiles(socketPath: socket, credential: credential)
                printJSON(["removed_objects": result.removedObjects, "removed_bytes": result.removedBytes, "object_count": result.objectCount, "total_bytes": result.totalBytes, "digests": result.digests])
            } else { exit(2) }
        } else {
            exit(2)
        }
    }

    private static func printProfileReceipt(_ receipt: HomeProfileReceipt) {
        printJSON(["authority_epoch": receipt.authorityEpoch, "operation_id": receipt.operationID, "action": receipt.action, "input_digest": receipt.inputDigest, "expected_revision": receipt.expectedRevision, "artifact_digest": receipt.artifactDigest, "final_revision": receipt.finalRevision, "changed_targets": receipt.changedTargets, "invalidated_requests": receipt.invalidatedRequests, "unknown_outcomes": receipt.unknownOutcomes, "previous_trust_revision": receipt.previousTrustRevision, "trust_generation": receipt.trustGeneration, "policy_generation": receipt.policyGeneration])
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
