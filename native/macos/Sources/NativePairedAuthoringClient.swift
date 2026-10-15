import Foundation

// Metadata only. Public construction cannot create signed access or a session.
struct NativePairedAuthoringBasis: Sendable, Equatable, CustomReflectable {
    let association: NativeControllerPublicAssociation, scope: HomeControllerScope
    var context: NativePendingContext {
        let c = scope.identity
        return NativePendingContext(deployment: c.deploymentID, owner: c.ownerID, epoch: Int64(c.authorityEpoch), principal: c.principalID)
    }
    var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
    func check(_ current: HomeControllerScope, association: NativeControllerPublicAssociation, identity: HomeControllerIdentity) throws {
        guard association == self.association, current.identity.matchesAuthority(identity), current.identity.revision == identity.revision,
              current.permissions == scope.permissions, current.targetIDs == scope.targetIDs else { throw LocalHealthError.nativeGuardConflict }
        try NativePairedSessionCorrespondence.check(current, association: association)
        try NativePairedSessionCorrespondence.checkProfileScope(current, context: context)
    }
}
struct NativePairedAuthoringPreparation: Sendable, CustomReflectable {
    let original: HomeAuthoringOriginal, payload: Data?, identity: HomeControllerIdentity
    let paired: NativePairedAuthoringBasis, manualBasis: String?
    var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
}
struct NativePairedAuthoringContract: Sendable {
    let identity: HomeControllerIdentity, contract: HomeAuthoringContractRead
}

