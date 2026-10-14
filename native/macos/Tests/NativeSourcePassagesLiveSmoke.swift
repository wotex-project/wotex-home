import Foundation
import AppKit
import SwiftUI

private actor PassageGate {
    var calls = 0
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { calls += 1; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

private actor PassageSequence {
    var calls = 0
    func next(_ value: HomeSourcePassage) throws -> HomeAuthoringReadResult {
        calls += 1
        if calls == 1 { return .passages([value]) }
        if calls == 2 { return .passages(nil) }
        throw LocalHealthError.transport
    }
}

@main
struct NativeSourcePassagesLiveSmoke {
    private static func require(_ value: Bool, _ phase: String) throws {
        guard value else { FileHandle.standardError.write(Data("source passage fixture failed: \(phase)\n".utf8)); throw LocalHealthError.invalidResponse }
    }
    @MainActor static func main() async throws {
        guard CommandLine.arguments.count == 5, let line = readLine() else { exit(2) }
        let credential = try OperatorCredential.decode(line), socket = CommandLine.arguments[1]
        let root = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true), mode = CommandLine.arguments[3]
        let vectors = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[4]))) as! [String: Any]
        let records = vectors["expected"] as! [[String: Any]]
        let selectors = (vectors["selectors"] as! [[String: Any]]).map {
            HomeSourcePassageSelector(digest: $0["source_ref"] as! String, offset: LocalHealthClient.profileInteger($0["offset"])!, length: LocalHealthClient.profileInteger($0["length"])!)
        }
        let requested = (vectors["requested"] as? [[String: Any]])?.map {
            HomeSourcePassageSelector(digest: $0["source_ref"] as! String, offset: LocalHealthClient.profileInteger($0["offset"])!, length: LocalHealthClient.profileInteger($0["length"])!)
        } ?? selectors
        let envelope: [String: Any] = ["api_version": 1, "outcome": "ok", "authoring_passages": records]
        let decoded = try NativeAuthoringReadClient.decodePassages(envelope, selectors: selectors)!
        try require(decoded.map(\.text) == records.map { $0["text"] as! String }, "independent decode")
        for key in ["source_ref", "source_payload_sha256", "passage_sha256", "first_revision", "offset", "length", "text"] {
            var changed = records
            switch key {
            case "source_payload_sha256": changed[0][key] = String(repeating: "G", count: 64)
            case "first_revision": changed[0][key] = true
            case "offset": changed[0][key] = 0.0
            case "length": changed[0][key] = selectors[0].length + 1
            case "text": changed[0][key] = "\u{0}"
            default: changed[0][key] = String(repeating: "0", count: 64)
            }
            do { _ = try NativeAuthoringReadClient.decodePassages(["api_version": 1, "outcome": "ok", "authoring_passages": changed], selectors: selectors); try require(false, "changed " + key) }
            catch LocalHealthError.invalidResponse {}
        }
        for changed in [Array(records.reversed()), Array(records.dropFirst()), records + [records[0]], [records[0].merging(["extra": 1]) { _, value in value }] + Array(records.dropFirst())] {
            do { _ = try NativeAuthoringReadClient.decodePassages(["api_version": 1, "outcome": "ok", "authoring_passages": changed], selectors: selectors); try require(false, "record shape/order") }
            catch LocalHealthError.invalidResponse {}
        }
        for invalid in [[], [selectors[0], selectors[0]], Array(selectors.reversed()), [HomeSourcePassageSelector(digest: selectors[0].digest, offset: -1, length: 1)], [HomeSourcePassageSelector(digest: selectors[0].digest, offset: 0, length: 4097)], Array(repeating: selectors[0], count: 33)] {
            do { _ = try NativeAuthoringReadClient.fetchPassages(socketPath: root.appendingPathComponent("missing.sock").path, credential: Data(), selectors: invalid); try require(false, "invalid input") }
            catch LocalHealthError.invalidProfileRequest {}
        }
        let boundary = vectors["bounds"] as! [String: Any]
        let boundarySelectors = (boundary["selectors"] as! [[String: Any]]).map {
            HomeSourcePassageSelector(digest: $0["source_ref"] as! String, offset: LocalHealthClient.profileInteger($0["offset"])!, length: LocalHealthClient.profileInteger($0["length"])!)
        }
        let boundaryResponse: [String: Any] = ["api_version": 1, "outcome": "ok", "authoring_passages": boundary["expected"]!]
        let boundaryResult = try NativeAuthoringReadClient.decodePassages(boundaryResponse, selectors: boundarySelectors)!
        try require(boundaryResult.count == 32 && boundaryResult.reduce(0, { $0 + $1.text.utf8.count }) == 131072, "exact count/byte ceilings")
        let control = vectors["control"] as! [String: Any]
        let controlSelector = HomeSourcePassageSelector(digest: control["source_ref"] as! String, offset: 0, length: 8)
        do {
            _ = try NativeAuthoringReadClient.decodePassages(["api_version": 1, "outcome": "ok", "authoring_passages": [control]], selectors: [controlSelector])
            try require(false, "matched hash control refusal")
        } catch LocalHealthError.invalidResponse {}
        let notFound: [String: Any] = ["api_version": 1, "outcome": "not_found"]
        try require(try NativeAuthoringReadClient.decodePassages(notFound, selectors: selectors) == nil, "exact not found")
        do { _ = try NativeAuthoringReadClient.decodePassages(notFound.merging(["extra": 1]) { _, value in value }, selectors: selectors); try require(false, "not-found shape") }
        catch LocalHealthError.invalidResponse {}
        let metadata = root.appendingPathComponent("controller", isDirectory: true)
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let capture: @Sendable () throws -> LocalCredentialCapture = { LocalCredentialCapture(bytes: credential, nativeReference: nil) }
        let controller = NativeControllerSessionDriver(directory: metadata, local: NativeControllerLocalReadClient(capture: capture, socket: { socket }))
        controller.installLocalFence(); await controller.reload()
        if mode == "read" {
            guard case .passages(let values?) = try await controller.readAuthoring(.passages(selectors)) else { exit(1) }
            try require(values.map(\.text) == decoded.map(\.text) && values.map(\.passageSHA) == decoded.map(\.passageSHA), "actual ranges")
        }
        let model = NativeAuthoringReadViewModel(reader: { try await controller.readAuthoring($0) })
        model.sourceDigestInput = requested[0].digest; model.sourceOffsetInput = String(requested[0].offset); model.sourceLengthInput = String(requested[0].length)
        model.workAllowed = { false }; try require(!model.canReadPassage, "shared guard"); await model.readPassage()
        try require(model.passages.isEmpty, "guard no read"); model.workAllowed = { true }
        await model.readPassage()
        if mode == "refused" || mode == "not-found" {
            try require(model.passages.isEmpty && !model.busy && (mode == "not-found" ? model.error == nil : model.error != nil), "whole read refusal")
            print("refused"); return
        }
        try require(model.passages.count == 1 && model.passages[0].text == decoded[0].text && model.error == nil, "model read")
        try require(!String(reflecting: model).contains(decoded[0].text) && !String(reflecting: decoded[0]).contains(decoded[0].text), "text reflection")
        for event in ["digest", "offset", "length", "history", "session", "wake", "cancel"] {
            let gate = PassageGate(), result = HomeAuthoringReadResult.passages([decoded[0]])
            let delayed = NativeAuthoringReadViewModel(reader: { _ in await gate.wait(); return result })
            delayed.sourceDigestInput = selectors[0].digest; delayed.sourceOffsetInput = String(selectors[0].offset); delayed.sourceLengthInput = String(selectors[0].length)
            try require(await gate.calls == 0, "mount")
            let pending = Task { await delayed.readPassage() }
            for _ in 0..<200 { if await gate.calls == 1 { break }; try await Task.sleep(for: .milliseconds(5)) }
            try require(delayed.busy && !delayed.canChangeSession, "busy")
            await delayed.readPassage(); try require(await gate.calls == 1, "single read")
            switch event {
            case "digest": delayed.sourceDigestInput = String(repeating: "0", count: 64)
            case "offset": delayed.sourceOffsetInput = "2"
            case "length": delayed.sourceLengthInput = "1"
            case "history": delayed.operationInput = "other:1"
            case "session": delayed.invalidateSessionView()
            case "wake": delayed.hostDidWake()
            default: pending.cancel()
            }
            await gate.release(); await pending.value
            try require(delayed.passages.isEmpty && !delayed.busy, "retired text")
        }
        for width in [480, 600, 720, 980, 1320] { try await render(model, width: width, mode: root.lastPathComponent) }
        model.sourceOffsetInput = "00"; try require(!model.canReadPassage && model.passages.isEmpty, "canonical decimal")
        let sequence = PassageSequence()
        let missing = NativeAuthoringReadViewModel(reader: { _ in try await sequence.next(decoded[0]) })
        missing.sourceDigestInput = selectors[0].digest; missing.sourceOffsetInput = String(selectors[0].offset); missing.sourceLengthInput = String(selectors[0].length)
        await missing.readPassage(); try require(missing.passages.count == 1, "prior text")
        await missing.readPassage(); try require(missing.passages.isEmpty && missing.error == nil, "not found clears text")
        await missing.readPassage(); try require(missing.passages.isEmpty && missing.error != nil, "failure hides text")
        let associations = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("associations.json"))) as! [String: Any]
        let publicRows = associations["valid_records"] as! [[String: Any]]
        let association = try NativeControllerPublicAssociation.decode(Data((publicRows[4]["body"] as! String).utf8))
        let saved = try NativeControllerAssociationStorage.retaining(association, directory: metadata, expected: controller.snapshot!)
        _ = try NativeControllerAssociationStorage.selecting(.remote(association.id), directory: metadata, expected: saved)
        let paired = NativeControllerSessionDriver(directory: metadata, local: NativeControllerLocalReadClient(capture: { throw LocalHealthError.invalidCredential }, socket: { throwawaySocket() }))
        paired.installLocalFence(); await paired.reload()
        do { _ = try await paired.readAuthoring(.passages(selectors)); try require(false, "paired source refusal") }
        catch NativeControllerDriverError.unavailable {}
        print("verified")
    }
    private static func throwawaySocket() -> String { fatalError("paired source acquired local socket") }
    @MainActor private static func render(_ model: NativeAuthoringReadViewModel, width: Int, mode: String) async throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        let directory = URL(fileURLWithPath: "_build/native", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let content = ScrollView { NativeAuthoringReadPanel(authoring: model).padding(24) }.frame(width: CGFloat(width), height: 1100)
            .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .light)
        let view = NSHostingView(rootView: content); view.frame = NSRect(x: 0, y: 0, width: width, height: 1100)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; window.orderFront(nil); defer { window.close() }
        try await Task.sleep(for: .milliseconds(100)); view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
        try data.write(to: directory.appendingPathComponent("source-passages-\(mode)-\(width).png"))
    }
}
