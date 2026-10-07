import CoreFoundation
import Foundation

enum NativePendingError: LocalizedError {
    case invalidRecord, unavailable, conflict, capacity, outcomeUnknown
    var errorDescription: String? {
        switch self {
        case .invalidRecord: "Home's pending operation journal contains an unsupported record."
        case .unavailable: "Home's private pending operation journal is unavailable."
        case .conflict: "Pending operations changed. Reload their original records before continuing."
        case .capacity: "Home cannot retain another pending operation. Resolve an original operation first."
        case .outcomeUnknown: "Saving the original operation is uncertain. Reload it before sending any request."
        }
    }
}

enum NativePendingCategory: String, CaseIterable, Sendable { case maintenance, override, power, profile, rule, access }

enum NativePendingRecoveryAction: Equatable, Sendable {
    case lookup, retry, cancelReview
    func permits(_ entry: NativePendingEntry) -> Bool {
        switch self {
        case .lookup: return true
        case .retry: return !entry.phase.isHeldReview
        case .cancelReview: return entry.phase.isHeldReview || entry.phase.isCancellation
        }
    }
}
enum NativePendingRecoveryOutcome: Sendable {
    case resolved(String), retained(String)
    case review(token: String, digest: String)
}

struct NativePendingContext: Equatable, Sendable {
    let deployment: String, owner: String, epoch: Int64, principal: String
    var valid: Bool {
        NativeCoreWire.digest(deployment) && NativeCoreWire.digest(owner) && epoch > 0 && LocalHealthClient.profileID(principal)
    }
    func matches(_ identity: HomeControllerIdentity) -> Bool {
        valid && deployment == identity.deploymentID && owner == identity.ownerID &&
            epoch == identity.authorityEpoch && principal == identity.principalID
    }
    fileprivate var values: [PendingValue] { [.string(deployment), .string(owner), .integer(epoch), .string(principal)] }
}

// These are custody references only. Neither variant contains a secret or seal.
enum NativePendingCustody: Equatable, Sendable, CustomReflectable {
    case manual(verifier: String)
    case native(role: NativeCustodyRole, creationRevision: Int64, verifier: String)
    var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
    var verifier: String {
        switch self { case .manual(let value), .native(_, _, let value): value }
    }
    func valid(context: NativePendingContext) -> Bool {
        guard context.valid, NativeCoreWire.digest(verifier) else { return false }
        switch self {
        case .manual: return !context.principal.hasPrefix("native-setup-v1:")
        case .native(let role, let revision, _):
            return revision > 0 && context.principal == NativeCoreWire.principal(context.epoch, role)
        }
    }
    func matches(_ bytes: Data) -> Bool { bytes.count == 32 && LocalHealthClient.profileSHA(bytes) == verifier }
    func nativeOriginal(context: NativePendingContext) throws -> NativeOriginalReference {
        guard valid(context: context), case .native(let role, let revision, let verifier) = self else {
            throw NativePendingError.invalidRecord
        }
        return NativeOriginalReference(receipt: NativeCreationReceipt(deployment: context.deployment, owner: context.owner,
            epoch: context.epoch, role: role, principal: context.principal, revision: revision), verifier: verifier)
    }
    fileprivate var values: [PendingValue] {
        switch self {
        case .manual(let verifier): [.string("manual"), .string(verifier)]
        case .native(let role, let revision, let verifier): [.string("native"), .string(role.rawValue), .integer(revision), .string(verifier)]
        }
    }
}

