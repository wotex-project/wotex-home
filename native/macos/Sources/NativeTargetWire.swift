import CryptoKit
import Foundation

struct NativeTargetBasis: Equatable, Sendable {
    let resource: Int64
    let binding: Int64
    let generation: Int64
    let artifact: String
}

struct NativeTargetChange: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    enum Action: String, Sendable { case grant, revoke }
    let original: NativeOriginalReference
    let operation: String
    let expectedRevision: Int64
    let target: String
    let action: Action
    let basis: NativeTargetBasis?
    var description: String { "private_native_target_change" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
}

struct NativeTargetReceipt: Equatable, Sendable {
    let deployment: String
    let owner: String
    let epoch: Int64
    let principal: String
    let operation: String
    let action: NativeTargetChange.Action
    let target: String
    let inputDigest: String
    let expectedRevision: Int64
    let changeRevision: Int64
    let finalRevision: Int64
    let affected: Int64
    let unknown: Int64
}

enum NativeTargetReply: Equatable, Sendable {
    case receipt(NativeTargetReceipt), notFound, rejected(String)
}

// Inert correspondence only. OS peer seals, existing Keychain custody and
// original pending publication must precede delivery through the broker.
enum NativeTargetWire {
    static let format = "wotex-home.native-target-access.v1"
    static let reasons: Set<String> = [
        "invalid_native_target_record", "native_owner_changed", "native_custody_conflict",
        "native_target_unavailable", "native_target_changed", "native_target_exists",
        "native_target_missing", "native_target_capacity", "native_operation_conflict",
        "revision_conflict", "maintenance_active", "source_retired", "outcome_unknown",
    ]

    static func change(_ value: NativeTargetChange) throws -> Data {
        let original = value.original
        guard original.valid, original.receipt.role == .operator,
              identifier(value.operation), identifier(value.target),
              value.expectedRevision >= original.receipt.revision,
              value.expectedRevision < Int64.max else { throw NativeSetupWireError.invalidRecord }
        var fields = originalFields(original, kind: value.action.rawValue)
        fields += [value.operation, value.expectedRevision, value.target]
        switch value.action {
        case .grant:
            guard let basis = value.basis, basis.resource >= 1, basis.binding >= 1,
                  basis.generation >= 1, NativeCoreWire.digest(basis.artifact) else { throw NativeSetupWireError.invalidRecord }
            fields += [basis.resource, basis.binding, basis.generation, basis.artifact]
        case .revoke:
            guard value.basis == nil else { throw NativeSetupWireError.invalidRecord }
        }
        return try NativeTargetScalars.encode(fields)
    }

    static func change(_ bytes: Data) throws -> NativeTargetChange {
        let fields = try NativeTargetScalars.decode(bytes)
        guard fields.count == 10 || fields.count == 14, fields[0] as? String == format,
              let kind = fields[1] as? String, let action = NativeTargetChange.Action(rawValue: kind),
              let original = original(fields), let operation = fields[7] as? String,
              let expected = NativeScalarJSON.integer(fields[8], minimum: 1),
              let target = fields[9] as? String else { throw NativeSetupWireError.invalidRecord }
        let basis: NativeTargetBasis?
        if action == .grant {
            guard fields.count == 14,
                  let resource = NativeScalarJSON.integer(fields[10], minimum: 1),
                  let binding = NativeScalarJSON.integer(fields[11], minimum: 1),
                  let generation = NativeScalarJSON.integer(fields[12], minimum: 1),
                  let artifact = fields[13] as? String else { throw NativeSetupWireError.invalidRecord }
            basis = NativeTargetBasis(resource: resource, binding: binding, generation: generation, artifact: artifact)
        } else {
            guard fields.count == 10 else { throw NativeSetupWireError.invalidRecord }
            basis = nil
        }
        let value = NativeTargetChange(original: original, operation: operation, expectedRevision: expected,
            target: target, action: action, basis: basis)
        guard try change(value) == bytes else { throw NativeSetupWireError.invalidRecord }
        return value
    }

    static func status(original: NativeOriginalReference, operation: String) throws -> Data {
        guard original.valid, original.receipt.role == .operator, identifier(operation) else { throw NativeSetupWireError.invalidRecord }
        return try NativeTargetScalars.encode(originalFields(original, kind: "status") + [operation])
    }

    static func status(_ bytes: Data) throws -> (NativeOriginalReference, String) {
        let fields = try NativeTargetScalars.decode(bytes)
        guard fields.count == 8, fields[0] as? String == format, fields[1] as? String == "status",
              let original = original(fields), let operation = fields[7] as? String,
              try status(original: original, operation: operation) == bytes else { throw NativeSetupWireError.invalidRecord }
        return (original, operation)
    }

    static func reply(_ bytes: Data, matching change: NativeTargetChange) throws -> NativeTargetReply {
        _ = try self.change(change)
        let result = try reply(bytes, original: change.original, operation: change.operation)
        if case .receipt(let receipt) = result {
            guard receipt.action == change.action, receipt.target == change.target,
                  receipt.expectedRevision == change.expectedRevision,
                  receipt.inputDigest == digest(try self.change(change)) else { throw NativeSetupWireError.invalidRecord }
        }
        return result
    }

