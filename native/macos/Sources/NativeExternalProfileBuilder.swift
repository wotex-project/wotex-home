import Foundation

// Pure advisory construction. Only the selected driver and Store can admit a decision.
enum NativeExternalProfileBuilder {
    static func inspection(context: HomeExternalProfileContext, operation: String, objects: NativeExternalProfileObjects) throws -> HomeExternalProfileOriginal {
        try build(context, operation: operation) { context, base in
            var content = try checkedObjects(objects, at: context.basis.revision)
            content["reader_basis_sha256"] = try reader(context)
            return try encode(base, ["inspection": content], .inspection)
        }
    }
    static func approve(context: HomeExternalProfileContext, operation: String, catalogue: HomeExternalProfileCatalogue,
                        inspection: HomeExternalProfileOriginalRead, artifact: HomeExternalInspectionArtifact) throws -> HomeExternalProfileOriginal {
        try build(context, operation: operation, maintenance: true) { context, base in
            let catalogue = try checkedCatalogue(catalogue, context), artifact = try checkedArtifact(artifact, context)
            guard inspection.kind == .inspection, case .inspection(let detail) = inspection.detail else { throw LocalHealthError.invalidProfileRequest }
            _ = try NativeExternalProfileClient.decodeOriginal(["api_version": 1, "outcome": "ok", "external_inspection_receipt": [
                "authority_epoch": inspection.epoch, "operation_id": inspection.operation, "revision": inspection.revision, "input_sha256": inspection.inputSHA,
                "reader_basis_sha256": detail.readerBasis, "result_sha256": detail.resultSHA, "capture_digest": detail.capture,
                "envelope_sha256": detail.envelope, "home_consumption": "matched"
            ]], kind: .inspection, epoch: inspection.epoch, operation: inspection.operation)
            let ref = HomeExternalInspectionReference(epoch: inspection.epoch, operation: inspection.operation, revision: inspection.revision,
                inputSHA: inspection.inputSHA, resultSHA: detail.resultSHA)
            guard ref == artifact.reference, inspection.revision <= context.basis.revision, detail.readerBasis == (try reader(context)) else { throw LocalHealthError.nativeGuardConflict }
            let item = try item(catalogue, digest: artifact.digest, required: false)
            if let item {
                guard item.state == "revoked", item.id == artifact.id, item.version == artifact.version else { throw LocalHealthError.nativeGuardConflict }
            }
            return try encode(base, ["action": "approve", "artifact_digest": artifact.digest, "expected_trust_revision": item?.trustRevision ?? 0,
                "expected_policy_generation": context.basis.policyGeneration, "inspection_ref": ref.fields(), "acknowledgement": "operator_digest_approval"], .trust)
        }
    }
    static func revokeTrust(context: HomeExternalProfileContext, operation: String, catalogue: HomeExternalProfileCatalogue, artifact: String) throws -> HomeExternalProfileOriginal {
        try build(context, operation: operation, maintenance: true) { context, base in
            guard LocalHealthClient.profileDigest(artifact) else { throw LocalHealthError.invalidProfileRequest }
            let catalogue = try checkedCatalogue(catalogue, context)
            guard let item = try item(catalogue, digest: artifact, required: true), item.state != "revoked" else { throw LocalHealthError.nativeGuardConflict }
            return try encode(base, ["action": "revoke", "artifact_digest": artifact, "expected_trust_revision": item.trustRevision,
                "expected_policy_generation": context.basis.policyGeneration, "inspection_ref": NSNull(), "acknowledgement": NSNull()], .trust)
        }
    }
    static func select(context: HomeExternalProfileContext, operation: String, catalogue: HomeExternalProfileCatalogue,
                       target: HomeExternalTargetBasis, sources: HomeExternalSourceCatalogue, source: String,
                       objects: NativeExternalProfileObjects, artifact: HomeExternalInspectionArtifact) throws -> HomeExternalProfileOriginal {
        try build(context, operation: operation, maintenance: true) { context, base in
            guard LocalHealthClient.profileID(source) else { throw LocalHealthError.invalidProfileRequest }
            let catalogue = try checkedCatalogue(catalogue, context), target = try checkedTarget(target, context)
            let sources = try checkedSources(sources, context), artifact = try checkedArtifact(artifact, context), basis = try reader(context)
            guard let item = try item(catalogue, digest: artifact.digest, required: true), item.state == "approved", item.readerBasis == basis,
                  item.id == artifact.id, item.version == artifact.version, let owner = sources.ownerEpoch,
                  let chosen = sources.sources.first(where: { $0.reference == source }), chosen.readerBasis == basis else { throw LocalHealthError.nativeGuardConflict }
            let fields = try checkedObjects(objects, at: context.basis.revision)
            try matchObjects(fields, artifact.objects)
            return try encode(base, ["action": "select", "target_id": target.target, "artifact_digest": artifact.digest,
                "expected_trust_revision": item.trustRevision, "expected_policy_generation": context.basis.policyGeneration,
                "expected_selection_revision": target.selectionRevision, "expected_resource_revision": target.resourceRevision,
                "source_ref": source, "source_owner_epoch": owner, "source_selection_sha256": chosen.selectionSHA,
                "objects": fields, "acknowledgement": "operator_external_selection"], .target)
        }
    }
    static func revokeTarget(context: HomeExternalProfileContext, operation: String, catalogue: HomeExternalProfileCatalogue, target: HomeExternalTargetBasis) throws -> HomeExternalProfileOriginal {
        try build(context, operation: operation, maintenance: true) { context, base in
            let catalogue = try checkedCatalogue(catalogue, context), target = try checkedTarget(target, context)
            guard target.state == "selected", let digest = target.artifact,
                  let item = try item(catalogue, digest: digest, required: true), item.trustRevision == target.trustRevision else { throw LocalHealthError.nativeGuardConflict }
            return try encode(base, ["action": "revoke", "target_id": target.target, "artifact_digest": digest,
                "expected_trust_revision": item.trustRevision, "expected_policy_generation": context.basis.policyGeneration,
                "expected_selection_revision": target.selectionRevision, "expected_resource_revision": target.resourceRevision,
                "source_ref": NSNull(), "source_owner_epoch": NSNull(), "source_selection_sha256": NSNull(), "objects": NSNull(), "acknowledgement": NSNull()], .target)
        }
    }
    private static func build(_ context: HomeExternalProfileContext, operation: String, maintenance: Bool = false,
                              body: (HomeExternalProfileContext, [String: Any]) throws -> HomeExternalProfileOriginal) throws -> HomeExternalProfileOriginal {
        do {
            guard LocalHealthClient.profileID(operation) else { throw LocalHealthError.invalidProfileRequest }
            let context = try NativeExternalGuidanceClient.decodeContext(wrap("external_profile_context", context.basis, [
                "maintenance": context.maintenance ? "maintenance" : "normal", "maintenance_revision": context.maintenanceRevision,
                "reader": ["state": context.readerBasis == nil ? "unavailable" : "available", "basis_sha256": optional(context.readerBasis), "reason": optional(context.readerReason)]
            ])).0
            guard !maintenance || context.maintenance else { throw LocalHealthError.nativeGuardConflict }
            return try body(context, ["authority_epoch": context.basis.epoch, "operation_id": operation, "expected_revision": context.basis.revision])
        } catch LocalHealthError.invalidResponse { throw LocalHealthError.invalidProfileRequest }
    }
    private static func encode(_ base: [String: Any], _ fields: [String: Any], _ kind: HomeExternalProfileOriginalKind) throws -> HomeExternalProfileOriginal {
        try NativeExternalProfileOriginalWire.encode(base.merging(fields) { _, new in new }, kind: kind)
    }
    private static func reader(_ context: HomeExternalProfileContext) throws -> String {
        guard let basis = context.readerBasis else { throw LocalHealthError.nativeGuardConflict }; return basis
    }
    private static func checkedObjects(_ objects: NativeExternalProfileObjects, at revision: Int64) throws -> [String: Any] {
        let fields = try objects.fields()
        let handles = [fields["envelope_ref"] as! [String: Any], (fields["profile"] as! [String: Any])["object_ref"] as! [String: Any]] +
            (fields["definitions"] as! [[String: Any]]).map { $0["object_ref"] as! [String: Any] }
        guard handles.allSatisfy({ Int64(LocalHealthClient.profileInteger($0["first_revision"])!) <= revision }) else { throw LocalHealthError.nativeGuardConflict }
        return fields
    }
    private static func same(_ left: HomeExternalGuidanceBasis, _ right: HomeExternalGuidanceBasis) throws {
        guard left.principal == right.principal, left.epoch == right.epoch, left.revision == right.revision,
              left.policyGeneration == right.policyGeneration else { throw LocalHealthError.nativeGuardConflict }
    }
    private static func checkedCatalogue(_ value: HomeExternalProfileCatalogue, _ context: HomeExternalProfileContext) throws -> HomeExternalProfileCatalogue {
        guard value.items.count <= 64 else { throw LocalHealthError.invalidProfileRequest }
        let checked = try NativeExternalProfileClient.decodeCatalogue(["api_version": 1, "outcome": "ok", "external_profile_catalogue": [
            "authority_epoch": value.epoch, "store_revision": value.revision, "policy_generation": value.policyGeneration,
            "items": value.items.map { ["artifact_digest": $0.artifact, "id": $0.id, "version": $0.version, "trust_author": $0.author,
                "state": $0.state, "reader_basis_sha256": optional($0.readerBasis), "trust_revision": $0.trustRevision, "trust_generation": $0.trustGeneration] }
        ]])
        guard checked.epoch == context.basis.epoch, checked.revision == context.basis.revision,
              checked.policyGeneration == context.basis.policyGeneration else { throw LocalHealthError.nativeGuardConflict }
        return checked
    }
    private static func item(_ catalogue: HomeExternalProfileCatalogue, digest: String, required: Bool) throws -> HomeExternalProfileItem? {
        let found = catalogue.items.filter { $0.artifact == digest }
        guard found.count <= 1, !required || found.count == 1 else { throw LocalHealthError.nativeGuardConflict }; return found.first
    }
    private static func checkedTarget(_ value: HomeExternalTargetBasis, _ context: HomeExternalProfileContext) throws -> HomeExternalTargetBasis {
        let checked = try NativeExternalGuidanceClient.decodeTarget(wrap("external_target_basis", value.basis, [
            "target_id": value.target, "state": value.state, "selection_revision": value.selectionRevision, "selection_generation": value.generation,
            "resource_revision": value.resourceRevision, "binding_revision": value.bindingRevision, "trust_revision": value.trustRevision, "artifact_digest": optional(value.artifact)
        ]), target: value.target).0
        try same(checked.basis, context.basis); return checked
    }
    private static func checkedSources(_ value: HomeExternalSourceCatalogue, _ context: HomeExternalProfileContext) throws -> HomeExternalSourceCatalogue {
        guard value.sources.count <= 32, (value.ownerEpoch?.utf8.count ?? 0) <= 32, (value.reason?.utf8.count ?? 0) <= 128,
              value.sources.allSatisfy({ [$0.reference, $0.selectionSHA, $0.readerBasis, $0.epoch, $0.method, $0.trust, $0.policySHA].allSatisfy { $0.utf8.count <= 128 } }) else { throw LocalHealthError.invalidProfileRequest }
        let checked = try NativeExternalGuidanceClient.decodeSources(wrap("external_source_catalogue", value.basis, [
            "state": value.ownerEpoch == nil ? "unavailable" : "available", "owner_epoch": optional(value.ownerEpoch), "reason": optional(value.reason),
            "sources": value.sources.map { ["source_ref": $0.reference, "source_selection_sha256": $0.selectionSHA, "reader_basis_sha256": $0.readerBasis,
                "source_epoch": $0.epoch, "source_generation": $0.generation, "method": $0.method, "trust": $0.trust, "policy_sha256": $0.policySHA] }
        ])).0
        try same(checked.basis, context.basis); return checked
    }
    private static func checkedArtifact(_ value: HomeExternalInspectionArtifact, _ context: HomeExternalProfileContext) throws -> HomeExternalInspectionArtifact {
        guard (2...34).contains(value.objects.count), value.canonical.count <= 32768, value.id.utf8.count <= 128, value.version.utf8.count <= 17,
              value.objects.allSatisfy({ $0.objectSHA.utf8.count <= 64 && $0.payloadSHA.utf8.count <= 64 && ($0.referenceID?.utf8.count ?? 0) <= 256 &&
                  ($0.referenceVersion?.utf8.count ?? 0) <= 17 && ($0.referenceSHA?.utf8.count ?? 0) <= 64 }) else { throw LocalHealthError.invalidProfileRequest }
        let rows: [[String: Any]] = try value.objects.map { row in
            let ref: Any
            if let id = row.referenceID {
                guard let version = row.referenceVersion, let sha = row.referenceSHA else { throw LocalHealthError.invalidProfileRequest }
                ref = ["id": id, "version": version, "sha256": sha]
            } else {
                guard row.referenceVersion == nil, row.referenceSHA == nil else { throw LocalHealthError.invalidProfileRequest }; ref = NSNull()
            }
            return ["kind": row.kind, "reference": ref, "object_digest": row.objectSHA, "payload_sha256": row.payloadSHA, "payload_bytes": row.payloadBytes]
        }
        guard let checked = try NativeExternalGuidanceClient.decodeArtifact(wrap("external_inspection_artifact", value.basis, [
            "inspection_ref": value.reference.fields(), "artifact_digest": value.digest,
            "artifact": ["format": "wotex-home.external-artifact@1", "id": value.id, "version": value.version, "objects": rows]
        ]), reference: value.reference).0, checked.canonical == value.canonical else { throw LocalHealthError.invalidProfileRequest }
        try same(checked.basis, context.basis); return checked
    }
    private static func matchObjects(_ fields: [String: Any], _ objects: [HomeExternalArtifactObject]) throws {
        let profile = fields["profile"] as! [String: Any], definitions = fields["definitions"] as! [[String: Any]]
        let handles = [fields["envelope_ref"] as! [String: Any], profile["object_ref"] as! [String: Any]] + definitions.map { $0["object_ref"] as! [String: Any] }
        let references: [Any] = [NSNull(), profile["reference"]!] + definitions.map { $0["reference"]! }
        guard handles.count == objects.count else { throw LocalHealthError.nativeGuardConflict }
        for (index, object) in objects.enumerated() {
            guard handles[index]["object_digest"] as? String == object.objectSHA else { throw LocalHealthError.nativeGuardConflict }
            if index > 0 {
                let ref = references[index] as! [String: Any]
                guard ref["id"] as? String == object.referenceID, ref["version"] as? String == object.referenceVersion,
                      ref["sha256"] as? String == object.referenceSHA else { throw LocalHealthError.nativeGuardConflict }
            }
        }
    }
    private static func optional(_ value: String?) -> Any { value.map { $0 as Any } ?? NSNull() }
    private static func wrap(_ operation: String, _ basis: HomeExternalGuidanceBasis, _ fields: [String: Any]) -> [String: Any] {
        ["api_version": 1, "outcome": "ok", operation: ["format": "wotex-home." + operation.replacingOccurrences(of: "_", with: "-") + "@1",
            "principal_id": basis.principal, "authority_epoch": basis.epoch, "store_revision": basis.revision, "policy_generation": basis.policyGeneration]
            .merging(fields) { _, new in new }]
    }
}
