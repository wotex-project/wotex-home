import CoreFoundation
import CryptoKit
import Foundation

enum NativeSetupWireError: Error { case invalidRecord }

enum NativeCustodyRole: String, CaseIterable, Sendable {
    case diagnostic, `operator`, maintenance, transfer
}

struct NativeControllerScope: Equatable, Sendable {
    let deployment: String
    let owner: String
    let epoch: Int64
    let revision: Int64
}

// Decoded kernel-token metadata is not an authenticated peer seal.
struct NativeCoreEndpointMetadata: Equatable, Sendable, CustomReflectable {
    let scope: NativeControllerScope
    let auditToken: Data
    var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
}

struct NativeCreationReceipt: Equatable, Sendable {
    let deployment: String
    let owner: String
    let epoch: Int64
    let role: NativeCustodyRole
    let principal: String
    let revision: Int64
}

// A reference is inert metadata. It never supplies an OS signing or custody seal.
struct NativeOriginalReference: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let receipt: NativeCreationReceipt
    let verifier: String
    var description: String { "private_native_original_reference" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
    var valid: Bool {
        NativeCoreWire.digest(receipt.deployment) && NativeCoreWire.digest(receipt.owner) &&
            NativeCoreWire.digest(verifier) && receipt.epoch >= 1 && receipt.revision >= 1 &&
            receipt.principal == NativeCoreWire.principal(receipt.epoch, receipt.role)
    }
    func matches(_ scope: NativeControllerScope) -> Bool {
        valid && NativeCoreWire.valid(scope) && receipt.deployment == scope.deployment &&
            receipt.owner == scope.owner && receipt.epoch == scope.epoch && scope.revision >= receipt.revision
    }
    func accepts(_ record: NativeCredentialRecord) -> Bool {
        valid && record.receipt == receipt && record.bytes.count == 32 &&
            verifier == NativeCoreWire.hex(Data(SHA256.hash(data: record.bytes)))
    }
}

enum NativeCoreWire {
    static let format = "wotex-home.native-setup-authority.v1"
    static let reasons: Set<String> = [
        "invalid_native_setup_record", "native_owner_changed", "native_custody_conflict",
        "native_setup_unavailable", "outcome_unknown", "frame_timeout", "core_owner_lost", "channel_closed",
    ]

    static func identityRequest() throws -> Data {
        try NativeScalarJSON.encode([format, "identity"])
    }

    static func ensureRequest(_ scope: NativeControllerScope, role: NativeCustodyRole, verifier: Data) throws -> Data {
        guard valid(scope), verifier.count == 32 else { throw NativeSetupWireError.invalidRecord }
        let hex = verifier.map { String(format: "%02x", $0) }.joined()
        return try NativeScalarJSON.encode([format, "ensure", scope.deployment, scope.owner, scope.epoch, role.rawValue, hex])
    }

    static func existingRequest(_ original: NativeOriginalReference) throws -> Data {
        guard original.valid else { throw NativeSetupWireError.invalidRecord }
        let receipt = original.receipt
        return try NativeScalarJSON.encode([format, "existing", receipt.deployment, receipt.owner,
                                            receipt.epoch, receipt.role.rawValue, original.verifier, receipt.revision])
    }

    static func identity(_ body: Data) throws -> NativeControllerScope {
        let values = try NativeScalarJSON.decode(body)
        guard values.count == 6, values[0] as? String == format, values[1] as? String == "identity",
              let deployment = values[2] as? String, digest(deployment),
              let owner = values[3] as? String, digest(owner),
              let epoch = NativeScalarJSON.integer(values[4], minimum: 1),
              let revision = NativeScalarJSON.integer(values[5], minimum: 0) else {
            throw NativeSetupWireError.invalidRecord
        }
        return NativeControllerScope(deployment: deployment, owner: owner, epoch: epoch, revision: revision)
    }

    static func receipt(_ body: Data, scope: NativeControllerScope, role: NativeCustodyRole) throws -> NativeCreationReceipt {
        try creationReceipt(body, scope: scope, role: role, kind: "ensured")
    }

