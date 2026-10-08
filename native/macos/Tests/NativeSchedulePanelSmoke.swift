import AppKit
import Darwin
import Foundation
import SwiftUI

private final class SchedulePanelCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Data
    init(_ bytes: Data) { self.bytes = bytes }
    func capture() -> LocalCredentialCapture { lock.withLock { LocalCredentialCapture(bytes: bytes, nativeReference: nil) } }
    func change(_ bytes: Data) { lock.withLock { self.bytes = bytes } }
}
private enum SchedulePanelSmokeError: Error { case assertion(Int), detail(Int, String) }
private final class ScheduleReadGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var started = false, released = false
    var didStart: Bool { condition.lock(); defer { condition.unlock() }; return started }
    func block() {
        condition.lock(); defer { condition.unlock() }; started = true
        let deadline = Date().addingTimeInterval(5)
        while !released && condition.wait(until: deadline) {}
    }
    func release() { condition.lock(); defer { condition.unlock() }; released = true; condition.broadcast() }
}

@main
struct NativeSchedulePanelSmoke {
    @MainActor static func main() async {
        do { try await run(); print("{\"complete\":true}") }
        catch SchedulePanelSmokeError.assertion(let line) { print("{\"complete\":false,\"line\":\(line)}") }
        catch SchedulePanelSmokeError.detail(let line, let reason) {
            let bytes = try! JSONSerialization.data(withJSONObject: ["complete": false, "line": line, "reason": reason])
            print(String(decoding: bytes, as: UTF8.self))
        }
        catch { print("{\"complete\":false,\"line\":0}") }
    }
    @MainActor private static func run() async throws {
        try check(CommandLine.arguments.count == 5)
        guard let line = readLine(), let fields = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: String],
              let original = decode(fields["original"]), let other = decode(fields["other"]) else { throw SchedulePanelSmokeError.assertion(#line) }
        let path = CommandLine.arguments[1], directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true), mode = CommandLine.arguments[3]
        let capture = SchedulePanelCapture(original)
        let readGate = ScheduleReadGate()
        let journal = NativePendingCoordinator(persistence: NativePendingPersistence(directory: directory), capture: { capture.capture() }, socketPath: { path })
        let client = NativeSchedulePanelClient(capture: { capture.capture() },
            identity: { try LocalHealthClient.fetchControllerIdentity(socketPath: path, credential: $0) },
            catalogue: { try LocalHealthClient.fetchCatalogue(socketPath: path, credential: $0) },
            timezone: { try NativeScheduleClient.timezone(socketPath: path, credential: $0, name: $1, local: $2) },
            current: { try NativeScheduleClient.current(socketPath: path, credential: $0, principal: $1) },
            source: { bytes, revision, principal in
                let source = try NativeScheduleClient.source(socketPath: path, credential: bytes, revision: revision, principal: principal)
                if mode == "reload-changed-custody" { capture.change(other) }
                if mode == "reload-selector-edited" || mode == "reload-session-fence" { readGate.block() }
                return source
            },
            deliver: { try NativeScheduleClient.deliver(socketPath: path, credential: $0, original: $1, principal: $2, lookup: $3) })
        let model = NativeScheduleViewModel(client: client, journal: journal)
        if mode == "interval-lifecycle" { try drafts() }
        journal.didResolve = { [weak model] in model?.originalResolved($0) }
        await journal.loadIfNeeded()
        try check(model.canReview && !model.canSubmit && model.canChangeSession)
        model.draft.target = "light:schedule-fixture"; model.draft.kind = .interval
        model.draft.anchor = Date(timeIntervalSince1970: 100)
        if mode.hasPrefix("reload-") && !mode.hasSuffix("seed") {
            try check(!model.hasAdmission && model.retainedDetail.isEmpty && journal.entries.isEmpty)
            model.draft.target = "light:edited-draft"; model.draft.on = false
            if mode == "reload-selector-edited" || mode == "reload-session-fence" {
                let read = Task { await model.reloadAdmission() }
                let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
                while !readGate.didStart && DispatchTime.now().uptimeNanoseconds < deadline { try await Task.sleep(for: .milliseconds(10)) }
                try check(readGate.didStart && model.busy && !model.canChangeSession && !model.canSubmit)
                if mode == "reload-selector-edited" { model.admissionRevisionInput = "999" }
                else { model.invalidateSessionView() }
                readGate.release(); await read.value
                try check(!model.hasAdmission && model.retainedDetail.isEmpty && !model.canSubmit && journal.entries.isEmpty)
                if mode == "reload-session-fence" { try check(model.error == nil) }
                return
            }
            await model.reloadAdmission()
            if mode == "reload-lost-read" {
                try check(model.error != nil && !model.hasAdmission && !model.unconfirmed && journal.entries.isEmpty)
                await model.reloadAdmission()
            }
            if ["reload-missing", "reload-revoked", "reload-changed-custody", "reload-changed-controller"].contains(mode) {
                try check(!model.hasAdmission && !model.canSubmit && model.retainedDetail.isEmpty && journal.entries.isEmpty)
                try check((mode == "reload-changed-custody" || mode == "reload-changed-controller") == (model.error != nil))
                return
            }
            try check(model.error == nil && model.hasAdmission && !model.canSubmit && !model.unconfirmed && journal.entries.isEmpty)
            try check(model.retainedDetail.contains("light:schedule-fixture") && model.draft.target == "light:edited-draft" && !model.draft.on)
            if mode == "reload-calendar" { try check(model.retainedDetail.contains("Fixture/Stockholm") && model.retainedDetail.contains("Daily")); return }
            if mode == "reload-lost-read" { return }
            await model.prepare(.activate)
            try check(model.error == nil && model.decision == .activate && model.reviewDetail.contains("light:schedule-fixture") && model.reviewDetail.contains("Power On") && !model.canSubmit)
            if mode == "reload-activate" { try await preview(model, journal: journal, path: CommandLine.arguments[4].replacingOccurrences(of: ".png", with: "-reloaded.png"), width: 900) }
            model.confirmed = true; await model.submit()
            try check(model.error == nil && journal.entries.isEmpty && !model.unconfirmed)
            await model.refreshCurrent(); try check(model.error == nil && model.currentDetail.contains("Active"))
            return
        }
        if mode == "reload-calendar-seed" { model.draft.kind = .daily; model.draft.zone = "Fixture/Stockholm"; model.draft.localDate = "2040-10-28"; model.draft.localTime = "02:30:00" }
        if mode.hasPrefix("once") || mode.hasPrefix("daily") || mode.hasPrefix("weekdays") || mode == "utc-lifecycle" {
            model.draft.kind = mode.hasPrefix("once") ? .once : mode.hasPrefix("daily") ? .daily : .weekdays
            model.draft.zone = "Fixture/Stockholm"; model.draft.localDate = mode == "daily-gap" ? "2026-03-29" : "2040-10-28"
            model.draft.localTime = "02:30:00"
            if mode == "utc-lifecycle" { model.draft.kind = .daily; model.draft.zone = "Etc/UTC" }
        }
        if mode == "once-fold" {
            await model.prepare(.admit)
            try check(model.decision == nil && !model.canSubmit && model.choices == [2_234_997_000_000,2_235_000_600_000])
            try check(journal.entries.isEmpty && !FileManager.default.fileExists(atPath: directory.appendingPathComponent("native-pending-v1.json").path))
            let revision = model.sourceRevision
            model.selectedInstant = model.choices[1]
            try check(model.sourceRevision == revision + 1 && !model.confirmed)
        }
        if mode == "interval-lifecycle" {
            await model.prepare(.record)
            try check(model.error == nil && model.decision == .record && !model.canSubmit && journal.entries.isEmpty)
            model.confirmed = true; await model.submit()
            try check(model.error == nil && !model.hasAdmission && journal.entries.isEmpty)
        }
        await model.prepare(.admit)
        try check(model.error == nil && model.decision == .admit && !model.canSubmit && journal.entries.isEmpty)
        if mode == "daily-gap" { try check(model.reviewDetail.contains("gap") && model.choices.isEmpty) }
        if mode == "weekdays-fold" { try check(model.reviewDetail.contains("first instant once")) }
        if mode == "edited" {
            model.confirmed = true; model.draft.on = false
            try check(!model.canSubmit && !model.confirmed && model.decision == nil)
            await model.submit(); try check(journal.entries.isEmpty)
            return
        }
        if mode == "changed-custody" { capture.change(other) }
        var lock: Int32 = -1
        if mode == "publication" {
            lock = open(directory.appendingPathComponent("native-pending-v1.lock").path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
            try check(lock >= 0 && flock(lock, LOCK_EX | LOCK_NB) == 0)
        }
        model.confirmed = true
        await model.submit()
        if mode == "publication" {
            _ = flock(lock, LOCK_UN); _ = Darwin.close(lock)
            try check(model.error != nil && !model.canSubmit && journal.needsReload && journal.entries.count == 1)
            await journal.reload()
            await journal.recover(journal.entries[0], action: .retry, custody: { _ in original }, execute: NativePendingRecoveryOperations.execute)
            try check(journal.error == nil && model.hasAdmission && journal.entries.isEmpty)
            return
        }
        if ["changed-custody", "changed-controller", "first-refused"].contains(mode) {
            try check(model.error != nil && !model.unconfirmed && !model.hasAdmission && !model.confirmed && journal.entries.isEmpty)
            try check(model.canReview && !model.canSubmit)
            return
        }
        if mode == "lost-reply" {
            try check(model.error != nil && model.unconfirmed && !model.canReview && !model.canChangeSession && journal.entries.count == 1)
            let entry = journal.entries[0]
            try check(try entry.scheduleOperation().source?.rule.target == "light:schedule-fixture")
            model.draft.target = "light:edited"; model.confirmed = true
            await model.submit(); await model.prepare(.admit); await model.reloadAdmission()
            try check(journal.entries == [entry] && !model.canSubmit)
            try await preview(model, journal: journal, path: CommandLine.arguments[4].replacingOccurrences(of: ".png", with: "-pending.png"), width: 480)
            await journal.recover(entry, action: .lookup, custody: { _ in original }, execute: NativePendingRecoveryOperations.execute)
            try check(model.hasAdmission && !model.unconfirmed && journal.entries.isEmpty && journal.error == nil)
            return
        }
        try check(model.error == nil && model.hasAdmission && !model.unconfirmed && journal.entries.isEmpty)
        if mode == "once-fold" {
            await model.prepare(.activate)
            try check(model.error == nil && model.reviewDetail.contains("2040-10-28") && model.reviewDetail.contains("Chosen UTC"))
            model.confirmed = true; await model.submit()
            try check(model.error?.contains("timezone_basis_changed") == true && journal.entries.isEmpty && model.hasAdmission)
        }
        if mode == "interval-lifecycle" || mode == "utc-lifecycle" {
            await model.prepare(.activate)
            try check(model.error == nil && model.decision == .activate && !model.canSubmit)
            if mode == "interval-lifecycle" { try await preview(model, journal: journal, path: CommandLine.arguments[4], width: 480) }
            model.confirmed = true; await model.submit()
            if let error = model.error { throw SchedulePanelSmokeError.detail(#line, error) }
            try check(model.error == nil && journal.entries.isEmpty)
            await model.refreshCurrent(); try check(model.error == nil && model.currentDetail.contains("Active"))
            await model.prepare(.suspend)
            try check(model.error == nil && model.decision == .suspend && !model.canSubmit)
            model.confirmed = true; await model.submit()
            try check(model.error == nil && journal.entries.isEmpty)
            await model.refreshCurrent(); try check(model.error == nil && model.currentDetail.contains("Suspended"))
        }
        if mode == "weekdays-fold" { try await preview(model, journal: journal, path: CommandLine.arguments[4].replacingOccurrences(of: ".png", with: "-weekdays.png"), width: 900) }
    }
    @MainActor private static func preview(_ model: NativeScheduleViewModel, journal: NativePendingCoordinator, path: String, width: CGFloat) async throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        let content = ScrollView { VStack(alignment: .leading, spacing: 16) { NativeSchedulePanel(schedules: model); Divider(); NativePendingPanel(journal: journal, recoveryAllowed: true) } }
            .padding(24).frame(width: width, height: 1100, alignment: .topLeading).background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .light)
        let hosting = NSHostingView(rootView: content); hosting.frame = NSRect(x: 0, y: 0, width: width, height: 1100)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting; window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(200)); hosting.layoutSubtreeIfNeeded(); hosting.displayIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { throw SchedulePanelSmokeError.assertion(#line) }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let bytes = bitmap.representation(using: .png, properties: [:]) else { throw SchedulePanelSmokeError.assertion(#line) }
        try bytes.write(to: URL(fileURLWithPath: path))
    }
    private static func decode(_ text: String?) -> Data? {
        guard let text, text.count == 43 else { return nil }
        return Data(base64Encoded: text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "=")
    }
    private static func drafts() throws {
        var draft = NativeScheduleDraft()
        draft.target = "light:one"; draft.kind = .interval; draft.anchor = Date(timeIntervalSince1970: 100)
        draft.boundedStart = true; draft.start = Date(timeIntervalSince1970: 100)
        draft.lateSeconds = "10"; draft.toleranceMilliseconds = "100"
        let source = try draft.source(id: "schedule:one", revision: 2, principal: "operator:one", resource: 4, timezone: nil, choice: nil)
        try check(try NativeScheduleWire.digest(.admit(epoch: 7, operation: "schedule:admit", expected: 9, source: source)) == "1733caf36b0a194037c5fba75126eaa4285ea779d9062c9c28e6ab507a3e8a42")
        for text in ["", "01", "-1", "1.0", " 1", "1 ", "true", "9223372036854775808"] {
            try refused { _ = try NativeScheduleDraft.integer(text) }
        }
        try refused { _ = try NativeScheduleDraft.integer("9223372036854775807", multiplier: 60_000) }
        for date in [Date(timeIntervalSince1970: -1), Date(timeIntervalSince1970: .infinity), Date(timeIntervalSince1970: .nan)] {
            try refused { _ = try NativeScheduleDraft.milliseconds(date) }
        }
        try check(try NativeScheduleDraft.milliseconds(Date(timeIntervalSince1970: 1.125)) == 1_125)
        for period in ["0", "44641"] {
            var invalid = draft; invalid.periodMinutes = period
            try refused { _ = try invalid.source(id: "schedule:one", revision: 2, principal: "operator:one", resource: 4, timezone: nil, choice: nil) }
        }
        draft.kind = .once; draft.zone = "Fixture/Stockholm"; draft.localDate = "2040-10-28"; draft.localTime = "02:30:00"
        let zone = HomeScheduleTimezone(name: draft.zone, digest: String(repeating: "a", count: 64), localDateTime: "2040-10-28T02:30:00", instants: [2_234_997_000_000,2_235_000_600_000])
        try refused { _ = try draft.source(id: "schedule:one", revision: 2, principal: "operator:one", resource: 4, timezone: zone, choice: nil) }
        try refused { _ = try draft.source(id: "schedule:one", revision: 2, principal: "operator:one", resource: 4, timezone: zone, choice: 1) }
        let chosen = try draft.source(id: "schedule:one", revision: 2, principal: "operator:one", resource: 4, timezone: zone, choice: zone.instants[1])
        if case .once(_, _, _, _, let instant) = chosen.trigger { try check(instant == 2_235_000_600_000) }
        else { throw SchedulePanelSmokeError.assertion(#line) }
        draft.kind = .weekdays; draft.weekdays = []
        try refused { _ = try draft.source(id: "schedule:one", revision: 2, principal: "operator:one", resource: 4, timezone: zone, choice: nil) }
    }
    private static func refused(_ operation: () throws -> Void) throws {
        do { try operation() } catch is NativeScheduleError { return }
        throw SchedulePanelSmokeError.assertion(#line)
    }
    private static func check(_ value: Bool, line: Int = #line) throws { if !value { throw SchedulePanelSmokeError.assertion(line) } }
}
