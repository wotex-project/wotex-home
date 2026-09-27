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
        case .noCredential: "Import an operator credential to read Home state."
        case .keychain(let status): "Keychain error \(status)."
        case .invalidSocket: "The private Home socket is unavailable."
        case .wrongPeer: "The Home socket belongs to another user."
        case .transport: "Could not complete the local Home request."
        case .invalidResponse: "The host returned an invalid local response."
        case .server(let reason): "Host rejected the local request: \(reason)."
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

struct HomeObservation: Sendable, Identifiable {
    let thingID: String
    let capabilityKey: String
    let quality: String
    let trust: String
    let valueText: String
    let revision: Int

    var id: String { "\(thingID)/\(capabilityKey)" }
}

struct HomeSnapshot: Sendable {
    let authorityEpoch: Int
    let watermark: Int
    let observations: [HomeObservation]
}

struct HomeThing: Sendable, Identifiable {
    let id: String
    let role: String
    let profileRef: String
    let capabilityCount: Int
    let resourceRevision: Int
}

struct HomeCatalogue: Sendable {
    let authorityEpoch: Int
    let watermark: Int
    let things: [HomeThing]
}

struct HomeReadView: Sendable {
    let catalogue: HomeCatalogue
    let snapshot: HomeSnapshot
}

enum LocalHealthClient {
    private static let maxResponseBytes = 1_048_576

    static func fetch() throws -> HomeHealth {
        let credential = try OperatorCredential.load()
        return try fetch(socketPath: defaultSocketPath(), credential: credential)
    }

    static func fetch(socketPath path: String, credential: Data) throws -> HomeHealth {
        let response = try request(socketPath: path, credential: credential, operation: "health")
        return try decodeHealth(response)
    }

    static func fetchSnapshot() throws -> HomeSnapshot {
        let credential = try OperatorCredential.load()
        return try fetchSnapshot(socketPath: defaultSocketPath(), credential: credential)
    }

    static func fetchSnapshot(socketPath path: String, credential: Data) throws -> HomeSnapshot {
        try fetchSnapshot(socketPath: path, credential: credential, startingWatermark: nil)
    }

    static func fetchReadView() throws -> HomeReadView {
        let credential = try OperatorCredential.load()
        return try fetchReadView(socketPath: defaultSocketPath(), credential: credential)
    }

    static func fetchReadView(socketPath path: String, credential: Data) throws -> HomeReadView {
        let catalogue = try fetchCatalogue(socketPath: path, credential: credential)
        let snapshot = try fetchSnapshot(
            socketPath: path, credential: credential, startingWatermark: catalogue.watermark
        )
        guard snapshot.authorityEpoch == catalogue.authorityEpoch,
              snapshot.watermark == catalogue.watermark else {
            throw LocalHealthError.invalidResponse
        }
        return HomeReadView(catalogue: catalogue, snapshot: snapshot)
    }

    private static func fetchSnapshot(
        socketPath path: String, credential: Data, startingWatermark: Int?
    ) throws -> HomeSnapshot {
        var watermark = startingWatermark
        var authorityEpoch: Int?
        var after: [String: String]?
        var observations: [HomeObservation] = []

        // One principal may see 32 Things with 32 capabilities each: 1,024 rows.
        for _ in 0..<11 {
            let response = try request(
                socketPath: path,
                credential: credential,
                operation: "snapshot",
                fields: [
                    "watermark": watermark.map { $0 as Any } ?? NSNull(),
                    "after": after.map { $0 as Any } ?? NSNull(),
                    "page_size": 100,
                ]
            )
            let page = try decodeSnapshot(response)
            if let prior = watermark, prior != page.watermark {
                throw LocalHealthError.invalidResponse
            }
            if let prior = authorityEpoch, prior != page.authorityEpoch {
                throw LocalHealthError.invalidResponse
            }
            watermark = page.watermark
            authorityEpoch = page.authorityEpoch
            observations.append(contentsOf: page.observations)
            guard observations.count <= 1_024 else { throw LocalHealthError.invalidResponse }
            guard let next = page.nextAfter else {
                return HomeSnapshot(
                    authorityEpoch: page.authorityEpoch,
                    watermark: page.watermark,
                    observations: observations
                )
            }
            if next == after { throw LocalHealthError.invalidResponse }
            after = next
        }
        throw LocalHealthError.invalidResponse
    }

