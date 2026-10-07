import Foundation
import SwiftUI

@MainActor
final class MaintenanceViewModel: ObservableObject, CustomReflectable {
    nonisolated var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
    nonisolated private let credentialLoader: @Sendable () throws -> Data
    nonisolated private let socketPath: @Sendable () -> String
    let journal: NativePendingCoordinator
    init(credentialLoader: @escaping @Sendable () throws -> Data = { try OperatorCredential.load() },
         socketPath: @escaping @Sendable () -> String = { LocalHealthClient.defaultSocketPath() },
         journal: NativePendingCoordinator = .shared) {
        self.credentialLoader = credentialLoader; self.socketPath = socketPath; self.journal = journal
    }
    @Published var authorityEpochInput = ""
    @Published var operationIDInput = ""
    @Published private(set) var busy = false
    @Published private(set) var current: HomeMaintenanceStatus?
    @Published private(set) var statusDetail = "No maintenance status yet"
    @Published private(set) var receiptDetail = "No maintenance operation selected"
    @Published private(set) var error: String?
    @Published private(set) var hasUnconfirmedOperation = false
    private var snapshotCredential: Data?

    private struct PendingChange: Sendable {
        let original: NativePendingOriginal
        let expectedRevision: Int
        let beginRevision: Int
        var credential: Data { original.bytes }
        var authorityEpoch: Int { Int(original.entry.context.epoch) }
        var operationID: String { original.entry.input.operationID }
        func matches(_ receipt: HomeMaintenanceReceipt) -> Bool {
            guard receipt.principalID == original.entry.context.principal,
                  receipt.authorityEpoch == authorityEpoch, receipt.operationID == operationID else { return false }
            if beginRevision == 0 {
                return receipt.action == "begin" && receipt.revision > expectedRevision &&
                    receipt.revision - expectedRevision == receipt.affectedRequests + 2
            }
            return receipt.action == "end" && receipt.beginRevision == beginRevision && receipt.revision == expectedRevision + 1
        }
    }
    private var pending: PendingChange?

    var canBegin: Bool { journal.canStart && !busy && !hasUnconfirmedOperation && current?.state == "normal" && snapshotCredential != nil }
    var canEnd: Bool { journal.canStart && !busy && !hasUnconfirmedOperation && current?.state == "maintenance" && snapshotCredential != nil }
    private var hasCurrentPendingMemory: Bool {
        guard let pending else { return false }
        guard let owner = journal.owner else { return true }
        let context = pending.original.entry.context
        return context.deployment == owner.deployment && context.owner == owner.owner && context.epoch == owner.epoch
    }
    var canChangeSession: Bool { !busy && !hasCurrentPendingMemory && journal.canStart }
    func originalResolved(_ entry: NativePendingEntry) {
        guard let original = pending?.original.entry, original.context == entry.context,
              original.custody == entry.custody, original.input == entry.input else { return }
        pending = nil; hasUnconfirmedOperation = false; invalidateStatus()
    }
    func invalidateSessionView() {
        if let owner = journal.owner, let change = pending {
            let context = change.original.entry.context
            if context.deployment != owner.deployment || context.owner != owner.owner || context.epoch != owner.epoch {
                pending = nil; hasUnconfirmedOperation = false // Its original stays in the private journal.
            }
        }
        invalidateStatus()
    }

