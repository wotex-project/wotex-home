import AppKit
import Darwin
import Foundation
import SwiftUI

private enum ExternalPanelFailure: Error { case line(Int) }
private final class ExternalPanelCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func record() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

@main
struct NativeExternalProfilePanelLiveSmoke {
    @MainActor static func main() async {
        do {
            guard CommandLine.arguments.count == 4, let line = readLine(), let bytes = Data(base64Encoded: line), bytes.count == 32,
                  let body = readLine(), let request = try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any],
                  let kind = HomeExternalProfileOriginalKind(rawValue: request["kind"] as! String), let fields = request["input"] as? [String: Any] else { throw ExternalPanelFailure.line(#line) }
            let socket = CommandLine.arguments[1], root = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true), mode = CommandLine.arguments[3]
            let original = try NativeExternalProfileOriginalWire.encode(fields, kind: kind), calls = ExternalPanelCalls()
            let metadata = root.appendingPathComponent("metadata", isDirectory: true), pending = root.appendingPathComponent("pending", isDirectory: true)
            for path in [metadata, pending] where !FileManager.default.fileExists(atPath: path.path) {
                try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            }
            let capture: @Sendable () throws -> LocalCredentialCapture = { calls.record(); return .init(bytes: bytes, nativeReference: nil) }
            let controller = NativeControllerSessionDriver(directory: metadata, local: .init(capture: capture, socket: { socket }))
            controller.installLocalFence(); await controller.reload()
            let journal = NativePendingCoordinator(persistence: .init(directory: pending), capture: capture, socketPath: { socket })
            await journal.reload()
            let application = HomeApplicationModel(pending: journal, controller: controller)
            let model = application.externalProfiles
            model.entryMode = .file
            let file = root.appendingPathComponent("decision.json")
            try JSONSerialization.data(withJSONObject: fields).write(to: file); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            model.kind = kind; model.originalURL = file
            try check(calls.count == 0 && model.details.isEmpty && !model.canSubmit)
            model.operationInput = "valid:original"
            for invalid in ["", "0", "01", "-1", "1.0", "9223372036854775808"] {
                model.epochInput = invalid; try check(!model.canLookup)
            }
            model.epochInput = "1"; model.operationInput = String(repeating: "x", count: 129); try check(!model.canLookup)
            model.epochInput = ""; model.operationInput = ""; try check(calls.count == 0)
            if mode == "lost" && kind == .inspection { try await render(model, state: "idle"); try check(calls.count == 0) }
            // Additional checks may only narrow the installed selected guard,
            // including in original-purpose scope and nested calls.
            let checks = ExternalPanelCalls()
            do {
                try NativeLocalControllerRequestGuard.withAdditionalCheck({ checks.record() }) {
                    try NativeLocalControllerRequestGuard.withAdditionalCheck({ throw LocalHealthError.sessionChanged }) {
                        _ = try NativeLocalControllerRequestGuard.acquire()
                    }
                }
                throw ExternalPanelFailure.line(#line)
            } catch LocalHealthError.sessionChanged {}
            try check(checks.count == 1 && calls.count == 0)
            do {
                try NativeLocalControllerRequestGuard.withOriginal {
                    try NativeLocalControllerRequestGuard.withAdditionalCheck({ throw LocalHealthError.sessionChanged }) {
                        _ = try NativeLocalControllerRequestGuard.acquire()
                    }
                }
                throw ExternalPanelFailure.line(#line)
            } catch LocalHealthError.sessionChanged {}
            if mode == "reads" {
                await model.refresh(); try check(model.error == nil && model.catalogue != nil)
                model.epochInput = String(original.epoch); model.operationInput = original.operation
                await model.lookup()
                guard let receipt = model.receipt else { throw ExternalPanelFailure.line(#line) }
                try NativeExternalProfileMutationClient.verify(receipt, original: original)
                try check(model.error == nil && journal.entries.isEmpty && model.catalogue?.items.first?.state == "revoked")
                return
            }
            if mode == "paired-refusal" {
                let corpus = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "test/fixtures/controller_connections/native_associations_v1.json"))) as! [String: Any]
                let row = (corpus["valid_records"] as! [[String: Any]])[0]
                let record = try NativeControllerPublicAssociation.decode(Data((row["body"] as! String).utf8))
                let stored = try NativeControllerAssociationStorage.retaining(record, directory: metadata, expected: .empty)
                _ = try NativeControllerAssociationStorage.selecting(.remote(record.id), directory: metadata, expected: stored)
                await controller.reload()
                do { _ = try await controller.prepareExternalProfile(kind: kind, originalURL: root.appendingPathComponent("missing")); throw ExternalPanelFailure.line(#line) }
                catch NativeControllerDriverError.unavailable {}
                do { _ = try await controller.readExternalProfileCatalogue(); throw ExternalPanelFailure.line(#line) }
                catch NativeControllerDriverError.unavailable {}
                do { _ = try await controller.readExternalProfileOriginal(kind: kind, epoch: 1, operation: "test"); throw ExternalPanelFailure.line(#line) }
                catch NativeControllerDriverError.unavailable {}
                try check(calls.count == 0 && journal.entries.isEmpty); return
            }
            if mode == "retire-prepare" {
                let work = Task { @MainActor in await model.prepare() }
                var retired = false
                for _ in 0..<1500 {
                    if FileManager.default.fileExists(atPath: root.appendingPathComponent("retire").path) {
                        try check(application.busy && !application.canChangeSession)
                        model.invalidate(clearReads: true); retired = true
                        try Data().write(to: root.appendingPathComponent("retired")); break
                    }
                    try await Task.sleep(for: .milliseconds(5))
                }
                await work.value
                try check(retired && model.details.isEmpty && !model.confirmed && model.receipt == nil && journal.entries.isEmpty)
                return
            }
            if mode == "retire-status" || mode == "cancel-status" {
                let prepared = try await controller.prepareExternalProfile(kind: kind, originalURL: file)
                let submission = Task { @MainActor in try await controller.submitExternalProfile(prepared, journal: journal) }
                let monitor = Task { @MainActor in
                    for _ in 0..<1500 {
                        if FileManager.default.fileExists(atPath: root.appendingPathComponent("retire").path) {
                            try check(application.busy && !application.canChangeSession)
                            if mode == "cancel-status" { submission.cancel() } else { prepared.retire() }
                            try Data().write(to: root.appendingPathComponent("retired")); return
                        }
                        try await Task.sleep(for: .milliseconds(5))
                    }
                    throw ExternalPanelFailure.line(#line)
                }
                do { _ = try await submission.value; throw ExternalPanelFailure.line(#line) }
                catch LocalHealthError.sessionChanged {}
                catch is CancellationError {}
                try await monitor.value
                try check(journal.entries.count == 1 && journal.entries[0].input == .externalProfile(original))
                let before = calls.count
                do { _ = try await controller.submitExternalProfile(prepared, journal: journal); throw ExternalPanelFailure.line(#line) }
                catch LocalHealthError.sessionChanged {}
                try check(calls.count == before)
                return
            }
            if ["submit", "lost", "stage", "refused", "stale-review", "failed-publication", "failed-resolution"].contains(mode) {
                await model.prepare()
                if mode == "refused" {
                    try check(model.error != nil && model.details.isEmpty && journal.entries.isEmpty)
                    try await render(model, state: "error"); return
                }
                try check(model.error == nil && !model.details.isEmpty && !model.canSubmit && journal.entries.isEmpty && Mirror(reflecting: model).children.isEmpty)
                model.confirmed = true; try check(model.canSubmit)
                if kind == .trust && (mode == "stage" || mode == "lost") {
                    model.confirmed = false; try await render(model, state: "prepared")
                    model.confirmed = true; try await render(model, state: "confirmed")
                }
                if mode == "stage" {
                    let identity = try NativeExternalProfileClient.identity(socketPath: socket, credential: bytes)
                    _ = try await journal.begin(.externalProfile(original), authorityEpoch: Int(original.epoch), expectedController: identity)
                    return
                }
                if mode == "failed-publication" {
                    let path = pending.appendingPathComponent("native-pending-v1.json")
                    try Data("unsafe".utf8).write(to: path); try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path.path)
                }
                // Submission must use the reviewed immutable bytes rather than
                // rereading a file modified after preparation.
                try Data("changed after review".utf8).write(to: file)
                await model.submit()
                try check(!model.confirmed && model.details.isEmpty)
                if mode == "submit" { try check(model.error == nil && model.receipt != nil && journal.entries.isEmpty) }
                else if mode == "stale-review" { try check(model.error != nil && journal.entries.isEmpty) }
                else {
                    try check(model.error != nil && journal.entries.count == 1 && journal.entries[0].input == .externalProfile(original))
                    if mode == "failed-publication" || mode == "failed-resolution" { try check(journal.needsReload) }
                }
                if mode == "submit" || mode == "lost" { try await render(model, state: mode == "submit" ? "success" : "uncertain") }
            } else {
                guard let entry = journal.entries.first, journal.entries.count == 1, entry.input == .externalProfile(original) else { throw ExternalPanelFailure.line(#line) }
                let before = try NativePendingStorage.load(directory: pending)
                let action: NativePendingRecoveryAction = mode.hasPrefix("retry") ? .retry : mode == "ack-absent" ? .acknowledgeAbsent : .lookup
                await journal.recover(entry, action: action, custody: { _ in bytes }, execute: { entry, credential, path, action in
                    try NativePendingRecoveryOperations.execute(entry, credential: credential, socketPath: path, action: action)
                })
                if mode == "lookup-missing" || mode == "denied" || mode == "retry-lost" {
                    try check(try NativePendingStorage.load(directory: pending) == before && journal.entries == [entry])
                    try check(mode == "lookup-missing" ? journal.error == nil : journal.error != nil)
                } else { try check(journal.error == nil && journal.entries.isEmpty && journal.snapshot?.document.version == .v9) }
                if mode == "lookup-missing" {
                    model.epochInput = String(original.epoch); model.operationInput = original.operation
                    await model.lookup(); try check(model.error == nil && model.receipt == nil && model.status.contains("No matching"))
                    try await render(model, state: "missing")
                }
            }
            print("external selected panel workflow passed")
        } catch ExternalPanelFailure.line(let line) {
            FileHandle.standardError.write(Data("external selected panel assertion failed at line \(line)\n".utf8)); exit(1)
        } catch {
            FileHandle.standardError.write(Data("external selected panel workflow failed: \(type(of: error))\n".utf8)); exit(1)
        }
    }
    private static func check(_ value: @autoclosure () throws -> Bool, line: Int = #line) throws {
        guard try value() else { throw ExternalPanelFailure.line(line) }
    }
    @MainActor private static func render(_ model: NativeExternalProfileViewModel, state: String) async throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        for enlarged in [false, true] {
            for width in [480, 599, 600, 839, 840, 1320] {
                let scale: CGFloat = enlarged ? 1.4 : 1, logicalWidth = CGFloat(width) / scale
                let inner = NativeExternalProfilePanel(profiles: model).padding(16)
                let measured = NSHostingView(rootView: inner.frame(width: logicalWidth))
                measured.frame = NSRect(x: 0, y: 0, width: logicalWidth, height: 1); measured.layoutSubtreeIfNeeded()
                let logicalHeight = max(400, measured.fittingSize.height), height = ceil(logicalHeight * scale)
                let content = inner.frame(width: logicalWidth, height: logicalHeight, alignment: .topLeading)
                    .scaleEffect(scale, anchor: .topLeading)
                    .frame(width: CGFloat(width), height: height, alignment: .topLeading)
                    .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .light)
                let view = NSHostingView(rootView: content); view.frame = NSRect(x: 0, y: 0, width: CGFloat(width), height: height)
                let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .aqua); window.contentView = view; window.orderFront(nil)
                defer { window.close() }
                try await Task.sleep(for: .milliseconds(100)); view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw ExternalPanelFailure.line(#line) }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                guard let data = bitmap.representation(using: .png, properties: [:]) else { throw ExternalPanelFailure.line(#line) }
                let path = URL(fileURLWithPath: "_build/native/external-profile-\(state)-\(width)\(enlarged ? "-large" : "").png")
                try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: path)
            }
        }
    }
}
