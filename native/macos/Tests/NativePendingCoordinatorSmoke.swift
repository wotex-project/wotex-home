import Foundation
import SwiftUI

private final class CaptureSource: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Data
    private var count = 0
    init(_ bytes: Data) { self.bytes = bytes }
    func capture() -> LocalCredentialCapture { lock.withLock { count += 1; return LocalCredentialCapture(bytes: bytes, nativeReference: nil) } }
    func replace(_ value: Data) { lock.withLock { bytes = value } }
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
        if mode == "create" {
            try require(coordinator.canStart)
            let input = NativePendingInput.suspend(operation: "rule:pending-original", revision: 3)
            do { _ = try await coordinator.begin(input, authorityEpoch: 1, expectedCredential: other); throw CoordinatorSmokeError.failed }
            catch LocalHealthError.sessionChanged {}
            try require(coordinator.canStart && coordinator.entries.isEmpty && source.calls == 1)
            do { _ = try await coordinator.begin(input, authorityEpoch: 2, expectedCredential: original); throw CoordinatorSmokeError.failed }
            catch LocalHealthError.sessionChanged {}
            try require(coordinator.canStart && coordinator.entries.isEmpty && source.calls == 2)
            try require(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("native-pending-v1.json").path))
            let pending = try await coordinator.begin(input, authorityEpoch: 1, expectedCredential: original)
            try require(pending.bytes == original && coordinator.entries == [pending.entry] && source.calls == 3)
            try require(!coordinator.canStart && pending.entry.context.principal == "operator:pending-fixture")
            try require(Mirror(reflecting: pending).children.isEmpty && Mirror(reflecting: coordinator).children.isEmpty)
            source.replace(other)
            do { _ = try await coordinator.begin(.suspend(operation: "rule:replacement", revision: 3), authorityEpoch: 1); throw CoordinatorSmokeError.failed }
            catch LocalHealthError.server("resolve_original_operation") {}
            try require(source.calls == 3)
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
            try await coordinator.resolving(pending)
            try require(coordinator.entries.isEmpty && coordinator.canStart && source.calls == 0)
            let loaded = try NativePendingStorage.load(directory: directory)
            try require(loaded.document.revision == 2 && loaded.document.entries.isEmpty)
        }
        print("{\"complete\":true}")
    }
    private static func decode(_ value: String?) -> Data? {
        guard let value, value.count == 43 else { return nil }
        return Data(base64Encoded: value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "=")
    }
    private static func require(_ value: Bool, line: Int = #line) throws {
        if !value { throw CoordinatorSmokeError.assertion(line) }
    }
}
