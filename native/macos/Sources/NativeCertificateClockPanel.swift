import SwiftUI

// Presentation-only actions. A fixture can exercise this model without being
// installed in the production source owner or providing its TLS producer.
struct NativeCertificateClockActions: Sendable {
    let begin: @Sendable () async throws -> Void
    let importResponse: @Sendable (URL, String) async throws -> Void
    let withdraw: @Sendable () -> Void
    let status: @Sendable () -> NativeCertificateClockStatus
}

@MainActor
final class NativeCertificateClockViewModel: ObservableObject {
    nonisolated private let owner: NativeCertificateClockOwner?
    private let actions: NativeCertificateClockActions
    @Published private(set) var snapshot = NativeCertificateClockStatus(phase: .unavailable,
        source: nil, procedure: nil, requestDigest: nil, requestURL: nil,
        remainingMilliseconds: nil, busy: false, error: nil)
    @Published private(set) var error: String?
    @Published private var inFlight: UUID?
    @Published var responsePath = "" {
        didSet { if oldValue != responsePath { selectionChanged() } }
    }
    private var generation: UInt64 = 0
    private var actionGeneration: UInt64?
    private var task: Task<Void, Never>?
    private var polling: Task<Void, Never>?
    var workAllowed: () -> Bool = { true }
    var didChange: () -> Void = {}

    init() {
        let owner = NativeCertificateClockOwner()
        self.owner = owner
        actions = NativeCertificateClockActions(begin: { _ = try await owner.begin() },
            importResponse: { _ = try await owner.importResponse($0, requestDigest: $1) },
            withdraw: { owner.withdraw() }, status: { owner.status() })
    }
    // Metadata/action seam only. It cannot supply a production clock.
    init(actions: NativeCertificateClockActions) { owner = nil; self.actions = actions }
    deinit { task?.cancel(); polling?.cancel() }

