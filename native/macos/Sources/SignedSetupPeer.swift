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
    static func keychainGroup(team: String, entitlements: [String: Any], role: NativeSetupRole = .agent) throws -> String {
        _ = try requirement(role, team: team)
        let group = team + "." + role.rawValue
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

struct NativeInstalledReleaseSeal: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    fileprivate let outer: URL
    fileprivate let release: URL
    fileprivate let identity: Data
    var executable: URL { release }
    var description: String { "private_native_installed_release" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
}

struct NativePairedKeychainAccessSeal: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    fileprivate let outer: URL
    fileprivate let team: String, group: String
    fileprivate let executableIdentity: Data, bundleIdentity: Data
    fileprivate let deadline: UInt64
    var description: String { "private_paired_keychain_access" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
}

enum NativeProtectedInstallation {
    static func physicalPath(_ path: String) throws -> String {
        guard path.hasPrefix("/"), !path.utf8.contains(0), let resolved = realpath(path, nil) else {
            throw NativeSetupPeerError.signingUnavailable
        }
        defer { free(resolved) }
        guard let physical = String(validatingCString: resolved) else { throw NativeSetupPeerError.signingUnavailable }
        return physical
    }

    static func entry(_ path: String) throws {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_uid == 0,
              info.st_mode & 0o022 == 0,
              [mode_t(S_IFREG), mode_t(S_IFDIR)].contains(info.st_mode & mode_t(S_IFMT)),
              access(path, W_OK) != 0 else { throw NativeSetupPeerError.signingUnavailable }
        errno = 0
        guard let acl = acl_get_link_np(path, ACL_TYPE_EXTENDED) else {
            // Darwin also reports ENOENT for an existing object with no ACL.
            // Distinguish that from a missing/changed path with its OS identity.
            var repeated = stat()
            guard errno == ENOENT, lstat(path, &repeated) == 0,
                  repeated.st_dev == info.st_dev, repeated.st_ino == info.st_ino,
                  repeated.st_uid == info.st_uid, repeated.st_mode == info.st_mode,
                  access(path, W_OK) != 0 else { throw NativeSetupPeerError.signingUnavailable }
            return
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        guard acl_valid(acl) == 0 else { throw NativeSetupPeerError.signingUnavailable }
        for index in 0..<170 {
            var entry: acl_entry_t?
            errno = 0
            if acl_get_entry(acl, Int32(index), &entry) != 0 {
                guard errno == EINVAL else { throw NativeSetupPeerError.signingUnavailable }
                return
            }
            guard let entry else { throw NativeSetupPeerError.signingUnavailable }
            var tag = ACL_UNDEFINED_TAG
            guard acl_get_tag_type(entry, &tag) == 0 else { throw NativeSetupPeerError.signingUnavailable }
            if tag == ACL_EXTENDED_DENY { continue }
            guard tag == ACL_EXTENDED_ALLOW else { throw NativeSetupPeerError.signingUnavailable }
            var permissions: acl_permset_t?
            guard acl_get_permset(entry, &permissions) == 0, let permissions else {
                throw NativeSetupPeerError.signingUnavailable
            }
            for permission in [ACL_WRITE_DATA, ACL_APPEND_DATA, ACL_DELETE, ACL_DELETE_CHILD,
                               ACL_WRITE_ATTRIBUTES, ACL_WRITE_EXTATTRIBUTES, ACL_WRITE_SECURITY, ACL_CHANGE_OWNER] {
                guard acl_get_perm_np(permissions, permission) == 0 else {
                    throw NativeSetupPeerError.signingUnavailable
                }
            }
        }
        throw NativeSetupPeerError.signingUnavailable
    }

    static func bundle(_ outer: URL, deadline: UInt64) throws {
        guard getuid() != 0, getuid() == geteuid(),
              outer.path == (try physicalPath(outer.path)) else {
            throw NativeSetupPeerError.signingUnavailable
        }
        var ancestor = outer
        while true {
            try entry(ancestor.path)
            if ancestor.path == "/" { break }
            ancestor.deleteLastPathComponent()
        }
        var failed = false
        guard let entries = FileManager.default.enumerator(at: outer, includingPropertiesForKeys: nil,
            errorHandler: { _, _ in failed = true; return false }) else {
            throw NativeSetupPeerError.signingUnavailable
        }
        var count = 0
        for case let entryURL as URL in entries {
            count += 1
            guard count <= 16_384, !failed, DispatchTime.now().uptimeNanoseconds < deadline,
                  entryURL.path.hasPrefix(outer.path + "/") else { throw NativeSetupPeerError.signingUnavailable }
            try entry(entryURL.path)
        }
        guard !failed, DispatchTime.now().uptimeNanoseconds < deadline else { throw NativeSetupPeerError.expired }
    }
}

enum SignedSetupPeer {
    // Actual installed app custody, independent of the local agent/socket seal.
    // No caller-supplied signer facts, group, path or lease enter this gate.
    static func pairedKeychainAccess() throws -> NativePairedKeychainAccessSeal {
        let (deadline, overflow) = DispatchTime.now().uptimeNanoseconds.addingReportingOverflow(5_000_000_000)
        guard !overflow else { throw NativeSetupPeerError.expired }
        let facts = try pairedKeychainFacts(deadline: deadline)
        return NativePairedKeychainAccessSeal(outer: facts.outer, team: facts.team, group: facts.group,
            executableIdentity: facts.executableIdentity, bundleIdentity: facts.bundleIdentity, deadline: deadline)
    }

    static func currentPairedKeychain(_ seal: NativePairedKeychainAccessSeal) throws -> String {
        let facts = try pairedKeychainFacts(deadline: seal.deadline)
        guard facts.outer == seal.outer, facts.team == seal.team, facts.group == seal.group,
              facts.executableIdentity == seal.executableIdentity, facts.bundleIdentity == seal.bundleIdentity else {
            throw NativeSetupPeerError.signingUnavailable
        }
        return facts.group
    }

    private static func pairedKeychainFacts(deadline: UInt64) throws ->
        (outer: URL, team: String, group: String, executableIdentity: Data, bundleIdentity: Data) {
        try fresh(deadline)
        guard getuid() != 0, getuid() == geteuid() else { throw NativeSetupPeerError.signingUnavailable }
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { throw NativeSetupPeerError.signingUnavailable }
        let info = try information(code, deadline: deadline)
        guard let team = info[kSecCodeInfoTeamIdentifier as String] as? String,
              let main = info[kSecCodeInfoMainExecutable as String] as? URL,
              let executableIdentity = info[kSecCodeInfoUnique as String] as? Data,
              !executableIdentity.isEmpty, executableIdentity.count <= 64,
              let entitlements = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any] else {
            throw NativeSetupPeerError.signingUnavailable
        }
        try validate(code, role: .app, team: team, info: info, deadline: deadline)
        let contents = main.deletingLastPathComponent().deletingLastPathComponent()
        let outer = contents.deletingLastPathComponent()
        guard contents.lastPathComponent == "Contents", outer.path.hasSuffix(".app"),
              main.path == contents.appendingPathComponent("MacOS/WotexHome").path else {
            throw NativeSetupPeerError.signingUnavailable
        }
        try NativeProtectedInstallation.bundle(outer, deadline: deadline)
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(outer as CFURL, [], &staticCode) == errSecSuccess, let staticCode else {
            throw NativeSetupPeerError.signingUnavailable
        }
        var requirement: SecRequirement?
        let text = try NativeSetupSigningPolicy.requirement(.app, team: team)
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else {
            throw NativeSetupPeerError.signingUnavailable
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        guard SecStaticCodeCheckValidity(staticCode, flags, requirement) == errSecSuccess else {
            throw NativeSetupPeerError.signingUnavailable
        }
        try fresh(deadline)
        var staticValue: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &staticValue) == errSecSuccess,
              let staticValue, let staticInfo = staticValue as? [String: Any],
              let bundleIdentity = staticInfo[kSecCodeInfoUnique as String] as? Data,
              !bundleIdentity.isEmpty, bundleIdentity.count <= 64 else { throw NativeSetupPeerError.signingUnavailable }
        try metadata(staticInfo, role: .app, team: team)
        let group = try NativeSetupSigningPolicy.keychainGroup(team: team, entitlements: entitlements, role: .app)
        try fresh(deadline)
        return (outer, team, group, executableIdentity, bundleIdentity)
    }

    static func developmentRelease() throws -> URL {
        let (deadline, overflow) = DispatchTime.now().uptimeNanoseconds.addingReportingOverflow(5_000_000_000)
        guard !overflow else { throw NativeSetupPeerError.expired }
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { throw NativeSetupPeerError.signingUnavailable }
        let info = try information(code, deadline: deadline)
        guard info[kSecCodeInfoTeamIdentifier as String] == nil,
              let flags = info[kSecCodeInfoFlags as String] as? NSNumber,
              CFGetTypeID(flags) != CFBooleanGetTypeID(),
              ["c", "s", "i", "l", "q", "C", "S", "I", "L", "Q"].contains(String(cString: flags.objCType)),
              flags.int64Value >= 0, flags.uint64Value <= UInt64(UInt32.max),
              flags.uint32Value & SecCodeSignatureFlags.adhoc.rawValue != 0,
              flags.uint32Value & ~(SecCodeSignatureFlags.adhoc.rawValue | SecCodeSignatureFlags.linkerSigned.rawValue) == 0,
              let main = info[kSecCodeInfoMainExecutable as String] as? URL else {
            throw NativeSetupPeerError.signingUnavailable
        }
        let contents = try helperContents(main)
        let release = contents.appendingPathComponent("Resources/WotexHomeRelease/bin/wotex_home")
        var infoFile = stat()
        guard lstat(release.path, &infoFile) == 0, infoFile.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              access(release.path, X_OK) == 0 else { throw NativeSetupPeerError.signingUnavailable }
        try fresh(deadline)
        return release
    }

    static func installedRelease() throws -> NativeInstalledReleaseSeal {
        let (deadline, overflow) = DispatchTime.now().uptimeNanoseconds.addingReportingOverflow(5_000_000_000)
        guard !overflow else { throw NativeSetupPeerError.expired }
        let team = try selfTeam(.agent, deadline: deadline)
        _ = try selfKeychainGroup(team: team, deadline: deadline)
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { throw NativeSetupPeerError.signingUnavailable }
        let info = try information(code, deadline: deadline)
        try validate(code, role: .agent, team: team, info: info, deadline: deadline)
        guard let main = info[kSecCodeInfoMainExecutable as String] as? URL else {
            throw NativeSetupPeerError.signingUnavailable
        }
        let contents = try helperContents(main)
        let outer = contents.deletingLastPathComponent()
        try NativeProtectedInstallation.bundle(outer, deadline: deadline)
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(outer as CFURL, [], &staticCode) == errSecSuccess, let staticCode else {
            throw NativeSetupPeerError.signingUnavailable
        }
        var requirement: SecRequirement?
        let requirementText = try NativeSetupSigningPolicy.requirement(.app, team: team)
        guard SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess,
              let requirement else { throw NativeSetupPeerError.signingUnavailable }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        guard SecStaticCodeCheckValidity(staticCode, flags, requirement) == errSecSuccess else {
            throw NativeSetupPeerError.signingUnavailable
        }
        try fresh(deadline)
        var staticValue: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &staticValue) == errSecSuccess,
              let staticValue, let staticInfo = staticValue as? [String: Any],
              let identity = staticInfo[kSecCodeInfoUnique as String] as? Data,
              !identity.isEmpty, identity.count <= 64 else { throw NativeSetupPeerError.signingUnavailable }
        try metadata(staticInfo, role: .app, team: team)
        let release = contents.appendingPathComponent("Resources/WotexHomeRelease/bin/wotex_home")
        var releaseInfo = stat()
        guard lstat(release.path, &releaseInfo) == 0,
              releaseInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              access(release.path, X_OK) == 0 else { throw NativeSetupPeerError.signingUnavailable }
        guard try selfTeam(.agent, deadline: deadline) == team else { throw NativeSetupPeerError.wrongPeer }
        try fresh(deadline)
        return NativeInstalledReleaseSeal(outer: outer, release: release, identity: identity)
    }

    static func currentInstalledRelease(_ seal: NativeInstalledReleaseSeal) throws {
        let current = try installedRelease()
        guard current.outer == seal.outer, current.release == seal.release, current.identity == seal.identity else {
            throw NativeSetupPeerError.signingUnavailable
        }
    }

    private static func helperContents(_ main: URL) throws -> URL {
        var contents = main
        for _ in 0..<6 { contents.deleteLastPathComponent() }
        let expected = contents.appendingPathComponent("Library/LoginItems/WotexHomeAgent.app/Contents/MacOS/WotexHomeAgent")
        guard contents.lastPathComponent == "Contents", contents.deletingLastPathComponent().path.hasSuffix(".app"),
              main.path == expected.path else { throw NativeSetupPeerError.signingUnavailable }
        return contents
    }

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
        try metadata(info, role: role, team: team)
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

    private static func metadata(_ info: [String: Any], role: NativeSetupRole, team: String) throws {
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
    }

    private static func fresh(_ deadline: UInt64) throws {
        guard DispatchTime.now().uptimeNanoseconds < deadline else { throw NativeSetupPeerError.expired }
    }
}
