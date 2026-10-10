import AppKit
import Combine
import SwiftUI

// One process-wide session and journal for windows and the menu-bar surface.
// Construction connects guards; it performs no API, Keychain or device operation.
@MainActor
final class HomeApplicationModel: ObservableObject {
    let setup = NativeSetupViewModel()
    let maintenance: MaintenanceViewModel
    let profiles: ProfilesViewModel
    let network = NativeNetworkViewModel()
    let access: NativeAccessViewModel
    let rules: NativeRuleViewModel
    let schedules: NativeScheduleViewModel
    let things: NativeThingViewModel
    let health: HealthViewModel
    let pending: NativePendingCoordinator
    let controller: NativeControllerSessionDriver
    private var subscriptions: Set<AnyCancellable> = []

    var busy: Bool {
        pending.busy || health.busy || health.stageBusy || health.receiptBusy || health.overrideBusy ||
            health.ruleBusy || health.enrollmentBusy || maintenance.busy || profiles.busy || access.busy ||
            rules.busy || schedules.busy || things.busy || setup.busy || network.busy || controller.busy
    }
    var canChangeSession: Bool {
        !controller.busy && !setup.busy && !network.busy && pending.canStart && health.canChangeSession &&
            maintenance.canChangeSession && profiles.canChangeSession && access.canChangeSession &&
            rules.canChangeSession && schedules.canChangeSession && things.canChangeSession
    }

    init(pending: NativePendingCoordinator = .shared, health: HealthViewModel? = nil,
         things: NativeThingViewModel? = nil, controller: NativeControllerSessionDriver = NativeControllerSessionDriver()) {
        self.pending = pending
        self.controller = controller
        self.health = health ?? HealthViewModel(journal: pending, selectedReader: { try await controller.readHome() })
        self.things = things ?? NativeThingViewModel(selectedReader: { try await controller.readThing(target: $0, probe: $1) })
        maintenance = MaintenanceViewModel(journal: pending)
        profiles = ProfilesViewModel(journal: pending)
        access = NativeAccessViewModel(journal: pending)
        rules = NativeRuleViewModel(journal: pending)
        schedules = NativeScheduleViewModel(journal: pending)
        controller.installLocalFence()
        bind()
        let publishers: [ObservableObjectPublisher] = [setup.objectWillChange, self.health.objectWillChange,
            maintenance.objectWillChange, profiles.objectWillChange, network.objectWillChange,
            pending.objectWillChange, access.objectWillChange, rules.objectWillChange,
            schedules.objectWillChange, self.things.objectWillChange, controller.objectWillChange]
        for publisher in publishers {
            publisher.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.willSleepNotification] {
            NSWorkspace.shared.notificationCenter.publisher(for: name).sink { [weak self] _ in
                // Schedule workspace events on the owning actor before
                // invalidating presentation.
                Task { @MainActor [weak self] in self?.hostAvailabilityChanged() }
            }.store(in: &subscriptions)
        }
    }
    private func bind() {
        controller.changesAllowed = { [weak self] in self?.canChangeSession == true }
        controller.selectionChanged = { [weak self] in self?.invalidateSessionViews() }
        health.manualImported = { [weak self] in self?.setup.manualImported() }
        health.powerRequestsAllowed = { [weak self] in self?.controller.localSelected == true && self?.canChangeSession == true }
        setup.changesAllowed = { [weak self] in self?.controller.localSelected == true && self?.canChangeSession == true }
        setup.checkAllowed = { [weak self] in self?.controller.localSelected == true && self?.busy == false }
        setup.ownerChecked = { [weak self] owner in
            guard let self else { return }
            pending.observedOwner(owner)
            health.invalidateSessionView(); things.invalidateSessionView()
            rules.invalidateSessionView(); schedules.invalidateSessionView()
        }
        pending.didResolve = { [weak self] entry in
            guard let self else { return }
            health.originalResolved(entry); maintenance.originalResolved(entry); profiles.originalResolved(entry)
            access.originalResolved(entry); rules.originalResolved(entry); schedules.originalResolved(entry)
        }
        network.changesAllowed = { [weak self] in self?.controller.localSelected == true && self?.canChangeSession == true }
        setup.selectionChanged = { [weak self] in self?.invalidateSessionViews() }
        access.didChangeAccess = { [weak self] in
            guard let self else { return }
            health.invalidateSessionView(); profiles.invalidateSessionView(); rules.invalidateSessionView()
            schedules.invalidateSessionView(); things.invalidateSessionView()
        }
        things.changesAllowed = { [weak self] in self?.busy == false && self?.pending.canStart == true }
        things.didRefreshReports = { [weak self] in self?.health.invalidateSessionView() }
        rules.didChangeRules = { [weak self] in self?.health.invalidateSessionView(); self?.schedules.invalidateSessionView() }
        schedules.didChangeSchedules = { [weak self] in self?.health.invalidateSessionView(); self?.rules.invalidateSessionView() }
        rules.didStageInvocation = { [weak self] epoch, operation in
            self?.health.authorityEpochInput = String(epoch); self?.health.operationIDInput = operation
        }
    }
    private func invalidateSessionViews() {
        health.invalidateSessionView(); maintenance.invalidateSessionView(); profiles.invalidateSessionView()
        access.invalidateSessionView(); rules.invalidateSessionView(); schedules.invalidateSessionView(); things.invalidateSessionView()
    }
    func hostAvailabilityChanged() {
        health.invalidateSessionView()
        things.hostDidWake()
    }
}
