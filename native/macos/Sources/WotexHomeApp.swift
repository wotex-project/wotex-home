import ServiceManagement
import SwiftUI

@MainActor
final class HealthViewModel: ObservableObject {
    @Published var credentialInput = ""
    @Published var authorityEpochInput = ""
    @Published var operationIDInput = ""
    @Published var enrollmentReviewRefInput = ""
    @Published var overrideAuthorityEpochInput = ""
    @Published var overrideOperationIDInput = ""
    @Published private(set) var summary = "No health check yet"
    @Published private(set) var detail = ""
    @Published private(set) var executionDetail = ""
    @Published private(set) var unknownWarning = false
    @Published private(set) var observations: [HomeObservation] = []
    @Published private(set) var things: [HomeThing] = []
    @Published private(set) var overrides: [HomeOverride] = []
    @Published private(set) var catalogueDetail = "No catalogue yet"
    @Published private(set) var snapshotDetail = "No snapshot yet"
    @Published private(set) var overrideDetail = "No override check yet"
    @Published private(set) var error: String?
    @Published private(set) var busy = false
    @Published private(set) var receiptBusy = false
    @Published private(set) var stageBusy = false
    @Published private(set) var receiptStatus = "No operation selected"
    @Published private(set) var receiptError: String?
    @Published private(set) var enrollmentBusy = false
    @Published private(set) var enrollmentStatus = "No enrollment review selected"
    @Published private(set) var enrollmentError: String?
    @Published private(set) var overrideBusy = false
    @Published private(set) var overrideStatus = "No override operation selected"
    @Published private(set) var overrideError: String?
    @Published var ruleAuthorityEpochInput = ""
    @Published var ruleOperationIDInput = ""
    @Published private(set) var ruleBusy = false
    @Published private(set) var ruleStatus = "No rule policy check yet"
    @Published private(set) var ruleError: String?
    private var currentStoreRevision: Int?
    private var currentAuthorityEpoch: Int?

    func refreshRules() {
        ruleBusy = true
        ruleError = nil
        Task {
            do {
                let status = try await Task.detached(priority: .userInitiated) {
                    try LocalHealthClient.fetchRuleStatus()
                }.value
                ruleStatus = "Rules \(status.state) · Generation \(status.generation) · Admission \(status.admissionRevision)"
                if let reason = status.reason { ruleStatus += " · \(reason)" }
                if currentAuthorityEpoch != status.authorityEpoch { currentStoreRevision = nil }
            } catch {
                ruleStatus = "Rule policy unavailable"
                ruleError = error.localizedDescription
            }
            ruleBusy = false
        }
    }

    func suspendRules() {
        guard let epoch = currentAuthorityEpoch, let revision = currentStoreRevision else {
            ruleError = "Refresh the Home view before suspending rules."
            return
        }
        let operation = "suspend:" + UUID().uuidString.lowercased()
        ruleAuthorityEpochInput = String(epoch)
        ruleOperationIDInput = operation
        ruleBusy = true
        ruleError = nil
        ruleStatus = "Suspending rules…"
        Task {
            do {
                let receipt = try await Task.detached(priority: .userInitiated) {
                    try LocalHealthClient.suspendRules(authorityEpoch: epoch, operationID: operation, expectedRevision: revision)
                }.value
                currentStoreRevision = receipt.storeRevision
                ruleStatus = ruleActivationSummary(receipt)
            } catch {
                ruleStatus = "Suspension not confirmed; look up \(operation)"
                ruleError = error.localizedDescription
            }
            ruleBusy = false
        }
    }

