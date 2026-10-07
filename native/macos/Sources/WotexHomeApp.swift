import AppKit
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
}

struct HomeWindow: View {
    @StateObject private var registration = ServiceRegistration()
    @StateObject private var navigation = HomeWindowNavigation()
    @EnvironmentObject private var health: HealthViewModel
    @EnvironmentObject private var maintenance: MaintenanceViewModel
    @EnvironmentObject private var profiles: ProfilesViewModel
    @EnvironmentObject private var setup: NativeSetupViewModel
    @EnvironmentObject private var network: NativeNetworkViewModel
    @EnvironmentObject private var pending: NativePendingCoordinator
    @EnvironmentObject private var access: NativeAccessViewModel
    @EnvironmentObject private var rules: NativeRuleViewModel
    @EnvironmentObject private var thingView: NativeThingViewModel
    private var changesAllowed: Bool { pending.canStart && health.canChangeSession && maintenance.canChangeSession && profiles.canChangeSession && access.canChangeSession && rules.canChangeSession && thingView.canChangeSession && !network.busy }
    private var modelsBusy: Bool { health.busy || health.stageBusy || health.receiptBusy || health.overrideBusy || health.ruleBusy || health.enrollmentBusy || maintenance.busy || profiles.busy || access.busy || rules.busy || thingView.busy || setup.busy || network.busy }

