import AppKit
import Foundation
import SwiftUI

struct NativeThingPanelClient: Sendable {
    let capture: @Sendable () throws -> LocalCredentialCapture
    let identity: @Sendable (Data) throws -> HomeControllerIdentity
    let inspect: @Sendable (Data, String) throws -> HomeThingInspection
    let refresh: @Sendable (Data, String) throws -> HomeThingRefresh
    init(capture: @escaping @Sendable () throws -> LocalCredentialCapture = { try OperatorCredential.captureOriginal() },
         identity: @escaping @Sendable (Data) throws -> HomeControllerIdentity = { try LocalHealthClient.fetchControllerIdentity(socketPath: LocalHealthClient.defaultSocketPath(), credential: $0) },
         inspect: @escaping @Sendable (Data, String) throws -> HomeThingInspection = { try NativeThingClient.fetch(socketPath: LocalHealthClient.defaultSocketPath(), credential: $0, target: $1) },
         refresh: @escaping @Sendable (Data, String) throws -> HomeThingRefresh = { try NativeThingClient.refresh(socketPath: LocalHealthClient.defaultSocketPath(), credential: $0, target: $1) }) {
        self.capture = capture; self.identity = identity; self.inspect = inspect; self.refresh = refresh
    }
}

@MainActor
final class NativeThingViewModel: ObservableObject, CustomReflectable {
    nonisolated var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
    nonisolated private let client: NativeThingPanelClient
    nonisolated private let monotonic: @Sendable () -> UInt64
    private let selectedReader: (@Sendable (String, Bool) async throws -> (HomeThingInspection, HomeThingRefresh?))?
    @Published var targetIDInput = "" { didSet { if targetIDInput != oldValue { invalidate() } } }
    @Published private(set) var inspection: HomeThingInspection?
    @Published private(set) var busy = false
    @Published private(set) var status = "Choose an enrolled Thing and read its stored state."
    @Published private(set) var error: String?
    private var requestedAt: UInt64 = 0
    private var presentationGeneration: UInt64 = 0
    var changesAllowed: () -> Bool = { true }
    var didRefreshReports: (() -> Void)?
    init(client: NativeThingPanelClient = NativeThingPanelClient(), monotonic: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
         selectedReader: (@Sendable (String, Bool) async throws -> (HomeThingInspection, HomeThingRefresh?))? = nil) {
        self.client = client; self.monotonic = monotonic
        self.selectedReader = selectedReader
    }
    var canRead: Bool { !busy && LocalHealthClient.profileID(targetIDInput) }
    var canProbe: Bool { canRead && changesAllowed() }
    var canChangeSession: Bool { !busy }
    var elapsedMilliseconds: Int64 {
        let now = monotonic()
        guard now >= requestedAt else { return Int64.max }
        let elapsed = now - requestedAt
        // Round up: client redraws can only shorten the Store's remaining life.
        return Int64(min(UInt64(Int64.max), elapsed / 1_000_000 + (elapsed % 1_000_000 == 0 ? 0 : 1)))
    }
    private func invalidate() { presentationGeneration &+= 1; inspection = nil; error = nil; status = "Read stored state for the selected Thing." }
    func invalidateSessionView() { invalidate(); status = "Read the selected Thing under the current session." }
    func hostDidWake() { invalidate(); status = "Host availability changed. Read stored state or explicitly refresh the device." }
    func load(probe: Bool = false) async {
        guard probe ? canProbe : canRead else { return }
        let target = targetIDInput, started = monotonic(), generation = presentationGeneration
        busy = true; inspection = nil; error = nil; status = probe ? "Reading the enrolled device…" : "Reading stored evidence…"
        defer { busy = false }
        do {
            let result: (HomeThingInspection, HomeThingRefresh?)
            if let selectedReader { result = try await selectedReader(target, probe) }
            else { result = try await Task.detached(priority: .userInitiated) {
                let capture = try self.client.capture(), before = try self.client.identity(capture.bytes)
                if let reference = capture.nativeReference {
                    guard case .recover(let original) = try NativeBrokerWire.request(reference), original.valid, original.verifier == capture.verifier,
                          original.receipt.deployment == before.deploymentID, original.receipt.owner == before.ownerID,
                          original.receipt.epoch == before.authorityEpoch, original.receipt.principal == before.principalID,
                          before.revision >= original.receipt.revision else { throw LocalHealthError.nativeGuardConflict }
                }
                let refreshed = probe ? try self.client.refresh(capture.bytes, target) : nil
                let view = try self.client.inspect(capture.bytes, target), after = try self.client.identity(capture.bytes)
                guard before.matchesAuthority(after), view.thingID == target, view.principal == before.principalID,
                      view.epoch == before.authorityEpoch, view.revision >= before.revision, after.revision >= view.revision,
                      refreshed == nil || refreshed?.target == target else { throw LocalHealthError.nativeGuardConflict }
                return (view, refreshed)
            }.value }
            guard target == targetIDInput, generation == presentationGeneration else { throw LocalHealthError.sessionChanged }
            inspection = result.0; requestedAt = started
            status = result.1 == nil ? "Stored evidence read. This did not contact the device." : "Device read committed. Reports remain evidence of reported state."
            if result.1 != nil { didRefreshReports?() }
        } catch {
            self.error = error.localizedDescription
            status = probe ? "Device read unconfirmed. Read stored state before deciding whether to probe again." : "Stored evidence unavailable under this session."
        }
    }
}

