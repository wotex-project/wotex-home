import Foundation
import CryptoKit
import CoreFoundation

enum NativeControllerPairingError: Error { case invalidRecord }

struct NativeControllerAddress: Equatable, Sendable {
    let kind: String
    let value: String
}

struct NativeControllerInvitation: Equatable, Sendable {
    let controller: String
    let identity: NativeControllerAddress
    let leafPin: String
    let trustAnchor: Data
    let endpoint: NativeControllerAddress
    let port: Int64
    let invitation: String
    let bootstrapSecret: Data
}

// Public trust and location only. Retaining a peer does not retain the
// invitation/bootstrap secret or authorize any application operation.
struct NativeControllerPeer: Equatable, Sendable {
    let controller: String
    let identity: NativeControllerAddress
    let leafPin: String
    let trustAnchor: Data
    let endpoint: NativeControllerAddress
    let port: Int64

    init(invitation: NativeControllerInvitation) throws {
        _ = try NativeControllerPairingWire.encode(invitation)
        controller = invitation.controller; identity = invitation.identity
        leafPin = invitation.leafPin; trustAnchor = invitation.trustAnchor
        endpoint = invitation.endpoint; port = invitation.port
    }

    init(controller: String, identity: NativeControllerAddress, leafPin: String,
         trustAnchor: Data, endpoint: NativeControllerAddress, port: Int64) throws {
        self.controller = controller; self.identity = identity; self.leafPin = leafPin
        self.trustAnchor = trustAnchor; self.endpoint = endpoint; self.port = port
        guard NativeControllerPairingWire.peer(self) else { throw NativeControllerPairingError.invalidRecord }
    }
}

struct NativeControllerBootstrapRequest: Equatable, Sendable {
    let controller: String
    let invitation: String
    let client: String
    let request: String
    let label: String
    let bootstrapSecret: Data
}

struct NativeControllerPairingContext: Equatable, Sendable {
    let controller: String
    let invitation: String
    let client: String
    let request: String
    let requestDigest: String
}

struct NativeControllerAccess: Equatable, Sendable {
    let permissions: [String]
    let targets: [String]
    static let initial = Self(permissions: ["read"], targets: [])
}

struct NativeControllerAssociation: Equatable, Sendable {
    let context: NativeControllerPairingContext
    let deployment: String
    let owner: String
    let epoch: Int64
    let principal: String
    let revision: Int64
    let access: NativeControllerAccess
    let credential: Data
}

enum NativeControllerBootstrapResponse: Equatable, Sendable {
    case paired(NativeControllerAssociation)
    case refused(NativeControllerPairingContext, String)

    var context: NativeControllerPairingContext {
        switch self {
        case .paired(let association): association.context
        case .refused(let context, _): context
        }
    }
}

// Syntax and exact correspondence only. No TLS connection, trust evaluation,
// Keychain publication, operator approval or Store provisioning happens here.
enum NativeControllerPairingWire {
    static let maximumBytes = 8192
    private static let invitationFormat = "wotex-home.controller-invitation.v1"
    private static let requestFormat = "wotex-home.controller-bootstrap-request.v1"
    private static let responseFormat = "wotex-home.controller-bootstrap-response.v1"
    private static let permissions: Set<String> = ["read", "control:ordinary", "rule:review", "rule:manage", "enroll:review", "qualify:profile", "policy:manage", "host:maintain", "profile:manage", "host:transfer"]
    private static let zeroTargetPermissions: Set<String> = ["read", "enroll:review", "host:maintain", "profile:manage", "host:transfer"]
    private static let reasons: Set<String> = ["pairing_closed", "pairing_expired", "invitation_unavailable", "invitation_consumed", "confirmation_denied", "pairing_busy", "pairing_unavailable", "outcome_unknown"]

    static func frameSize(_ header: Data) throws -> Int {
        guard header.count == 4 else { throw NativeControllerPairingError.invalidRecord }
        let size = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard (1...UInt32(maximumBytes)).contains(size) else { throw NativeControllerPairingError.invalidRecord }
        return Int(size)
    }

    static func frame(_ invitation: NativeControllerInvitation) throws -> Data { framed(try encode(invitation)) }
    static func frame(_ request: NativeControllerBootstrapRequest) throws -> Data { framed(try encode(request)) }
    static func frame(_ response: NativeControllerBootstrapResponse) throws -> Data { framed(try encode(response)) }
    static func decodeInvitationFrame(_ frame: Data) throws -> NativeControllerInvitation { try decodeInvitation(body(frame)) }
    static func decodeRequestFrame(_ frame: Data) throws -> NativeControllerBootstrapRequest { try decodeRequest(body(frame)) }
    static func decodeResponseFrame(_ frame: Data) throws -> NativeControllerBootstrapResponse { try decodeResponse(body(frame)) }

