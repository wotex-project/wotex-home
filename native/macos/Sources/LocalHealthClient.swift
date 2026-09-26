import Darwin
import Foundation
import Security

enum LocalHealthError: LocalizedError {
    case invalidCredential
    case noCredential
    case keychain(OSStatus)
    case invalidSocket
    case wrongPeer
    case transport
    case invalidResponse
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidCredential: "Enter the 43-character operator credential."
        case .noCredential: "Import an operator credential to read host health."
        case .keychain(let status): "Keychain error \(status)."
        case .invalidSocket: "The private Home socket is unavailable."
        case .wrongPeer: "The Home socket belongs to another user."
        case .transport: "Could not complete the local health request."
        case .invalidResponse: "The host returned an invalid health response."
        case .server(let reason): "Host rejected health request: \(reason)."
        }
    }
}

enum OperatorCredential {
    private static let service = "org.wotex.home.operator"
    private static let account = "local-api-v1"

    private static var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
    }

    static func save(_ encoded: String) throws {
        guard encoded.count == 43,
              encoded.utf8.allSatisfy({
                  (65...90).contains($0) || (97...122).contains($0) ||
                      (48...57).contains($0) || $0 == 45 || $0 == 95
              }),
              let data = Data(base64Encoded: encoded.replacingOccurrences(of: "-", with: "+")
                  .replacingOccurrences(of: "_", with: "/") + "="),
              data.count == 32,
              encode(data) == encoded else {
            throw LocalHealthError.invalidCredential
        }

        var attributes = query
        attributes[kSecValueData as String] = data
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let update = SecItemUpdate(
                query as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
            guard update == errSecSuccess else { throw LocalHealthError.keychain(update) }
        } else if status != errSecSuccess {
            throw LocalHealthError.keychain(status)
        }
    }

    static func load() throws -> Data {
        var attributes = query
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        if status == errSecItemNotFound { throw LocalHealthError.noCredential }
        guard status == errSecSuccess else { throw LocalHealthError.keychain(status) }
        guard let data = result as? Data, data.count == 32 else {
            throw LocalHealthError.invalidCredential
        }
        return data
    }

    static func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw LocalHealthError.keychain(status)
        }
    }

    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

struct HomeHealth: Sendable {
    let revision: Int
    let authorityEpoch: Int
    let heldRequests: Int
    let activeThings: Int
    let activePrincipals: Int
    let writable: Bool
    let dispatchEnabled: Bool
}

enum LocalHealthClient {
    private static let maxResponseBytes = 1_048_576

    static func fetch() throws -> HomeHealth {
        let credential = try OperatorCredential.load()
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        let directory = support.appendingPathComponent("WoTExHome/ipc", isDirectory: true)
        let path = directory.appendingPathComponent("home.sock").path
        return try fetch(socketPath: path, credential: credential)
    }

    static func fetch(socketPath path: String, credential: Data) throws -> HomeHealth {
        guard credential.count == 32 else { throw LocalHealthError.invalidCredential }
        try checkPath((path as NSString).deletingLastPathComponent, path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw LocalHealthError.transport }
        defer { _ = Darwin.close(fd) }

        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        let timeoutSize = socklen_t(MemoryLayout<timeval>.size)
        guard setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, timeoutSize) == 0,
              setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, timeoutSize) == 0 else {
            throw LocalHealthError.transport
        }

        var address = sockaddr_un()
        let pathBytes = Array(path.utf8) + [0]
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw LocalHealthError.invalidSocket
        }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            bytes.copyBytes(from: pathBytes)
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw LocalHealthError.invalidSocket }

        var peerUID = uid_t.max
        var peerGID = gid_t.max
        guard getpeereid(fd, &peerUID, &peerGID) == 0, peerUID == geteuid() else {
            throw LocalHealthError.wrongPeer
        }

        let request: [String: Any] = [
            "api_version": 1,
            "operation": "health",
            "credential": OperatorCredential.encode(credential),
        ]
        let body = try JSONSerialization.data(withJSONObject: request)
        guard body.count <= 65_536 else { throw LocalHealthError.transport }
        var length = UInt32(body.count).bigEndian
        let header = withUnsafeBytes(of: &length) { Data($0) }
        try writeAll(fd, header)
        try writeAll(fd, body)

        let responseHeader = try readExactly(fd, 4)
        let responseLength = responseHeader.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard responseLength > 0 && responseLength <= maxResponseBytes else {
            throw LocalHealthError.invalidResponse
        }
        let response = try readExactly(fd, Int(responseLength))
        return try decode(response)
    }

    private static func checkPath(_ directory: String, _ socketPath: String) throws {
        var parent = stat()
        var child = stat()
        guard lstat(directory, &parent) == 0,
              parent.st_uid == geteuid(),
              (parent.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              (parent.st_mode & 0o777) == 0o700,
              lstat(socketPath, &child) == 0,
              child.st_uid == geteuid(),
              (child.st_mode & mode_t(S_IFMT)) == mode_t(S_IFSOCK),
              (child.st_mode & 0o777) == 0o600 else {
            throw LocalHealthError.invalidSocket
        }
    }

    private static func writeAll(_ fd: Int32, _ data: Data) throws {
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { bytes in
                Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), data.count - offset)
            }
            if written < 0 && errno == EINTR { continue }
            guard written > 0 else { throw LocalHealthError.transport }
            offset += written
        }
    }

    private static func readExactly(_ fd: Int32, _ count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let received = bytes.withUnsafeMutableBytes { buffer in
                Darwin.read(fd, buffer.baseAddress!.advanced(by: offset), count - offset)
            }
            if received < 0 && errno == EINTR { continue }
            guard received > 0 else { throw LocalHealthError.transport }
            offset += received
        }
        return Data(bytes)
    }

    private static func decode(_ data: Data) throws -> HomeHealth {
        guard let value = try? JSONSerialization.jsonObject(with: data),
              let response = value as? [String: Any],
              response["api_version"] as? Int == 1,
              let outcome = response["outcome"] as? String else {
            throw LocalHealthError.invalidResponse
        }
        if outcome == "error" {
            guard let reason = response["reason"] as? String, reason.count <= 128 else {
                throw LocalHealthError.invalidResponse
            }
            throw LocalHealthError.server(reason)
        }
        guard outcome == "ok",
              let health = response["health"] as? [String: Any],
              let revision = health["store_revision"] as? Int, revision >= 0,
              let epoch = health["authority_epoch"] as? Int, epoch >= 0,
              let held = health["held_requests"] as? Int, held >= 0,
              let things = health["active_things"] as? Int, things >= 0,
              let principals = health["active_principals"] as? Int, principals >= 0,
              let writable = health["writable"] as? Bool,
              let dispatch = health["dispatch_enabled"] as? Bool else {
            throw LocalHealthError.invalidResponse
        }
        return HomeHealth(
            revision: revision,
            authorityEpoch: epoch,
            heldRequests: held,
            activeThings: things,
            activePrincipals: principals,
            writable: writable,
            dispatchEnabled: dispatch
        )
    }
}