enum NativePendingInput: Equatable, Sendable {
    case power(operation: String, target: String, revision: Int64, on: Bool)
    case cancel(operation: String)
    case issueOverride(operation: String, target: String, revision: Int64, duration: Int64)
    case revokeOverride(operation: String)
    case suspend(operation: String, revision: Int64)
    case beginMaintenance(operation: String, revision: Int64)
    case endMaintenance(operation: String, revision: Int64, beginRevision: Int64)
    case profile(preparing: Bool, operation: HomeProfileOperation)
    case targetAccess(operation: String, revision: Int64, target: String, action: NativeTargetChange.Action, basis: NativeTargetBasis?)
    case explicitRule(HomeExplicitRuleOperation)
    var category: NativePendingCategory {
        switch self {
        case .power, .cancel: .power
        case .issueOverride, .revokeOverride: .override
        case .suspend, .explicitRule: .rule
        case .beginMaintenance, .endMaintenance: .maintenance
        case .profile: .profile
        case .targetAccess: .access
        }
    }
    var operationID: String {
        switch self {
        case .power(let operation, _, _, _), .cancel(let operation), .issueOverride(let operation, _, _, _),
             .revokeOverride(let operation), .suspend(let operation, _), .beginMaintenance(let operation, _),
             .endMaintenance(let operation, _, _): operation
        case .profile(_, let operation): operation.operationID
        case .targetAccess(let operation, _, _, _, _): operation
        case .explicitRule(let operation): operation.operationID
        }
    }
    fileprivate func values(context: NativePendingContext) throws -> [PendingValue] {
        guard LocalHealthClient.profileID(operationID) else { throw NativePendingError.invalidRecord }
        switch self {
        case .power(let operation, let target, let revision, let on):
            guard LocalHealthClient.profileID(target), revision >= 0 else { throw NativePendingError.invalidRecord }
            return [.string("submit"), .string(operation), .string(target), .integer(revision), .boolean(on)]
        case .cancel(let operation): return [.string("cancel"), .string(operation)]
        case .issueOverride(let operation, let target, let revision, let duration):
            guard LocalHealthClient.profileID(target), revision >= 0, (1...86_400_000).contains(duration) else { throw NativePendingError.invalidRecord }
            return [.string("override_issue"), .string(operation), .string(target), .integer(revision), .integer(duration)]
        case .revokeOverride(let operation): return [.string("override_revoke"), .string(operation)]
        case .suspend(let operation, let revision):
            guard revision >= 0, revision < Int64.max else { throw NativePendingError.invalidRecord }
            return [.string("activate_rule"), .string(operation), .integer(revision), .integer(0)]
        case .beginMaintenance(let operation, let revision):
            guard revision >= 0, revision <= Int64.max - 2 else { throw NativePendingError.invalidRecord }
            return [.string("begin_maintenance"), .string(operation), .integer(revision)]
        case .endMaintenance(let operation, let revision, let beginRevision):
            guard revision >= 1, revision < Int64.max, (1...revision).contains(beginRevision) else { throw NativePendingError.invalidRecord }
            return [.string("end_maintenance"), .string(operation), .integer(revision), .integer(beginRevision)]
        case .profile(let preparing, let operation):
            guard operation.authorityEpoch == context.epoch, !preparing || operation.action == "select" else { throw NativePendingError.invalidRecord }
            let fields = HomeProfileOperation.commonFields + (operation.action == "select" ? HomeProfileOperation.selectionFields :
                operation.action == "revoke_selection" ? HomeProfileOperation.revocationFields : [])
            let dictionary = try operation.fields()
            return [.string(preparing ? "profile_prepare" : "profile_change")] + (try fields.map { try PendingValue.scalar(dictionary[$0]!) })
        case .targetAccess(let operation, let revision, let target, let action, let basis):
            guard NativeTargetWire.identifier(target), revision >= 1, revision < Int64.max else { throw NativePendingError.invalidRecord }
            let common: [PendingValue] = [.string("native_target_" + action.rawValue), .string(operation), .integer(revision), .string(target)]
            if action == .revoke {
                guard basis == nil else { throw NativePendingError.invalidRecord }
                return common
            }
            guard let basis, basis.resource >= 1, basis.binding >= 1, basis.generation >= 1,
                  NativeCoreWire.digest(basis.artifact) else { throw NativePendingError.invalidRecord }
            return common + [.integer(basis.resource), .integer(basis.binding), .integer(basis.generation), .string(basis.artifact)]
        case .explicitRule(let operation):
            guard operation.epoch == context.epoch else { throw NativePendingError.invalidRecord }
            return try NativeRuleOperationWire.record(operation).map(PendingValue.ruleScalar)
        }
    }
    fileprivate static func decode(_ values: [PendingValue]) throws -> Self {
        guard let action = values.first?.string, values.count >= 2 else { throw NativePendingError.invalidRecord }
        func operation() throws -> String { try values[1].requiredString() }
        switch (action, values.count) {
        case (NativeRuleOperationWire.format, 6), (NativeRuleOperationWire.format, 9):
            do { return .explicitRule(try NativeRuleOperationWire.decode(PendingValue.array(values).encoded())) }
            catch { throw NativePendingError.invalidRecord }
        case ("submit", 5):
            guard case .boolean(let on) = values[4] else { throw NativePendingError.invalidRecord }
            return .power(operation: try operation(), target: try values[2].requiredString(), revision: try values[3].requiredInteger(), on: on)
        case ("cancel", 2): return .cancel(operation: try operation())
        case ("override_issue", 5): return .issueOverride(operation: try operation(), target: try values[2].requiredString(), revision: try values[3].requiredInteger(), duration: try values[4].requiredInteger())
        case ("override_revoke", 2): return .revokeOverride(operation: try operation())
        case ("activate_rule", 4):
            guard values[3] == .integer(0) else { throw NativePendingError.invalidRecord }
            return .suspend(operation: try operation(), revision: try values[2].requiredInteger())
        case ("begin_maintenance", 3): return .beginMaintenance(operation: try operation(), revision: try values[2].requiredInteger())
        case ("end_maintenance", 4): return .endMaintenance(operation: try operation(), revision: try values[2].requiredInteger(), beginRevision: try values[3].requiredInteger())
        case ("native_target_grant", 8):
            return .targetAccess(operation: try operation(), revision: try values[2].requiredInteger(), target: try values[3].requiredString(),
                action: .grant, basis: NativeTargetBasis(resource: try values[4].requiredInteger(), binding: try values[5].requiredInteger(),
                    generation: try values[6].requiredInteger(), artifact: try values[7].requiredString()))
        case ("native_target_revoke", 4):
            return .targetAccess(operation: try operation(), revision: try values[2].requiredInteger(), target: try values[3].requiredString(), action: .revoke, basis: nil)
        case ("profile_prepare", _), ("profile_change", _):
            let action = try values[1].requiredString()
            let fields = HomeProfileOperation.commonFields + (action == "select" ? HomeProfileOperation.selectionFields :
                action == "revoke_selection" ? HomeProfileOperation.revocationFields : [])
            guard values.count == fields.count + 1 else { throw NativePendingError.invalidRecord }
            let dictionary = Dictionary(uniqueKeysWithValues: try zip(fields, values.dropFirst()).map { ($0.0, try $0.1.scalarObject()) })
            do { return .profile(preparing: values[0].string == "profile_prepare", operation: try HomeProfileOperation(dictionary)) }
            catch { throw NativePendingError.invalidRecord }
        default: throw NativePendingError.invalidRecord
        }
    }
}

