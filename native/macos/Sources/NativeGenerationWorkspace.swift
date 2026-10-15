import CoreFoundation
import Foundation

struct NativeGenerationWorkspaceEntry: Sendable, Equatable, CustomReflectable {
    let context: NativePendingContext, custody: NativePendingCustody, basisSHA: String
    let preparation: HomeGenerationOriginal, attempts: [HomeGenerationOriginal], cancellationPending: Bool
    var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
    fileprivate var scopeKey: Data { WorkspaceValue.array([.string(context.deployment), .string(context.owner), .integer(context.epoch)]).encoded() }
    func checked() throws -> Self {
        guard !custody.isPaired, LocalHealthClient.profileDigest(basisSHA), preparation.kind == .preparation,
              preparation.epoch == context.epoch, attempts.count <= 3 else { throw NativePendingError.invalidRecord }
        _ = try NativePendingEntry(context: context, custody: custody, input: .generation(preparation), phase: .pending).generationOperation()
        let fields = try preparation.fields()
        guard let budget = fields["budget"] as? [String: Any], let count = LocalHealthClient.profileInteger(budget["attempts"]),
              attempts.count <= count else { throw NativePendingError.invalidRecord }
        var previous: HomeGenerationOriginal?, ids: Set<String> = [preparation.operation]
        for (index, attempt) in attempts.enumerated() {
            _ = try NativePendingEntry(context: context, custody: custody, input: .generation(attempt), phase: .pending).generationOperation()
            let input = try attempt.fields()
            guard attempt.kind == .attempt, attempt.expectedRevision > (previous?.expectedRevision ?? preparation.expectedRevision),
                  input["preparation_operation_id"] as? String == preparation.operation,
                  input["preparation_sha256"] as? String == preparation.sha,
                  LocalHealthClient.profileInteger(input["attempt"]) == index + 1,
                  ids.insert(attempt.operation).inserted else { throw NativePendingError.invalidRecord }
            if let previous { guard input["previous_operation_id"] as? String == previous.operation else { throw NativePendingError.invalidRecord } }
            previous = attempt
        }
        return self
    }
    func appending(_ attempt: HomeGenerationOriginal) throws -> Self {
        if attempts.last == attempt { return try checked() }
        return try Self(context: context, custody: custody, basisSHA: basisSHA, preparation: preparation,
            attempts: attempts + [attempt], cancellationPending: cancellationPending).checked()
    }
    func cancellation(_ pending: Bool) throws -> Self {
        try Self(context: context, custody: custody, basisSHA: basisSHA, preparation: preparation,
            attempts: attempts, cancellationPending: pending).checked()
    }
    fileprivate func value() throws -> WorkspaceValue {
        _ = try checked()
        let custodyValues: [WorkspaceValue]
        switch custody {
        case .manual(let verifier): custodyValues = [.string("manual"), .string(verifier)]
        case .native(let role, let revision, let verifier): custodyValues = [.string("native"), .string(role.rawValue), .integer(revision), .string(verifier)]
        case .paired: throw NativePendingError.invalidRecord
        }
        return .array([.array([.string(context.deployment), .string(context.owner), .integer(context.epoch), .string(context.principal)]),
            .array(custodyValues), .string(basisSHA), .string(String(decoding: preparation.canonical, as: UTF8.self)),
            .array(attempts.map { .string(String(decoding: $0.canonical, as: UTF8.self)) }), .boolean(cancellationPending)])
    }
    fileprivate static func decode(_ value: WorkspaceValue) throws -> Self {
        let fields = try value.array(count: 6), c = try fields[0].array(count: 4), custody = try fields[1].array()
        let context = NativePendingContext(deployment: try c[0].string(), owner: try c[1].string(), epoch: try c[2].integer(), principal: try c[3].string())
        let reference: NativePendingCustody
        if custody.count == 2, custody[0] == .string("manual") { reference = .manual(verifier: try custody[1].string()) }
        else if custody.count == 4, custody[0] == .string("native"), custody[1] == .string("operator") {
            reference = .native(role: .operator, creationRevision: try custody[2].integer(), verifier: try custody[3].string())
        } else { throw NativePendingError.invalidRecord }
        let preparation = try NativeGenerationOriginalWire.decode(Data(fields[3].string().utf8), kind: .preparation)
        let attempts = try fields[4].array().map { try NativeGenerationOriginalWire.decode(Data($0.string().utf8), kind: .attempt) }
        guard case .boolean(let cancellation) = fields[5] else { throw NativePendingError.invalidRecord }
        return try Self(context: context, custody: reference, basisSHA: fields[2].string(), preparation: preparation,
            attempts: attempts, cancellationPending: cancellation).checked()
    }
}