    static func originalReceipt(_ body: Data, scope: NativeControllerScope, original: NativeOriginalReference) throws -> NativeCreationReceipt {
        guard original.matches(scope) else { throw NativeSetupWireError.invalidRecord }
        let receipt = try creationReceipt(body, scope: scope, role: original.receipt.role, kind: "found")
        guard receipt == original.receipt else { throw NativeSetupWireError.invalidRecord }
        return receipt
    }

    private static func creationReceipt(_ body: Data, scope: NativeControllerScope, role: NativeCustodyRole, kind: String) throws -> NativeCreationReceipt {
        let values = try NativeScalarJSON.decode(body)
        guard valid(scope), values.count == 8, values[0] as? String == format,
              values[1] as? String == kind, values[2] as? String == scope.deployment,
              values[3] as? String == scope.owner,
              NativeScalarJSON.integer(values[4], minimum: 1) == scope.epoch,
              values[5] as? String == role.rawValue,
              values[6] as? String == principal(scope.epoch, role),
              let revision = NativeScalarJSON.integer(values[7], minimum: 1) else {
            throw NativeSetupWireError.invalidRecord
        }
        return NativeCreationReceipt(deployment: scope.deployment, owner: scope.owner, epoch: scope.epoch,
                                     role: role, principal: principal(scope.epoch, role), revision: revision)
    }

    static func error(_ body: Data) throws -> String {
        let values = try NativeScalarJSON.decode(body)
        guard values.count == 3, values[0] as? String == format, values[1] as? String == "error",
              let reason = values[2] as? String, reasons.contains(reason) else {
            throw NativeSetupWireError.invalidRecord
        }
        return reason
    }

    static func principal(_ epoch: Int64, _ role: NativeCustodyRole) -> String {
        "native-setup-v1:\(epoch):\(role.rawValue)"
    }

    static func valid(_ scope: NativeControllerScope) -> Bool {
        digest(scope.deployment) && digest(scope.owner) && scope.epoch >= 1 && scope.revision >= 0
    }

    static func digest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func hex(_ bytes: Data) -> String { bytes.map { String(format: "%02x", $0) }.joined() }
}

enum NativeBrokerRequest: Equatable, Sendable {
    case status
    case endpoint
    case credential(NativeCustodyRole)
    case recover(NativeOriginalReference)
    case accessChange(NativeTargetChange)
    case accessStatus(NativeOriginalReference, String)
}

struct NativeCredentialRecord: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let receipt: NativeCreationReceipt
    let bytes: Data
    var description: String { "private_native_credential_record" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
}

enum NativeBrokerWire {
    static let format = "wotex-home.native-credential-broker.v1"
    static let reasons: Set<String> = [
        "setup_unavailable", "capacity", "peer_refused", "expired", "keychain_locked", "keychain_denied",
        "keychain_unavailable", "custody_conflict", "owner_changed", "invalid_request", "outcome_unknown",
    ]

    static func request(_ value: NativeBrokerRequest) throws -> Data {
        switch value {
        case .status: return try NativeScalarJSON.encode([format, "status"])
        case .endpoint: return try NativeScalarJSON.encode([format, "endpoint"])
        case .credential(let role): return try NativeScalarJSON.encode([format, "credential", role.rawValue])
        case .accessChange(let change): return try NativeTargetWire.change(change)
        case .accessStatus(let original, let operation): return try NativeTargetWire.status(original: original, operation: operation)
        case .recover(let original):
            guard original.valid else { throw NativeSetupWireError.invalidRecord }
            let receipt = original.receipt
            return try NativeScalarJSON.encode([format, "recover", receipt.deployment, receipt.owner,
                                                receipt.epoch, receipt.role.rawValue, original.verifier, receipt.revision])
        }
    }

