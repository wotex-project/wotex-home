import Foundation

enum NativeExternalGuidedAction: String, CaseIterable, Sendable {
    case inspection, approve, revokeTrust, select, revokeTarget
    var title: String {
        switch self {
        case .inspection: "Inspect profile"
        case .approve: "Approve exact artifact"
        case .revokeTrust: "Withdraw approval"
        case .select: "Select read-only target"
        case .revokeTarget: "Withdraw target"
        }
    }
    var needsObjects: Bool { self == .inspection || self == .select }
    var needsInspection: Bool { self == .approve || self == .select }
}
enum NativeExternalProfileDraft: Sendable, CustomReflectable {
    case inspection(operation: String, objects: NativeExternalProfileObjects)
    case approve(operation: String, epoch: Int64, inspection: String)
    case revokeTrust(operation: String, artifact: String)
    case select(operation: String, epoch: Int64, inspection: String, target: String, source: String, objects: NativeExternalProfileObjects)
    case revokeTarget(operation: String, target: String)
    var operation: String {
        switch self {
        case .inspection(let op, _), .approve(let op, _, _), .revokeTrust(let op, _), .select(let op, _, _, _, _, _), .revokeTarget(let op, _): op
        }
    }
    var kind: HomeExternalProfileOriginalKind {
        switch self { case .inspection: .inspection; case .approve, .revokeTrust: .trust; case .select, .revokeTarget: .target }
    }
    func validate() throws {
        guard LocalHealthClient.profileID(operation) else { throw LocalHealthError.invalidProfileRequest }
        switch self {
        case .inspection(_, let objects): _ = try objects.fields()
        case .approve(_, let epoch, let inspection):
            guard epoch > 0, LocalHealthClient.profileID(inspection) else { throw LocalHealthError.invalidProfileRequest }
        case .revokeTrust(_, let artifact):
            guard LocalHealthClient.profileDigest(artifact) else { throw LocalHealthError.invalidProfileRequest }
        case .select(_, let epoch, let inspection, let target, let source, let objects):
            guard epoch > 0, LocalHealthClient.profileID(inspection), LocalHealthClient.profileID(target), LocalHealthClient.profileID(source) else { throw LocalHealthError.invalidProfileRequest }
            _ = try objects.fields()
        case .revokeTarget(_, let target):
            guard LocalHealthClient.profileID(target) else { throw LocalHealthError.invalidProfileRequest }
        }
    }
    var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
}
enum NativeExternalGuidedError: Error, LocalizedError {
    case inspectionMissing
    var errorDescription: String? { "The selected inspection is not recorded for this actor. Inspect the owned profile first." }
}
struct NativeExternalGuidedPreparation: Sendable {
    let original: HomeExternalProfileOriginal, identity: HomeControllerIdentity
}

