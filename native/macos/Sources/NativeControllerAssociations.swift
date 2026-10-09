import CryptoKit
import Foundation

enum NativeControllerAssociationError: Error { case invalidRecord, unavailable, conflict, capacity, outcomeUnknown }

struct NativeControllerAssociationScope: Equatable, Sendable {
    let deployment: String, owner: String, epoch: Int64, principal: String, creationRevision: Int64
}

// Public historical metadata only. Neither construction nor file load is a
// TLS/custody seal, a current grant or permission to import an application key.
struct NativeControllerPublicAssociation: Equatable, Sendable {
    let id: String
    let label: String
    let peer: NativeControllerPeer
    let scope: NativeControllerAssociationScope
    let original: NativeControllerPairingContext
    let access: NativeControllerAccess
    let verifier: String

    static let keychainService = "org.wotex.home.paired-controller.v1"
    var keychainAccount: String { id }

    static func corresponding(peer: NativeControllerPeer, label: String,
                              delivered: NativeControllerAssociation, request: NativeControllerBootstrapRequest,
                              approvedAccess: NativeControllerAccess) throws -> Self {
        do {
            guard delivered.context == (try NativeControllerPairingWire.context(request)),
                  peer.controller == request.controller, delivered.access == approvedAccess,
                  delivered.credential.count == 32, delivered.credential != request.bootstrapSecret else {
                throw NativeControllerAssociationError.invalidRecord
            }
            let scope = NativeControllerAssociationScope(deployment: delivered.deployment, owner: delivered.owner,
                epoch: delivered.epoch, principal: delivered.principal, creationRevision: delivered.revision)
            let verifier = NativeControllerAssociationsWire.hash(delivered.credential)
            let candidate = Self(id: "", label: label, peer: peer, scope: scope,
                original: delivered.context, access: delivered.access, verifier: verifier)
            let result = Self(id: try NativeControllerAssociationsWire.bindingID(candidate), label: label,
                peer: peer, scope: scope, original: delivered.context, access: delivered.access, verifier: verifier)
            _ = try result.encoded()
            return result
        } catch { throw NativeControllerAssociationError.invalidRecord }
    }

    func changingMetadata(label: String, endpoint: NativeControllerAddress, port: Int64) throws -> Self {
        do {
            let peer = try NativeControllerPeer(controller: peer.controller, identity: peer.identity, leafPin: peer.leafPin,
                trustAnchor: peer.trustAnchor, endpoint: endpoint, port: port)
            let result = Self(id: id, label: label, peer: peer, scope: scope, original: original, access: access, verifier: verifier)
            _ = try result.encoded()
            return result
        } catch { throw NativeControllerAssociationError.invalidRecord }
    }

    func encoded() throws -> Data { try NativeControllerAssociationsWire.encode(self) }
    static func decode(_ bytes: Data) throws -> Self { try NativeControllerAssociationsWire.decode(bytes) }
}

enum NativeControllerAssociationsWire {
    static let maximumRecordBytes = 16_384
    static let maximumDocumentBytes = 131_072
    private static let format = "wotex-home.native-controller-association.v1"
    private static let bindingFormat = "wotex-home.native-controller-association-binding.v1"

