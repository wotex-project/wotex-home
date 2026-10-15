import AppKit
import Foundation
import SwiftUI

private enum GuidedFailure: Error { case line(Int) }
private final class GuidedCaptures: @unchecked Sendable {
    private let lock = NSLock(); private var value = 0
    func record() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}
@main
struct NativeExternalProfileGuidedSmoke {
    @MainActor static func main() async {
        do {
            guard CommandLine.arguments.count == 4, let line = readLine(), let bytes = Data(base64Encoded: line), bytes.count == 32,
                  let body = readLine(), let request = try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any],
                  let action = NativeExternalGuidedAction(rawValue: request["method"] as! String), let fields = request["input"] as? [String: Any] else { throw GuidedFailure.line(#line) }
            let socket = CommandLine.arguments[1], root = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true), mode = CommandLine.arguments[3]
            let kind: HomeExternalProfileOriginalKind = action == .inspection ? .inspection : [.approve, .revokeTrust].contains(action) ? .trust : .target
            let original = try NativeExternalProfileOriginalWire.encode(fields, kind: kind), captures = GuidedCaptures()
            let metadata = root.appendingPathComponent("metadata"), pending = root.appendingPathComponent("pending")
            for path in [metadata, pending] where !FileManager.default.fileExists(atPath: path.path) {
                try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            }
            let capture: @Sendable () throws -> LocalCredentialCapture = { captures.record(); return LocalCredentialCapture(bytes: bytes, nativeReference: nil) }
            let controller = NativeControllerSessionDriver(directory: metadata, local: .init(capture: capture, socket: { socket }))
            controller.installLocalFence(); await controller.reload()
            let journal = NativePendingCoordinator(persistence: .init(directory: pending), capture: capture, socketPath: { socket })
            await journal.reload()
            let app = HomeApplicationModel(pending: journal, controller: controller), model = app.externalProfiles
            try check(model.entryMode == .guided && captures.count == 0 && !model.canPrepare)
            model.action = action
            model.newOperation(); try check(LocalHealthClient.profileID(model.decisionOperation) && captures.count == 0)
            model.decisionOperation = original.operation
            if action.needsObjects {
                let objects = (action == .inspection ? fields["inspection"] : fields["objects"]) as! [String: Any]
                let envelope = objects["envelope_ref"] as! [String: Any]
                model.envelopeDigest = envelope["object_digest"] as! String; model.envelopeFirstRevision = String((envelope["first_revision"] as! NSNumber).int64Value)
                model.profileFields = row(objects["profile"] as! [String: Any]); model.definitionFields = (objects["definitions"] as! [[String: Any]]).map(row)
            }
            if action.needsInspection {
                let reference = request["inspection_ref"] as! [String: Any]
                model.inspectionEpoch = String((reference["authority_epoch"] as! NSNumber).int64Value); model.inspectionOperation = reference["operation_id"] as! String
            }
            if action == .revokeTrust { model.artifactDigest = fields["artifact_digest"] as! String }
            if action == .select || action == .revokeTarget { model.targetID = fields["target_id"] as! String }
            if action == .select { model.sourceRef = fields["source_ref"] as! String }
            try check(captures.count == 0)
            let retainedEntries = journal.entries
            let operation = model.decisionOperation; model.decisionOperation = "bad/id"; await model.prepare()
            try check(captures.count == 0 && journal.entries == retainedEntries); model.decisionOperation = operation
            for invalid in ["0", "01", " 1", "1.0", "9223372036854775808"] {
                try check(NativeExternalGuidedObjectRow.positive(invalid) == nil)
                if action.needsInspection {
                    let epoch = model.inspectionEpoch; model.inspectionEpoch = invalid
                    await model.prepare(); try check(captures.count == 0 && !model.canPrepare && journal.entries == retainedEntries)
                    model.inspectionEpoch = epoch
                }
                if action.needsObjects {
                    let row = model.profileFields; model.profileFields.firstRevision = invalid
                    await model.prepare(); try check(captures.count == 0 && !model.canPrepare && journal.entries == retainedEntries)
                    model.profileFields = row
                }
            }
            if action == .select || action == .revokeTarget {
                let target = model.targetID; model.targetID = "bad/id"
                await model.prepare(); try check(captures.count == 0 && !model.canPrepare && journal.entries == retainedEntries)
                model.targetID = target
            }
            if action.needsObjects {
                let rows = model.definitionFields
                for _ in 0..<33 { model.addDefinition() }
                try check(model.definitionFields.count == 32 && captures.count == 0)
                model.removeDefinition(model.definitionFields[0].id)
                try check(model.definitionFields.count == 31 && captures.count == 0)
                model.definitionFields = rows
            }
            if mode == "paired" {
                let corpus = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "test/fixtures/controller_connections/native_associations_v1.json"))) as! [String: Any]
                let record = try NativeControllerPublicAssociation.decode(Data((((corpus["valid_records"] as! [[String: Any]])[0])["body"] as! String).utf8))
                let stored = try NativeControllerAssociationStorage.retaining(record, directory: metadata, expected: .empty)
                _ = try NativeControllerAssociationStorage.selecting(.remote(record.id), directory: metadata, expected: stored)
                await controller.reload()
                do { _ = try await controller.prepareExternalProfile(draft: model.guidedDraft()); throw GuidedFailure.line(#line) } catch NativeControllerDriverError.unavailable {}
                do { _ = try await controller.readExternalProfileSources(); throw GuidedFailure.line(#line) } catch NativeControllerDriverError.unavailable {}
                try check(captures.count == 0 && journal.entries.isEmpty); return
            }
            if mode == "recover" {
                guard let entry = journal.entries.first, journal.entries.count == 1, entry.input == .externalProfile(original) else { throw GuidedFailure.line(#line) }
                await journal.recover(entry, action: .lookup, custody: { _ in bytes }, execute: { entry, credential, path, action in
                    try NativePendingRecoveryOperations.execute(entry, credential: credential, socketPath: path, action: action)
                })
                try check(journal.entries.isEmpty && !journal.needsReload); return
            }
            if action == .select {
                model.sourceRef = ""; await model.refreshSources()
                try check(model.error == nil && model.sources?.sources.count == 1 && model.sourceRef.isEmpty)
                model.sourceRef = fields["source_ref"] as! String
            }
            let rendering = request["render"] as? Bool == true
            if rendering { try await render(model, state: "input") }
            if mode == "retire" || mode == "cancel" {
                let prepared = try await controller.prepareExternalProfile(draft: model.guidedDraft())
                let work = Task { @MainActor in try await controller.submitExternalProfile(prepared, journal: journal) }
                let monitor = Task { @MainActor in
                    try await wait(root.appendingPathComponent("held")); try check(app.busy && !app.canChangeSession)
                    if mode == "cancel" { work.cancel() } else { prepared.retire() }
                    try Data().write(to: root.appendingPathComponent("released"))
                }
                do { _ = try await work.value; throw GuidedFailure.line(#line) } catch LocalHealthError.sessionChanged {} catch is CancellationError {}
                try await monitor.value
                try check(journal.entries.count == 1 && journal.entries[0].input == .externalProfile(original))
                let before = captures.count
                do { _ = try await controller.submitExternalProfile(prepared, journal: journal); throw GuidedFailure.line(#line) } catch LocalHealthError.sessionChanged {}
                try check(captures.count == before); return
            }
            if mode == "delayed" {
                let work = Task { @MainActor in await model.prepare() }
                try await wait(root.appendingPathComponent("held")); try check(app.busy && !app.canChangeSession)
                model.decisionOperation = "changed:while-preparing"
                try Data().write(to: root.appendingPathComponent("released")); await work.value
                try check(model.details.isEmpty && !model.canSubmit && journal.entries.isEmpty); return
            }
            await model.prepare()
            if mode == "missing" || mode == "reader" || mode == "unavailable" {
                try check(model.error != nil && model.details.isEmpty && journal.entries.isEmpty)
                if rendering { try await render(model, state: mode == "missing" ? "missing" : "error") }; return
            }
            try check(model.error == nil && !model.details.isEmpty && !model.canSubmit && journal.entries.isEmpty)
            if rendering { try await render(model, state: "prepared") }
            model.confirmed = true; try check(model.canSubmit)
            if rendering { try await render(model, state: "confirmed") }
            if mode == "failed-publication" {
                let path = pending.appendingPathComponent("native-pending-v1.json")
                try Data("unsafe".utf8).write(to: path); try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path.path)
            }
            await model.submit()
            try check(!model.confirmed && model.details.isEmpty)
            if mode == "submit" {
                guard let receipt = model.receipt else { throw GuidedFailure.line(#line) }
                try NativeExternalProfileMutationClient.verify(receipt, original: original)
                try check(model.error == nil && journal.entries.isEmpty)
            } else if mode == "stale" || mode == "owner" { try check(model.error != nil && journal.entries.isEmpty) }
            else {
                try check(model.error != nil && journal.entries.count == 1 && journal.entries[0].input == .externalProfile(original))
                if mode == "failed-publication" || mode == "failed-resolution" { try check(journal.needsReload) }
            }
            if rendering { try await render(model, state: mode == "submit" ? "success" : "uncertain") }
        } catch { FileHandle.standardError.write(Data("guided external workflow failed: \(error)\n".utf8)); exit(1) }
    }
    private static func row(_ fields: [String: Any]) -> NativeExternalGuidedObjectRow {
        let ref = fields["reference"] as! [String: Any], handle = fields["object_ref"] as! [String: Any]
        var result = NativeExternalGuidedObjectRow(); result.uri = ref["id"] as! String; result.version = ref["version"] as! String
        result.referenceSHA = ref["sha256"] as! String; result.objectDigest = handle["object_digest"] as! String; result.firstRevision = String((handle["first_revision"] as! NSNumber).int64Value)
        return result
    }
    @MainActor private static func wait(_ path: URL) async throws {
        for _ in 0..<1500 { if FileManager.default.fileExists(atPath: path.path) { return }; try await Task.sleep(for: .milliseconds(5)) }
        throw GuidedFailure.line(#line)
    }
    private static func check(_ value: @autoclosure () throws -> Bool, line: Int = #line) throws { guard try value() else { throw GuidedFailure.line(line) } }
    @MainActor private static func render(_ model: NativeExternalProfileViewModel, state: String) async throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        for large in [false, true] { for width in [480, 599, 600, 839, 840, 1320] {
            let scale: CGFloat = large ? 1.4 : 1, logical = CGFloat(width) / scale
            let inner = NativeExternalProfilePanel(profiles: model).padding(16)
            let measured = NSHostingView(rootView: inner.frame(width: logical)); measured.frame = NSRect(x: 0, y: 0, width: logical, height: 1); measured.layoutSubtreeIfNeeded()
            let logicalHeight = max(400, measured.fittingSize.height), height = ceil(logicalHeight * scale)
            let content = inner.frame(width: logical, height: logicalHeight, alignment: .topLeading).scaleEffect(scale, anchor: .topLeading)
                .frame(width: CGFloat(width), height: height, alignment: .topLeading).background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .light)
            let view = NSHostingView(rootView: content); view.frame = NSRect(x: 0, y: 0, width: CGFloat(width), height: height)
            let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .aqua); window.contentView = view; window.orderFront(nil)
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(100)); view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw GuidedFailure.line(#line) }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else { throw GuidedFailure.line(#line) }
            let path = URL(fileURLWithPath: "_build/native/external-guided-\(model.action.rawValue)-\(state)-\(width)\(large ? "-large" : "").png")
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true); try data.write(to: path)
        } }
    }
}
