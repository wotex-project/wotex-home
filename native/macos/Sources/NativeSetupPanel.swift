import SwiftUI

extension NativeCustodyRole {
    var title: String {
        switch self {
        case .diagnostic: "Diagnostic"
        case .operator: "Operator"
        case .maintenance: "Maintenance"
        case .transfer: "Transfer"
        }
    }
    var explanation: String {
        switch self {
        case .diagnostic: "Read Home diagnostics."
        case .operator: "Review devices, profiles and rules; manage Home. Device access needs a separate grant."
        case .maintenance: "Read diagnostics and enter or leave maintenance."
        case .transfer: "Authorize explicit controller transfer. This role cannot read ordinary health or control devices."
        }
    }
}

@MainActor
final class NativeSetupViewModel: ObservableObject {
    @Published var role: NativeCustodyRole = .diagnostic
    @Published private(set) var busy = false
    @Published private(set) var status = "No setup check yet"
    @Published private(set) var session = "Manual credential mode"
    @Published private(set) var error: String?
    @Published private(set) var scope: NativeControllerScope?
    @Published private(set) var receipt: NativeCreationReceipt?
    var selectionChanged: (() -> Void)?
    var changesAllowed: () -> Bool = { true }

    func refresh() {
        guard !busy, changesAllowed() else { return }
        busy = true; error = nil
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) { try NativeBrokerClient.status() }.value
                scope = result
                status = "Controller available · Authority \(result.epoch) · Revision \(result.revision)"
                if let receipt, receipt.deployment != result.deployment || receipt.owner != result.owner || receipt.epoch != result.epoch {
                    OperatorCredential.endNativeSession()
                    self.receipt = nil
                    session = "Authority changed · Select a new session"
                    selectionChanged?()
                }
            } catch { status = "Setup unavailable"; self.error = error.localizedDescription }
            busy = false
        }
    }

    func select() {
        guard !busy, changesAllowed() else { return }
        let requested = role
        busy = true; error = nil
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) { try NativeBrokerClient.credential(role: requested) }.value
                try OperatorCredential.selectNative(result.bytes)
                receipt = result.receipt
                scope = nil // The original creation receipt is not a current Store watermark.
                session = "\(requested.title) session · Authority \(result.receipt.epoch)"
                status = "Session selected"
                selectionChanged?()
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }

    func endSession() {
        guard !busy, changesAllowed() else { return }
        OperatorCredential.endNativeSession()
        session = "No credential selected"; scope = nil; receipt = nil; error = nil
        selectionChanged?()
    }

    func selectManual() {
        guard !busy, changesAllowed() else { return }
        OperatorCredential.selectManual()
        session = "Manual credential mode"; scope = nil; receipt = nil; error = nil
        selectionChanged?()
    }

    func manualImported() {
        session = "Manual credential mode"; scope = nil; receipt = nil; error = nil
        selectionChanged?()
    }
}

struct NativeSetupPanel: View {
    @ObservedObject var setup: NativeSetupViewModel
    var changesAllowed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Home session").font(.headline)
            Text(setup.session)
            Text(setup.status).font(.callout).foregroundStyle(.secondary)
            HStack {
                Picker("Role", selection: $setup.role) {
                    ForEach(NativeCustodyRole.allCases, id: \.self) { Text($0.title).tag($0) }
                }.frame(maxWidth: 260)
                Button("Select Session") { setup.select() }
                Button("Check Setup") { setup.refresh() }
                Button("End Session") { setup.endSession() }
                Button("Use Manual Credential") { setup.selectManual() }
            }.disabled(setup.busy || !changesAllowed)
            Text(setup.role.explanation).font(.callout).fixedSize(horizontal: false, vertical: true)
            if !changesAllowed {
                Text("Resolve the pending operation or review before changing sessions.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Text("Native sessions stay in this app until it closes. Registration, session selection and device permission are separate steps.")
                .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error = setup.error { Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
        }
    }
}
