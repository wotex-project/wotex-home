import Foundation

enum NativeControllerPairingCustodyError: Error { case expired }

struct NativeControllerPairingDelivery: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let association: NativeControllerPublicAssociation
    fileprivate let bearer: Data
    fileprivate let expires: ContinuousClock.Instant
    fileprivate let clock: NativeControllerCertificateClock
    var description: String { "private_controller_pairing_delivery" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }

    // The private initializer belongs to this file's actual TLS entry only.
    // This access is still custody, never a current remote grant or scope seal.
    func keychainCredential() throws -> Data {
        guard !Task.isCancelled, ContinuousClock.now < expires else { throw NativeControllerPairingCustodyError.expired }
        do { _ = try clock.bounds() }
        catch { throw NativeControllerPairingCustodyError.expired }
        return bearer
    }
}

enum NativeControllerPairingDeliveryResult: Sendable {
    case paired(NativeControllerPairingDelivery)
    case refused(NativeControllerPairingContext, String)
}

enum NativeControllerPairingCustody {
    static func bootstrap(_ invitation: NativeControllerInvitation, request: NativeControllerBootstrapRequest,
                          label: String, clock: NativeControllerCertificateClock,
                          approvedAccess: NativeControllerAccess = .initial,
                          diagnostics: NativeControllerTLSDiagnostics? = nil) async throws -> NativeControllerPairingDeliveryResult {
        guard NativeControllerPairingWire.label(label) else { throw NativeControllerTLSError.invalidRecord }
        let response = try await NativeControllerTLSClient.bootstrap(invitation, request: request, clock: clock,
            approvedAccess: approvedAccess, diagnostics: diagnostics)
        guard !Task.isCancelled else { throw NativeControllerTLSError.outcomeUnknown }
        switch response {
        case .refused(let context, let reason): return .refused(context, reason)
        case .paired(let delivered):
            do {
                _ = try clock.bounds()
                let association = try NativeControllerPublicAssociation.corresponding(peer: NativeControllerPeer(invitation: invitation),
                    label: label, delivered: delivered, request: request, approvedAccess: approvedAccess)
                return .paired(NativeControllerPairingDelivery(association: association, bearer: delivered.credential,
                    expires: ContinuousClock.now.advanced(by: .seconds(5)), clock: clock))
            } catch { throw NativeControllerTLSError.outcomeUnknown }
        }
    }
}