// Typed remote preparation only. Private file closures run after live scope.
// No signing backend, mutation, pending publisher or bearer is returned.
enum NativePairedAuthoringClient {
    static func scoped<Value>(_ basis: NativePairedAuthoringBasis, credential: Data, _ operation: () throws -> Value) throws -> Value {
        guard let transport = NativeDomainTransportScope.current, basis.association.verifier == LocalHealthClient.profileSHA(credential),
              credential.count == 32 else { throw NativePendingError.unavailable }
        try NativePairedSessionCorrespondence.check(basis.scope, association: basis.association)
        try NativePairedSessionCorrespondence.checkProfileScope(basis.scope, context: basis.context)
        let guarded = try NativePairedProfileTransport.guarding(transport, association: basis.association, credential: credential,
            context: basis.context, originalScope: basis.scope)
        do { return try NativeDomainTransportScope.$current.withValue(guarded, operation: operation) }
        catch {
            let ordinary: Bool
            if case LocalHealthError.invalidProfileRequest = error { ordinary = true }
            else { ordinary = error is NativeAuthoringFileError }
            if ordinary {
                let current = try NativeDomainTransportScope.$current.withValue(transport) {
                    try LocalHealthClient.fetchControllerScope(socketPath: "", credential: credential)
                }
                try basis.check(current, association: basis.association, identity: basis.scope.identity)
            }
            throw error
        }
    }
    static func contract(_ basis: NativePairedAuthoringBasis, credential: Data) throws -> NativePairedAuthoringContract {
        try scoped(basis, credential: credential) { try contractRead(basis, credential) }
    }
    private static func contractRead(_ basis: NativePairedAuthoringBasis, _ credential: Data,
                                     selections: NativeAuthoringSelections? = nil) throws -> NativePairedAuthoringContract {
        let before = try LocalHealthClient.fetchControllerIdentity(socketPath: "", credential: credential)
        let contract = try NativeAuthoringContractClient.fetch(socketPath: "", credential: credential)
        try selections?.verify(socket: "", credential: credential)
        let after = try LocalHealthClient.fetchControllerIdentity(socketPath: "", credential: credential)
        guard basis.context.matches(before), before.revision >= basis.scope.identity.revision, after.matchesAuthority(before), before.revision == after.revision,
              contract.principal == after.principalID, contract.epoch == after.authorityEpoch, contract.revision == after.revision else { throw LocalHealthError.nativeGuardConflict }
        return NativePairedAuthoringContract(identity: after, contract: contract)
    }
    private static func profileIdentity(_ basis: NativePairedAuthoringBasis, _ credential: Data) throws -> HomeControllerIdentity {
        let before = try LocalHealthClient.fetchControllerIdentity(socketPath: "", credential: credential)
        let profiles = try LocalHealthClient.fetchProfiles(socketPath: "", credential: credential)
        let after = try LocalHealthClient.fetchControllerIdentity(socketPath: "", credential: credential)
        guard basis.context.matches(before), before.revision >= basis.scope.identity.revision, after.matchesAuthority(before), profiles.authorityEpoch == after.authorityEpoch,
              before.revision == profiles.storeRevision, profiles.storeRevision == after.revision else { throw LocalHealthError.nativeGuardConflict }
        return after
    }
    static func data(_ basis: NativePairedAuthoringBasis, credential: Data, kind: HomeAuthoringObjectKind,
                     operation: String, payload: () throws -> Data) throws -> NativePairedAuthoringPreparation {
        try scoped(basis, credential: credential) {
            let bytes = try payload(), identity = try profileIdentity(basis, credential)
            return try imported(basis, identity: identity, contract: nil, operation: operation, kind: kind.rawValue, payload: bytes)
        }
    }
    static func draft(_ basis: NativePairedAuthoringBasis, credential: Data, operation: String, expectedBasis: String? = nil,
                      payload: () throws -> Data) throws -> NativePairedAuthoringPreparation {
        try scoped(basis, credential: credential) {
            let bytes = try payload(), read = try contractRead(basis, credential)
            guard expectedBasis == nil || expectedBasis == read.contract.basisSHA else { throw LocalHealthError.nativeGuardConflict }
            return try imported(basis, identity: read.identity, contract: read.contract.basisSHA, operation: operation, kind: "draft", payload: bytes)
        }
    }
    private static func imported(_ basis: NativePairedAuthoringBasis, identity: HomeControllerIdentity, contract: String?,
                                 operation: String, kind: String, payload: Data) throws -> NativePairedAuthoringPreparation {
        let summary = try NativeAuthoringReadClient.objectSummary(kind: kind, payload: payload)
        let original = try NativeAuthoringOriginalWire.encode(["authority_epoch": identity.authorityEpoch, "expected_revision": identity.revision,
            "operation_id": operation, "object": ["kind": summary.kind, "object_digest": summary.digest,
                "payload_sha256": summary.payloadSHA, "payload_bytes": summary.size]], kind: .import)
        _ = try NativePendingAuthoring.checked(original, payload: payload)
        return NativePairedAuthoringPreparation(original: original, payload: payload, identity: identity, paired: basis, manualBasis: contract)
    }
    static func assessment(_ basis: NativePairedAuthoringBasis, credential: Data, receipt: HomeAuthoringOriginalRead,
                           owner: HomeControllerIdentity, operation: String, instruction: String,
                           selections: () throws -> NativeAuthoringSelections) throws -> NativePairedAuthoringPreparation {
        try scoped(basis, credential: credential) {
            let selected = try selections(), read = try contractRead(basis, credential, selections: selected)
            guard read.identity.matchesAuthority(owner), receipt.kind == .import, receipt.epoch == read.identity.authorityEpoch,
                  let object = receipt.object, object.kind == "draft", let first = receipt.firstRevision else { throw LocalHealthError.nativeGuardConflict }
            try owned(credential, digest: object.digest, first: first, kind: "draft", summary: object)
            var limits: [String: Any] = read.contract.limits.authoring.mapValues { Int($0) as Any }; limits["reader"] = read.contract.limits.reader.mapValues(Int.init)
            let after = try LocalHealthClient.fetchControllerIdentity(socketPath: "", credential: credential)
            guard after.matchesAuthority(read.identity), after.revision == read.identity.revision else { throw LocalHealthError.nativeGuardConflict }
            let original = try NativeAuthoringOriginalWire.encode(["authority_epoch": after.authorityEpoch, "expected_revision": after.revision,
                "operation_id": operation, "request": ["mode": "manual", "contract_digest": read.contract.contractSHA,
                    "base_draft_ref": ["object_digest": object.digest, "first_revision": Int(first)], "source_refs": selected.sources.map(\.fields),
                    "fixture_refs": selected.fixtures.map(\.fields), "instruction": instruction, "limits": limits]], kind: .candidate)
            return NativePairedAuthoringPreparation(original: original, payload: nil, identity: after, paired: basis, manualBasis: read.contract.basisSHA)
        }
    }
    static func review(_ basis: NativePairedAuthoringBasis, credential: Data, epoch: Int64, candidateID: String,
                       operation: String, content: () throws -> [String: Any]) throws -> NativePairedAuthoringPreparation {
        try scoped(basis, credential: credential) {
            var review = try content(); try NativeAuthoringReviewContent.validateFields(review)
            let read = try contractRead(basis, credential)
            guard let candidate = try NativeAuthoringReadClient.fetchOriginal(socketPath: "", credential: credential,
                kind: .candidate, epoch: epoch, operation: candidateID), candidate.disposition == "compatible" else { throw LocalHealthError.server("candidate_unavailable") }
            guard candidate.epoch == read.identity.authorityEpoch, candidate.basisSHA == read.contract.basisSHA,
                  candidate.revision <= read.identity.revision, let input = candidate.inputSHA, let assessment = candidate.resultSHA else { throw LocalHealthError.nativeGuardConflict }
            review["candidate_ref"] = ["authority_epoch": Int(candidate.epoch), "operation_id": candidate.operation,
                "revision": Int(candidate.revision), "input_sha256": input, "assessment_sha256": assessment]
            let after = try LocalHealthClient.fetchControllerIdentity(socketPath: "", credential: credential)
            guard after.matchesAuthority(read.identity), after.revision == read.identity.revision else { throw LocalHealthError.nativeGuardConflict }
            let original = try NativeAuthoringOriginalWire.encode(["authority_epoch": after.authorityEpoch, "expected_revision": after.revision,
                "operation_id": operation, "review": review], kind: .review)
            return NativePairedAuthoringPreparation(original: original, payload: nil, identity: after, paired: basis, manualBasis: read.contract.basisSHA)
        }
    }
    static func original(_ basis: NativePairedAuthoringBasis, credential: Data, kind: HomeAuthoringOriginalKind,
                         original: () throws -> HomeAuthoringOriginal, payload: () throws -> Data?) throws -> NativePairedAuthoringPreparation {
        try scoped(basis, credential: credential) {
            let original = try original(), bytes = try payload()
            guard original.kind == kind else { throw LocalHealthError.invalidProfileRequest }
            _ = try NativePendingAuthoring.checked(original, payload: bytes)
            let identity = try profileIdentity(basis, credential)
            guard original.epoch == identity.authorityEpoch, original.expectedRevision == identity.revision else { throw LocalHealthError.nativeGuardConflict }
            let contract: String?
            if kind == .import { contract = nil }
            else {
                let read = try contractRead(basis, credential)
                guard read.identity.revision == identity.revision else { throw LocalHealthError.nativeGuardConflict }
                contract = read.contract.basisSHA
                if kind == .candidate {
                    let request = try original.fields()["request"] as! [String: Any]
                    guard request["contract_digest"] as? String == read.contract.contractSHA else { throw LocalHealthError.nativeGuardConflict }
                    let draft = request["base_draft_ref"] as! [String: Any]
                    try owned(credential, digest: draft["object_digest"] as! String, first: Int64(LocalHealthClient.profileInteger(draft["first_revision"])!), kind: "draft")
                    for (field, objectKind) in [("source_refs", "source"), ("fixture_refs", "fixture")] {
                        for ref in request[field] as! [[String: Any]] {
                            try owned(credential, digest: ref["object_digest"] as! String, first: Int64(LocalHealthClient.profileInteger(ref["first_revision"])!), kind: objectKind)
                        }
                    }
                } else {
                    let review = try original.fields()["review"] as! [String: Any], ref = review["candidate_ref"] as! [String: Any]
                    guard let candidate = try NativeAuthoringReadClient.fetchOriginal(socketPath: "", credential: credential, kind: .candidate,
                        epoch: original.epoch, operation: ref["operation_id"] as! String), candidate.disposition == "compatible",
                          candidate.revision == LocalHealthClient.profileInteger(ref["revision"]).map(Int64.init), candidate.inputSHA == ref["input_sha256"] as? String,
                          candidate.resultSHA == ref["assessment_sha256"] as? String, candidate.basisSHA == contract else { throw LocalHealthError.nativeGuardConflict }
                }
            }
            let after = try LocalHealthClient.fetchControllerIdentity(socketPath: "", credential: credential)
            guard after.matchesAuthority(identity), after.revision == identity.revision else { throw LocalHealthError.nativeGuardConflict }
            return NativePairedAuthoringPreparation(original: original, payload: bytes, identity: after, paired: basis, manualBasis: contract)
        }
    }
    static func validate(_ prepared: NativePairedAuthoringPreparation, fresh: NativePairedAuthoringBasis, credential: Data) throws {
        try prepared.paired.check(fresh.scope, association: fresh.association, identity: prepared.identity)
        try scoped(fresh, credential: credential) {
            _ = try NativePendingAuthoring.checked(prepared.original, payload: prepared.payload)
            let identity: HomeControllerIdentity
            if let expected = prepared.manualBasis {
                let read = try contractRead(fresh, credential)
                guard read.contract.basisSHA == expected else { throw LocalHealthError.nativeGuardConflict }; identity = read.identity
            } else { identity = try profileIdentity(fresh, credential) }
            guard identity.matchesAuthority(prepared.identity), identity.revision == prepared.identity.revision,
                  prepared.original.epoch == identity.authorityEpoch, prepared.original.expectedRevision == identity.revision else { throw LocalHealthError.nativeGuardConflict }
        }
    }
    private static func owned(_ credential: Data, digest: String, first: Int64, kind: String, summary: HomeAuthoringObjectSummary? = nil) throws {
        guard let object = try NativeAuthoringReadClient.fetchObject(socketPath: "", credential: credential, digest: digest),
              object.summary.kind == kind, object.firstRevision == first, summary == nil || summary == object.summary else { throw LocalHealthError.invalidResponse }
    }
}