    static func reply(_ bytes: Data, original reference: NativeOriginalReference, operation: String) throws -> NativeTargetReply {
        _ = try status(original: reference, operation: operation)
        let fields = try NativeTargetScalars.decode(bytes)
        guard fields[0] as? String == format, let kind = fields[1] as? String else { throw NativeSetupWireError.invalidRecord }
        if kind == "error" {
            guard fields.count == 3, let reason = fields[2] as? String, reasons.contains(reason) else { throw NativeSetupWireError.invalidRecord }
            return .rejected(reason)
        }
        if kind == "not_found" {
            let expected = originalFields(reference, kind: "not_found") + [operation]
            guard try NativeTargetScalars.encode(expected) == bytes else { throw NativeSetupWireError.invalidRecord }
            return .notFound
        }
        let original = reference.receipt
        guard kind == "receipt", fields.count == 15,
              fields[2] as? String == original.deployment, fields[3] as? String == original.owner,
              NativeScalarJSON.integer(fields[4], minimum: 1) == original.epoch,
              fields[5] as? String == original.principal, fields[6] as? String == operation,
              let actionName = fields[7] as? String, let action = NativeTargetChange.Action(rawValue: actionName),
              let target = fields[8] as? String, identifier(target),
              let digest = fields[9] as? String, NativeCoreWire.digest(digest),
              let expected = NativeScalarJSON.integer(fields[10], minimum: original.revision), expected < Int64.max,
              let revision = NativeScalarJSON.integer(fields[11], minimum: 2), revision == expected + 1,
              let final = NativeScalarJSON.integer(fields[12], minimum: 2),
              let affected = NativeScalarJSON.integer(fields[13], minimum: 0), affected <= 1024,
              let unknown = NativeScalarJSON.integer(fields[14], minimum: 0), unknown <= affected else { throw NativeSetupWireError.invalidRecord }
        let (expectedFinal, overflow) = revision.addingReportingOverflow(affected)
        guard !overflow, final == expectedFinal else { throw NativeSetupWireError.invalidRecord }
        return .receipt(NativeTargetReceipt(deployment: original.deployment, owner: original.owner,
            epoch: original.epoch, principal: original.principal, operation: operation,
            action: action, target: target, inputDigest: digest,
            expectedRevision: expected, changeRevision: revision, finalRevision: final,
            affected: affected, unknown: unknown))
    }

    static func digest(_ bytes: Data) -> String { NativeCoreWire.hex(Data(SHA256.hash(data: bytes))) }

    static func verify(_ value: NativeTargetReply, matching change: NativeTargetChange) throws {
        switch value {
        case .receipt(let receipt):
            let fields: [Any] = [format, "receipt", receipt.deployment, receipt.owner, receipt.epoch, receipt.principal,
                receipt.operation, receipt.action.rawValue, receipt.target, receipt.inputDigest, receipt.expectedRevision,
                receipt.changeRevision, receipt.finalRevision, receipt.affected, receipt.unknown]
            guard try reply(NativeTargetScalars.encode(fields), matching: change) == value else { throw NativeSetupWireError.invalidRecord }
        case .notFound: _ = try self.change(change)
        case .rejected(let reason):
            guard reasons.contains(reason) else { throw NativeSetupWireError.invalidRecord }
            _ = try self.change(change)
        }
    }

    private static func originalFields(_ original: NativeOriginalReference, kind: String) -> [Any] {
        let value = original.receipt
        return [format, kind, value.deployment, value.owner, value.epoch, value.revision, original.verifier]
    }

    private static func original(_ fields: [Any]) -> NativeOriginalReference? {
        guard fields.count >= 7, let deployment = fields[2] as? String, let owner = fields[3] as? String,
              let epoch = NativeScalarJSON.integer(fields[4], minimum: 1),
              let creation = NativeScalarJSON.integer(fields[5], minimum: 1), let verifier = fields[6] as? String else { return nil }
        let receipt = NativeCreationReceipt(deployment: deployment, owner: owner, epoch: epoch, role: .operator,
            principal: NativeCoreWire.principal(epoch, .operator), revision: creation)
        let original = NativeOriginalReference(receipt: receipt, verifier: verifier)
        return original.valid ? original : nil
    }

    static func identifier(_ value: String) -> Bool {
        let bytes = value.utf8
        func alphanumeric(_ byte: UInt8) -> Bool { (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) }
        guard bytes.count >= 1, bytes.count <= 128, let first = bytes.first, alphanumeric(first) else { return false }
        return bytes.allSatisfy { alphanumeric($0) || [46,95,58,45].contains($0) }
    }
}

// Separate sixteen-member profile; the existing nine-member setup/broker
// scanner retains its original bounds and records.
private enum NativeTargetScalars {
    static func decode(_ bytes: Data) throws -> [Any] {
        guard bytes.count >= 2, bytes.count <= 4096, bytes.first == 91, bytes.last == 93 else { throw NativeSetupWireError.invalidRecord }
        var depth = 0, length = 0, commas = 0
        var quoted = false
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
                    guard commas < 16 else { throw NativeSetupWireError.invalidRecord }
                case 48...57:
                    length += 1
                    guard length <= 19 else { throw NativeSetupWireError.invalidRecord }
                default: throw NativeSetupWireError.invalidRecord
                }
            }
        }
        guard !quoted, depth == 0, let values = try? JSONSerialization.jsonObject(with: bytes) as? [Any],
              try encode(values) == bytes else { throw NativeSetupWireError.invalidRecord }
        return values
    }

    static func encode(_ values: [Any]) throws -> Data {
        guard values.count >= 2, values.count <= 16, values.allSatisfy({ value in
            if let string = value as? String {
                return string.utf8.count <= 128 && string.utf8.allSatisfy { $0 >= 32 && $0 <= 126 && $0 != 34 && $0 != 92 }
            }
            return NativeScalarJSON.integer(value, minimum: 0) != nil
        }) else { throw NativeSetupWireError.invalidRecord }
        let bytes = try JSONSerialization.data(withJSONObject: values, options: [.withoutEscapingSlashes])
        guard bytes.count <= 4096 else { throw NativeSetupWireError.invalidRecord }
        return bytes
    }
}