    nonisolated func clock() throws -> NativeControllerCertificateClock {
        guard let owner else { throw NativeCertificateClockError.clockUnavailable }
        return try owner.clock()
    }
    nonisolated func hasConfidence() -> Bool {
        guard let owner else { return false }
        let status = owner.status()
        return status.phase == .qualified && !status.busy
    }
    var busy: Bool { inFlight != nil || snapshot.busy }
    var canBegin: Bool { !busy && workAllowed() && [.unavailable, .withdrawn].contains(snapshot.phase) }
    var canImport: Bool {
        !busy && workAllowed() && [.requesting, .qualified].contains(snapshot.phase) &&
            snapshot.requestDigest != nil && validPath
    }
    var canWithdraw: Bool { busy || [.requesting, .qualified].contains(snapshot.phase) }
    private var validPath: Bool {
        responsePath.hasPrefix("/") && (1...4096).contains(responsePath.utf8.count) && !responsePath.utf8.contains(0)
    }
    var outcome: String? { error ?? snapshot.error.map(Self.message) }
    var status: String {
        switch snapshot.phase {
        case .unavailable: "Trusted certificate clock unavailable"
        case .requesting: "Waiting for a signed answer"
        case .qualified: "Signed time accepted"
        case .withdrawn: busy ? "Clock withdrawn · Waiting for work to retire" : "Clock withdrawn"
        }
    }
    func begin() {
        guard canBegin else { return }
        start { [actions] in try await actions.begin() }
    }
    func importResponse() {
        guard !busy, workAllowed(), [.requesting, .qualified].contains(snapshot.phase),
              let digest = snapshot.requestDigest else { return }
        guard validPath else { error = "Choose an absolute signed-answer file path, at most 4096 UTF-8 bytes."; return }
        let url = URL(fileURLWithPath: responsePath)
        start { [actions] in try await actions.importResponse(url, digest) }
    }
    func withdraw() {
        generation &+= 1; task?.cancel(); actions.withdraw(); error = nil
        refreshStatus(); didChange(); pollIfNeeded()
    }
    func selectionChanged() {
        // This source belongs to the app, not a selected controller. Preserve
        // an idle accepted source; revoke a possibly publishing active action.
        if inFlight != nil { withdraw() } else { error = nil }
    }
    func refreshStatus() {
        if inFlight != nil, actionGeneration != generation { actions.withdraw() }
        let before = snapshot, current = actions.status()
        snapshot = current
        if before.phase != current.phase || before.requestDigest != current.requestDigest { didChange() }
    }
    private func start(_ operation: @escaping @Sendable () async throws -> Void) {
        let nonce = UUID(), original = generation
        inFlight = nonce; actionGeneration = original; error = nil; didChange(); pollIfNeeded()
        task = Task { [weak self] in
            var failure: String?
            do { try await operation() } catch { failure = Self.message(error as? NativeCertificateClockError ?? .clockUnavailable) }
            guard let self, inFlight == nonce else { return }
            if original != generation || Task.isCancelled { actions.withdraw() }
            else { error = failure }
            inFlight = nil; actionGeneration = nil; task = nil; refreshStatus()
        }
    }
    private func pollIfNeeded() {
        guard polling == nil else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self else { return }
                refreshStatus()
                if !busy && ![.requesting, .qualified].contains(snapshot.phase) { polling = nil; return }
            }
        }
    }
    private static func message(_ error: NativeCertificateClockError) -> String {
        switch error {
        case .invalidDocument: "The signed answer or installed clock policy is invalid. Begin a fresh request after checking the source."
        case .scopeConflict: "The answer belongs to another request, policy or app. Keep the original request and check the answer."
        case .invalidSignature: "The answer does not match the installed issuer key. Begin a fresh request after checking the source."
        case .clockUnavailable: "Trusted time is unavailable. Check the installed source and begin a fresh request."
        case .expired: "The original clock request or source expired. Begin a fresh request."
        case .custodyConflict: "Clock files or app custody changed. Check the installed source and begin a fresh request."
        case .capacity: "Clock work is still active or retained request capacity is full. Wait for active work to retire."
        case .outcomeUnknown: "Clock-file publication is uncertain. No confidence was installed; begin a fresh request when work retires."
        }
    }
}

struct NativeCertificateClockPanel: View {
    @ObservedObject var clock: NativeCertificateClockViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(clock.status).font(.headline)
            Text("Use an installed, qualified local time source for paired controllers. A signed answer identifies the issuer; its accuracy depends on that source's qualification.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let source = clock.snapshot.source { Text("Source: \(source)").fixedSize(horizontal: false, vertical: true) }
            if let procedure = clock.snapshot.procedure { Text("Procedure: \(procedure)").font(.caption).fixedSize(horizontal: false, vertical: true) }
            if let remaining = clock.snapshot.remainingMilliseconds { Text("Original age remaining: \(remaining) ms").font(.caption).monospacedDigit() }
            if let url = clock.snapshot.requestURL {
                Text("Transfer this public request to the local issuer:").font(.callout)
                Text(url.path).font(.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            TextField("Absolute signed-answer file path", text: $clock.responsePath).textFieldStyle(.roundedBorder)
                .accessibilityLabel("Signed-answer file path")
            ViewThatFits(in: .horizontal) {
                HStack { controls }
                VStack(alignment: .leading) { controls }
            }
            if let outcome = clock.outcome { Text(outcome).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            Text("No request is sent automatically. Acceptance expires at its original deadline; use Begin again after withdrawal or expiry.")
                .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    private var controls: some View {
        Group {
            Button("Begin Clock Request") { clock.begin() }.disabled(!clock.canBegin)
            Button("Import Signed Answer") { clock.importResponse() }.disabled(!clock.canImport)
            Button("Withdraw Clock") { clock.withdraw() }.disabled(!clock.canWithdraw)
        }
    }
}