struct NativeGenerationWorkspaceDocument: Sendable, Equatable, CustomReflectable {
    static let format = "wotex-home.native-generation-workspace.v1"
    let revision: Int64, entries: [NativeGenerationWorkspaceEntry]
    static var empty: Self { Self(revision: 0, entries: []) }
    var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
    static func sorted(_ entries: [NativeGenerationWorkspaceEntry]) -> [NativeGenerationWorkspaceEntry] { entries.sorted { $0.scopeKey.lexicographicallyPrecedes($1.scopeKey) } }
    func encoded() throws -> Data {
        guard revision > 0, entries.count <= 16, Self.sorted(entries) == entries,
              Set(entries.map(\.scopeKey)).count == entries.count else { throw NativePendingError.invalidRecord }
        let bytes = try WorkspaceValue.array([.string(Self.format), .integer(revision), .array(entries.map { try $0.value() })]).encoded()
        _ = try WorkspaceJSON.decode(bytes); return bytes
    }
    static func decode(_ bytes: Data) throws -> Self {
        do {
            let root = try WorkspaceJSON.decode(bytes).array(count: 3)
            guard try root[0].string() == format else { throw NativePendingError.invalidRecord }
            let value = try Self(revision: root[1].integer(), entries: root[2].array().map(NativeGenerationWorkspaceEntry.decode))
            guard try value.encoded() == bytes else { throw NativePendingError.invalidRecord }; return value
        } catch { throw NativePendingError.invalidRecord }
    }
}

struct NativeGenerationWorkspaceSnapshot: Sendable, Equatable, CustomReflectable {
    let document: NativeGenerationWorkspaceDocument
    fileprivate let file: NativePrivateDocumentSnapshot
    static var empty: Self { Self(document: .empty, file: .empty) }
    var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
}

enum NativeGenerationWorkspaceStorage {
    static func load(directory: URL) throws -> NativeGenerationWorkspaceSnapshot {
        try mapped { try snapshot(NativePrivateDocuments.load(directory: directory, kind: .generation)) }
    }
    static func retaining(_ entry: NativeGenerationWorkspaceEntry, directory: URL, expected: NativeGenerationWorkspaceSnapshot) throws -> NativeGenerationWorkspaceSnapshot {
        _ = try entry.checked()
        if expected.document.entries.contains(entry) { return try publish(expected.document.entries, directory, expected) }
        guard expected.document.entries.count < 16 else { throw NativePendingError.capacity }
        guard !expected.document.entries.contains(where: { $0.scopeKey == entry.scopeKey }) else { throw NativePendingError.conflict }
        return try publish(expected.document.entries + [entry], directory, expected)
    }
    static func replacing(_ entry: NativeGenerationWorkspaceEntry, with replacement: NativeGenerationWorkspaceEntry,
                          directory: URL, expected: NativeGenerationWorkspaceSnapshot) throws -> NativeGenerationWorkspaceSnapshot {
        _ = try replacement.checked()
        guard let index = expected.document.entries.firstIndex(of: entry), entry.context == replacement.context,
              entry.custody == replacement.custody, entry.basisSHA == replacement.basisSHA, entry.preparation == replacement.preparation,
              replacement.attempts == entry.attempts || (replacement.attempts.count == entry.attempts.count + 1 && Array(replacement.attempts.dropLast()) == entry.attempts),
              replacement.attempts == entry.attempts || replacement.cancellationPending == entry.cancellationPending else { throw NativePendingError.conflict }
        var entries = expected.document.entries; entries[index] = replacement
        return try publish(entries, directory, expected)
    }
    static func removing(_ entry: NativeGenerationWorkspaceEntry, directory: URL, expected: NativeGenerationWorkspaceSnapshot) throws -> NativeGenerationWorkspaceSnapshot {
        guard expected.document.entries.contains(entry) else { throw NativePendingError.conflict }
        return try publish(expected.document.entries.filter { $0 != entry }, directory, expected)
    }
    private static func publish(_ entries: [NativeGenerationWorkspaceEntry], _ directory: URL, _ expected: NativeGenerationWorkspaceSnapshot) throws -> NativeGenerationWorkspaceSnapshot {
        try mapped {
            let bytes: Data?
            if entries == expected.document.entries { bytes = expected.file.bytes }
            else {
                guard expected.document.revision < Int64.max else { throw NativePendingError.invalidRecord }
                bytes = try NativeGenerationWorkspaceDocument(revision: expected.document.revision + 1,
                    entries: NativeGenerationWorkspaceDocument.sorted(entries)).encoded()
            }
            return try snapshot(NativePrivateDocuments.replace(directory: directory, kind: .generation, expected: expected.file, bytes: bytes))
        }
    }
    private static func snapshot(_ file: NativePrivateDocumentSnapshot) throws -> NativeGenerationWorkspaceSnapshot {
        try NativeGenerationWorkspaceSnapshot(document: file.bytes.map(NativeGenerationWorkspaceDocument.decode) ?? .empty, file: file)
    }
    private static func mapped<Value>(_ operation: () throws -> Value) throws -> Value {
        do { return try operation() }
        catch let error as NativePrivateDocumentError {
            switch error {
            case .unavailable: throw NativePendingError.unavailable
            case .invalidRecord: throw NativePendingError.invalidRecord
            case .conflict: throw NativePendingError.conflict
            case .capacity: throw NativePendingError.capacity
            case .outcomeUnknown: throw NativePendingError.outcomeUnknown
            }
        }
    }
}

