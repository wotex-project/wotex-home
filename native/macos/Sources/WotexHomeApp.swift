import ServiceManagement
import SwiftUI

@MainActor
final class HealthViewModel: ObservableObject {
    @Published var credentialInput = ""
    @Published private(set) var summary = "No health check yet"
    @Published private(set) var detail = ""
    @Published private(set) var error: String?
    @Published private(set) var busy = false

    func importCredential() {
        let encoded = credentialInput
        busy = true
        error = nil
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try OperatorCredential.save(encoded)
                }.value
                credentialInput = ""
                refresh()
            } catch {
                self.error = error.localizedDescription
                busy = false
            }
        }
    }

    func refresh() {
        busy = true
        error = nil
        Task {
            do {
                let health = try await Task.detached(priority: .userInitiated) {
                    try LocalHealthClient.fetch()
                }.value
                summary = health.writable ? "Host store available" : "Host store unavailable"
                detail = "Revision \(health.revision) · Authority \(health.authorityEpoch) · " +
                    "\(health.activeThings) Things · \(health.activePrincipals) principals · " +
                    "\(health.heldRequests) held requests · " +
                    (health.dispatchEnabled ? "Dispatch enabled" : "Dispatch disabled")
            } catch {
                summary = "Health unavailable"
                detail = ""
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}

@MainActor
final class ServiceRegistration: ObservableObject {
    @Published private(set) var status = "Checking registration…"
    @Published private(set) var error: String?

    private let service = SMAppService.agent(plistName: "org.wotex.home.agent.plist")

    init() {
        refresh()
    }

    func refresh() {
        switch service.status {
        case .enabled:
            status = "Enabled for this user"
        case .requiresApproval:
            status = "Approval required in System Settings"
        case .notRegistered:
            status = "Stopped"
        case .notFound:
            status = "Agent missing from app bundle"
        @unknown default:
            status = "Unknown registration state"
        }
    }

    func enable() {
        do {
            try service.register()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        refresh()
    }

    func disable() {
        do {
            try service.unregister()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        refresh()
    }

    func openApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

struct HomeWindow: View {
    @StateObject private var registration = ServiceRegistration()
    @StateObject private var health = HealthViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("WoTEx Home")
                .font(.title)
            Text(registration.status)
                .font(.headline)
            Text("Registration controls the per-user background host. Closing this window does not stop an enabled host.")
                .fixedSize(horizontal: false, vertical: true)

            if let error = registration.error {
                Text(error)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Enable Background Host") { registration.enable() }
                Button("Stop Background Host") { registration.disable() }
                Button("Approval Settings") { registration.openApprovalSettings() }
                Button("Refresh") { registration.refresh() }
            }

            Divider()
            Text("Local host health")
                .font(.headline)
            Text(health.summary)
            if !health.detail.isEmpty {
                Text(health.detail)
                    .font(.callout)
            }
            if let error = health.error {
                Text(error)
                    .foregroundStyle(.red)
            }
            HStack {
                SecureField("Operator credential", text: $health.credentialInput)
                    .textFieldStyle(.roundedBorder)
                Button("Import to Keychain") {
                    health.importCredential()
                }
                .disabled(health.busy || health.credentialInput.isEmpty)
                Button("Refresh Health") { health.refresh() }
                    .disabled(health.busy)
            }
            Text("A credential must come from trusted local provisioning. Health is a storage diagnostic; it does not establish device control.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(minWidth: 720, minHeight: 360)
    }
}

@main
struct WotexHomeApp: App {
    var body: some Scene {
        WindowGroup {
            HomeWindow()
        }
    }
}
