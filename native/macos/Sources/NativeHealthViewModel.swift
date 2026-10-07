import Foundation
import SwiftUI

@MainActor
final class HealthViewModel: ObservableObject, CustomReflectable {
    nonisolated var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
    nonisolated private let credentialLoader: @Sendable () throws -> Data
    nonisolated private let socketPath: @Sendable () -> String
    init(credentialLoader: @escaping @Sendable () throws -> Data = { try OperatorCredential.load() },
         socketPath: @escaping @Sendable () -> String = { LocalHealthClient.defaultSocketPath() }) {
        self.credentialLoader = credentialLoader; self.socketPath = socketPath
    }
    private enum Category: Hashable { case power, override, rule }
    private enum Input: Sendable {
        case power(target: String, revision: Int, on: Bool)
        case cancel
        case issueOverride(target: String, revision: Int, duration: Int)
        case revokeOverride
        case suspend(revision: Int)
    }
    private struct Original: Sendable {
        let credential: Data
        let epoch: Int
        let operation: String
        let input: Input
    }
    private var pending: [Category: Original] = [:] // At most one in each of three fixed categories.
    @Published private(set) var hasUnconfirmedOperation = false
    var hasUnconfirmedPower: Bool { pending[.power] != nil }
    var hasUnconfirmedOverride: Bool { pending[.override] != nil }
    var hasUnconfirmedRule: Bool { pending[.rule] != nil }
    private var snapshotCredential: Data?
    var canChangeSession: Bool {
        !busy && !receiptBusy && !stageBusy && !overrideBusy && !ruleBusy && !enrollmentBusy && !hasUnconfirmedOperation
    }
    private func remember(_ category: Category, epoch: Int, operation: String, input: Input,
                          credential: Data? = nil) async throws -> Original {
        guard pending[category] == nil else { throw LocalHealthError.server("resolve_original_operation") }
        let captured = try await Task.detached(priority: .userInitiated) { try credential ?? self.credentialLoader() }.value
        let original = Original(credential: captured, epoch: epoch, operation: operation, input: input)
        pending[category] = original; hasUnconfirmedOperation = true
        return original
    }
    private func matching(_ category: Category, epoch: Int, operation: String) -> Original? {
        pending[category].flatMap { $0.epoch == epoch && $0.operation == operation ? $0 : nil }
    }
    private func resolve(_ category: Category) { pending[category] = nil; hasUnconfirmedOperation = !pending.isEmpty }
    private func rejected(_ error: Error, category: Category) {
        if case LocalHealthError.server(let reason) = error, reason != "outcome_unknown", reason != "resolve_original_operation" { resolve(category) }
    }
    func invalidateSessionView() {
        currentStoreRevision = nil; currentAuthorityEpoch = nil; snapshotCredential = nil
        things = []; observations = []; overrides = []
        summary = "Refresh Home with the selected session"; detail = ""; executionDetail = ""; unknownWarning = false
        catalogueDetail = "Catalogue unavailable"; snapshotDetail = "Snapshot unavailable"; overrideDetail = "Overrides unavailable"
        ruleStatus = "Refresh rule policy with the selected session"
    }

    var manualImported: (() -> Void)?
    @Published var credentialInput = ""
    @Published var authorityEpochInput = ""
    @Published var operationIDInput = ""
    @Published var enrollmentReviewRefInput = ""
    @Published var overrideAuthorityEpochInput = ""
    @Published var overrideOperationIDInput = ""
    @Published private(set) var summary = "No health check yet"
    @Published private(set) var detail = ""
    @Published private(set) var executionDetail = ""
    @Published private(set) var unknownWarning = false
    @Published private(set) var observations: [HomeObservation] = []
    @Published private(set) var things: [HomeThing] = []
    @Published private(set) var overrides: [HomeOverride] = []
    @Published private(set) var catalogueDetail = "No catalogue yet"
    @Published private(set) var snapshotDetail = "No snapshot yet"
    @Published private(set) var overrideDetail = "No override check yet"
    @Published private(set) var error: String?
    @Published private(set) var busy = false
    @Published private(set) var receiptBusy = false
    @Published private(set) var stageBusy = false
    @Published private(set) var receiptStatus = "No operation selected"
    @Published private(set) var receiptError: String?
    @Published private(set) var enrollmentBusy = false
    @Published private(set) var enrollmentStatus = "No enrollment review selected"
    @Published private(set) var enrollmentError: String?
    @Published private(set) var overrideBusy = false
    @Published private(set) var overrideStatus = "No override operation selected"
    @Published private(set) var overrideError: String?
    @Published var ruleAuthorityEpochInput = ""
    @Published var ruleOperationIDInput = ""
    @Published private(set) var ruleBusy = false
    @Published private(set) var ruleStatus = "No rule policy check yet"
    @Published private(set) var ruleError: String?
    private var currentStoreRevision: Int?
    private var currentAuthorityEpoch: Int?