    static func request(_ body: Data) throws -> NativeBrokerRequest {
        if let change = try? NativeTargetWire.change(body) { return .accessChange(change) }
        if let (original, operation) = try? NativeTargetWire.status(body) { return .accessStatus(original, operation) }
        let values = try NativeScalarJSON.decode(body)
        guard values[0] as? String == format else { throw NativeSetupWireError.invalidRecord }
        if values.count == 2 && values[1] as? String == "status" { return .status }
        if values.count == 2 && values[1] as? String == "endpoint" { return .endpoint }
        if values.count == 8, values[1] as? String == "recover" {
            guard let deployment = values[2] as? String, let owner = values[3] as? String,
                  let epoch = NativeScalarJSON.integer(values[4], minimum: 1),
                  let roleName = values[5] as? String, let role = NativeCustodyRole(rawValue: roleName),
                  let verifier = values[6] as? String, let revision = NativeScalarJSON.integer(values[7], minimum: 1) else {
                throw NativeSetupWireError.invalidRecord
            }
            let receipt = NativeCreationReceipt(deployment: deployment, owner: owner, epoch: epoch, role: role,
                                                principal: NativeCoreWire.principal(epoch, role), revision: revision)
            let original = NativeOriginalReference(receipt: receipt, verifier: verifier)
            guard original.valid else { throw NativeSetupWireError.invalidRecord }
            return .recover(original)
        }
        guard values.count == 3, values[1] as? String == "credential",
              let raw = values[2] as? String, let role = NativeCustodyRole(rawValue: raw) else {
            throw NativeSetupWireError.invalidRecord
        }
        return .credential(role)
    }

    static func status(_ scope: NativeControllerScope) throws -> Data {
        guard NativeCoreWire.valid(scope) else { throw NativeSetupWireError.invalidRecord }
        return try NativeScalarJSON.encode([format, "status", scope.deployment, scope.owner, scope.epoch, scope.revision])
    }

    static func endpoint(_ metadata: NativeCoreEndpointMetadata) throws -> Data {
        let scope = metadata.scope
        guard NativeCoreWire.valid(scope), metadata.auditToken.count == 32 else { throw NativeSetupWireError.invalidRecord }
        return try NativeScalarJSON.encode([format, "endpoint", scope.deployment, scope.owner, scope.epoch,
                                            scope.revision, base64url(metadata.auditToken)])
    }

