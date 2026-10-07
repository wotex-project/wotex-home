import AppKit
import Foundation
import SwiftUI

private final class PreferenceInventorySource: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ["en0", "en1"] // Inert interface offers; no socket or admission.
    func names() -> [String] { lock.withLock { value } }
    func remove() { lock.withLock { value = [] } }
}
private enum NetworkPanelSmokeError: Error { case failed }

@main
struct NativeNetworkPanelSmoke {
    @MainActor
    static func main() async throws {
        guard CommandLine.arguments.count == 3 else { throw NetworkPanelSmokeError.failed }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let source = PreferenceInventorySource()
        let first = NativeNetworkViewModel(directory: directory, inventory: { source.names() })
        let second = NativeNetworkViewModel(directory: directory, inventory: { source.names() })
        try require(!first.canSave && !first.busy && first.names.isEmpty)
        first.refresh(); try await finished(first)
        second.refresh(); try await finished(second)
        try require(first.canSave && first.selected.isEmpty && first.error == nil)
        first.changesAllowed = { false }; first.selected = "en0"; first.save()
        try require(!first.busy && !FileManager.default.fileExists(atPath: directory.appendingPathComponent("native-network-v1.json").path))
        first.changesAllowed = { true }; first.save(); try await finished(first)
        try require(first.error == nil && first.status.contains("Next start") && first.status.contains("Stop and enable"))
        try require(try NativeCoreEnvironment.values(dataDirectory: directory)["WOTEX_HOME_LIFX_INTERFACE"] == "en0")
        second.selected = "en1"; second.save(); try await finished(second)
        try require(second.error != nil && !second.canSave)
        try require(try NativeNetworkPreferences.load(directory: directory).record.interface == "en0")
        second.refresh(); try await finished(second)
        try require(second.selected == "en0" && second.canSave)
        source.remove(); second.selected = "en1"; second.save(); try await finished(second)
        try require(second.error != nil && !second.canSave)
        second.refresh(); try await finished(second)
        try require(second.savedUnavailable == "en0" && !second.canSave)
        second.selected = ""; second.save(); try await finished(second)
        try require(second.error == nil && second.canSave)
        try require(try NativeCoreEnvironment.values(dataDirectory: directory)["WOTEX_HOME_LIFX_INTERFACE"] == nil)
        try await render(NativeNetworkViewModel(), destination: CommandLine.arguments[2])
        for width in [599, 600, 839, 840] {
            let destination = String(CommandLine.arguments[2].dropLast(4)) + "-\(width).png"
            try await render(NativeNetworkViewModel(), destination: destination, width: CGFloat(width), height: 360)
        }
        print("native network explicit selection and conflict/churn guards passed")
    }
    @MainActor
    private static func finished(_ model: NativeNetworkViewModel) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
        while model.busy { try require(DispatchTime.now().uptimeNanoseconds < deadline); try await Task.sleep(for: .milliseconds(10)) }
    }
    @MainActor
    private static func render(_ model: NativeNetworkViewModel, destination: String, width: CGFloat = 880, height: CGFloat = 240) async throws {
        _ = NSApplication.shared
        let view = NSHostingView(rootView: NativeNetworkPanel(network: model, changesAllowed: true)
            .padding(24).frame(width: width, height: height, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .light))
        view.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.title = "Unselected network fixture"; window.contentView = view
        window.orderFront(nil); defer { window.close() }
        try await Task.sleep(for: .milliseconds(150))
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw NetworkPanelSmokeError.failed }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let bytes = bitmap.representation(using: .png, properties: [:]) else { throw NetworkPanelSmokeError.failed }
        try bytes.write(to: URL(fileURLWithPath: destination), options: .atomic)
    }
    private static func require(_ condition: Bool) throws { if !condition { throw NetworkPanelSmokeError.failed } }
}
