import AppKit
import Foundation
import SwiftUI

private actor AuthoringReadGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var calls = 0
    func wait() async { calls += 1; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
private enum AuthoringReadAssertion: Error { case failed(Int) }

@main
struct NativeAuthoringReadPanelSmoke {
    @MainActor static func main() async {
        do { try await run(); print("native authoring delayed delivery, missing/error, metadata and mounted layout passed") }
        catch { FileHandle.standardError.write(Data("native authoring panel fixture failed: \(error)\n".utf8)); exit(1) }
    }
    @MainActor private static func run() async throws {
        guard CommandLine.arguments.count == 3,
              let vector = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as? [String: Any],
              let raw = vector["receipt"] as? [String: Any], let operation = raw["operation_id"] as? String,
              let receipt = try NativeAuthoringReadClient.decodeOriginal(["api_version": 1, "outcome": "ok", "authoring_review_receipt": raw], kind: .review, epoch: 1, operation: operation) else { throw AuthoringReadAssertion.failed(#line) }
        let model = NativeAuthoringReadViewModel(reader: { _ in .original(receipt) })
        try require(model.original == nil && !model.busy && !model.canReadOriginal)
        model.kind = .review; model.epochInput = "1"; model.operationInput = operation
        for bad in ["01", " 1", "+1", "0", "-1", "9223372036854775808"] { model.epochInput = bad; try require(!model.canReadOriginal) }
        model.epochInput = "1"; await model.readOriginal()
        try require(model.original?.resultSHA == receipt.resultSHA && model.error == nil && model.status.contains("Inert"))
        for event in ["kind", "epoch", "operation", "digest", "session", "wake"] {
            let gate = AuthoringReadGate()
            let pending = NativeAuthoringReadViewModel(reader: { _ in await gate.wait(); return .original(receipt) })
            pending.kind = .review; pending.epochInput = "1"; pending.operationInput = operation
            try require(await gate.calls == 0)
            let work = Task { await pending.readOriginal() }
            for _ in 0..<200 { if await gate.calls == 1 { break }; try await Task.sleep(for: .milliseconds(5)) }
            try require(await gate.calls == 1 && pending.busy && !pending.canChangeSession)
            await pending.readOriginal(); try require(await gate.calls == 1)
            switch event {
            case "kind": pending.kind = .import
            case "epoch": pending.epochInput = "2"
            case "operation": pending.operationInput = "other:1"
            case "digest": pending.digestInput = String(repeating: "a", count: 64)
            case "session": pending.invalidateSessionView()
            default: pending.hostDidWake()
            }
            await gate.release(); await work.value
            try require(pending.original == nil && pending.object == nil && !pending.busy && pending.error == nil)
        }
        let missing = NativeAuthoringReadViewModel(reader: { _ in .original(nil) })
        missing.epochInput = "1"; missing.operationInput = operation; await missing.readOriginal()
        try require(missing.original == nil && missing.error == nil && missing.status.contains("not found"))
        let failure = NativeAuthoringReadViewModel(reader: { _ in throw LocalHealthError.transport })
        failure.epochInput = "1"; failure.operationInput = operation; await failure.readOriginal()
        try require(failure.original == nil && failure.error != nil && !failure.busy)
        for width in [480, 599, 600, 839, 840] {
            try await render(model, width: width, path: CommandLine.arguments[2] + "/authoring-review-\(width).png")
        }
        let payload = Data(repeating: 255, count: 262_144)
        let rawSHA = LocalHealthClient.profileSHA(payload)
        var frame = Data([87, 79, 72, 65, 1, 1, 0, 4, 0, 0])
        for index in stride(from: 0, to: 64, by: 2) {
            let start = rawSHA.index(rawSHA.startIndex, offsetBy: index), end = rawSHA.index(start, offsetBy: 2)
            frame.append(UInt8(rawSHA[start..<end], radix: 16)!)
        }
        frame.append(payload)
        let digest = LocalHealthClient.profileSHA(frame)
        let objectResponse: [String: Any] = ["api_version": 1, "outcome": "ok", "authoring_object": ["first_revision": 3,
            "object": ["kind": "source", "object_digest": digest, "payload_sha256": rawSHA, "payload_bytes": payload.count],
            "payload_base64": payload.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")]]
        let object = try NativeAuthoringReadClient.decodeObject(objectResponse, digest: digest)
        let objectModel = NativeAuthoringReadViewModel(reader: { _ in .object(object) })
        objectModel.digestInput = digest; await objectModel.readObject()
        try require(objectModel.object?.size == 262_144 && objectModel.firstRevision == 3 && objectModel.original == nil)
        for width in [480, 599, 600, 839, 840] {
            try await render(objectModel, width: width, path: CommandLine.arguments[2] + "/authoring-object-\(width).png")
        }
        model.invalidateSessionView(); try require(model.original == nil)
    }
    private static func require(_ value: Bool, line: Int = #line) throws { guard value else { throw AuthoringReadAssertion.failed(line) } }
    @MainActor private static func render(_ model: NativeAuthoringReadViewModel, width: Int, path: String) async throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        let content = ScrollView { NativeAuthoringReadPanel(authoring: model).padding(24) }.frame(width: CGFloat(width), height: 920)
            .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .light)
        let view = NSHostingView(rootView: content); view.frame = NSRect(x: 0, y: 0, width: width, height: 920)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; window.orderFront(nil); defer { window.close() }
        try await Task.sleep(for: .milliseconds(100)); view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw AuthoringReadAssertion.failed(#line) }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw AuthoringReadAssertion.failed(#line) }
        try data.write(to: URL(fileURLWithPath: path))
    }
}
