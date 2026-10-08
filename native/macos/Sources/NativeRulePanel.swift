import Foundation
import SwiftUI

struct NativeRulePanelClient: Sendable {
    let capture: @Sendable () throws -> LocalCredentialCapture
    let identity: @Sendable (Data) throws -> HomeControllerIdentity
    let preview: @Sendable (Data, HomeExplicitPowerRule) throws -> HomeExplicitRulePreview
    let current: @Sendable (Data) throws -> HomeExplicitRuleCurrent
    let status: @Sendable (Data) throws -> HomeRuleStatus
    let deliver: @Sendable (Data, HomeExplicitRuleOperation, String, Bool) throws -> HomeExplicitRuleResult
    init(capture: @escaping @Sendable () throws -> LocalCredentialCapture = { try OperatorCredential.captureOriginal() },
         identity: @escaping @Sendable (Data) throws -> HomeControllerIdentity = { try LocalHealthClient.fetchControllerIdentity(socketPath: LocalHealthClient.defaultSocketPath(), credential: $0) },
         preview: @escaping @Sendable (Data, HomeExplicitPowerRule) throws -> HomeExplicitRulePreview = { try NativeRuleClient.preview(socketPath: LocalHealthClient.defaultSocketPath(), credential: $0, rule: $1) },
         current: @escaping @Sendable (Data) throws -> HomeExplicitRuleCurrent = { try NativeRuleClient.current(socketPath: LocalHealthClient.defaultSocketPath(), credential: $0) },
         status: @escaping @Sendable (Data) throws -> HomeRuleStatus = { try LocalHealthClient.fetchRuleStatus(socketPath: LocalHealthClient.defaultSocketPath(), credential: $0) },
         deliver: @escaping @Sendable (Data, HomeExplicitRuleOperation, String, Bool) throws -> HomeExplicitRuleResult = { try NativeRuleClient.deliver(socketPath: LocalHealthClient.defaultSocketPath(), credential: $0, original: $1, principal: $2, lookup: $3) }) {
        self.capture = capture; self.identity = identity; self.preview = preview; self.current = current; self.status = status; self.deliver = deliver
    }
}

enum NativeRuleDecision: String, Sendable {
    case record, admit, activate, invoke, suspend
    var button: String {
        switch self { case .record: "Record Screening"; case .admit: "Admit Draft"; case .activate: "Activate Admission"; case .invoke: "Stage Invocation"; case .suspend: "Suspend Policy" }
    }
}

