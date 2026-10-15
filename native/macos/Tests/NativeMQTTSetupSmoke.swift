import AppKit
import Foundation
import SwiftUI

private enum SetupSmokeError: Error { case failed }
private final class SetupCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var values = [0,0,0]
    func note(_ index: Int) -> Int { lock.withLock { values[index] += 1; return values[index] } }
    func count(_ index: Int) -> Int { lock.withLock { values[index] } }
}
private actor SetupLatch {
    private var open = false
    private var pending: CheckedContinuation<Void, Never>?
    func wait() async { if !open { await withCheckedContinuation { pending = $0 } } }
    func release() { open = true; pending?.resume(); pending = nil }
}

@main
struct NativeMQTTSetupSmoke {
    @MainActor
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { throw SetupSmokeError.failed }
        let bytes = try Data(contentsOf: URL(fileURLWithPath: "test/fixtures/mqtt/native-provision.json"))
        let vectors = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        let summary = try NativeMQTTProvisionWire.reply(Data((vectors["prepared"] as! String).utf8), kind: "prepared")
        let draft = NativeMQTTSetupDraft(summary: summary)
        do { _ = try await NativeMQTTSetupOperations.live.publish(draft, true); throw SetupSmokeError.failed }
        catch NativeMQTTProvisionError.unavailable {} // Inert metadata mints no seal.
        let counts = SetupCounts()
        let operations = NativeMQTTSetupOperations(
            prepare: { _,_ in _ = counts.note(0); try await Task.sleep(for: .milliseconds(20)); return draft },
            importCredential: { _,_ in _ = counts.note(1); try await Task.sleep(for: .milliseconds(20)) },
            publish: { _,retry in
                let count = counts.note(2)
                try await Task.sleep(for: .milliseconds(20))
                if count == 1 { guard !retry else { throw SetupSmokeError.failed }; throw NativeMQTTProvisionError.outcomeUnknown }
                guard retry else { throw SetupSmokeError.failed }; return summary
            })
        let model = NativeMQTTSetupViewModel(operations: operations)
        try check(counts.count(0) == 0 && !model.busy && model.summary == nil)
        model.localSelected = { false }; choose(model); model.prepare()
        try check(!model.authoringSelected && counts.count(0) == 0)
        model.localSelected = { true }; model.workAllowed = { false }; choose(model)
        try check(!model.sourceSelected)
        model.workAllowed = { true }; choose(model)
        model.prepare(); model.prepare(); try await finished(model)
        try check(counts.count(0) == 1 && model.summary == summary && !model.canPublish)
        try await render(model, name: "mqtt-setup-prepared.png", folder: CommandLine.arguments[1])
        model.importCredential(URL(fileURLWithPath: "/private/fixture/credential.json"))
        model.importCredential(URL(fileURLWithPath: "/private/fixture/second.json")); try await finished(model)
        try check(counts.count(1) == 1 && model.credentialImported && model.canPublish)
        model.publish(); model.publish(); try await finished(model)
        try check(counts.count(2) == 1 && model.uncertain && !model.canChangeSession && !model.canChoose && !model.canPrepare)
        model.selectSource(URL(fileURLWithPath: "/private/fixture/changed.json"))
        try check(model.summary == summary)
        try await render(model, name: "mqtt-setup-uncertain.png", folder: CommandLine.arguments[1])
        model.publish(); model.publish(); try await finished(model)
        try check(counts.count(2) == 2 && !model.uncertain && model.canChangeSession && model.error == nil)
        try await stale(draft)
        try await invalidatedPublication(draft)
        print("native MQTT setup explicit work, shared fences, late results and exact uncertain retry passed")
    }
    @MainActor private static func choose(_ model: NativeMQTTSetupViewModel) {
        model.selectAuthoring(URL(fileURLWithPath: "/private/fixture/authoring.json"))
        model.selectSource(URL(fileURLWithPath: "/private/fixture/mqtt.json"))
    }
    @MainActor private static func stale(_ draft: NativeMQTTSetupDraft) async throws {
        let counts = SetupCounts(), gate = SetupLatch()
        let model = NativeMQTTSetupViewModel(operations: NativeMQTTSetupOperations(
            prepare: { _,_ in _ = counts.note(0); await gate.wait(); return draft },
            importCredential: { _,_ in throw SetupSmokeError.failed }, publish: { _,_ in throw SetupSmokeError.failed }))
        choose(model); model.prepare()
        try await observed { counts.count(0) == 1 }
        model.invalidate(); await gate.release(); try await finished(model)
        try check(model.summary == nil && !model.credentialImported && !model.canPublish)
    }
    @MainActor private static func invalidatedPublication(_ draft: NativeMQTTSetupDraft) async throws {
        let counts = SetupCounts(), gate = SetupLatch()
        let model = NativeMQTTSetupViewModel(operations: NativeMQTTSetupOperations(
            prepare: { _,_ in draft }, importCredential: { _,_ in },
            publish: { _,retry in _ = counts.note(2); if !retry { await gate.wait() }; return draft.summary }))
        choose(model); model.prepare(); try await finished(model)
        model.importCredential(URL(fileURLWithPath: "/private/fixture/credential.json")); try await finished(model)
        model.publish(); try await observed { counts.count(2) == 1 }
        model.invalidate(); await gate.release(); try await finished(model)
        try check(model.uncertain && model.summary == draft.summary && !model.canChangeSession)
        model.publish(); try await finished(model)
        try check(!model.uncertain && counts.count(2) == 2)
    }
    @MainActor private static func finished(_ model: NativeMQTTSetupViewModel) async throws { try await observed { !model.busy } }
    @MainActor private static func observed(_ condition: () -> Bool) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + 3_000_000_000
        while !condition() { try check(DispatchTime.now().uptimeNanoseconds < deadline); try await Task.sleep(for: .milliseconds(10)) }
    }
    @MainActor private static func render(_ model: NativeMQTTSetupViewModel, name: String, folder: String) async throws {
        _ = NSApplication.shared
        let view = NSHostingView(rootView: VStack(alignment: .leading, spacing: 16) {
            Text("Local MQTT observations").font(.title2)
            NativeMQTTSetupPanel(mqtt: model)
        }.padding(24).frame(width: 620, height: 760, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .light))
        view.frame = NSRect(x: 0, y: 0, width: 620, height: 760)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; window.orderFront(nil); defer { window.close() }
        try await Task.sleep(for: .milliseconds(150)); view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw SetupSmokeError.failed }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw SetupSmokeError.failed }
        try data.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name), options: .atomic)
    }
    private static func check(_ value: Bool, line: UInt = #line) throws {
        if !value { FileHandle.standardError.write(Data("native MQTT setup assertion \(line) failed\n".utf8)); throw SetupSmokeError.failed }
    }
}