    static func fetchCatalogue(socketPath path: String, credential: Data) throws -> HomeCatalogue {
        var watermark: Int?
        var authorityEpoch: Int?
        var after: String?
        var things: [HomeThing] = []

        for _ in 0..<4 {
            let response = try request(
                socketPath: path,
                credential: credential,
                operation: "catalogue",
                fields: [
                    "watermark": watermark.map { $0 as Any } ?? NSNull(),
                    "after": after.map { $0 as Any } ?? NSNull(),
                    "page_size": 10,
                ]
            )
            let page = try decodeCatalogue(response)
            if let prior = watermark, prior != page.watermark {
                throw LocalHealthError.invalidResponse
            }
            if let prior = authorityEpoch, prior != page.authorityEpoch {
                throw LocalHealthError.invalidResponse
            }
            if let prior = after, let first = page.things.first, first.id <= prior {
                throw LocalHealthError.invalidResponse
            }
            watermark = page.watermark
            authorityEpoch = page.authorityEpoch
            things.append(contentsOf: page.things)
            guard things.count <= 32 else { throw LocalHealthError.invalidResponse }
            guard let next = page.nextAfter else {
                return HomeCatalogue(
                    authorityEpoch: page.authorityEpoch,
                    watermark: page.watermark,
                    things: things
                )
            }
            if next == after { throw LocalHealthError.invalidResponse }
            after = next
        }
        throw LocalHealthError.invalidResponse
    }

    private static func defaultSocketPath() -> String {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        let directory = support.appendingPathComponent("WoTExHome/ipc", isDirectory: true)
        return directory.appendingPathComponent("home.sock").path
    }