@MainActor
final class NativeRuleViewModel: ObservableObject, CustomReflectable {
    nonisolated var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
    nonisolated private let client: NativeRulePanelClient
    private let journal: NativePendingCoordinator
    @Published var targetIDInput = "" { didSet { if oldValue != targetIDInput { edited() } } }
    @Published var on = true { didSet { if oldValue != on { edited() } } }
    @Published var confirmed = false
    @Published private(set) var sourceRevision: Int64 = 1
    @Published private(set) var busy = false
    @Published private(set) var status = "Draft one explicit Light power action, then review its screening or admission."
    @Published private(set) var currentDetail = "Refresh current policy to read its retained source."
    @Published private(set) var reviewDetail = ""
    @Published private(set) var decision: NativeRuleDecision?
    @Published private(set) var error: String?
    @Published private(set) var unconfirmed = false
    @Published private(set) var hasAdmission = false
    @Published private(set) var receiptOperationID = ""
    @Published private(set) var receiptEpoch: Int64 = 0
    private let ruleID = "rule:" + UUID().uuidString.lowercased()
    private struct Review: Sendable {
        let capture: LocalCredentialCapture, identity: HomeControllerIdentity
        let decision: NativeRuleDecision
        let rule: HomeExplicitPowerRule?
        let revision: Int64, admission: Int64, generation: Int64
        let maySubmit: Bool
    }
    private var review: Review?
    private var admissionHint: NativePendingEntry?
    private var pending: NativePendingOriginal?
    private var refusedOriginal: NativePendingEntry?
    var didChangeRules: (() -> Void)?
    var didStageInvocation: ((Int, String) -> Void)?
    init(client: NativeRulePanelClient = NativeRulePanelClient(), journal: NativePendingCoordinator = .shared) { self.client = client; self.journal = journal }
    var canReview: Bool { !busy && pending == nil && journal.canStart }
    var canSubmit: Bool { canReview && confirmed && review?.maySubmit == true }
    var canRecover: Bool { !busy && pending != nil && !journal.busy && !journal.needsReload }
    var canChangeSession: Bool { !busy && journal.canStart }
    private func edited() {
        if sourceRevision < Int64.max { sourceRevision += 1 }
        clearReview()
    }
    private func clearReview() { review = nil; decision = nil; reviewDetail = ""; confirmed = false }
    func invalidateSessionView() {
        if let scope = journal.owner, let context = pending?.entry.context,
           context.deployment != scope.deployment || context.owner != scope.owner || context.epoch != scope.epoch {
            pending = nil; unconfirmed = false
        }
        clearReview(); admissionHint = nil; hasAdmission = false
        currentDetail = "Refresh current policy under the selected session."
        receiptOperationID = ""; receiptEpoch = 0
    }
    func originalResolved(_ entry: NativePendingEntry) {
        if refusedOriginal != entry, case .explicitRule(let operation) = entry.input, operation.kind == "admit" {
            admissionHint = entry; hasAdmission = true
        }
        guard let original = pending?.entry, original.context == entry.context,
              original.custody == entry.custody, original.input == entry.input else { return }
        pending = nil; unconfirmed = false; clearReview(); didChangeRules?()
    }
    private nonisolated static func context(_ identity: HomeControllerIdentity) -> NativePendingContext {
        NativePendingContext(deployment: identity.deploymentID, owner: identity.ownerID, epoch: Int64(identity.authorityEpoch), principal: identity.principalID)
    }
    private nonisolated static func check(_ capture: LocalCredentialCapture, identity: HomeControllerIdentity) throws {
        guard capture.bytes.count == 32 else { throw LocalHealthError.invalidCredential }
        if let reference = capture.nativeReference {
            guard case .recover(let original) = try NativeBrokerWire.request(reference), original.valid,
                  original.receipt.role == .operator, original.verifier == capture.verifier,
                  context(identity).matches(identity), original.receipt.deployment == identity.deploymentID,
                  original.receipt.owner == identity.ownerID, original.receipt.epoch == identity.authorityEpoch,
                  original.receipt.principal == identity.principalID, identity.revision >= original.receipt.revision else { throw LocalHealthError.nativeGuardConflict }
        }
    }
    private nonisolated static func matches(_ current: HomeExplicitRuleCurrent, _ identity: HomeControllerIdentity) -> Bool {
        current.principal == identity.principalID && current.epoch == identity.authorityEpoch && current.revision >= identity.revision
    }
    func refreshCurrent() async {
        guard canReview else { return }
        busy = true; error = nil; clearReview(); defer { busy = false }
        do {
            let current = try await Task.detached {
                let capture = try self.client.capture(), identity = try self.client.identity(capture.bytes)
                try Self.check(capture, identity: identity)
                let current = try self.client.current(capture.bytes)
                guard Self.matches(current, identity) else { throw LocalHealthError.nativeGuardConflict }
                return current
            }.value
            if let rule = current.rule {
                currentDetail = "\(current.state.capitalized) · Generation \(current.generation)\n\(rule.target) · Power \(rule.on ? "On" : "Off") · Source version \(rule.sourceRevision)"
            } else { currentDetail = "Inactive · Generation \(current.generation)" }
            status = "Current policy read. Review a separate action before changing it."
        } catch { self.error = error.localizedDescription; status = "Current policy unavailable." }
    }
    func prepare(_ action: NativeRuleDecision) async {
        guard canReview else { return }
        let draft = HomeExplicitPowerRule(id: ruleID, sourceRevision: sourceRevision, target: targetIDInput, on: on)
        let hint = admissionHint
        if [.record, .admit].contains(action) && !draft.valid { return }
        if action == .activate && hint == nil { return }
        busy = true; error = nil; clearReview(); defer { busy = false }
        do {
            let prepared = try await Task.detached(priority: .userInitiated) {
                let capture = try self.client.capture(), identity = try self.client.identity(capture.bytes)
                try Self.check(capture, identity: identity)
                switch action {
                case .record, .admit:
                    let preview = try self.client.preview(capture.bytes, draft)
                    guard preview.rule == draft, preview.revision >= identity.revision else { throw LocalHealthError.invalidResponse }
                    let detail = "\(draft.target) · Power \(draft.on ? "On" : "Off") · Source version \(draft.sourceRevision)\nScreening: \(preview.decision.replacingOccurrences(of: "_", with: " "))\n\(preview.hasProposalBasis ? "Proposal basis is present. Admission is checked separately by Home." : "Screening supplies no admission or execution authority.")"
                    return (Review(capture: capture, identity: identity, decision: action, rule: draft, revision: preview.revision, admission: 0, generation: 0,
                        maySubmit: action == .record || (preview.decision == "pending_positive_basis" && preview.hasProposalBasis)), detail)
                case .activate:
                    guard let hint, hint.context.matches(identity), hint.custody.matches(capture.bytes),
                          case .explicitRule(let original) = hint.input, original.kind == "admit",
                          let rule = original.rule else { throw LocalHealthError.sessionChanged }
                    if case .native = hint.custody {
                        guard capture.nativeReference == (try NativeBrokerWire.request(.recover(hint.custody.nativeOriginal(context: hint.context)))) else { throw LocalHealthError.sessionChanged }
                    } else { guard capture.nativeReference == nil else { throw LocalHealthError.sessionChanged } }
                    let result = try self.client.deliver(capture.bytes, original, identity.principalID, true)
                    try result.verify(original: original, principal: identity.principalID)
                    guard case .admission(let admission) = result.receipt, identity.revision >= admission.revision else { throw LocalHealthError.invalidResponse }
                    let policy = try self.client.status(capture.bytes)
                    guard policy.authorityEpoch == identity.authorityEpoch else { throw LocalHealthError.nativeGuardConflict }
                    let detail = "Activate the retained admission for \(rule.target) · Power \(rule.on ? "On" : "Off").\nReplace generation \(policy.generation) with this one explicit action. Unsent work is fenced; handed-off outcomes can remain uncertain."
                    return (Review(capture: capture, identity: identity, decision: action, rule: rule, revision: Int64(identity.revision), admission: Int64(admission.revision), generation: 0, maySubmit: true), detail)
                case .invoke:
                    let current = try self.client.current(capture.bytes)
                    guard Self.matches(current, identity), current.state == "active", let rule = current.rule else { throw LocalHealthError.server("rule_basis_changed") }
                    let detail = "Stage \(rule.target) · Power \(rule.on ? "On" : "Off") from generation \(current.generation).\nThis creates one ordinary request. Its receipt does not establish a device effect."
                    return (Review(capture: capture, identity: identity, decision: action, rule: rule, revision: current.revision, admission: current.admissionRevision, generation: current.generation, maySubmit: true), detail)
                case .suspend:
                    let policy = try self.client.status(capture.bytes)
                    guard policy.authorityEpoch == identity.authorityEpoch else { throw LocalHealthError.nativeGuardConflict }
                    return (Review(capture: capture, identity: identity, decision: action, rule: nil, revision: Int64(identity.revision), admission: 0, generation: 0, maySubmit: true),
                        "Suspend generation \(policy.generation). Unsent work is fenced; this cannot recall a packet already handed off.")
                }
            }.value
            if action == .record || action == .admit {
                guard draft.sourceRevision == sourceRevision && draft.target == targetIDInput && draft.on == on else { throw LocalHealthError.sessionChanged }
            }
            review = prepared.0; decision = action; reviewDetail = prepared.1
            status = prepared.0.maySubmit ? "Confirm this reviewed decision before submitting it." : "This draft cannot be admitted. Screening can still be recorded."
        } catch { self.error = error.localizedDescription; status = "Rule review unavailable." }
    }
    func submit() async {
        guard canSubmit, let review else { return }
        busy = true; error = nil; defer { busy = false }
        do {
            let operation = "rule:" + UUID().uuidString.lowercased(), epoch = Int64(review.identity.authorityEpoch)
            let input: HomeExplicitRuleOperation
            switch review.decision {
            case .record: guard let rule = review.rule else { throw NativePendingError.invalidRecord }; input = .review(epoch: epoch, operation: operation, expected: review.revision, rule: rule)
            case .admit: guard let rule = review.rule else { throw NativePendingError.invalidRecord }; input = .admit(epoch: epoch, operation: operation, expected: review.revision, rule: rule)
            case .activate, .suspend: input = .activate(epoch: epoch, operation: operation, expected: review.revision, admission: review.admission)
            case .invoke: guard let rule = review.rule else { throw NativePendingError.invalidRecord }; input = .invoke(epoch: epoch, operation: operation, generation: review.generation, ruleID: rule.id)
            }
            let original = try await journal.begin(.explicitRule(input), authorityEpoch: Int(epoch), expectedCredential: review.capture.bytes, expectedNativeReference: review.capture.nativeReference, expectedController: review.identity, expectedCapture: review.capture)
            pending = original; unconfirmed = true; confirmed = false
            let result = try await Task.detached { try self.client.deliver(original.bytes, input, original.entry.context.principal, false) }.value
            try await accept(result, original: original)
        } catch {
            if case LocalHealthError.server(let reason) = error, Self.definiteRefusals.contains(reason), let original = pending {
                refusedOriginal = original.entry
                defer { refusedOriginal = nil }
                do { try await journal.resolving(original); originalResolved(original.entry); status = "Rule operation refused. Review the current state before another decision." }
                catch { status = "Original resolution unconfirmed. Reload pending operations." }
            } else { status = "Rule operation unconfirmed. Recover its original input." }
            self.error = error.localizedDescription
        }
    }
    func recover(lookup: Bool) async {
        guard canRecover, let pending else { return }
        busy = true; error = nil; defer { busy = false }
        do {
            let original = try journal.currentOriginal(pending), input = try original.entry.ruleOperation()
            let result = try await Task.detached { try self.client.deliver(original.bytes, input, original.entry.context.principal, lookup) }.value
            try await accept(result, original: original)
        } catch { self.error = error.localizedDescription; status = "Original recovery unconfirmed. Its input remains retained." }
    }
    private func accept(_ result: HomeExplicitRuleResult, original: NativePendingOriginal) async throws {
        try result.verify(original: original.entry.ruleOperation(), principal: original.entry.context.principal)
        if case .notFound = result.receipt { status = "No original result confirmed. Look up or retry this retained request."; return }
        try await journal.resolving(original)
        originalResolved(original.entry)
        switch result.receipt {
        case .review(let review): status = "Screening recorded: \(review.decision.replacingOccurrences(of: "_", with: " ")). Review admission separately; screening grants no execution authority."
        case .admission(let admission): status = "Restricted admission confirmed at revision \(admission.revision). Review activation separately."
        case .activation(let activation): status = activation.admissionRevision == 0 ? "Policy suspended at generation \(activation.generation)." : "Generation \(activation.generation) activated. Review invocation separately."
        case .invocation(let request):
            receiptOperationID = original.entry.input.operationID; receiptEpoch = original.entry.context.epoch
            didStageInvocation?(Int(receiptEpoch), receiptOperationID)
            status = "Invocation is \(request.disposition) at revision \(request.revision). Read observations to establish device state."
        case .notFound: break
        }
    }
    private nonisolated static let definiteRefusals: Set<String> = ["permission_denied", "unauthorized", "invalid_credential", "invalid_rule_operation", "invalid_rule_review_operation", "unsupported_admission_profile", "resnapshot_required", "stale_authority_epoch", "stale_rule_generation", "rule_operation_conflict", "rule_review_operation_conflict", "rule_review_capacity", "rule_admission_capacity", "rule_activation_capacity", "maintenance_active", "review_scope_unavailable", "review_basis_changed", "rule_basis_changed", "invariant_unresolved", "operator_override_active"]
}

