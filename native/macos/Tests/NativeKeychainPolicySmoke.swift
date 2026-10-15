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
        try mqtt()
        print("native Keychain inert query and error policy passed")
    }

    private static func mqtt() throws {
        let source = String(repeating: "a", count: 64)
        let account = try NativeMQTTKeychainPolicy.account(source: source)
        try check(account == "mqtt." + source)
        try check(try NativeMQTTKeychainPolicy.account(source: String(repeating: "b", count: 64)) != account)
        let context = LAContext(); context.interactionNotAllowed = true
        defer { context.invalidate() }
        let group = "AB12CD34EF.org.wotex.home.mqtt.v1"
        let query = NativeMQTTKeychainPolicy.attributes(account: account, group: group, context: context)
        try check(query[kSecAttrService as String] as? String == "org.wotex.home.mqtt.v1")
        try check(query[kSecAttrAccount as String] as? String == account)
        try check(query[kSecAttrAccessGroup as String] as? String == group)
        try check(query[kSecAttrAccessible as String] as? String == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        try boolean(query[kSecUseDataProtectionKeychain as String], equals: true)
        try boolean(query[kSecAttrSynchronizable as String], equals: false)
        for role in [NativeSetupRole.app, .agent] {
            let own = "AB12CD34EF." + role.rawValue
            let entitlements: [String: Any] = ["com.apple.application-identifier": own, "keychain-access-groups": [own, group]]
            try check(try NativeSetupSigningPolicy.mqttKeychainGroup(team: "AB12CD34EF", entitlements: entitlements, role: role) == group)
            for groups in [[own], [own, group, group], [own, group, "AB12CD34EF.shared"], [own, "ZZ12CD34EF.org.wotex.home.mqtt.v1"]] {
                do {
                    _ = try NativeSetupSigningPolicy.mqttKeychainGroup(team: "AB12CD34EF",
                        entitlements: ["com.apple.application-identifier": own, "keychain-access-groups": groups], role: role)
                    throw KeychainSmokeError.failed
                } catch NativeSetupPeerError.signingUnavailable {}
            }
        }
        let document = Data(#"{"format":"wotex-home.mqtt-credential@1","password_base64":"Zml4dHVyZS1wYXNzd29yZA==","username":"fixture-user"}"#.utf8)
        let credential = try NativeMQTTCredential(document: document)
        try check(try credential.document() == document)
        try check(!String(describing: credential).contains("fixture"))
        try check(!String(reflecting: credential).contains("fixture"))
        try check(Mirror(reflecting: credential).children.isEmpty)
        let vectors = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "test/fixtures/mqtt/native-bootstrap.json"))) as! [String: Any]
        try check(try NativeMQTTBootstrapWire.request(Data((vectors["none"] as! String).utf8)) == nil)
        try check(try NativeMQTTBootstrapWire.request(Data((vectors["request"] as! String).utf8)) == source)
        try check(try credential.bootstrapReply(source: source) == Data((vectors["reply"] as! String).utf8))
        let maximum = try JSONSerialization.data(withJSONObject: ["format": "wotex-home.mqtt-credential@1",
            "username": String(repeating: "å", count: 64), "password_base64": Data(repeating: 255, count: 4096).base64EncodedString()],
            options: [.sortedKeys, .withoutEscapingSlashes])
        let maximumReply = try NativeMQTTCredential(document: maximum).bootstrapReply(source: source)
        try check(maximumReply.count > 4096 && maximumReply.count <= 8192)
        for bad in [document + Data([10]), Data(#"{"format":"wotex-home.mqtt-credential@1","password_base64":"YQ","username":"u"}"#.utf8),
            Data(#"{"format":"wotex-home.mqtt-credential@1","password_base64":"cA==","username":"u","username":"v"}"#.utf8), Data(repeating: 91, count: 8193)] {
            do { _ = try NativeMQTTCredential(document: bad); throw KeychainSmokeError.failed }
            catch NativeSetupWireError.invalidRecord {}
        }
        // The actual unsigned executable must fail in the self-signing gate,
        // before either installed SecItem path. No successful seal is injected.
        let custodian = NativeMQTTKeychainCustodian()
        do { _ = try custodian.existing(source: source, deadline: deadline()); throw KeychainSmokeError.failed }
        catch is NativeSetupPeerError {}
        do { try custodian.importCredential(credential, source: source, deadline: deadline()); throw KeychainSmokeError.failed }
        catch is NativeSetupPeerError {}
    }

    private static func deadline() -> UInt64 { DispatchTime.now().uptimeNanoseconds + 5_000_000_000 }

    private static func check(_ value: Bool) throws { if !value { throw KeychainSmokeError.failed } }
    private static func boolean(_ value: Any?, equals expected: Bool) throws {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID(),
              number.boolValue == expected else { throw KeychainSmokeError.failed }
    }
}
