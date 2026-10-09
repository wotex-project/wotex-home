import CoreFoundation
import Foundation
import LocalAuthentication
import Security

private enum PairedKeychainSmokeError: Error { case failed(Int) }

@main
struct NativePairedKeychainPolicySmoke {
    static func main() {
        do {
            guard CommandLine.arguments.count == 2,
                  let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as? [String: Any],
                  let rows = fixture["valid_records"] as? [[String: Any]], rows.count == 9 else { throw PairedKeychainSmokeError.failed(#line) }
            let group = "AB12CD34EF.org.wotex.home"
            let context = LAContext(); context.interactionNotAllowed = true
            defer { context.invalidate() }
            var accounts: Set<String> = []
            for row in rows {
                guard let body = row["body"] as? String, let expected = row["association_id"] as? String else { throw PairedKeychainSmokeError.failed(#line) }
                let association = try NativeControllerPublicAssociation.decode(Data(body.utf8))
                let query = try NativePairedKeychainPolicy.attributes(association: association, group: group, context: context)
                try require(Set(query.keys) == Set([
                    kSecClass, kSecUseDataProtectionKeychain, kSecAttrSynchronizable, kSecAttrAccessible,
                    kSecAttrAccessGroup, kSecAttrService, kSecAttrAccount, kSecUseAuthenticationContext,
                ].map { $0 as String }))
                try require(query[kSecClass as String] as? String == kSecClassGenericPassword as String)
                try require(query[kSecAttrAccessible as String] as? String == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
                try require(query[kSecAttrService as String] as? String == "org.wotex.home.paired-controller.v1")
                try require(query[kSecAttrAccount as String] as? String == expected)
                try require(query[kSecAttrAccessGroup as String] as? String == group)
                try boolean(query[kSecUseDataProtectionKeychain as String], true)
                try boolean(query[kSecAttrSynchronizable as String], false)
                try require((query[kSecUseAuthenticationContext as String] as? LAContext) === context)
                try require(context.interactionNotAllowed)
                accounts.insert(expected)
                try require(NativePairedKeychainPolicy.matches(Data(repeating: 8, count: 32), association: association))
                try require(!NativePairedKeychainPolicy.matches(Data(repeating: 9, count: 32), association: association))
                try require(!NativePairedKeychainPolicy.matches(Data(repeating: 8, count: 31), association: association))
                try require(!NativePairedKeychainPolicy.matches(Data(repeating: 8, count: 33), association: association))
                try signingPolicy(group: group)
            }
            try require(accounts.count == 8) // Label/endpoint metadata share the original binding account.
            guard let body = rows[0]["body"] as? String else { throw PairedKeychainSmokeError.failed(#line) }
            let association = try NativeControllerPublicAssociation.decode(Data(body.utf8))
            for wrong in ["AB12CD34EF.org.wotex.home.agent", "ab12cd34ef.org.wotex.home", "AB12CD34E.org.wotex.home", "AB12CD34EF.org.wotex.home.extra"] {
                try denied { _ = try NativePairedKeychainPolicy.attributes(association: association, group: wrong, context: context) }
            }
            let interactive = LAContext()
            defer { interactive.invalidate() }
            try denied { _ = try NativePairedKeychainPolicy.attributes(association: association, group: group, context: interactive) }
            let corrupt = NativeControllerPublicAssociation(id: association.id, label: association.label, peer: association.peer,
                scope: association.scope, original: association.original, access: association.access, verifier: String(repeating: "0", count: 64))
            do { _ = try NativePairedKeychainPolicy.attributes(association: corrupt, group: group, context: context); throw PairedKeychainSmokeError.failed(#line) }
            catch NativeControllerAssociationError.invalidRecord {}
            for (status, expected) in [
                (errSecInteractionNotAllowed, NativePairedKeychainError.locked), (errSecAuthFailed, .denied),
                (errSecUserCanceled, .denied), (errSecMissingEntitlement, .denied), (errSecDecode, .custodyConflict),
                (errSecNotAvailable, .unavailable), (errSecParam, .unavailable), (errSecSuccess, .unavailable),
                (errSecItemNotFound, .unavailable), (errSecDuplicateItem, .unavailable),
            ] { try require(NativePairedKeychainPolicy.failure(status) == expected) }

            // These are actual OS signing checks in the unsigned fixture. They
            // must refuse before any SecItem call; no successful seal is faked.
            do { _ = try SignedSetupPeer.pairedKeychainAccess(); throw PairedKeychainSmokeError.failed(#line) }
            catch NativeSetupPeerError.signingUnavailable {}
            let custodian = NativePairedKeychainCustodian()
            try denied { _ = try custodian.existing(association: association) }
            print("native paired Keychain inert policy and actual unsigned custody refusal passed")
        } catch PairedKeychainSmokeError.failed(let line) {
            FileHandle.standardError.write(Data("native paired Keychain policy assertion failed at source line \(line)\n".utf8))
            exit(1)
        } catch {
            FileHandle.standardError.write(Data("native paired Keychain policy fixture failed\n".utf8))
            exit(1)
        }
    }
    private static func signingPolicy(group: String) throws {
        for entitlements: [String: Any] in [
            ["com.apple.application-identifier": group],
            ["com.apple.application-identifier": group, "keychain-access-groups": [group]],
        ] {
            try require(try NativeSetupSigningPolicy.keychainGroup(team: "AB12CD34EF", entitlements: entitlements, role: .app) == group)
            do { _ = try NativeSetupSigningPolicy.keychainGroup(team: "AB12CD34EF", entitlements: entitlements); throw PairedKeychainSmokeError.failed(#line) }
            catch NativeSetupPeerError.signingUnavailable {}
        }
        for entitlements: [String: Any] in [
            ["com.apple.application-identifier": "AB12CD34EF.org.wotex.home.agent"],
            ["com.apple.application-identifier": group, "keychain-access-groups": [group, group + ".agent"]],
            ["com.apple.application-identifier": group, "keychain-access-groups": []],
            ["com.apple.application-identifier": group, "keychain-access-groups": group],
            ["com.apple.application-identifier": group, "keychain-access-groups": ["ZZ12CD34EF.org.wotex.home"]],
        ] {
            do { _ = try NativeSetupSigningPolicy.keychainGroup(team: "AB12CD34EF", entitlements: entitlements, role: .app); throw PairedKeychainSmokeError.failed(#line) }
            catch NativeSetupPeerError.signingUnavailable {}
        }
    }
    private static func boolean(_ value: Any?, _ expected: Bool) throws {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID(), number.boolValue == expected else { throw PairedKeychainSmokeError.failed(#line) }
    }
    private static func denied(_ work: () throws -> Void) throws {
        do { try work(); throw PairedKeychainSmokeError.failed(#line) }
        catch NativePairedKeychainError.denied {}
    }
    private static func require(_ value: Bool, line: Int = #line) throws { if !value { throw PairedKeychainSmokeError.failed(line) } }
}
