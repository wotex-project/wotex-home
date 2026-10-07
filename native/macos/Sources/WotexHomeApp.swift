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

struct HomeWindow: View {
    @StateObject private var registration = ServiceRegistration()
    @EnvironmentObject private var health: HealthViewModel
    @EnvironmentObject private var maintenance: MaintenanceViewModel
    @EnvironmentObject private var profiles: ProfilesViewModel
    @EnvironmentObject private var setup: NativeSetupViewModel
    @EnvironmentObject private var network: NativeNetworkViewModel
    @EnvironmentObject private var pending: NativePendingCoordinator
    @EnvironmentObject private var access: NativeAccessViewModel
    @EnvironmentObject private var rules: NativeRuleViewModel
    private var changesAllowed: Bool { pending.canStart && health.canChangeSession && maintenance.canChangeSession && profiles.canChangeSession && access.canChangeSession && rules.canChangeSession && !network.busy }

    var body: some View {
        ScrollView {
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
                NativePendingPanel(journal: pending, recoveryAllowed: !health.busy && !health.stageBusy &&
                    !health.receiptBusy && !health.overrideBusy && !health.ruleBusy && !health.enrollmentBusy &&
                    !maintenance.busy && !profiles.busy && !access.busy && !rules.busy)
                Divider()
                NativeNetworkPanel(network: network, changesAllowed: changesAllowed)
                Divider()
                NativeSetupPanel(setup: setup, changesAllowed: changesAllowed)
                Divider()
                NativeAccessPanel(access: access)
                Divider()
                NativeRulePanel(rules: rules).disabled(health.busy || health.stageBusy || health.receiptBusy || health.overrideBusy || health.ruleBusy || maintenance.busy || profiles.busy)
                Divider()
                Text("Local host health")
                    .font(.headline)
                Text(health.summary)
                if !health.detail.isEmpty {
                    Text(health.detail)
                        .font(.callout)
                }
                if !health.executionDetail.isEmpty {
                    Text(health.executionDetail)
                        .font(.callout)
                        .foregroundStyle(health.unknownWarning ? .orange : .secondary)
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
                    .disabled(!changesAllowed || setup.busy || health.credentialInput.isEmpty)
                    Button("Refresh Health") { health.refresh() }
                        .disabled(health.busy)
                }
                Text("A credential must come from trusted local provisioning. Health is a storage diagnostic; it does not establish device control.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Divider()
                Text("Operation receipt")
                    .font(.headline)
                HStack {
                    TextField("Authority epoch", text: $health.authorityEpochInput)
                        .frame(width: 150)
                    TextField("Operation ID", text: $health.operationIDInput)
                    Button("Look Up") { health.lookupReceipt() }
                        .disabled(health.receiptBusy || health.operationIDInput.isEmpty)
                    Button("Cancel Pending") { health.cancelPendingRequest() }
                        .disabled(health.receiptBusy || health.stageBusy || health.operationIDInput.isEmpty)
                    Button("Retry Original") { health.retryPower() }
                        .disabled(health.receiptBusy || health.stageBusy || !health.hasUnconfirmedPower)
                }
                Text(health.receiptStatus)
                    .font(.callout)
                if let error = health.receiptError {
                    Text(error)
                        .foregroundStyle(.red)
                }
                Text("A held receipt records a request. Cancel can withdraw held or still-queued work; claimed work cannot be recalled. After an uncertain submission or cancellation, look up the original operation ID.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Divider()
                Text("Enrollment review status")
                    .font(.headline)
                HStack {
                    TextField("Review reference", text: $health.enrollmentReviewRefInput)
                    Button("Look Up") { health.lookupEnrollmentReview() }
                        .disabled(health.enrollmentBusy || health.enrollmentReviewRefInput.isEmpty)
                }
                Text(health.enrollmentStatus)
                    .font(.callout)
                if let error = health.enrollmentError {
                    Text(error)
                        .foregroundStyle(.red)
                }
                Text("Only the original enrollment operator can inspect a review. This view does not enroll or qualify a device.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Divider()
                Text("Enrolled Things in this credential's scope")
                    .font(.headline)
                Text(health.catalogueDetail)
                    .font(.callout)
                if health.things.isEmpty {
                    Text("No Things in this credential's scope")
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(health.things) { thing in
                                HStack {
                                    Text("\(thing.id) · \(thing.role)")
                                    Spacer()
                                    Text("\(thing.capabilityCount) capabilities")
                                    Text("Revision \(thing.resourceRevision)")
                                        .foregroundStyle(.secondary)
                                    if thing.powerWritable {
                                        Button("Stage On") { health.stagePower(thing, on: true) }
                                            .disabled(health.stageBusy || health.receiptBusy || health.busy || health.hasUnconfirmedPower || !pending.canStart)
                                        Button("Stage Off") { health.stagePower(thing, on: false) }
                                            .disabled(health.stageBusy || health.receiptBusy || health.busy || health.hasUnconfirmedPower || !pending.canStart)
                                        Button("Issue 15 min override") {
                                            health.issueOverride(thing)
                                        }
                                        .disabled(health.overrideBusy || health.busy || health.hasUnconfirmedOverride || !pending.canStart)
                                    }
                                }
                                .font(.callout)
                            }
                        }
                    }
                    .frame(maxHeight: 160)
                }

                Divider()
                Text("Current operator overrides")
                    .font(.headline)
                Text(health.overrideDetail)
                    .font(.callout)
                if health.overrides.isEmpty {
                    Text("No active overrides in this credential's scope")
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(health.overrides) { item in
                                let seconds = max(1, (item.remainingMilliseconds + 999) / 1_000)
                                HStack {
                                    Text("\(item.targetID) · \(item.operatorID) · \(seconds) s remaining")
                                    if item.operationID != nil {
                                        Button("Revoke") { health.revokeOverride(item) }
                                            .disabled(health.overrideBusy || health.busy)
                                    }
                                }
                                .font(.callout)
                            }
                        }
                    }
                    .frame(maxHeight: 100)
                }
                HStack {
                    TextField("Authority epoch", text: $health.overrideAuthorityEpochInput)
                        .frame(width: 150)
                    TextField("Override operation ID", text: $health.overrideOperationIDInput)
                    Button("Look Up") { health.lookupOverride() }
                        .disabled(health.overrideBusy || health.overrideOperationIDInput.isEmpty)
                    Button("Revoke") { health.revokeOverride() }
                        .disabled(health.overrideBusy || health.overrideOperationIDInput.isEmpty)
                    Button("Retry Original") { health.retryOverride() }
                        .disabled(health.overrideBusy || !health.hasUnconfirmedOverride)
                }
                Text(health.overrideStatus)
                    .font(.callout)
                if let error = health.overrideError {
                    Text(error)
                        .foregroundStyle(.red)
                }
                Text("An override is a bounded priority lease. A live lease blocks rule effects at every execution boundary; issuing one does not change a device or recall a handed-off packet. Keep its operation ID to resolve a timed-out request.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Divider()
                Text("Rule policy")
                    .font(.headline)
                HStack {
                    Button("Refresh Rule Status") { health.refreshRules() }
                    Button("Suspend Rules") { health.suspendRules() }
                        .disabled(health.busy || health.hasUnconfirmedRule || !pending.canStart)
                    Button("Retry Original") { health.retryRule() }
                        .disabled(!health.hasUnconfirmedRule)
                }
                .disabled(health.ruleBusy)
                HStack {
                    TextField("Authority epoch", text: $health.ruleAuthorityEpochInput)
                        .frame(width: 150)
                    TextField("Rule operation ID", text: $health.ruleOperationIDInput)
                    Button("Look Up") { health.lookupRuleOperation() }
                        .disabled(health.ruleBusy || health.ruleOperationIDInput.isEmpty)
                }
                Text(health.ruleStatus)
                    .font(.callout)
                    .textSelection(.enabled)
                if let error = health.ruleError {
                    Text(error).foregroundStyle(.red)
                }
                Text("Rule management requires its own permission. Suspension cancels pending work and reports already handed-off effects as unknown. Keep the operation ID to resolve an uncertain reply.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Divider()
                HostMaintenancePanel(maintenance: maintenance)
                Divider()
                PortableProfilesPanel(profiles: profiles)
                Divider()
                Text("Latest stored observations")
                    .font(.headline)
                Text(health.snapshotDetail)
                    .font(.callout)
                if health.observations.isEmpty {
                    Text("No observations in this credential's scope")
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(health.observations) { item in
                                HStack {
                                    Text("\(item.thingID) · \(item.capabilityKey)")
                                    Spacer()
                                    Text(item.valueText)
                                    Text("\(item.quality) · \(item.trust)")
                                        .foregroundStyle(.secondary)
                                }
                                .font(.callout)
                            }
                        }
                    }
                    .frame(maxHeight: 240)
                }
            }
            .padding(24)
            .disabled(setup.busy || network.busy || access.busy || rules.busy)
        }
        .frame(minWidth: 900, minHeight: 680)
        .task { await pending.loadIfNeeded() }
        .onAppear {
            let coordinator = setup
            health.manualImported = { [weak coordinator] in coordinator?.manualImported() }
            let healthModel = health; let maintenanceModel = maintenance; let profilesModel = profiles
            let networkModel = network; let setupModel = setup
            let accessModel = access
            let rulesModel = rules
            let pendingModel = pending
            setup.changesAllowed = { pendingModel.canStart && healthModel.canChangeSession && maintenanceModel.canChangeSession && profilesModel.canChangeSession && accessModel.canChangeSession && rulesModel.canChangeSession && !networkModel.busy }
            setup.checkAllowed = { !pendingModel.busy && !healthModel.busy && !healthModel.stageBusy && !healthModel.receiptBusy && !healthModel.overrideBusy && !healthModel.ruleBusy && !maintenanceModel.busy && !profilesModel.busy && !accessModel.busy && !rulesModel.busy && !networkModel.busy }
            setup.ownerChecked = { pendingModel.observedOwner($0) }
            pending.didResolve = { [weak healthModel, weak maintenanceModel, weak profilesModel, weak accessModel, weak rulesModel] entry in
                healthModel?.originalResolved(entry); maintenanceModel?.originalResolved(entry); profilesModel?.originalResolved(entry); accessModel?.originalResolved(entry); rulesModel?.originalResolved(entry)
            }
            network.changesAllowed = { [weak setupModel] in pendingModel.canStart && healthModel.canChangeSession && maintenanceModel.canChangeSession && profilesModel.canChangeSession && accessModel.canChangeSession && rulesModel.canChangeSession && setupModel?.busy == false }
            setup.selectionChanged = {
                healthModel.invalidateSessionView(); maintenanceModel.invalidateSessionView(); profilesModel.invalidateSessionView(); accessModel.invalidateSessionView(); rulesModel.invalidateSessionView()
            }
            access.didChangeAccess = { healthModel.invalidateSessionView(); profilesModel.invalidateSessionView(); rulesModel.invalidateSessionView() }
            rules.didChangeRules = { healthModel.invalidateSessionView() }
            rules.didStageInvocation = { epoch, operation in healthModel.authorityEpochInput = String(epoch); healthModel.operationIDInput = operation }
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
        }
    }
}