enum NativePendingPhase: Equatable, Sendable {
    case pending
    case review(token: String, digest: String)
    case commitPending(token: String, digest: String)
    case cancelPending(token: String, digest: String)
    var isHeldReview: Bool { if case .review = self { return true }; return false }
    var isCancellation: Bool { if case .cancelPending = self { return true }; return false }
    fileprivate func values(input: NativePendingInput) throws -> [PendingValue] {
        let kind: String, token: String, digest: String
        switch self {
        case .pending: return [.string("pending")]
        case .review(let t, let d): kind = "review"; token = t; digest = d
        case .commitPending(let t, let d): kind = "commit_pending"; token = t; digest = d
        case .cancelPending(let t, let d): kind = "cancel_pending"; token = t; digest = d
        }
        guard case .profile(_, let operation) = input, operation.action == "select",
              LocalHealthClient.profileID(token), NativeCoreWire.digest(digest) else { throw NativePendingError.invalidRecord }
        return [.string(kind), .string(token), .string(digest)]
    }
    fileprivate static func decode(_ values: [PendingValue]) throws -> Self {
        if values == [.string("pending")] { return .pending }
        guard values.count == 3 else { throw NativePendingError.invalidRecord }
        let token = try values[1].requiredString(), digest = try values[2].requiredString()
        switch values[0].string {
        case "review": return .review(token: token, digest: digest)
        case "commit_pending": return .commitPending(token: token, digest: digest)
        case "cancel_pending": return .cancelPending(token: token, digest: digest)
        default: throw NativePendingError.invalidRecord
        }
    }
}

