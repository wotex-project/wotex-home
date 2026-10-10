import Foundation
import LocalAuthentication
import Security

enum NativePairedKeychainError: Error { case capacity, expired, locked, denied, unavailable, custodyConflict, outcomeUnknown }

enum NativePairedKeychainPolicy {
    static func attributes(association: NativeControllerPublicAssociation, group: String, context: LAContext) throws -> [String: Any] {
        _ = try association.encoded()
        let suffix = ".org.wotex.home"
        guard group.hasSuffix(suffix), group.utf8.count == 10 + suffix.utf8.count,
              group.utf8.prefix(10).allSatisfy({ (65...90).contains($0) || (48...57).contains($0) }),
              context.interactionNotAllowed else { throw NativePairedKeychainError.denied }
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: false,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrAccessGroup as String: group,
            kSecAttrService as String: NativeControllerPublicAssociation.keychainService,
            kSecAttrAccount as String: association.keychainAccount,
            kSecUseAuthenticationContext as String: context,
        ]
    }
    static func failure(_ status: OSStatus) -> NativePairedKeychainError {
        switch status {
        case errSecInteractionNotAllowed: .locked
        case errSecAuthFailed, errSecUserCanceled, errSecMissingEntitlement: .denied
        case errSecDecode: .custodyConflict
        default: .unavailable
        }
    }
    static func matches(_ bytes: Data, association: NativeControllerPublicAssociation) -> Bool {
        bytes.count == 32 && NativeControllerAssociationsWire.hash(bytes) == association.verifier
    }
}

struct NativePairedKeychainCredential: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    fileprivate let bearer: Data
    fileprivate let associationID: String
    fileprivate let access: NativePairedKeychainAccessSeal
    var description: String { "private_paired_keychain_credential" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
    func credential(for association: NativeControllerPublicAssociation) throws -> Data {
        do { _ = try SignedSetupPeer.currentPairedKeychain(access) }
        catch NativeSetupPeerError.expired { throw NativePairedKeychainError.expired }
        catch { throw NativePairedKeychainError.denied }
        guard !Task.isCancelled else { throw NativePairedKeychainError.expired }
        do { _ = try association.encoded() }
        catch { throw NativePairedKeychainError.custodyConflict }
        guard association.id == associationID, NativePairedKeychainPolicy.matches(bearer, association: association) else {
            throw NativePairedKeychainError.custodyConflict
        }
        do { _ = try SignedSetupPeer.currentPairedKeychain(access) }
        catch NativeSetupPeerError.expired { throw NativePairedKeychainError.expired }
        catch { throw NativePairedKeychainError.denied }
        guard !Task.isCancelled else { throw NativePairedKeychainError.expired }
        return bearer
    }
}

// Real SecItem only, behind an actual signed/protected app seal. There is no
// injected backend, caller-supplied raw import, update/delete or local fallback.
final class NativePairedKeychainCustodian: @unchecked Sendable {
    private let lock = NSLock()

    func retaining(_ delivery: NativeControllerPairingDelivery) throws -> NativePairedKeychainCredential {
        guard lock.try() else { throw NativePairedKeychainError.capacity }
        defer { lock.unlock() }
        return try mapped {
            let proposed = try delivery.keychainCredential(), association = delivery.association
            let access = try SignedSetupPeer.pairedKeychainAccess()
            if let bytes = try read(association: association, access: access, delivery: delivery) {
                guard bytes == proposed else { throw NativePairedKeychainError.custodyConflict }
                return NativePairedKeychainCredential(bearer: bytes, associationID: association.id, access: access)
            }
            let group = try current(access, delivery: delivery)
            let context = LAContext(); context.interactionNotAllowed = true
            defer { context.invalidate() }
            var query = try NativePairedKeychainPolicy.attributes(association: association, group: group, context: context)
            query[kSecValueData as String] = proposed
            _ = try current(access, delivery: delivery)
            let status = SecItemAdd(query as CFDictionary, nil)
            do { _ = try current(access, delivery: delivery) }
            catch { throw NativePairedKeychainError.outcomeUnknown }
            guard status == errSecSuccess || status == errSecDuplicateItem else { throw NativePairedKeychainPolicy.failure(status) }
            do {
                guard let bytes = try read(association: association, access: access, delivery: delivery), bytes == proposed else {
                    throw NativePairedKeychainError.custodyConflict
                }
                return NativePairedKeychainCredential(bearer: bytes, associationID: association.id, access: access)
            } catch { throw NativePairedKeychainError.outcomeUnknown }
        }
    }

    func existing(association: NativeControllerPublicAssociation) throws -> NativePairedKeychainCredential {
        guard lock.try() else { throw NativePairedKeychainError.capacity }
        defer { lock.unlock() }
        return try mapped {
            _ = try association.encoded()
            return try existingCredential(association: association, access: SignedSetupPeer.pairedKeychainAccess())
        }
    }

    // Only an actual current-process seal can reach this overload. The session
    // factory retains this original access across file/SecItem boundaries; it
    // cannot renew the five-second lease by asking for another signing seal.
    func existing(association: NativeControllerPublicAssociation,
                  access: NativePairedKeychainAccessSeal) throws -> NativePairedKeychainCredential {
        guard lock.try() else { throw NativePairedKeychainError.capacity }
        defer { lock.unlock() }
        return try mapped {
            _ = try association.encoded()
            return try existingCredential(association: association, access: access)
        }
    }

    private func existingCredential(association: NativeControllerPublicAssociation,
                                    access: NativePairedKeychainAccessSeal) throws -> NativePairedKeychainCredential {
        guard let bytes = try read(association: association, access: access, delivery: nil) else {
            throw NativePairedKeychainError.custodyConflict
        }
        return NativePairedKeychainCredential(bearer: bytes, associationID: association.id, access: access)
    }

    private func read(association: NativeControllerPublicAssociation, access: NativePairedKeychainAccessSeal,
                      delivery: NativeControllerPairingDelivery?) throws -> Data? {
        let group = try current(access, delivery: delivery)
        let context = LAContext(); context.interactionNotAllowed = true
        defer { context.invalidate() }
        var query = try NativePairedKeychainPolicy.attributes(association: association, group: group, context: context)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        _ = try current(access, delivery: delivery)
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        _ = try current(access, delivery: delivery)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw NativePairedKeychainPolicy.failure(status) }
        guard let bytes = value as? Data, NativePairedKeychainPolicy.matches(bytes, association: association) else {
            throw NativePairedKeychainError.custodyConflict
        }
        return bytes
    }
    private func current(_ access: NativePairedKeychainAccessSeal, delivery: NativeControllerPairingDelivery?) throws -> String {
        guard !Task.isCancelled else { throw NativePairedKeychainError.expired }
        if let delivery { _ = try delivery.keychainCredential() }
        let group = try SignedSetupPeer.currentPairedKeychain(access)
        guard !Task.isCancelled else { throw NativePairedKeychainError.expired }
        if let delivery { _ = try delivery.keychainCredential() }
        return group
    }
    private func mapped<T>(_ work: () throws -> T) throws -> T {
        do { return try work() }
        catch NativeControllerPairingCustodyError.expired { throw NativePairedKeychainError.expired }
        catch NativeSetupPeerError.expired { throw NativePairedKeychainError.expired }
        catch is NativeSetupPeerError { throw NativePairedKeychainError.denied }
        catch is NativeControllerAssociationError { throw NativePairedKeychainError.custodyConflict }
    }
}
