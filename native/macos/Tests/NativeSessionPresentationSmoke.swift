import AppKit
import Foundation
import SwiftUI

private enum SessionSmokeError: Error { case failed }

@main
struct NativeSessionPresentationSmoke {
    @MainActor
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { throw SessionSmokeError.failed }
        let original = Data(repeating: 0x37, count: 32) // Inert, never an Authority credential.
        let replacement = Data(repeating: 0x38, count: 32)
        try OperatorCredential.selectNative(original)
        try check(OperatorCredential.nativeSessionSelected && OperatorCredential.load() == original)
        do { _ = try OperatorCredential.captureOriginal(); throw SessionSmokeError.failed }
        catch LocalHealthError.wrongPeer {}
        try check(try OperatorCredential.load() == original)
        do { try OperatorCredential.selectNative(Data(repeating: 0, count: 31)); throw SessionSmokeError.failed }
        catch LocalHealthError.invalidCredential {}
        try check(try OperatorCredential.load() == original)
        try OperatorCredential.selectNative(replacement)
        try check(try OperatorCredential.load() == replacement)
        OperatorCredential.endNativeSession()
        do { _ = try OperatorCredential.load(); throw SessionSmokeError.failed }
        catch LocalHealthError.noCredential {}
        do { _ = try OperatorCredential.captureOriginal(); throw SessionSmokeError.failed }
        catch LocalHealthError.noCredential {}
        do { _ = try OperatorCredential.recoverOriginalManual(verifier: "invalid"); throw SessionSmokeError.failed }
        catch LocalHealthError.invalidCredential {}
        try check(!OperatorCredential.nativeSessionSelected)
        OperatorCredential.selectManual() // No Keychain read: this changes only memory mode.
        try check(!OperatorCredential.nativeSessionSelected)
        try OperatorCredential.selectNative(original)
        let model = NativeSetupViewModel()
        // Actual unsigned self/default setup is unavailable; no fake successful
        // broker or Keychain backend is supplied to this model.
        model.role = .operator
        model.select()
        let deadline = DispatchTime.now().uptimeNanoseconds + 7_000_000_000
        while model.busy && DispatchTime.now().uptimeNanoseconds < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try check(!model.busy && model.error != nil && OperatorCredential.load() == original)
        model.endSession()
        do { _ = try OperatorCredential.load(); throw SessionSmokeError.failed }
        catch LocalHealthError.noCredential {}
        try check(model.session == "No credential selected" && model.scope == nil)
        try await render(model, destination: CommandLine.arguments[1])
        print("native session memory transitions and unsigned setup refusal passed")
    }

    @MainActor
    private static func render(_ model: NativeSetupViewModel, destination: String) async throws {
        _ = NSApplication.shared
        let content = NativeSetupPanel(setup: model, changesAllowed: true)
            .padding(24).frame(width: 880, height: 280, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .light)
        let view = NSHostingView(rootView: content)
        view.frame = NSRect(x: 0, y: 0, width: 880, height: 280)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.title = "Inert Home session fixture"; window.contentView = view
        window.orderFront(nil); defer { window.close() }
        try await Task.sleep(for: .milliseconds(150))
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw SessionSmokeError.failed }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let bytes = bitmap.representation(using: .png, properties: [:]) else { throw SessionSmokeError.failed }
        try bytes.write(to: URL(fileURLWithPath: destination), options: .atomic)
    }

    private static func check(_ value: Bool) throws { if !value { throw SessionSmokeError.failed } }
}