// One fresh comparison group; no nested read SDK brackets, publication or mutation.
enum NativeExternalGuidedWorkflow {
    static func prepare(_ draft: NativeExternalProfileDraft, socket: String, credential: Data,
                        validateIdentity: (HomeControllerIdentity) throws -> Void) throws -> NativeExternalGuidedPreparation {
        try draft.validate()
        guard credential.count == 32 else { throw LocalHealthError.invalidProfileRequest }
        let before = try NativeExternalProfileClient.identity(socketPath: socket, credential: credential)
        try validateIdentity(before)
        let context = try context(socket, credential)
        let catalogue = try NativeExternalProfileClient.decodeCatalogue(read(socket, credential, "external_profiles"))
        var inspection: HomeExternalProfileOriginalRead?, artifact: HomeExternalInspectionArtifact?, target: HomeExternalTargetBasis?, sources: HomeExternalSourceCatalogue?
        switch draft {
        case .approve(_, let epoch, let operation), .select(_, let epoch, let operation, _, _, _):
            guard let receipt = try NativeExternalProfileClient.decodeOriginal(read(socket, credential, "external_inspection_status", ["authority_epoch": epoch, "operation_id": operation]),
                kind: .inspection, epoch: epoch, operation: operation), case .inspection(let detail) = receipt.detail else { throw NativeExternalGuidedError.inspectionMissing }
            inspection = receipt
            let ref = HomeExternalInspectionReference(epoch: receipt.epoch, operation: receipt.operation, revision: receipt.revision, inputSHA: receipt.inputSHA, resultSHA: detail.resultSHA)
            guard let value = try NativeExternalGuidanceClient.decodeArtifact(read(socket, credential, "external_inspection_artifact", ["inspection_ref": ref.fields()]), reference: ref).0 else { throw NativeExternalGuidedError.inspectionMissing }
            artifact = value
        default: break
        }
        switch draft {
        case .select(_, _, _, let id, _, _), .revokeTarget(_, let id):
            target = try NativeExternalGuidanceClient.decodeTarget(read(socket, credential, "external_target_basis", ["target_id": id]), target: id).0
        default: break
        }
        if case .select = draft { sources = try NativeExternalGuidanceClient.decodeSources(read(socket, credential, "external_source_catalogue")).0 }
        let fresh = try self.context(socket, credential)
        guard same(context.basis, fresh.basis), context.maintenance == fresh.maintenance, context.maintenanceRevision == fresh.maintenanceRevision,
              catalogue.epoch == context.basis.epoch, catalogue.revision == context.basis.revision, catalogue.policyGeneration == context.basis.policyGeneration else { throw LocalHealthError.nativeGuardConflict }
        switch draft {
        case .inspection, .approve, .select:
            guard context.readerBasis != nil, fresh.readerBasis == context.readerBasis else { throw LocalHealthError.nativeGuardConflict }
        default: break
        }
        let original: HomeExternalProfileOriginal
        switch draft {
        case .inspection(let op, let objects): original = try NativeExternalProfileBuilder.inspection(context: fresh, operation: op, objects: objects)
        case .approve(let op, _, _): original = try NativeExternalProfileBuilder.approve(context: fresh, operation: op, catalogue: catalogue, inspection: inspection!, artifact: artifact!)
        case .revokeTrust(let op, let digest): original = try NativeExternalProfileBuilder.revokeTrust(context: fresh, operation: op, catalogue: catalogue, artifact: digest)
        case .select(let op, _, _, _, let source, let objects): original = try NativeExternalProfileBuilder.select(context: fresh, operation: op, catalogue: catalogue, target: target!, sources: sources!, source: source, objects: objects, artifact: artifact!)
        case .revokeTarget(let op, _): original = try NativeExternalProfileBuilder.revokeTarget(context: fresh, operation: op, catalogue: catalogue, target: target!)
        }
        let existing = try NativeExternalProfileClient.decodeOriginal(read(socket, credential, original.kind.operation,
            ["authority_epoch": original.epoch, "operation_id": original.operation]), kind: original.kind, epoch: original.epoch, operation: original.operation, expectedInputSHA: original.sha)
        let after = try NativeExternalProfileClient.identity(socketPath: socket, credential: credential)
        guard existing == nil, before.matchesAuthority(after), before.revision == after.revision, context.basis.principal == after.principalID,
              context.basis.epoch == Int64(after.authorityEpoch), context.basis.revision == Int64(after.revision) else { throw LocalHealthError.nativeGuardConflict }
        return NativeExternalGuidedPreparation(original: original, identity: after)
    }
    static func sourceChoices(socket: String, credential: Data, validateIdentity: (HomeControllerIdentity) throws -> Void) throws -> HomeExternalSourceCatalogue {
        guard credential.count == 32 else { throw LocalHealthError.invalidProfileRequest }
        let before = try NativeExternalProfileClient.identity(socketPath: socket, credential: credential)
        try validateIdentity(before)
        let sources = try NativeExternalGuidanceClient.decodeSources(read(socket, credential, "external_source_catalogue")).0
        let after = try NativeExternalProfileClient.identity(socketPath: socket, credential: credential)
        guard before.matchesAuthority(after), before.revision == after.revision, sources.basis.principal == after.principalID,
              sources.basis.epoch == Int64(after.authorityEpoch), sources.basis.revision == Int64(after.revision) else { throw LocalHealthError.nativeGuardConflict }
        return sources
    }
    private static func context(_ socket: String, _ credential: Data) throws -> HomeExternalProfileContext {
        try NativeExternalGuidanceClient.decodeContext(read(socket, credential, "external_profile_context")).0
    }
    private static func read(_ socket: String, _ credential: Data, _ operation: String, _ fields: [String: Any] = [:]) throws -> [String: Any] {
        try LocalHealthClient.externalProfileReadTransport(socketPath: socket, credential: credential, operation: operation, fields: fields)
    }
    private static func same(_ left: HomeExternalGuidanceBasis, _ right: HomeExternalGuidanceBasis) -> Bool {
        left.principal == right.principal && left.epoch == right.epoch && left.revision == right.revision && left.policyGeneration == right.policyGeneration
    }
}
