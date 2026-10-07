import AppKit
import Foundation
import SwiftUI

private final class MaintenanceCredentialSource: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Data
    private var captures = 0
    init(_ bytes: Data) { self.bytes = bytes }
    func load() -> Data { lock.withLock { bytes } }
    func capture() -> LocalCredentialCapture { lock.withLock { captures += 1; return LocalCredentialCapture(bytes: bytes, nativeReference: nil) } }
    func replace(_ value: Data) { lock.withLock { bytes = value } }
    var calls: Int { lock.withLock { captures } }
}
private enum MaintenancePanelSmokeError: Error { case failed, assertion(Int) }

@main
struct LiveMaintenancePanelSmoke {
    @MainActor
    static func main() async {
        do { try await run() }
        catch MaintenancePanelSmokeError.assertion(let line) { print("{\"complete\":false,\"line\":\(line)}") }
        catch { print("{\"complete\":false,\"line\":0}") }
    }
    @MainActor
    private static func run() async throws {
        guard CommandLine.arguments.count == 5, let line = readLine(),
              let secret = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: String],
              let original = decode(secret["original"]), let other = decode(secret["other"]) else { throw MaintenancePanelSmokeError.failed }
        let path = CommandLine.arguments[1], mode = CommandLine.arguments[2]
        let directory = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
        let source = MaintenanceCredentialSource(original)
        let journal = NativePendingCoordinator(persistence: NativePendingPersistence(directory: directory),
            capture: { source.capture() }, socketPath: { path })
        try require(source.calls == 0 && !journal.canStart)
        await journal.loadIfNeeded()
        try require(source.calls == 0 && journal.canStart)
        let model = MaintenanceViewModel(credentialLoader: { source.load() }, socketPath: { path }, journal: journal)
        model.refresh(); try await finished(model)
        try require(model.error == nil && model.canChangeSession)
        let ending = mode.hasPrefix("end-")
        try require(ending ? model.canEnd : model.canBegin)
        if mode.hasSuffix("changed") { source.replace(other) }
        if ending { model.end() } else { model.begin() }
        try await finished(model)
        let operation = model.operationIDInput
        try require(!operation.isEmpty && model.current == nil && source.calls == 1)
        if mode.hasSuffix("changed") {
            try require(model.error != nil && !model.hasUnconfirmedOperation && journal.entries.isEmpty && model.canChangeSession)
            try require(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("native-pending-v1.json").path))
        } else if mode.hasSuffix("first-refused") {
            try require(model.error != nil && !model.hasUnconfirmedOperation && journal.entries.isEmpty && model.canChangeSession)
            let empty = try NativePendingStorage.load(directory: directory)
            try require(empty.document.revision == 2 && empty.document.entries.isEmpty)
        } else {
            try require(model.hasUnconfirmedOperation && !model.canChangeSession && journal.entries.count == 1 && !journal.canStart)
            try require(Mirror(reflecting: model).children.isEmpty)
            let secondWindow = MaintenanceViewModel(credentialLoader: { source.load() }, socketPath: { path }, journal: journal)
            secondWindow.refresh(); try await finished(secondWindow)
            secondWindow.begin(); secondWindow.end()
            try require(!secondWindow.busy && secondWindow.operationIDInput.isEmpty && !secondWindow.canChangeSession)
            if mode == "begin-retry" { try await render(model, destination: CommandLine.arguments[4]) }
            source.replace(other)
            model.begin(); model.end()
            try require(!model.busy && model.operationIDInput == operation)
            if mode.hasSuffix("unsubmitted") {
                model.lookup(); try await finished(model)
                try require(model.hasUnconfirmedOperation && journal.entries.count == 1)
            }
            if mode.hasSuffix("refused") {
                for _ in 0..<2 {
                    model.retryOriginal(); try await finished(model)
                    try require(model.error != nil && model.hasUnconfirmedOperation && journal.entries.count == 1 && !model.canChangeSession)
                }
                model.lookup(); try await finished(model)
                try require(model.hasUnconfirmedOperation && journal.entries.count == 1 && source.calls == 1)
            } else {
                if mode.hasSuffix("lookup") { model.lookup() } else { model.retryOriginal() }
                try await finished(model)
                try require(model.error == nil && !model.hasUnconfirmedOperation && model.canChangeSession && journal.entries.isEmpty && source.calls == 1)
                let empty = try NativePendingStorage.load(directory: directory)
                try require(empty.document.revision == 2 && empty.document.entries.isEmpty)
            }
        }
        let output = try JSONSerialization.data(withJSONObject: ["complete": true, "operation": operation], options: .sortedKeys)
        print(String(decoding: output, as: UTF8.self))
    }
    @MainActor
    private static func finished(_ model: MaintenanceViewModel) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + 10_000_000_000
        while model.busy { try require(DispatchTime.now().uptimeNanoseconds < deadline); try await Task.sleep(for: .milliseconds(10)) }
    }
    @MainActor
    private static func render(_ model: MaintenanceViewModel, destination: String) async throws {
        _ = NSApplication.shared
        let content = HostMaintenancePanel(maintenance: model).padding(24).frame(width: 880, height: 350, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .light)
        let view = NSHostingView(rootView: content)
        view.frame = NSRect(x: 0, y: 0, width: 880, height: 350)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.title = "Private maintenance fixture"; window.contentView = view
        window.orderFront(nil); defer { window.close() }
        try await Task.sleep(for: .milliseconds(150))
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw MaintenancePanelSmokeError.failed }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let bytes = bitmap.representation(using: .png, properties: [:]) else { throw MaintenancePanelSmokeError.failed }
        try bytes.write(to: URL(fileURLWithPath: destination), options: .atomic)
    }
    private static func decode(_ value: String?) -> Data? {
        guard let value, value.count == 43 else { return nil }
        return Data(base64Encoded: value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "=")
    }
    private static func require(_ value: Bool, line: Int = #line) throws {
        if !value { throw MaintenancePanelSmokeError.assertion(line) }
    }
}
