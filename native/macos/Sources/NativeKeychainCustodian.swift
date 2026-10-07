import CryptoKit
import Foundation
import LocalAuthentication
import Security

enum NativeKeychainError: Error {
    case capacity, expired, locked, denied, unavailable, custodyConflict, ownerChanged
}

enum NativeKeychainPolicy {
    static let service = "org.wotex.home.native-setup.v1"

    static func account(_ scope: NativeControllerScope, role: NativeCustodyRole) throws -> String {
        guard NativeCoreWire.valid(scope) else { throw NativeKeychainError.ownerChanged }
        return "\(scope.deployment).\(scope.owner).\(scope.epoch).\(role.rawValue)"
    }

    // This dictionary is inert; it is not an access seal or a successful item.
    static func attributes(account: String, group: String, context: LAContext) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: false,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrAccessGroup as String: group,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseAuthenticationContext as String: context,
        ]
    }

    static func failure(_ status: OSStatus) -> NativeKeychainError {
        switch status {
        case errSecInteractionNotAllowed: .locked
        case errSecAuthFailed, errSecUserCanceled, errSecMissingEntitlement: .denied
        case errSecDecode: .custodyConflict
        default: .unavailable
        }
    }
}

struct NativeKeychainCredential: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    fileprivate let bytes: Data
    fileprivate let scope: NativeControllerScope
    fileprivate let role: NativeCustodyRole
    var description: String { "private_native_keychain_credential" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
    var verifier: Data { Data(SHA256.hash(data: bytes)) }

    // The broker must obtain currentScope from its original actual core. This
    // last boundary also rechecks the original signed peer and deadline.
    func delivery(receipt: NativeCreationReceipt, currentScope: NativeControllerScope,
                  socket: Int32, peer: NativeSetupPeerSeal, deadline: UInt64) throws -> NativeCredentialRecord {
        guard DispatchTime.now().uptimeNanoseconds < deadline else { throw NativeKeychainError.expired }
        guard currentScope.deployment == scope.deployment, currentScope.owner == scope.owner,
              currentScope.epoch == scope.epoch,
              receipt.deployment == scope.deployment, receipt.owner == scope.owner,
              receipt.epoch == scope.epoch, receipt.role == role,
              receipt.principal == NativeCoreWire.principal(scope.epoch, role),
              receipt.revision >= 1, currentScope.revision >= receipt.revision else { throw NativeKeychainError.ownerChanged }
        _ = try SignedSetupPeer.keychainAccess(socket, seal: peer)
        guard DispatchTime.now().uptimeNanoseconds < deadline else { throw NativeKeychainError.expired }
        return NativeCredentialRecord(receipt: receipt, bytes: bytes)
    }
}

// Only real SecItem results behind a real private signing seal construct a
// credential. There is no injected Keychain backend, update/delete, fallback,
// serialized seal or test-success path in this installed custodian.
final class NativeKeychainCustodian: @unchecked Sendable {
    private let lock = NSLock()

    func obtain(scope: NativeControllerScope, role: NativeCustodyRole, socket: Int32,
                peer: NativeSetupPeerSeal, deadline: UInt64) throws -> NativeKeychainCredential {
        guard lock.try() else { throw NativeKeychainError.capacity }
        defer { lock.unlock() }
        try fresh(deadline)
        let access = try SignedSetupPeer.keychainAccess(socket, seal: peer)
        let account = try NativeKeychainPolicy.account(scope, role: role)
        if let existing = try read(account: account, socket: socket, access: access, deadline: deadline) {
            return NativeKeychainCredential(bytes: existing, scope: scope, role: role)
        }

        var proposed = Data(count: 32)
        let randomStatus = proposed.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!)
        }
        guard randomStatus == errSecSuccess else { throw NativeKeychainError.unavailable }
        try fresh(deadline)
        let group = try SignedSetupPeer.currentKeychain(socket, access: access)
        try fresh(deadline)
        let context = LAContext()
        context.interactionNotAllowed = true
        defer { context.invalidate() }
        var query = NativeKeychainPolicy.attributes(account: account, group: group, context: context)
        query[kSecValueData as String] = proposed
        let added = SecItemAdd(query as CFDictionary, nil)
        try fresh(deadline)
        _ = try SignedSetupPeer.currentKeychain(socket, access: access)
        try fresh(deadline)
        guard added == errSecSuccess || added == errSecDuplicateItem else {
            throw NativeKeychainPolicy.failure(added)
        }
        guard let persisted = try read(account: account, socket: socket, access: access, deadline: deadline) else {
            throw NativeKeychainError.unavailable
        }
        if added == errSecSuccess && persisted != proposed { throw NativeKeychainError.custodyConflict }
        return NativeKeychainCredential(bytes: persisted, scope: scope, role: role)
    }

    private func read(account: String, socket: Int32, access: NativeKeychainAccessSeal,
                      deadline: UInt64) throws -> Data? {
        try fresh(deadline)
        let group = try SignedSetupPeer.currentKeychain(socket, access: access)
        try fresh(deadline)
        let context = LAContext()
        context.interactionNotAllowed = true
        defer { context.invalidate() }
        var query = NativeKeychainPolicy.attributes(account: account, group: group, context: context)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        try fresh(deadline)
        _ = try SignedSetupPeer.currentKeychain(socket, access: access)
        try fresh(deadline)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw NativeKeychainPolicy.failure(status) }
        guard let bytes = value as? Data, bytes.count == 32 else { throw NativeKeychainError.custodyConflict }
        return bytes
    }

    private func fresh(_ deadline: UInt64) throws {
        guard DispatchTime.now().uptimeNanoseconds < deadline else { throw NativeKeychainError.expired }
    }
}
