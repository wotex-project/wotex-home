import Foundation
import AppKit
import SwiftUI

private actor DataPreparationGate {
    var calls = 0
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { calls += 1; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

@main
struct NativeAuthoringDataSelectionLiveSmoke {
    private static func require(_ value: Bool, _ phase: String, _ error: String? = nil) throws {
        guard value else {
            FileHandle.standardError.write(Data("data selection fixture failed at \(phase): \(error ?? "invalid state")\n".utf8))
            throw LocalHealthError.invalidResponse
        }
    }
    @MainActor static func main() async throws {
        guard CommandLine.arguments.count == 5, let line = readLine() else { exit(2) }
        let credential = try OperatorCredential.decode(line), socket = CommandLine.arguments[1]
        let root = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true), mode = CommandLine.arguments[3]
        if mode == "lookup" {
            let snapshot = try NativePendingStorage.load(directory: root)
            guard snapshot.document.entries.count == 1 else { exit(1) }
            let entry = snapshot.document.entries[0]
            guard case .resolved = try NativePendingRecoveryOperations.execute(entry, credential: credential, socketPath: socket, action: .lookup) else { exit(1) }
            let resolved = try NativePendingStorage.resolving(entry, directory: root, expected: snapshot)
            guard resolved.document.entries.isEmpty else { exit(1) }; print("resolved"); return
        }
        let metadata = root.appendingPathComponent("controller", isDirectory: true)
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let capture: @Sendable () throws -> LocalCredentialCapture = { LocalCredentialCapture(bytes: credential, nativeReference: nil) }
        let controller = NativeControllerSessionDriver(directory: metadata, local: NativeControllerLocalReadClient(capture: capture, socket: { socket }))
        controller.installLocalFence(); await controller.reload()
        let journal = NativePendingCoordinator(persistence: NativePendingPersistence(directory: root), capture: capture, socketPath: { socket })
        await journal.reload()
        let model = NativeAuthoringViewModel(journal: journal, preparer: { _, _, _ in throw LocalHealthError.invalidProfileRequest },
            sender: { try await controller.submitAuthoring($0, journal: journal) },
            draftPreparer: { try await controller.prepareManualDraftImport($0) },
            draftSender: { try await controller.submitManualDraftImport($0, journal: journal) },
            assessmentPreparer: { try await controller.prepareManualDraftAssessment($0, instruction: $1) },
            reviewPreparer: { try await controller.prepareAuthoringReview(candidateEpoch: $0, candidateOperation: $1, evidenceURL: $2) },
            dataPreparer: { try await controller.prepareAuthoringDataImport(kind: $0, url: $1) },
            selectedAssessmentPreparer: { try await controller.prepareManualDraftAssessment($0, instruction: $1, selectionURL: $2) })
        if mode == "data" || mode == "lost" || mode == "file-refused" {
            guard let kind = HomeAuthoringObjectKind(rawValue: CommandLine.arguments[4]) else { exit(2) }
            model.entryMode = .dataImport; model.dataKind = kind; model.dataURL = root.appendingPathComponent("payload.bin")
            model.workAllowed = { false }; try require(!model.canPrepareData, "work guard"); await model.prepareData()
            try require(model.details.isEmpty, "work guard I/O"); model.workAllowed = { true }
            await model.prepareData()
            if mode == "file-refused" {
                try require(model.error != nil && model.details.isEmpty && journal.entries.isEmpty, "private file refusal")
                print("refused"); return
            }
            try require(!model.details.isEmpty && !model.canSubmit && journal.entries.isEmpty, "data preparation", model.error)
            if kind == .source && mode == "data" {
                let prepared = try await controller.prepareAuthoringDataImport(kind: kind, url: model.dataURL!)
                for event in ["file", "kind", "entry", "session", "wake", "cancel"] {
                    let gate = DataPreparationGate()
                    let delayed = NativeAuthoringViewModel(journal: journal, preparer: { _, _, _ in prepared }, sender: { _ in throw NativeAuthoringDeliveryError.outcomeUnknown },
                        dataPreparer: { _, _ in await gate.wait(); return prepared })
                    delayed.entryMode = .dataImport; delayed.dataURL = model.dataURL
                    try require(await gate.calls == 0, "mount")
                    let task = Task { await delayed.prepareData() }
                    for _ in 0..<200 { if await gate.calls == 1 { break }; try await Task.sleep(for: .milliseconds(5)) }
                    try require(delayed.busy && !delayed.canChangeSession, "busy")
                    await delayed.prepareData(); try require(await gate.calls == 1, "single call")
                    switch event {
                    case "file": delayed.dataURL = root.appendingPathComponent("other.bin")
                    case "kind": delayed.dataKind = .fixture
                    case "entry": delayed.entryMode = .original
                    case "session": delayed.invalidateSessionView()
                    case "wake": delayed.hostDidWake()
                    default: task.cancel()
                    }
                    await gate.release(); await task.value
                    try require(delayed.details.isEmpty && delayed.receipt == nil && !delayed.canSubmit && !delayed.busy, "retired data")
                }
                for width in [480, 600, 720, 980, 1320] { try await render(model, width: width, mode: "prepared") }
            }
            model.confirmed = true; await model.submit()
            if mode == "lost" {
                try require(model.receipt == nil && model.importedHandleJSON == nil && !journal.entries.isEmpty && model.status.contains("unconfirmed"), "lost data")
                print("unconfirmed"); exit(3)
            }
            guard let receipt = model.receipt, let object = receipt.object, let first = receipt.firstRevision else { try require(false, "data submit", model.error); exit(1) }
            try require(journal.entries.isEmpty && model.importedHandleJSON != nil, "matched handle")
            if kind == .source { for width in [480, 600, 720, 980, 1320] { try await render(model, width: width, mode: "receipt") } }
            let result: [String: Any] = ["operation_id": receipt.operation, "revision": Int(receipt.revision),
                "object_digest": object.digest, "first_revision": Int(first), "kind": object.kind, "payload_sha256": object.payloadSHA, "payload_bytes": object.size]
            print(String(decoding: try JSONSerialization.data(withJSONObject: result), as: UTF8.self)); return
        }
        model.entryMode = .manualDraft; model.draftURL = root.appendingPathComponent("draft.json")
        await model.prepareManual(); try require(!model.details.isEmpty, "draft preparation", model.error)
        model.confirmed = true; await model.submit(); guard let owned = model.ownedDraft else { try require(false, "draft submit", model.error); exit(1) }
        if mode == "pipeline" {
            // Imports are explicit independent actions; their returned handles are selected only here by the fixture operator.
            var sourceHandles: [[String: Any]] = [], fixtureHandles: [[String: Any]] = [], envelopeHandle: [String: Any]?
            for (kind, name) in [(HomeAuthoringObjectKind.source, "source.bin"), (.fixture, "fixture-0.json"), (.fixture, "fixture-1.json"), (.envelope, "envelope.json")] {
                let prepared = try await controller.prepareAuthoringDataImport(kind: kind, url: root.appendingPathComponent(name))
                let receipt = try await controller.submitAuthoring(prepared, journal: journal)
                let handle: [String: Any] = ["object_digest": receipt.object!.digest, "first_revision": Int(receipt.firstRevision!)]
                if kind == .source { sourceHandles.append(handle) }
                if kind == .fixture { fixtureHandles.append(handle) }
                if kind == .envelope { envelopeHandle = handle }
            }
            fixtureHandles.sort { ($0["object_digest"] as! String) < ($1["object_digest"] as! String) }
            let selections: [String: Any] = ["source_refs": sourceHandles, "fixture_refs": fixtureHandles]
            try write(try JSONSerialization.data(withJSONObject: selections, options: [.sortedKeys]), to: root.appendingPathComponent("selections.json"))
            var content = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("review-content.json"))) as! [String: Any]
            content["envelope_ref"] = envelopeHandle!
            try write(try JSONSerialization.data(withJSONObject: content, options: [.sortedKeys]), to: root.appendingPathComponent("review-content.json"))
        }
        model.selectionURL = root.appendingPathComponent("selections.json")
        await model.prepareManual()
        if mode == "selection-refused" {
            try require(model.details.isEmpty && model.error != nil && model.ownedDraft?.receipt.operation == owned.receipt.operation && journal.entries.isEmpty, "selection refusal")
            print("refused"); return
        }
        try require(!model.details.isEmpty && !model.canSubmit && journal.entries.isEmpty, "selected assessment", model.error)
        if mode == "pipeline" {
            model.selectionURL = nil
            try require(model.ownedDraft?.receipt.operation == owned.receipt.operation && model.details.isEmpty, "selection edit retains draft")
            model.selectionURL = root.appendingPathComponent("selections.json"); await model.prepareManual()
            for width in [480, 600, 720, 980, 1320] { try await render(model, width: width, mode: "selected") }
        }
        model.confirmed = true; await model.submit()
        guard let candidate = model.receipt, candidate.kind == .candidate, candidate.disposition == "compatible" else { try require(false, "candidate submit", model.error); exit(1) }
        let candidateReport: [String: Any] = ["operation_id": candidate.operation, "revision": Int(candidate.revision), "input_sha256": candidate.inputSHA!]
        model.entryMode = .review; model.candidateEpochInput = String(candidate.epoch); model.candidateOperationInput = candidate.operation
        model.reviewURL = root.appendingPathComponent("review-content.json")
        await model.prepareReview(); try require(!model.details.isEmpty, "review preparation", model.error)
        model.confirmed = true; await model.submit()
        guard let review = model.receipt, review.kind == .review else { try require(false, "review submit", model.error); exit(1) }
        try require(review.sourceReview == "attributed" && review.proposalStatus == "complete" && journal.entries.isEmpty, "complete proposal")
        let result: [String: Any] = ["draft_operation": owned.receipt.operation, "candidate": candidateReport,
            "review_operation": review.operation, "review_revision": Int(review.revision)]
        print(String(decoding: try JSONSerialization.data(withJSONObject: result), as: UTF8.self))
    }
    private static func write(_ bytes: Data, to url: URL) throws {
        try bytes.write(to: url); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
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
        try data.write(to: directory.appendingPathComponent("authoring-data-\(mode)-\(width).png"))
    }
}
