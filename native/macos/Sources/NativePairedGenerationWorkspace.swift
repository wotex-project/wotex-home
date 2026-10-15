import Foundation

// Closed metadata choices. None can manufacture a signed workspace session.
enum NativePairedWorkspaceAction: Sendable, Equatable {
    case status, cancel, restorePending, assessDraft(operation: String, instruction: String), archive(acceptUncertainty: Bool)
}

struct NativePairedWorkspaceRead: Sendable, CustomReflectable {
    let root: HomeGenerationStatus?, attempt: HomeGenerationStatus?, identity: HomeControllerIdentity
    var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
}
struct NativePairedGeneratedAssessment: Sendable, CustomReflectable {
    let original: HomeAuthoringOriginal, identity: HomeControllerIdentity, contract: HomeAuthoringContractRead
    var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
}

enum NativePairedWorkspaceCorrespondence {
    static func association(_ entry: NativeGenerationWorkspaceEntry, action: NativePairedWorkspaceAction,
                            workspace: NativeGenerationWorkspaceSnapshot, pending: NativePendingSnapshot,
                            associations: NativeControllerAssociationSnapshot) throws -> NativeControllerPublicAssociation {
        _ = try entry.checked(); _ = try workspace.document.encoded()
        guard workspace.document.entries.contains(entry), case .paired(let id, _, _, _) = entry.custody,
              let association = associations.document.records.first(where: { $0.id == id }),
              entry.custody.matches(association: association, context: entry.context),
              association.access.permissions.contains("profile:manage") else { throw NativePendingError.conflict }
        switch action {
        case .assessDraft(let operation, let instruction):
            guard LocalHealthClient.profileID(operation), instruction.utf8.count <= 4096,
                  instruction.replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\t", with: "").range(of: "\\p{Cc}", options: .regularExpression) == nil,
                  !entry.attempts.isEmpty else { throw LocalHealthError.invalidProfileRequest }
        case .restorePending, .archive:
            guard !entry.cancellationPending, !pending.document.entries.contains(where: { sameOwner($0.context, entry.context) }) else { throw NativePendingError.conflict }
        case .status, .cancel: break
        }
        return association
    }
    static func sameOwner(_ a: NativePendingContext, _ b: NativePendingContext) -> Bool {
        a.deployment == b.deployment && a.owner == b.owner && a.epoch == b.epoch
    }
    static func intent(_ entry: NativeGenerationWorkspaceEntry, value: Bool,
                       before: NativeGenerationWorkspaceSnapshot, after: NativeGenerationWorkspaceSnapshot) throws -> NativeGenerationWorkspaceEntry {
        let next = try entry.cancellation(value)
        try publication(entry, replacement: next, before: before, after: after)
        return next
    }
    static func publication(_ entry: NativeGenerationWorkspaceEntry, replacement: NativeGenerationWorkspaceEntry?,
                            before: NativeGenerationWorkspaceSnapshot, after: NativeGenerationWorkspaceSnapshot) throws {
        guard entry.custody.isPaired, before.document.entries.contains(entry), before.document.version == .v2,
              after.document.version == before.document.version else { throw NativePendingError.conflict }
        if let replacement {
            guard replacement == (try entry.cancellation(replacement.cancellationPending)) else { throw NativePendingError.conflict }
        } else { guard !entry.cancellationPending else { throw NativePendingError.conflict } }
        let entries = before.document.entries.compactMap { $0 == entry ? replacement : $0 }
        if entries == before.document.entries {
            guard before == after else { throw NativePendingError.conflict }
        } else {
            guard before.document.revision < Int64.max, after.document.revision == before.document.revision + 1,
                  after.document.entries == entries else { throw NativePendingError.conflict }
        }
        _ = try after.document.encoded()
    }
    static func restoredOriginal(_ entry: NativeGenerationWorkspaceEntry) throws -> NativePendingEntry {
        guard !entry.cancellationPending else { throw NativePendingError.conflict }
        _ = try entry.checked()
        return NativePendingEntry(context: entry.context, custody: entry.custody,
            input: .generation(entry.attempts.last ?? entry.preparation), phase: .pending)
    }
    static func permitsArchive(_ entry: NativeGenerationWorkspaceEntry, read: NativePairedWorkspaceRead, acceptUncertainty: Bool) throws {
        guard !entry.cancellationPending, read.attempt?.state != "running" else { throw NativePendingError.conflict }
        let uncertain = read.root == nil || (!entry.attempts.isEmpty && (read.attempt == nil || (read.attempt?.state == "unknown" && read.attempt?.result == nil)))
        guard !uncertain || acceptUncertainty else { throw NativePendingError.conflict }
    }
}

