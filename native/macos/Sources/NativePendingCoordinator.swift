import Foundation
import SwiftUI

struct NativePendingPersistence: Sendable {
    private let directory: URL?
    init() { directory = nil }
    // A private foreground fixture cannot supply an authenticated custody seal.
    init(directory: URL) { self.directory = directory }
    func load() throws -> NativePendingSnapshot {
        if let directory { return try NativePendingStorage.load(directory: directory) }
        return try NativePendingStorage.load()
    }
    func retain(_ entry: NativePendingEntry, expected: NativePendingSnapshot) throws -> NativePendingSnapshot {
        if let directory { return try NativePendingStorage.retaining(entry, directory: directory, expected: expected) }
        return try NativePendingStorage.retaining(entry, expected: expected)
    }
    func phase(_ entry: NativePendingEntry, _ phase: NativePendingPhase, expected: NativePendingSnapshot) throws -> NativePendingSnapshot {
        if let directory { return try NativePendingStorage.changingPhase(of: entry, to: phase, directory: directory, expected: expected) }
        return try NativePendingStorage.changingPhase(of: entry, to: phase, expected: expected)
    }
    func resolve(_ entry: NativePendingEntry, expected: NativePendingSnapshot) throws -> NativePendingSnapshot {
        if let directory { return try NativePendingStorage.confirmingResolution(entry, directory: directory, expected: expected) }
        return try NativePendingStorage.confirmingResolution(entry, expected: expected)
    }
}

struct NativePendingOriginal: Sendable, CustomReflectable {
    let bytes: Data
    let entry: NativePendingEntry
    var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
}

@MainActor
final class NativePendingCoordinator: ObservableObject, CustomReflectable {
    static let shared = NativePendingCoordinator()
    nonisolated var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
    nonisolated private let persistence: NativePendingPersistence
    nonisolated private let capture: @Sendable () throws -> LocalCredentialCapture
    nonisolated let socketPath: @Sendable () -> String
    @Published private(set) var snapshot: NativePendingSnapshot?
    @Published private(set) var busy = false
    @Published private(set) var needsReload = true
    @Published private(set) var status = "Load pending operations before starting new work."
    @Published private(set) var error: String?
    @Published private(set) var owner: NativeControllerScope?
    var entries: [NativePendingEntry] { snapshot?.document.entries ?? [] }
    var hasCurrentOriginal: Bool {
        guard let owner else { return !entries.isEmpty }
        return entries.contains { $0.context.deployment == owner.deployment && $0.context.owner == owner.owner && $0.context.epoch == owner.epoch }
    }
    var canStart: Bool { snapshot != nil && !busy && !needsReload && !hasCurrentOriginal }
    init(persistence: NativePendingPersistence = NativePendingPersistence(),
         capture: @escaping @Sendable () throws -> LocalCredentialCapture = { try OperatorCredential.captureOriginal() },
         socketPath: @escaping @Sendable () -> String = { LocalHealthClient.defaultSocketPath() }) {
        self.persistence = persistence; self.capture = capture; self.socketPath = socketPath
    }

