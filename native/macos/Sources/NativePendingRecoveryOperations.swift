import Foundation

// Closed SDK calls from the retained typed input. There is no editable request,
// credential selection, new operation ID or approval renewal in this runner.
enum NativePendingRecoveryOperations {
    static func execute(_ entry: NativePendingEntry, credential: Data, socketPath: String,
                        action: NativePendingRecoveryAction) throws -> NativePendingRecoveryOutcome {
        guard action.permits(entry), entry.custody.matches(credential) else { throw NativePendingError.invalidRecord }
        _ = try NativePendingDocument(revision: 1, entries: [entry]).encoded()
        let epoch = Int(entry.context.epoch), operation = entry.input.operationID
        let missing = NativePendingRecoveryOutcome.retained("No matching result confirmed. The original request remains retained.")
        switch entry.input {
        case .power(_, let target, let revision, let on):
            if action == .retry {
                let receipt = try LocalHealthClient.submitPower(socketPath: socketPath, credential: credential,
                    targetID: target, expectedRevision: Int(revision), authorityEpoch: epoch, operationID: operation, on: on)
                return power(receipt)
            }
            guard case .found(let receipt) = try LocalHealthClient.fetchReceiptStatus(socketPath: socketPath,
                credential: credential, authorityEpoch: epoch, operationID: operation) else { return missing }
            return power(receipt)
        case .cancel:
            let result = action == .retry ?
                try LocalHealthClient.cancelRequest(socketPath: socketPath, credential: credential, authorityEpoch: epoch, operationID: operation) :
                try LocalHealthClient.fetchReceiptStatus(socketPath: socketPath, credential: credential, authorityEpoch: epoch, operationID: operation)
            guard case .found(let receipt) = result, receipt.disposition == "rejected" else { return missing }
            return .resolved("Original cancellation confirmed at revision \(receipt.revision).")
        case .issueOverride(_, let target, let revision, let duration):
            let receipt: HomeOverrideReceipt
            if action == .retry {
                receipt = try LocalHealthClient.issueOverride(socketPath: socketPath, credential: credential,
                    targetID: target, basisRevision: Int(revision), authorityEpoch: epoch, operationID: operation,
                    durationMilliseconds: Int(duration))
            } else {
                guard case .found(let found) = try LocalHealthClient.fetchOverrideStatus(socketPath: socketPath,
                    credential: credential, authorityEpoch: epoch, operationID: operation) else { return missing }
                receipt = found
            }
            guard receipt.operatorID == entry.context.principal, receipt.targetID == target,
                  receipt.basisRevision == revision, receipt.durationMilliseconds == duration else { throw LocalHealthError.invalidResponse }
            return .resolved("Original override issue confirmed at revision \(receipt.issueRevision).")
        case .revokeOverride:
            let result = action == .retry ?
                try LocalHealthClient.revokeOverride(socketPath: socketPath, credential: credential, authorityEpoch: epoch, operationID: operation) :
                try LocalHealthClient.fetchOverrideStatus(socketPath: socketPath, credential: credential, authorityEpoch: epoch, operationID: operation)
            guard case .found(let receipt) = result, let revision = receipt.revokeRevision else { return missing }
            guard receipt.operatorID == entry.context.principal else { throw LocalHealthError.invalidResponse }
            return .resolved("Original override revocation confirmed at revision \(revision).")
        case .suspend(_, let revision):
            let receipt: HomeRuleActivation
            if action == .retry {
                receipt = try LocalHealthClient.suspendRules(socketPath: socketPath, credential: credential,
                    authorityEpoch: epoch, operationID: operation, expectedRevision: Int(revision))
            } else {
                guard case .activation(let found) = try LocalHealthClient.fetchRuleOperationStatus(socketPath: socketPath,
                    credential: credential, authorityEpoch: epoch, operationID: operation) else { return missing }
                receipt = found
            }
            guard receipt.admissionRevision == 0, receipt.revision == revision + 1 else { throw LocalHealthError.invalidResponse }
            return .resolved("Original rule suspension confirmed at revision \(receipt.revision).")
        case .beginMaintenance(_, let revision):
            let receipt: HomeMaintenanceReceipt
            if action == .retry {
                receipt = try LocalHealthClient.beginMaintenance(socketPath: socketPath, credential: credential,
                    authorityEpoch: epoch, operationID: operation, expectedRevision: Int(revision))
            } else {
                guard case .found(let found) = try LocalHealthClient.fetchMaintenanceOperationStatus(socketPath: socketPath,
                    credential: credential, authorityEpoch: epoch, operationID: operation) else { return missing }
                receipt = found
            }
            guard receipt.principalID == entry.context.principal, receipt.action == "begin", receipt.revision > revision,
                  receipt.revision - Int(revision) == receipt.affectedRequests + 2 else { throw LocalHealthError.invalidResponse }
            return .resolved("Original maintenance begin confirmed at revision \(receipt.revision).")
        case .endMaintenance(_, let revision, let begin):
            let receipt: HomeMaintenanceReceipt
            if action == .retry {
                receipt = try LocalHealthClient.endMaintenance(socketPath: socketPath, credential: credential,
                    authorityEpoch: epoch, operationID: operation, expectedRevision: Int(revision), beginRevision: Int(begin))
            } else {
                guard case .found(let found) = try LocalHealthClient.fetchMaintenanceOperationStatus(socketPath: socketPath,
                    credential: credential, authorityEpoch: epoch, operationID: operation) else { return missing }
                receipt = found
            }
            guard receipt.principalID == entry.context.principal, receipt.action == "end", receipt.beginRevision == begin,
                  receipt.revision == revision + 1 else { throw LocalHealthError.invalidResponse }
            return .resolved("Original maintenance end confirmed at revision \(receipt.revision).")
        case .profile(let preparing, let input):
            if action == .lookup {
                if case .found(let receipt) = try LocalHealthClient.fetchProfileOperation(socketPath: socketPath,
                    credential: credential, authorityEpoch: epoch, operationID: operation, input: input) {
                    return profile(receipt)
                }
                if let reference = review(entry.phase), case .found(let held) = try LocalHealthClient.fetchProfileReview(
                    socketPath: socketPath, credential: credential, token: reference.token, input: input) {
                    guard held.digest == reference.digest else { throw LocalHealthError.invalidResponse }
                    return .retained("Original review is \(held.state). Its recorded intent remains unchanged.")
                }
                return missing
            }
            if case .cancelPending(let token, _) = entry.phase {
                return try LocalHealthClient.cancelProfileReview(socketPath: socketPath, credential: credential, token: token) ?
                    .resolved("Original profile review cancellation confirmed.") : missing
            }
            if entry.phase == .pending && preparing {
                switch try LocalHealthClient.prepareProfile(socketPath: socketPath, credential: credential, input: input) {
                case .review(let held): return .review(token: held.token, digest: held.digest)
                case .committed(let receipt): return profile(receipt)
                }
            }
            guard entry.phase == .pending || { if case .commitPending = entry.phase { return true }; return false }() else {
                throw NativePendingError.invalidRecord
            }
            return profile(try LocalHealthClient.changeProfile(socketPath: socketPath, credential: credential, input: input))
        }
    }
    private static func power(_ receipt: HomeReceipt) -> NativePendingRecoveryOutcome {
        .resolved("Original request is \(receipt.disposition) at revision \(receipt.revision). This receipt does not establish observed device state.")
    }
    private static func profile(_ receipt: HomeProfileReceipt) -> NativePendingRecoveryOutcome {
        .resolved("Original profile \(receipt.action) confirmed at revision \(receipt.finalRevision).")
    }
    private static func review(_ phase: NativePendingPhase) -> (token: String, digest: String)? {
        switch phase {
        case .pending: nil
        case .review(let token, let digest), .commitPending(let token, let digest), .cancelPending(let token, let digest): (token, digest)
        }
    }
}
