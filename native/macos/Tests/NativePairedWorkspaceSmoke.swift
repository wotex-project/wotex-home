import Darwin
import Foundation

private enum WorkspaceSessionSmokeError: Error { case failed(Int) }
private final class WorkspaceClockProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
    func clock() throws -> NativeControllerCertificateClock {
        lock.lock(); count += 1; lock.unlock(); throw NativeControllerTLSError.tlsClockUncertain
    }
}

private final class HeldWorkspacePublication: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false, ended = false
    let release = DispatchSemaphore(value: 0)
    var opened: Bool { lock.lock(); defer { lock.unlock() }; return started }
    var finished: Bool { lock.lock(); defer { lock.unlock() }; return ended }
    func hold(_ operation: () throws -> NativeGenerationWorkspaceSnapshot) throws -> NativeGenerationWorkspaceSnapshot {
        lock.lock(); started = true; lock.unlock()
        defer { lock.lock(); ended = true; lock.unlock() }
        guard release.wait(timeout: .now() + 3) == .success else { throw WorkspaceSessionSmokeError.failed(#line) }
        return try operation()
    }
}

// Scripted public scope replies test transport guards only, never signing.
private final class WorkspaceScopeScript: NativeDomainTransport, @unchecked Sendable {
    let association: NativeControllerPublicAssociation
    private let lock = NSLock()
    private var scopes: [(Int, [String], [String])]
    private var domainCount = 0
    init(_ association: NativeControllerPublicAssociation, scopes: [(Int, [String], [String])]) { self.association = association; self.scopes = scopes }
    var calls: Int { lock.lock(); defer { lock.unlock() }; return domainCount }
    func request(body: Data, allowNotFound: Bool) throws -> Data {
        let request = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        if request["operation"] as? String == "controller_scope" {
            lock.lock()
            guard !scopes.isEmpty else { lock.unlock(); throw WorkspaceSessionSmokeError.failed(#line) }
            let next = scopes.removeFirst(); lock.unlock()
            let c = association.scope
            return try JSONSerialization.data(withJSONObject: ["api_version": 1, "outcome": "ok", "controller_scope": [
                "format": "wotex-home.controller-scope.v1", "deployment_id": c.deployment, "owner_id": c.owner,
                "authority_epoch": Int(c.epoch), "store_revision": next.0, "principal_id": c.principal,
                "permissions": next.1, "target_ids": next.2]])
        }
        lock.lock(); domainCount += 1; lock.unlock()
        return Data("{\"api_version\":1,\"outcome\":\"ok\"}".utf8)
    }
}

@main
struct NativePairedWorkspaceSmoke {
    static func main() async {
        do {
            guard CommandLine.arguments.count == 2 else { throw WorkspaceSessionSmokeError.failed(#line) }
            let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            try vectors(root)
            try await unsigned(root)
            print("paired workspace independent transitions, file witnesses and unsigned purpose refusal passed")
        } catch WorkspaceSessionSmokeError.failed(let line) {
            FileHandle.standardError.write(Data("paired workspace assertion failed at source line \(line)\n".utf8)); exit(1)
        } catch {
            FileHandle.standardError.write(Data("paired workspace fixture failed\n".utf8)); exit(1)
        }
    }
    private static func vectors(_ root: URL) throws {
        let corpus = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "test/fixtures/profiles/native-paired-workspace-transitions.json"))) as! [String: Any]
        let cases = corpus["cases"] as! [[String: Any]]
        try require(cases.count == 245)
        for (index, vector) in cases.enumerated() {
            let directory = root.appendingPathComponent("v-\(index)", isDirectory: true)
            try makeDirectory(directory)
            try write(directory.appendingPathComponent("native-generation-workspace-v1.json"), Data((vector["before"] as! String).utf8))
            try write(directory.appendingPathComponent("native-pending-v1.json"), Data((vector["pending_before"] as! String).utf8))
            let before = try NativeGenerationWorkspaceStorage.load(directory: directory)
            let pending = try NativePendingStorage.load(directory: directory)
            let entry = before.document.entries[vector["index"] as! Int]
            let action = vector["action"] as! String
            let after: NativeGenerationWorkspaceSnapshot
            if vector["permitted"] as! Bool == false {
                if action == "restore" { try refused { _ = try NativePairedWorkspaceCorrespondence.restoredOriginal(entry) } }
                else {
                    let identity = HomeControllerIdentity(deploymentID: entry.context.deployment, ownerID: entry.context.owner,
                        authorityEpoch: Int(entry.context.epoch), revision: 1, principalID: entry.context.principal)
                    try refused { try NativePairedWorkspaceCorrespondence.permitsArchive(entry,
                        read: NativePairedWorkspaceRead(root: nil, attempt: nil, identity: identity), acceptUncertainty: true) }
                }
                try NativeGenerationWorkspaceStorage.check(before, directory: directory)
                continue
            }
            switch action {
            case "retain":
                after = try NativeGenerationWorkspaceStorage.replacing(entry, with: entry, directory: directory, expected: before)
                try NativePairedWorkspaceCorrespondence.publication(entry, replacement: entry, before: before, after: after)
                try require(after == before)
            case "intent", "clear":
                let changed = try entry.cancellation(action == "intent")
                after = try NativeGenerationWorkspaceStorage.replacing(entry, with: changed, directory: directory, expected: before)
                try require(try NativePairedWorkspaceCorrespondence.intent(entry, value: action == "intent", before: before, after: after) == changed)
                if changed != entry { try refused { _ = try NativePairedWorkspaceCorrespondence.intent(entry, value: action == "intent", before: before, after: before) } }
            case "archive":
                after = try NativeGenerationWorkspaceStorage.removing(entry, directory: directory, expected: before)
                try NativePairedWorkspaceCorrespondence.publication(entry, replacement: nil, before: before, after: after)
                try refused { try NativePairedWorkspaceCorrespondence.publication(entry, replacement: nil, before: before, after: before) }
            case "restore":
                after = before
                let original = try NativePairedWorkspaceCorrespondence.restoredOriginal(entry)
                let next = try NativePendingStorage.retaining(original, directory: directory, expected: pending)
                try NativePairedCaptureCorrespondence.publication(of: original, before: pending, after: next)
                try require(try next.document.encoded() == Data((vector["pending_after"] as! String).utf8))
                try require(try LocalHealthClient.profileSHA(next.document.encoded()) == vector["pending_sha256"] as! String)
            default: throw WorkspaceSessionSmokeError.failed(#line)
            }
            try require(try after.document.encoded() == Data((vector["after"] as! String).utf8))
            try require(try LocalHealthClient.profileSHA(after.document.encoded()) == vector["after_sha256"] as! String)
            if after != before { try refused { try NativeGenerationWorkspaceStorage.check(before, directory: directory) } }
            try NativeGenerationWorkspaceStorage.check(after, directory: directory)
            // Replacing the same bytes still changes the inode witness.
            let replacement = directory.appendingPathComponent("same-content")
            try write(replacement, after.document.encoded())
            try require(rename(replacement.path, directory.appendingPathComponent("native-generation-workspace-v1.json").path) == 0)
            try refused { try NativeGenerationWorkspaceStorage.check(after, directory: directory) }
        }
    }
    private static func unsigned(_ root: URL) async throws {
        let records = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "test/fixtures/controller_connections/native_associations_v1.json"))) as! [String: Any]
        let body = (records["valid_records"] as! [[String: Any]])[0]["body"] as! String
        let original = try NativeControllerPublicAssociation.decode(Data(body.utf8))
        let access = NativeControllerAccess(permissions: ["profile:manage"], targets: [])
        let candidate = NativeControllerPublicAssociation(id: "", label: original.label, peer: original.peer, scope: original.scope,
            original: original.original, access: access, verifier: original.verifier)
        let association = NativeControllerPublicAssociation(id: try NativeControllerAssociationsWire.bindingID(candidate), label: original.label,
            peer: original.peer, scope: original.scope, original: original.original, access: access, verifier: original.verifier)
        let corpus = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "test/fixtures/profiles/native-generation-workspace-v2.json"))) as! [String: Any]
        let source = try (corpus["cases"] as! [[String: Any]]).map { try NativeGenerationWorkspaceDocument.decode(Data(($0["document"] as! String).utf8)) }
        let template = source.flatMap(\.entries).first { $0.context.epoch == 1 && !$0.attempts.isEmpty && !$0.cancellationPending }!
        let c = association.scope
        let entry = try NativeGenerationWorkspaceEntry(context: NativePendingContext(deployment: c.deployment, owner: c.owner, epoch: c.epoch, principal: c.principal),
            custody: .paired(from: association), basisSHA: template.basisSHA, preparation: template.preparation, attempts: template.attempts, cancellationPending: false).checked()
        let directory = root.appendingPathComponent("unsigned", isDirectory: true)
        try makeDirectory(directory)
        let workspace = try NativeGenerationWorkspaceStorage.retaining(entry, directory: directory, expected: .empty)
        let associations = try NativeControllerAssociationStorage.retaining(association, directory: directory, expected: .empty)
        for action in [NativePairedWorkspaceAction.status, .cancel, .restorePending, .assessDraft(operation: "manual:paired-generated", instruction: "Review the original draft."), .archive(acceptUncertainty: true)] {
            try require(try NativePairedWorkspaceCorrespondence.association(entry, action: action, workspace: workspace, pending: .empty, associations: associations) == association)
            let clock = WorkspaceClockProbe()
            do {
                _ = try await NativePairedControllerSession.generationWorkspace(entry, action: action, workspace: workspace,
                    pending: .empty, associations: associations, clock: clock.clock)
                throw WorkspaceSessionSmokeError.failed(#line)
            } catch NativePairedSessionError.custody(.denied) {}
            try require(clock.calls == 0)
        }
        try refused { _ = try NativePairedWorkspaceCorrespondence.association(entry, action: .status, workspace: .empty, pending: .empty, associations: associations) }
        try refused { _ = try NativePairedWorkspaceCorrespondence.association(entry, action: .status, workspace: workspace, pending: .empty, associations: .empty) }
        try refused { _ = try NativePairedGenerationWorkspaceOperations.read(entry, association: association, credential: Data(repeating: 8, count: 32)) }
        let badCustodies: [NativePendingCustody] = [
            .paired(association: String(repeating: "a", count: 64), controller: association.peer.controller, creationRevision: c.creationRevision, verifier: association.verifier),
            .paired(association: association.id, controller: String(repeating: "a", count: 64), creationRevision: c.creationRevision, verifier: association.verifier),
            .paired(association: association.id, controller: association.peer.controller, creationRevision: c.creationRevision, verifier: String(repeating: "a", count: 64)),
        ]
        for custody in badCustodies {
            let changed = NativeGenerationWorkspaceEntry(context: entry.context, custody: custody, basisSHA: entry.basisSHA,
                preparation: entry.preparation, attempts: entry.attempts, cancellationPending: false)
            try refused { _ = try NativePairedWorkspaceCorrespondence.association(changed, action: .status, workspace: workspace, pending: .empty, associations: associations) }
        }
        for action in [NativePairedWorkspaceAction.assessDraft(operation: "", instruction: ""), .assessDraft(operation: "manual:valid", instruction: "bad\u{0000}instruction"),
                       .assessDraft(operation: "manual:valid", instruction: String(repeating: "a", count: 4097))] {
            do { _ = try NativePairedWorkspaceCorrespondence.association(entry, action: action, workspace: workspace, pending: .empty, associations: associations); throw WorkspaceSessionSmokeError.failed(#line) }
            catch LocalHealthError.invalidProfileRequest {}
        }
        let pendingOriginal = try NativePairedWorkspaceCorrespondence.restoredOriginal(entry)
        let pending = try NativePendingStorage.retaining(pendingOriginal, directory: directory, expected: .empty)
        for action in [NativePairedWorkspaceAction.restorePending, .archive(acceptUncertainty: true)] {
            try refused { _ = try NativePairedWorkspaceCorrespondence.association(entry, action: action, workspace: workspace, pending: pending, associations: associations) }
        }
        try require(try NativePairedWorkspaceCorrespondence.association(entry, action: .status, workspace: workspace, pending: pending, associations: associations) == association)
        try NativePairedGenerationOriginalCorrespondence.check(pendingOriginal, workspace: workspace)
        let oldRoot = NativePendingEntry(context: entry.context, custody: entry.custody, input: .generation(entry.preparation), phase: .pending)
        try refused { try NativePairedGenerationOriginalCorrespondence.check(oldRoot, workspace: workspace) }
        var edited = try entry.attempts.last!.fields()
        edited["expected_revision"] = Int(entry.attempts.last!.expectedRevision) + 1
        let changedOriginal = try NativeGenerationOriginalWire.encode(edited, kind: .attempt)
        let substituted = NativePendingEntry(context: entry.context, custody: entry.custody, input: .generation(changedOriginal), phase: .pending)
        try refused { try NativePairedGenerationOriginalCorrespondence.check(substituted, workspace: workspace) }
        for action in [NativePendingRecoveryAction.lookup, .retry, .acknowledgeUnknown, .acknowledgeAbsent] {
            let clock = WorkspaceClockProbe()
            do {
                _ = try await NativePairedControllerSession.recovering(pendingOriginal, action: action, pending: pending,
                    associations: associations, workspace: action == .retry ? workspace : nil, clock: clock.clock)
                throw WorkspaceSessionSmokeError.failed(#line)
            } catch NativePairedSessionError.custody(.denied) {}
            try require(clock.calls == 0)
        }
        let noWorkspaceClock = WorkspaceClockProbe()
        do {
            _ = try await NativePairedControllerSession.recovering(pendingOriginal, action: .retry, pending: pending,
                associations: associations, clock: noWorkspaceClock.clock)
            throw WorkspaceSessionSmokeError.failed(#line)
        } catch NativePendingError.conflict {}
        try require(noWorkspaceClock.calls == 0)
        try refused { try NativePairedGenerationOriginalCorrespondence.check(pendingOriginal, workspace: .empty) }
        let intent = try entry.cancellation(true)
        let intended = try NativeGenerationWorkspaceStorage.replacing(entry, with: intent, directory: directory, expected: workspace)
        try refused { try NativePairedGenerationOriginalCorrespondence.check(pendingOriginal, workspace: intended) }
        let restoredWorkspace = try NativeGenerationWorkspaceStorage.replacing(intent, with: entry, directory: directory, expected: intended)
        try NativePairedGenerationOriginalCorrespondence.check(pendingOriginal, workspace: restoredWorkspace)
        let missing = NativePairedWorkspaceRead(root: nil, attempt: nil, identity: HomeControllerIdentity(deploymentID: c.deployment,
            ownerID: c.owner, authorityEpoch: Int(c.epoch), revision: 1, principalID: c.principal))
        try refused { try NativePairedWorkspaceCorrespondence.permitsArchive(entry, read: missing, acceptUncertainty: false) }
        try NativePairedWorkspaceCorrespondence.permitsArchive(entry, read: missing, acceptUncertainty: true)
        try NativeGenerationWorkspaceStorage.check(restoredWorkspace, directory: directory)
        try scopeGuards(entry, association: association)
        try await latePublication(entry, root: root)
    }
    private static func scopeGuards(_ entry: NativeGenerationWorkspaceEntry, association: NativeControllerPublicAssociation) throws {
        let pending = NativePendingEntry(context: entry.context, custody: entry.custody, input: .generation(entry.preparation), phase: .pending)
        let key = Data(repeating: 8, count: 32), permissions = ["profile:manage"]
        let body = try LocalHealthClient.requestBody(credential: key, operation: "health")
        let regressing = WorkspaceScopeScript(association, scopes: [(9, permissions, []), (10, permissions, []), (10, permissions, []), (9, permissions, [])])
        let guarded = try NativePairedProfileTransport.guarding(regressing, association: association, credential: key, entry: pending)
        _ = try guarded.request(body: body, allowNotFound: false)
        do { _ = try guarded.request(body: body, allowNotFound: false); throw WorkspaceSessionSmokeError.failed(#line) }
        catch NativePairedSessionError.scopeConflict {}
        try require(regressing.calls == 1)
        let shared = NativePairedScopeRevision(initial: 9)
        try NativePairedProfileTransport.$revisions.withValue(shared) {
            let first = WorkspaceScopeScript(association, scopes: [(9, permissions, []), (10, permissions, []), (10, permissions, [])])
            let owner = try NativePairedProfileTransport.guarding(first, association: association, credential: key, entry: pending)
            _ = try owner.request(body: body, allowNotFound: false)
            let second = WorkspaceScopeScript(association, scopes: [(9, permissions, [])])
            do { _ = try NativePairedProfileTransport.guarding(second, association: association, credential: key, entry: pending); throw WorkspaceSessionSmokeError.failed(#line) }
            catch NativePairedSessionError.scopeConflict {}
            try require(second.calls == 0)
        }
        for changed in [(10, ["read"], [String]()), (10, permissions, ["light:fixture"])] {
            let script = WorkspaceScopeScript(association, scopes: [(9, permissions, []), changed])
            let owner = try NativePairedProfileTransport.guarding(script, association: association, credential: key, entry: pending)
            do { _ = try owner.request(body: body, allowNotFound: false); throw WorkspaceSessionSmokeError.failed(#line) }
            catch NativePairedSessionError.scopeConflict {}
            try require(script.calls == 0)
        }
    }

    private static func latePublication(_ entry: NativeGenerationWorkspaceEntry, root: URL) async throws {
        let directory = root.appendingPathComponent("late-publication", isDirectory: true)
        try makeDirectory(directory)
        let before = try NativeGenerationWorkspaceStorage.retaining(entry, directory: directory, expected: .empty)
        let changed = try entry.cancellation(true), held = HeldWorkspacePublication()
        let task = Task {
            try await NativePendingPublicationOwner.performValue(until: .now.advanced(by: .milliseconds(150))) {
                try held.hold { try NativeGenerationWorkspaceStorage.replacing(entry, with: changed, directory: directory, expected: before) }
            }
        }
        for _ in 0..<100 where !held.opened { try await Task.sleep(for: .milliseconds(5)) }
        try require(held.opened)
        do { _ = try await task.value; throw WorkspaceSessionSmokeError.failed(#line) }
        catch NativePendingError.outcomeUnknown {}
        held.release.signal()
        for _ in 0..<100 where !held.finished { try await Task.sleep(for: .milliseconds(5)) }
        try require(held.finished)
        let after = try NativeGenerationWorkspaceStorage.load(directory: directory)
        try require(after.document.entries == [changed])
        try refused { try NativeGenerationWorkspaceStorage.check(before, directory: directory) }
    }
    private static func makeDirectory(_ url: URL) throws { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false); try require(chmod(url.path, 0o700) == 0) }
    private static func write(_ url: URL, _ bytes: Data) throws { try bytes.write(to: url); try require(chmod(url.path, 0o600) == 0) }
    private static func require(_ value: @autoclosure () throws -> Bool, line: Int = #line) throws { guard try value() else { throw WorkspaceSessionSmokeError.failed(line) } }
    private static func refused(_ operation: () throws -> Void) throws {
        do { try operation(); throw WorkspaceSessionSmokeError.failed(#line) }
        catch is NativePendingError {}
    }
}