    func lookupRuleOperation() {
        let operation = ruleOperationIDInput
        guard let epoch = Int(ruleAuthorityEpochInput), epoch >= 1 else {
            ruleError = LocalHealthError.invalidRuleRequest.localizedDescription
            return
        }
        ruleBusy = true
        ruleError = nil
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try LocalHealthClient.fetchRuleOperationStatus(authorityEpoch: epoch, operationID: operation)
                }.value
                switch result {
                case .activation(let receipt): ruleStatus = ruleActivationSummary(receipt)
                case .admission(let receipt): ruleStatus = "Admitted revision \(receipt.revision) · \(receipt.artifactDigest)"
                case .notFound: ruleStatus = "No rule receipt for \(operation) in epoch \(epoch)"
                }
            } catch {
                ruleStatus = "Rule operation status unavailable"
                ruleError = error.localizedDescription
            }
            ruleBusy = false
        }
    }

    private func ruleActivationSummary(_ receipt: HomeRuleActivation) -> String {
        let action = receipt.admissionRevision == 0 ? "Suspended" : "Activated"
        return "\(action) generation \(receipt.generation) · \(receipt.affectedRequests) affected requests · " +
            "\(receipt.unknownOutcomes) unknown outcomes at the activation barrier"
    }

    func issueOverride(_ thing: HomeThing) {
        guard thing.powerWritable, let epoch = currentAuthorityEpoch else {
            overrideError = "Refresh the scoped Home view before issuing an override."
            return
        }
        let operationID = "override:" + UUID().uuidString.lowercased()
        overrideAuthorityEpochInput = String(epoch)
        overrideOperationIDInput = operationID
        overrideStatus = "Issuing \(operationID)…"
        overrideError = nil
        overrideBusy = true
        Task {
            do {
                let receipt = try await Task.detached(priority: .userInitiated) {
                    try LocalHealthClient.issueOverride(
                        targetID: thing.id, basisRevision: thing.resourceRevision,
                        authorityEpoch: epoch, operationID: operationID,
                        durationMilliseconds: 900_000
                    )
                }.value
                overrideStatus = overrideSummary(receipt)
                overrideBusy = false
                refresh()
            } catch {
                overrideStatus = "Issue not confirmed; look up \(operationID)"
                overrideError = error.localizedDescription
                overrideBusy = false
            }
        }
    }

    func lookupOverride() {
        let operationID = overrideOperationIDInput
        guard let epoch = Int(overrideAuthorityEpochInput), epoch >= 1 else {
            overrideError = LocalHealthError.invalidOverrideRequest.localizedDescription
            return
        }
        overrideBusy = true
        overrideError = nil
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try LocalHealthClient.fetchOverrideStatus(
                        authorityEpoch: epoch, operationID: operationID
                    )
                }.value
                switch result {
                case .notFound:
                    overrideStatus = "No override receipt for \(operationID) in epoch \(epoch)"
                case .found(let receipt):
                    overrideStatus = overrideSummary(receipt)
                }
            } catch {
                overrideStatus = "Override status unavailable"
                overrideError = error.localizedDescription
            }
            overrideBusy = false
        }
    }

    func revokeOverride(_ item: HomeOverride) {
        guard let operationID = item.operationID else { return }
        overrideAuthorityEpochInput = String(item.authorityEpoch)
        overrideOperationIDInput = operationID
        revokeOverride()
    }

    func revokeOverride() {
        let operationID = overrideOperationIDInput
        guard let epoch = Int(overrideAuthorityEpochInput), epoch >= 1 else {
            overrideError = LocalHealthError.invalidOverrideRequest.localizedDescription
            return
        }
        overrideBusy = true
        overrideError = nil
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try LocalHealthClient.revokeOverride(
                        authorityEpoch: epoch, operationID: operationID
                    )
                }.value
                switch result {
                case .notFound:
                    overrideStatus = "No override receipt for \(operationID) in epoch \(epoch)"
                case .found(let receipt):
                    overrideStatus = overrideSummary(receipt)
                }
                overrideBusy = false
                refresh()
            } catch {
                overrideStatus = "Revoke not confirmed; look up \(operationID)"
                overrideError = error.localizedDescription
                overrideBusy = false
            }
        }
    }

    private func overrideSummary(_ receipt: HomeOverrideReceipt) -> String {
        let state = receipt.active ? "active" : "inactive"
        let remaining = receipt.remainingMilliseconds / 1_000
        return "\(receipt.operationID) · \(state) · \(remaining) s remaining · " +
            "Issue revision \(receipt.issueRevision)" +
            (receipt.revokeRevision.map { " · Revoked at \($0)" } ?? "")
    }

    func stagePower(_ thing: HomeThing, on: Bool) {
        guard thing.powerWritable, let epoch = currentAuthorityEpoch else {
            receiptError = "Refresh the scoped Home view before staging power."
            return
        }
        let operationID = "op:" + UUID().uuidString.lowercased()
        authorityEpochInput = String(epoch)
        operationIDInput = operationID
        receiptStatus = "Submitting \(operationID)…"
        receiptError = nil
        stageBusy = true
        Task {
            do {
                let receipt = try await Task.detached(priority: .userInitiated) {
                    try LocalHealthClient.submitPower(
                        targetID: thing.id, expectedRevision: thing.resourceRevision,
                        authorityEpoch: epoch, operationID: operationID, on: on
                    )
                }.value
                receiptStatus = "\(receipt.operationID) · \(receipt.disposition) · " +
                    "Revision \(receipt.revision)" +
                    (receipt.reason.map { " · \($0)" } ?? "")
                stageBusy = false
                refresh()
            } catch {
                receiptStatus = "Submission not confirmed; look up \(operationID)"
                receiptError = error.localizedDescription
                stageBusy = false
            }
        }
    }

    func lookupReceipt() {
        let operationID = operationIDInput
        guard let epoch = Int(authorityEpochInput), epoch >= 1 else {
            receiptError = LocalHealthError.invalidReceiptRequest.localizedDescription
            return
        }
        receiptBusy = true
        receiptError = nil
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try LocalHealthClient.fetchReceiptStatus(
                        authorityEpoch: epoch, operationID: operationID
                    )
                }.value
                switch result {
                case .notFound:
                    receiptStatus = "No receipt for \(operationID) in epoch \(epoch) " +
                        "in this credential's scope"
                case .found(let receipt):
                    receiptStatus = "\(receipt.operationID) · \(receipt.disposition) · " +
                        "Revision \(receipt.revision)" +
                        (receipt.reason.map { " · \($0)" } ?? "")
                }
            } catch {
                receiptStatus = "Receipt unavailable"
                receiptError = error.localizedDescription
            }
            receiptBusy = false
        }
    }

    func cancelPendingRequest() {
        let operationID = operationIDInput
        guard let epoch = Int(authorityEpochInput), epoch >= 1 else {
            receiptError = LocalHealthError.invalidReceiptRequest.localizedDescription
            return
        }
        receiptBusy = true
        receiptError = nil
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try LocalHealthClient.cancelRequest(
                        authorityEpoch: epoch, operationID: operationID
                    )
                }.value
                switch result {
                case .notFound:
                    receiptStatus = "No receipt for \(operationID) in epoch \(epoch) " +
                        "in this credential's scope"
                case .found(let receipt):
                    receiptStatus = "\(receipt.operationID) · \(receipt.disposition) · " +
                        "Revision \(receipt.revision)" +
                        (receipt.reason.map { " · \($0)" } ?? "")
                }
                receiptBusy = false
                refresh()
            } catch {
                receiptStatus = "Cancellation not confirmed; look up \(operationID)"
                receiptError = error.localizedDescription
                receiptBusy = false
            }
        }
    }

    func lookupEnrollmentReview() {
        let reviewRef = enrollmentReviewRefInput
        enrollmentBusy = true
        enrollmentError = nil
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try LocalHealthClient.fetchEnrollmentStatus(reviewRef: reviewRef)
                }.value
                switch result {
                case .notFound:
                    enrollmentStatus = "No enrollment review \(reviewRef) in this credential's scope"
                case .found(let review):
                    enrollmentStatus = "\(review.reviewRef) · \(review.thingID) · " +
                        "\(review.state) · Review revision \(review.reviewRevision) · " +
                        "Current binding revision \(review.bindingRevision) · " +
                        "Digest version \(review.digestVersion)"
                }
            } catch {
                enrollmentStatus = "Enrollment review unavailable"
                enrollmentError = error.localizedDescription
            }
            enrollmentBusy = false
        }
    }

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
                let (health, readView, activeOverrides) = try await Task.detached(priority: .userInitiated) {
                    let health = try LocalHealthClient.fetch()
                    let readView = try LocalHealthClient.fetchReadView()
                    guard health.authorityEpoch == readView.catalogue.authorityEpoch else {
                        throw LocalHealthError.invalidResponse
                    }
                    let overrides = try LocalHealthClient.fetchOverrides(
                        targetIDs: readView.catalogue.things.map(\.id)
                    )
                    return (health, readView, overrides)
                }.value
                summary = health.writable ? "Host store available" : "Host store unavailable"
                detail = "Revision \(health.revision) · Authority \(health.authorityEpoch) · " +
                    "Rule generation \(health.ruleGeneration) · " +
                    "\(health.activeThings) Things · \(health.activePrincipals) principals · " +
                    (health.dispatchEnabled ? "Dispatch enabled" : "Dispatch disabled")
                executionDetail = "\(health.heldRequests) held · \(health.queuedRequests) queued · " +
                    "\(health.claimedRequests) claimed · \(health.unknownOutcomes) unknown outcomes"
                unknownWarning = health.unknownOutcomes > 0
                currentAuthorityEpoch = health.authorityEpoch
                currentStoreRevision = readView.catalogue.watermark
                things = readView.catalogue.things
                overrides = activeOverrides
                overrideDetail = "\(activeOverrides.count) active overrides at refresh"
                catalogueDetail = "Catalogue revision \(readView.catalogue.watermark) · " +
                    "\(things.count) scoped Things"
                observations = readView.snapshot.observations
                snapshotDetail = "Snapshot revision \(readView.snapshot.watermark) · " +
                    "\(observations.count) scoped observations"
            } catch {
                summary = "Health unavailable"
                detail = ""
                executionDetail = ""
                unknownWarning = false
                currentAuthorityEpoch = nil
                currentStoreRevision = nil
                observations = []
                things = []
                overrides = []
                catalogueDetail = "Catalogue unavailable"
                snapshotDetail = "Snapshot unavailable"
                overrideDetail = "Overrides unavailable"
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
    @StateObject private var health = HealthViewModel()

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
                    .disabled(health.busy || health.credentialInput.isEmpty)
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
                                            .disabled(health.stageBusy || health.receiptBusy || health.busy)
                                        Button("Stage Off") { health.stagePower(thing, on: false) }
                                            .disabled(health.stageBusy || health.receiptBusy || health.busy)
                                        Button("Issue 15 min override") {
                                            health.issueOverride(thing)
                                        }
                                        .disabled(health.overrideBusy || health.busy)
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
                        .disabled(health.busy)
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
        }
        .frame(minWidth: 900, minHeight: 680)
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
