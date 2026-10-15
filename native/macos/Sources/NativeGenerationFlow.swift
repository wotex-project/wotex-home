import Foundation
import SwiftUI

struct NativeGenerationContext: Sendable, CustomReflectable {
    let options: HomeGenerationOptions, contract: HomeAuthoringContractRead, identity: HomeControllerIdentity
    let capture: LocalCredentialCapture?, selection: NativeControllerAssociationSnapshot, generation: UInt64
    let paired: NativePairedAuthoringBasis?
    private let readDeadline: ContinuousClock.Instant?
    init(options: HomeGenerationOptions, contract: HomeAuthoringContractRead, identity: HomeControllerIdentity,
         capture: LocalCredentialCapture, selection: NativeControllerAssociationSnapshot, generation: UInt64) {
        self.options = options; self.contract = contract; self.identity = identity; self.capture = capture
        self.selection = selection; self.generation = generation; paired = nil; readDeadline = nil
    }
    init(paired value: NativePairedGenerationContext, selection: NativeControllerAssociationSnapshot,
         generation: UInt64, deadline: ContinuousClock.Instant) {
        options = value.options; contract = value.contract; identity = value.identity; capture = nil; paired = value.paired
        self.selection = selection; self.generation = generation; readDeadline = deadline
    }
    func deliveryCurrent() throws {
        if let readDeadline { guard !Task.isCancelled, ContinuousClock.now < readDeadline else { throw NativePendingError.outcomeUnknown } }
    }
    var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
    var policies: [[String: Any]] { (try? options.fields()["policies"] as? [[String: Any]]) ?? [] }
}

struct NativeGenerationDraftFields: Sendable, Equatable, CustomReflectable {
    var policySHA = "", instruction = "", attempts = "", attemptMS = "", totalMS = ""
    var passages: Set<Int> = [], examples: Set<Int> = []
    var remoteConsent = false
    var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
    func original(_ context: NativeGenerationContext, operation: String) throws -> HomeGenerationOriginal {
        let policies = try context.options.fields()["policies"] as! [[String: Any]]
        guard let policy = policies.first(where: { $0["policy_sha256"] as? String == policySHA }),
              let provider = policy["provider"] as? [String: Any], let locality = provider["locality"] as? String,
              locality == "local" || (policy["remote_export"] as? Bool == true && remoteConsent) else { throw LocalHealthError.invalidProfileRequest }
        func decimal(_ value: String, maximum: Int) throws -> Int {
            guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }), let integer = Int(value),
                  String(integer) == value, (1...maximum).contains(integer) else { throw LocalHealthError.invalidProfileRequest }
            return integer
        }
        func selected(_ indexes: Set<Int>, _ rows: [[String: Any]]) throws -> [[String: Any]] {
            guard indexes.allSatisfy({ rows.indices.contains($0) }) else { throw LocalHealthError.invalidProfileRequest }
            return indexes.sorted().map { rows[$0] }
        }
        return try NativeGenerationOriginalWire.encode([
            "authority_epoch": context.identity.authorityEpoch, "operation_id": operation, "expected_revision": context.identity.revision,
            "provider_sha256": policy["provider_sha256"]!, "policy_sha256": policySHA, "remote_export": locality == "remote",
            "projection": ["contract_digest": context.contract.contractSHA, "instruction": instruction,
                "passages": try selected(passages, policy["passages"] as! [[String: Any]]),
                "examples": try selected(examples, policy["examples"] as! [[String: Any]]), "limits": policy["limits"]!],
            "budget": ["attempts": try decimal(attempts, maximum: 3), "attempt_ms": try decimal(attemptMS, maximum: 30000), "total_ms": try decimal(totalMS, maximum: 120000)]
        ], kind: .preparation)
    }
}

struct NativeGenerationDecision: Sendable, CustomReflectable {
    let original: HomeGenerationOriginal, context: NativeGenerationContext
    let previous: NativeGenerationWorkspaceEntry?
    var feedbackDraft: String? = nil
    var feedbackAssessment: HomeGenerationAssessment? = nil
    var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
    var details: [String] {
        let fields = try? original.fields()
        return ["\(original.kind.rawValue.capitalized) · \(original.operation)", "Authority \(original.epoch) · Store revision \(original.expectedRevision)",
            "Input SHA \(original.sha)", "Provider \(fields?["provider_sha256"] as? String ?? "Retained root provider")"] + (context.paired.map { ["Controller: \($0.association.label)"] } ?? [])
    }
}

