import AppKit
import Darwin
import Foundation
import SwiftUI

private final class QuickFixtureSource: @unchecked Sendable {
    private let lock = NSCondition()
    private var bytes: Data
    private var captureCount = 0, loadCount = 0, saveCount = 0
    private var pauseLoad = false, waiting = false, released = false
    init(_ bytes: Data) { self.bytes = bytes }
    func capture() -> LocalCredentialCapture { lock.lock(); defer { lock.unlock() }; captureCount += 1; return LocalCredentialCapture(bytes: bytes, nativeReference: nil) }
    func load() -> Data {
        lock.lock(); defer { lock.unlock() }; loadCount += 1
        if pauseLoad { waitLocked() }
        return bytes
    }
    func saved() { lock.lock(); saveCount += 1; lock.unlock() }
    var saves: Int { lock.lock(); defer { lock.unlock() }; return saveCount }
    func pauseNextLoad() { lock.lock(); pauseLoad = true; lock.unlock() }
    func pauseInspection() { lock.lock(); defer { lock.unlock() }; waitLocked() }
    private func waitLocked() { waiting = true; while !released { lock.wait() } }
    func release() { lock.lock(); released = true; pauseLoad = false; lock.broadcast(); lock.unlock() }
    func replace(_ bytes: Data) { lock.lock(); self.bytes = bytes; lock.unlock() }
    var ready: Bool { lock.lock(); defer { lock.unlock() }; return waiting }
    var captures: Int { lock.lock(); defer { lock.unlock() }; return captureCount }
    var loads: Int { lock.lock(); defer { lock.unlock() }; return loadCount }
}
private enum QuickAssertion: Error { case failed(Int) }

