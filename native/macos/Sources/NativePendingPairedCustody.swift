import Foundation

// Public reference matching only. The actual remote consumer must obtain
// fresh existing Keychain/TLS/Authority custody before capturing or recovering.
extension NativePendingCustody {
    static func paired(from association: NativeControllerPublicAssociation) throws -> Self {
        do { _ = try association.encoded() } catch { throw NativePendingError.invalidRecord }
        return .paired(association: association.id, controller: association.peer.controller,
            creationRevision: association.scope.creationRevision, verifier: association.verifier)
    }
    func matches(association: NativeControllerPublicAssociation, context: NativePendingContext) -> Bool {
        guard valid(context: context), (try? association.encoded()) != nil,
              case .paired(let id, let controller, let creation, let verifier) = self else { return false }
        return id == association.id && controller == association.peer.controller && creation == association.scope.creationRevision &&
            verifier == association.verifier && context.deployment == association.scope.deployment && context.owner == association.scope.owner &&
            context.epoch == association.scope.epoch && context.principal == association.scope.principal
    }
}