struct NativePendingEntry: Equatable, Sendable, CustomReflectable {
    let context: NativePendingContext, custody: NativePendingCustody, input: NativePendingInput, phase: NativePendingPhase
    var category: NativePendingCategory { input.category }
    var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
    func changingPhase(_ phase: NativePendingPhase) throws -> Self {
        let entry = Self(context: context, custody: custody, input: input, phase: phase)
        _ = try entry.value()
        return entry
    }
    fileprivate var key: Data { PendingValue.array(context.values + [.string(category.rawValue)]).encoded() }
    fileprivate var categoryKey: Data { PendingValue.array(Array(context.values.prefix(3)) + [.string(category.rawValue)]).encoded() }
    fileprivate func value() throws -> PendingValue {
        guard custody.valid(context: context) else { throw NativePendingError.invalidRecord }
        if category == .access { _ = try targetChange() }
        if case .explicitRule = input { _ = try ruleOperation() }
        return .array([.string(category.rawValue), .array(context.values), .array(custody.values),
            .array(try input.values(context: context)), .array(try phase.values(input: input))])
    }
    func targetChange() throws -> NativeTargetChange {
        guard phase == .pending, case .targetAccess(let operation, let revision, let target, let action, let basis) = input,
              case .native(.operator, _, _) = custody else { throw NativePendingError.invalidRecord }
        let change = NativeTargetChange(original: try custody.nativeOriginal(context: context), operation: operation,
            expectedRevision: revision, target: target, action: action, basis: basis)
        do { _ = try NativeTargetWire.change(change) } catch { throw NativePendingError.invalidRecord }
        return change
    }
    func ruleOperation() throws -> HomeExplicitRuleOperation {
        guard custody.valid(context: context), phase == .pending, case .explicitRule(let operation) = input,
              operation.epoch == context.epoch else { throw NativePendingError.invalidRecord }
        if case .native(let role, let creation, _) = custody {
            guard role == .operator, operation.expectedRevision.map({ $0 >= creation }) != false else { throw NativePendingError.invalidRecord }
        }
        do { _ = try NativeRuleOperationWire.encode(operation) } catch { throw NativePendingError.invalidRecord }
        return operation
    }
    fileprivate static func decode(_ value: PendingValue) throws -> Self {
        let fields = try value.requiredArray(count: 5)
        let contextFields = try fields[1].requiredArray(count: 4)
        let context = NativePendingContext(deployment: try contextFields[0].requiredString(), owner: try contextFields[1].requiredString(),
            epoch: try contextFields[2].requiredInteger(), principal: try contextFields[3].requiredString())
        let custodyFields = try fields[2].requiredArray()
        let custody: NativePendingCustody
        if custodyFields.count == 2, custodyFields[0] == .string("manual") {
            custody = .manual(verifier: try custodyFields[1].requiredString())
        } else if custodyFields.count == 4, custodyFields[0] == .string("native"),
                  let role = NativeCustodyRole(rawValue: try custodyFields[1].requiredString()) {
            custody = .native(role: role, creationRevision: try custodyFields[2].requiredInteger(), verifier: try custodyFields[3].requiredString())
        } else { throw NativePendingError.invalidRecord }
        let input = try NativePendingInput.decode(fields[3].requiredArray())
        guard fields[0].string == input.category.rawValue else { throw NativePendingError.invalidRecord }
        let result = Self(context: context, custody: custody, input: input, phase: try NativePendingPhase.decode(fields[4].requiredArray()))
        _ = try result.value()
        return result
    }
}

enum NativePendingVersion: String, Sendable {
    case v1 = "wotex-home.native-pending.v1", v2 = "wotex-home.native-pending.v2", v3 = "wotex-home.native-pending.v3"
    static func requiring(_ entries: [NativePendingEntry], keeping version: Self = .v1) -> Self {
        if version == .v3 || entries.contains(where: { if case .explicitRule = $0.input { return true }; return false }) { return .v3 }
        if version == .v2 || entries.contains(where: { $0.category == .access }) { return .v2 }
        return .v1
    }
}

struct NativePendingDocument: Equatable, Sendable, CustomReflectable {
    static let format = "wotex-home.native-pending.v1"
    let revision: Int64, entries: [NativePendingEntry]
    let version: NativePendingVersion
    init(revision: Int64, entries: [NativePendingEntry], version: NativePendingVersion? = nil) {
        self.revision = revision; self.entries = entries
        self.version = version ?? NativePendingVersion.requiring(entries)
    }
    static var empty: Self { Self(revision: 0, entries: []) }
    var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
    static func sorted(_ entries: [NativePendingEntry]) -> [NativePendingEntry] { entries.sorted { $0.key.lexicographicallyPrecedes($1.key) } }
    func encoded() throws -> Data {
        guard revision > 0, entries.count <= 16,
              NativePendingVersion.requiring(entries, keeping: version) == version else { throw NativePendingError.invalidRecord }
        let values = try entries.map { try $0.value() }
        guard Self.sorted(entries) == entries,
              Set(entries.map(\.categoryKey)).count == entries.count else { throw NativePendingError.invalidRecord }
        let bytes = PendingValue.array([.string(version.rawValue), .integer(revision), .array(values)]).encoded()
        _ = try PendingJSON.decode(bytes)
        return bytes
    }
    static func decode(_ bytes: Data) throws -> Self {
        let values = try PendingJSON.decode(bytes).requiredArray(count: 3)
        guard let version = NativePendingVersion(rawValue: try values[0].requiredString()) else { throw NativePendingError.invalidRecord }
        let result = Self(revision: try values[1].requiredInteger(), entries: try values[2].requiredArray().map { try NativePendingEntry.decode($0) }, version: version)
        guard try result.encoded() == bytes else { throw NativePendingError.invalidRecord }
        return result
    }
}