// Raw transport adapter only. The actual factory fixes the retained entry and
// action, app/Keychain seal, file witnesses and finite TLS lifetime around it.
enum NativePairedGenerationWorkspaceOperations {
    static func read(_ entry: NativeGenerationWorkspaceEntry, association: NativeControllerPublicAssociation,
                     credential: Data) throws -> NativePairedWorkspaceRead {
        try scoped(entry, association, credential) {
            let root = try NativeGenerationClient.status(socketPath: "", credential: credential, kind: .preparation,
                epoch: entry.preparation.epoch, operation: entry.preparation.operation, original: entry.preparation)
            let attempt: HomeGenerationStatus?
            if let original = entry.attempts.last {
                attempt = try NativeGenerationClient.status(socketPath: "", credential: credential, kind: .attempt,
                    epoch: original.epoch, operation: original.operation, original: original)
            } else { attempt = nil }
            let identity = try LocalHealthClient.fetchControllerIdentity(socketPath: "", credential: credential)
            guard entry.context.matches(identity), Int64(identity.revision) >= max(root?.knownRevision ?? 0, attempt?.knownRevision ?? 0) else { throw LocalHealthError.nativeGuardConflict }
            return NativePairedWorkspaceRead(root: root, attempt: attempt, identity: identity)
        }
    }
    static func cancel(_ entry: NativeGenerationWorkspaceEntry, association: NativeControllerPublicAssociation,
                       credential: Data) throws -> HomeGenerationStatus? {
        guard entry.cancellationPending else { throw NativePendingError.conflict }
        return try scoped(entry, association, credential) {
            guard try NativeGenerationClient.status(socketPath: "", credential: credential, kind: .preparation,
                epoch: entry.preparation.epoch, operation: entry.preparation.operation, original: entry.preparation) != nil else { throw NativePendingError.conflict }
            return try NativeGenerationClient.cancel(socketPath: "", credential: credential, original: entry.preparation)
        }
    }
    static func assess(_ entry: NativeGenerationWorkspaceEntry, association: NativeControllerPublicAssociation,
                       credential: Data, operation: String, instruction: String) throws -> NativePairedGeneratedAssessment {
        try scoped(entry, association, credential) {
            let before = try LocalHealthClient.fetchControllerIdentity(socketPath: "", credential: credential)
            guard let attempt = entry.attempts.last,
                  let status = try NativeGenerationClient.status(socketPath: "", credential: credential, kind: .attempt,
                    epoch: attempt.epoch, operation: attempt.operation, original: attempt),
                  let result = status.result, result.disposition == "candidate", let assessment = result.assessment else { throw LocalHealthError.invalidProfileRequest }
            let fields = try result.fields(), draft = fields["draft_ref"] as! [String: Any]
            let digest = draft["object_digest"] as! String, first = LocalHealthClient.profileInteger(draft["first_revision"])!
            let identity = try JSONSerialization.data(withJSONObject: [entry.context.principal, attempt.epoch, attempt.operation, "draft"], options: [.withoutEscapingSlashes])
            let importID = "ga:" + LocalHealthClient.profileSHA(Data("wotex-home.generation-object-operation@1\n".utf8) + identity)
            guard let imported = try NativeAuthoringReadClient.fetchOriginal(socketPath: "", credential: credential,
                    kind: .import, epoch: attempt.epoch, operation: importID), imported.object?.kind == "draft",
                  imported.object?.digest == digest, imported.firstRevision == Int64(first), imported.object?.payloadSHA == assessment.draftSHA,
                  let object = try NativeAuthoringReadClient.fetchObject(socketPath: "", credential: credential, digest: digest),
                  object.summary == imported.object, object.firstRevision == Int64(first) else { throw LocalHealthError.invalidResponse }
            let projection = try entry.preparation.fields()["projection"] as! [String: Any]
            func handles(_ rows: [[String: Any]], kind: String) throws -> [[String: Any]] {
                var selected: [String: Int] = [:]
                for row in rows {
                    let digest = row["object_digest"] as! String, first = LocalHealthClient.profileInteger(row["first_revision"])!
                    guard selected[digest] == nil || selected[digest] == first else { throw LocalHealthError.invalidProfileRequest }
                    selected[digest] = first
                }
                return try selected.keys.sorted().map { digest in
                    guard let object = try NativeAuthoringReadClient.fetchObject(socketPath: "", credential: credential, digest: digest),
                          object.summary.kind == kind, object.firstRevision == Int64(selected[digest]!) else { throw LocalHealthError.invalidResponse }
                    return ["object_digest": digest, "first_revision": selected[digest]!]
                }
            }
            let sources = try handles((projection["passages"] as! [[String: Any]]).map { $0["reference"] as! [String: Any] }, kind: "source")
            let fixtures = try handles(projection["examples"] as! [[String: Any]], kind: "fixture")
            let contract = try NativeAuthoringContractClient.fetch(socketPath: "", credential: credential)
            let after = try LocalHealthClient.fetchControllerIdentity(socketPath: "", credential: credential)
            guard entry.context.matches(before), after.matchesAuthority(before), after.revision == before.revision,
                  contract.epoch == entry.context.epoch, contract.principal == entry.context.principal,
                  contract.revision == Int64(after.revision), contract.basisSHA == entry.basisSHA else { throw LocalHealthError.nativeGuardConflict }
            var limits: [String: Any] = contract.limits.authoring.mapValues { Int($0) as Any }; limits["reader"] = contract.limits.reader.mapValues(Int.init)
            let original = try NativeAuthoringOriginalWire.encode(["authority_epoch": after.authorityEpoch, "expected_revision": after.revision,
                "operation_id": operation, "request": ["mode": "manual", "contract_digest": contract.contractSHA,
                    "base_draft_ref": ["object_digest": digest, "first_revision": first], "source_refs": sources,
                    "fixture_refs": fixtures, "instruction": instruction, "limits": limits]], kind: .candidate)
            return NativePairedGeneratedAssessment(original: original, identity: after, contract: contract)
        }
    }
    private static func scoped<Value>(_ entry: NativeGenerationWorkspaceEntry, _ association: NativeControllerPublicAssociation,
                                      _ credential: Data, _ operation: () throws -> Value) throws -> Value {
        _ = try entry.checked()
        guard entry.custody.isPaired, entry.custody.matches(association: association, context: entry.context), entry.custody.matches(credential),
              let base = NativeDomainTransportScope.current else { throw NativePendingError.unavailable }
        let original = NativePendingEntry(context: entry.context, custody: entry.custody, input: .generation(entry.preparation), phase: .pending)
        let guarded = try NativePairedProfileTransport.guarding(base, association: association, credential: credential, entry: original)
        return try NativeDomainTransportScope.$current.withValue(guarded, operation: operation)
    }
}