    static func endpoint(_ body: Data) throws -> NativeCoreEndpointMetadata {
        let values = try NativeScalarJSON.decode(body)
        guard values.count == 7, values[0] as? String == format, values[1] as? String == "endpoint",
              let deployment = values[2] as? String, NativeCoreWire.digest(deployment),
              let owner = values[3] as? String, NativeCoreWire.digest(owner),
              let epoch = NativeScalarJSON.integer(values[4], minimum: 1),
              let revision = NativeScalarJSON.integer(values[5], minimum: 0),
              let encoded = values[6] as? String, encoded.utf8.count == 43,
              let bytes = Data(base64Encoded: encoded.replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/") + "="),
              bytes.count == 32, base64url(bytes) == encoded else { throw NativeSetupWireError.invalidRecord }
        return NativeCoreEndpointMetadata(scope: NativeControllerScope(deployment: deployment, owner: owner,
            epoch: epoch, revision: revision), auditToken: bytes)
    }

    static func status(_ body: Data) throws -> NativeControllerScope {
        let values = try NativeScalarJSON.decode(body)
        guard values.count == 6, values[0] as? String == format, values[1] as? String == "status",
              let deployment = values[2] as? String, NativeCoreWire.digest(deployment),
              let owner = values[3] as? String, NativeCoreWire.digest(owner),
              let epoch = NativeScalarJSON.integer(values[4], minimum: 1),
              let revision = NativeScalarJSON.integer(values[5], minimum: 0) else {
            throw NativeSetupWireError.invalidRecord
        }
        return NativeControllerScope(deployment: deployment, owner: owner, epoch: epoch, revision: revision)
    }

    // Inert encoding/decoding never authenticates a socket or opens Keychain.
    static func credential(_ record: NativeCredentialRecord) throws -> Data {
        let receipt = record.receipt
        guard NativeCoreWire.digest(receipt.deployment), NativeCoreWire.digest(receipt.owner),
              receipt.epoch >= 1, receipt.revision >= 1,
              receipt.principal == NativeCoreWire.principal(receipt.epoch, receipt.role), record.bytes.count == 32 else {
            throw NativeSetupWireError.invalidRecord
        }
        return try NativeScalarJSON.encode([format, "credential", receipt.deployment, receipt.owner,
                                           receipt.epoch, receipt.role.rawValue, receipt.principal, receipt.revision,
                                           base64url(record.bytes)])
    }

    static func credential(_ body: Data, role: NativeCustodyRole) throws -> NativeCredentialRecord {
        let values = try NativeScalarJSON.decode(body)
        guard values.count == 9, values[0] as? String == format, values[1] as? String == "credential",
              let deployment = values[2] as? String, NativeCoreWire.digest(deployment),
              let owner = values[3] as? String, NativeCoreWire.digest(owner),
              let epoch = NativeScalarJSON.integer(values[4], minimum: 1), values[5] as? String == role.rawValue,
              values[6] as? String == NativeCoreWire.principal(epoch, role),
              let revision = NativeScalarJSON.integer(values[7], minimum: 1),
              let encoded = values[8] as? String, encoded.utf8.count == 43,
              let bytes = Data(base64Encoded: encoded.replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/") + "="),
              bytes.count == 32, base64url(bytes) == encoded else { throw NativeSetupWireError.invalidRecord }
        let receipt = NativeCreationReceipt(deployment: deployment, owner: owner, epoch: epoch, role: role,
                                             principal: NativeCoreWire.principal(epoch, role), revision: revision)
        return NativeCredentialRecord(receipt: receipt, bytes: bytes)
    }

    static func error(_ reason: String) throws -> Data {
        guard reasons.contains(reason) else { throw NativeSetupWireError.invalidRecord }
        return try NativeScalarJSON.encode([format, "error", reason])
    }

    static func error(_ body: Data) throws -> String {
        let values = try NativeScalarJSON.decode(body)
        guard values.count == 3, values[0] as? String == format, values[1] as? String == "error",
              let reason = values[2] as? String, reasons.contains(reason) else { throw NativeSetupWireError.invalidRecord }
        return reason
    }

    private static func base64url(_ bytes: Data) -> String {
        bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

// This profile's strings are fixed ASCII vocabulary, hex IDs and base64url.
// Escapes/whitespace are alternate encodings. Screen structure, member count,
// strings and integers before Foundation allocates a parsed JSON container.
enum NativeScalarJSON {
    static func decode(_ bytes: Data) throws -> [Any] {
        guard bytes.count >= 2, bytes.count <= 4096, bytes.first == 91, bytes.last == 93 else {
            throw NativeSetupWireError.invalidRecord
        }
        var depth = 0
        var quoted = false
        var length = 0
        var commas = 0
        for byte in bytes {
            if quoted {
                if byte == 34 { quoted = false; length = 0 }
                else {
                    guard byte >= 32, byte <= 126, byte != 92, length < 128 else { throw NativeSetupWireError.invalidRecord }
                    length += 1
                }
            } else {
                switch byte {
                case 91:
                    guard depth == 0 else { throw NativeSetupWireError.invalidRecord }
                    depth = 1
                case 93: depth -= 1
                case 34: quoted = true; length = 0
                case 44:
                    commas += 1; length = 0
                    guard commas < 9 else { throw NativeSetupWireError.invalidRecord }
                case 48...57:
                    length += 1
                    guard length <= 19 else { throw NativeSetupWireError.invalidRecord }
                default: throw NativeSetupWireError.invalidRecord
                }
            }
        }
        guard !quoted, depth == 0,
              let values = try? JSONSerialization.jsonObject(with: bytes) as? [Any],
              values.count >= 2, values.count <= 9,
              try encode(values) == bytes else { throw NativeSetupWireError.invalidRecord }
        return values
    }

    static func encode(_ values: [Any]) throws -> Data {
        guard values.count >= 2, values.count <= 9, values.allSatisfy({ value in
            if let string = value as? String {
                return string.utf8.count <= 128 && string.utf8.allSatisfy { $0 >= 32 && $0 <= 126 && $0 != 34 && $0 != 92 }
            }
            return integer(value, minimum: 0) != nil
        }) else { throw NativeSetupWireError.invalidRecord }
        let bytes = try JSONSerialization.data(withJSONObject: values, options: [.withoutEscapingSlashes])
        guard bytes.count <= 4096 else { throw NativeSetupWireError.invalidRecord }
        return bytes
    }

    static func integer(_ value: Any, minimum: Int64) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              ["c", "s", "i", "l", "q", "C", "S", "I", "L", "Q"].contains(String(cString: number.objCType)),
              number.int64Value >= minimum, number.uint64Value <= UInt64(Int64.max) else { return nil }
        return number.int64Value
    }
}
