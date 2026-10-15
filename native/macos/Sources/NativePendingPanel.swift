import SwiftUI

@MainActor
private final class NativePendingConfirmation: ObservableObject {
    @Published var entry: NativePendingEntry?
}

struct NativePendingPanel: View {
    @ObservedObject var journal: NativePendingCoordinator
    var recoveryAllowed: Bool
    var pairedRecover: ((NativePendingEntry, NativePendingRecoveryAction) async -> Void)? = nil
    @StateObject private var confirmation = NativePendingConfirmation()
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
                    Text("Authority \(entry.context.epoch) · \(entry.category == .generation ? "Original status needs confirmation" : phase(entry.phase))").font(.caption).foregroundStyle(.secondary)
                    if let detail = detail(entry) { Text(detail).font(.callout).fixedSize(horizontal: false, vertical: true) }
                    if entry.category == .generation {
                        Text("Generation original · Recovery uses retained bytes; reservation is separate from draft completion").font(.caption).foregroundStyle(.secondary)
                    }
                    if entry.category == .authoring {
                        Text("Authoring original · Lookup and retry use its retained bytes").font(.caption).foregroundStyle(.secondary)
                    }
                    if entry.custody.isPaired {
                        Text(pairedRecover == nil ? "Paired controller original · Remote recovery unavailable" : "Paired controller original · Recovery uses its recorded controller")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack { recoveryControls(entry) }
                        VStack(alignment: .leading) { recoveryControls(entry) }
                    }.disabled((entry.custody.isPaired && pairedRecover == nil) || !recoveryAllowed || journal.busy || journal.needsReload)
                }
            }
            if !journal.entries.isEmpty {
                Text("Recovery opens existing custody and checks the original controller and principal. Each action uses the recorded request. A missing result leaves the original retained.")
                    .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .confirmationDialog("Clear if the original generation outcome is unknown?",
            isPresented: Binding(get: { confirmation.entry != nil }, set: { if !$0 { confirmation.entry = nil } }),
            presenting: confirmation.entry) { entry in
                Button("Acknowledge Unknown Outcome") { recover(entry, .acknowledgeUnknown); confirmation.entry = nil }
                Button("Keep Original", role: .cancel) { confirmation.entry = nil }
            } message: { _ in
                Text("This clears the pending record only after checking an unknown outcome. A model may still be working, and a result may appear later. No new attempt is sent.")
            }
    }
    private func recoveryControls(_ entry: NativePendingEntry) -> some View {
        Group {
            Button("Look Up Original") { recover(entry, .lookup) }.disabled(!NativePendingRecoveryAction.lookup.permits(entry))
            if NativePendingRecoveryAction.retry.permits(entry) {
                Button("Retry Original") { recover(entry, .retry) }
            }
            if NativePendingRecoveryAction.cancelReview.permits(entry) {
                Button("Cancel Original Review") { recover(entry, .cancelReview) }
            }
            if NativePendingRecoveryAction.acknowledgeUnknown.permits(entry) {
                Button("Acknowledge Unknown Outcome…") { confirmation.entry = entry }
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
        case .generation(let original): return "Retained generation \(original.kind.rawValue) · Submission unconfirmed"
        case .authoring(let original, _): return "Retained authoring \(original.kind.rawValue) · Store basis \(original.expectedRevision) · Input SHA \(original.sha)"
        default: return nil
        }
    }
    private func recover(_ entry: NativePendingEntry, _ action: NativePendingRecoveryAction) {
        if entry.custody.isPaired {
            if let pairedRecover { Task { await pairedRecover(entry, action) } }
            return
        }
        Task { await journal.recover(entry, action: action, custody: { entry in
            switch entry.custody {
            case .manual(let verifier): return try OperatorCredential.recoverOriginalManual(verifier: verifier)
            case .native: return try NativeBrokerClient.recover(original: entry.custody.nativeOriginal(context: entry.context)).bytes
            case .paired: throw NativePendingError.unavailable
            }
        }, execute: NativePendingRecoveryOperations.execute) }
    }
}
