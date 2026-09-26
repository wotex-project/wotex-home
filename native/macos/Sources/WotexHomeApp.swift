import ServiceManagement
import SwiftUI

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
        }
        .padding(24)
        .frame(minWidth: 600, minHeight: 220)
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
