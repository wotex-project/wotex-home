import Foundation
import SwiftUI

struct NativeHomeRead: Sendable, CustomReflectable {
    let health: HomeHealth
    let view: HomeReadView
    let overrides: [HomeOverride]
    let localCredential: Data?
    let pairedPower: NativePairedPowerViewBasis?
    init(health: HomeHealth, view: HomeReadView, overrides: [HomeOverride], localCredential: Data?, pairedPower: NativePairedPowerViewBasis? = nil) {
        self.health = health; self.view = view; self.overrides = overrides; self.localCredential = localCredential; self.pairedPower = pairedPower
    }
    var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
}

@MainActor
final class HealthViewModel: ObservableObject, CustomReflectable {
    nonisolated var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
    nonisolated private let credentialLoader: @Sendable () throws -> Data
    nonisolated private let socketPath: @Sendable () -> String
    nonisolated private let credentialSaver: @Sendable (String) throws -> Void
    private let journal: NativePendingCoordinator
    private let selectedReader: (@Sendable () async throws -> NativeHomeRead)?
    private let pairedPowerSender: (@Sendable (NativePairedPowerViewBasis, HomeThing, Bool, String) async throws -> NativePairedRecoveryPublication)?
    init(credentialLoader: @escaping @Sendable () throws -> Data = { try OperatorCredential.load() },
         socketPath: @escaping @Sendable () -> String = { LocalHealthClient.defaultSocketPath() },
         journal: NativePendingCoordinator = .shared,
         credentialSaver: @escaping @Sendable (String) throws -> Void = { try OperatorCredential.save($0) },
         selectedReader: (@Sendable () async throws -> NativeHomeRead)? = nil,
         pairedPowerSender: (@Sendable (NativePairedPowerViewBasis, HomeThing, Bool, String) async throws -> NativePairedRecoveryPublication)? = nil) {
        self.credentialLoader = credentialLoader; self.socketPath = socketPath; self.journal = journal
        self.credentialSaver = credentialSaver
        self.selectedReader = selectedReader
        self.pairedPowerSender = pairedPowerSender
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
        let retained: NativePendingOriginal
        var credential: Data { retained.bytes }
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
    private var pairedPowerBasis: NativePairedPowerViewBasis?
    private var viewGeneration = UUID()
    private var hasCurrentPendingMemory: Bool {
        guard let owner = journal.owner else { return !pending.isEmpty }
        return pending.values.contains { original in
            let context = original.retained.entry.context
            return context.deployment == owner.deployment && context.owner == owner.owner && context.epoch == owner.epoch
        }
    }
    var canChangeSession: Bool {
        !busy && !receiptBusy && !stageBusy && !overrideBusy && !ruleBusy && !enrollmentBusy &&
            !hasCurrentPendingMemory && journal.canStart
    }
    private func remember(_ category: Category, epoch: Int, operation: String, input: Input,
                          credential: Data? = nil) async throws -> Original {
        guard pending[category] == nil else { throw LocalHealthError.server("resolve_original_operation") }
        let request: NativePendingInput
        switch input {
        case .power(let target, let revision, let on): request = .power(operation: operation, target: target, revision: Int64(revision), on: on)
        case .cancel: request = .cancel(operation: operation)
        case .issueOverride(let target, let revision, let duration): request = .issueOverride(operation: operation, target: target, revision: Int64(revision), duration: Int64(duration))
        case .revokeOverride: request = .revokeOverride(operation: operation)
        case .suspend(let revision): request = .suspend(operation: operation, revision: Int64(revision))
        }
        let retained = try await journal.begin(request, authorityEpoch: epoch, expectedCredential: credential)
        let original = Original(retained: retained, epoch: epoch, operation: operation, input: input)
        pending[category] = original; hasUnconfirmedOperation = true
        return original
    }
    private func matching(_ category: Category, epoch: Int, operation: String) -> Original? {
        pending[category].flatMap { $0.epoch == epoch && $0.operation == operation ? $0 : nil }
    }
    private func resolve(_ category: Category) async throws {
        guard let original = pending[category] else { return }
        try await journal.resolving(original.retained)
        pending[category] = nil; hasUnconfirmedOperation = !pending.isEmpty
    }
    func originalResolved(_ entry: NativePendingEntry) {
        if entry.category == .power && entry.input.operationID == operationIDInput && String(entry.context.epoch) == authorityEpochInput {
            receiptStatus = "Original power request reconciled · \(entry.input.operationID). Look up its receipt for the recorded disposition."
            receiptError = nil
        }
        pending = pending.filter { _, original in
            let retained = original.retained.entry
            return retained.context != entry.context || retained.custody != entry.custody || retained.input != entry.input
        }
        hasUnconfirmedOperation = !pending.isEmpty
        invalidateSessionView()
    }
    private func rejected(_ error: Error, category: Category) async {
        if case LocalHealthError.server(let reason) = error, reason != "outcome_unknown", reason != "resolve_original_operation" {
            // An unexpected/internal power error can follow a committed request.
            // Only closed first-attempt refusals permit removing its original.
            if category == .power && !Self.definitePowerRefusals.contains(reason) { return }
            // File failure keeps both the durable record and its in-memory original.
            do { try await resolve(category) } catch { self.error = error.localizedDescription }
        }
    }
    private static let definitePowerRefusals: Set<String> = ["unauthorized", "invalid_credential", "invalid_request",
        "invalid_envelope", "invalid_fields", "unsupported_api_version", "invalid_id", "invalid_revision", "invalid_value",
        "target_unavailable", "receipt_capacity", "operation_id_conflict", "reserved_operation_id", "maintenance_active"]
    func invalidateSessionView() {
        viewGeneration = UUID()
        if let owner = journal.owner {
            // Authenticated ownership change leaves old originals in the file;
            // they never become requests under the newly selected session.
            pending = pending.filter { _, original in
                let context = original.retained.entry.context
                return context.deployment == owner.deployment && context.owner == owner.owner && context.epoch == owner.epoch
            }
            hasUnconfirmedOperation = !pending.isEmpty
        }
        currentStoreRevision = nil; currentAuthorityEpoch = nil; snapshotCredential = nil; pairedPowerBasis = nil
        things = []; observations = []; overrides = []
        summary = "Refresh Home with the selected session"; detail = ""; executionDetail = ""; unknownWarning = false; dispatchEnabled = nil
        catalogueDetail = "Catalogue unavailable"; snapshotDetail = "Snapshot unavailable"; overrideDetail = "Overrides unavailable"
        ruleStatus = "Refresh rule policy with the selected session"
    }

    var manualImported: (() -> Void)?
    var powerRequestsAllowed: () -> Bool = { true }
    @Published var credentialInput = ""
    @Published var authorityEpochInput = ""
    @Published var operationIDInput = ""
    @Published private var requestedPower: (operation: String, epoch: Int, target: String, on: Bool, resource: Int)?
    var powerRequestDetail: String? {
        guard let requestedPower, requestedPower.operation == operationIDInput,
              String(requestedPower.epoch) == authorityEpochInput else { return nil }
        return "Requested \(requestedPower.on ? "On" : "Off") · \(requestedPower.target) · Resource \(requestedPower.resource)"
    }
    @Published var enrollmentReviewRefInput = ""
    @Published var overrideAuthorityEpochInput = ""
    @Published var overrideOperationIDInput = ""
    @Published private(set) var summary = "No health check yet"
    @Published private(set) var detail = ""
    @Published private(set) var executionDetail = ""
    @Published private(set) var unknownWarning = false
    @Published private(set) var dispatchEnabled: Bool?
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
        guard journal.canStart, !hasCurrentPendingMemory, !ruleBusy, pending[.rule] == nil, let epoch = currentAuthorityEpoch, let revision = currentStoreRevision,
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
                try await resolve(.rule)
                currentStoreRevision = receipt.storeRevision
                ruleStatus = ruleActivationSummary(receipt)
            } catch {
                await rejected(error, category: .rule)
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
                    if original != nil { try await resolve(.rule); currentStoreRevision = nil }
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
        guard !journal.busy, !journal.needsReload, let original = pending[category] else { return }
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
                if confirmed { try await resolve(category); currentStoreRevision = nil }
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
        guard journal.canStart, !hasCurrentPendingMemory, !overrideBusy, pending[.override] == nil, thing.powerWritable, let epoch = currentAuthorityEpoch,
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
                try await resolve(.override)
                overrideStatus = overrideSummary(receipt)
                overrideBusy = false
                refresh()
            } catch {
                await rejected(error, category: .override)
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
                        if case .issueOverride = original.input { try await resolve(.override) }
                        if case .revokeOverride = original.input, receipt.revokeRevision != nil { try await resolve(.override) }
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
        guard !journal.busy, !journal.needsReload, !overrideBusy else { return }
        let operationID = overrideOperationIDInput
        guard let epoch = Int(overrideAuthorityEpochInput), epoch >= 1 else {
            overrideError = LocalHealthError.invalidOverrideRequest.localizedDescription
            return
        }
        let retained = matching(.override, epoch: epoch, operation: operationID)
        guard retained != nil || (journal.canStart && !hasCurrentPendingMemory) else { return }
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
                    if retained == nil { try await resolve(.override) }
                case .found(let receipt):
                    overrideStatus = overrideSummary(receipt)
                    if receipt.revokeRevision != nil { try await resolve(.override) }
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
        guard canStagePower(thing), let epoch = currentAuthorityEpoch else {
            receiptError = "Refresh the scoped Home view before staging power."
            return
        }
        let operationID = "op:" + UUID().uuidString.lowercased()
        requestedPower = (operationID, epoch, thing.id, on, thing.resourceRevision)
        authorityEpochInput = String(epoch)
        operationIDInput = operationID
        receiptStatus = "Submitting \(operationID)…"
        receiptError = nil
        stageBusy = true
        if let basis = pairedPowerBasis, let sender = pairedPowerSender {
            Task {
                var received: NativePairedRecoveryPublication?
                do {
                    let publication = try await sender(basis, thing, on, operationID)
                    received = publication
                    try publication.deliveryCurrent()
                    switch publication.outcome {
                    case .retained(let detail), .resolved(let detail): receiptStatus = detail
                    case .review: receiptStatus = "Original review retained. Use shared recovery before another request."
                    }
                    stageBusy = false
                    if case .resolved = publication.outcome { refresh() }
                } catch {
                    if let received { journal.pairedDeliveryUnconfirmed(received) }
                    let retained = journal.entries.contains { $0.input.operationID == operationID && $0.category == .power }
                    receiptStatus = retained ? "Submission not confirmed; recover \(operationID)" : "Power request not confirmed · \(operationID)"
                    receiptError = error.localizedDescription; stageBusy = false
                }
            }
            return
        }
        guard let credential = snapshotCredential else { stageBusy = false; return }
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
                try await resolve(.power)
                receiptStatus = "\(receipt.operationID) · \(receipt.disposition) · " +
                    "Revision \(receipt.revision)" +
                    (receipt.reason.map { " · \($0)" } ?? "")
                stageBusy = false
                refresh()
            } catch {
                await rejected(error, category: .power)
                let retained = journal.entries.contains { $0.input.operationID == operationID && $0.category == .power }
                receiptStatus = retained ? "Submission not confirmed; look up \(operationID)" : "Power request refused or not submitted · \(operationID)"
                receiptError = error.localizedDescription
                stageBusy = false
            }
        }
    }

    func canStagePower(_ thing: HomeThing) -> Bool {
        powerRequestsAllowed() && canChangeSession && thing.powerWritable && currentAuthorityEpoch != nil &&
            (snapshotCredential != nil || (pairedPowerSender != nil && pairedPowerBasis?.permits(thing) == true)) &&
            things.contains { $0.id == thing.id && $0.resourceRevision == thing.resourceRevision &&
                $0.profileRef == thing.profileRef && $0.role == thing.role && $0.powerWritable }
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
                        if case .power = original.input { try await resolve(.power) }
                        if case .cancel = original.input, receipt.disposition == "rejected" { try await resolve(.power) }
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
        guard !journal.busy, !journal.needsReload, !receiptBusy, !stageBusy else { return }
        let operationID = operationIDInput
        guard let epoch = Int(authorityEpochInput), epoch >= 1 else {
            receiptError = LocalHealthError.invalidReceiptRequest.localizedDescription
            return
        }
        let retained = matching(.power, epoch: epoch, operation: operationID)
        guard retained != nil || (journal.canStart && !hasCurrentPendingMemory) else { return }
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
                    if retained == nil { try await resolve(.power) }
                case .found(let receipt):
                    receiptStatus = "\(receipt.operationID) · \(receipt.disposition) · " +
                        "Revision \(receipt.revision)" +
                        (receipt.reason.map { " · \($0)" } ?? "")
                    try await resolve(.power)
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
                    try self.credentialSaver(encoded)
                }.value
                credentialInput = ""
                busy = false
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
        let generation = viewGeneration
        busy = true
        error = nil
        Task {
            do {
                let result: NativeHomeRead
                if let selectedReader { result = try await selectedReader() }
                else { result = try await Task.detached(priority: .userInitiated) {
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
                    return NativeHomeRead(health: health, view: readView, overrides: overrides, localCredential: credential)
                }.value }
                let health = result.health, readView = result.view, activeOverrides = result.overrides
                try result.pairedPower?.deliveryCurrent()
                guard generation == viewGeneration else { busy = false; return }
                summary = health.writable ? "Host store available" : "Host store unavailable"
                detail = "Revision \(health.revision) · Authority \(health.authorityEpoch) · " +
                    "Rule generation \(health.ruleGeneration) · " +
                    "\(health.activeThings) Things · \(health.activePrincipals) principals · " +
                    (health.dispatchEnabled ? "Dispatch enabled" : "Dispatch disabled")
                executionDetail = "\(health.heldRequests) held · \(health.queuedRequests) queued · " +
                    "\(health.claimedRequests) claimed · \(health.unknownOutcomes) unknown outcomes"
                unknownWarning = health.unknownOutcomes > 0
                dispatchEnabled = health.dispatchEnabled
                snapshotCredential = result.localCredential
                pairedPowerBasis = result.pairedPower
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
                guard generation == viewGeneration else { busy = false; return }
                summary = "Health unavailable"
                detail = ""
                executionDetail = ""
                unknownWarning = false
                dispatchEnabled = nil
                snapshotCredential = nil
                pairedPowerBasis = nil
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