    static func hash(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    private static func scope(_ record: NativeControllerPublicAssociation) -> [Any] {
        let s = record.scope
        return [s.deployment, s.owner, s.epoch, s.principal, s.creationRevision]
    }
    private static func original(_ record: NativeControllerPublicAssociation) -> [Any] {
        let o = record.original
        return [o.invitation, o.client, o.request, o.requestDigest]
    }
    static func binding(_ record: NativeControllerPublicAssociation) throws -> Data {
        let p = record.peer, s = record.scope, o = record.original
        guard NativeControllerPairingWire.peer(p),
              [s.deployment, s.owner, o.invitation, o.client, o.request, o.requestDigest, record.verifier].allSatisfy(NativeControllerPairingWire.digest),
              s.epoch > 0, s.creationRevision > 0, o.controller == p.controller,
              s.principal == "paired-controller-v1:\(s.epoch):\(o.client)",
              NativeControllerPairingWire.id(s.principal), NativeControllerPairingWire.access(record.access) else {
            throw NativeControllerAssociationError.invalidRecord
        }
        do {
            return try ControllerPairingJSON.encode([bindingFormat, p.controller, [p.identity.kind, p.identity.value],
                p.leafPin, NativeControllerPairingWire.base64(p.trustAnchor), scope(record), original(record),
                record.access.permissions, record.access.targets, record.verifier], maximumBytes: maximumRecordBytes)
        } catch { throw NativeControllerAssociationError.invalidRecord }
    }
    static func bindingID(_ record: NativeControllerPublicAssociation) throws -> String { hash(try binding(record)) }
    static func encode(_ record: NativeControllerPublicAssociation) throws -> Data {
        guard NativeControllerPairingWire.label(record.label), record.id == (try bindingID(record)) else {
            throw NativeControllerAssociationError.invalidRecord
        }
        let p = record.peer
        do {
            return try ControllerPairingJSON.encode([format, 1, record.id, NativeControllerPairingWire.base64(Data(record.label.utf8)),
                p.controller, [p.identity.kind, p.identity.value], p.leafPin, NativeControllerPairingWire.base64(p.trustAnchor),
                [p.endpoint.kind, p.endpoint.value, p.port], scope(record), original(record),
                record.access.permissions, record.access.targets, record.verifier], maximumBytes: maximumRecordBytes)
        } catch { throw NativeControllerAssociationError.invalidRecord }
    }
    static func decode(_ bytes: Data) throws -> NativeControllerPublicAssociation {
        do {
            let a = try ControllerPairingJSON.decode(bytes, maximumBytes: maximumRecordBytes)
            guard a.count == 14, a[0] as? String == format, ControllerPairingJSON.integer(a[1]) == 1,
                  let id = a[2] as? String, let labelBytes = NativeControllerPairingWire.unbase64(a[3], minimum: 1, maximum: 80),
                  let label = String(data: labelBytes, encoding: .utf8), let controller = a[4] as? String,
                  let identity = a[5] as? [String], identity.count == 2, let pin = a[6] as? String,
                  let anchor = NativeControllerPairingWire.unbase64(a[7], minimum: 1, maximum: 4096),
                  let endpoint = a[8] as? [Any], endpoint.count == 3, let kind = endpoint[0] as? String,
                  let address = endpoint[1] as? String, let port = ControllerPairingJSON.integer(endpoint[2]),
                  let scope = a[9] as? [Any], scope.count == 5, let deployment = scope[0] as? String,
                  let owner = scope[1] as? String, let epoch = ControllerPairingJSON.integer(scope[2]),
                  let principal = scope[3] as? String, let revision = ControllerPairingJSON.integer(scope[4]),
                  let original = a[10] as? [String], original.count == 4,
                  let permissions = a[11] as? [String], let targets = a[12] as? [String], let verifier = a[13] as? String else {
                throw NativeControllerAssociationError.invalidRecord
            }
            let peer = try NativeControllerPeer(controller: controller, identity: .init(kind: identity[0], value: identity[1]),
                leafPin: pin, trustAnchor: anchor, endpoint: .init(kind: kind, value: address), port: port)
            let result = NativeControllerPublicAssociation(id: id, label: label, peer: peer,
                scope: .init(deployment: deployment, owner: owner, epoch: epoch, principal: principal, creationRevision: revision),
                original: .init(controller: controller, invitation: original[0], client: original[1], request: original[2], requestDigest: original[3]),
                access: .init(permissions: permissions, targets: targets), verifier: verifier)
            guard try encode(result) == bytes else { throw NativeControllerAssociationError.invalidRecord }
            return result
        } catch { throw NativeControllerAssociationError.invalidRecord }
    }
}

enum NativeControllerSelection: Equatable, Sendable {
    case local, remote(String)
    fileprivate var values: [Any] { switch self { case .local: ["local"]; case .remote(let id): ["remote", id] } }
}

struct NativeControllerAssociationDocument: Equatable, Sendable {
    let revision: Int64
    let selection: NativeControllerSelection
    let records: [NativeControllerPublicAssociation]
    static let empty = Self(revision: 0, selection: .local, records: [])
    private static let format = "wotex-home.native-controllers.v1"

