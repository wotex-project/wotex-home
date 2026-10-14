import AppKit
import Darwin
import Foundation
import SwiftUI

private actor AuthoringPanelGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var calls = 0
    func wait() async { calls += 1; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
private enum AuthoringPanelAssertion: Error { case failed(Int) }

@main
struct NativeAuthoringPanelSmoke {
    @MainActor static func main() async throws {
        guard CommandLine.arguments.count == 3 else { exit(2) }
        let socket = CommandLine.arguments[1], root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("authoring-panel-" + UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let metadata = root.appendingPathComponent("metadata", isDirectory: true), pendingRoot = root.appendingPathComponent("pending", isDirectory: true)
        for folder in [metadata, pendingRoot] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        let capture: @Sendable () throws -> LocalCredentialCapture = { LocalCredentialCapture(bytes: Data(repeating: 7, count: 32), nativeReference: nil) }
        let controller = NativeControllerSessionDriver(directory: metadata, local: NativeControllerLocalReadClient(capture: capture, socket: { socket }))
        controller.installLocalFence(); await controller.reload()
        let originalURL = root.appendingPathComponent("original.json"), payloadURL = root.appendingPathComponent("payload.bin")
        let payload = Data("private-provider-canary".utf8), rawSHA = LocalHealthClient.profileSHA(Data("private-provider-canary".utf8))
        var frame = Data([87, 79, 72, 65, 1, 1, 0, 0, 0, UInt8(payload.count)])
        for n in stride(from: 0, to: 64, by: 2) {
            let start = rawSHA.index(rawSHA.startIndex, offsetBy: n), end = rawSHA.index(start, offsetBy: 2); frame.append(UInt8(rawSHA[start..<end], radix: 16)!)
        }
        frame.append(payload)
        let object: [String: Any] = ["kind": "source", "object_digest": LocalHealthClient.profileSHA(frame), "payload_sha256": rawSHA, "payload_bytes": payload.count]
        let original: [String: Any] = ["authority_epoch": 1, "operation_id": "import:panel", "expected_revision": 1, "object": object]
        try JSONSerialization.data(withJSONObject: original).write(to: originalURL); try payload.write(to: payloadURL)
        guard chmod(originalURL.path, 0o600) == 0, chmod(payloadURL.path, 0o600) == 0 else { exit(1) }
        if CommandLine.arguments[2] == "manual-panel" {
            let prepared = try await controller.prepareManualDraftImport(payloadURL)
            let journal = NativePendingCoordinator(persistence: NativePendingPersistence(directory: pendingRoot), capture: capture, socketPath: { socket })
            await journal.reload()
            let model = NativeAuthoringViewModel(journal: journal, preparer: { _, _, _ in prepared }, sender: { _ in throw NativeAuthoringDeliveryError.outcomeUnknown },
                draftPreparer: { _ in prepared }, draftSender: { _ in throw NativeAuthoringDeliveryError.outcomeUnknown },
                assessmentPreparer: { _, _ in prepared })
            model.entryMode = .manualDraft; try require(!model.canPrepareManual && !model.canPrepare)
            model.draftURL = payloadURL; await model.prepareManual()
            try require(!model.details.isEmpty && !model.canSubmit && !String(reflecting: model).contains("private-provider-canary"))
            for width in [480, 600, 720, 980, 1320] { try await render(model, width: width, path: "_build/native/manual-draft-prepared-\(width).png") }
            for event in ["file", "entry", "session", "wake", "cancel"] {
                let gate = AuthoringPanelGate()
                let delayed = NativeAuthoringViewModel(journal: journal, preparer: { _, _, _ in prepared }, sender: { _ in throw NativeAuthoringDeliveryError.outcomeUnknown },
                    draftPreparer: { _ in await gate.wait(); return prepared }, draftSender: { _ in throw NativeAuthoringDeliveryError.outcomeUnknown }, assessmentPreparer: { _, _ in prepared })
                delayed.entryMode = .manualDraft; delayed.draftURL = payloadURL
                try require(await gate.calls == 0)
                let pending = Task { await delayed.prepareManual() }
                for _ in 0..<200 { if await gate.calls == 1 { break }; try await Task.sleep(for: .milliseconds(5)) }
                try require(await gate.calls == 1 && delayed.busy && !delayed.canChangeSession)
                await delayed.prepareManual(); try require(await gate.calls == 1)
                switch event {
                case "file": delayed.draftURL = root.appendingPathComponent("other.json")
                case "entry": delayed.entryMode = .original
                case "session": delayed.invalidateSessionView()
                case "wake": delayed.hostDidWake()
                default: pending.cancel()
                }
                await gate.release(); await pending.value
                try require(delayed.details.isEmpty && !delayed.canSubmit && delayed.ownedDraft == nil && !delayed.busy)
            }
            model.confirmed = true; await model.submit()
            try require(model.ownedDraft == nil && model.unconfirmed && !model.canPrepareManual && model.error != nil && !model.busy)
            print("manual draft explicit preparation, delayed retirement, uncertainty and widths passed"); return
        }
        let prepared: NativeAuthoringPreparedDecision
        do {
            prepared = try await controller.prepareAuthoring(kind: .import, originalURL: originalURL, payloadURL: payloadURL)
            guard CommandLine.arguments[2] == "panel" else { throw AuthoringPanelAssertion.failed(#line) }
        } catch LocalHealthError.nativeGuardConflict where CommandLine.arguments[2].hasPrefix("invalid") { return }
        catch LocalHealthError.server("permission_denied") where CommandLine.arguments[2] == "refused" { return }
        let result = try NativeAuthoringReadClient.decodeOriginal(["api_version": 1, "outcome": "ok", "authoring_object_receipt": ["authority_epoch": 1, "operation_id": "import:panel", "revision": 2, "first_revision": 2, "object": object]], kind: .import, epoch: 1, operation: "import:panel")!
        let journal = NativePendingCoordinator(persistence: NativePendingPersistence(directory: pendingRoot), capture: capture, socketPath: { socket })
        await journal.reload()
        let model = NativeAuthoringViewModel(journal: journal, preparer: { _, _, _ in prepared }, sender: { _ in result })
        try require(!model.canPrepare && model.details.isEmpty && model.receipt == nil)
        model.originalURL = originalURL; model.payloadURL = payloadURL; await model.prepare()
        try require(!model.details.isEmpty && !model.canSubmit && !model.details.joined().contains("private-provider-canary"))
        model.confirmed = true; try require(model.canSubmit)
        for width in [480, 599, 600, 839, 840] { try await render(model, width: width, path: "_build/native/authoring-prepared-\(width).png") }
        await model.submit(); try require(model.receipt?.revision == 2 && model.error == nil && model.details.isEmpty)
        for event in ["kind", "original", "payload", "session", "wake"] {
            let gate = AuthoringPanelGate()
            let delayed = NativeAuthoringViewModel(journal: journal, preparer: { _, _, _ in await gate.wait(); return prepared }, sender: { _ in result })
            delayed.originalURL = originalURL; delayed.payloadURL = payloadURL
            try require(await gate.calls == 0)
            let work = Task { await delayed.prepare() }
            for _ in 0..<200 { if await gate.calls == 1 { break }; try await Task.sleep(for: .milliseconds(5)) }
            try require(await gate.calls == 1 && delayed.busy && !delayed.canChangeSession)
            await delayed.prepare(); try require(await gate.calls == 1)
            switch event {
            case "kind": delayed.kind = .review
            case "original": delayed.originalURL = root.appendingPathComponent("other.json")
            case "payload": delayed.payloadURL = root.appendingPathComponent("other.bin")
            case "session": delayed.invalidateSessionView()
            default: delayed.hostDidWake()
            }
            await gate.release(); await work.value
            try require(delayed.details.isEmpty && !delayed.canSubmit && delayed.receipt == nil && !delayed.busy)
        }
        let failed = NativeAuthoringViewModel(journal: journal, preparer: { _, _, _ in prepared }, sender: { _ in throw NativeAuthoringDeliveryError.outcomeUnknown })
        failed.originalURL = originalURL; failed.payloadURL = payloadURL; await failed.prepare(); failed.confirmed = true
        await failed.submit(); try require(failed.error != nil && failed.receipt == nil && !failed.busy)
        for width in [480, 840] { try await render(failed, width: width, path: "_build/native/authoring-error-\(width).png") }
        print("native authoring confirmation, delayed retirement, private review and mounted layout passed")
    }
    private static func require(_ value: Bool, line: Int = #line) throws { guard value else { throw AuthoringPanelAssertion.failed(line) } }
    @MainActor private static func render(_ model: NativeAuthoringViewModel, width: Int, path: String) async throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        let content = ScrollView { NativeAuthoringPanel(authoring: model).padding(24) }.frame(width: CGFloat(width), height: 920)
            .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .light)
        let view = NSHostingView(rootView: content); view.frame = NSRect(x: 0, y: 0, width: width, height: 920)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; window.orderFront(nil); defer { window.close() }
        try await Task.sleep(for: .milliseconds(100)); view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw AuthoringPanelAssertion.failed(#line) }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw AuthoringPanelAssertion.failed(#line) }
        try data.write(to: URL(fileURLWithPath: path))
    }
}