    var body: some View {
        HomeTaskShell(task: $navigation.task, availability: registration.status, session: setup.session) {
            NativePendingPanel(journal: pending, recoveryAllowed: !modelsBusy)
        } content: {
            Group {
                switch navigation.task {
                case .things: thingsTask
                case .rules: NativeRulePanel(rules: rules)
                case .activity: activityTask
                case .setup: setupTask
                }
            }.disabled(modelsBusy)
        }
        .frame(minWidth: 480, minHeight: 640)
        .task { await pending.loadIfNeeded() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in thingView.hostDidWake() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)) { _ in thingView.hostDidWake() }
        .onAppear {
            let coordinator = setup
            health.manualImported = { [weak coordinator] in coordinator?.manualImported() }
            let healthModel = health; let maintenanceModel = maintenance; let profilesModel = profiles
            let networkModel = network; let setupModel = setup
            let accessModel = access
            let rulesModel = rules
            let thingModel = thingView
            let pendingModel = pending
            setup.changesAllowed = { pendingModel.canStart && healthModel.canChangeSession && maintenanceModel.canChangeSession && profilesModel.canChangeSession && accessModel.canChangeSession && rulesModel.canChangeSession && thingModel.canChangeSession && !networkModel.busy }
            setup.checkAllowed = { !pendingModel.busy && !healthModel.busy && !healthModel.stageBusy && !healthModel.receiptBusy && !healthModel.overrideBusy && !healthModel.ruleBusy && !healthModel.enrollmentBusy && !maintenanceModel.busy && !profilesModel.busy && !accessModel.busy && !rulesModel.busy && !thingModel.busy && !networkModel.busy }
            setup.ownerChecked = { pendingModel.observedOwner($0); thingModel.invalidateSessionView() }
            pending.didResolve = { [weak healthModel, weak maintenanceModel, weak profilesModel, weak accessModel, weak rulesModel] entry in
                healthModel?.originalResolved(entry); maintenanceModel?.originalResolved(entry); profilesModel?.originalResolved(entry); accessModel?.originalResolved(entry); rulesModel?.originalResolved(entry)
            }
            network.changesAllowed = { [weak setupModel] in pendingModel.canStart && healthModel.canChangeSession && maintenanceModel.canChangeSession && profilesModel.canChangeSession && accessModel.canChangeSession && rulesModel.canChangeSession && thingModel.canChangeSession && setupModel?.busy == false }
            setup.selectionChanged = {
                healthModel.invalidateSessionView(); maintenanceModel.invalidateSessionView(); profilesModel.invalidateSessionView(); accessModel.invalidateSessionView(); rulesModel.invalidateSessionView(); thingModel.invalidateSessionView()
            }
            access.didChangeAccess = { healthModel.invalidateSessionView(); profilesModel.invalidateSessionView(); rulesModel.invalidateSessionView(); thingModel.invalidateSessionView() }
            thingView.changesAllowed = { pendingModel.canStart && !setupModel.busy && !networkModel.busy && !healthModel.busy && !healthModel.stageBusy && !healthModel.receiptBusy && !healthModel.overrideBusy && !healthModel.ruleBusy && !healthModel.enrollmentBusy && !maintenanceModel.busy && !profilesModel.busy && !accessModel.busy && !rulesModel.busy }
            thingView.didRefreshReports = { healthModel.invalidateSessionView() }
            rules.didChangeRules = { healthModel.invalidateSessionView() }
            rules.didStageInvocation = { epoch, operation in healthModel.authorityEpochInput = String(epoch); healthModel.operationIDInput = operation }
        }
    }

    private var setupTask: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Local controller").font(.headline)
            Text("Closing this window leaves an enabled background host running. Registration eligibility and authenticated host health are separate.").fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack { registrationControls }
                VStack(alignment: .leading) { registrationControls }
            }
            if let error = registration.error { Text(error).foregroundStyle(.red) }
            NativeSetupPanel(setup: setup, changesAllowed: changesAllowed)
            NativeNetworkPanel(network: network, changesAllowed: changesAllowed)
            Divider()
            Text("Review a device").font(.headline)
            Text("Choose an exact supported profile, refresh its state, discover and interview the device, then review and commit its selection. Enrollment grants no control.").fixedSize(horizontal: false, vertical: true)
            DisclosureGroup("Maintenance for profile changes") { HostMaintenancePanel(maintenance: maintenance).padding(.top, 8) }
            PortableProfilesPanel(profiles: profiles)
            Divider()
            NativeAccessPanel(access: access)
            DisclosureGroup("Manual credential import") {
                SecureField("Operator credential", text: $health.credentialInput).textFieldStyle(.roundedBorder)
                Button("Import to Keychain") { health.importCredential() }.disabled(!changesAllowed || health.credentialInput.isEmpty)
                Text("Use a credential from trusted local provisioning. Import explicitly selects manual custody.").font(.footnote).foregroundStyle(.secondary)
            }
            healthStatus
        }
    }
    private var registrationControls: some View {
        Group {
            Button("Enable Background Host") { registration.enable() }.disabled(modelsBusy || pending.busy)
            Button("Stop Background Host") { registration.disable() }.disabled(modelsBusy || pending.busy)
            Button("Approval Settings") { registration.openApprovalSettings() }
            Button("Check Registration") { registration.refresh() }
        }
    }
    private var healthStatus: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Authenticated host status").font(.headline)
            Text(health.summary).fixedSize(horizontal: false, vertical: true)
            if !health.detail.isEmpty { Text(health.detail).font(.callout).fixedSize(horizontal: false, vertical: true) }
            if !health.executionDetail.isEmpty { Text(health.executionDetail).font(.callout).foregroundStyle(health.unknownWarning ? .orange : .secondary).fixedSize(horizontal: false, vertical: true) }
            if let error = health.error { Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            Button("Read Home State") { health.refresh() }.disabled(health.busy)
            Text("Storage diagnostics do not establish a device effect.").font(.footnote).foregroundStyle(.secondary)
        }
    }
    private var thingsTask: some View {
        VStack(alignment: .leading, spacing: 16) {
            healthStatus
            Text(health.catalogueDetail).font(.callout)
            if health.things.isEmpty {
                Text("No enrolled Things in this session's scope. Review a device and its access in Setup.").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(health.things) { thing in
                Button { thingView.targetIDInput = thing.id } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(thing.id).font(.headline)
                        Text("\(thing.role) · \(thing.capabilityCount) capabilities · Resource \(thing.resourceRevision)").font(.caption)
                        Text(thing.profileRef).font(.caption)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain).accessibilityLabel("Inspect " + thing.id)
                    .accessibilityAddTraits(thingView.targetIDInput == thing.id ? .isSelected : [])
            }
            NativeThingPanel(things: thingView)
            if let view = thingView.inspection, let thing = health.things.first(where: { $0.id == view.thingID && $0.resourceRevision == view.resourceRevision && $0.powerWritable }) {
                Divider()
                Text("Request power for \(thing.id)").font(.headline)
                ViewThatFits(in: .horizontal) {
                    HStack { powerControls(thing) }
                    VStack(alignment: .leading) { powerControls(thing) }
                }
                Text("These controls stage an ordinary request or priority lease. Inspect its receipt in Activity; a held request is not a device result.").font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private func powerControls(_ thing: HomeThing) -> some View {
        Group {
            Button("Stage On") { health.stagePower(thing, on: true) }.disabled(health.hasUnconfirmedPower || !pending.canStart)
            Button("Stage Off") { health.stagePower(thing, on: false) }.disabled(health.hasUnconfirmedPower || !pending.canStart)
            Button("Issue 15 min Override") { health.issueOverride(thing) }.disabled(health.hasUnconfirmedOverride || !pending.canStart)
        }
    }
    private var activityTask: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Operation receipt").font(.headline)
            TextField("Authority epoch", text: $health.authorityEpochInput)
            TextField("Operation ID", text: $health.operationIDInput)
            ViewThatFits(in: .horizontal) {
                HStack { receiptControls }
                VStack(alignment: .leading) { receiptControls }
            }
            Text(health.receiptStatus).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            if let error = health.receiptError { Text(error).foregroundStyle(.red) }
            Text("Look up the original ID after uncertainty. Cancel withdraws held or still-queued work; a handed-off packet cannot be recalled.").font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            Text("Current overrides").font(.headline)
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
    @StateObject private var setup = NativeSetupViewModel()
    @StateObject private var health = HealthViewModel()
    @StateObject private var maintenance = MaintenanceViewModel()
    @StateObject private var profiles = ProfilesViewModel()
    @StateObject private var network = NativeNetworkViewModel()
    @StateObject private var pending = NativePendingCoordinator.shared
    @StateObject private var access = NativeAccessViewModel()
    @StateObject private var rules = NativeRuleViewModel()
    @StateObject private var thingView = NativeThingViewModel()
    var body: some Scene {
        WindowGroup {
            HomeWindow()
                .environmentObject(setup)
                .environmentObject(health)
                .environmentObject(maintenance)
                .environmentObject(profiles)
                .environmentObject(network)
                .environmentObject(pending)
                .environmentObject(access)
                .environmentObject(rules)
                .environmentObject(thingView)
        }
    }
}
