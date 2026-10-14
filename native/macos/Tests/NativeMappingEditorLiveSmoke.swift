import Foundation
import AppKit
import SwiftUI

private actor MappingGate {
    var calls = 0
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { calls += 1; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

@main
struct NativeMappingEditorLiveSmoke {
    private static func require(_ value: Bool, _ phase: String) throws {
        guard value else { FileHandle.standardError.write(Data("mapping editor fixture failed: \(phase)\n".utf8)); throw LocalHealthError.invalidResponse }
    }
    @MainActor static func main() async throws {
        guard CommandLine.arguments.count == 4, let line = readLine() else { exit(2) }
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
        let input = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("fields.json"))) as! [String: String]
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
            mappingLoader: { try await controller.loadMappingEditorContext() },
            mappingPreparer: { try await controller.prepareMappingDraftImport(context: $0, fields: $1) })
        model.entryMode = .manualDraft
        try require(model.mappingEntry == .editor && model.mappingContext == nil && !model.canPrepareManual && journal.entries.isEmpty, "initial")
        model.workAllowed = { false }; await model.loadMappingContext(); try require(model.mappingContext == nil, "shared load guard"); model.workAllowed = { true }
        await model.loadMappingContext()
        if mode == "context-refused" {
            try require(model.mappingContext == nil && model.error != nil && !model.canPrepareManual && journal.entries.isEmpty, "context refusal")
            print("refused"); return
        }
        guard let context = model.mappingContext else { try require(false, "context load"); exit(1) }
        try require(model.mappingFields.binding == nil && !model.canPrepareManual, "no inferred binding")
        let fields = NativeMappingDraftFields(id: input["id"]!, version: input["version"]!, binding: context.grammar.bindings[0],
            fingerprint: input["fingerprint"]!, channels: input["channels"]!, definitions: input["definitions"]!, requires: input["requires"]!, annotations: input["annotations"]!)
        model.mappingFields = fields
        try require(model.canPrepareManual && model.mappingValidationMessage == nil, "bounded fields")
        if mode == "normal" { try pureChecks(fields, grammar: context.grammar) }
        await model.prepareManual()
        if mode == "basis-refused" {
            try require(model.details.isEmpty && model.mappingContext == nil && model.ownedDraft == nil && journal.entries.isEmpty && model.error != nil, "basis fence")
            print("refused"); return
        }
        try require(!model.details.isEmpty && !model.canSubmit && journal.entries.isEmpty, "import prepare")
        if mode == "normal" {
            let prepared = try await controller.prepareMappingDraftImport(context: context, fields: fields)
            for phase in ["load", "prepare"] {
                for event in ["field", "binding", "entry", "session", "wake", "cancel"] {
                    let gate = MappingGate()
                    let delayed = NativeAuthoringViewModel(journal: journal, preparer: { _, _, _ in prepared }, sender: { _ in throw NativeAuthoringDeliveryError.outcomeUnknown },
                        draftPreparer: { _ in prepared }, draftSender: { _ in throw LocalHealthError.invalidProfileRequest }, assessmentPreparer: { _, _ in prepared },
                        mappingLoader: { if phase == "load" { await gate.wait() }; return context },
                        mappingPreparer: { _, _ in await gate.wait(); return prepared })
                    delayed.entryMode = .manualDraft; delayed.mappingFields = fields
                    if phase == "prepare" { await delayed.loadMappingContext() }
                    let pending = Task { if phase == "load" { await delayed.loadMappingContext() } else { await delayed.prepareManual() } }
                    for _ in 0..<200 { if await gate.calls == 1 { break }; try await Task.sleep(for: .milliseconds(5)) }
                    try require(delayed.busy && !delayed.canChangeSession, "busy")
                    await delayed.loadMappingContext(); await delayed.prepareManual(); try require(await gate.calls == 1, "one call")
                    switch event {
                    case "field": delayed.mappingFields.id = "urn:example:profile:edited"
                    case "binding": delayed.mappingFields.binding = nil
                    case "entry": delayed.mappingEntry = .file
                    case "session": delayed.invalidateSessionView()
                    case "wake": delayed.hostDidWake()
                    default: pending.cancel()
                    }
                    await gate.release(); await pending.value
                    try require(delayed.details.isEmpty && delayed.ownedDraft == nil && !delayed.canSubmit && !delayed.busy, "retired decision")
                    if phase == "load" || ["session", "wake", "cancel"].contains(event) { try require(delayed.mappingContext == nil, "retired context") }
                    try require(Array(delayed.mappingFields.channels.utf8) == Array(fields.channels.utf8), "preserved text")
                }
            }
            for width in [480, 600, 720, 980, 1320] { try await render(model, width: width, mode: "prepared") }
        }
        model.confirmed = true; await model.submit()
        if mode == "lost" {
            try require(model.ownedDraft == nil && model.receipt == nil && model.unconfirmed && !model.canPrepareManual && !journal.entries.isEmpty, "lost import")
            print("unconfirmed"); exit(3)
        }
        if mode == "cas-refused" {
            try require(model.ownedDraft == nil && model.receipt == nil && !model.unconfirmed && journal.entries.isEmpty && model.error != nil, "CAS refusal")
            print("refused"); return
        }
        guard let owned = model.ownedDraft else { try require(false, "owned import"); exit(1) }
        try require(owned.receipt.object?.kind == "draft" && journal.entries.isEmpty && !model.canSubmit, "matched handoff")
        await model.prepareManual(); try require(!model.details.isEmpty && !model.canSubmit, "separate assessment")
        model.confirmed = true; await model.submit()
        guard let candidate = model.receipt else { try require(false, "candidate receipt"); exit(1) }
        try require(candidate.kind == .candidate && candidate.disposition == (mode == "invalid" ? "invalid" : "compatible") && journal.entries.isEmpty, "producer result")
        let output: [String: Any] = ["import_operation": owned.receipt.operation, "import_revision": Int(owned.receipt.revision),
            "object_digest": owned.receipt.object!.digest, "first_revision": Int(owned.receipt.firstRevision!),
            "candidate_operation": candidate.operation, "candidate_revision": Int(candidate.revision), "disposition": candidate.disposition!]
        await model.loadMappingContext()
        try require(model.ownedDraft == nil && model.mappingContext != nil && Array(model.mappingFields.channels.utf8) == Array(fields.channels.utf8), "explicit reload retires handoff")
        print(String(decoding: try JSONSerialization.data(withJSONObject: output), as: UTF8.self))
    }
    private static func pureChecks(_ fields: NativeMappingDraftFields, grammar: HomeMappingGrammar) throws {
        let bytes = try fields.payload(grammar: grammar)
        try require(bytes.range(of: Data(fields.channels.utf8)) != nil && bytes.range(of: Data(fields.definitions.utf8)) != nil, "exact sections")
        var numeric = fields
        numeric.annotations = "{\"exact\":9007199254740993,\"decimal\":1.23000000000000000000001,\"text\":\"e\u{301}\"}"
        try require(try numeric.payload(grammar: grammar).range(of: Data(numeric.annotations.utf8)) != nil, "numeric/Unicode lexemes")
        var variants: [NativeMappingDraftFields] = []
        var changed = fields; changed.binding = HomeMappingBinding(id: fields.binding!.id, version: fields.binding!.version, sha: String(repeating: "0", count: 64)); variants.append(changed)
        changed = fields; changed.id = ""; variants.append(changed)
        changed = fields; changed.version = "01.0.0"; variants.append(changed)
        for text in ["", "{}", "[", "[{\"x\":1,\"x\":2}]", "[" + Array(repeating: "{}", count: 33).joined(separator: ",") + "]", String(repeating: " ", count: 262145), "[" + String(repeating: "[", count: 8) + "0" + String(repeating: "]", count: 8) + "]"] {
            changed = fields; changed.channels = text; variants.append(changed)
        }
        changed = fields; changed.annotations = "[]"; variants.append(changed)
        changed = fields; changed.annotations = "{\"x\":\"" + String(repeating: "x", count: 8193) + "\"}"; variants.append(changed)
        changed = fields; changed.channels = "[{\"x\":[" + Array(repeating: "0", count: 1025).joined(separator: ",") + "]}]"; variants.append(changed)
        changed = fields; changed.channels = "[" + Array(repeating: "[" + Array(repeating: "0", count: 200).joined(separator: ",") + "]", count: 32).joined(separator: ",") + "]"; variants.append(changed)
        for value in variants {
            var refused = false
            do { _ = try value.payload(grammar: grammar) } catch { refused = true }
            try require(refused, "invalid payload accepted")
        }
        try require(Mirror(reflecting: fields).children.isEmpty, "private reflection")
    }
    @MainActor private static func render(_ model: NativeAuthoringViewModel, width: Int, mode: String) async throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        let directory = URL(fileURLWithPath: "_build/native", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let content = ScrollView { NativeAuthoringPanel(authoring: model).padding(24) }.frame(width: CGFloat(width), height: 1100)
            .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .light)
        let view = NSHostingView(rootView: content); view.frame = NSRect(x: 0, y: 0, width: width, height: 1100)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; window.orderFront(nil); defer { window.close() }
        try await Task.sleep(for: .milliseconds(100)); view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
        try data.write(to: directory.appendingPathComponent("mapping-editor-\(mode)-\(width).png"))
    }
}
