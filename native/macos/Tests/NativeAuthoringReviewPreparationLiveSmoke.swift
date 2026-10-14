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
        let editor = mode.hasPrefix("editor-"), outcome = mode.replacingOccurrences(of: "editor-", with: "")
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
        let editedPreparer: (@Sendable (Int64, String, NativeAuthoringReviewContent) async throws -> NativeAuthoringPreparedDecision)?
        if editor { editedPreparer = { try await controller.prepareAuthoringReview(candidateEpoch: $0, candidateOperation: $1, content: $2) } }
        else { editedPreparer = nil }
        let model = NativeAuthoringViewModel(journal: journal, preparer: { _, _, _ in throw LocalHealthError.invalidProfileRequest },
            sender: { try await controller.submitAuthoring($0, journal: journal) },
            reviewPreparer: { try await controller.prepareAuthoringReview(candidateEpoch: $0, candidateOperation: $1, evidenceURL: $2) },
            editedReviewPreparer: editedPreparer)
        model.entryMode = .review; model.candidateEpochInput = String(epoch); model.candidateOperationInput = operation
        model.reviewURL = root.appendingPathComponent("review-content.json")
        let content: [String: Any]
        if editor {
            content = try JSONSerialization.jsonObject(with: Data(contentsOf: model.reviewURL!)) as! [String: Any]
            try configureEditor(model, content: content); try pureEditorChecks(content)
            let noIO = root.appendingPathComponent("preflight", isDirectory: true)
            try FileManager.default.createDirectory(at: noIO, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let preflight = NativeControllerSessionDriver(directory: noIO, local: NativeControllerLocalReadClient(
                capture: { throw LocalHealthError.invalidCredential }, socket: { fatalError("invalid editor content reached socket") }))
            await preflight.reload()
            do {
                _ = try await preflight.prepareAuthoringReview(candidateEpoch: epoch, candidateOperation: operation,
                    content: NativeAuthoringReviewContent(mode: .source, evidence: [NativeAuthoringCitation(path: "/unknown", source: String(repeating: "0", count: 64), locator: "explicit")], unresolved: [], envelope: nil))
                exit(1)
            } catch LocalHealthError.invalidProfileRequest {}
        } else { content = [:] }
        guard model.canPrepareReview, !model.canSubmit, journal.entries.isEmpty else { exit(1) }
        await model.prepareReview()
        if outcome == "refused" {
            guard model.details.isEmpty, model.error != nil, journal.entries.isEmpty, !model.canSubmit else { exit(1) }
            print("refused"); return
        }
        guard !model.details.isEmpty, !model.canSubmit, journal.entries.isEmpty else {
            FileHandle.standardError.write(Data("review preparation failed: \(model.error ?? "invalid state")\n".utf8)); exit(1)
        }
        if !editor && outcome != "lost" && outcome != "submit-refused" {
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
        if editor && outcome != "lost" && outcome != "submit-refused" {
            let prepared = try await controller.prepareAuthoringReview(candidateEpoch: epoch, candidateOperation: operation, content: model.editedReviewContent())
            for event in ["path", "source", "locator", "unicode", "add", "remove", "unresolved", "unresolved-add", "unresolved-remove", "mode", "envelope", "content-entry", "session", "wake", "cancel"] {
                let gate = ReviewPreparationGate()
                let delayed = NativeAuthoringViewModel(journal: journal, preparer: { _, _, _ in prepared }, sender: { _ in throw NativeAuthoringDeliveryError.outcomeUnknown },
                    editedReviewPreparer: { _, _, _ in await gate.wait(); return prepared })
                delayed.entryMode = .review; delayed.candidateEpochInput = String(epoch); delayed.candidateOperationInput = operation
                try configureEditor(delayed, content: content)
                delayed.reviewUnresolved = [NativeReviewUnresolvedRow(path: "/profile/binding")]
                if event == "unicode" { delayed.reviewCitations[0].locator = "é" }
                let savedCount = delayed.reviewCitations.count
                guard await gate.calls == 0, delayed.canPrepareReview else { exit(1) }
                let pending = Task { await delayed.prepareReview() }
                for _ in 0..<200 { if await gate.calls == 1 { break }; try await Task.sleep(for: .milliseconds(5)) }
                guard delayed.busy, !delayed.canChangeSession else { exit(1) }
                await delayed.prepareReview(); delayed.addReviewCitation(); delayed.removeReviewCitation(delayed.reviewCitations[0].id)
                guard await gate.calls == 1, delayed.reviewCitations.count == savedCount else { exit(1) }
                switch event {
                case "path": delayed.reviewCitations[0].path = "/definitions/31/unit"
                case "source": delayed.reviewCitations[0].source = String(repeating: "0", count: 64)
                case "locator": delayed.reviewCitations[0].locator += " edited"
                case "unicode": delayed.reviewCitations[0].locator = "e\u{301}"
                case "add": delayed.reviewCitations.append(NativeReviewCitationRow())
                case "remove": delayed.reviewCitations.removeLast()
                case "unresolved": delayed.reviewUnresolved[0].path = "/definitions/31/unit"
                case "unresolved-add": delayed.reviewUnresolved.append(NativeReviewUnresolvedRow())
                case "unresolved-remove": delayed.reviewUnresolved.removeLast()
                case "mode": delayed.reviewMode = delayed.reviewMode == .source ? .complete : .source
                case "envelope": delayed.reviewEnvelopeDigest = String(repeating: "0", count: 64)
                case "content-entry": delayed.reviewEntry = .file
                case "session": delayed.invalidateSessionView()
                case "wake": delayed.hostDidWake()
                default: pending.cancel()
                }
                await gate.release(); await pending.value
                guard delayed.details.isEmpty, !delayed.canSubmit, delayed.receipt == nil, !delayed.busy else { exit(1) }
                if ["session", "wake", "cancel"].contains(event) { guard delayed.reviewCitations.count == savedCount else { exit(1) } }
            }
            model.reviewCitations.append(NativeReviewCitationRow()); guard !model.canPrepareReview, model.details.isEmpty else { exit(1) }
            model.removeReviewCitation(model.reviewCitations.last!.id); await model.prepareReview()
            guard !model.details.isEmpty, !model.canSubmit else { exit(1) }
        }
        for width in [480, 600, 720, 980, 1320] { try await render(model, width: width, mode: mode) }
        model.confirmed = true; await model.submit()
        if outcome == "submit-refused" {
            guard model.receipt == nil, model.error != nil, journal.entries.isEmpty, model.status.contains("refused"), !model.canSubmit else { exit(1) }
            print("refused"); return
        }
        if outcome == "lost" {
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
    @MainActor private static func configureEditor(_ model: NativeAuthoringViewModel, content: [String: Any]) throws {
        model.reviewEntry = .editor; model.reviewMode = NativeAuthoringReviewMode(rawValue: content["mode"] as! String)!
        model.reviewCitations = (content["evidence"] as! [[String: Any]]).reversed().map {
            NativeReviewCitationRow(path: $0["instance_path"] as! String, source: $0["source_ref"] as! String, locator: $0["locator"] as! String)
        }
        model.reviewUnresolved = (content["unresolved_paths"] as! [String]).reversed().map { NativeReviewUnresolvedRow(path: $0) }
        if let handle = content["envelope_ref"] as? [String: Any] {
            model.reviewEnvelopeDigest = handle["object_digest"] as! String; model.reviewEnvelopeRevision = String(LocalHealthClient.profileInteger(handle["first_revision"])!)
        }
    }
    private static func pureEditorChecks(_ fields: [String: Any]) throws {
        let records = fields["evidence"] as! [[String: Any]]
        let citations = records.reversed().map { NativeAuthoringCitation(path: $0["instance_path"] as! String, source: $0["source_ref"] as! String, locator: $0["locator"] as! String) }
        let sample = citations[0]
        let valid = NativeAuthoringReviewContent(mode: .source, evidence: citations, unresolved: ["/profile/channels/0/semantic", "/profile/binding"], envelope: nil)
        let canonical = try valid.checkedFields()
        guard (canonical["evidence"] as! [[String: String]]) == records as! [[String: String]], canonical["unresolved_paths"] as! [String] == ["/profile/binding", "/profile/channels/0/semantic"] else { exit(1) }
        var invalid = [
            NativeAuthoringReviewContent(mode: .source, evidence: [sample, sample], unresolved: [], envelope: nil),
            NativeAuthoringReviewContent(mode: .source, evidence: Array(repeating: sample, count: 257), unresolved: [], envelope: nil),
            NativeAuthoringReviewContent(mode: .source, evidence: [], unresolved: Array(repeating: "/profile/binding", count: 65), envelope: nil),
            NativeAuthoringReviewContent(mode: .source, evidence: [], unresolved: ["/profile/binding", "/profile/binding"], envelope: nil),
            NativeAuthoringReviewContent(mode: .complete, evidence: [], unresolved: [], envelope: nil),
            NativeAuthoringReviewContent(mode: .source, evidence: [], unresolved: [], envelope: NativeAuthoringObjectHandle(digest: sample.source, firstRevision: 1))
        ]
        for bad in ["", String(repeating: "x", count: 257), "line\n", "format\u{202E}"] {
            invalid.append(NativeAuthoringReviewContent(mode: .source, evidence: [NativeAuthoringCitation(path: sample.path, source: sample.source, locator: bad)], unresolved: [], envelope: nil))
        }
        for path in ["/profile/channels/32/semantic", "/profile/channels/00/semantic", "/unknown", String(repeating: "x", count: 513)] {
            invalid.append(NativeAuthoringReviewContent(mode: .source, evidence: [NativeAuthoringCitation(path: path, source: sample.source, locator: sample.locator)], unresolved: [], envelope: nil))
        }
        for handle in [NativeAuthoringObjectHandle(digest: sample.source, firstRevision: 0), NativeAuthoringObjectHandle(digest: "bad", firstRevision: 1)] {
            invalid.append(NativeAuthoringReviewContent(mode: .complete, evidence: [], unresolved: [], envelope: handle))
        }
        for content in invalid {
            do { _ = try content.checkedFields(); exit(1) } catch LocalHealthError.invalidProfileRequest {}
        }
        let composed = NativeAuthoringCitation(path: sample.path, source: sample.source, locator: "é")
        let decomposed = NativeAuthoringCitation(path: sample.path, source: sample.source, locator: "e\u{301}")
        let unicode = try NativeAuthoringReviewContent(mode: .source, evidence: [composed, decomposed], unresolved: [], envelope: nil).checkedFields()
        let locators = (unicode["evidence"] as! [[String: String]]).map { Array($0["locator"]!.utf8) }
        guard locators == [Array(decomposed.locator.utf8), Array(composed.locator.utf8)], !String(reflecting: valid).contains(sample.locator) else { exit(1) }
        let bounds = try NativeAuthoringReviewContent(mode: .source,
            evidence: (0..<256).reversed().map { NativeAuthoringCitation(path: sample.path, source: sample.source, locator: String(format: "%03d", $0) + String(repeating: "x", count: 253)) },
            unresolved: (0..<32).reversed().flatMap { ["/profile/channels/\($0)/selector", "/profile/channels/\($0)/semantic"] }, envelope: nil).checkedFields()
        guard (bounds["evidence"] as! [Any]).count == 256, (bounds["unresolved_paths"] as! [Any]).count == 64 else { exit(1) }
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
