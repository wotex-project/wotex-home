import Darwin
import Foundation
import SwiftUI

private final class CaptureSource: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Data
    private var reference: Data?
    private var count = 0
    init(_ bytes: Data) { self.bytes = bytes }
    func capture() -> LocalCredentialCapture { lock.withLock { count += 1; return LocalCredentialCapture(bytes: bytes, nativeReference: reference) } }
    func replace(_ value: Data) { lock.withLock { bytes = value } }
    func changeReference(_ value: Data?) { lock.withLock { reference = value } }
    var calls: Int { lock.withLock { count } }
}
private enum CoordinatorSmokeError: Error { case failed, assertion(Int) }

@main
struct NativePendingCoordinatorSmoke {
    @MainActor
    static func main() async {
        do { try await run() }
        catch CoordinatorSmokeError.assertion(let line) { print("{\"complete\":false,\"line\":\(line)}") }
        catch LocalHealthError.server(let reason) { print("{\"complete\":false,\"line\":0,\"reason\":\"\(reason)\"}") }
        catch let error as NativePendingError { print("{\"complete\":false,\"line\":0,\"reason\":\"\(error)\"}") }
        catch { print("{\"complete\":false,\"line\":0}") }
    }
    @MainActor
    private static func run() async throws {
        guard CommandLine.arguments.count == 4, let line = readLine(),
              let values = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: String],
              let original = decode(values["original"]), let other = decode(values["other"]) else { throw CoordinatorSmokeError.failed }
        let path = CommandLine.arguments[1]
        let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let mode = CommandLine.arguments[3]
        let source = CaptureSource(original)
        let coordinator = NativePendingCoordinator(persistence: NativePendingPersistence(directory: directory),
            capture: { source.capture() }, socketPath: { path })
        try require(!coordinator.canStart && source.calls == 0)
        await coordinator.loadIfNeeded()
        try require(!coordinator.busy && !coordinator.needsReload && source.calls == 0)
        if mode == "phases" {
            try await phases(coordinator, directory: directory, bytes: original)
            try require(source.calls == 0)
            print("{\"complete\":true}")
            return
        }
        if mode == "publication" {
            let lock = open(directory.appendingPathComponent("native-pending-v1.lock").path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
            try require(lock >= 0 && flock(lock, LOCK_EX | LOCK_NB) == 0)
            do { _ = try await coordinator.begin(.suspend(operation: "rule:publication-original", revision: 3), authorityEpoch: 1, expectedCredential: original); throw CoordinatorSmokeError.failed }
            catch NativePendingError.capacity {}
            _ = flock(lock, LOCK_UN); _ = Darwin.close(lock)
            try require(coordinator.needsReload && !coordinator.canStart && coordinator.entries.count == 1 && source.calls == 1)
            await coordinator.reload()
            try require(!coordinator.needsReload && coordinator.snapshot?.document.entries.isEmpty == true &&
                coordinator.entries[0].input.operationID == "rule:publication-original" && !coordinator.canStart && source.calls == 1)
            source.replace(other)
            do { _ = try await coordinator.begin(.suspend(operation: "rule:replacement", revision: 3), authorityEpoch: 1); throw CoordinatorSmokeError.failed }
            catch LocalHealthError.server("resolve_original_operation") {}
            try require(source.calls == 1 && !FileManager.default.fileExists(atPath: directory.appendingPathComponent("native-pending-v1.json").path))
            print("{\"complete\":true}")
            return
        }
        if mode == "create" {
            try require(coordinator.canStart)
            let input = NativePendingInput.suspend(operation: "rule:pending-original", revision: 3)
            source.changeReference(Data([1]))
            do { _ = try await coordinator.begin(input, authorityEpoch: 1, expectedCapture: LocalCredentialCapture(bytes: original, nativeReference: nil)); throw CoordinatorSmokeError.failed }
            catch LocalHealthError.sessionChanged {}
            try require(coordinator.canStart && coordinator.entries.isEmpty && source.calls == 1)
            source.changeReference(nil)
            do { _ = try await coordinator.begin(input, authorityEpoch: 1, expectedCapture: LocalCredentialCapture(bytes: original, nativeReference: Data([1]))); throw CoordinatorSmokeError.failed }
            catch LocalHealthError.sessionChanged {}
            try require(coordinator.canStart && coordinator.entries.isEmpty && source.calls == 2)
            do { _ = try await coordinator.begin(input, authorityEpoch: 1, expectedCredential: other); throw CoordinatorSmokeError.failed }
            catch LocalHealthError.sessionChanged {}
            try require(coordinator.canStart && coordinator.entries.isEmpty && source.calls == 3)
            do { _ = try await coordinator.begin(input, authorityEpoch: 2, expectedCredential: original); throw CoordinatorSmokeError.failed }
            catch LocalHealthError.sessionChanged {}
            try require(coordinator.canStart && coordinator.entries.isEmpty && source.calls == 4)
            try require(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("native-pending-v1.json").path))
            let pending = try await coordinator.begin(input, authorityEpoch: 1, expectedCredential: original)
            try require(pending.bytes == original && coordinator.entries == [pending.entry] && source.calls == 5)
            try require(!coordinator.canStart && pending.entry.context.principal == "operator:pending-fixture")
            try require(Mirror(reflecting: pending).children.isEmpty && Mirror(reflecting: coordinator).children.isEmpty)
            source.replace(other)
            do { _ = try await coordinator.begin(.suspend(operation: "rule:replacement", revision: 3), authorityEpoch: 1); throw CoordinatorSmokeError.failed }
            catch LocalHealthError.server("resolve_original_operation") {}
            try require(source.calls == 5)
            do {
                _ = try await Task.detached {
                    try LocalHealthClient.suspendRules(socketPath: path, credential: pending.bytes,
                        authorityEpoch: 1, operationID: "rule:pending-original", expectedRevision: 3)
                }.value
                throw CoordinatorSmokeError.failed
            } catch LocalHealthError.transport {}
            try require(coordinator.entries == [pending.entry] && !coordinator.canStart)
        } else {
            try require(coordinator.entries.count == 1 && !coordinator.canStart)
            let entry = coordinator.entries[0]
            if mode == "recover-scope" {
                let context = NativePendingContext(deployment: entry.context.deployment, owner: entry.context.owner,
                    epoch: entry.context.epoch, principal: "other:pending-fixture")
                let mismatched = NativePendingEntry(context: context, custody: entry.custody, input: entry.input, phase: entry.phase)
                let first = try NativePendingStorage.load(directory: directory)
                let cleared = try NativePendingStorage.resolving(entry, directory: directory, expected: first)
                _ = try NativePendingStorage.retaining(mismatched, directory: directory, expected: cleared)
                await coordinator.reload()
                for action in [NativePendingRecoveryAction.lookup, .retry] {
                    await coordinator.recover(mismatched, action: action, custody: { _ in original }, execute: NativePendingRecoveryOperations.execute)
                    try require(coordinator.error != nil && coordinator.entries == [mismatched] && !coordinator.canStart && source.calls == 0)
                }
                print("{\"complete\":true}")
                return
            }
            if mode.hasPrefix("recover-") {
                if mode == "recover-confirm" {
                    guard case .activation(let receipt) = try LocalHealthClient.fetchRuleOperationStatus(socketPath: path,
                        credential: original, authorityEpoch: 1, operationID: entry.input.operationID), receipt.admissionRevision == 0 else {
                        throw CoordinatorSmokeError.failed
                    }
                    _ = try NativePendingStorage.resolving(entry, directory: directory, expected: NativePendingStorage.load(directory: directory))
                    do { try await coordinator.resolving(NativePendingOriginal(bytes: original, entry: entry)); throw CoordinatorSmokeError.failed }
                    catch NativePendingError.conflict {}
                    await coordinator.reload()
                    try require(coordinator.snapshot?.document.entries.isEmpty == true && coordinator.entries == [entry])
                }
                let action: NativePendingRecoveryAction = mode.hasSuffix("lookup") || mode == "recover-confirm" ? .lookup : .retry
                await coordinator.recover(entry, action: action, custody: { _ in other }, execute: NativePendingRecoveryOperations.execute)
                try require(coordinator.error != nil && coordinator.entries == [entry] && source.calls == 0)
                await coordinator.recover(entry, action: action, custody: { _ in original }, execute: NativePendingRecoveryOperations.execute)
                try require(coordinator.error == nil && coordinator.entries.isEmpty && coordinator.canStart && source.calls == 0)
                let loaded = try NativePendingStorage.load(directory: directory)
                try require(loaded.document.revision == 2 && loaded.document.entries.isEmpty)
                print("{\"complete\":true}")
                return
            }
            let identity = try await Task.detached { try LocalHealthClient.fetchControllerIdentity(socketPath: path, credential: original) }.value
            try require(entry.context.matches(identity) && entry.custody.matches(original))
            let otherIdentity = try await Task.detached { try LocalHealthClient.fetchControllerIdentity(socketPath: path, credential: other) }.value
            try require(!entry.context.matches(otherIdentity) && !entry.custody.matches(other))
            try require(source.calls == 0 && coordinator.entries == [entry])
            let pending = NativePendingOriginal(bytes: original, entry: entry)
            switch entry.input {
            case .suspend(let operation, let revision):
                if mode == "lookup" {
                    let result = try await Task.detached {
                        try LocalHealthClient.fetchRuleOperationStatus(socketPath: path, credential: pending.bytes,
                            authorityEpoch: Int(entry.context.epoch), operationID: operation)
                    }.value
                    guard case .activation(let receipt) = result else { throw CoordinatorSmokeError.failed }
                    try require(receipt.admissionRevision == 0 && receipt.revision == revision + 1)
                } else if mode == "retry" {
                    let result = try await Task.detached {
                        try LocalHealthClient.suspendRules(socketPath: path, credential: pending.bytes,
                            authorityEpoch: Int(entry.context.epoch), operationID: operation, expectedRevision: Int(revision))
                    }.value
                    try require(result.admissionRevision == 0 && result.revision == revision + 1)
                } else { throw CoordinatorSmokeError.failed }
            default: throw CoordinatorSmokeError.failed
            }
            // Another actual private file publisher finishes this same verified
            // resolution before our original cached publication can confirm it.
            let onDisk = try NativePendingStorage.load(directory: directory)
            _ = try NativePendingStorage.resolving(entry, directory: directory, expected: onDisk)
            do { try await coordinator.resolving(pending); throw CoordinatorSmokeError.failed }
            catch NativePendingError.conflict {}
            try require(coordinator.needsReload && !coordinator.canStart && coordinator.entries == [entry])
            await coordinator.reload()
            try require(!coordinator.needsReload && coordinator.snapshot?.document.entries.isEmpty == true &&
                coordinator.entries == [entry] && !coordinator.canStart)
            try await coordinator.resolving(pending)
            try require(coordinator.entries.isEmpty && coordinator.canStart && source.calls == 0)
            let loaded = try NativePendingStorage.load(directory: directory)
            try require(loaded.document.revision == 2 && loaded.document.entries.isEmpty)
        }
        print("{\"complete\":true}")
    }
    @MainActor
    private static func phases(_ coordinator: NativePendingCoordinator, directory: URL, bytes: Data) async throws {
        // Inert journal metadata only: no review approval, credential capture,
        // API request or synthetic authenticated custody result is provided.
        let context = NativePendingContext(deployment: String(repeating: "a", count: 64), owner: String(repeating: "b", count: 64), epoch: 1, principal: "operator:inert")
        let operation = try HomeProfileOperation(["action": "select", "authority_epoch": 1, "operation_id": "profile:phase",
            "expected_revision": 9, "artifact_digest": String(repeating: "c", count: 64), "expected_trust_revision": 2,
            "target_id": "light:inert", "expected_resource_revision": 4, "expected_binding_revision": 3,
            "expected_selection_generation": 2, "expected_policy_generation": 5, "expected_rule_generation": 6,
            "session_ref": "capture:inert", "candidate_ref": "candidate:inert", "review_ref": "review:inert"])
        let entry = NativePendingEntry(context: context, custody: .manual(verifier: LocalHealthClient.profileSHA(bytes)),
            input: .profile(preparing: true, operation: operation), phase: .pending)
        let first = try NativePendingStorage.retaining(entry, directory: directory, expected: .empty)
        await coordinator.reload()
        let held = NativePendingPhase.review(token: "review:original", digest: String(repeating: "d", count: 64))
        _ = try NativePendingStorage.changingPhase(of: entry, to: held, directory: directory, expected: first)
        let original = NativePendingOriginal(bytes: bytes, entry: entry)
        do { _ = try await coordinator.changingPhase(original, to: held); throw CoordinatorSmokeError.failed }
        catch NativePendingError.conflict {}
        try require(coordinator.needsReload && !coordinator.canStart)
        await coordinator.reload()
        let reviewed = try await coordinator.changingPhase(original, to: held)
        try require(coordinator.snapshot?.document.revision == 2 && reviewed.entry.phase == held)
        let commit = NativePendingPhase.commitPending(token: "review:original", digest: String(repeating: "d", count: 64))
        _ = try NativePendingStorage.changingPhase(of: reviewed.entry, to: commit, directory: directory,
            expected: NativePendingStorage.load(directory: directory))
        do { _ = try await coordinator.changingPhase(reviewed, to: commit); throw CoordinatorSmokeError.failed }
        catch NativePendingError.conflict {}
        await coordinator.reload()
        let committed = try await coordinator.changingPhase(reviewed, to: commit)
        try require(coordinator.snapshot?.document.revision == 3 && committed.entry.phase == commit)
        do { _ = try await coordinator.changingPhase(reviewed, to: .cancelPending(token: "review:original", digest: String(repeating: "d", count: 64))); throw CoordinatorSmokeError.failed }
        catch NativePendingError.conflict {}
        try require(coordinator.needsReload && !coordinator.canStart)
        await coordinator.reload()
        try require(coordinator.entries == [committed.entry] && !coordinator.canStart)
    }
    private static func decode(_ value: String?) -> Data? {
        guard let value, value.count == 43 else { return nil }
        return Data(base64Encoded: value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "=")
    }
    private static func require(_ value: Bool, line: Int = #line) throws {
        if !value { throw CoordinatorSmokeError.assertion(line) }
    }
}
