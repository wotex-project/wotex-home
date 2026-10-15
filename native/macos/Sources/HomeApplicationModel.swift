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
    let mqtt = NativeMQTTSetupViewModel()
    let access: NativeAccessViewModel
    let rules: NativeRuleViewModel
    let schedules: NativeScheduleViewModel
    let things: NativeThingViewModel
    let externalReports: NativeExternalReportViewModel
    let externalProfiles: NativeExternalProfileViewModel
    let authoring: NativeAuthoringReadViewModel
    let authoringOperations: NativeAuthoringViewModel
    let generation: NativeGenerationViewModel
    let health: HealthViewModel
    let pending: NativePendingCoordinator
    let controller: NativeControllerSessionDriver
    private var subscriptions: Set<AnyCancellable> = []

    var busy: Bool {
        pending.busy || health.busy || health.stageBusy || health.receiptBusy || health.overrideBusy ||
            health.ruleBusy || health.enrollmentBusy || maintenance.busy || profiles.busy || access.busy ||
            rules.busy || schedules.busy || things.busy || externalReports.busy || externalProfiles.busy || authoring.busy || authoringOperations.busy || generation.busy || generation.workspace.busy || setup.busy || network.busy || mqtt.busy || controller.busy
    }
    var canChangeSession: Bool {
        !controller.busy && !setup.busy && !network.busy && mqtt.canChangeSession && pending.canStart && health.canChangeSession &&
            maintenance.canChangeSession && profiles.canChangeSession && access.canChangeSession &&
            rules.canChangeSession && schedules.canChangeSession && things.canChangeSession && externalReports.canChangeSession && externalProfiles.canChangeSession && authoring.canChangeSession && authoringOperations.canChangeSession && generation.canChangeSession
    }

    init(pending: NativePendingCoordinator = .shared, health: HealthViewModel? = nil,
         things: NativeThingViewModel? = nil, controller: NativeControllerSessionDriver = NativeControllerSessionDriver()) {
        self.pending = pending
        self.controller = controller
        self.health = health ?? HealthViewModel(journal: pending, selectedReader: { try await controller.readHome() },
            pairedPowerSender: { try await controller.submitPower(view: $0, thing: $1, on: $2, operation: $3, journal: pending) },
            pairedReceiptReader: { try await controller.readPowerReceipt($0) })
        self.things = things ?? NativeThingViewModel(selectedReader: { try await controller.readThing(target: $0, probe: $1) })
        externalReports = NativeExternalReportViewModel(reader: { try await controller.readExternalReport(target: $0, key: $1) })
        externalProfiles = NativeExternalProfileViewModel(journal: pending, controller: controller)
        authoring = NativeAuthoringReadViewModel(reader: { try await controller.readAuthoring($0) })
        authoringOperations = NativeAuthoringViewModel(journal: pending,
            preparer: { try await controller.prepareAuthoring(kind: $0, originalURL: $1, payloadURL: $2) },
            sender: { try await controller.submitAuthoring($0, journal: pending) },
            deliverySender: { try await controller.submitAuthoringDelivery($0, journal: pending) },
            draftPreparer: { try await controller.prepareManualDraftImport($0) },
            draftSender: { try await controller.submitManualDraftImport($0, journal: pending) },
            assessmentPreparer: { try await controller.prepareManualDraftAssessment($0, instruction: $1) },
            reviewPreparer: { try await controller.prepareAuthoringReview(candidateEpoch: $0, candidateOperation: $1, evidenceURL: $2) },
            dataPreparer: { try await controller.prepareAuthoringDataImport(kind: $0, url: $1) },
            selectedAssessmentPreparer: { try await controller.prepareManualDraftAssessment($0, instruction: $1, selectionURL: $2) },
            editedReviewPreparer: { try await controller.prepareAuthoringReview(candidateEpoch: $0, candidateOperation: $1, content: $2) },
            mappingLoader: { try await controller.loadMappingEditorContext() },
            mappingPreparer: { try await controller.prepareMappingDraftImport(context: $0, fields: $1) })
        generation = NativeGenerationViewModel(controller: controller, journal: pending)
        maintenance = MaintenanceViewModel(journal: pending)
        profiles = ProfilesViewModel(journal: pending)
        access = NativeAccessViewModel(journal: pending)
        rules = NativeRuleViewModel(journal: pending)
        schedules = NativeScheduleViewModel(journal: pending)
        controller.installLocalFence()
        bind()
        let publishers: [ObservableObjectPublisher] = [setup.objectWillChange, self.health.objectWillChange,
            maintenance.objectWillChange, profiles.objectWillChange, network.objectWillChange, mqtt.objectWillChange,
            pending.objectWillChange, access.objectWillChange, rules.objectWillChange,
            schedules.objectWillChange, self.things.objectWillChange, externalReports.objectWillChange, externalProfiles.objectWillChange, authoring.objectWillChange, authoringOperations.objectWillChange, generation.objectWillChange, generation.workspace.objectWillChange, controller.objectWillChange]
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
        health.powerRequestsAllowed = { [weak self] in self?.canChangeSession == true }
        setup.changesAllowed = { [weak self] in self?.controller.localSelected == true && self?.canChangeSession == true }
        setup.checkAllowed = { [weak self] in self?.controller.localSelected == true && self?.busy == false }
        setup.ownerChecked = { [weak self] owner in
            guard let self else { return }
            pending.observedOwner(owner)
            health.invalidateSessionView(); things.invalidateSessionView(); externalReports.invalidateSessionView(); externalProfiles.invalidate(clearReads: true); authoring.invalidateSessionView(); authoringOperations.invalidateSessionView(); generation.invalidate()
            rules.invalidateSessionView(); schedules.invalidateSessionView()
        }
        pending.didResolve = { [weak self] entry in
            guard let self else { return }
            health.originalResolved(entry); maintenance.originalResolved(entry); profiles.originalResolved(entry)
            access.originalResolved(entry); rules.originalResolved(entry); schedules.originalResolved(entry)
        }
        network.changesAllowed = { [weak self] in self?.controller.localSelected == true && self?.canChangeSession == true }
        mqtt.workAllowed = { [weak self] in self?.busy == false && self?.pending.canStart == true }
        mqtt.localSelected = { [weak self] in self?.controller.localSelected == true }
        self.health.receiptRequestsAllowed = { [weak self] in self?.busy == false }
        self.health.localReceiptAllowed = { [weak self] in self?.controller.localSelected == true }
        setup.selectionChanged = { [weak self] in self?.invalidateSessionViews() }
        access.didChangeAccess = { [weak self] in
            guard let self else { return }
            health.invalidateSessionView(); profiles.invalidateSessionView(); rules.invalidateSessionView()
            schedules.invalidateSessionView(); things.invalidateSessionView(); externalReports.invalidateSessionView(); externalProfiles.invalidate(clearReads: true); authoring.invalidateSessionView(); authoringOperations.invalidateSessionView(); generation.invalidate()
        }
        externalProfiles.workAllowed = { [weak self] in self?.busy == false }
        authoring.workAllowed = { [weak self] in self?.busy == false }
        authoring.sourceAllowed = { [weak self] in self?.controller.needsReload == false }
        authoringOperations.workAllowed = { [weak self] in self?.busy == false && self?.controller.needsReload == false }
        generation.workAllowed = { [weak self] in self?.busy == false && self?.controller.needsReload == false }
        generation.didAssess = { [weak self] in self?.authoringOperations.useGeneratedCandidate($0) }
        things.changesAllowed = { [weak self] in self?.busy == false && self?.pending.canStart == true }
        things.didRefreshReports = { [weak self] in self?.health.invalidateSessionView() }
        rules.didChangeRules = { [weak self] in self?.health.invalidateSessionView(); self?.schedules.invalidateSessionView() }
        schedules.didChangeSchedules = { [weak self] in self?.health.invalidateSessionView(); self?.rules.invalidateSessionView() }
        rules.didStageInvocation = { [weak self] epoch, operation in
            self?.health.authorityEpochInput = String(epoch); self?.health.operationIDInput = operation
        }
    }
    private func invalidateSessionViews() {
        mqtt.invalidate()
        health.invalidateSessionView(); maintenance.invalidateSessionView(); profiles.invalidateSessionView()
        access.invalidateSessionView(); rules.invalidateSessionView(); schedules.invalidateSessionView(); things.invalidateSessionView(); externalReports.invalidateSessionView(); externalProfiles.invalidate(clearReads: true); authoring.invalidateSessionView(); authoringOperations.invalidateSessionView(); generation.invalidate()
    }
    func hostAvailabilityChanged() {
        mqtt.invalidate()
        health.invalidateSessionView()
        things.hostDidWake()
        externalReports.hostDidWake()
        externalProfiles.invalidate(clearReads: true)
        authoring.hostDidWake()
        authoringOperations.hostDidWake()
        generation.invalidate()
    }
}
