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
                    HStack {
                        Button("Look Up Original") { recover(entry, .lookup) }
                        if NativePendingRecoveryAction.retry.permits(entry) {
                            Button("Retry Original") { recover(entry, .retry) }
                        }
                        if NativePendingRecoveryAction.cancelReview.permits(entry) {
                            Button("Cancel Original Review") { recover(entry, .cancelReview) }
                        }
                    }.disabled(!recoveryAllowed || journal.busy || journal.needsReload)
                }
            }
            if !journal.entries.isEmpty {
                Text("Recovery opens existing custody and checks the original controller and principal. Each action uses the recorded request. A missing result leaves the original retained.")
                    .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
    private func recover(_ entry: NativePendingEntry, _ action: NativePendingRecoveryAction) {
        Task { await journal.recover(entry, action: action, custody: { entry in
            switch entry.custody {
            case .manual(let verifier): return try OperatorCredential.recoverOriginalManual(verifier: verifier)
            case .native: return try NativeBrokerClient.recover(original: entry.custody.nativeOriginal(context: entry.context)).bytes
            }
        }, execute: NativePendingRecoveryOperations.execute) }
    }
}