    private static func request(
        socketPath path: String,
        credential: Data,
        operation: String,
        fields: [String: Any] = [:]
    ) throws -> [String: Any] {
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

        var request: [String: Any] = [
            "api_version": 1,
            "operation": operation,
            "credential": OperatorCredential.encode(credential),
        ]
        for (key, value) in fields {
            guard request[key] == nil else { throw LocalHealthError.invalidResponse }
            request[key] = value
        }
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
        return try decodeEnvelope(response)
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

    private static func decodeEnvelope(_ data: Data) throws -> [String: Any] {
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
        guard outcome == "ok" else { throw LocalHealthError.invalidResponse }
        return response
    }

    private static func decodeHealth(_ response: [String: Any]) throws -> HomeHealth {
        guard let health = response["health"] as? [String: Any],
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

    private struct SnapshotPage {
        let authorityEpoch: Int
        let watermark: Int
        let observations: [HomeObservation]
        let nextAfter: [String: String]?
    }

    private struct CataloguePage {
        let authorityEpoch: Int
        let watermark: Int
        let things: [HomeThing]
        let nextAfter: String?
    }

    private static func decodeCatalogue(_ response: [String: Any]) throws -> CataloguePage {
        guard let catalogue = response["catalogue"] as? [String: Any],
              let epoch = catalogue["authority_epoch"] as? Int, epoch >= 1,
              let watermark = catalogue["watermark"] as? Int, watermark >= 0,
              let rawItems = catalogue["items"] as? [[String: Any]],
              rawItems.count <= 10,
              let rawAfter = catalogue["next_after"] else {
            throw LocalHealthError.invalidResponse
        }

        let things = try rawItems.map(decodeThing)
        for (previous, current) in zip(things, things.dropFirst())
        where current.id <= previous.id {
            throw LocalHealthError.invalidResponse
        }
        let nextAfter: String?
        if rawAfter is NSNull {
            nextAfter = nil
        } else if let cursor = rawAfter as? String,
                  !things.isEmpty,
                  things.last?.id == cursor {
            nextAfter = cursor
        } else {
            throw LocalHealthError.invalidResponse
        }

        return CataloguePage(
            authorityEpoch: epoch,
            watermark: watermark,
            things: things,
            nextAfter: nextAfter
        )
    }

    private static func decodeThing(_ raw: [String: Any]) throws -> HomeThing {
        guard let id = raw["id"] as? String, !id.isEmpty,
              let role = raw["role"] as? String,
              role == "Light" || role == "SmokeDetector",
              let profile = raw["profile_ref"] as? String, !profile.isEmpty,
              let capabilities = raw["capabilities"] as? [[String: Any]],
              (1...32).contains(capabilities.count),
              let revision = raw["resource_revision"] as? Int, revision >= 0 else {
            throw LocalHealthError.invalidResponse
        }
        return HomeThing(
            id: id,
            role: role,
            profileRef: profile,
            capabilityCount: capabilities.count,
            resourceRevision: revision
        )
    }

    private static func decodeSnapshot(_ response: [String: Any]) throws -> SnapshotPage {
        guard let snapshot = response["snapshot"] as? [String: Any],
              let epoch = snapshot["authority_epoch"] as? Int, epoch >= 1,
              let watermark = snapshot["watermark"] as? Int, watermark >= 0,
              let rawItems = snapshot["items"] as? [[String: Any]],
              rawItems.count <= 100,
              let rawAfter = snapshot["next_after"] else {
            throw LocalHealthError.invalidResponse
        }

        let observations = try rawItems.map(decodeObservation)
        let nextAfter: [String: String]?
        if rawAfter is NSNull {
            nextAfter = nil
        } else if let cursor = rawAfter as? [String: String],
                  cursor.count == 2,
                  let thing = cursor["thing_id"], !thing.isEmpty,
                  let capability = cursor["capability_key"], !capability.isEmpty,
                  !observations.isEmpty,
                  observations.last?.thingID == thing,
                  observations.last?.capabilityKey == capability {
            nextAfter = cursor
        } else {
            throw LocalHealthError.invalidResponse
        }

        return SnapshotPage(
            authorityEpoch: epoch,
            watermark: watermark,
            observations: observations,
            nextAfter: nextAfter
        )
    }

    private static func decodeObservation(_ raw: [String: Any]) throws -> HomeObservation {
        guard let thing = raw["thing_id"] as? String, !thing.isEmpty,
              let capability = raw["capability_key"] as? String, !capability.isEmpty,
              let quality = raw["quality"] as? String,
              quality == "reported" || quality == "unknown",
              let trust = raw["trust"] as? String,
              ["unauthenticated_local", "authenticated_device", "bridge_attested", "synthetic_lab"]
                  .contains(trust),
              let revision = raw["revision"] as? Int, revision >= 0,
              let value = raw["value"] else {
            throw LocalHealthError.invalidResponse
        }

        let text: String
        if quality == "unknown" {
            guard value is NSNull else { throw LocalHealthError.invalidResponse }
            text = "Unknown"
        } else {
            guard let map = value as? [String: Any] else {
                throw LocalHealthError.invalidResponse
            }
            text = try valueText(map)
        }

        return HomeObservation(
            thingID: thing,
            capabilityKey: capability,
            quality: quality,
            trust: trust,
            valueText: text,
            revision: revision
        )
    }

    private static func valueText(_ value: [String: Any]) throws -> String {
        switch value["type"] as? String {
        case "boolean":
            guard let on = value["value"] as? Bool else { break }
            return on ? "On" : "Off"
        case "fraction":
            guard let ppm = value["ppm"] as? Int, (0...1_000_000).contains(ppm) else { break }
            return String(format: "%.1f%%", Double(ppm) / 10_000.0)
        case "kelvin":
            guard let kelvin = value["kelvin"] as? Int, kelvin > 0 else { break }
            return "\(kelvin) K"
        case "hsv":
            guard let hue = value["hue_mdeg"] as? Int, (0..<360_000).contains(hue),
                  let saturation = value["saturation_ppm"] as? Int,
                  (0...1_000_000).contains(saturation) else { break }
            return String(format: "%.1f° · %.1f%%", Double(hue) / 1_000.0,
                          Double(saturation) / 10_000.0)
        case "xy":
            guard let x = value["x_ppm"] as? Int, let y = value["y_ppm"] as? Int,
                  x >= 0, y >= 0, x + y <= 1_000_000 else { break }
            return "xy \(x), \(y) ppm"
        case "smoke_state":
            guard let state = value["state"] as? String,
                  state == "clear" || state == "alarm" else { break }
            return state == "alarm" ? "Alarm reported" : "Clear reported"
        default:
            break
        }
        throw LocalHealthError.invalidResponse
    }
}
