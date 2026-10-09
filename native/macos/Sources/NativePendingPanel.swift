import SwiftUI

struct NativePendingPanel: View {
    @ObservedObject var journal: NativePendingCoordinator
    var recoveryAllowed: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pending operations").font(.headline)
            Text(journal.status).font(.callout).fixedSize(horizontal: false, vertical: true)
            if let error = journal.error { Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            if journal.needsReload {
                Button("Reload Original Records") { Task { await journal.reload() } }.disabled(journal.busy)
            }
            ForEach(Array(journal.entries.enumerated()), id: \.offset) { _, entry in
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(entry.category.rawValue.capitalized) · \(entry.input.operationID)").font(.callout).textSelection(.enabled)
                    Text("Authority \(entry.context.epoch) · \(phase(entry.phase))").font(.caption).foregroundStyle(.secondary)
                    if let detail = detail(entry) { Text(detail).font(.callout).fixedSize(horizontal: false, vertical: true) }
                    if entry.custody.isPaired {
                        Text("Paired controller original · Remote recovery unavailable").font(.caption).foregroundStyle(.secondary)
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack { recoveryControls(entry) }
                        VStack(alignment: .leading) { recoveryControls(entry) }
                    }.disabled(entry.custody.isPaired || !recoveryAllowed || journal.busy || journal.needsReload)
                }
            }
            if !journal.entries.isEmpty {
                Text("Recovery opens existing custody and checks the original controller and principal. Each action uses the recorded request. A missing result leaves the original retained.")
                    .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private func recoveryControls(_ entry: NativePendingEntry) -> some View {
        Group {
            Button("Look Up Original") { recover(entry, .lookup) }
            if NativePendingRecoveryAction.retry.permits(entry) {
                Button("Retry Original") { recover(entry, .retry) }
            }
            if NativePendingRecoveryAction.cancelReview.permits(entry) {
                Button("Cancel Original Review") { recover(entry, .cancelReview) }
            }
        }
    }
    private func phase(_ value: NativePendingPhase) -> String {
        switch value {
        case .pending: "Submission unconfirmed"
        case .review: "Held review; lookup or cancellation available"
        case .commitPending: "Commit intent retained"
        case .cancelPending: "Cancellation intent retained"
        }
    }
    private func detail(_ entry: NativePendingEntry) -> String? {
        switch entry.input {
        case .power(_, let target, let revision, let on):
            return "Retained power \(on ? "On" : "Off") for \(target) · Resource \(revision)"
        case .cancel:
            return "Retained cancellation of the original power request"
        case .schedule(let operation):
            if let source = operation.source {
                let decision = operation.kind == "review" ? "screening" : "admission"
                return "Retained schedule \(decision) for \(source.rule.target) · Power \(source.rule.on ? "On" : "Off") · Source version \(source.sourceRevision)"
            }
            if case .activate(_, _, _, let admission) = operation { return "Retained schedule activation of admission \(admission)" }
            return "Retained schedule suspension"
        case .explicitRule(let operation):
            switch operation {
            case .review(_, _, _, let rule): return "Retained screening for \(rule.target) · Power \(rule.on ? "On" : "Off") · Source version \(rule.sourceRevision)"
            case .admit(_, _, _, let rule): return "Retained admission for \(rule.target) · Power \(rule.on ? "On" : "Off") · Source version \(rule.sourceRevision)"
            case .activate(_, _, _, let admission): return admission == 0 ? "Retained policy suspension" : "Retained activation of admission \(admission)"
            case .invoke(_, _, let generation, let rule): return "Retained invocation of \(rule) · Generation \(generation)"
            }
        case .targetAccess(_, _, let target, let action, _): return "Retained access \(action.rawValue) for \(target)"
        default: return nil
        }
    }
    private func recover(_ entry: NativePendingEntry, _ action: NativePendingRecoveryAction) {
        Task { await journal.recover(entry, action: action, custody: { entry in
            switch entry.custody {
            case .manual(let verifier): return try OperatorCredential.recoverOriginalManual(verifier: verifier)
            case .native: return try NativeBrokerClient.recover(original: entry.custody.nativeOriginal(context: entry.context)).bytes
            case .paired: throw NativePendingError.unavailable
            }
        }, execute: NativePendingRecoveryOperations.execute) }
    }
}
