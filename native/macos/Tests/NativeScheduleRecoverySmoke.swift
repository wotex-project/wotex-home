import Darwin
import AppKit
import Foundation
import SwiftUI

private enum ScheduleRecoverySmokeError: Error { case failed(Int) }

@main
struct NativeScheduleRecoverySmoke {
    @MainActor
    static func main() async {
        do { try await run(); print("{\"complete\":true}") }
        catch ScheduleRecoverySmokeError.failed(let line) { print("{\"complete\":false,\"line\":\(line)}") }
        catch { print("{\"complete\":false,\"line\":0}") }
    }
    @MainActor
    private static func run() async throws {
        try check(CommandLine.arguments.count == 6)
        let socket = CommandLine.arguments[1], directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let mode = CommandLine.arguments[3], stage = CommandLine.arguments[4]
        guard let line = readLine(), let values = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: String],
              let bytes = decode(values["original"]), let other = decode(values["other"]),
              let document = values["document"] else { throw ScheduleRecoverySmokeError.failed(#line) }
        let operation = try NativeScheduleWire.decode(Data(document.utf8))
        let journal = NativePendingCoordinator(persistence: NativePendingPersistence(directory: directory),
            capture: { LocalCredentialCapture(bytes: bytes, nativeReference: nil) }, socketPath: { socket })
        await journal.loadIfNeeded()
        try check(!journal.busy && !journal.needsReload)
        if stage == "create" {
            try check(journal.canStart && journal.entries.isEmpty)
            if mode == "admit-publication" {
                let lock = open(directory.appendingPathComponent("native-pending-v1.lock").path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
                try check(lock >= 0 && flock(lock, LOCK_EX | LOCK_NB) == 0)
                do { _ = try await journal.begin(.schedule(operation), authorityEpoch: 1, expectedCredential: bytes); throw ScheduleRecoverySmokeError.failed(#line) }
                catch NativePendingError.capacity {}
                _ = flock(lock, LOCK_UN); _ = Darwin.close(lock)
                try check(journal.needsReload && !journal.canStart && journal.entries.count == 1)
                await journal.reload()
                let entry = journal.entries[0]
                try check(journal.snapshot?.document.entries.isEmpty == true && !journal.canStart)
                await journal.recover(entry, action: .retry, custody: { _ in bytes }, execute: NativePendingRecoveryOperations.execute)
                try check(journal.error == nil && journal.canStart && journal.entries.isEmpty)
                return
            }
            let pending = try await journal.begin(.schedule(operation), authorityEpoch: 1, expectedCredential: bytes)
            try check(!journal.canStart && journal.entries == [pending.entry] && pending.entry.scheduleOperation() == operation)
            try check(journal.snapshot?.document.version == .v4 && journal.snapshot?.document.revision == 1)
            if mode == "admit-lookup" { try await preview(journal, path: CommandLine.arguments[5]) }
            do {
                _ = try await Task.detached { try NativeScheduleClient.deliver(socketPath: socket, credential: pending.bytes,
                    original: operation, principal: pending.entry.context.principal, lookup: false) }.value
                throw ScheduleRecoverySmokeError.failed(#line)
            } catch LocalHealthError.transport {}
            try check(journal.entries == [pending.entry] && !journal.canStart)
            return
        }
        if stage == "verify" {
            let retained = ["admit-missing", "admit-refused", "admit-scope"].contains(mode)
            try check(journal.snapshot?.document.version == .v4 && journal.snapshot?.document.revision == (retained ? 1 : 2))
            try check(journal.entries.count == (retained ? 1 : 0) && journal.canStart == !retained)
            if retained { try check(try journal.entries[0].scheduleOperation() == operation) }
            return // A fresh process reads only; it never recovers automatically.
        }
        try check(stage == "recover" && journal.entries.count == 1 && !journal.canStart)
        let entry = journal.entries[0], before = try Data(contentsOf: directory.appendingPathComponent("native-pending-v1.json"))
        try check(try entry.scheduleOperation() == operation)
        let action: NativePendingRecoveryAction = mode.hasSuffix("retry") || mode == "admit-unsubmitted" ? .retry : .lookup
        // The existing-only custody opener cannot substitute another account's
        // credential even when that account has the same permissions and target.
        await journal.recover(entry, action: action, custody: { _ in other }, execute: NativePendingRecoveryOperations.execute)
        try check(journal.error != nil && journal.entries == [entry] && Data(contentsOf: directory.appendingPathComponent("native-pending-v1.json")) == before)
        await journal.recover(entry, action: action, custody: { _ in bytes }, execute: NativePendingRecoveryOperations.execute)
        if ["admit-missing", "admit-refused", "admit-scope", "admit-tampered"].contains(mode) {
            try check(journal.entries == [entry] && !journal.canStart && Data(contentsOf: directory.appendingPathComponent("native-pending-v1.json")) == before)
            try check(mode == "admit-missing" ? journal.error == nil : journal.error != nil)
            if mode != "admit-tampered" { return }
            await journal.recover(entry, action: .lookup, custody: { _ in bytes }, execute: NativePendingRecoveryOperations.execute)
        }
        try check(journal.error == nil && journal.canStart && journal.entries.isEmpty)
        try check(journal.snapshot?.document.version == .v4 && journal.snapshot?.document.revision == 2)
    }
    private static func decode(_ text: String?) -> Data? {
        guard let text, text.count == 43 else { return nil }
        return Data(base64Encoded: text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "=")
    }
    @MainActor
    private static func preview(_ journal: NativePendingCoordinator, path: String) async throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        let content = NativePendingPanel(journal: journal, recoveryAllowed: true).padding(24)
            .frame(width: 480, height: 370, alignment: .topLeading).background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .light)
        let hosting = NSHostingView(rootView: content)
        hosting.frame = NSRect(x: 0, y: 0, width: 480, height: 370)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting; window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(200))
        hosting.layoutSubtreeIfNeeded(); hosting.displayIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { throw ScheduleRecoverySmokeError.failed(#line) }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let bytes = bitmap.representation(using: .png, properties: [:]) else { throw ScheduleRecoverySmokeError.failed(#line) }
        try bytes.write(to: URL(fileURLWithPath: path))
    }
    private static func check(_ value: Bool, line: Int = #line) throws {
        if !value { throw ScheduleRecoverySmokeError.failed(line) }
    }
}