    func refresh() {
        guard !busy else { return }
        busy = true; error = nil; current = nil; snapshotCredential = nil
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    let credential = try self.credentialLoader()
                    return (try LocalHealthClient.fetchMaintenanceStatus(socketPath: self.socketPath(), credential: credential), credential)
                }.value
                let status = result.0
                current = status; snapshotCredential = result.1
                let state = status.state == "maintenance" ? "Maintenance active" : "Accepting new requests"
                statusDetail = "\(state) · Revision \(status.storeRevision) · Authority \(status.authorityEpoch) · Generation \(status.generation)"
                if status.beginRevision > 0 { statusDetail += " · Begin revision \(status.beginRevision)" }
            } catch { statusDetail = "Maintenance status unavailable"; self.error = error.localizedDescription }
            busy = false
        }
    }

    func begin() { change(begin: true) }
    func end() { change(begin: false) }
    private func change(begin: Bool) {
        guard (begin ? canBegin : canEnd), let status = current, let credential = snapshotCredential else { return }
        let operation = "maintenance:" + UUID().uuidString.lowercased()
        authorityEpochInput = String(status.authorityEpoch); operationIDInput = operation
        busy = true; error = nil; invalidateStatus()
        Task {
            do {
                let input: NativePendingInput = begin ? .beginMaintenance(operation: operation, revision: Int64(status.storeRevision)) :
                    .endMaintenance(operation: operation, revision: Int64(status.storeRevision), beginRevision: Int64(status.beginRevision))
                let original = try await journal.begin(input, authorityEpoch: status.authorityEpoch, expectedCredential: credential)
                let change = PendingChange(original: original, expectedRevision: status.storeRevision, beginRevision: begin ? 0 : status.beginRevision)
                pending = change; hasUnconfirmedOperation = true
                await perform(change, recovering: false)
            } catch { receiptDetail = "Maintenance request could not be sent"; self.error = error.localizedDescription }
            busy = false
        }
    }
    func retryOriginal() {
        guard !busy, !journal.busy, !journal.needsReload, let change = pending else { return }
        authorityEpochInput = String(change.authorityEpoch); operationIDInput = change.operationID
        busy = true; error = nil; invalidateStatus()
        Task { await perform(change, recovering: true); busy = false }
    }
    private func resolve(_ change: PendingChange) async throws {
        try await journal.resolving(change.original)
        pending = nil; hasUnconfirmedOperation = false
    }
    private func perform(_ change: PendingChange, recovering: Bool) async {
        receiptDetail = "Submitting \(change.operationID)…"
        do {
            let receipt = try await Task.detached(priority: .userInitiated) {
                if change.beginRevision == 0 {
                    return try LocalHealthClient.beginMaintenance(socketPath: self.socketPath(), credential: change.credential,
                        authorityEpoch: change.authorityEpoch, operationID: change.operationID, expectedRevision: change.expectedRevision)
                }
                return try LocalHealthClient.endMaintenance(socketPath: self.socketPath(), credential: change.credential,
                    authorityEpoch: change.authorityEpoch, operationID: change.operationID,
                    expectedRevision: change.expectedRevision, beginRevision: change.beginRevision)
            }.value
            guard change.matches(receipt) else { throw LocalHealthError.invalidResponse }
            try await resolve(change)
            receiptDetail = summary(receipt)
        } catch {
            if !recovering, case LocalHealthError.server(let reason) = error, reason != "outcome_unknown" {
                do { try await resolve(change); receiptDetail = "Host rejected \(change.operationID)" }
                catch { receiptDetail = "Original rejection retained; journal resolution is not confirmed."; self.error = error.localizedDescription; return }
            } else {
                receiptDetail = "Not confirmed · Authority \(change.authorityEpoch) · \(change.operationID). Look up or retry this original operation."
            }
            self.error = error.localizedDescription
        }
    }
    func lookup() {
        guard !busy else { return }
        let operation = operationIDInput
        guard let epoch = Int(authorityEpochInput), epoch >= 1 else { error = LocalHealthError.invalidMaintenanceRequest.localizedDescription; return }
        let original = pending.flatMap { $0.authorityEpoch == epoch && $0.operationID == operation ? $0 : nil }
        busy = true; error = nil
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    let credential = try original?.credential ?? self.credentialLoader()
                    return try LocalHealthClient.fetchMaintenanceOperationStatus(socketPath: self.socketPath(), credential: credential,
                        authorityEpoch: epoch, operationID: operation)
                }.value
                switch result {
                case .found(let receipt):
                    if let original {
                        guard original.matches(receipt) else { throw LocalHealthError.invalidResponse }
                        try await resolve(original); invalidateStatus()
                    }
                    receiptDetail = summary(receipt)
                case .notFound:
                    receiptDetail = "No maintenance receipt for \(operation) in authority \(epoch)."
                    if original != nil { receiptDetail += " Retry the original operation to resolve it." }
                }
            } catch { receiptDetail = "Maintenance operation status unavailable"; self.error = error.localizedDescription }
            busy = false
        }
    }
    private func invalidateStatus() { current = nil; snapshotCredential = nil; statusDetail = "Refresh maintenance status before another change." }
    private func summary(_ receipt: HomeMaintenanceReceipt) -> String {
        let action = receipt.action == "begin" ? "Maintenance began" : "Maintenance ended"
        return "\(action) at revision \(receipt.revision) · Begin \(receipt.beginRevision) · Generation \(receipt.generation) · " +
            "\(receipt.affectedRequests) affected requests · \(receipt.unknownOutcomes) unknown outcomes at that barrier · \(receipt.operationID)"
    }
}

struct HostMaintenancePanel: View {
    @StateObject private var maintenance: MaintenanceViewModel
    @ObservedObject private var journal: NativePendingCoordinator
    init(maintenance: MaintenanceViewModel = MaintenanceViewModel()) {
        _maintenance = StateObject(wrappedValue: maintenance)
        _journal = ObservedObject(wrappedValue: maintenance.journal)
    }

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
