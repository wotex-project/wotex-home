import Foundation
import SwiftUI

struct NativeGenerationContext: Sendable, CustomReflectable {
    let options: HomeGenerationOptions, contract: HomeAuthoringContractRead, identity: HomeControllerIdentity
    let capture: LocalCredentialCapture, selection: NativeControllerAssociationSnapshot, generation: UInt64
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
            "Input SHA \(original.sha)", "Provider \(fields?["provider_sha256"] as? String ?? "Retained root provider")"]
    }
}

@MainActor
final class NativeGenerationWorkspaceCoordinator: ObservableObject {
    @Published private(set) var snapshot: NativeGenerationWorkspaceSnapshot?
    @Published private(set) var busy = false
    @Published private(set) var needsReload = false
    private let directory: URL?
    init(directory: URL? = nil) { self.directory = directory }
    var entries: [NativeGenerationWorkspaceEntry] { snapshot?.document.entries ?? [] }
    func reload() async throws {
        guard !busy else { throw NativePendingError.conflict }; busy = true; defer { busy = false }
        do {
            let directory = directory
            snapshot = try await Task.detached {
                guard let root = try directory ?? NativePrivateDocuments.directory(create: false) else { return NativeGenerationWorkspaceSnapshot.empty }
                return try NativeGenerationWorkspaceStorage.load(directory: root)
            }.value
            needsReload = false
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
    func current(_ entry: NativeGenerationWorkspaceEntry) throws {
        guard !busy, !needsReload, entries.contains(entry) else { throw NativePendingError.conflict }
    }
}
