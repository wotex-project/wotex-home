import CoreFoundation
import Foundation
import LocalAuthentication
import Security

private enum KeychainSmokeError: Error { case failed }

@main
struct NativeKeychainPolicySmoke {
    static func main() throws {
        let scope = NativeControllerScope(deployment: String(repeating: "a", count: 64),
                                          owner: String(repeating: "b", count: 64), epoch: 7, revision: 9)
        let group = "AB12CD34EF.org.wotex.home.agent"
        let context = LAContext()
        context.interactionNotAllowed = true
        defer { context.invalidate() }
        for role in NativeCustodyRole.allCases {
            let expected = String(repeating: "a", count: 64) + "." + String(repeating: "b", count: 64) + ".7." + role.rawValue
            let account = try NativeKeychainPolicy.account(scope, role: role)
            try check(account == expected)
            let query = NativeKeychainPolicy.attributes(account: account, group: group, context: context)
            try check(Set(query.keys) == Set([
                kSecClass, kSecUseDataProtectionKeychain, kSecAttrSynchronizable, kSecAttrAccessible,
                kSecAttrAccessGroup, kSecAttrService, kSecAttrAccount, kSecUseAuthenticationContext,
            ].map { $0 as String }))
            try check(query[kSecClass as String] as? String == kSecClassGenericPassword as String)
            try check(query[kSecAttrAccessible as String] as? String == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
            try check(query[kSecAttrService as String] as? String == "org.wotex.home.native-setup.v1")
            try check(query[kSecAttrAccount as String] as? String == expected)
            try check(query[kSecAttrAccessGroup as String] as? String == group)
            try boolean(query[kSecUseDataProtectionKeychain as String], equals: true)
            try boolean(query[kSecAttrSynchronizable as String], equals: false)
            try check((query[kSecUseAuthenticationContext as String] as? LAContext) === context)
            try check(context.interactionNotAllowed)
        }
        for (status, expected) in [
            (errSecInteractionNotAllowed, NativeKeychainError.locked),
            (errSecAuthFailed, .denied), (errSecUserCanceled, .denied), (errSecMissingEntitlement, .denied),
            (errSecDecode, .custodyConflict), (errSecNotAvailable, .unavailable), (errSecParam, .unavailable),
            (errSecSuccess, .unavailable), (errSecItemNotFound, .unavailable), (errSecDuplicateItem, .unavailable),
        ] {
            try check(NativeKeychainPolicy.failure(status) == expected)
        }
        let changed = NativeControllerScope(deployment: scope.deployment, owner: scope.owner, epoch: 8, revision: 9)
        try check(try NativeKeychainPolicy.account(changed, role: .operator) != NativeKeychainPolicy.account(scope, role: .operator))
        let invalid = NativeControllerScope(deployment: "bad", owner: scope.owner, epoch: 0, revision: 0)
        do { _ = try NativeKeychainPolicy.account(invalid, role: .operator); throw KeychainSmokeError.failed }
        catch NativeKeychainError.ownerChanged {}
        print("native Keychain inert query and error policy passed")
    }

    private static func check(_ value: Bool) throws { if !value { throw KeychainSmokeError.failed } }
    private static func boolean(_ value: Any?, equals expected: Bool) throws {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID(),
              number.boolValue == expected else { throw KeychainSmokeError.failed }
    }
}
