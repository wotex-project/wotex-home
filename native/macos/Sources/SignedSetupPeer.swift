import CoreFoundation
import Darwin
import Foundation
import Security

enum NativeSetupRole: String, Sendable {
    case app = "org.wotex.home"
    case agent = "org.wotex.home.agent"

    var peer: NativeSetupRole { self == .app ? .agent : .app }
}

enum NativeSetupPeerError: Error {
    case signingUnavailable
    case invalidSocket
    case wrongPeer
    case expired
}

enum NativeSetupSigningPolicy {
    static func requirement(_ role: NativeSetupRole, team: String) throws -> String {
        guard team.utf8.count == 10,
              team.utf8.allSatisfy({ (65...90).contains($0) || (48...57).contains($0) }) else {
            throw NativeSetupPeerError.signingUnavailable
        }
        return "anchor apple generic and identifier \"\(role.rawValue)\" and " +
            "certificate 1[field.1.2.840.113635.100.6.2.6] exists and " +
            "certificate leaf[field.1.2.840.113635.100.6.1.13] exists and " +
            "certificate leaf[subject.OU] = \"\(team)\""
    }

    static func permits(flags: UInt32, entitlements: [String: Any]) -> Bool {
        guard flags & SecCodeSignatureFlags.runtime.rawValue != 0 else { return false }
        let forbidden = [
            "com.apple.security.get-task-allow",
            "com.apple.security.cs.debugger",
            "com.apple.security.cs.disable-library-validation",
            "com.apple.security.cs.allow-unsigned-executable-memory",
            "com.apple.security.cs.allow-jit",
            "com.apple.security.cs.allow-dyld-environment-variables",
            "com.apple.security.cs.disable-executable-page-protection",
        ]
        return forbidden.allSatisfy { key in
            guard let value = entitlements[key] else { return true }
            guard let number = value as? NSNumber,
                  CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
            return !number.boolValue
        }
    }

    // Pure metadata screening is inert. Only the actual-self/peer gate below
    // can turn OS signing information into a Keychain access seal.
    static func keychainGroup(team: String, entitlements: [String: Any]) throws -> String {
        _ = try requirement(.agent, team: team)
        let group = team + ".org.wotex.home.agent"
        guard entitlements["com.apple.application-identifier"] as? String == group else {
            throw NativeSetupPeerError.signingUnavailable
        }
        if let value = entitlements["keychain-access-groups"] {
            guard let groups = value as? [String], groups == [group] else {
                throw NativeSetupPeerError.signingUnavailable
            }
        }
        return group
    }
}

struct NativeSetupPeerSeal: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    fileprivate let token: Data
    fileprivate let role: NativeSetupRole
    fileprivate let team: String
    fileprivate let uid: uid_t
    fileprivate let deadline: UInt64
    var description: String { "private_native_setup_peer" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
}

struct NativeKeychainAccessSeal: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    fileprivate let group: String
    fileprivate let peer: NativeSetupPeerSeal
    var description: String { "private_native_keychain_access" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
}

enum SignedSetupPeer {
    static func keychainAccess(_ socket: Int32, seal: NativeSetupPeerSeal) throws -> NativeKeychainAccessSeal {
        try current(socket, seal: seal, as: .agent)
        let group = try selfKeychainGroup(team: seal.team, deadline: seal.deadline)
        try current(socket, seal: seal, as: .agent)
        return NativeKeychainAccessSeal(group: group, peer: seal)
    }

    static func currentKeychain(_ socket: Int32, access: NativeKeychainAccessSeal) throws -> String {
        try current(socket, seal: access.peer, as: .agent)
        guard try selfKeychainGroup(team: access.peer.team, deadline: access.peer.deadline) == access.group else {
            throw NativeSetupPeerError.signingUnavailable
        }
        try current(socket, seal: access.peer, as: .agent)
        return access.group
    }

    static func connected(_ socket: Int32, as role: NativeSetupRole) throws -> NativeSetupPeerSeal {
        let (deadline, overflow) = DispatchTime.now().uptimeNanoseconds.addingReportingOverflow(5_000_000_000)
        guard !overflow else { throw NativeSetupPeerError.expired }
        let team = try selfTeam(role, deadline: deadline)
        let token = try auditToken(socket)
        try validateGuest(token, role: role.peer, team: team, deadline: deadline)
        guard try auditToken(socket) == token,
              try selfTeam(role, deadline: deadline) == team else { throw NativeSetupPeerError.wrongPeer }
        try fresh(deadline)
        return NativeSetupPeerSeal(token: token, role: role.peer, team: team, uid: geteuid(), deadline: deadline)
    }

    static func current(_ socket: Int32, seal: NativeSetupPeerSeal, as role: NativeSetupRole) throws {
        try fresh(seal.deadline)
        guard role.peer == seal.role, geteuid() == seal.uid,
              try selfTeam(role, deadline: seal.deadline) == seal.team,
              try auditToken(socket) == seal.token else { throw NativeSetupPeerError.wrongPeer }
        try validateGuest(seal.token, role: seal.role, team: seal.team, deadline: seal.deadline)
        guard try auditToken(socket) == seal.token,
              try selfTeam(role, deadline: seal.deadline) == seal.team else {
            throw NativeSetupPeerError.wrongPeer
        }
        try fresh(seal.deadline)
    }

