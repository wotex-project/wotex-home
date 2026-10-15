import AppKit
import Foundation
import SwiftUI

private enum PanelAssertion: Error { case failed(Int) }
private actor ClockPanelLatch {
    private var continuation: CheckedContinuation<Void, Never>?
    private var open = false
    func wait() async { if !open { await withCheckedContinuation { continuation = $0 } } }
    func release() { open = true; continuation?.resume(); continuation = nil }
}
private final class ClockPanelState: @unchecked Sendable {
    private let lock = NSLock()
    private var phase = NativeCertificateClockPhase.unavailable
    private var active = false
    private var counts = [0, 0, 0]
    private var imported: (String, String)?
    func begin() { lock.withLock { counts[0] += 1; phase = .requesting } }
    func accept(_ url: URL, _ digest: String) { lock.withLock { counts[1] += 1; imported = (url.path, digest); phase = .qualified } }
    func withdraw() { lock.withLock { counts[2] += 1; phase = .withdrawn } }
    func set(_ phase: NativeCertificateClockPhase, busy: Bool = false) { lock.withLock { self.phase = phase; active = busy } }
    var calls: [Int] { lock.withLock { counts } }
    var input: (String, String)? { lock.withLock { imported } }
    func status() -> NativeCertificateClockStatus {
        lock.withLock {
            let known = phase != .unavailable
            return NativeCertificateClockStatus(phase: phase,
                source: known ? "source:local-qualified-issuer" : nil,
                procedure: known ? "procedure:offline-source-qualification" : nil,
                requestDigest: known ? String(repeating: "d", count: 64) : nil,
                requestURL: known ? URL(fileURLWithPath: "/private/fixture/long-public-request-location/certificate-clock/request-generation-with-original-start/request.json") : nil,
                remainingMilliseconds: [.requesting, .qualified].contains(phase) ? 58_321 : nil,
                busy: active, error: nil)
        }
    }
    var actions: NativeCertificateClockActions {
        NativeCertificateClockActions(begin: { self.begin() },
            importResponse: { self.accept($0, $1) }, withdraw: { self.withdraw() }, status: { self.status() })
    }
}

