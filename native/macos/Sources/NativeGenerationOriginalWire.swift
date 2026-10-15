import Foundation
import CoreFoundation

enum HomeGenerationOriginalKind: String, CaseIterable, Sendable {
    case preparation, attempt
    var format: String { "wotex-home.generation-\(rawValue).v1" }
    var maximum: Int { self == .preparation ? 32768 : 2048 }
    var nativeMaximum: Int { self == .preparation ? 131072 : 8192 }
}

struct HomeGenerationOriginal: Sendable, Equatable, CustomReflectable {
    let kind: HomeGenerationOriginalKind, epoch: Int64, operation: String, expectedRevision: Int64
    let canonical: Data
    var sha: String { LocalHealthClient.profileSHA(canonical) }
    var customMirror: Mirror { Mirror(self, children: ["kind": kind.rawValue, "epoch": epoch, "operation": operation]) }
    fileprivate init(kind: HomeGenerationOriginalKind, epoch: Int64, operation: String, revision: Int64, canonical: Data) {
        self.kind = kind; self.epoch = epoch; self.operation = operation; self.expectedRevision = revision; self.canonical = canonical
    }
    func fields() throws -> [String: Any] {
        let (checked, fields) = try NativeGenerationOriginalWire.checked(canonical, kind: kind)
        guard checked == self else { throw LocalHealthError.invalidProfileRequest }; return fields
    }
}

struct HomeGenerationReservation: Sendable, Equatable {
    let kind: HomeGenerationOriginalKind, epoch: Int64, operation: String, revision: Int64
    let inputSHA: String, providerSHA: String, policySHA: String?, preparationSHA: String?, attempt: Int?
    let canonical: Data
    var disposition: String { kind == .preparation ? "prepared" : "handoff_reserved" }
    fileprivate init(kind: HomeGenerationOriginalKind, epoch: Int64, operation: String, revision: Int64,
                     inputSHA: String, providerSHA: String, policySHA: String?, preparationSHA: String?, attempt: Int?, canonical: Data) {
        self.kind = kind; self.epoch = epoch; self.operation = operation; self.revision = revision
        self.inputSHA = inputSHA; self.providerSHA = providerSHA; self.policySHA = policySHA
        self.preparationSHA = preparationSHA; self.attempt = attempt; self.canonical = canonical
    }
    func matches(_ original: HomeGenerationOriginal) throws {
        guard try NativeGenerationOriginalWire.decodeReservation(canonical, kind: kind) == self else { throw LocalHealthError.invalidResponse }
        let fields = try original.fields()
        guard kind == original.kind, epoch == original.epoch, operation == original.operation,
              original.expectedRevision < Int64.max, revision == original.expectedRevision + 1,
              inputSHA == original.sha else { throw LocalHealthError.invalidResponse }
        if kind == .preparation {
            guard providerSHA == fields["provider_sha256"] as? String, policySHA == fields["policy_sha256"] as? String else { throw LocalHealthError.invalidResponse }
        } else {
            guard preparationSHA == fields["preparation_sha256"] as? String,
                  attempt == LocalHealthClient.profileInteger(fields["attempt"]) else { throw LocalHealthError.invalidResponse }
        }
    }
}

enum NativeGenerationOriginalWire {
    private static let projectionKeys = ["contract_digest", "instruction", "passages", "examples", "limits"]
    private static let limitKeys = ["max_passages", "max_passage_bytes", "max_passages_bytes", "max_examples", "max_examples_bytes", "max_input_bytes"]
    private static let ceilings: [Int64] = [32, 4096, 131072, 32, 262144, 1048576]
    private static let preparationKeys = ["authority_epoch", "operation_id", "expected_revision", "provider_sha256", "policy_sha256", "remote_export", "projection", "budget"]
    private static let attemptKeys = ["authority_epoch", "operation_id", "expected_revision", "preparation_operation_id", "preparation_sha256", "attempt", "previous_operation_id", "repair_export"]
    private static let preparationReceipt = ["authority_epoch", "operation_id", "revision", "input_sha256", "projection_sha256", "basis_sha256", "provider_sha256", "policy_sha256", "disposition"]
    private static let attemptReceipt = ["authority_epoch", "operation_id", "revision", "input_sha256", "preparation_sha256", "attempt", "handoff_sha256", "provider_sha256", "disposition"]