private indirect enum WorkspaceValue: Equatable {
    case string(String), integer(Int64), boolean(Bool), array([WorkspaceValue])
    func string() throws -> String { guard case .string(let value) = self else { throw NativePendingError.invalidRecord }; return value }
    func integer() throws -> Int64 { guard case .integer(let value) = self else { throw NativePendingError.invalidRecord }; return value }
    func array(count: Int? = nil) throws -> [Self] { guard case .array(let value) = self, count == nil || count == value.count else { throw NativePendingError.invalidRecord }; return value }
    func encoded() -> Data {
        switch self {
        case .string(let value): return Data(("\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"").utf8)
        case .integer(let value): return Data(String(value).utf8)
        case .boolean(let value): return Data((value ? "true" : "false").utf8)
        case .array(let values): return Data([91]) + values.enumerated().reduce(into: Data()) { result, item in if item.offset > 0 { result.append(44) }; result.append(item.element.encoded()) } + Data([93])
        }
    }
}

private struct WorkspaceJSON {
    let bytes: [UInt8]
    var index = 0, nodes = 0
    static func decode(_ bytes: Data) throws -> WorkspaceValue {
        guard (1...2_097_152).contains(bytes.count) else { throw NativePendingError.invalidRecord }
        var parser = Self(bytes: Array(bytes))
        let value = try parser.value([])
        guard parser.index == parser.bytes.count else { throw NativePendingError.invalidRecord }; return value
    }
    private mutating func value(_ path: [Int]) throws -> WorkspaceValue {
        nodes += 1
        guard nodes <= 1024, index < bytes.count else { throw NativePendingError.invalidRecord }
        if bytes[index] == 91 {
            guard path.count < 4 else { throw NativePendingError.invalidRecord }
            index += 1; var values: [WorkspaceValue] = []
            if take(93) { return .array(values) }
            while true {
                guard values.count < 16 else { throw NativePendingError.invalidRecord }
                values.append(try value(path + [values.count]))
                if take(93) { return .array(values) }
                guard take(44) else { throw NativePendingError.invalidRecord }
            }
        }
        if bytes[index] == 34 {
            let rootDocument = path.count == 3 && path[0] == 2 && path[2] == 3
            let attemptDocument = path.count == 4 && path[0] == 2 && path[2] == 4
            let document = rootDocument || attemptDocument, maximum = rootDocument ? 32768 : attemptDocument ? 2048 : 128
            index += 1; var decoded: [UInt8] = []
            while index < bytes.count && bytes[index] != 34 {
                guard decoded.count < maximum, document ? bytes[index] >= 32 : (32...126).contains(bytes[index]) else { throw NativePendingError.invalidRecord }
                var byte = bytes[index]; index += 1
                if byte == 92 {
                    guard document, index < bytes.count, bytes[index] == 34 || bytes[index] == 92 else { throw NativePendingError.invalidRecord }
                    byte = bytes[index]; index += 1
                }
                decoded.append(byte)
            }
            guard take(34), let string = String(bytes: decoded, encoding: .utf8) else { throw NativePendingError.invalidRecord }; return .string(string)
        }
        if (48...57).contains(bytes[index]) {
            let start = index; var integer: Int64 = 0
            while index < bytes.count && (48...57).contains(bytes[index]) {
                let (product, multiplied) = integer.multipliedReportingOverflow(by: 10)
                let (sum, added) = product.addingReportingOverflow(Int64(bytes[index] - 48))
                guard !multiplied, !added else { throw NativePendingError.invalidRecord }; integer = sum; index += 1
            }
            guard index - start == 1 || bytes[start] != 48 else { throw NativePendingError.invalidRecord }; return .integer(integer)
        }
        if literal("true") { return .boolean(true) }
        if literal("false") { return .boolean(false) }
        throw NativePendingError.invalidRecord
    }
    private mutating func take(_ byte: UInt8) -> Bool { if index < bytes.count && bytes[index] == byte { index += 1; return true }; return false }
    private mutating func literal(_ text: String) -> Bool {
        let value = Array(text.utf8)
        guard index + value.count <= bytes.count, Array(bytes[index..<index + value.count]) == value else { return false }
        index += value.count; return true
    }
}