    private static func framed(_ bytes: Data) -> Data {
        let size = UInt32(bytes.count)
        return Data([UInt8(size >> 24), UInt8((size >> 16) & 255), UInt8((size >> 8) & 255), UInt8(size & 255)]) + bytes
    }

    private static func body(_ frame: Data) throws -> Data {
        guard frame.count >= 4 else { throw NativeControllerPairingError.invalidRecord }
        let size = try frameSize(Data(frame.prefix(4)))
        guard frame.count == size + 4 else { throw NativeControllerPairingError.invalidRecord }
        return Data(frame.dropFirst(4))
    }

    static func encode(_ invitation: NativeControllerInvitation) throws -> Data {
        guard digest(invitation.controller), address(invitation.identity), digest(invitation.leafPin),
              (1...4096).contains(invitation.trustAnchor.count), address(invitation.endpoint),
              (1024...65535).contains(invitation.port), digest(invitation.invitation), invitation.bootstrapSecret.count == 32 else { throw NativeControllerPairingError.invalidRecord }
        return try ControllerPairingJSON.encode([invitationFormat, 1, invitation.controller,
            [invitation.identity.kind, invitation.identity.value], invitation.leafPin, base64(invitation.trustAnchor),
            [invitation.endpoint.kind, invitation.endpoint.value, invitation.port], invitation.invitation, base64(invitation.bootstrapSecret)])
    }

    static func peer(_ peer: NativeControllerPeer) -> Bool {
        digest(peer.controller) && address(peer.identity) && digest(peer.leafPin) &&
            (1...4096).contains(peer.trustAnchor.count) && address(peer.endpoint) &&
            (1024...65535).contains(peer.port)
    }

    static func decodeInvitation(_ bytes: Data) throws -> NativeControllerInvitation {
        let a = try ControllerPairingJSON.decode(bytes)
        guard a.count == 9, a[0] as? String == invitationFormat, integer(a[1]) == 1,
              let controller = a[2] as? String, let identity = a[3] as? [String], identity.count == 2,
              let pin = a[4] as? String, let anchor = unbase64(a[5], minimum: 1, maximum: 4096),
              let endpoint = a[6] as? [Any], endpoint.count == 3, let kind = endpoint[0] as? String,
              let value = endpoint[1] as? String, let port = integer(endpoint[2]),
              let invitation = a[7] as? String, let secret = unbase64(a[8], minimum: 32, maximum: 32) else { throw NativeControllerPairingError.invalidRecord }
        let result = NativeControllerInvitation(controller: controller, identity: .init(kind: identity[0], value: identity[1]), leafPin: pin,
            trustAnchor: anchor, endpoint: .init(kind: kind, value: value), port: port, invitation: invitation, bootstrapSecret: secret)
        guard try encode(result) == bytes else { throw NativeControllerPairingError.invalidRecord }
        return result
    }

    static func encode(_ request: NativeControllerBootstrapRequest) throws -> Data {
        guard [request.controller, request.invitation, request.client, request.request].allSatisfy(digest),
              label(request.label), request.bootstrapSecret.count == 32 else { throw NativeControllerPairingError.invalidRecord }
        return try ControllerPairingJSON.encode([requestFormat, 1, request.controller, request.invitation,
            request.client, request.request, base64(Data(request.label.utf8)), base64(request.bootstrapSecret)])
    }

    static func decodeRequest(_ bytes: Data) throws -> NativeControllerBootstrapRequest {
        let a = try ControllerPairingJSON.decode(bytes)
        guard a.count == 8, a[0] as? String == requestFormat, integer(a[1]) == 1,
              let controller = a[2] as? String, let invitation = a[3] as? String,
              let client = a[4] as? String, let request = a[5] as? String,
              let labelBytes = unbase64(a[6], minimum: 1, maximum: 80), let label = String(data: labelBytes, encoding: .utf8),
              let secret = unbase64(a[7], minimum: 32, maximum: 32) else { throw NativeControllerPairingError.invalidRecord }
        let result = NativeControllerBootstrapRequest(controller: controller, invitation: invitation, client: client,
            request: request, label: label, bootstrapSecret: secret)
        guard try encode(result) == bytes else { throw NativeControllerPairingError.invalidRecord }
        return result
    }

    static func context(_ request: NativeControllerBootstrapRequest) throws -> NativeControllerPairingContext {
        let hash = SHA256.hash(data: try encode(request)).map { String(format: "%02x", $0) }.joined()
        return .init(controller: request.controller, invitation: request.invitation, client: request.client, request: request.request, requestDigest: hash)
    }