    func refreshRules() {
        guard !ruleBusy else { return }
        ruleBusy = true
        ruleError = nil
        Task {
            do {
                let status = try await Task.detached(priority: .userInitiated) {
                    try LocalHealthClient.fetchRuleStatus(socketPath: self.socketPath(), credential: self.credentialLoader())
                }.value
                ruleStatus = "Rules \(status.state) · Generation \(status.generation) · Admission \(status.admissionRevision)"
                if let reason = status.reason { ruleStatus += " · \(reason)" }
                if currentAuthorityEpoch != status.authorityEpoch { currentStoreRevision = nil }
            } catch {
                ruleStatus = "Rule policy unavailable"
                ruleError = error.localizedDescription
            }
            ruleBusy = false
        }
    }

    func suspendRules() {
        guard !ruleBusy, pending[.rule] == nil, let epoch = currentAuthorityEpoch, let revision = currentStoreRevision,
              let credential = snapshotCredential else {
            ruleError = "Refresh the Home view before suspending rules."
            return
        }
        let operation = "suspend:" + UUID().uuidString.lowercased()
        ruleAuthorityEpochInput = String(epoch)
        ruleOperationIDInput = operation
        ruleBusy = true
        ruleError = nil
        ruleStatus = "Suspending rules…"
        Task {
            do {
                let original = try await remember(.rule, epoch: epoch, operation: operation, input: .suspend(revision: revision), credential: credential)
                let receipt = try await Task.detached(priority: .userInitiated) {
                    try LocalHealthClient.suspendRules(socketPath: self.socketPath(), credential: original.credential,
                        authorityEpoch: epoch, operationID: operation, expectedRevision: revision)
                }.value
                resolve(.rule)
                currentStoreRevision = receipt.storeRevision
                ruleStatus = ruleActivationSummary(receipt)
            } catch {
                rejected(error, category: .rule)
                ruleStatus = "Suspension not confirmed; look up \(operation)"
                ruleError = error.localizedDescription
            }
            ruleBusy = false
        }
    }

