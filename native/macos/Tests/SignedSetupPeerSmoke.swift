import CoreFoundation
import Darwin
import Foundation
import Security

private enum SmokeError: Error { case failed }

@main
struct SignedSetupPeerSmoke {
    static func main() throws {
        try policyVectors()
        try socketVectors()
        try installationVectors()
        print("signed setup peer policy and unsigned socket refusal passed")
    }

    private static func check(_ condition: Bool) throws {
        guard condition else { throw SmokeError.failed }
    }

    private static func refused<T>(_ operation: () throws -> T) throws {
        do {
            _ = try operation()
        } catch is NativeSetupPeerError {
            return
        }
        throw SmokeError.failed
    }

    private static func policyVectors() throws {
        let team = "AB12CD34EF"
        for (role, identifier) in [(NativeSetupRole.app, "org.wotex.home"), (.agent, "org.wotex.home.agent")] {
            let expected = "anchor apple generic and identifier \"\(identifier)\" and " +
                "certificate 1[field.1.2.840.113635.100.6.2.6] exists and " +
                "certificate leaf[field.1.2.840.113635.100.6.1.13] exists and " +
                "certificate leaf[subject.OU] = \"AB12CD34EF\""
            let value = try NativeSetupSigningPolicy.requirement(role, team: team)
            try check(value == expected)
            var requirement: SecRequirement?
            try check(SecRequirementCreateWithString(value as CFString, [], &requirement) == errSecSuccess)
            try check(requirement != nil)
        }
        for invalid in ["", "AB12CD34E", "AB12CD34EFG", "ab12cd34ef", "AB12CD34E\"", "AB12CD34ÉF", "AB12CD34E\n"] {
            try refused { try NativeSetupSigningPolicy.requirement(.app, team: invalid) }
        }
        try check(!NativeSetupSigningPolicy.permits(flags: 0, entitlements: [:]))
        try check(!NativeSetupSigningPolicy.permits(flags: 0x2, entitlements: [:]))
        try check(NativeSetupSigningPolicy.permits(flags: 0x10000, entitlements: [:]))
        let forbidden = [
            "com.apple.security.get-task-allow",
            "com.apple.security.cs.debugger",
            "com.apple.security.cs.disable-library-validation",
            "com.apple.security.cs.allow-unsigned-executable-memory",
            "com.apple.security.cs.allow-jit",
            "com.apple.security.cs.allow-dyld-environment-variables",
            "com.apple.security.cs.disable-executable-page-protection",
        ]
        for key in forbidden {
            try check(NativeSetupSigningPolicy.permits(flags: 0x10000, entitlements: [key: false]))
            for malformed: Any in [true, 0, 1, 0.0, "false", NSNull(), [false]] {
                try check(!NativeSetupSigningPolicy.permits(flags: 0x10000, entitlements: [key: malformed]))
            }
        }
        try check(NativeSetupSigningPolicy.permits(flags: 0x10000, entitlements: [
            "com.apple.security.network.client": true,
            "keychain-access-groups": ["AB12CD34EF.unrelated"],
        ]))
        let ownGroup = "AB12CD34EF.org.wotex.home.agent"
        try check(try NativeSetupSigningPolicy.keychainGroup(team: team, entitlements: [
            "com.apple.application-identifier": ownGroup,
        ]) == ownGroup)
        try check(try NativeSetupSigningPolicy.keychainGroup(team: team, entitlements: [
            "com.apple.application-identifier": ownGroup, "keychain-access-groups": [ownGroup],
        ]) == ownGroup)
        for value: Any in [[], [ownGroup, ownGroup], [ownGroup, "AB12CD34EF.shared"],
                           ["AB12CD34EF.shared"], ownGroup, [1], NSNull()] {
            try refused {
                try NativeSetupSigningPolicy.keychainGroup(team: team, entitlements: [
                    "com.apple.application-identifier": ownGroup, "keychain-access-groups": value,
                ])
            }
        }
        for value: Any in ["AB12CD34EF.org.wotex.home", "AB12CD34EF.shared", "", 1, NSNull()] {
            try refused { try NativeSetupSigningPolicy.keychainGroup(team: team, entitlements: ["com.apple.application-identifier": value]) }
        }
        try refused { try NativeSetupSigningPolicy.keychainGroup(team: team, entitlements: [:]) }
    }

