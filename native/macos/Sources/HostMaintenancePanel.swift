import Foundation
import SwiftUI

@MainActor
final class MaintenanceViewModel: ObservableObject {
    @Published var authorityEpochInput = ""
    @Published var operationIDInput = ""
    @Published private(set) var busy = false
    @Published private(set) var current: HomeMaintenanceStatus?
    @Published private(set) var statusDetail = "No maintenance status yet"
    @Published private(set) var receiptDetail = "No maintenance operation selected"
    @Published private(set) var error: String?
    @Published private(set) var hasUnconfirmedOperation = false

    private struct PendingChange: Sendable {
        let credential: Data
        let authorityEpoch: Int
        let operationID: String
        let expectedRevision: Int
        let beginRevision: Int
    }
    private var pending: PendingChange?

    var canBegin: Bool { !busy && !hasUnconfirmedOperation && current?.state == "normal" }
    var canEnd: Bool { !busy && !hasUnconfirmedOperation && current?.state == "maintenance" }

    func refresh() {
        guard !busy else { return }
        busy = true
        error = nil
        current = nil
        Task {
            do {
                let status = try await Task.detached(priority: .userInitiated) {
                    try LocalHealthClient.fetchMaintenanceStatus()
                }.value
                current = status
                let state = status.state == "maintenance" ? "Maintenance active" : "Accepting new requests"
                statusDetail = "\(state) · Revision \(status.storeRevision) · Authority \(status.authorityEpoch) · Generation \(status.generation)"
                if status.beginRevision > 0 { statusDetail += " · Begin revision \(status.beginRevision)" }
            } catch {
                statusDetail = "Maintenance status unavailable"
                self.error = error.localizedDescription
            }
            busy = false
        }
    }

    func begin() { change(begin: true) }
    func end() { change(begin: false) }

    private func change(begin: Bool) {
        guard (begin ? canBegin : canEnd), let status = current else { return }
        let operation = "maintenance:" + UUID().uuidString.lowercased()
        authorityEpochInput = String(status.authorityEpoch)
        operationIDInput = operation
        busy = true
        error = nil
        invalidateStatus()
        Task {
            do {
                let credential = try await Task.detached(priority: .userInitiated) {
                    try OperatorCredential.load()
                }.value
                let change = PendingChange(credential: credential, authorityEpoch: status.authorityEpoch,
                    operationID: operation, expectedRevision: status.storeRevision,
                    beginRevision: begin ? 0 : status.beginRevision)
                pending = change
                hasUnconfirmedOperation = true
                await perform(change, recovering: false)
            } catch {
                receiptDetail = "Maintenance request could not be sent"
                self.error = error.localizedDescription
            }
            busy = false
        }
    }

    func retryOriginal() {
        guard !busy, let change = pending else { return }
        authorityEpochInput = String(change.authorityEpoch)
        operationIDInput = change.operationID
        busy = true
        error = nil
        invalidateStatus()
        Task {
            await perform(change, recovering: true)
            busy = false
        }
    }

    private func perform(_ change: PendingChange, recovering: Bool) async {
        receiptDetail = "Submitting \(change.operationID)…"
        do {
            let receipt = try await Task.detached(priority: .userInitiated) {
                if change.beginRevision == 0 {
                    return try LocalHealthClient.beginMaintenance(credential: change.credential,
                        authorityEpoch: change.authorityEpoch, operationID: change.operationID,
                        expectedRevision: change.expectedRevision)
                }
                return try LocalHealthClient.endMaintenance(credential: change.credential,
                    authorityEpoch: change.authorityEpoch, operationID: change.operationID,
                    expectedRevision: change.expectedRevision, beginRevision: change.beginRevision)
            }.value
            receiptDetail = summary(receipt)
            pending = nil
            hasUnconfirmedOperation = false
        } catch {
            if !recovering, case LocalHealthError.server(let reason) = error, reason != "outcome_unknown" {
                receiptDetail = "Host rejected \(change.operationID)"
                pending = nil
                hasUnconfirmedOperation = false
            } else {
                receiptDetail = "Not confirmed · Authority \(change.authorityEpoch) · \(change.operationID). Look up or retry this original operation."
            }
            self.error = error.localizedDescription
        }
    }

    func lookup() {
        guard !busy else { return }
        let operation = operationIDInput
        guard let epoch = Int(authorityEpochInput), epoch >= 1 else {
            error = LocalHealthError.invalidMaintenanceRequest.localizedDescription
            return
        }
        // Resolve a pending request under its original credential even after another import.
        let original = pending.flatMap {
            $0.authorityEpoch == epoch && $0.operationID == operation ? $0 : nil
        }
        busy = true
        error = nil
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    let credential = try original?.credential ?? OperatorCredential.load()
                    return try LocalHealthClient.fetchMaintenanceOperationStatus(credential: credential,
                        authorityEpoch: epoch, operationID: operation)
                }.value
                switch result {
                case .found(let receipt):
                    receiptDetail = summary(receipt)
                    if original != nil {
                        pending = nil
                        hasUnconfirmedOperation = false
                        invalidateStatus()
                    }
                case .notFound:
                    receiptDetail = "No maintenance receipt for \(operation) in authority \(epoch)."
                    if original != nil { receiptDetail += " Retry the original operation to resolve it." }
                }
            } catch {
                receiptDetail = "Maintenance operation status unavailable"
                self.error = error.localizedDescription
            }
            busy = false
        }
    }

    private func invalidateStatus() {
        current = nil
        statusDetail = "Refresh maintenance status before another change."
    }

    private func summary(_ receipt: HomeMaintenanceReceipt) -> String {
        let action = receipt.action == "begin" ? "Maintenance began" : "Maintenance ended"
        return "\(action) at revision \(receipt.revision) · Begin \(receipt.beginRevision) · Generation \(receipt.generation) · " +
            "\(receipt.affectedRequests) affected requests · \(receipt.unknownOutcomes) unknown outcomes at that barrier · \(receipt.operationID)"
    }
}

struct HostMaintenancePanel: View {
    @StateObject private var maintenance = MaintenanceViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Host maintenance").font(.headline)
            Text(maintenance.statusDetail).font(.callout).textSelection(.enabled)
            HStack {
                Button("Refresh Maintenance Status") { maintenance.refresh() }
                    .disabled(maintenance.busy)
                Button("Begin Maintenance") { maintenance.begin() }
                    .disabled(!maintenance.canBegin)
                Button("End Maintenance") { maintenance.end() }
                    .disabled(!maintenance.canEnd)
                if maintenance.hasUnconfirmedOperation {
                    Button("Retry Original") { maintenance.retryOriginal() }
                        .disabled(maintenance.busy)
                }
            }
            HStack {
                TextField("Authority epoch", text: $maintenance.authorityEpochInput).frame(width: 150)
                TextField("Maintenance operation ID", text: $maintenance.operationIDInput)
                Button("Look Up") { maintenance.lookup() }
                    .disabled(maintenance.busy || maintenance.operationIDInput.isEmpty)
            }
            Text(maintenance.receiptDetail).font(.callout).textSelection(.enabled)
            if let error = maintenance.error { Text(error).foregroundStyle(.red) }
            Text("A maintenance credential is required. Begin suspends rules and blocks new requests across restart; already handed-off effects remain uncertain. End permits new requests and leaves rules suspended. Receipt counts describe the original barrier. Refresh status to see the current state.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}