@main
struct NativeCertificateClockPanelSmoke {
    @MainActor static func main() async {
        do {
            guard CommandLine.arguments.count == 2 else { throw PanelAssertion.failed(#line) }
            let state = ClockPanelState(), model = NativeCertificateClockViewModel(actions: state.actions)
            var changed = 0
            model.didChange = { changed += 1 }
            try require(state.calls == [0, 0, 0] && !model.busy && model.snapshot.phase == .unavailable)
            // A presentation seam cannot provide the production driver's clock.
            do { _ = try model.clock(); throw PanelAssertion.failed(#line) }
            catch NativeCertificateClockError.clockUnavailable {}
            try require(!model.hasConfidence())
            model.workAllowed = { false }; model.begin(); try require(state.calls == [0, 0, 0])
            model.workAllowed = { true }; model.begin(); model.begin()
            try await until { !model.busy }
            try require(state.calls == [1, 0, 0] && model.snapshot.phase == .requesting && changed > 0)
            for path in ["relative.json", "file:///private/answer.json", "/bad\0answer", "/" + String(repeating: "x", count: 4096)] {
                model.responsePath = path; model.importResponse()
                try require(state.calls[1] == 0 && model.error != nil && model.snapshot.phase == .requesting)
            }
            model.responsePath = "/private/fixture/signed answer.json"
            model.workAllowed = { false }; model.importResponse(); try require(state.calls[1] == 0)
            model.workAllowed = { true }; model.importResponse(); model.importResponse()
            try await until { !model.busy }
            try require(state.calls == [1, 1, 0] && model.snapshot.phase == .qualified && model.error == nil)
            try require(state.input?.0 == model.responsePath && state.input?.1 == String(repeating: "d", count: 64))
            let selected = model.snapshot.requestDigest
            model.selectionChanged(); model.responsePath = "/private/fixture/another answer.json"
            try require(model.snapshot.phase == .qualified && model.snapshot.requestDigest == selected && state.calls[2] == 0)
            try await render(model, width: 380, path: CommandLine.arguments[1] + "/narrow.png")
            try await render(model, width: 780, path: CommandLine.arguments[1] + "/wide.png")
            model.workAllowed = { false }; model.withdraw()
            try require(model.snapshot.phase == .withdrawn && state.calls[2] == 1 && model.snapshot.remainingMilliseconds == nil)

            for reason in 0..<3 { try await stale(reason: reason) }
            try await heldImport()
            try await retirementAndExpiry()
            try await production(root: CommandLine.arguments[1])
            print("native clock shared guards, fixed inputs, late-action refusal, retirement, production unsigned binding and narrow/wide panels passed")
        } catch {
            let detail: String
            if case PanelAssertion.failed(let line) = error { detail = "assertion \(line)" }
            else { detail = String(reflecting: type(of: error)) }
            FileHandle.standardError.write(Data("native clock panel fixture failed: \(detail)\n".utf8)); exit(1)
        }
    }
    @MainActor private static func stale(reason: Int) async throws {
        let state = ClockPanelState(), gate = ClockPanelLatch()
        let model = NativeCertificateClockViewModel(actions: NativeCertificateClockActions(
            begin: { state.begin(); await gate.wait(); state.set(.qualified) },
            importResponse: { _,_ in throw PanelAssertion.failed(#line) },
            withdraw: { state.withdraw() }, status: { state.status() }))
        model.begin(); try await until { state.calls[0] == 1 }
        if reason == 0 { model.responsePath = "/changed/input.json" }
        else if reason == 1 { model.selectionChanged() }
        else { model.withdraw() }
        try require(model.busy && model.snapshot.phase == .withdrawn && !model.canBegin)
        model.begin(); try require(state.calls[0] == 1)
        state.set(.qualified); model.refreshStatus()
        try require(model.snapshot.phase == .withdrawn) // Polling cannot publish a stale positive either.
        await gate.release(); try await until { !model.busy }
        try require(model.snapshot.phase == .withdrawn && state.calls[2] >= 2 && !model.hasConfidence())
    }
    @MainActor private static func heldImport() async throws {
        let state = ClockPanelState(), gate = ClockPanelLatch()
        let model = NativeCertificateClockViewModel(actions: NativeCertificateClockActions(
            begin: { state.begin() }, importResponse: { url,digest in await gate.wait(); state.accept(url, digest) },
            withdraw: { state.withdraw() }, status: { state.status() }))
        model.begin(); try await until { !model.busy }
        model.responsePath = "/original/answer with spaces.json"; model.importResponse()
        try require(model.busy)
        model.responsePath = "/changed/answer.json"; await gate.release()
        try await until { !model.busy }
        try require(state.input?.0 == "/original/answer with spaces.json" && model.snapshot.phase == .withdrawn)
    }
    @MainActor private static func retirementAndExpiry() async throws {
        let state = ClockPanelState()
        let model = NativeCertificateClockViewModel(actions: NativeCertificateClockActions(
            begin: { state.set(.withdrawn, busy: true); throw NativeCertificateClockError.expired },
            importResponse: { _,_ in throw PanelAssertion.failed(#line) },
            withdraw: { state.withdraw() }, status: { state.status() }))
        model.begin(); try await until { model.error != nil }
        try require(model.busy && !model.canBegin)
        state.set(.withdrawn); model.refreshStatus(); try require(!model.busy && model.canBegin)
        state.set(.qualified); model.refreshStatus()
        var changes = 0; model.didChange = { changes += 1 }
        state.set(.withdrawn); try await until { model.snapshot.phase == .withdrawn }
        try require(changes == 1)
    }
    @MainActor private static func production(root: String) async throws {
        let directory = URL(fileURLWithPath: root).appendingPathComponent("pending", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let journal = NativePendingCoordinator(persistence: NativePendingPersistence(directory: directory))
        let gate = ClockPanelLatch()
        let health = HealthViewModel(journal: journal, selectedReader: { await gate.wait(); throw PanelAssertion.failed(#line) })
        let app = HomeApplicationModel(pending: journal, health: health)
        try require(!app.busy && !app.certificateClock.hasConfidence() && !app.controller.pairedRecoveryAvailable)
        let driver = NativeControllerSessionDriver(certificateClock: { throw PanelAssertion.failed(#line) },
            certificateClockAvailable: { false })
        try require(!driver.pairedRecoveryAvailable)
        // Unloaded pending custody is itself a shared work guard, not an
        // invitation to ignore pending originals before setting up the clock.
        app.certificateClock.begin()
        try require(!app.certificateClock.busy && app.certificateClock.snapshot.phase == .unavailable)
        await journal.loadIfNeeded()
        try require(journal.canStart && app.canChangeSession)
        health.refresh()
        try require(app.busy)
        app.certificateClock.begin()
        try require(!app.certificateClock.busy && app.certificateClock.snapshot.phase == .unavailable)
        app.certificateClock.withdraw() // Confidence can be revoked while busy.
        await gate.release(); try await until { !health.busy }
        app.certificateClock.begin()
        try require(app.busy && !app.canChangeSession)
        try await until { !app.certificateClock.busy }
        try require(app.certificateClock.snapshot.phase == .withdrawn && app.certificateClock.outcome != nil && !app.busy)
        app.hostAvailabilityChanged()
        try require(app.certificateClock.snapshot.phase == .withdrawn && !app.certificateClock.hasConfidence())
        let rows = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath:
            "test/fixtures/controller_connections/native_pending_v5.json"))) as! [String: Any]
        let row = (rows["valid"] as! [[String: Any]]).first { $0["name"] as? String == "paired_power" }!
        let entry = try NativePendingDocument.decode(Data((row["body"] as! String).utf8)).entries[0]
        guard let empty = journal.snapshot else { throw PanelAssertion.failed(#line) }
        let retained = try NativePendingStorage.retaining(entry, directory: directory, expected: empty)
        await journal.reload()
        try require(journal.snapshot == retained && !journal.canStart && !app.canChangeSession && app.canPrepareCertificateClock)
        app.certificateClock.begin(); try require(app.busy && app.certificateClock.busy)
        try await until { !app.certificateClock.busy }
        try require(app.certificateClock.outcome != nil && journal.snapshot == retained && journal.entries == [entry])
        try NativePendingStorage.check(retained, directory: directory)
        try require(!app.canChangeSession && app.canPrepareCertificateClock)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath:
            directory.appendingPathComponent("native-pending-v1.json").path)
        await journal.reload()
        try require(journal.needsReload && !app.canPrepareCertificateClock)
        app.certificateClock.begin()
        try require(!app.certificateClock.busy && journal.entries == [entry])
    }
    @MainActor private static func until(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(7))
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw PanelAssertion.failed(#line) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    private static func require(_ condition: Bool, line: Int = #line) throws {
        guard condition else { throw PanelAssertion.failed(line) }
    }
    @MainActor private static func render(_ model: NativeCertificateClockViewModel, width: CGFloat, path: String) async throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        let view = NSHostingView(rootView: NativeCertificateClockPanel(clock: model)
            .padding(24).frame(width: width, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .light))
        let height = view.fittingSize.height
        try require(height.isFinite && height > 250 && height < 900)
        view.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; window.orderFront(nil); defer { window.close() }
        try await Task.sleep(for: .milliseconds(150)); view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw PanelAssertion.failed(#line) }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw PanelAssertion.failed(#line) }
        try png.write(to: URL(fileURLWithPath: path))
    }
}
