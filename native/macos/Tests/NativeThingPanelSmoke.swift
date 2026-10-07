import AppKit
import Foundation
import SwiftUI

final class ThingFixtureState: @unchecked Sendable {
    private let lock = NSCondition()
    private var count = 0, waiting = false, released = false
    private var clock: UInt64 = 1_000_000_000
    func captured() { lock.lock(); count += 1; lock.unlock() }
    var captures: Int { lock.lock(); defer { lock.unlock() }; return count }
    func now() -> UInt64 { lock.lock(); defer { lock.unlock() }; return clock }
    func advance() { lock.lock(); clock += 5_001_000_000; lock.unlock() }
    func pause() { lock.lock(); waiting = true; while !released { lock.wait() }; lock.unlock() }
    var ready: Bool { lock.lock(); defer { lock.unlock() }; return waiting }
    func release() { lock.lock(); released = true; lock.broadcast(); lock.unlock() }
}
enum ThingPanelAssertion: Error { case failed(Int) }

@main
struct NativeThingPanelSmoke {
    @MainActor static func main() async {
        do { try await run(); print("{\"complete\":true}") }
        catch ThingPanelAssertion.failed(let line) { print("{\"complete\":false,\"line\":\(line)}") }
        catch { print("{\"complete\":false}") }
    }
    @MainActor private static func run() async throws {
        guard CommandLine.arguments.count == 4, let line = readLine(),
              let bytes = Data(base64Encoded: line.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "="), bytes.count == 32 else { throw ThingPanelAssertion.failed(#line) }
        let path = CommandLine.arguments[1], mode = CommandLine.arguments[2], state = ThingFixtureState()
        let client = NativeThingPanelClient(capture: { state.captured(); return LocalCredentialCapture(bytes: bytes, nativeReference: nil) },
            identity: { try LocalHealthClient.fetchControllerIdentity(socketPath: path, credential: $0) },
            inspect: { credential, target in
                let result = try NativeThingClient.fetch(socketPath: path, credential: credential, target: target)
                if ["draft-changed", "wake"].contains(mode) { state.pause() }
                return result
            }, refresh: { try NativeThingClient.refresh(socketPath: path, credential: $0, target: $1) })
        let model = NativeThingViewModel(client: client, monotonic: { state.now() })
        try require(state.captures == 0 && model.inspection == nil && !model.busy)
        model.targetIDInput = "light:fixture"
        model.changesAllowed = { false }
        await model.load(probe: true)
        try require(state.captures == 0 && model.inspection == nil)
        model.changesAllowed = { true }
        if ["draft-changed", "wake"].contains(mode) {
            let work = Task { await model.load() }
            for _ in 0..<600 {
                if state.ready { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            try require(state.ready && model.busy && !model.canChangeSession)
            if mode == "wake" { model.hostDidWake() } else { model.targetIDInput = "light:other" }
            state.release(); await work.value
            try require(model.inspection == nil && model.error != nil && !model.busy)
            return
        }
        await model.load(probe: mode.contains("probe"))
        if mode == "revoked" || mode == "owner-changed" {
            try require(model.inspection == nil && model.error != nil && !model.busy)
            return
        }
        if mode == "lost-probe" {
            try require(model.inspection == nil && model.error != nil && model.status.contains("unconfirmed"))
            await model.load()
        }
        try require(model.error == nil && !model.busy && model.canChangeSession)
        guard let view = model.inspection, let entry = view.capabilities.first else { throw ThingPanelAssertion.failed(#line) }
        try require(view.thingID == "light:fixture" && view.principal == "reader:thing-fixture" && view.capabilities.count == 1)
        let expected = mode == "missing" ? "missing" : mode == "stale" ? "stale" : mode == "synthetic" ? "synthetic" : "fresh"
        try require(entry.freshness == expected)
        if expected == "fresh" {
            try require(entry.currentValue == HomeObservedValue.boolean(true) && entry.report?.trust == "unauthenticated_local")
            state.advance()
            try require(model.elapsedMilliseconds == 5_001 && entry.displayedValue(elapsedMilliseconds: model.elapsedMilliseconds) == nil)
        } else { try require(entry.currentValue == nil) }
        if mode == "stale" || mode == "synthetic" {
            for width in [599, 600, 839, 840] { try await preview(model, width: width, path: CommandLine.arguments[3] + "/thing-\(mode)-\(width).png") }
        }
        model.hostDidWake()
        try require(model.inspection == nil)
    }
    private static func require(_ value: Bool, line: Int = #line) throws { guard value else { throw ThingPanelAssertion.failed(line) } }
    @MainActor private static func preview(_ model: NativeThingViewModel, width: Int, path: String) async throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        let content = ScrollView { NativeThingPanel(things: model).padding(24) }.frame(width: CGFloat(width), height: 720)
            .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .light)
        let view = NSHostingView(rootView: content); view.frame = NSRect(x: 0, y: 0, width: width, height: 720)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; window.orderFront(nil); defer { window.close() }
        try await Task.sleep(for: .milliseconds(200)); view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw ThingPanelAssertion.failed(#line) }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw ThingPanelAssertion.failed(#line) }
        try data.write(to: URL(fileURLWithPath: path))
    }
}