    // The OS owns these bytes; no PID, pathname or signing fact enters this lookup.
    static func auditToken(_ socket: Int32) throws -> Data {
        guard getuid() != 0, getuid() == geteuid() else { throw NativeSetupPeerError.wrongPeer }
        var address = sockaddr_storage()
        var addressLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let addressStatus = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getpeername(socket, $0, &addressLength)
            }
        }
        guard addressStatus == 0, address.ss_family == sa_family_t(AF_UNIX) else {
            throw NativeSetupPeerError.invalidSocket
        }
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(socket, &uid, &gid) == 0, uid == geteuid() else {
            throw NativeSetupPeerError.wrongPeer
        }
        var type: Int32 = 0
        var typeLength = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(socket, SOL_SOCKET, SO_TYPE, &type, &typeLength) == 0,
              typeLength == MemoryLayout<Int32>.size, type == SOCK_STREAM else {
            throw NativeSetupPeerError.invalidSocket
        }
        var words = [UInt32](repeating: 0, count: 8)
        var length = socklen_t(32)
        let status = words.withUnsafeMutableBytes {
            getsockopt(socket, SOL_LOCAL, LOCAL_PEERTOKEN, $0.baseAddress, &length)
        }
        guard status == 0, length == 32 else { throw NativeSetupPeerError.invalidSocket }
        return words.withUnsafeBytes { Data($0) }
    }

    private static func selfTeam(_ role: NativeSetupRole, deadline: UInt64) throws -> String {
        try fresh(deadline)
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else {
            throw NativeSetupPeerError.signingUnavailable
        }
        try fresh(deadline)
        let info = try information(code, deadline: deadline)
        guard let team = info[kSecCodeInfoTeamIdentifier as String] as? String else {
            throw NativeSetupPeerError.signingUnavailable
        }
        try validate(code, role: role, team: team, info: info, deadline: deadline)
        return team
    }

    private static func selfKeychainGroup(team: String, deadline: UInt64) throws -> String {
        try fresh(deadline)
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else {
            throw NativeSetupPeerError.signingUnavailable
        }
        let info = try information(code, deadline: deadline)
        try validate(code, role: .agent, team: team, info: info, deadline: deadline)
        guard let entitlements = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any] else {
            throw NativeSetupPeerError.signingUnavailable
        }
        let group = try NativeSetupSigningPolicy.keychainGroup(team: team, entitlements: entitlements)
        try fresh(deadline)
        return group
    }

    private static func validateGuest(_ token: Data, role: NativeSetupRole, team: String, deadline: UInt64) throws {
        try fresh(deadline)
        var guest: SecCode?
        let attributes = [kSecGuestAttributeAudit as String: token] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &guest) == errSecSuccess,
              let guest else { throw NativeSetupPeerError.wrongPeer }
        try fresh(deadline)
        try validate(guest, role: role, team: team,
                     info: information(guest, deadline: deadline), deadline: deadline)
    }

    private static func information(_ code: SecCode, deadline: UInt64) throws -> [String: Any] {
        try fresh(deadline)
        guard SecCodeCheckValidity(code, [], nil) == errSecSuccess else {
            throw NativeSetupPeerError.signingUnavailable
        }
        try fresh(deadline)
        // SecCode.h explicitly accepts a dynamic Code in this API's StaticCode
        // slot. Preserve that object rather than selecting a filesystem path.
        let dynamicCode = unsafeBitCast(code, to: SecStaticCode.self)
        var value: CFDictionary?
        guard SecCodeCopySigningInformation(dynamicCode, SecCSFlags(rawValue: kSecCSSigningInformation), &value) == errSecSuccess,
              let value, let info = value as? [String: Any] else { throw NativeSetupPeerError.signingUnavailable }
        try fresh(deadline)
        return info
    }

    private static func validate(_ code: SecCode, role: NativeSetupRole, team: String,
                                 info: [String: Any], deadline: UInt64) throws {
        try fresh(deadline)
        guard info[kSecCodeInfoIdentifier as String] as? String == role.rawValue,
              info[kSecCodeInfoTeamIdentifier as String] as? String == team,
              let flags = info[kSecCodeInfoFlags as String] as? NSNumber,
              CFGetTypeID(flags) != CFBooleanGetTypeID(),
              ["c", "s", "i", "l", "q", "C", "S", "I", "L", "Q"].contains(String(cString: flags.objCType)),
              flags.int64Value >= 0, flags.uint64Value <= UInt64(UInt32.max) else {
            throw NativeSetupPeerError.wrongPeer
        }
        let entitlements: [String: Any]
        if let value = info[kSecCodeInfoEntitlementsDict as String] {
            guard let parsed = value as? [String: Any] else { throw NativeSetupPeerError.wrongPeer }
            entitlements = parsed
        } else {
            guard info[kSecCodeInfoEntitlements as String] == nil else {
                throw NativeSetupPeerError.wrongPeer
            }
            entitlements = [:]
        }
        guard NativeSetupSigningPolicy.permits(flags: flags.uint32Value, entitlements: entitlements) else {
            throw NativeSetupPeerError.wrongPeer
        }
        var requirement: SecRequirement?
        let text = try NativeSetupSigningPolicy.requirement(role, team: team)
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
              let requirement else { throw NativeSetupPeerError.signingUnavailable }
        try fresh(deadline)
        guard SecCodeCheckValidity(code, [], requirement) == errSecSuccess else {
            throw NativeSetupPeerError.wrongPeer
        }
        try fresh(deadline)
    }

    private static func fresh(_ deadline: UInt64) throws {
        guard DispatchTime.now().uptimeNanoseconds < deadline else { throw NativeSetupPeerError.expired }
    }
}