struct NativeThingPanel: View {
    @ObservedObject var things: NativeThingViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Inspect a Thing").font(.headline)
            Text(things.status).fixedSize(horizontal: false, vertical: true)
            TextField("Enrolled Thing ID", text: $things.targetIDInput).textFieldStyle(.roundedBorder).disabled(things.busy)
            ViewThatFits(in: .horizontal) {
                HStack { readControls }
                VStack(alignment: .leading) { readControls }
            }
            if let view = things.inspection {
                Text("\(view.thingID) · \(view.role)").font(.title2).textSelection(.enabled)
                Text("\(view.profile) · Resource \(view.resourceRevision) · Store \(view.revision) · Authority \(view.epoch)")
                    .font(.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    ForEach(view.capabilities) { entry in capability(entry, view: view) }
                }
                Text("Session: \(view.principal)").font(.caption).textSelection(.enabled)
            }
            if let error = things.error { Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            Text("Stored reports, protocol acknowledgements and observed effects have separate meanings. A device read grants no access or physical qualification.")
                .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in things.hostDidWake() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)) { _ in things.hostDidWake() }
    }
    private var readControls: some View {
        Group {
            Button("Read Stored State") { Task { await things.load() } }.disabled(!things.canRead)
            Button("Read LIFX Device") { Task { await things.load(probe: true) } }.disabled(!things.canProbe)
        }
    }
    private func capability(_ entry: HomeInspectedCapability, view: HomeThingInspection) -> some View {
        let elapsed = things.elapsedMilliseconds, freshness = entry.displayedFreshness(elapsedMilliseconds: elapsed)
        return VStack(alignment: .leading, spacing: 6) {
            Divider()
            Text("\(entry.declaration.key) · \(entry.declaration.risk.capitalized) · \(entry.declaration.unit)").font(.headline)
            Text("Current: \(entry.displayedValue(elapsedMilliseconds: elapsed)?.text ?? "Unknown")")
                .font(.title3).accessibilityLabel("Current \(entry.declaration.key): \(entry.displayedValue(elapsedMilliseconds: elapsed)?.text ?? "unknown")")
            Text("Freshness: \(freshness.replacingOccurrences(of: "_", with: " ")) · Profile: \(entry.profileStatus.replacingOccurrences(of: "_", with: " "))")
                .foregroundStyle(freshness == "fresh" ? Color.primary : Color.orange).fixedSize(horizontal: false, vertical: true)
            if let report = entry.report {
                Text("Stored: \(report.value?.text ?? "Unknown") · \(report.quality) · \(report.trust.replacingOccurrences(of: "_", with: " "))")
                    .fixedSize(horizontal: false, vertical: true)
                Text("Received UTC ms: \(report.receivedTime) · Source UTC ms: \(report.sourceTime.map(String.init) ?? "Unavailable")")
                    .font(.caption).fixedSize(horizontal: false, vertical: true)
                DisclosureGroup("Observation evidence") {
                    Text("Report revision \(report.revision) · Source \(report.sourceEpoch) · Sequence \(report.sourceSequence)\nAdapter boot \(report.bootEpoch) · Adapter receive ms \(report.receivedMonotonic)\nStore receipt boot \(report.receiptEpoch ?? "Untimed") · Receipt ms \(report.receiptMonotonic.map(String.init) ?? "Unavailable")\nInspection boot \(view.storeBootEpoch) · Sample ms \(view.sampledMilliseconds)\nProfile \(entry.declaration.profile) · Evidence \(entry.declaration.evidence)\nDeclaration freshness \(entry.declaration.freshnessMilliseconds) ms · Operations \(entry.declaration.operations.joined(separator: ", "))")
                        .font(.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            } else { Text("No stored observation for this capability.").foregroundStyle(.secondary) }
        }.accessibilityElement(children: .contain)
    }
}