    static func encode(_ response: NativeControllerBootstrapResponse) throws -> Data {
        let c = response.context
        guard [c.controller, c.invitation, c.client, c.request, c.requestDigest].allSatisfy(digest) else { throw NativeControllerPairingError.invalidRecord }
        let payload: [Any]
        switch response {
        case .paired(let a):
            guard digest(a.deployment), digest(a.owner), a.epoch >= 1, id(a.principal), a.revision >= 1,
                  access(a.access), a.credential.count == 32 else { throw NativeControllerPairingError.invalidRecord }
            payload = ["paired", a.deployment, a.owner, a.epoch, a.principal, a.revision, a.access.permissions, a.access.targets, base64(a.credential)]
        case .refused(_, let reason):
            guard reasons.contains(reason) else { throw NativeControllerPairingError.invalidRecord }
            payload = ["refused", reason]
        }
        return try ControllerPairingJSON.encode([responseFormat, 1, c.controller, c.invitation, c.client, c.request, c.requestDigest, payload])
    }

    static func decodeResponse(_ bytes: Data) throws -> NativeControllerBootstrapResponse {
        let a = try ControllerPairingJSON.decode(bytes)
        guard a.count == 8, a[0] as? String == responseFormat, integer(a[1]) == 1,
              let controller = a[2] as? String, let invitation = a[3] as? String,
              let client = a[4] as? String, let request = a[5] as? String, let hash = a[6] as? String,
              let payload = a[7] as? [Any] else { throw NativeControllerPairingError.invalidRecord }
        let c = NativeControllerPairingContext(controller: controller, invitation: invitation, client: client, request: request, requestDigest: hash)
        let result: NativeControllerBootstrapResponse
        if payload.count == 9, payload[0] as? String == "paired",
           let deployment = payload[1] as? String, let owner = payload[2] as? String, let epoch = integer(payload[3]),
           let principal = payload[4] as? String, let revision = integer(payload[5]),
           let permissions = payload[6] as? [String], let targets = payload[7] as? [String],
           let secret = unbase64(payload[8], minimum: 32, maximum: 32) {
            result = .paired(.init(context: c, deployment: deployment, owner: owner, epoch: epoch, principal: principal,
                revision: revision, access: .init(permissions: permissions, targets: targets), credential: secret))
        } else if payload.count == 2, payload[0] as? String == "refused", let reason = payload[1] as? String {
            result = .refused(c, reason)
        } else { throw NativeControllerPairingError.invalidRecord }
        guard try encode(result) == bytes else { throw NativeControllerPairingError.invalidRecord }
        return result
    }

    static func verifyResponse(_ bytes: Data, request: NativeControllerBootstrapRequest, approvedAccess: NativeControllerAccess = .initial) throws -> NativeControllerBootstrapResponse {
        guard access(approvedAccess) else { throw NativeControllerPairingError.invalidRecord }
        let response = try decodeResponse(bytes)
        guard try response.context == context(request) else { throw NativeControllerPairingError.invalidRecord }
        if case .paired(let association) = response,
           association.access != approvedAccess || association.credential == request.bootstrapSecret { throw NativeControllerPairingError.invalidRecord }
        return response
    }

    static func access(_ access: NativeControllerAccess) -> Bool {
        !access.permissions.isEmpty && access.permissions.count <= permissions.count &&
            access.permissions == access.permissions.sorted() && Set(access.permissions).count == access.permissions.count &&
            access.permissions.allSatisfy(permissions.contains) && access.targets.count <= 32 &&
            access.targets == access.targets.sorted() && Set(access.targets).count == access.targets.count && access.targets.allSatisfy(id) &&
            (!access.permissions.contains("host:transfer") || (access.permissions == ["host:transfer"] && access.targets.isEmpty)) &&
            (!access.targets.isEmpty || access.permissions.allSatisfy(zeroTargetPermissions.contains))
    }

    private static func digest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func id(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        func alphaNumeric(_ b: UInt8) -> Bool { (48...57).contains(b) || (65...90).contains(b) || (97...122).contains(b) }
        return (1...128).contains(bytes.count) && alphaNumeric(bytes[0]) && bytes.allSatisfy { alphaNumeric($0) || [46, 95, 58, 45].contains($0) }
    }