    func lookupRuleOperation() {
        guard !ruleBusy else { return }
        let operation = ruleOperationIDInput
        guard let epoch = Int(ruleAuthorityEpochInput), epoch >= 1 else {
            ruleError = LocalHealthError.invalidRuleRequest.localizedDescription
            return
        }
        let original = matching(.rule, epoch: epoch, operation: operation)
        ruleBusy = true
        ruleError = nil
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try LocalHealthClient.fetchRuleOperationStatus(socketPath: self.socketPath(), credential: original?.credential ?? self.credentialLoader(), authorityEpoch: epoch, operationID: operation)
                }.value
                switch result {
                case .activation(let receipt):
                    ruleStatus = ruleActivationSummary(receipt)
                    if original != nil { resolve(.rule); currentStoreRevision = nil }
                case .admission(let receipt): ruleStatus = "Admitted revision \(receipt.revision) · \(receipt.artifactDigest)"
                case .notFound: ruleStatus = "No rule receipt for \(operation) in epoch \(epoch)"
                }
            } catch {
                ruleStatus = "Rule operation status unavailable"
                ruleError = error.localizedDescription
            }
            ruleBusy = false
        }
    }

    private func ruleActivationSummary(_ receipt: HomeRuleActivation) -> String {
        let action = receipt.admissionRevision == 0 ? "Suspended" : "Activated"
        return "\(action) generation \(receipt.generation) · \(receipt.affectedRequests) affected requests · " +
            "\(receipt.unknownOutcomes) unknown outcomes at the activation barrier"
    }

    private enum OriginalResult: Sendable {
        case power(HomeReceipt), cancellation(HomeReceiptLookup)
        case overrideIssue(HomeOverrideReceipt), overrideRevocation(HomeOverrideLookup)
        case suspension(HomeRuleActivation)
    }
    nonisolated private func send(_ original: Original) throws -> OriginalResult {
        let path = socketPath()
        switch original.input {
        case .power(let target, let revision, let on):
            return .power(try LocalHealthClient.submitPower(socketPath: path, credential: original.credential,
                targetID: target, expectedRevision: revision, authorityEpoch: original.epoch,
                operationID: original.operation, on: on))
        case .cancel:
            return .cancellation(try LocalHealthClient.cancelRequest(socketPath: path, credential: original.credential,
                authorityEpoch: original.epoch, operationID: original.operation))
        case .issueOverride(let target, let revision, let duration):
            return .overrideIssue(try LocalHealthClient.issueOverride(socketPath: path, credential: original.credential,
                targetID: target, basisRevision: revision, authorityEpoch: original.epoch,
                operationID: original.operation, durationMilliseconds: duration))
        case .revokeOverride:
            return .overrideRevocation(try LocalHealthClient.revokeOverride(socketPath: path, credential: original.credential,
                authorityEpoch: original.epoch, operationID: original.operation))
        case .suspend(let revision):
            return .suspension(try LocalHealthClient.suspendRules(socketPath: path, credential: original.credential,
                authorityEpoch: original.epoch, operationID: original.operation, expectedRevision: revision))
        }
    }
    func retryPower() { retryOriginal(.power) }
    func retryOverride() { retryOriginal(.override) }
    func retryRule() { retryOriginal(.rule) }
    private func retryOriginal(_ category: Category) {
        guard let original = pending[category] else { return }
        switch category {
        case .power:
            guard !stageBusy, !receiptBusy else { return }
            authorityEpochInput = String(original.epoch); operationIDInput = original.operation
            stageBusy = true; receiptError = nil
        case .override:
            guard !overrideBusy else { return }
            overrideAuthorityEpochInput = String(original.epoch); overrideOperationIDInput = original.operation
            overrideBusy = true; overrideError = nil
        case .rule:
            guard !ruleBusy else { return }
            ruleAuthorityEpochInput = String(original.epoch); ruleOperationIDInput = original.operation
            ruleBusy = true; ruleError = nil
        }
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) { try self.send(original) }.value
                var confirmed = true
                switch result {
                case .power(let receipt): receiptStatus = "\(receipt.operationID) · \(receipt.disposition) · Revision \(receipt.revision)"
                case .cancellation(let lookup):
                    switch lookup {
                    case .found(let receipt): receiptStatus = "\(receipt.operationID) · \(receipt.disposition) · Revision \(receipt.revision)"
                    case .notFound: receiptStatus = "No receipt found. The original cancellation remains unresolved."; confirmed = false
                    }
                case .overrideIssue(let receipt): overrideStatus = overrideSummary(receipt)
                case .overrideRevocation(let lookup):
                    switch lookup {
                    case .found(let receipt): overrideStatus = overrideSummary(receipt); confirmed = receipt.revokeRevision != nil
                    case .notFound: overrideStatus = "No receipt found. The original revocation remains unresolved."; confirmed = false
                    }
                case .suspension(let receipt): ruleStatus = ruleActivationSummary(receipt)
                }
                if confirmed { resolve(category); currentStoreRevision = nil }
            } catch {
                // Preserve the original after every unsuccessful retry, including
                // policy withdrawal; that refusal says nothing about an earlier commit.
                switch category {
                case .power: receiptError = error.localizedDescription
                case .override: overrideError = error.localizedDescription
                case .rule: ruleError = error.localizedDescription
                }
            }
            switch category {
            case .power: stageBusy = false
            case .override: overrideBusy = false
            case .rule: ruleBusy = false
            }
        }
    }

    func issueOverride(_ thing: HomeThing) {
        guard !overrideBusy, pending[.override] == nil, thing.powerWritable, let epoch = currentAuthorityEpoch,
              let credential = snapshotCredential else {
            overrideError = "Refresh the scoped Home view before issuing an override."
            return
        }
        let operationID = "override:" + UUID().uuidString.lowercased()
        overrideAuthorityEpochInput = String(epoch)
        overrideOperationIDInput = operationID
        overrideStatus = "Issuing \(operationID)…"
        overrideError = nil
        overrideBusy = true
        Task {
            do {
                let original = try await remember(.override, epoch: epoch, operation: operationID,
                    input: .issueOverride(target: thing.id, revision: thing.resourceRevision, duration: 900_000), credential: credential)
                let receipt = try await Task.detached(priority: .userInitiated) {
                    try LocalHealthClient.issueOverride(
                        socketPath: self.socketPath(), credential: original.credential, targetID: thing.id, basisRevision: thing.resourceRevision,
                        authorityEpoch: epoch, operationID: operationID,
                        durationMilliseconds: 900_000
                    )
                }.value
                resolve(.override)
                overrideStatus = overrideSummary(receipt)
                overrideBusy = false
                refresh()
            } catch {
                rejected(error, category: .override)
                overrideStatus = "Issue not confirmed; look up \(operationID)"
                overrideError = error.localizedDescription
                overrideBusy = false
            }
        }
    }

    func lookupOverride() {
        guard !overrideBusy else { return }
        let operationID = overrideOperationIDInput
        guard let epoch = Int(overrideAuthorityEpochInput), epoch >= 1 else {
            overrideError = LocalHealthError.invalidOverrideRequest.localizedDescription
            return
        }
        let original = matching(.override, epoch: epoch, operation: operationID)
        overrideBusy = true
        overrideError = nil
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try LocalHealthClient.fetchOverrideStatus(
                        socketPath: self.socketPath(), credential: original?.credential ?? self.credentialLoader(), authorityEpoch: epoch, operationID: operationID
                    )
                }.value
                switch result {
                case .notFound:
                    overrideStatus = "No override receipt for \(operationID) in epoch \(epoch)"
                case .found(let receipt):
                    overrideStatus = overrideSummary(receipt)
                    if let original {
                        if case .issueOverride = original.input { resolve(.override) }
                        if case .revokeOverride = original.input, receipt.revokeRevision != nil { resolve(.override) }
                    }
                }
            } catch {
                overrideStatus = "Override status unavailable"
                overrideError = error.localizedDescription
            }
            overrideBusy = false
        }
    }

    func revokeOverride(_ item: HomeOverride) {
        guard let operationID = item.operationID else { return }
        overrideAuthorityEpochInput = String(item.authorityEpoch)
        overrideOperationIDInput = operationID
        revokeOverride()
    }

    func revokeOverride() {
        guard !overrideBusy else { return }
        let operationID = overrideOperationIDInput
        guard let epoch = Int(overrideAuthorityEpochInput), epoch >= 1 else {
            overrideError = LocalHealthError.invalidOverrideRequest.localizedDescription
            return
        }
        let retained = matching(.override, epoch: epoch, operation: operationID)
        guard pending[.override] == nil || retained != nil else { return }
        if let retained, case .issueOverride = retained.input { return } // Resolve the issue before replacing it with revocation.
        overrideBusy = true
        overrideError = nil
        Task {
            do {
                let original: Original
                if let retained { original = retained }
                else { original = try await remember(.override, epoch: epoch, operation: operationID, input: .revokeOverride) }
                let result = try await Task.detached(priority: .userInitiated) {
                    try LocalHealthClient.revokeOverride(
                        socketPath: self.socketPath(), credential: original.credential, authorityEpoch: epoch, operationID: operationID
                    )
                }.value
                switch result {
                case .notFound:
                    overrideStatus = "No override receipt for \(operationID) in epoch \(epoch)"
                    if retained == nil { resolve(.override) }
                case .found(let receipt):
                    overrideStatus = overrideSummary(receipt)
                    if receipt.revokeRevision != nil { resolve(.override) }
                }
                overrideBusy = false
                if pending[.override] == nil { refresh() }
            } catch {
                // A retry refusal does not prove that an earlier request did not commit.
                overrideStatus = "Revoke not confirmed; look up \(operationID)"
                overrideError = error.localizedDescription
                overrideBusy = false
            }
        }
    }

    private func overrideSummary(_ receipt: HomeOverrideReceipt) -> String {
        let state = receipt.active ? "active" : "inactive"
        let remaining = receipt.remainingMilliseconds / 1_000
        return "\(receipt.operationID) · \(state) · \(remaining) s remaining · " +
            "Issue revision \(receipt.issueRevision)" +
            (receipt.revokeRevision.map { " · Revoked at \($0)" } ?? "")
    }

    func stagePower(_ thing: HomeThing, on: Bool) {
        guard !stageBusy, !receiptBusy, pending[.power] == nil, thing.powerWritable, let epoch = currentAuthorityEpoch,
              let credential = snapshotCredential else {
            receiptError = "Refresh the scoped Home view before staging power."
            return
        }
        let operationID = "op:" + UUID().uuidString.lowercased()
        authorityEpochInput = String(epoch)
        operationIDInput = operationID
        receiptStatus = "Submitting \(operationID)…"
        receiptError = nil
        stageBusy = true
        Task {
            do {
                let original = try await remember(.power, epoch: epoch, operation: operationID,
                    input: .power(target: thing.id, revision: thing.resourceRevision, on: on), credential: credential)
                let receipt = try await Task.detached(priority: .userInitiated) {
                    try LocalHealthClient.submitPower(
                        socketPath: self.socketPath(), credential: original.credential, targetID: thing.id, expectedRevision: thing.resourceRevision,
                        authorityEpoch: epoch, operationID: operationID, on: on
                    )
                }.value
                resolve(.power)
                receiptStatus = "\(receipt.operationID) · \(receipt.disposition) · " +
                    "Revision \(receipt.revision)" +
                    (receipt.reason.map { " · \($0)" } ?? "")
                stageBusy = false
                refresh()
            } catch {
                rejected(error, category: .power)
                receiptStatus = "Submission not confirmed; look up \(operationID)"
                receiptError = error.localizedDescription
                stageBusy = false
            }
        }
    }

    func lookupReceipt() {
        guard !receiptBusy, !stageBusy else { return }
        let operationID = operationIDInput
        guard let epoch = Int(authorityEpochInput), epoch >= 1 else {
            receiptError = LocalHealthError.invalidReceiptRequest.localizedDescription
            return
        }
        let original = matching(.power, epoch: epoch, operation: operationID)
        receiptBusy = true
        receiptError = nil
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try LocalHealthClient.fetchReceiptStatus(
                        socketPath: self.socketPath(), credential: original?.credential ?? self.credentialLoader(), authorityEpoch: epoch, operationID: operationID
                    )
                }.value
                switch result {
                case .notFound:
                    receiptStatus = "No receipt for \(operationID) in epoch \(epoch) " +
                        "in this credential's scope"
                case .found(let receipt):
                    if let original {
                        if case .power = original.input { resolve(.power) }
                        if case .cancel = original.input, receipt.disposition == "rejected" { resolve(.power) }
                    }
                    receiptStatus = "\(receipt.operationID) · \(receipt.disposition) · " +
                        "Revision \(receipt.revision)" +
                        (receipt.reason.map { " · \($0)" } ?? "")
                }
            } catch {
                receiptStatus = "Receipt unavailable"
                receiptError = error.localizedDescription
            }
            receiptBusy = false
        }
    }

    func cancelPendingRequest() {
        guard !receiptBusy, !stageBusy else { return }
        let operationID = operationIDInput
        guard let epoch = Int(authorityEpochInput), epoch >= 1 else {
            receiptError = LocalHealthError.invalidReceiptRequest.localizedDescription
            return
        }
        let retained = matching(.power, epoch: epoch, operation: operationID)
        guard pending[.power] == nil || retained != nil else { return }
        if let retained, case .power = retained.input { return } // Resolve admission before attempting cancellation.
        receiptBusy = true
        receiptError = nil
        Task {
            do {
                let original: Original
                if let retained { original = retained }
                else { original = try await remember(.power, epoch: epoch, operation: operationID, input: .cancel) }
                let result = try await Task.detached(priority: .userInitiated) {
                    try LocalHealthClient.cancelRequest(
                        socketPath: self.socketPath(), credential: original.credential, authorityEpoch: epoch, operationID: operationID
                    )
                }.value
                switch result {
                case .notFound:
                    receiptStatus = "No receipt for \(operationID) in epoch \(epoch) " +
                        "in this credential's scope"
                    if retained == nil { resolve(.power) }
                case .found(let receipt):
                    receiptStatus = "\(receipt.operationID) · \(receipt.disposition) · " +
                        "Revision \(receipt.revision)" +
                        (receipt.reason.map { " · \($0)" } ?? "")
                    resolve(.power)
                }
                receiptBusy = false
                if pending[.power] == nil { refresh() }
            } catch {
                receiptStatus = "Cancellation not confirmed; look up \(operationID)"
                receiptError = error.localizedDescription
                receiptBusy = false
            }
        }
    }

    func lookupEnrollmentReview() {
        guard !enrollmentBusy else { return }
        let reviewRef = enrollmentReviewRefInput
        enrollmentBusy = true
        enrollmentError = nil
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try LocalHealthClient.fetchEnrollmentStatus(socketPath: self.socketPath(), credential: self.credentialLoader(), reviewRef: reviewRef)
                }.value
                switch result {
                case .notFound:
                    enrollmentStatus = "No enrollment review \(reviewRef) in this credential's scope"
                case .found(let review):
                    enrollmentStatus = "\(review.reviewRef) · \(review.thingID) · " +
                        "\(review.state) · Review revision \(review.reviewRevision) · " +
                        "Current binding revision \(review.bindingRevision) · " +
                        "Digest version \(review.digestVersion)"
                }
            } catch {
                enrollmentStatus = "Enrollment review unavailable"
                enrollmentError = error.localizedDescription
            }
            enrollmentBusy = false
        }
    }

    func importCredential() {
        guard canChangeSession else { return }
        let encoded = credentialInput
        busy = true
        error = nil
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try OperatorCredential.save(encoded)
                }.value
                credentialInput = ""
                manualImported?()
                refresh()
            } catch {
                self.error = error.localizedDescription
                busy = false
            }
        }
    }

    func refresh() {
        guard !busy else { return }
        busy = true
        error = nil
        Task {
            do {
                let (health, readView, activeOverrides, credential) = try await Task.detached(priority: .userInitiated) {
                    let credential = try self.credentialLoader()
                    let path = self.socketPath()
                    let health = try LocalHealthClient.fetch(socketPath: path, credential: credential)
                    let readView = try LocalHealthClient.fetchReadView(socketPath: path, credential: credential)
                    guard health.authorityEpoch == readView.catalogue.authorityEpoch else {
                        throw LocalHealthError.invalidResponse
                    }
                    let overrides = try LocalHealthClient.fetchOverrides(
                        socketPath: path, credential: credential, targetIDs: readView.catalogue.things.map(\.id)
                    )
                    return (health, readView, overrides, credential)
                }.value
                summary = health.writable ? "Host store available" : "Host store unavailable"
                detail = "Revision \(health.revision) · Authority \(health.authorityEpoch) · " +
                    "Rule generation \(health.ruleGeneration) · " +
                    "\(health.activeThings) Things · \(health.activePrincipals) principals · " +
                    (health.dispatchEnabled ? "Dispatch enabled" : "Dispatch disabled")
                executionDetail = "\(health.heldRequests) held · \(health.queuedRequests) queued · " +
                    "\(health.claimedRequests) claimed · \(health.unknownOutcomes) unknown outcomes"
                unknownWarning = health.unknownOutcomes > 0
                snapshotCredential = credential
                currentAuthorityEpoch = health.authorityEpoch
                currentStoreRevision = readView.catalogue.watermark
                things = readView.catalogue.things
                overrides = activeOverrides
                overrideDetail = "\(activeOverrides.count) active overrides at refresh"
                catalogueDetail = "Catalogue revision \(readView.catalogue.watermark) · " +
                    "\(things.count) scoped Things"
                observations = readView.snapshot.observations
                snapshotDetail = "Snapshot revision \(readView.snapshot.watermark) · " +
                    "\(observations.count) scoped observations"
            } catch {
                summary = "Health unavailable"
                detail = ""
                executionDetail = ""
                unknownWarning = false
                snapshotCredential = nil
                currentAuthorityEpoch = nil
                currentStoreRevision = nil
                observations = []
                things = []
                overrides = []
                catalogueDetail = "Catalogue unavailable"
                snapshotDetail = "Snapshot unavailable"
                overrideDetail = "Overrides unavailable"
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}
