import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class ServiceRegistration: ObservableObject {
    @Published private(set) var status = "Checking registration…"
    @Published private(set) var error: String?
    @Published private(set) var registered = false
    @Published private(set) var requiresApproval = false

    private let service = SMAppService.agent(plistName: "org.wotex.home.agent.plist")

    init() {
        refresh()
    }

    func refresh() {
        let current = service.status
        registered = current == .enabled || current == .requiresApproval
        requiresApproval = current == .requiresApproval
        switch current {
        case .enabled:
            status = "Registered and eligible to run for this user"
        case .requiresApproval:
            status = "Approval required in System Settings"
        case .notRegistered:
            status = "Background service not registered"
        case .notFound:
            status = "Background service unavailable"
        @unknown default:
            status = "Unknown registration state"
        }
    }

    func setRegistered(_ enabled: Bool) {
        refresh()
        guard enabled != registered else { return }
        if enabled { enable() } else { disable() }
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

@MainActor
final class HomeWindowNavigation: ObservableObject {
    @Published var task: HomeTask = .setup
    @Published var rulesMode = HomeRulesMode.explicit
}

struct HomeWindow: View {
    @StateObject private var registration = ServiceRegistration()
    @StateObject private var navigation = HomeWindowNavigation()
    @EnvironmentObject private var application: HomeApplicationModel
    @EnvironmentObject private var health: HealthViewModel
    @EnvironmentObject private var maintenance: MaintenanceViewModel
    @EnvironmentObject private var profiles: ProfilesViewModel
    @EnvironmentObject private var setup: NativeSetupViewModel
    @EnvironmentObject private var network: NativeNetworkViewModel
    @EnvironmentObject private var pending: NativePendingCoordinator
    @EnvironmentObject private var access: NativeAccessViewModel
    @EnvironmentObject private var rules: NativeRuleViewModel
    @EnvironmentObject private var schedules: NativeScheduleViewModel
    @EnvironmentObject private var thingView: NativeThingViewModel
    private var changesAllowed: Bool { application.canChangeSession }
    private var modelsBusy: Bool { application.busy }

    var body: some View {
        HomeTaskShell(task: $navigation.task, availability: registration.status, session: setup.session) {
            if pending.needsReload || !pending.entries.isEmpty || pending.error != nil {
                HomeSection(title: "Recovery") { NativePendingPanel(journal: pending, recoveryAllowed: !modelsBusy) }
            }
            if health.unknownWarning {
                Label(health.executionDetail, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        } content: {
            Group {
                switch navigation.task {
                case .things: thingsTask
                case .rules:
                    HomeSection(title: "Power automation") {
                        Picker("Automation", selection: $navigation.rulesMode) {
                            ForEach(HomeRulesMode.allCases) { Text($0.title).tag($0) }
                        }.pickerStyle(.segmented)
                        if navigation.rulesMode == .explicit { NativeRulePanel(rules: rules) }
                        else { NativeSchedulePanel(schedules: schedules) }
                    }
                case .activity: activityTask
                case .setup: setupTask
                }
            }.disabled(modelsBusy)
        }
        .frame(minWidth: 480, minHeight: 640)
        .task { await pending.loadIfNeeded() }
    }

    private var setupTask: some View {
        VStack(alignment: .leading, spacing: 24) {
            HomeSection(title: "Local controller") {
                HomeSettingToggle(title: "Background controller",
                    detail: "Start Home at login and keep it running when this window closes.",
                    isOn: Binding(get: { registration.registered }, set: {
                        guard !modelsBusy, !pending.busy else { return }
                        registration.setRegistered($0)
                    }))
                    .disabled(modelsBusy || pending.busy)
                Text(registration.status).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ViewThatFits(in: .horizontal) {
                    HStack { registrationControls }
                    VStack(alignment: .leading) { registrationControls }
                }
                if let error = registration.error { Text(error).foregroundStyle(.red) }
                Divider()
                healthStatus
            }
            HomeSection(title: "Session and access") {
                NativeSetupPanel(setup: setup, changesAllowed: changesAllowed)
                Divider()
                NativeAccessPanel(access: access)
                DisclosureGroup("Manual credential import") {
                    SecureField("Operator credential", text: $health.credentialInput).textFieldStyle(.roundedBorder)
                    Button("Import to Keychain") { health.importCredential() }.disabled(!changesAllowed || health.credentialInput.isEmpty)
                    Text("Use a credential from trusted local provisioning. Import explicitly selects manual custody.").font(.footnote).foregroundStyle(.secondary)
                }
            }
            HomeSection(title: "Local discovery") { NativeNetworkPanel(network: network, changesAllowed: changesAllowed) }
            HomeSection(title: "Device profiles") {
                Text("Choose an exact supported profile, refresh its state, discover and interview the device, then review and commit its selection. Enrollment grants no control.").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                DisclosureGroup("Maintenance for profile changes") { HostMaintenancePanel(maintenance: maintenance).padding(.top, 8) }
                PortableProfilesPanel(profiles: profiles)
            }
        }
    }
    private var registrationControls: some View {
        Group {
            if registration.requiresApproval { Button("Open Approval Settings") { registration.openApprovalSettings() } }
            Button("Check Registration") { registration.refresh() }
        }
    }
    private var healthStatus: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Authenticated host status").font(.subheadline.weight(.semibold))
            Text(health.summary).fixedSize(horizontal: false, vertical: true)
            if !health.detail.isEmpty { Text(health.detail).font(.callout).fixedSize(horizontal: false, vertical: true) }
            if !health.executionDetail.isEmpty { Text(health.executionDetail).font(.callout).foregroundStyle(health.unknownWarning ? .orange : .secondary).fixedSize(horizontal: false, vertical: true) }
            if let error = health.error { Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            Button("Read Home State") { health.refresh() }.disabled(health.busy)
            Text("Registration, connection health and device observations are separate.").font(.footnote).foregroundStyle(.secondary)
        }
    }
    private var thingsTask: some View {
        VStack(alignment: .leading, spacing: 24) {
            HomeSection(title: "Controller status") { healthStatus }
            HomeSection(title: "Enrolled Things") {
                Text(health.catalogueDetail).font(.callout).foregroundStyle(.secondary)
                if health.things.isEmpty {
                    Text("No enrolled Things in this session's scope. Review a device and its access in Setup.").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(health.things) { thing in
                    Button { thingView.targetIDInput = thing.id } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: thing.role == "Light" ? "lightbulb" : "sensor").font(.title2).foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(thing.id).font(.headline)
                                Text("\(thing.role) · \(thing.capabilityCount) capabilities · Resource \(thing.resourceRevision)").font(.caption).foregroundStyle(.secondary)
                                Text(thing.profileRef).font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: thingView.targetIDInput == thing.id ? "checkmark.circle.fill" : "chevron.right").foregroundStyle(thingView.targetIDInput == thing.id ? Color.accentColor : Color.secondary)
                        }.padding(12).background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain).accessibilityLabel("Inspect " + thing.id)
                        .accessibilityAddTraits(thingView.targetIDInput == thing.id ? .isSelected : [])
                }
            }
            HomeSection(title: "Selected Thing") { NativeThingPanel(things: thingView) }
            if let view = thingView.inspection, let thing = health.things.first(where: { $0.id == view.thingID && $0.resourceRevision == view.resourceRevision && $0.powerWritable }) {
                HomeSection(title: "Request power for " + thing.id) {
                    ViewThatFits(in: .horizontal) {
                        HStack { powerControls(thing) }
                        VStack(alignment: .leading) { powerControls(thing) }
                    }
                    Text("These controls stage an ordinary request or priority lease. Inspect its receipt in Activity; a held request is not a device result.").font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
    private func powerControls(_ thing: HomeThing) -> some View {
        Group {
            Button("Stage On") { health.stagePower(thing, on: true) }.disabled(!health.canStagePower(thing))
            Button("Stage Off") { health.stagePower(thing, on: false) }.disabled(!health.canStagePower(thing))
            Button("Issue 15 min Override") { health.issueOverride(thing) }.disabled(health.hasUnconfirmedOverride || !pending.canStart)
        }
    }
    private var activityTask: some View {
        VStack(alignment: .leading, spacing: 24) {
            HomeSection(title: "Power request receipts") {
                TextField("Authority epoch", text: $health.authorityEpochInput)
                TextField("Operation ID", text: $health.operationIDInput)
                ViewThatFits(in: .horizontal) {
                    HStack { receiptControls }
                    VStack(alignment: .leading) { receiptControls }
                }
                Text(health.receiptStatus).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                if let error = health.receiptError { Text(error).foregroundStyle(.red) }
                Text("Look up the original ID after uncertainty. Cancel withdraws held or still-queued work; a handed-off packet cannot be recalled.").font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HomeSection(title: "Priority overrides") {
                Text(health.overrideDetail).fixedSize(horizontal: false, vertical: true)
                ForEach(health.overrides) { item in
                    Text("\(item.targetID) · \(item.operatorID) · \(max(1, (item.remainingMilliseconds + 999) / 1_000)) s at last read").fixedSize(horizontal: false, vertical: true)
                    if item.operationID != nil { Button("Revoke Original Override") { health.revokeOverride(item) } }
                }
                TextField("Override authority epoch", text: $health.overrideAuthorityEpochInput)
                TextField("Override operation ID", text: $health.overrideOperationIDInput)
                ViewThatFits(in: .horizontal) {
                    HStack { overrideControls }
                    VStack(alignment: .leading) { overrideControls }
                }
                Text(health.overrideStatus).fixedSize(horizontal: false, vertical: true)
                if let error = health.overrideError { Text(error).foregroundStyle(.red) }
            }
            HomeSection(title: "Other original receipts") {
                DisclosureGroup("Enrollment review lookup") {
                    TextField("Original review reference", text: $health.enrollmentReviewRefInput)
                    Button("Look Up Review") { health.lookupEnrollmentReview() }.disabled(health.enrollmentReviewRefInput.isEmpty)
                    Text(health.enrollmentStatus).fixedSize(horizontal: false, vertical: true)
                    if let error = health.enrollmentError { Text(error).foregroundStyle(.red) }
                }
                DisclosureGroup("Original rule receipt lookup") {
                    TextField("Rule authority epoch", text: $health.ruleAuthorityEpochInput)
                    TextField("Rule operation ID", text: $health.ruleOperationIDInput)
                    Button("Look Up Rule Receipt") { health.lookupRuleOperation() }.disabled(health.ruleOperationIDInput.isEmpty)
                    Button("Retry Original Suspension") { health.retryRule() }.disabled(!health.hasUnconfirmedRule)
                    Button("Read Rule Policy") { health.refreshRules() }
                    Text(health.ruleStatus).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    if let error = health.ruleError { Text(error).foregroundStyle(.red) }
                }
            }
        }
    }
    private var receiptControls: some View {
        Group {
            Button("Look Up Original") { health.lookupReceipt() }.disabled(health.operationIDInput.isEmpty)
            Button("Cancel Pending") { health.cancelPendingRequest() }.disabled(health.operationIDInput.isEmpty)
            Button("Retry Original Power") { health.retryPower() }.disabled(!health.hasUnconfirmedPower)
        }
    }
    private var overrideControls: some View {
        Group {
            Button("Look Up Override") { health.lookupOverride() }.disabled(health.overrideOperationIDInput.isEmpty)
            Button("Revoke Override") { health.revokeOverride() }.disabled(health.overrideOperationIDInput.isEmpty)
            Button("Retry Original Override") { health.retryOverride() }.disabled(!health.hasUnconfirmedOverride)
        }
    }
}

@main
struct WotexHomeApp: App {
    @StateObject private var application = HomeApplicationModel()
    @Environment(\.openWindow) private var openWindow
    var body: some Scene {
        WindowGroup("WoTEx Home", id: "home") {
            HomeWindow()
                .environmentObject(application)
                .environmentObject(application.setup)
                .environmentObject(application.health)
                .environmentObject(application.maintenance)
                .environmentObject(application.profiles)
                .environmentObject(application.network)
                .environmentObject(application.pending)
                .environmentObject(application.access)
                .environmentObject(application.rules)
                .environmentObject(application.schedules)
                .environmentObject(application.things)
        }
        MenuBarExtra {
            HomeQuickBar(application: application) {
                openWindow(id: "home")
                NSApp.activate()
            }
        } label: {
            let attention = !application.pending.entries.isEmpty || application.pending.error != nil || application.health.unknownWarning
            Label(attention ? "WoTEx Home needs attention" : "WoTEx Home", systemImage: attention ? "exclamationmark.triangle" : "house.fill")
        }.menuBarExtraStyle(.window)
    }
}
