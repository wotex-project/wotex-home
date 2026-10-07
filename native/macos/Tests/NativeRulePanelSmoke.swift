import AppKit
import Darwin
import Foundation
import SwiftUI

private enum RulePanelSmokeError: Error { case assertion(UInt) }
private final class RulePanelCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Data
    private var count = 0
    init(_ value: Data) { bytes = value }
    func capture() -> LocalCredentialCapture { lock.withLock { count += 1; return LocalCredentialCapture(bytes: bytes, nativeReference: nil) } }
    func replace(_ value: Data) { lock.withLock { bytes = value } }
    var calls: Int { lock.withLock { count } }
}

@main
struct NativeRulePanelSmoke {
    @MainActor static func main() async {
        do { try await run() }
        catch RulePanelSmokeError.assertion(let line) { print("{\"complete\":false,\"line\":\(line)}") }
        catch { print("{\"complete\":false,\"line\":0}") }
    }
    @MainActor private static func run() async throws {
        guard CommandLine.arguments.count == 5, let line = readLine(),
              let values = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: String],
              let original = decode(values["original"]), let other = decode(values["other"]) else { throw RulePanelSmokeError.assertion(#line) }
        let socket = CommandLine.arguments[1], mode = CommandLine.arguments[2]
        let directory = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
        let source = RulePanelCapture(original)
        let journal = NativePendingCoordinator(persistence: NativePendingPersistence(directory: directory), capture: { source.capture() }, socketPath: { socket })
        try require(source.calls == 0 && !journal.canStart)
        await journal.loadIfNeeded()
        try require(source.calls == 0 && !journal.needsReload)
        let client = NativeRulePanelClient(capture: { source.capture() },
            identity: { try LocalHealthClient.fetchControllerIdentity(socketPath: socket, credential: $0) },
            preview: { try NativeRuleClient.preview(socketPath: socket, credential: $0, rule: $1) },
            current: { try NativeRuleClient.current(socketPath: socket, credential: $0) },
            status: { try LocalHealthClient.fetchRuleStatus(socketPath: socket, credential: $0) },
            deliver: { try NativeRuleClient.deliver(socketPath: socket, credential: $0, original: $1, principal: $2, lookup: $3) })
        let model = NativeRuleViewModel(client: client, journal: journal)
        journal.didResolve = { [weak model] in model?.originalResolved($0) }
        if mode.hasPrefix("recover-") {
            try require(journal.entries.count == 1 && source.calls == 0 && !model.canReview)
            let entry = journal.entries[0]
            await journal.recover(entry, action: mode.hasSuffix("retry") ? .retry : .lookup, custody: { _ in original }, execute: NativePendingRecoveryOperations.execute)
            try require(journal.error == nil && journal.entries.isEmpty && model.hasAdmission && source.calls == 0)
            await model.prepare(.activate)
            try require(model.error == nil && model.decision == .activate && !model.canSubmit)
            model.confirmed = true; await model.submit()
            try require(model.error == nil && model.canReview && journal.canStart && !model.unconfirmed)
            print("{\"complete\":true}"); return
        }
        if mode == "invoke-restarted" {
            try require(journal.entries.isEmpty && source.calls == 0 && !model.hasAdmission)
            await model.refreshCurrent()
            try require(model.error == nil && model.currentDetail.contains("Active") && model.currentDetail.contains("light:rule-fixture"))
            await model.prepare(.invoke)
            try require(model.error == nil && model.reviewDetail.contains("light:rule-fixture") && !model.canSubmit)
            model.confirmed = true; await model.submit()
            try require(model.error == nil && model.status.contains("held") && !model.receiptOperationID.isEmpty && model.receiptEpoch == 1)
            try require(journal.canStart && journal.entries.isEmpty)
            print("{\"complete\":true}"); return
        }
        try require(journal.canStart && source.calls == 0)
        model.targetIDInput = "light:rule-fixture"
        let kind = String(mode.split(separator: "-").first!)
        if mode == "lifecycle" {
            for action in [NativeRuleDecision.record, .admit, .activate, .invoke, .suspend] {
                await model.prepare(action)
                try require(model.error == nil && model.decision == action && !model.canSubmit && journal.entries.isEmpty)
                if action == .admit { try await preview(model, journal: journal, path: CommandLine.arguments[4]) }
                model.confirmed = true; await model.submit()
                try require(model.error == nil && journal.canStart && journal.entries.isEmpty && !model.unconfirmed)
                if action == .record { try require(!model.hasAdmission && model.status.contains("Screening")) }
                if action == .admit { try require(model.hasAdmission && model.status.contains("admission")) }
                if action == .activate { try require(model.status.contains("activated")) }
                if action == .invoke { try require(model.status.contains("held") && !model.receiptOperationID.isEmpty) }
                if action == .suspend { try require(model.status.contains("suspended")) }
            }
            print("{\"complete\":true}"); return
        }
        if kind == "activate" || kind == "invoke" {
            await model.prepare(.admit); model.confirmed = true; await model.submit()
            try require(model.error == nil && model.hasAdmission && journal.canStart)
        }
        if kind == "invoke" {
            await model.prepare(.activate); model.confirmed = true; await model.submit()
            try require(model.error == nil && journal.canStart)
        }
        let action: NativeRuleDecision = kind == "review" ? .record : kind == "activate" ? .activate : kind == "invoke" ? .invoke : .admit
        await model.prepare(action)
        try require(model.error == nil && model.decision == action && !model.canSubmit && journal.entries.isEmpty)
        if mode == "admit-edited" {
            model.on = false; model.confirmed = true; await model.submit()
            try require(model.decision == nil && !model.canSubmit && model.canReview && journal.entries.isEmpty)
            print("{\"complete\":true}"); return
        }
        // Editing invalidates a source review; it cannot alter a retained input.
        if mode == "admit-changed" { source.replace(other) }
        model.confirmed = true
        let lock: Int32
        if mode == "admit-publication" {
            lock = open(directory.appendingPathComponent("native-pending-v1.lock").path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
            try require(lock >= 0 && flock(lock, LOCK_EX | LOCK_NB) == 0)
        } else { lock = -1 }
        await model.submit()
        if lock >= 0 { _ = flock(lock, LOCK_UN); _ = Darwin.close(lock) }
        if mode == "admit-changed" || mode == "admit-controller" {
            try require(model.error != nil && journal.entries.isEmpty && journal.canStart && !model.unconfirmed && !model.hasAdmission)
            print("{\"complete\":true}"); return
        }
        if mode == "admit-stale" || mode == "admit-first-refused" {
            try require(model.error != nil && journal.canStart && journal.entries.isEmpty && !model.unconfirmed && !model.hasAdmission)
            print("{\"complete\":true}"); return
        }
        if mode == "admit-publication" {
            try require(journal.needsReload && journal.entries.count == 1 && !journal.canStart)
            await journal.reload()
            try require(journal.entries.count == 1 && journal.snapshot?.document.entries.isEmpty == true)
            let entry = journal.entries[0]
            await journal.recover(entry, action: .lookup, custody: { _ in original }, execute: NativePendingRecoveryOperations.execute)
            try require(journal.error == nil && journal.entries == [entry] && !journal.canStart)
            await journal.recover(entry, action: .retry, custody: { _ in original }, execute: NativePendingRecoveryOperations.execute)
            try require(journal.error == nil && journal.entries.isEmpty && model.hasAdmission && journal.canStart)
            print("{\"complete\":true}"); return
        }
        try require(model.error != nil && model.unconfirmed && !model.canReview && journal.entries.count == 1)
        let entry = journal.entries[0]
        model.targetIDInput = "light:edited"; model.on = false
        let captures = source.calls
        await model.prepare(.admit); model.confirmed = true; await model.submit()
        try require(source.calls == captures && journal.entries == [entry] && model.unconfirmed && !model.canReview)
        if mode == "admit-lookup" { try await preview(model, journal: journal, path: CommandLine.arguments[4].replacingOccurrences(of: ".png", with: "-unconfirmed.png")) }
        if mode.contains("restart") { print("{\"complete\":true}"); return }
        if mode == "admit-refused" {
            for lookup in [true, false] { await model.recover(lookup: lookup); try require(model.error != nil && model.unconfirmed && journal.entries == [entry] && !journal.canStart) }
            await journal.recover(entry, action: .retry, custody: { _ in original }, execute: NativePendingRecoveryOperations.execute)
            try require(journal.error != nil && journal.entries == [entry] && !journal.canStart)
            print("{\"complete\":true}"); return
        }
        if mode == "admit-missing" || mode == "admit-lookup-tampered" {
            await model.recover(lookup: true)
            try require(model.unconfirmed && journal.entries == [entry] && !journal.canStart)
        }
        // Both model and shared runner resolve the exact retained source.
        if mode.hasSuffix("retry") || mode == "admit-unsubmitted" || mode == "admit-missing" { await model.recover(lookup: false) }
        else { await journal.recover(entry, action: .lookup, custody: { _ in original }, execute: NativePendingRecoveryOperations.execute) }
        try require(journal.error == nil && journal.entries.isEmpty && journal.canStart && !model.unconfirmed)
        if kind == "admit" { try require(model.hasAdmission) }
        try require(try NativePendingStorage.load(directory: directory).document.version == .v3)
        print("{\"complete\":true}")
    }
    private static func decode(_ value: String?) -> Data? {
        guard let value else { return nil }
        let padded = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + String(repeating: "=", count: (4 - value.count % 4) % 4)
        return Data(base64Encoded: padded)
    }
    private static func require(_ condition: Bool, line: UInt = #line) throws { guard condition else { throw RulePanelSmokeError.assertion(line) } }
    @MainActor private static func preview(_ model: NativeRuleViewModel, journal: NativePendingCoordinator, path: String) async throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        let content = VStack(alignment: .leading, spacing: 16) { NativeRulePanel(rules: model); Divider(); NativePendingPanel(journal: journal, recoveryAllowed: true) }.padding(24).frame(width: 900, height: 860, alignment: .topLeading).background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .light)
        let hosting = NSHostingView(rootView: content)
        hosting.frame = NSRect(x: 0, y: 0, width: 900, height: 860)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting; window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(200))
        hosting.layoutSubtreeIfNeeded(); hosting.displayIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { throw RulePanelSmokeError.assertion(#line) }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let bytes = bitmap.representation(using: .png, properties: [:]) else { throw RulePanelSmokeError.assertion(#line) }
        try bytes.write(to: URL(fileURLWithPath: path))
    }
}