    func encoded() throws -> Data {
        guard revision > 0, records.count <= 8, records.map(\.id) == records.map(\.id).sorted(),
              Set(records.map(\.id)).count == records.count else { throw NativeControllerAssociationError.invalidRecord }
        if case .remote(let id) = selection, !records.contains(where: { $0.id == id }) { throw NativeControllerAssociationError.invalidRecord }
        let bodies = try records.map { String(decoding: try $0.encoded(), as: UTF8.self) }
        return try NativeControllerDocumentJSON.encode([Self.format, revision, selection.values, bodies])
    }
    static func decode(_ bytes: Data) throws -> Self {
        let a = try NativeControllerDocumentJSON.decode(bytes)
        guard a.count == 4, a[0] as? String == format, let revision = ControllerPairingJSON.integer(a[1]), revision > 0,
              let selectionValues = a[2] as? [String], let bodies = a[3] as? [String], bodies.count <= 8 else {
            throw NativeControllerAssociationError.invalidRecord
        }
        let selection: NativeControllerSelection
        if selectionValues == ["local"] { selection = .local }
        else if selectionValues.count == 2, selectionValues[0] == "remote" { selection = .remote(selectionValues[1]) }
        else { throw NativeControllerAssociationError.invalidRecord }
        let result = Self(revision: revision, selection: selection, records: try bodies.map { try NativeControllerPublicAssociation.decode(Data($0.utf8)) })
        guard try result.encoded() == bytes else { throw NativeControllerAssociationError.invalidRecord }
        return result
    }
}

// This new root permits escaped canonical record strings only. Bound bytes,
// depth, member counts and decoded string length before Foundation allocation.
private enum NativeControllerDocumentJSON {
    static func decode(_ bytes: Data) throws -> [Any] {
        guard (2...NativeControllerAssociationsWire.maximumDocumentBytes).contains(bytes.count), bytes.first == 91, bytes.last == 93 else {
            throw NativeControllerAssociationError.invalidRecord
        }
        var counts: [Int] = [], quoted = false, escaped = false, length = 0
        for byte in bytes {
            if quoted {
                if escaped {
                    guard byte == 34 || byte == 92 else { throw NativeControllerAssociationError.invalidRecord }
                    escaped = false; length += 1
                } else if byte == 34 { quoted = false; length = 0 }
                else if byte == 92 { escaped = true }
                else {
                    guard (32...126).contains(byte) else { throw NativeControllerAssociationError.invalidRecord }
                    length += 1
                }
                guard length <= NativeControllerAssociationsWire.maximumRecordBytes else { throw NativeControllerAssociationError.invalidRecord }
            } else {
                switch byte {
                case 91:
                    guard counts.count < 2 else { throw NativeControllerAssociationError.invalidRecord }
                    counts.append(0); length = 0
                case 93:
                    guard !counts.isEmpty else { throw NativeControllerAssociationError.invalidRecord }
                    counts.removeLast(); length = 0
                case 34: quoted = true; length = 0
                case 44:
                    guard !counts.isEmpty, counts[counts.count - 1] < 31 else { throw NativeControllerAssociationError.invalidRecord }
                    counts[counts.count - 1] += 1; length = 0
                case 48...57:
                    length += 1
                    guard length <= 19 else { throw NativeControllerAssociationError.invalidRecord }
                default: throw NativeControllerAssociationError.invalidRecord
                }
            }
        }
        guard !quoted, !escaped, counts.isEmpty, let values = try? JSONSerialization.jsonObject(with: bytes) as? [Any],
              try encode(values) == bytes else { throw NativeControllerAssociationError.invalidRecord }
        return values
    }
    static func encode(_ values: [Any]) throws -> Data {
        func valid(_ value: Any, depth: Int) -> Bool {
            if let array = value as? [Any] { return depth < 2 && array.count <= 32 && array.allSatisfy { valid($0, depth: depth + 1) } }
            if let string = value as? String { return string.utf8.count <= NativeControllerAssociationsWire.maximumRecordBytes && string.utf8.allSatisfy { (32...126).contains($0) } }
            return ControllerPairingJSON.integer(value) != nil
        }
        guard valid(values, depth: 0) else { throw NativeControllerAssociationError.invalidRecord }
        let bytes = try JSONSerialization.data(withJSONObject: values, options: .withoutEscapingSlashes)
        guard bytes.count <= NativeControllerAssociationsWire.maximumDocumentBytes else { throw NativeControllerAssociationError.invalidRecord }
        return bytes
    }
}