@main struct HomeQuickBarSmoke {
    @MainActor static func main() async {
        do { try await run(); print("{\"complete\":true}") }
        catch QuickAssertion.failed(let line) { print("{\"complete\":false,\"line\":\(line)}") }
        catch { print("{\"complete\":false,\"line\":0}") }
    }
    @MainActor private static func run() async throws {
        guard CommandLine.arguments.count == 5, let line = readLine(),
              let values = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: String],
              let original = decode(values["original"]), let other = decode(values["other"]) else { throw QuickAssertion.failed(#line) }
        let path = CommandLine.arguments[1], directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let mode = CommandLine.arguments[3], preview = CommandLine.arguments[4], source = QuickFixtureSource(original)
        let journal = NativePendingCoordinator(persistence: NativePendingPersistence(directory: directory),
            capture: { source.capture() }, socketPath: { path })
        let health = HealthViewModel(credentialLoader: { source.load() }, socketPath: { path }, journal: journal, credentialSaver: { _ in
            source.saved(); if mode == "import-failed" { throw LocalHealthError.invalidCredential }
        })
        let thingClient = NativeThingPanelClient(capture: { LocalCredentialCapture(bytes: original, nativeReference: nil) },
            identity: { try LocalHealthClient.fetchControllerIdentity(socketPath: path, credential: $0) },
            inspect: { credential, target in
                let result = try NativeThingClient.fetch(socketPath: path, credential: credential, target: target)
                source.pauseInspection(); return result
            }, refresh: { _, _ in throw QuickAssertion.failed(#line) })
        let app = HomeApplicationModel(pending: journal, health: health, things: NativeThingViewModel(client: thingClient))
        try require(source.captures == 0 && source.loads == 0 && journal.snapshot == nil && !app.busy)
        // Mount the actual dropdown before any explicit read. Its task only loads
        // the journal, including on restored-process runs with a retained request.
        try await render(app, path: preview + "-startup.png", dark: false)
        try require(source.captures == 0 && source.loads == 0 && journal.snapshot != nil && !journal.needsReload)
        if mode.hasPrefix("restore-") {
            try require(journal.entries.count == 1 && !app.canChangeSession && !app.setup.changesAllowed() && !app.network.changesAllowed())
            try await render(app, path: preview + "-pending-dark.png", dark: true)
            let entry = journal.entries[0]
            await recover(journal, entry: entry, bytes: original, action: mode == "restore-retry" ? .retry : .lookup)
            try require(journal.entries.isEmpty && journal.canStart && source.loads == 0 && source.captures == 0)
            return
        }
        if mode.hasPrefix("import") {
            health.credentialInput = values["original"]!
            health.importCredential(); try await wait { !health.busy }
            try require(source.saves == 1 && source.captures == 0 && journal.entries.isEmpty)
            if mode == "import-failed" {
                try require(health.error != nil && !health.credentialInput.isEmpty && source.loads == 0)
            } else {
                try require(health.error == nil && health.credentialInput.isEmpty && health.things.count == 1 && source.loads == 1 &&
                    health.canStagePower(health.things[0]) && app.canChangeSession)
            }
            return
        }
        if mode == "wake-read" {
            source.pauseNextLoad(); health.refresh()
            try await wait { source.ready }
            try require(app.busy && !app.canChangeSession)
            app.hostAvailabilityChanged(); source.release()
            try await wait { !health.busy }
            try require(health.things.isEmpty && health.dispatchEnabled == nil && health.summary.contains("Refresh") && source.captures == 0)
            health.refresh(); try await wait { !health.busy }
            try require(health.error == nil && health.things.count == 1 && source.loads == 2)
            return
        }
        health.refresh(); try await wait { !health.busy }
        try require(health.error == nil && health.dispatchEnabled == false && source.loads == 1 && source.captures == 0)
        if mode == "empty-scope" {
            try require(health.things.isEmpty && !health.canStagePower(fakeThing()))
            health.stagePower(fakeThing(), on: true)
            try require(source.captures == 0 && health.operationIDInput.isEmpty && journal.entries.isEmpty)
            return
        }
        guard let thing = health.things.first else { throw QuickAssertion.failed(#line) }
        try require(thing.id == "light:menu-fixture" && health.observations.first?.valueText == "Off" && health.observations.first?.trust == "synthetic_lab")
        if mode == "read-only" {
            try require(!thing.powerWritable && !health.canStagePower(thing) && !health.canStagePower(fakeThing()))
            health.stagePower(fakeThing(), on: true)
            try require(source.captures == 0 && health.operationIDInput.isEmpty && journal.entries.isEmpty)
            try await render(app, path: preview + "-read-only.png", dark: false)
            return
        }
        try require(health.canStagePower(thing) && app.canChangeSession)
        // A stale or invented row can never create an operation, even if a
        // delayed menu event bypasses the disabled visual control.
        let stale = HomeThing(id: thing.id, role: thing.role, profileRef: thing.profileRef,
            capabilityCount: thing.capabilityCount, resourceRevision: thing.resourceRevision + 1, powerWritable: true)
        try require(!health.canStagePower(stale) && !health.canStagePower(fakeThing(id: "light:not-scoped")))
        health.stagePower(stale, on: true)
        try require(source.captures == 0 && health.operationIDInput.isEmpty)
        if mode == "busy-inspection" {
            app.things.targetIDInput = thing.id
            let work = Task { await app.things.load() }
            try await wait { source.ready }
            try require(app.busy && !app.canChangeSession && !health.canStagePower(thing) && !app.setup.changesAllowed() && !app.network.changesAllowed())
            health.stagePower(thing, on: true)
            try require(health.operationIDInput.isEmpty && source.captures == 0)
            source.release(); await work.value
            try require(app.things.error == nil && !app.busy && health.canStagePower(thing))
            return
        }
        if mode == "pending-rule" {
            _ = try await journal.begin(.suspend(operation: "rule:menu-fence", revision: 4), authorityEpoch: 1, expectedCredential: original)
            try require(!health.canStagePower(thing) && !app.canChangeSession && !app.setup.changesAllowed() && !app.network.changesAllowed() && !app.things.canProbe)
            let session = app.setup.session
            app.setup.endSession(); health.stagePower(thing, on: true)
            try require(app.setup.session == session && health.operationIDInput.isEmpty && source.captures == 1 && journal.entries.count == 1)
            try await render(app, path: preview + "-rule-pending.png", dark: false)
            return
        }
        if mode == "changed-custody" { source.replace(other) }
        var heldLock: Int32 = -1
        if mode == "publication" {
            heldLock = open(directory.appendingPathComponent("native-pending-v1.lock").path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
            try require(heldLock >= 0 && flock(heldLock, LOCK_EX | LOCK_NB) == 0)
        }
        defer { if heldLock >= 0 { _ = flock(heldLock, LOCK_UN); _ = Darwin.close(heldLock) } }
        health.stagePower(thing, on: mode != "off")
        try await wait { !health.stageBusy && !health.busy }
        try require(!health.operationIDInput.isEmpty && source.captures == 1 &&
            health.powerRequestDetail?.contains("Requested " + (mode == "off" ? "Off" : "On")) == true &&
            health.powerRequestDetail?.contains(thing.id) == true)
        if mode == "changed-custody" {
            try require(health.receiptError != nil && journal.entries.isEmpty && journal.canStart && health.receiptStatus.contains("not submitted"))
            return
        }
        if mode == "publication" {
            try require(journal.needsReload && !journal.canStart && journal.entries.count == 1 && !health.canStagePower(thing))
            _ = flock(heldLock, LOCK_UN); _ = Darwin.close(heldLock); heldLock = -1
            await journal.reload()
            try require(journal.entries.count == 1 && !journal.canStart)
            await recover(journal, entry: journal.entries[0], bytes: original, action: .retry)
            try require(journal.entries.isEmpty && journal.canStart && !health.hasUnconfirmedPower && health.receiptStatus.contains("reconciled"))
            return
        }
        if mode.hasSuffix("-create") {
            try require(health.hasUnconfirmedPower && journal.entries.count == 1 && !journal.canStart && !app.canChangeSession)
            let operation = health.operationIDInput
            health.stagePower(thing, on: false)
            try require(health.operationIDInput == operation && source.captures == 1)
            try await render(app, path: preview + "-pending.png", dark: false)
            return
        }
        if mode == "first-refused" {
            try require(health.receiptError != nil && journal.entries.isEmpty && !health.hasUnconfirmedPower && health.receiptStatus.contains("refused"))
            return
        }
        try require(health.receiptError == nil && health.receiptStatus.contains("held") && !health.hasUnconfirmedPower && journal.entries.isEmpty &&
            health.observations.first?.valueText == "Off" && health.dispatchEnabled == false && health.executionDetail.contains("1 held"))
        try await render(app, path: preview + "-" + mode + ".png", dark: false)
        try await render(app, path: preview + "-" + mode + "-dark.png", dark: true)
        // App-scope callbacks are installed without constructing a Home window.
        app.setup.selectManual()
        try require(health.things.isEmpty && health.dispatchEnabled == nil && !health.canStagePower(thing))
    }
    @MainActor private static func recover(_ journal: NativePendingCoordinator, entry: NativePendingEntry, bytes: Data, action: NativePendingRecoveryAction) async {
        await journal.recover(entry, action: action, custody: { retained in
            guard retained.custody.matches(bytes) else { throw QuickAssertion.failed(#line) }
            return bytes
        }, execute: NativePendingRecoveryOperations.execute)
    }
    private static func decode(_ value: String?) -> Data? {
        guard let value else { return nil }
        let bytes = Data(base64Encoded: value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "=")
        return bytes?.count == 32 ? bytes : nil
    }
    private static func fakeThing(id: String = "light:menu-fixture") -> HomeThing {
        HomeThing(id: id, role: "Light", profileRef: "fixture:menu:1", capabilityCount: 1, resourceRevision: 0, powerWritable: true)
    }
    private static func require(_ value: Bool, line: Int = #line) throws { guard value else { throw QuickAssertion.failed(line) } }
    @MainActor private static func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<1_000 { if predicate() { return }; try await Task.sleep(for: .milliseconds(5)) }
        throw QuickAssertion.failed(#line)
    }
    @MainActor private static func render(_ app: HomeApplicationModel, path: String, dark: Bool) async throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        let view = NSHostingView(rootView: HomeQuickBar(application: app, openHome: {}).environment(\.colorScheme, dark ? .dark : .light))
        view.frame = NSRect(x: 0, y: 0, width: 380, height: 600)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; window.orderFront(nil); defer { window.close() }
        try await Task.sleep(for: .milliseconds(200)); view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw QuickAssertion.failed(#line) }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw QuickAssertion.failed(#line) }
        try data.write(to: URL(fileURLWithPath: path))
    }
}
