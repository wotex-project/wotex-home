import CoreFoundation
import CryptoKit
import Foundation

struct HomeExplicitPowerRule: Equatable, Sendable {
    let id: String
    let sourceRevision: Int64
    let target: String
    let on: Bool
    var valid: Bool { NativeRuleOperationWire.identifier(id) && sourceRevision >= 0 && NativeRuleOperationWire.identifier(target) }
    func source() throws -> [String: Any] {
        guard valid else { throw NativeRuleOperationError.invalidRecord }
        return ["version": 1, "id": id, "source_revision": sourceRevision,
            "trigger": ["kind": "explicit_request"], "predicate": ["op": "literal_true"],
            "effect": ["target_id": target, "capability_key": "power", "value": ["type": "boolean", "value": on]],
            "authority_class": "automation", "unknown_policy": "block", "ownership_ms": 1, "cooldown_ms": 0, "causal_budget": 1]
    }
}

enum NativeRuleOperationError: LocalizedError {
    case invalidRecord
    var errorDescription: String? { "Home could not verify the original explicit rule operation." }
}

// Inert, closed correspondence. Source construction cannot supply proof,
// admission, an active generation, a clock or device authority.
enum HomeExplicitRuleOperation: Equatable, Sendable {
    case review(epoch: Int64, operation: String, expected: Int64, rule: HomeExplicitPowerRule)
    case admit(epoch: Int64, operation: String, expected: Int64, rule: HomeExplicitPowerRule)
    case activate(epoch: Int64, operation: String, expected: Int64, admission: Int64)
    case invoke(epoch: Int64, operation: String, generation: Int64, ruleID: String)
    var kind: String {
        switch self { case .review: "review"; case .admit: "admit"; case .activate: "activate"; case .invoke: "invoke" }
    }
    var epoch: Int64 {
        switch self { case .review(let e, _, _, _), .admit(let e, _, _, _), .activate(let e, _, _, _), .invoke(let e, _, _, _): e }
    }
    var operationID: String {
        switch self { case .review(_, let o, _, _), .admit(_, let o, _, _), .activate(_, let o, _, _), .invoke(_, let o, _, _): o }
    }
    var expectedRevision: Int64? {
        switch self { case .review(_, _, let r, _), .admit(_, _, let r, _), .activate(_, _, let r, _): r; case .invoke: nil }
    }
    var rule: HomeExplicitPowerRule? { switch self { case .review(_, _, _, let r), .admit(_, _, _, let r): r; default: nil } }
}

enum NativeRuleOperationWire {
    static let format = "wotex-home.explicit-rule-operation.v1"
    static func identifier(_ value: String) -> Bool {
        func alpha(_ b: UInt8) -> Bool { (48...57).contains(b) || (65...90).contains(b) || (97...122).contains(b) }
        let bytes = value.utf8
        return (1...128).contains(bytes.count) && bytes.first.map(alpha) == true && bytes.allSatisfy { alpha($0) || [46,95,58,45].contains($0) }
    }
    static func record(_ input: HomeExplicitRuleOperation) throws -> [Any] {
        guard input.epoch > 0, identifier(input.operationID) else { throw NativeRuleOperationError.invalidRecord }
        var values: [Any] = [format, input.kind, input.epoch, input.operationID]
        switch input {
        case .review(_, _, let expected, let rule), .admit(_, _, let expected, let rule):
            guard (0..<Int64.max).contains(expected), rule.valid else { throw NativeRuleOperationError.invalidRecord }
            values += [expected, rule.id, rule.sourceRevision, rule.target, rule.on]
        case .activate(_, _, let expected, let admission):
            guard (0..<Int64.max).contains(expected), (0...expected).contains(admission) else { throw NativeRuleOperationError.invalidRecord }
            values += [expected, admission]
        case .invoke(_, _, let generation, let ruleID):
            guard generation > 0, identifier(ruleID) else { throw NativeRuleOperationError.invalidRecord }
            values += [generation, ruleID]
        }
        return values
    }
    static func encode(_ input: HomeExplicitRuleOperation) throws -> Data {
        try JSONSerialization.data(withJSONObject: record(input), options: [.withoutEscapingSlashes])
    }
    static func digest(_ input: HomeExplicitRuleOperation) throws -> String {
        SHA256.hash(data: try encode(input)).map { String(format: "%02x", $0) }.joined()
    }
    static func decode(_ bytes: Data) throws -> HomeExplicitRuleOperation {
        guard (2...4096).contains(bytes.count), bytes.first == 91, bytes.last == 93 else { throw NativeRuleOperationError.invalidRecord }
        // Bound allocation before Foundation parses: one flat array, nine
        // members, printable unescaped ASCII strings, nineteen-byte atoms.
        var quoted = false, length = 0, commas = 0, depth = 0
        for byte in bytes {
            if quoted {
                if byte == 34 { quoted = false; length = 0 }
                else { guard (32...126).contains(byte), byte != 92, length < 128 else { throw NativeRuleOperationError.invalidRecord }; length += 1 }
            } else {
                switch byte {
                case 91: guard depth == 0 else { throw NativeRuleOperationError.invalidRecord }; depth = 1
                case 93: depth -= 1
                case 34: quoted = true; length = 0
                case 44: commas += 1; length = 0; guard commas < 9 else { throw NativeRuleOperationError.invalidRecord }
                case 48...57, 97, 101, 102, 108, 114, 115, 116, 117:
                    length += 1; guard length <= 19 else { throw NativeRuleOperationError.invalidRecord }
                default: throw NativeRuleOperationError.invalidRecord
                }
            }
        }
        guard !quoted, depth == 0, let values = try? JSONSerialization.jsonObject(with: bytes) as? [Any],
              values.count == 6 || values.count == 9, values[0] as? String == format,
              let kind = values[1] as? String, let epoch = integer(values[2]), let operation = values[3] as? String,
              let basis = integer(values[4]) else { throw NativeRuleOperationError.invalidRecord }
        let result: HomeExplicitRuleOperation
        switch (kind, values.count) {
        case ("review", 9), ("admit", 9):
            guard let id = values[5] as? String, let source = integer(values[6]), let target = values[7] as? String,
                  let value = values[8] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { throw NativeRuleOperationError.invalidRecord }
            let rule = HomeExplicitPowerRule(id: id, sourceRevision: source, target: target, on: value.boolValue)
            result = kind == "review" ? .review(epoch: epoch, operation: operation, expected: basis, rule: rule) : .admit(epoch: epoch, operation: operation, expected: basis, rule: rule)
        case ("activate", 6):
            guard let admission = integer(values[5]) else { throw NativeRuleOperationError.invalidRecord }
            result = .activate(epoch: epoch, operation: operation, expected: basis, admission: admission)
        case ("invoke", 6):
            guard let rule = values[5] as? String else { throw NativeRuleOperationError.invalidRecord }
            result = .invoke(epoch: epoch, operation: operation, generation: basis, ruleID: rule)
        default: throw NativeRuleOperationError.invalidRecord
        }
        guard try encode(result) == bytes else { throw NativeRuleOperationError.invalidRecord }
        return result
    }
    private static func integer(_ value: Any) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              !["f", "d"].contains(String(cString: number.objCType)), let result = value as? Int64, result >= 0 else { return nil }
        return result
    }
}
