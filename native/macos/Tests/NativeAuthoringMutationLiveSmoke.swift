import Foundation
import AppKit
import SwiftUI

@main
struct NativeAuthoringMutationLiveSmoke {
    @MainActor static func main() async throws {
        guard CommandLine.arguments.count == 5, let line = readLine() else { exit(2) }
        let credential = try OperatorCredential.decode(line), socket = CommandLine.arguments[1]
        let root = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true), mode = CommandLine.arguments[3]
        if mode == "manual-draft" || mode == "manual-draft-lost" || mode == "manual-draft-basis" {
            let metadata = root.appendingPathComponent("controller", isDirectory: true)
            try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let capture: @Sendable () throws -> LocalCredentialCapture = { LocalCredentialCapture(bytes: credential, nativeReference: nil) }
            let controller = NativeControllerSessionDriver(directory: metadata, local: NativeControllerLocalReadClient(capture: capture, socket: { socket }))
            controller.installLocalFence(); await controller.reload()
            let journal = NativePendingCoordinator(persistence: NativePendingPersistence(directory: root), capture: capture, socketPath: { socket })
            await journal.reload()
            let model = NativeAuthoringViewModel(journal: journal,
                preparer: { try await controller.prepareAuthoring(kind: $0, originalURL: $1, payloadURL: $2) },
                sender: { try await controller.submitAuthoring($0, journal: journal) },
                draftPreparer: { try await controller.prepareManualDraftImport($0) },
                draftSender: { try await controller.submitManualDraftImport($0, journal: journal) },
                assessmentPreparer: { try await controller.prepareManualDraftAssessment($0, instruction: $1) })
            model.entryMode = .manualDraft; model.draftURL = root.appendingPathComponent("draft.json")
            try manualRequire(model.canPrepareManual && model.ownedDraft == nil && journal.entries.isEmpty, "initial")
            await model.prepareManual()
            try manualRequire(!model.details.isEmpty && !model.canSubmit && journal.entries.isEmpty, "import preparation", model.error)
            model.confirmed = true; await model.submit()
            if mode == "manual-draft-basis" {
                try manualRequire(model.ownedDraft == nil && model.receipt == nil && !model.unconfirmed && journal.entries.isEmpty && model.error != nil, "changed reviewed basis", model.error)
                print("refused"); return
            }
            if mode == "manual-draft-lost" {
                try manualRequire(model.ownedDraft == nil && model.receipt == nil && model.unconfirmed && !model.canPrepareManual && !journal.entries.isEmpty, "lost import", model.error)
                print("unconfirmed"); exit(3)
            }
            guard let owned = model.ownedDraft, let object = owned.receipt.object, object.kind == "draft",
                  model.receipt?.kind == .import, journal.entries.isEmpty, !model.canSubmit, model.error == nil else {
                try manualRequire(false, "import submission", model.error); exit(1)
            }
            let importReceipt = owned.receipt
            for width in [480, 600, 720, 980, 1320] { try await renderManual(model, width: width, suffix: CommandLine.arguments[4]) }
            await model.prepareManual()
            try manualRequire(!model.details.isEmpty && !model.canSubmit && journal.entries.isEmpty, "assessment preparation", model.error)
            model.confirmed = true; await model.submit()
            guard let candidate = model.receipt, candidate.kind == .candidate, candidate.disposition == "compatible",
                  journal.entries.isEmpty, model.error == nil, !model.busy else {
                try manualRequire(false, "assessment submission", model.error); exit(1)
            }
            let report: [String: Any] = ["object_digest": object.digest, "first_revision": importReceipt.firstRevision!,
                "import_operation": importReceipt.operation, "import_revision": importReceipt.revision,
                "candidate_operation": candidate.operation, "candidate_revision": candidate.revision,
                "candidate_input_sha256": candidate.inputSHA!, "basis_sha256": candidate.basisSHA!]
            model.draftURL = nil; model.draftURL = root.appendingPathComponent("draft.json")
            await model.prepareManual(); model.confirmed = true; await model.submit()
            guard let repeated = model.ownedDraft else { try manualRequire(false, "reimport", model.error); exit(1) }
            try manualRequire(repeated.receipt.firstRevision == importReceipt.firstRevision && repeated.receipt.revision > importReceipt.revision, "historical first revision")
            await model.prepareManual(); model.confirmed = true; await model.submit()
            try manualRequire(model.receipt?.kind == .candidate && model.receipt?.disposition == "compatible" && journal.entries.isEmpty, "reassessment", model.error)
            var finalReport = report
            finalReport["repeat_import_revision"] = repeated.receipt.revision
            finalReport["repeat_candidate_revision"] = model.receipt!.revision
            print(String(decoding: try JSONSerialization.data(withJSONObject: finalReport), as: UTF8.self)); return
        }
        if mode == "panel-submit" || mode == "panel-refused" {
            guard let kind = HomeAuthoringOriginalKind(rawValue: CommandLine.arguments[4]) else { exit(2) }
            let metadata = root.appendingPathComponent("controller", isDirectory: true)
            try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let capture: @Sendable () throws -> LocalCredentialCapture = { LocalCredentialCapture(bytes: credential, nativeReference: nil) }
            let controller = NativeControllerSessionDriver(directory: metadata, local: NativeControllerLocalReadClient(capture: capture, socket: { socket }))
            controller.installLocalFence(); await controller.reload()
            let journal = NativePendingCoordinator(persistence: NativePendingPersistence(directory: root), capture: capture, socketPath: { socket })
            await journal.reload()
            let model = NativeAuthoringViewModel(journal: journal,
                preparer: { try await controller.prepareAuthoring(kind: $0, originalURL: $1, payloadURL: $2) },
                sender: { try await controller.submitAuthoring($0, journal: journal) })
            model.kind = kind; model.originalURL = root.appendingPathComponent("original.json")
            if kind == .import { model.payloadURL = root.appendingPathComponent("payload.bin") }
            guard model.canPrepare, journal.entries.isEmpty else { exit(1) }
            await model.prepare()
            guard !model.details.isEmpty, !model.canSubmit, journal.entries.isEmpty else {
                FileHandle.standardError.write(Data("native authoring preparation failed: \(model.error ?? "missing review")\n".utf8)); exit(1)
            }
            model.confirmed = true; guard model.canSubmit else { exit(1) }
            await model.submit()
            if mode == "panel-refused" {
                guard model.receipt == nil, model.error != nil, journal.entries.isEmpty, journal.canStart, model.status.contains("refused") else {
                    FileHandle.standardError.write(Data("native initial refusal retained: \(model.error ?? "missing error")\n".utf8)); exit(1)
                }
                print("refused"); return
            }
            if model.receipt != nil {
                guard journal.entries.isEmpty && model.error == nil else { exit(1) }; print("resolved"); return
            }
            guard !journal.entries.isEmpty, model.error != nil, !model.busy, model.status.contains("unconfirmed") else { exit(1) }
            print("unconfirmed"); exit(3)
        }
        var snapshot = try NativePendingStorage.load(directory: root)
        let entry: NativePendingEntry
        if mode == "submit" || mode == "capture" {
            guard snapshot.document.entries.isEmpty, let kind = HomeAuthoringOriginalKind(rawValue: CommandLine.arguments[4]) else { exit(2) }
            let original = try NativeAuthoringOriginalWire.nativeJSON(Data(contentsOf: root.appendingPathComponent("original.json")), kind: kind)
            let payload = kind == .import ? try Data(contentsOf: root.appendingPathComponent("payload.bin")) : nil
            let identity = try LocalHealthClient.fetchControllerIdentity(socketPath: socket, credential: credential)
            entry = NativePendingEntry(context: NativePendingContext(deployment: identity.deploymentID, owner: identity.ownerID,
                epoch: Int64(identity.authorityEpoch), principal: identity.principalID), custody: .manual(verifier: LocalHealthClient.profileSHA(credential)),
                input: .authoring(original, payload), phase: .pending)
            snapshot = try NativePendingStorage.retaining(entry, directory: root, expected: snapshot)
            if mode == "capture" { print("retained"); return }
        } else {
            guard snapshot.document.entries.count == 1 else { exit(2) }; entry = snapshot.document.entries[0]
        }
        do {
            let result = try NativePendingRecoveryOperations.execute(entry, credential: credential, socketPath: socket,
                action: mode == "lookup" ? .lookup : .retry)
            switch result {
            case .resolved:
                snapshot = try NativePendingStorage.resolving(entry, directory: root, expected: snapshot)
                guard snapshot.document.entries.isEmpty && snapshot.document.version == .v6 else { exit(1) }
                print("resolved")
            case .retained: print("retained")
            case .review: exit(1)
            }
        } catch NativeAuthoringDeliveryError.outcomeUnknown {
            guard try NativePendingStorage.load(directory: root) == snapshot else { exit(1) }; print("unconfirmed"); exit(3)
        }
    }
    private static func manualRequire(_ value: Bool, _ phase: String, _ error: String? = nil) throws {
        guard value else {
            FileHandle.standardError.write(Data("manual draft fixture failed at \(phase): \(error ?? "invalid state")\n".utf8))
            throw LocalHealthError.invalidResponse
        }
    }
    @MainActor private static func renderManual(_ model: NativeAuthoringViewModel, width: Int, suffix: String) async throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        let directory = URL(fileURLWithPath: "_build/native", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let content = ScrollView { NativeAuthoringPanel(authoring: model).padding(24) }.frame(width: CGFloat(width), height: 920)
            .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .light)
        let view = NSHostingView(rootView: content); view.frame = NSRect(x: 0, y: 0, width: width, height: 920)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; window.orderFront(nil); defer { window.close() }
        try await Task.sleep(for: .milliseconds(100)); view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw LocalHealthError.invalidResponse }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw LocalHealthError.invalidResponse }
        try data.write(to: directory.appendingPathComponent("manual-draft-owned-\(suffix)-\(width).png"))
    }
}