    static func nativeJSON(_ bytes: Data, kind: HomeGenerationOriginalKind) throws -> HomeGenerationOriginal {
        guard (1...kind.nativeMaximum).contains(bytes.count) else { throw LocalHealthError.invalidProfileRequest }
        try StrictLocalJSON.check(bytes)
        guard let input = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw LocalHealthError.invalidProfileRequest }
        return try encode(input, kind: kind)
    }
    static func encode(_ input: [String: Any], kind: HomeGenerationOriginalKind) throws -> HomeGenerationOriginal {
        let keys = kind == .preparation ? preparationKeys : attemptKeys
        guard exact(input, keys), let epoch = integer(input["authority_epoch"], minimum: 1),
              let revision = integer(input["expected_revision"], minimum: 0), let operation = id(input["operation_id"]) else { throw LocalHealthError.invalidProfileRequest }
        var values: [Any] = [epoch, operation, revision]
        if kind == .preparation {
            guard let provider = digest(input["provider_sha256"]), let policy = digest(input["policy_sha256"]),
                  let remote = boolean(input["remote_export"]),
                  let projection = input["projection"] as? [String: Any], let budget = input["budget"] as? [String: Any],
                  exact(budget, ["attempts", "attempt_ms", "total_ms"]),
                  let attempts = boundedInteger(budget["attempts"], maximum: 3),
                  let attemptMS = boundedInteger(budget["attempt_ms"], maximum: 30000),
                  let totalMS = boundedInteger(budget["total_ms"], maximum: 120000), attemptMS <= totalMS else { throw LocalHealthError.invalidProfileRequest }
            values += [provider, policy, remote, try projectionValues(projection), [attempts, attemptMS, totalMS]]
        } else {
            guard let preparation = id(input["preparation_operation_id"]), let sha = digest(input["preparation_sha256"]),
                  let attempt = boundedInteger(input["attempt"], maximum: 3), let repair = boolean(input["repair_export"]) else { throw LocalHealthError.invalidProfileRequest }
            let previous: Any
            if attempt == 1 {
                guard input["previous_operation_id"] is NSNull, repair == false else { throw LocalHealthError.invalidProfileRequest }
                previous = NSNull()
            } else {
                guard let value = id(input["previous_operation_id"]), repair == true else { throw LocalHealthError.invalidProfileRequest }
                previous = value
            }
            values += [preparation, sha, attempt, previous, repair]
        }
        let canonical = try JSONSerialization.data(withJSONObject: [kind.format, values], options: [.withoutEscapingSlashes])
        guard canonical.count <= kind.maximum else { throw LocalHealthError.invalidProfileRequest }
        return HomeGenerationOriginal(kind: kind, epoch: epoch, operation: operation, revision: revision, canonical: canonical)
    }
    static func decode(_ bytes: Data, kind: HomeGenerationOriginalKind) throws -> HomeGenerationOriginal {
        try checked(bytes, kind: kind).0
    }
    fileprivate static func checked(_ bytes: Data, kind: HomeGenerationOriginalKind) throws -> (HomeGenerationOriginal, [String: Any]) {
        guard (1...kind.maximum).contains(bytes.count) else { throw LocalHealthError.invalidProfileRequest }
        try StrictLocalJSON.check(bytes)
        guard let root = try JSONSerialization.jsonObject(with: bytes) as? [Any], root.count == 2,
              root[0] as? String == kind.format, let values = root[1] as? [Any], values.count == 8 else { throw LocalHealthError.invalidProfileRequest }
        var input = map(kind == .preparation ? preparationKeys : attemptKeys, values)
        if kind == .preparation {
            guard let projection = values[6] as? [Any], projection.count == 5,
                  let passages = projection[2] as? [Any], passages.count <= 32,
                  let examples = projection[3] as? [Any], examples.count <= 32,
                  let limits = projection[4] as? [Any], limits.count == 6,
                  let budget = values[7] as? [Any], budget.count == 3 else { throw LocalHealthError.invalidProfileRequest }
            let nativePassages = try passages.map { raw -> [String: Any] in
                guard let row = raw as? [Any], row.count == 4 else { throw LocalHealthError.invalidProfileRequest }
                return ["reference": map(["object_digest", "first_revision"], Array(row.prefix(2))), "offset": row[2], "length": row[3]]
            }
            let nativeExamples = try examples.map { raw -> [String: Any] in
                guard let row = raw as? [Any], row.count == 2 else { throw LocalHealthError.invalidProfileRequest }
                return map(["object_digest", "first_revision"], row)
            }
            input["projection"] = ["contract_digest": projection[0], "instruction": projection[1], "passages": nativePassages,
                                   "examples": nativeExamples, "limits": map(limitKeys, limits)]
            input["budget"] = map(["attempts", "attempt_ms", "total_ms"], budget)
        }
        let original = try encode(input, kind: kind)
        guard original.canonical == bytes else { throw LocalHealthError.invalidProfileRequest }
        return (original, input)
    }
    static func reservation(_ fields: [String: Any], kind: HomeGenerationOriginalKind) throws -> HomeGenerationReservation {
        do {
            let keys = kind == .preparation ? preparationReceipt : attemptReceipt
            guard exact(fields, keys), let epoch = integer(fields["authority_epoch"], minimum: 1),
                  let revision = integer(fields["revision"], minimum: 1), let operation = id(fields["operation_id"]),
                  let input = digest(fields["input_sha256"]), let provider = digest(fields["provider_sha256"]),
                  fields["disposition"] as? String == (kind == .preparation ? "prepared" : "handoff_reserved") else { throw LocalHealthError.invalidResponse }
            var policy: String?, preparation: String?, attempt: Int?
            if kind == .preparation {
                guard digest(fields["projection_sha256"]) != nil, digest(fields["basis_sha256"]) != nil,
                      let selected = digest(fields["policy_sha256"]) else { throw LocalHealthError.invalidResponse }
                policy = selected
            } else {
                guard let selected = digest(fields["preparation_sha256"]), digest(fields["handoff_sha256"]) != nil,
                      let index = boundedInteger(fields["attempt"], maximum: 3) else { throw LocalHealthError.invalidResponse }
                preparation = selected; attempt = Int(index)
            }
            let canonical = try JSONSerialization.data(withJSONObject: keys.map { fields[$0]! }, options: [.withoutEscapingSlashes])
            guard canonical.count <= 2048 else { throw LocalHealthError.invalidResponse }
            return HomeGenerationReservation(kind: kind, epoch: epoch, operation: operation, revision: revision, inputSHA: input,
                                             providerSHA: provider, policySHA: policy, preparationSHA: preparation, attempt: attempt, canonical: canonical)
        } catch { throw LocalHealthError.invalidResponse }
    }
    static func decodeReservation(_ bytes: Data, kind: HomeGenerationOriginalKind) throws -> HomeGenerationReservation {
        do {
            guard (1...2048).contains(bytes.count) else { throw LocalHealthError.invalidResponse }
            try StrictLocalJSON.check(bytes)
            guard let values = try JSONSerialization.jsonObject(with: bytes) as? [Any], values.count == 9 else { throw LocalHealthError.invalidResponse }
            let receipt = try reservation(map(kind == .preparation ? preparationReceipt : attemptReceipt, values), kind: kind)
            guard receipt.canonical == bytes else { throw LocalHealthError.invalidResponse }; return receipt
        } catch { throw LocalHealthError.invalidResponse }
    }

    private static func projectionValues(_ value: [String: Any]) throws -> [Any] {
        guard exact(value, projectionKeys), let contract = digest(value["contract_digest"]), let instruction = value["instruction"] as? String,
              instruction.utf8.count <= 4096,
              instruction.replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\t", with: "").range(of: "\\p{Cc}", options: .regularExpression) == nil,
              let passages = value["passages"] as? [[String: Any]], passages.count <= 32,
              let examples = value["examples"] as? [[String: Any]], examples.count <= 32,
              let limits = value["limits"] as? [String: Any], exact(limits, limitKeys) else { throw LocalHealthError.invalidProfileRequest }
        let selected = try zip(limitKeys, ceilings).map { key, ceiling -> Int64 in
            guard let selected = boundedInteger(limits[key], maximum: ceiling) else { throw LocalHealthError.invalidProfileRequest }; return selected
        }
        guard passages.count <= selected[0], examples.count <= selected[3] else { throw LocalHealthError.invalidProfileRequest }
        var firstRevisions: [String: Int64] = [:]
        var passageOrder: [(String, Int64, Int64)] = []
        var total: Int64 = 0
        let passageValues: [[Any]] = try passages.map { passage in
            guard exact(passage, ["reference", "offset", "length"]), let reference = passage["reference"] as? [String: Any],
                  let offset = integer(passage["offset"], minimum: 0), offset <= 262144,
                  let length = boundedInteger(passage["length"], maximum: selected[1]) else { throw LocalHealthError.invalidProfileRequest }
            let handle = try referenceValues(reference, revisions: &firstRevisions)
            passageOrder.append((handle[0] as! String, offset, length)); total += length
            return handle + [offset, length]
        }
        guard total <= selected[2], zip(passageOrder, passageOrder.dropFirst()).allSatisfy({ $0 < $1 }) else { throw LocalHealthError.invalidProfileRequest }
        let exampleValues = try examples.map { try referenceValues($0, revisions: &firstRevisions) }
        let exampleOrder = exampleValues.map { $0[0] as! String }
        guard zip(exampleOrder, exampleOrder.dropFirst()).allSatisfy({ $0 < $1 }) else { throw LocalHealthError.invalidProfileRequest }
        return [contract, instruction, passageValues, exampleValues, selected]
    }
    private static func referenceValues(_ value: [String: Any], revisions: inout [String: Int64]) throws -> [Any] {
        guard exact(value, ["object_digest", "first_revision"]), let sha = digest(value["object_digest"]),
              let revision = integer(value["first_revision"], minimum: 1), revisions[sha] == nil || revisions[sha] == revision else { throw LocalHealthError.invalidProfileRequest }
        revisions[sha] = revision; return [sha, revision]
    }
    private static func integer(_ value: Any?, minimum: Int64) -> Int64? {
        if let value, type(of: value) == Int64.self {
            let integer = value as! Int64
            return integer >= minimum ? integer : nil
        }
        guard let value = LocalHealthClient.profileInteger(value).map(Int64.init), value >= minimum else { return nil }; return value
    }
    private static func boundedInteger(_ value: Any?, maximum: Int64) -> Int64? {
        guard let value = integer(value, minimum: 1), value <= maximum else { return nil }; return value
    }
    private static func boolean(_ value: Any?) -> Bool? {
        guard let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }; return value.boolValue
    }
    private static func digest(_ value: Any?) -> String? { guard let value = value as? String, LocalHealthClient.profileDigest(value) else { return nil }; return value }
    private static func id(_ value: Any?) -> String? { guard let value = value as? String, LocalHealthClient.profileID(value) else { return nil }; return value }
    private static func exact(_ value: [String: Any], _ keys: [String]) -> Bool { Set(value.keys) == Set(keys) }
    private static func map(_ keys: [String], _ values: [Any]) -> [String: Any] { Dictionary(uniqueKeysWithValues: zip(keys, values)) }
}