// A bounded scanner returns typed primitives before Foundation can coerce
// numbers/booleans or allocate an unbounded tree. All closed IDs are ASCII.
private indirect enum PendingValue: Equatable {
    case string(String), integer(Int64), boolean(Bool), array([PendingValue])
    var string: String? { if case .string(let value) = self { value } else { nil } }
    func requiredString() throws -> String { guard let string else { throw NativePendingError.invalidRecord }; return string }
    func requiredInteger() throws -> Int64 { guard case .integer(let value) = self else { throw NativePendingError.invalidRecord }; return value }
    func requiredArray(count: Int? = nil) throws -> [Self] {
        guard case .array(let values) = self, count == nil || count == values.count else { throw NativePendingError.invalidRecord }
        return values
    }
    func scalarObject() throws -> Any {
        switch self {
        case .string(let value): return value
        case .integer(let value):
            guard let integer = Int(exactly: value) else { throw NativePendingError.invalidRecord }
            return integer
        default: throw NativePendingError.invalidRecord
        }
    }
    static func scalar(_ object: Any) throws -> Self {
        if let value = object as? String { return .string(value) }
        guard let value = LocalHealthClient.profileInteger(object) else { throw NativePendingError.invalidRecord }
        return .integer(Int64(value))
    }
    static func ruleScalar(_ object: Any) throws -> Self {
        if let value = object as? String { return .string(value) }
        if let number = object as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() { return .boolean(number.boolValue) }
        guard let value = NativeScalarJSON.integer(object, minimum: 0) else { throw NativePendingError.invalidRecord }
        return .integer(value)
    }
    func encoded() -> Data {
        switch self {
        case .string(let value): return Data(("\"" + value + "\"").utf8)
        case .integer(let value): return Data(String(value).utf8)
        case .boolean(let value): return Data((value ? "true" : "false").utf8)
        case .array(let values):
            var bytes = Data([91])
            for (index, value) in values.enumerated() { if index > 0 { bytes.append(44) }; bytes.append(value.encoded()) }
            bytes.append(93); return bytes
        }
    }
}

private struct PendingJSON {
    let bytes: [UInt8]
    var index = 0
    static func decode(_ bytes: Data) throws -> PendingValue {
        guard (1...65_536).contains(bytes.count) else { throw NativePendingError.invalidRecord }
        var parser = Self(bytes: Array(bytes))
        let value = try parser.value(depth: 0)
        guard parser.index == parser.bytes.count else { throw NativePendingError.invalidRecord }
        return value
    }
    private mutating func value(depth: Int) throws -> PendingValue {
        guard index < bytes.count else { throw NativePendingError.invalidRecord }
        switch bytes[index] {
        case 91:
            guard depth < 4 else { throw NativePendingError.invalidRecord }
            index += 1
            var values: [PendingValue] = []
            if take(93) { return .array(values) }
            while true {
                guard values.count < 32 else { throw NativePendingError.invalidRecord }
                values.append(try value(depth: depth + 1))
                if take(93) { return .array(values) }
                guard take(44) else { throw NativePendingError.invalidRecord }
            }
        case 34:
            index += 1; let start = index
            while index < bytes.count && bytes[index] != 34 {
                guard index - start < 128, (32...126).contains(bytes[index]), bytes[index] != 92 else { throw NativePendingError.invalidRecord }
                index += 1
            }
            guard take(34) else { throw NativePendingError.invalidRecord }
            return .string(String(decoding: bytes[start..<(index - 1)], as: UTF8.self))
        case 48...57:
            let start = index; var number: Int64 = 0
            while index < bytes.count && (48...57).contains(bytes[index]) {
                let (product, multiplied) = number.multipliedReportingOverflow(by: 10)
                let (sum, added) = product.addingReportingOverflow(Int64(bytes[index] - 48))
                guard !multiplied, !added else { throw NativePendingError.invalidRecord }
                number = sum; index += 1
            }
            guard index - start == 1 || bytes[start] != 48 else { throw NativePendingError.invalidRecord }
            return .integer(number)
        case 116: try literal("true"); return .boolean(true)
        case 102: try literal("false"); return .boolean(false)
        default: throw NativePendingError.invalidRecord
        }
    }
    private mutating func take(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1; return true
    }
    private mutating func literal(_ value: String) throws {
        for byte in value.utf8 { guard take(byte) else { throw NativePendingError.invalidRecord } }
    }
}