    // Startup is private-file read only. It never captures a credential or
    // invokes a broker, API, driver or automatic recovery action.
    func loadIfNeeded() async { if snapshot == nil || needsReload { await reload() } }
    func reload() async {
        guard !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            snapshot = try await Task.detached(priority: .userInitiated) { try self.persistence.load() }.value
            needsReload = false
            status = entries.isEmpty ? "No pending operations." : "Recover the original pending operation before new work."
        } catch { needsReload = true; status = "Pending operations unavailable."; self.error = error.localizedDescription }
    }
    // Only call with scope obtained by an actual signed broker status or an
    // authenticated identity read. Metadata decoded from a file supplies none.
    func observedOwner(_ scope: NativeControllerScope) {
        guard NativeCoreWire.valid(scope), !busy else { return }
        owner = scope
    }
    func begin(_ input: NativePendingInput, authorityEpoch: Int, expectedCredential: Data? = nil) async throws -> NativePendingOriginal {
        guard canStart, let expected = snapshot else { throw LocalHealthError.server("resolve_original_operation") }
        busy = true; error = nil
        defer { busy = false }
        let captured = try await Task.detached(priority: .userInitiated) { try self.capture() }.value
        guard expectedCredential == nil || expectedCredential == captured.bytes else { throw LocalHealthError.sessionChanged }
        let identity = try await Task.detached(priority: .userInitiated) {
            try LocalHealthClient.fetchControllerIdentity(socketPath: self.socketPath(), credential: captured.bytes)
        }.value
        guard identity.authorityEpoch == authorityEpoch else { throw LocalHealthError.sessionChanged }
        let context = NativePendingContext(deployment: identity.deploymentID, owner: identity.ownerID,
            epoch: Int64(identity.authorityEpoch), principal: identity.principalID)
        let custody: NativePendingCustody
        if let reference = captured.nativeReference {
            guard case .recover(let original) = try NativeBrokerWire.request(reference), original.verifier == captured.verifier,
                  original.receipt.deployment == context.deployment, original.receipt.owner == context.owner,
                  original.receipt.epoch == context.epoch, original.receipt.principal == context.principal,
                  identity.revision >= original.receipt.revision else { throw LocalHealthError.nativeGuardConflict }
            custody = .native(role: original.receipt.role, creationRevision: original.receipt.revision, verifier: captured.verifier)
        } else { custody = .manual(verifier: captured.verifier) }
        guard custody.valid(context: context) else { throw LocalHealthError.nativeGuardConflict }
        guard !expected.document.entries.contains(where: { $0.context.deployment == context.deployment &&
            $0.context.owner == context.owner && $0.context.epoch == context.epoch }) else {
            throw LocalHealthError.server("resolve_original_operation")
        }
        let entry = NativePendingEntry(context: context, custody: custody, input: input, phase: .pending)
        do {
            snapshot = try await Task.detached(priority: .userInitiated) { try self.persistence.retain(entry, expected: expected) }.value
        } catch {
            needsReload = true; self.error = error.localizedDescription
            status = "Original publication not confirmed. Reload before sending any request."
            throw error
        }
        owner = NativeControllerScope(deployment: context.deployment, owner: context.owner, epoch: context.epoch, revision: Int64(identity.revision))
        status = "Original operation retained before submission."
        return NativePendingOriginal(bytes: captured.bytes, entry: entry)
    }
    func changingPhase(_ original: NativePendingOriginal, to phase: NativePendingPhase) async throws -> NativePendingOriginal {
        guard !busy, !needsReload, let expected = snapshot,
              NativePendingStorage.permitsTransition(from: original.entry.phase, to: phase),
              let current = expected.document.entries.first(where: { $0.context == original.entry.context &&
                  $0.custody == original.entry.custody && $0.input == original.entry.input }) else {
            throw NativePendingError.conflict
        }
        busy = true; defer { busy = false }
        do {
            snapshot = try await Task.detached(priority: .userInitiated) { try self.persistence.phase(current, phase, expected: expected) }.value
            return NativePendingOriginal(bytes: original.bytes, entry: try current.changingPhase(phase))
        } catch { needsReload = true; self.error = error.localizedDescription; throw error }
    }
    // The caller has already verified its original Authority result or definite
    // first-attempt refusal. Publication must finish before it clears memory/UI.
    func resolving(_ original: NativePendingOriginal) async throws {
        guard !busy, !needsReload, let expected = snapshot else {
            throw NativePendingError.conflict
        }
        busy = true; defer { busy = false }
        do {
            snapshot = try await Task.detached(priority: .userInitiated) { try self.persistence.resolve(original.entry, expected: expected) }.value
            status = entries.isEmpty ? "No pending operations." : "Other original operations remain unresolved."
        } catch { needsReload = true; self.error = error.localizedDescription; throw error }
    }
}