struct NativeRulePanel: View {
    @ObservedObject var rules: NativeRuleViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Explicit rules").font(.headline)
            Text(rules.status).font(.callout).fixedSize(horizontal: false, vertical: true)
            TextField("Enrolled Light ID", text: $rules.targetIDInput).textFieldStyle(.roundedBorder).disabled(!rules.canReview)
            Toggle("Set Power On", isOn: $rules.on).toggleStyle(.switch).disabled(!rules.canReview)
            HStack {
                Button("Review Screening") { Task { await rules.prepare(.record) } }
                Button("Review Admission") { Task { await rules.prepare(.admit) } }
            }.disabled(!rules.canReview)
            HStack {
                Button("Review Activation") { Task { await rules.prepare(.activate) } }.disabled(!rules.canReview || !rules.hasAdmission)
                Button("Review Invocation") { Task { await rules.prepare(.invoke) } }
                Button("Review Suspension") { Task { await rules.prepare(.suspend) } }
            }.disabled(!rules.canReview)
            if let decision = rules.decision {
                Text(rules.reviewDetail).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Toggle("I reviewed this rule decision", isOn: $rules.confirmed).disabled(!rules.canReview)
                Button(decision.button) { Task { await rules.submit() } }.disabled(!rules.canSubmit)
            }
            if rules.unconfirmed {
                HStack {
                    Button("Look Up Original Rule") { Task { await rules.recover(lookup: true) } }
                    Button("Retry Original Rule") { Task { await rules.recover(lookup: false) } }
                }.disabled(!rules.canRecover)
            }
            Divider()
            Text(rules.currentDetail).font(.callout).fixedSize(horizontal: false, vertical: true)
            if !rules.receiptOperationID.isEmpty { Text("Request \(rules.receiptOperationID) · Authority \(rules.receiptEpoch)").font(.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            Button("Refresh Current Rule") { Task { await rules.refreshCurrent() } }.disabled(!rules.canReview)
            if let error = rules.error { Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            Text("This profile supports one explicit power action. Screening, admission, activation, staging and observed state are separate. Device dispatch requires its own qualification.")
                .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