    private static func address(_ address: NativeControllerAddress) -> Bool {
        let value = address.value
        switch address.kind {
        case "dns":
            guard (1...253).contains(value.utf8.count) else { return false }
            let labels = value.split(separator: ".", omittingEmptySubsequences: false)
            func alphanumeric(_ b: UInt8) -> Bool { (48...57).contains(b) || (97...122).contains(b) }
            return labels.allSatisfy { label in
                let bytes = Array(label.utf8)
                return (1...63).contains(bytes.count) && alphanumeric(bytes[0]) && alphanumeric(bytes[bytes.count - 1]) && bytes.allSatisfy { alphanumeric($0) || $0 == 45 }
            } && labels.last!.utf8.contains { (97...122).contains($0) }
        case "ipv4":
            let parts = value.split(separator: ".", omittingEmptySubsequences: false)
            return (7...15).contains(value.utf8.count) && parts.count == 4 && parts.allSatisfy { part in
                guard let n = Int(part), (0...255).contains(n) else { return false }
                return String(n) == part
            }
        case "ipv6":
            let parts = value.split(separator: ":", omittingEmptySubsequences: false)
            return value.utf8.count == 39 && parts.count == 8 && parts.allSatisfy { part in
                part.utf8.count == 4 && part.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
            }
        default: return false
        }
    }

    private static func label(_ value: String) -> Bool {
        (1...80).contains(value.utf8.count) && value.unicodeScalars.allSatisfy {
            let n = $0.value
            return !(0...31).contains(n) && !(127...159).contains(n) &&
                ![0x061C, 0x200E, 0x200F, 0x2028, 0x2029].contains(n) && !(0x202A...0x202E).contains(n) && !(0x2066...0x2069).contains(n)
        }
    }

    private static func base64(_ bytes: Data) -> String {
        bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private static func unbase64(_ value: Any, minimum: Int, maximum: Int) -> Data? {
        guard let value = value as? String, value.utf8.count <= (maximum * 4 + 2) / 3 else { return nil }
        let padded = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + String(repeating: "=", count: (4 - value.utf8.count % 4) % 4)
        guard let bytes = Data(base64Encoded: padded), (minimum...maximum).contains(bytes.count), base64(bytes) == value else { return nil }
        return bytes
    }

    private static func integer(_ value: Any) -> Int64? { ControllerPairingJSON.integer(value) }
}

private enum ControllerPairingJSON {
    static func decode(_ bytes: Data) throws -> [Any] {
        guard (2...NativeControllerPairingWire.maximumBytes).contains(bytes.count), bytes.first == 91, bytes.last == 93 else { throw NativeControllerPairingError.invalidRecord }
        var counts: [Int] = []
        var quoted = false
        var length = 0
        for byte in bytes {
            if quoted {
                if byte == 34 { quoted = false; length = 0 }
                else {
                    guard (32...126).contains(byte), byte != 92, length < 5462 else { throw NativeControllerPairingError.invalidRecord }
                    length += 1
                }
            } else {
                switch byte {
                case 91:
                    guard counts.count < 3 else { throw NativeControllerPairingError.invalidRecord }
                    counts.append(0); length = 0
                case 93:
                    guard !counts.isEmpty else { throw NativeControllerPairingError.invalidRecord }
                    counts.removeLast(); length = 0
                case 34: quoted = true; length = 0
                case 44:
                    guard !counts.isEmpty, counts[counts.count - 1] < 31 else { throw NativeControllerPairingError.invalidRecord }
                    counts[counts.count - 1] += 1; length = 0
                case 48...57:
                    length += 1
                    guard length <= 19 else { throw NativeControllerPairingError.invalidRecord }
                default: throw NativeControllerPairingError.invalidRecord
                }
            }
        }
        guard !quoted, counts.isEmpty, let a = try? JSONSerialization.jsonObject(with: bytes) as? [Any],
              try encode(a) == bytes else { throw NativeControllerPairingError.invalidRecord }
        return a
    }

    static func encode(_ a: [Any]) throws -> Data {
        func valid(_ value: Any, depth: Int) -> Bool {
            if let array = value as? [Any] { return depth < 3 && array.count <= 32 && array.allSatisfy { valid($0, depth: depth + 1) } }
            if let string = value as? String { return string.utf8.count <= 5462 && string.utf8.allSatisfy { (32...126).contains($0) && $0 != 34 && $0 != 92 } }
            return integer(value) != nil
        }
        guard valid(a, depth: 0) else { throw NativeControllerPairingError.invalidRecord }
        let bytes = try JSONSerialization.data(withJSONObject: a, options: [.withoutEscapingSlashes])
        guard bytes.count <= NativeControllerPairingWire.maximumBytes else { throw NativeControllerPairingError.invalidRecord }
        return bytes
    }

    static func integer(_ value: Any) -> Int64? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
              ["c", "s", "i", "l", "q", "C", "S", "I", "L", "Q"].contains(String(cString: n.objCType)),
              n.int64Value >= 0, n.uint64Value <= UInt64(Int64.max) else { return nil }
        return n.int64Value
    }
}
