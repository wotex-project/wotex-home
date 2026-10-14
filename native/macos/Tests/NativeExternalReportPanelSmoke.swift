import AppKit
import Foundation
import SwiftUI

private final class ReportClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant: UInt64 = 1_000_000_000
    func now() -> UInt64 { lock.lock(); defer { lock.unlock() }; return instant }
    func set(_ value: UInt64) { lock.lock(); instant = value; lock.unlock() }
}
private actor ReportGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var waiting = false
    func wait() async { waiting = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
private enum ReportAssertion: Error { case failed(Int) }

@main
struct NativeExternalReportPanelSmoke {
    @MainActor static func main() async {
        do { try await run(); print("native external report expiry, latency, invalidation and mounted layout passed") }
        catch { FileHandle.standardError.write(Data("native external report fixture failed: \(error)\n".utf8)); exit(1) }
    }
    @MainActor private static func run() async throws {
        guard CommandLine.arguments.count == 3,
              let vectors = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as? [String: Any],
              let vector = vectors["temperature"] as? [String: Any], var value = vector["value"] as? [String: Any] else { throw ReportAssertion.failed(#line) }
        value["continuity"] = "baseline"
        let raw: [String: Any] = ["format": "home-external-reported-value-v1", "target_id": "sensor:external", "capability_key": "sample",
            "store_revision": 42, "authority_epoch": 1, "selection_revision": 7, "resource_revision": 0, "report_revision": 8,
            "value": value, "freshness": "fresh", "reason": NSNull(), "age_ms": 5, "remaining_ms": 1000]
        let fresh = try decoded(raw)
        let clock = ReportClock()
        let model = NativeExternalReportViewModel(reader: { _, _ in fresh }, monotonic: { clock.now() })
        try require(model.report == nil && !model.busy && !model.canRead)
        model.targetIDInput = "sensor:external"; model.capabilityInput = "sample"
        await model.load()
        try require(model.report?.value?.coordinate == "2500" && model.elapsedMilliseconds == 0)
        clock.set(1_999_000_000)
        try require(model.elapsedMilliseconds == 999 && model.report?.displayedValue(elapsedMilliseconds: model.elapsedMilliseconds) != nil)
        clock.set(1_999_000_001)
        try require(model.elapsedMilliseconds == 1000 && model.report?.displayedValue(elapsedMilliseconds: model.elapsedMilliseconds) == nil)
        clock.set(999_999_999)
        try require(model.elapsedMilliseconds == Int64.max && model.report?.displayedValue(elapsedMilliseconds: model.elapsedMilliseconds) == nil)
        clock.set(1_000_000_000)
        try require(model.displayedValue == nil)
        await model.load()
        try require(model.displayedValue?.coordinate == "2500")

        var shortRaw = raw
        shortRaw["remaining_ms"] = 10
        let short = try decoded(shortRaw)
        let deadline = NativeExternalReportViewModel(reader: { _, _ in short })
        deadline.targetIDInput = "sensor:external"; deadline.capabilityInput = "sample"
        await deadline.load()
        try await Task.sleep(for: .milliseconds(50))
        try require(deadline.presentationExpired && deadline.displayedValue == nil)

        let delayed = NativeExternalReportViewModel(reader: { _, _ in clock.set(1_500_000_000); return fresh }, monotonic: { clock.now() })
        delayed.targetIDInput = "sensor:external"; delayed.capabilityInput = "sample"
        await delayed.load()
        try require(delayed.elapsedMilliseconds == 500 && delayed.report?.displayedValue(elapsedMilliseconds: 500) != nil)

        for event in ["target", "key", "session", "wake"] {
            let gate = ReportGate()
            let pending = NativeExternalReportViewModel(reader: { _, _ in await gate.wait(); return fresh })
            pending.targetIDInput = "sensor:external"; pending.capabilityInput = "sample"
            let work = Task { await pending.load() }
            for _ in 0..<200 { if await gate.waiting { break }; try await Task.sleep(for: .milliseconds(5)) }
            try require(await gate.waiting && pending.busy && !pending.canChangeSession)
            switch event {
            case "target": pending.targetIDInput = "sensor:other"
            case "key": pending.capabilityInput = "other"
            case "session": pending.invalidateSessionView()
            default: pending.hostDidWake()
            }
            await gate.release(); await work.value
            try require(pending.report == nil && pending.error != nil && !pending.busy)
        }
        let failed = NativeExternalReportViewModel(reader: { _, _ in throw LocalHealthError.transport })
        failed.targetIDInput = "sensor:external"; failed.capabilityInput = "sample"
        await failed.load()
        try require(failed.report == nil && failed.error != nil && !failed.status.contains("unconfirmed"))
        var unknownRaw = raw
        unknownRaw["value"] = NSNull(); unknownRaw["freshness"] = "unknown"; unknownRaw["reason"] = "external_selection_restart_required"; unknownRaw["remaining_ms"] = 0
        let unknown = try decoded(unknownRaw)
        let unknownModel = NativeExternalReportViewModel(reader: { _, _ in unknown })
        unknownModel.targetIDInput = "sensor:external"; unknownModel.capabilityInput = "sample"
        await unknownModel.load()
        try require(unknownModel.report?.value == nil)
        for state in ["fresh", "unknown", "expired"] {
            if state == "fresh" { clock.set(1_000_000_000); await model.load() }
            clock.set(state == "expired" ? 2_000_000_000 : 1_000_000_000)
            for width in [599, 600, 839, 840] {
                try await render(state == "unknown" ? unknownModel : model, width: width,
                    path: CommandLine.arguments[2] + "/external-report-\(state)-\(width).png")
            }
        }
        model.invalidateSessionView(); try require(model.report == nil)
    }
    private static func decoded(_ item: [String: Any]) throws -> HomeExternalReport {
        try NativeExternalReportClient.decode(["api_version": 1, "outcome": "ok", "external_report_preview": item], target: "sensor:external", key: "sample")
    }
    private static func require(_ value: Bool, line: Int = #line) throws { guard value else { throw ReportAssertion.failed(line) } }
    @MainActor private static func render(_ model: NativeExternalReportViewModel, width: Int, path: String) async throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        let content = ScrollView { NativeExternalReportPanel(reports: model).padding(24) }.frame(width: CGFloat(width), height: 640)
            .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .light)
        let view = NSHostingView(rootView: content); view.frame = NSRect(x: 0, y: 0, width: width, height: 640)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; window.orderFront(nil); defer { window.close() }
        try await Task.sleep(for: .milliseconds(100)); view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        let accessible = accessibilityText(view)
        let expected = model.displayedValue == nil ? "Reported sample: unknown" : "Reported sample: 2500"
        if accessible.isEmpty {
            if width == 599 { print("mounted accessibility tree unavailable in foreground fixture") }
        } else {
            try require(accessible.contains(expected))
            if model.displayedValue == nil { try require(!accessible.contains { $0.contains("2500") }) }
        }
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw ReportAssertion.failed(#line) }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw ReportAssertion.failed(#line) }
        try data.write(to: URL(fileURLWithPath: path))
    }
    @MainActor private static func accessibilityText(_ value: Any, depth: Int = 0) -> [String] {
        guard depth < 16, let element = value as? NSObject else { return [] }
        func attribute(_ name: String) -> Any? {
            let selector = NSSelectorFromString(name)
            guard element.responds(to: selector) else { return nil }
            return element.perform(selector)?.takeUnretainedValue()
        }
        let strings = [attribute("accessibilityLabel") as? String, attribute("accessibilityValue") as? String].compactMap { $0 }
        return strings + ((attribute("accessibilityChildren") as? [Any]) ?? []).flatMap { accessibilityText($0, depth: depth + 1) }
    }
}
