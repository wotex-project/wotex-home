import AppKit
import Darwin
import Foundation
import SwiftUI

private enum GenerationFlowAssertion: Error { case failed(Int) }

private final class GenerationCaptureGate: @unchecked Sendable {
    private let lock = NSLock(), release = DispatchSemaphore(value: 0)
    private var started = false, enabled = false
    var didStart: Bool { lock.lock(); defer { lock.unlock() }; return started }
    func arm() { lock.lock(); started = false; enabled = true; lock.unlock() }
    func hold() throws {
        lock.lock()
        guard enabled else { lock.unlock(); return }
        enabled = false; started = true; lock.unlock()
        guard release.wait(timeout: .now() + 5) == .success else { throw GenerationFlowAssertion.failed(#line) }
    }
    func resume() { release.signal() }
}

@main
struct NativeGenerationFlowSmoke {
    @MainActor static func main() async {
        do { try await run() }
        catch GenerationFlowAssertion.failed(let line) { FileHandle.standardError.write(Data("generation flow failed at line \(line)\n".utf8)); exit(1) }
        catch LocalHealthError.server(let reason) where ["generation_deadline_expired", "resnapshot_required"].contains(reason) {
            FileHandle.standardError.write(Data("generation flow refused: \(reason)\n".utf8)); exit(1)
        }
        catch { FileHandle.standardError.write(Data("generation flow failed\n".utf8)); exit(1) }
    }
    @MainActor private static func run() async throws {
        guard CommandLine.arguments.count == 3, ["--flow", "--flow-start-only", "--flow-prepare-only", "--flow-restart"].contains(CommandLine.arguments[1]), let line = readLine(),
              let config = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let encoded = config["credential"] as? String, let credential = Data(base64Encoded: encoded),
              let path = config["journal"] as? String else { throw GenerationFlowAssertion.failed(#line) }
        let directory = URL(fileURLWithPath: path, isDirectory: true), socket = CommandLine.arguments[2]
        let metadata = directory.appendingPathComponent("selection", isDirectory: true)
        if CommandLine.arguments[1] != "--flow-restart" {
            try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        let capture: @Sendable () throws -> LocalCredentialCapture = { LocalCredentialCapture(bytes: credential, nativeReference: nil) }
        let controller = NativeControllerSessionDriver(directory: metadata, local: NativeControllerLocalReadClient(capture: capture, socket: { socket }))
        controller.installLocalFence(); await controller.reload()
        var journal = NativePendingCoordinator(persistence: NativePendingPersistence(directory: directory), capture: capture, socketPath: { socket })
        await journal.reload()
        let workspace = NativeGenerationWorkspaceCoordinator(directory: directory)
        try await workspace.reload()
        if CommandLine.arguments[1] == "--flow-restart" {
            try await restart(controller, journal, workspace, credential, socket, config["scenario"] as! String)
            return
        }
        let context = try await controller.loadGenerationContext()
        try require(context.options.policyCount == 1 && context.identity.revision == 9)
        let pairedFixture = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "test/fixtures/profiles/native-generation-workspace-v2.json"))) as! [String: Any]
        let pairedEntry = try (pairedFixture["cases"] as! [[String: Any]]).flatMap {
            try NativeGenerationWorkspaceDocument.decode(Data(($0["document"] as! String).utf8)).entries
        }.first { !$0.attempts.isEmpty && !$0.cancellationPending }!
        let localOnly = NativeControllerSessionDriver(directory: metadata, local: NativeControllerLocalReadClient(capture: {
            throw GenerationFlowAssertion.failed(#line)
        }, socket: { "/private/tmp/must-not-open-generation-local.sock" }))
        await localOnly.reload()
        try require(localOnly.localSelected && localOnly.error == nil && context.selection == localOnly.snapshot)
        let forbidden: [@MainActor () async throws -> Void] = [
            { _ = try await localOnly.readGeneration(pairedEntry) },
            { _ = try await localOnly.prepareGenerationAttempt(pairedEntry, feedbackConsent: true) },
            { _ = try await localOnly.cancelGeneration(pairedEntry, workspace: workspace, retry: true) },
            { try await localOnly.restoreGenerationPending(pairedEntry, workspace: workspace, journal: journal) },
            { _ = try await localOnly.prepareGeneratedDraftAssessment(pairedEntry, instruction: "No local capture") },
            { _ = try await localOnly.submitGeneration(NativeGenerationDecision(original: pairedEntry.preparation, context: context, previous: pairedEntry), workspace: workspace, journal: journal) },
        ]
        for action in forbidden {
            do { try await action(); throw GenerationFlowAssertion.failed(#line) }
            catch NativeControllerDriverError.unavailable {}
        }
        try require(workspace.entries.isEmpty && journal.entries.isEmpty)
        var fields = NativeGenerationDraftFields()
        fields.policySHA = context.policies[0]["policy_sha256"] as! String
        fields.passages = [0]; fields.examples = [0]; fields.instruction = "Draft only; retain exact explicit sources."
        fields.attempts = "3"; fields.attemptMS = "30000"; fields.totalMS = "90000"
        do { _ = try fields.original(context, operation: "generation:no-consent"); throw GenerationFlowAssertion.failed(#line) }
        catch LocalHealthError.invalidProfileRequest {}
        fields.remoteConsent = true
        try await unsignedSubmission(context: context, fields: fields, directory: directory, workspace: workspace, journal: journal)
        if CommandLine.arguments[1] != "--flow" {
            let decision = try await controller.prepareGeneration(context, fields: fields)
            do { _ = try await controller.submitGeneration(decision, workspace: workspace, journal: journal); throw GenerationFlowAssertion.failed(#line) }
            catch NativeGenerationDeliveryError.outcomeUnknown {}
            guard let root = workspace.entries.first else { throw GenerationFlowAssertion.failed(#line) }
            await recover(journal, root, .lookup, credential, socket)
            try require(journal.entries.isEmpty)
            if CommandLine.arguments[1] == "--flow-start-only" {
                let attempt = try await controller.prepareGenerationAttempt(root, feedbackConsent: false)
                do { _ = try await controller.submitGeneration(attempt, workspace: workspace, journal: journal); throw GenerationFlowAssertion.failed(#line) }
                catch NativeGenerationDeliveryError.outcomeUnknown {}
                guard let handed = workspace.entries.first else { throw GenerationFlowAssertion.failed(#line) }
                let running = try await controller.readGeneration(handed).1
                try require(running?.state == "running" && running?.result == nil && journal.entries.count == 1)
            }
            print("native generation workspace retained before Store restart"); return
        }
        let refusedDecision = try await controller.prepareGeneration(context, fields: fields)
        let pendingFile = directory.appendingPathComponent("native-pending-v1.json")
        let revisionRace = directory.appendingPathComponent("generation-revision-race")
        try Data("prepare".utf8).write(to: revisionRace)
        do { _ = try await controller.submitGeneration(refusedDecision, workspace: workspace, journal: journal); throw GenerationFlowAssertion.failed(#line) }
        catch LocalHealthError.server("resnapshot_required") {}
        guard let refusedRoot = workspace.entries.first else { throw GenerationFlowAssertion.failed(#line) }
        try require(refusedRoot.preparation == refusedDecision.original && journal.entries.count == 1)
        try await missingChecks(journal, credential, socket, directory)
        let refusedView = NativeGenerationViewModel(controller: controller, journal: journal, workspace: workspace)
        await refusedView.load()
        try require(refusedView.entry == refusedRoot)
        refusedView.archiveConfirmed = true; await refusedView.archive()
        try require(workspace.entries == [refusedRoot] && refusedView.error != nil)
        refusedView.archiveConfirmed = true; refusedView.archiveUncertaintyConfirmed = true; await refusedView.archive()
        try require(workspace.entries.isEmpty && journal.entries.isEmpty)
        let fresh = try await controller.loadGenerationContext()
        try require(fresh.identity.revision == 10)
        let rootDecision = try await controller.prepareGeneration(fresh, fields: fields)
        let preservedEmpty = try Data(contentsOf: pendingFile)
        try FileManager.default.removeItem(at: pendingFile)
        try FileManager.default.createSymbolicLink(at: pendingFile, withDestinationURL: directory.appendingPathComponent("absent"))
        do { _ = try await controller.submitGeneration(rootDecision, workspace: workspace, journal: journal); throw GenerationFlowAssertion.failed(#line) }
        catch NativePendingError.unavailable {}
        guard let root = workspace.entries.first else { throw GenerationFlowAssertion.failed(#line) }
        try require(journal.entries.count == 1 && root.preparation == rootDecision.original)
        try require(try await controller.readGeneration(root).0 == nil)
        try FileManager.default.removeItem(at: pendingFile)
        guard FileManager.default.createFile(atPath: pendingFile.path, contents: preservedEmpty, attributes: [.posixPermissions: 0o600]) else { throw GenerationFlowAssertion.failed(#line) }
        journal = NativePendingCoordinator(persistence: NativePendingPersistence(directory: directory), capture: capture, socketPath: { socket })
        await journal.reload()
        try require(journal.entries.isEmpty)
        try await controller.restoreGenerationPending(root, workspace: workspace, journal: journal)
        try require(try journal.entries[0].generationOperation() == rootDecision.original)
        try await missingChecks(journal, credential, socket, directory)
        try require(workspace.entries == [root])
        try await controller.restoreGenerationPending(root, workspace: workspace, journal: journal)
        await recover(journal, root, .retry, credential, socket)
        try require(journal.entries.count == 1)
        await recover(journal, root, .lookup, credential, socket)
        try require(journal.entries.isEmpty)
        let values = try await controller.readGeneration(root)
        try require(values.0?.state == "prepared")
        let attempt = try await controller.prepareGenerationAttempt(root, feedbackConsent: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: pendingFile.path)
        do { _ = try await controller.submitGeneration(attempt, workspace: workspace, journal: journal); throw GenerationFlowAssertion.failed(#line) }
        catch NativePendingError.unavailable {}
        guard let handed = workspace.entries.first else { throw GenerationFlowAssertion.failed(#line) }
        try require(try await controller.readGeneration(handed).1 == nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pendingFile.path)
        journal = NativePendingCoordinator(persistence: NativePendingPersistence(directory: directory), capture: capture, socketPath: { socket })
        await journal.reload()
        try await controller.restoreGenerationPending(handed, workspace: workspace, journal: journal)
        try require(try journal.entries[0].generationOperation() == attempt.original)
        try await missingChecks(journal, credential, socket, directory)
        try require(workspace.entries == [handed])
        try await controller.restoreGenerationPending(handed, workspace: workspace, journal: journal)
        await recover(journal, handed, .retry, credential, socket)
        try require(journal.entries.count == 1)
        let status = try await awaitResult(controller, handed)
        try require(status.result?.assessment?.disposition == "invalid")
        await recover(journal, handed, .acknowledgeAbsent, credential, socket)
        try require(journal.entries.isEmpty)
        do { _ = try await controller.prepareGenerationAttempt(handed, feedbackConsent: false); throw GenerationFlowAssertion.failed(#line) }
        catch LocalHealthError.invalidProfileRequest {}
        let repair = try await controller.prepareGenerationAttempt(handed, feedbackConsent: true)
        try require(repair.feedbackDraft == "{}" && repair.feedbackAssessment?.disposition == "invalid")
        let repaired = try await controller.submitGeneration(repair, workspace: workspace, journal: journal)
        let result = try await awaitResult(controller, repaired)
        try require(result.result?.disposition == "candidate" && result.result?.assessment?.disposition == "compatible")
        await recover(journal, repaired, .lookup, credential, socket)
        do { _ = try await controller.prepareGenerationAttempt(repaired, feedbackConsent: true); throw GenerationFlowAssertion.failed(#line) }
        catch LocalHealthError.invalidProfileRequest {}
        try require(workspace.entries == [repaired] && journal.entries.isEmpty)
        let manual = try await controller.prepareGeneratedDraftAssessment(repaired, instruction: "Assess under the current installed contract.")
        let candidate = try await controller.submitAuthoring(manual, journal: journal)
        try require(candidate.kind == .candidate && candidate.sourceReview == "not_assessed")
        let view = NativeGenerationViewModel(controller: controller, journal: journal, workspace: workspace)
        _ = NativeGenerationPanel(generation: view)
        try require(view.context == nil && view.decision == nil && view.fields.attempts.isEmpty && !view.fields.remoteConsent)
        view.fields.passages = [0]; view.fields.examples = [0]; view.fields.remoteConsent = true; view.confirmed = true
        view.fields.policySHA = "different-policy"
        try require(view.fields.passages.isEmpty && view.fields.examples.isEmpty && !view.fields.remoteConsent && !view.confirmed)
        await view.load()
        try require(view.entry?.preparation == root.preparation)
        for width in [480, 720, 1320] { try await render(view, width: width) }
        view.assessmentInstruction = "Private instruction"; view.confirmed = true
        view.invalidate(); try require(view.context == nil && view.entry == nil && !view.confirmed && view.assessmentInstruction.isEmpty)
        let gate = GenerationCaptureGate()
        let delayed = NativeControllerSessionDriver(directory: metadata, local: NativeControllerLocalReadClient(capture: {
            try gate.hold(); return try capture()
        }, socket: { socket }))
        delayed.installLocalFence(); await delayed.reload()
        let late = NativeGenerationViewModel(controller: delayed, journal: journal, workspace: workspace)
        gate.arm()
        let loading = Task { await late.load() }
        let until = ContinuousClock.now.advanced(by: .seconds(4))
        while !gate.didStart { try require(ContinuousClock.now < until); try await Task.sleep(for: .milliseconds(1)) }
        late.invalidate(); gate.resume(); await loading.value
        try require(late.context == nil && late.entry == nil && late.decision == nil && !late.confirmed)
        await late.load()
        try require(late.entry != nil)
        late.assessmentInstruction = "Original assessment instruction"; gate.arm()
        let assessing = Task { await late.prepareAssessment() }
        let assessmentUntil = ContinuousClock.now.advanced(by: .seconds(4))
        while !gate.didStart { try require(ContinuousClock.now < assessmentUntil); try await Task.sleep(for: .milliseconds(1)) }
        late.assessmentInstruction = "Changed instruction while the response is held"
        gate.resume(); await assessing.value
        try require(late.assessment == nil && !late.confirmed)
        do { _ = try await controller.cancelGeneration(repaired, workspace: workspace, retry: true); throw GenerationFlowAssertion.failed(#line) }
        catch NativeGenerationDeliveryError.outcomeUnknown {}
        guard let intent = workspace.entries.first else { throw GenerationFlowAssertion.failed(#line) }
        try require(intent.cancellationPending)
        do { _ = try await controller.prepareGenerationAttempt(intent, feedbackConsent: true); throw GenerationFlowAssertion.failed(#line) }
        catch NativeControllerDriverError.unavailable {}
        let cancelled = try await controller.cancelGeneration(intent, workspace: workspace, retry: false)
        try require(!cancelled.cancellationPending)
        try await workspace.archive(cancelled)
        try require(workspace.entries.isEmpty && journal.entries.isEmpty)
        let expirationContext = try await controller.loadGenerationContext()
        fields.attempts = "1"; fields.attemptMS = "1"; fields.totalMS = "1000"
        let expirationDecision = try await controller.prepareGeneration(expirationContext, fields: fields)
        let expired = try await controller.submitGeneration(expirationDecision, workspace: workspace, journal: journal)
        try await Task.sleep(for: .milliseconds(1100))
        try require(try await controller.readGeneration(expired).0?.state == "expired")
        let expirationView = NativeGenerationViewModel(controller: controller, journal: journal, workspace: workspace)
        await expirationView.load(); await expirationView.refresh()
        try require(expirationView.rootStatus?.state == "expired")
        await expirationView.prepareAttempt()
        try require(expirationView.entry == nil && expirationView.rootStatus == nil && expirationView.decision == nil && expirationView.error != nil && journal.entries.isEmpty && workspace.entries == [expired])
        await expirationView.load()
        expirationView.archiveConfirmed = true; await expirationView.archive()
        try require(workspace.entries.isEmpty && journal.entries.isEmpty)
        let revocationContext = try await controller.loadGenerationContext()
        fields.attemptMS = "30000"; fields.totalMS = "30000"
        let revokeDecision = try await controller.prepareGeneration(revocationContext, fields: fields)
        let revokeRoot = try await controller.submitGeneration(revokeDecision, workspace: workspace, journal: journal)
        let revocationView = NativeGenerationViewModel(controller: controller, journal: journal, workspace: workspace)
        await revocationView.load(); await revocationView.refresh()
        try require(revocationView.entry == revokeRoot && revocationView.rootStatus?.state == "prepared")
        revocationView.assessmentInstruction = "Private content that must retire"; revocationView.confirmed = true
        try Data("revoke".utf8).write(to: directory.appendingPathComponent("generation-revoke"))
        await revocationView.refresh()
        try require(revocationView.entry == nil && revocationView.context == nil && revocationView.rootStatus == nil && revocationView.attemptStatus == nil && revocationView.assessmentInstruction.isEmpty && !revocationView.confirmed && revocationView.error != nil)
        try require(workspace.entries == [revokeRoot] && journal.entries.isEmpty)
        print("native generation first decisions, publication, repair, manual assessment and cancellation passed")
    }
    @MainActor private static func unsignedSubmission(context: NativeGenerationContext, fields: NativeGenerationDraftFields,
        directory: URL, workspace: NativeGenerationWorkspaceCoordinator, journal: NativePendingCoordinator) async throws {
        let vectors = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "test/fixtures/controller_connections/native_associations_v1.json"))) as! [String: Any]
        let row = (vectors["valid_records"] as! [[String: Any]])[4]
        let association = try NativeControllerPublicAssociation.decode(Data((row["body"] as! String).utf8))
        let path = directory.appendingPathComponent("unsigned-generation", isDirectory: true)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let retained = try NativeControllerAssociationStorage.retaining(association, directory: path, expected: .empty)
        let selection = try NativeControllerAssociationStorage.selecting(.remote(association.id), directory: path, expected: retained)
        let controller = NativeControllerSessionDriver(certificateClock: { throw GenerationFlowAssertion.failed(#line) }, directory: path,
            local: NativeControllerLocalReadClient(capture: { throw GenerationFlowAssertion.failed(#line) }, socket: { "/missing-generation-local-socket" }))
        await controller.reload()
        let c = association.scope
        let identity = HomeControllerIdentity(deploymentID: c.deployment, ownerID: c.owner, authorityEpoch: Int(c.epoch),
            revision: Int(c.creationRevision), principalID: c.principal)
        let basis = NativePairedAuthoringBasis(association: association, scope: HomeControllerScope(identity: identity,
            permissions: association.access.permissions, targetIDs: association.access.targets))
        // Metadata is deliberately not a remote read or a successful signing fixture.
        let reviewed = NativeGenerationContext(paired: NativePairedGenerationContext(options: context.options, contract: context.contract,
            identity: identity, paired: basis), selection: selection, generation: context.generation, deadline: .now)
        try require(reviewed.capture == nil && Mirror(reflecting: reviewed).children.isEmpty)
        let original = try fields.original(reviewed, operation: "generation:unsigned-first-submission")
        let decision = NativeGenerationDecision(original: original, context: reviewed, previous: nil)
        let savedWorkspace = workspace.snapshot, savedPending = journal.snapshot
        do { _ = try await controller.submitGenerationDelivery(decision, workspace: workspace, journal: journal); throw GenerationFlowAssertion.failed(#line) }
        catch NativePairedSessionError.custody(.denied) {}
        try require(workspace.snapshot == savedWorkspace && journal.snapshot == savedPending && !controller.busy)
    }
    @MainActor private static func render(_ model: NativeGenerationViewModel, width: Int) async throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        let content = ScrollView { NativeGenerationPanel(generation: model).padding(24) }.frame(width: CGFloat(width), height: 920)
            .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .light)
        let view = NSHostingView(rootView: content); view.frame = NSRect(x: 0, y: 0, width: width, height: 920)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; window.orderFront(nil); defer { window.close() }
        try await Task.sleep(for: .milliseconds(100)); view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw GenerationFlowAssertion.failed(#line) }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw GenerationFlowAssertion.failed(#line) }
        let path = URL(fileURLWithPath: "_build/native/generation-workspace-\(width).png")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: path)
    }
    @MainActor private static func awaitResult(_ controller: NativeControllerSessionDriver, _ entry: NativeGenerationWorkspaceEntry) async throws -> HomeGenerationStatus {
        let until = ContinuousClock.now.advanced(by: .seconds(4))
        while true {
            let result = try await controller.readGeneration(entry).1
            if let result, result.result != nil { return result }
            try require(ContinuousClock.now < until); try await Task.sleep(for: .milliseconds(15))
        }
    }
    @MainActor private static func recover(_ journal: NativePendingCoordinator, _ entry: NativeGenerationWorkspaceEntry,
                                         _ action: NativePendingRecoveryAction, _ bytes: Data, _ socket: String) async {
        guard let pending = journal.entries.first else { return }
        await journal.recover(pending, action: action, custody: { _ in bytes }, execute: NativePendingRecoveryOperations.execute)
    }
    @MainActor private static func missingChecks(_ journal: NativePendingCoordinator, _ credential: Data, _ socket: String, _ directory: URL) async throws {
        guard let entry = journal.entries.first else { throw GenerationFlowAssertion.failed(#line) }
        let file = directory.appendingPathComponent("native-pending-v1.json"), beforeBytes = try Data(contentsOf: file)
        let before = try LocalHealthClient.fetchControllerIdentity(socketPath: socket, credential: credential)
        await journal.recover(entry, action: .lookup, custody: { _ in credential }, execute: NativePendingRecoveryOperations.execute)
        try require(journal.entries == [entry] && Data(contentsOf: file) == beforeBytes)
        await journal.recover(entry, action: .acknowledgeAbsent, custody: { _ in Data(repeating: 42, count: 32) }, execute: NativePendingRecoveryOperations.execute)
        try require(journal.entries == [entry] && journal.error != nil && Data(contentsOf: file) == beforeBytes)
        let wrongScope = NativePendingEntry(context: NativePendingContext(deployment: entry.context.deployment,
            owner: entry.context.owner == String(repeating: "f", count: 64) ? String(repeating: "e", count: 64) : String(repeating: "f", count: 64),
            epoch: entry.context.epoch, principal: entry.context.principal), custody: entry.custody, input: entry.input, phase: .pending)
        do { _ = try NativePendingRecoveryOperations.execute(wrongScope, credential: credential, socketPath: socket, action: .acknowledgeAbsent); throw GenerationFlowAssertion.failed(#line) }
        catch LocalHealthError.nativeGuardConflict {}
        let marker = directory.appendingPathComponent("generation-read-failure")
        for failure in ["read", "malformed"] {
            try Data(failure.utf8).write(to: marker)
            await journal.recover(entry, action: .acknowledgeAbsent, custody: { _ in credential }, execute: NativePendingRecoveryOperations.execute)
            try require(journal.entries == [entry] && journal.error != nil && Data(contentsOf: file) == beforeBytes)
            try FileManager.default.removeItem(at: marker)
        }
        await journal.recover(entry, action: .acknowledgeAbsent, custody: { _ in credential }, execute: { entry, bytes, socket, action in
            let result = try NativePendingRecoveryOperations.execute(entry, credential: bytes, socketPath: socket, action: action)
            let replacement = directory.appendingPathComponent("pending-inode-replacement")
            guard FileManager.default.createFile(atPath: replacement.path, contents: beforeBytes, attributes: [.posixPermissions: 0o600]),
                  rename(replacement.path, file.path) == 0 else { throw GenerationFlowAssertion.failed(#line) }
            return result
        })
        try require(journal.entries == [entry] && journal.needsReload && Data(contentsOf: file) == beforeBytes)
        await journal.reload()
        await journal.recover(entry, action: .acknowledgeAbsent, custody: { _ in credential }, execute: NativePendingRecoveryOperations.execute)
        let after = try LocalHealthClient.fetchControllerIdentity(socketPath: socket, credential: credential)
        try require(journal.entries.isEmpty && journal.status.contains("may arrive later") && !journal.needsReload && before.revision == after.revision)
        let empty = try NativePendingStorage.load(directory: directory)
        try require(empty.document.version == .v7 && empty.document.entries.isEmpty)
    }
    @MainActor private static func restart(_ controller: NativeControllerSessionDriver, _ journal: NativePendingCoordinator,
                                           _ workspace: NativeGenerationWorkspaceCoordinator, _ credential: Data, _ socket: String, _ scenario: String) async throws {
        guard let entry = workspace.entries.first else { throw GenerationFlowAssertion.failed(#line) }
        let beforeWorkspace = workspace.snapshot, beforePending = journal.snapshot
        let before = try LocalHealthClient.fetchControllerIdentity(socketPath: socket, credential: credential)
        let view = NativeGenerationViewModel(controller: controller, journal: journal, workspace: workspace)
        try require(view.entry == nil && view.decision == nil)
        await view.load(); await view.refresh()
        try require(view.entry == entry && view.rootStatus?.state == "retired")
        if scenario == "restart" {
            try require(entry.attempts.count == 1 && view.attemptStatus?.state == "unknown" && view.attemptStatus?.result == nil && journal.entries.count == 1)
            do { _ = try await controller.prepareGenerationAttempt(entry, feedbackConsent: true); throw GenerationFlowAssertion.failed(#line) }
            catch LocalHealthError.server("generation_unavailable") {}
            await recover(journal, entry, .acknowledgeAbsent, credential, socket)
            try require(journal.snapshot == beforePending && journal.entries.count == 1)
            await recover(journal, entry, .lookup, credential, socket)
            try require(journal.snapshot == beforePending && journal.entries.count == 1)
        } else {
            let configuration = try await controller.loadGenerationContext()
            try require(configuration.options.policyCount == 0 && entry.attempts.isEmpty && journal.entries.isEmpty)
            await view.prepareAttempt()
            try require(view.entry == nil && view.decision == nil && view.error != nil)
        }
        let after = try LocalHealthClient.fetchControllerIdentity(socketPath: socket, credential: credential)
        try require(before.revision == after.revision && workspace.snapshot == beforeWorkspace && journal.snapshot == beforePending)
        print("native generation retired root and unknown or withdrawn panel guards passed")
    }
    private static func require(_ value: Bool, line: Int = #line) throws { if !value { throw GenerationFlowAssertion.failed(line) } }
}
