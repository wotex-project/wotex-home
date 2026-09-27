import ServiceManagement
import SwiftUI

@MainActor
final class HealthViewModel: ObservableObject {
    @Published var credentialInput = ""
    @Published var authorityEpochInput = ""
    @Published var operationIDInput = ""
    @Published private(set) var summary = "No health check yet"
    @Published private(set) var detail = ""
    @Published private(set) var executionDetail = ""
    @Published private(set) var unknownWarning = false
    @Published private(set) var observations: [HomeObservation] = []
    @Published private(set) var things: [HomeThing] = []
    @Published private(set) var catalogueDetail = "No catalogue yet"
    @Published private(set) var snapshotDetail = "No snapshot yet"
    @Published private(set) var error: String?
    @Published private(set) var busy = false
    @Published private(set) var receiptBusy = false
    @Published private(set) var stageBusy = false
    @Published private(set) var receiptStatus = "No operation selected"
    @Published private(set) var receiptError: String?
    private var currentAuthorityEpoch: Int?

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
                let (health, readView) = try await Task.detached(priority: .userInitiated) {
                    (try LocalHealthClient.fetch(), try LocalHealthClient.fetchReadView())
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
                things = readView.catalogue.things
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
                observations = []
                things = []
                catalogueDetail = "Catalogue unavailable"
                snapshotDetail = "Snapshot unavailable"
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
            }
            Text(health.receiptStatus)
                .font(.callout)
            if let error = health.receiptError {
                Text(error)
                    .foregroundStyle(.red)
            }
            Text("A held receipt records a request. It does not mean a device changed state. If submission times out, look up the shown operation ID before trying again.")
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
                                        .disabled(health.stageBusy || health.busy)
                                    Button("Stage Off") { health.stagePower(thing, on: false) }
                                        .disabled(health.stageBusy || health.busy)
                                }
                            }
                            .font(.callout)
                        }
                    }
                }
                .frame(maxHeight: 160)
            }

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
        .frame(minWidth: 800, minHeight: 580)
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