    private static func socketVectors() throws {
        try refused { try SignedSetupPeer.auditToken(-1) }
        let internet = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        try check(internet >= 0)
        defer { Darwin.close(internet) }
        try refused { try SignedSetupPeer.auditToken(internet) }
        let datagram = Darwin.socket(AF_UNIX, SOCK_DGRAM, 0)
        try check(datagram >= 0)
        defer { Darwin.close(datagram) }
        try refused { try SignedSetupPeer.auditToken(datagram) }

        var template = Array("/private/tmp/woh-peer.XXXXXX".utf8CString)
        let directory = template.withUnsafeMutableBufferPointer { buffer -> String? in
            guard let path = mkdtemp(buffer.baseAddress) else { return nil }
            return String(cString: path)
        }
        guard let directory else { throw SmokeError.failed }
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let path = directory + "/peer.sock"
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8CString)
        try check(bytes.count <= MemoryLayout.size(ofValue: address.sun_path))
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.copyBytes(from: bytes.map { UInt8(bitPattern: $0) })
        }
        let listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        let client = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        try check(listener >= 0 && client >= 0)
        defer { Darwin.close(client); Darwin.close(listener) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        try check(bound == 0 && Darwin.listen(listener, 1) == 0 && chmod(path, 0o600) == 0)
        try refused { try SignedSetupPeer.auditToken(listener) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(client, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        try check(connected == 0)
        let server = Darwin.accept(listener, nil, nil)
        try check(server >= 0)
        defer { Darwin.close(server) }
        let token = try SignedSetupPeer.auditToken(client)
        try check(token.count == 32 && token.contains { $0 != 0 })
        try check(try SignedSetupPeer.auditToken(client) == token)
        try check(try SignedSetupPeer.auditToken(server) == token)
        for role in [NativeSetupRole.app, .agent] {
            try refused { try SignedSetupPeer.connected(client, as: role) }
            try refused { try SignedSetupPeer.connected(server, as: role) }
        }
        var byte: UInt8 = 0
        try check(Darwin.recv(server, &byte, 1, MSG_DONTWAIT) == -1 && errno == EAGAIN)
        try check(Darwin.recv(client, &byte, 1, MSG_DONTWAIT) == -1 && errno == EAGAIN)
    }

    private static func installationVectors() throws {
        try refused { try SignedSetupPeer.installedRelease() }
        try NativeProtectedInstallation.entry("/usr/bin/true")
        try check(try NativeProtectedInstallation.physicalPath("/tmp") == "/private/tmp")
        try refused { try NativeProtectedInstallation.entry("/private/tmp") }
        var template = Array("/private/tmp/woh-install.XXXXXX".utf8CString)
        let directory = template.withUnsafeMutableBufferPointer { buffer -> String? in
            guard let path = mkdtemp(buffer.baseAddress) else { return nil }
            return String(cString: path)
        }
        guard let directory else { throw SmokeError.failed }
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let file = directory + "/unsigned"
        try Data("inert fixture".utf8).write(to: URL(fileURLWithPath: file))
        try check(chmod(file, 0o444) == 0)
        try refused { try NativeProtectedInstallation.entry(file) }
        let link = directory + "/link"
        try check(symlink("/usr/bin/true", link) == 0)
        try refused { try NativeProtectedInstallation.entry(link) }
        try refused { try NativeProtectedInstallation.bundle(URL(fileURLWithPath: directory), deadline: DispatchTime.now().uptimeNanoseconds + 5_000_000_000) }
    }
}