@MainActor
final class NativeGenerationWorkspaceCoordinator: ObservableObject {
    @Published private(set) var snapshot: NativeGenerationWorkspaceSnapshot?
    @Published private(set) var busy = false
    @Published private(set) var needsReload = false
    private let directory: URL?
    private var unconfirmedEntry: NativeGenerationWorkspaceEntry?
    init(directory: URL? = nil) { self.directory = directory }
    var entries: [NativeGenerationWorkspaceEntry] {
        let values = snapshot?.document.entries ?? []
        if let unconfirmedEntry, !values.contains(unconfirmedEntry) { return values + [unconfirmedEntry] }; return values
    }
    func deliveryUnconfirmed(_ entry: NativeGenerationWorkspaceEntry) { unconfirmedEntry = entry; needsReload = true }
    func reload() async throws {
        guard !busy else { throw NativePendingError.conflict }; busy = true; defer { busy = false }
        do {
            let directory = directory
            snapshot = try await Task.detached {
                guard let root = try directory ?? NativePrivateDocuments.directory(create: false) else { return NativeGenerationWorkspaceSnapshot.empty }
                return try NativeGenerationWorkspaceStorage.load(directory: root)
            }.value
            needsReload = false; unconfirmedEntry = nil
        } catch { needsReload = true; throw error }
    }
    private func write(_ action: @escaping @Sendable (URL, NativeGenerationWorkspaceSnapshot) throws -> NativeGenerationWorkspaceSnapshot) async throws {
        guard !busy, !needsReload, let expected = snapshot else { throw NativePendingError.conflict }
        busy = true; defer { busy = false }
        do {
            let directory = directory
            snapshot = try await Task.detached {
                guard let root = try directory ?? NativePrivateDocuments.directory(create: true) else { throw NativePendingError.unavailable }
                return try action(root, expected)
            }.value
        } catch { needsReload = true; throw error }
    }
    func retain(_ entry: NativeGenerationWorkspaceEntry) async throws { try await write { try NativeGenerationWorkspaceStorage.retaining(entry, directory: $0, expected: $1) } }
    func replace(_ entry: NativeGenerationWorkspaceEntry, with changed: NativeGenerationWorkspaceEntry) async throws { try await write { try NativeGenerationWorkspaceStorage.replacing(entry, with: changed, directory: $0, expected: $1) } }
    func archive(_ entry: NativeGenerationWorkspaceEntry) async throws { try await write { try NativeGenerationWorkspaceStorage.removing(entry, directory: $0, expected: $1) } }
    func publishPaired(_ entry: NativeGenerationWorkspaceEntry, previous: NativeGenerationWorkspaceEntry?,
                       session: NativePairedControllerSession) async throws -> NativeGenerationWorkspaceSnapshot {
        guard !busy, !needsReload, let expected = snapshot else { throw NativePendingError.conflict }
        busy = true; defer { busy = false }
        do {
            let publication = try await session.publishingGenerationWorkspace(entry, previous: previous, workspace: expected)
            try publication.deliveryCurrent(); snapshot = publication.workspace; return publication.workspace
        } catch { deliveryUnconfirmed(entry); throw error }
    }
    func performPaired(_ entry: NativeGenerationWorkspaceEntry, action: NativePairedWorkspaceAction,
                       journal: NativePendingCoordinator, associations: NativeControllerAssociationSnapshot,
                       clock: @escaping @Sendable () throws -> NativeControllerCertificateClock) async throws -> NativePairedWorkspacePublication {
        try current(entry)
        guard let expected = snapshot else { throw NativePendingError.conflict }
        busy = true; defer { busy = false }
        do {
            let publication = try await journal.performingPairedWorkspace(entry, action: action, workspace: expected,
                associations: associations, clock: clock)
            try publication.deliveryCurrent(); snapshot = publication.workspace; return publication
        } catch { deliveryUnconfirmed(entry); throw error }
    }
    func current(_ entry: NativeGenerationWorkspaceEntry) throws {
        guard !busy, !needsReload, entries.contains(entry) else { throw NativePendingError.conflict }
    }
}

// UI carries the actual production publication across the final actor hop.
struct NativeGenerationDelivery: Sendable, CustomReflectable {
    let entry: NativeGenerationWorkspaceEntry
    let root: HomeGenerationStatus?, attempt: HomeGenerationStatus?
    private let originalPublication: NativePairedRecoveryPublication?
    private let workspacePublication: NativePairedWorkspacePublication?
    var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
    init(local entry: NativeGenerationWorkspaceEntry, root: HomeGenerationStatus? = nil, attempt: HomeGenerationStatus? = nil) throws {
        guard !entry.custody.isPaired else { throw NativePendingError.unavailable }
        self.entry = entry; self.root = root; self.attempt = attempt; originalPublication = nil; workspacePublication = nil
    }
    init(original publication: NativePairedRecoveryPublication, entry: NativeGenerationWorkspaceEntry) throws {
        guard publication.entry.context == entry.context, publication.entry.custody == entry.custody,
              try publication.entry.generationOperation() == (entry.attempts.last ?? entry.preparation) else { throw NativePendingError.conflict }
        self.entry = entry; root = nil; attempt = nil; originalPublication = publication; workspacePublication = nil
    }
    init(workspace publication: NativePairedWorkspacePublication) {
        entry = publication.entry; root = publication.read.root; attempt = publication.read.attempt
        originalPublication = nil; workspacePublication = publication
    }
    @MainActor func deliveryCurrent(workspace: NativeGenerationWorkspaceCoordinator, journal: NativePendingCoordinator) throws {
        do { try originalPublication?.deliveryCurrent(); try workspacePublication?.deliveryCurrent() }
        catch { unconfirmed(workspace: workspace, journal: journal); throw error }
    }
    @MainActor func unconfirmed(workspace: NativeGenerationWorkspaceCoordinator, journal: NativePendingCoordinator) {
        guard originalPublication != nil || workspacePublication != nil else { return }
        workspace.deliveryUnconfirmed(entry)
        if let originalPublication { journal.pairedDeliveryUnconfirmed(originalPublication) }
        if let workspacePublication { journal.pairedWorkspaceUnconfirmed(workspacePublication) }
    }
}

struct NativeGenerationWorkspaceSelection: Sendable {
    let entry: NativeGenerationWorkspaceEntry?
    private let deadline: ContinuousClock.Instant?
    init(entry: NativeGenerationWorkspaceEntry?, deadline: ContinuousClock.Instant?) { self.entry = entry; self.deadline = deadline }
    func deliveryCurrent() throws {
        if let deadline { guard !Task.isCancelled, ContinuousClock.now < deadline else { throw NativePendingError.outcomeUnknown } }
    }
}
