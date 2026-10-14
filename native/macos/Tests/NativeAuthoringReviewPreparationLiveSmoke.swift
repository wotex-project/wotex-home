import Foundation
import AppKit
import SwiftUI

private actor ReviewPreparationGate {
    var calls = 0
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { calls += 1; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

@main
struct NativeAuthoringReviewPreparationLiveSmoke {
    @MainActor static func main() async throws {
        guard CommandLine.arguments.count == 5, let line = readLine() else { exit(2) }
        let credential = try OperatorCredential.decode(line), socket = CommandLine.arguments[1]
        let root = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true), mode = CommandLine.arguments[4]
        if mode == "lookup" {
            let snapshot = try NativePendingStorage.load(directory: root)
            guard snapshot.document.entries.count == 1 else { exit(1) }
            let entry = snapshot.document.entries[0]
            guard case .resolved = try NativePendingRecoveryOperations.execute(entry, credential: credential, socketPath: socket, action: .lookup) else { exit(1) }
            let resolved = try NativePendingStorage.resolving(entry, directory: root, expected: snapshot)
            guard resolved.document.entries.isEmpty else { exit(1) }
            print("resolved"); return
        }
        let candidate = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]))) as! [String: Any]
        let epoch = Int64(LocalHealthClient.profileInteger(candidate["authority_epoch"])!), operation = candidate["operation_id"] as! String
        let metadata = root.appendingPathComponent("controller", isDirectory: true)
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let capture: @Sendable () throws -> LocalCredentialCapture = { LocalCredentialCapture(bytes: credential, nativeReference: nil) }
        let controller = NativeControllerSessionDriver(directory: metadata, local: NativeControllerLocalReadClient(capture: capture, socket: { socket }))
        controller.installLocalFence(); await controller.reload()
        let journal = NativePendingCoordinator(persistence: NativePendingPersistence(directory: root), capture: capture, socketPath: { socket })
        await journal.reload()
        let model = NativeAuthoringViewModel(journal: journal, preparer: { _, _, _ in throw LocalHealthError.invalidProfileRequest },
            sender: { try await controller.submitAuthoring($0, journal: journal) },
            reviewPreparer: { try await controller.prepareAuthoringReview(candidateEpoch: $0, candidateOperation: $1, evidenceURL: $2) })
        model.entryMode = .review; model.candidateEpochInput = String(epoch); model.candidateOperationInput = operation
        model.reviewURL = root.appendingPathComponent("review-content.json")
        guard model.canPrepareReview, !model.canSubmit, journal.entries.isEmpty else { exit(1) }
        await model.prepareReview()
        if mode == "refused" {
            guard model.details.isEmpty, model.error != nil, journal.entries.isEmpty, !model.canSubmit else { exit(1) }
            print("refused"); return
        }
        guard !model.details.isEmpty, !model.canSubmit, journal.entries.isEmpty else {
            FileHandle.standardError.write(Data("review preparation failed: \(model.error ?? "invalid state")\n".utf8)); exit(1)
        }
        if mode != "lost" {
            let prepared = try await controller.prepareAuthoringReview(candidateEpoch: epoch, candidateOperation: operation, evidenceURL: root.appendingPathComponent("review-content.json"))
            for event in ["file", "epoch", "operation", "entry", "session", "wake", "cancel"] {
                let gate = ReviewPreparationGate()
                let delayed = NativeAuthoringViewModel(journal: journal, preparer: { _, _, _ in prepared }, sender: { _ in throw NativeAuthoringDeliveryError.outcomeUnknown },
                    reviewPreparer: { _, _, _ in await gate.wait(); return prepared })
                delayed.entryMode = .review; delayed.candidateEpochInput = String(epoch); delayed.candidateOperationInput = operation
                delayed.reviewURL = root.appendingPathComponent("review-content.json")
                guard await gate.calls == 0 else { exit(1) }
                let pending = Task { await delayed.prepareReview() }
                for _ in 0..<200 { if await gate.calls == 1 { break }; try await Task.sleep(for: .milliseconds(5)) }
                guard delayed.busy, !delayed.canChangeSession else { exit(1) }
                await delayed.prepareReview(); guard await gate.calls == 1 else { exit(1) }
                switch event {
                case "file": delayed.reviewURL = root.appendingPathComponent("other.json")
                case "epoch": delayed.candidateEpochInput = "2"
                case "operation": delayed.candidateOperationInput = "other:1"
                case "entry": delayed.entryMode = .original
                case "session": delayed.invalidateSessionView()
                case "wake": delayed.hostDidWake()
                default: pending.cancel()
                }
                await gate.release(); await pending.value
                guard delayed.details.isEmpty, !delayed.canSubmit, delayed.receipt == nil, !delayed.busy else { exit(1) }
            }
        }
        for width in [480, 600, 720, 980, 1320] { try await render(model, width: width, mode: mode) }
        model.confirmed = true; await model.submit()
        if mode == "lost" {
            guard model.receipt == nil, model.error != nil, !journal.entries.isEmpty, model.status.contains("unconfirmed") else { exit(1) }
            print("unconfirmed"); exit(3)
        }
        guard let receipt = model.receipt, receipt.kind == .review, journal.entries.isEmpty, model.error == nil else {
            FileHandle.standardError.write(Data("review submission failed: \(model.error ?? "invalid state")\n".utf8)); exit(1)
        }
        let result: [String: Any] = ["authority_epoch": receipt.epoch, "operation_id": receipt.operation, "revision": receipt.revision,
            "input_sha256": receipt.inputSHA!, "basis_sha256": receipt.basisSHA!, "result_sha256": receipt.resultSHA!,
            "source_review": receipt.sourceReview!, "home_consumption": receipt.consumption!, "fixture_status": receipt.fixtureStatus!, "proposal_status": receipt.proposalStatus!]
        print(String(decoding: try JSONSerialization.data(withJSONObject: result), as: UTF8.self))
    }
    @MainActor private static func render(_ model: NativeAuthoringViewModel, width: Int, mode: String) async throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        let directory = URL(fileURLWithPath: "_build/native", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let content = ScrollView { NativeAuthoringPanel(authoring: model).padding(24) }.frame(width: CGFloat(width), height: 920)
            .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .light)
        let view = NSHostingView(rootView: content); view.frame = NSRect(x: 0, y: 0, width: width, height: 920)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; window.orderFront(nil); defer { window.close() }
        try await Task.sleep(for: .milliseconds(100)); view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
        try data.write(to: directory.appendingPathComponent("authoring-review-\(mode)-\(width).png"))
    }
}
