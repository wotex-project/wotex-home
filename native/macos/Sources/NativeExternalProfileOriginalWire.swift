import Darwin
import Foundation

extension HomeExternalProfileOriginalKind {
    var format: String { "wotex-home.external-\(rawValue).v1" }
    var maximum: Int { self == .inspection ? 16384 : self == .trust ? 4096 : 32768 }
    var nativeMaximum: Int { maximum * 4 }
}

struct HomeExternalProfileOriginal: Sendable, Equatable, CustomReflectable {
    let kind: HomeExternalProfileOriginalKind, epoch: Int64, operation: String, expectedRevision: Int64
    let canonical: Data
    var sha: String { LocalHealthClient.profileSHA(canonical) }
    var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
    fileprivate init(kind: HomeExternalProfileOriginalKind, epoch: Int64, operation: String, revision: Int64, canonical: Data) {
        self.kind = kind; self.epoch = epoch; self.operation = operation; expectedRevision = revision; self.canonical = canonical
    }
    func fields() throws -> [String: Any] {
        let (checked, fields) = try NativeExternalProfileOriginalWire.checked(canonical, kind: kind)
        guard checked == self else { throw LocalHealthError.invalidProfileRequest }; return fields
    }
}

enum NativeExternalProfileOriginalWire {
    private static let inspectionKeys = ["authority_epoch", "operation_id", "expected_revision", "inspection"]
    private static let trustKeys = ["authority_epoch", "operation_id", "expected_revision", "action", "artifact_digest", "expected_trust_revision", "expected_policy_generation", "inspection_ref", "acknowledgement"]
    private static let targetKeys = ["authority_epoch", "operation_id", "expected_revision", "action", "target_id", "artifact_digest", "expected_trust_revision", "expected_policy_generation", "expected_selection_revision", "expected_resource_revision", "source_ref", "source_owner_epoch", "source_selection_sha256", "objects", "acknowledgement"]
    private static let refKeys = ["authority_epoch", "operation_id", "revision", "input_sha256", "result_sha256"]
    static func encode(_ fields: [String: Any], kind: HomeExternalProfileOriginalKind) throws -> HomeExternalProfileOriginal {
        guard exact(fields, kind == .inspection ? inspectionKeys : kind == .trust ? trustKeys : targetKeys),
              let epoch = integer(fields["authority_epoch"], minimum: 1), let operation = id(fields["operation_id"]),
              let revision = integer(fields["expected_revision"], minimum: 0) else { throw LocalHealthError.invalidProfileRequest }
        var values: [Any] = [epoch, operation, revision]
        switch kind {
        case .inspection:
            guard let content = fields["inspection"] as? [String: Any], exact(content, ["reader_basis_sha256", "envelope_ref", "profile", "definitions"]),
                  let basis = digest(content["reader_basis_sha256"]) else { throw LocalHealthError.invalidProfileRequest }
            values.append([basis] + (try objects(content, withBasis: true)))
        case .trust:
            guard let action = fields["action"] as? String, ["approve", "revoke"].contains(action), let artifact = digest(fields["artifact_digest"]),
                  let trust = integer(fields["expected_trust_revision"], minimum: 0), let policy = integer(fields["expected_policy_generation"], minimum: 0) else { throw LocalHealthError.invalidProfileRequest }
            let reference: Any
            if action == "approve" {
                guard fields["acknowledgement"] as? String == "operator_digest_approval", let ref = fields["inspection_ref"] as? [String: Any], exact(ref, refKeys),
                      integer(ref["authority_epoch"], minimum: 1) != nil, id(ref["operation_id"]) != nil, integer(ref["revision"], minimum: 1) != nil,
                      digest(ref["input_sha256"]) != nil, digest(ref["result_sha256"]) != nil else { throw LocalHealthError.invalidProfileRequest }
                reference = refKeys.map { ref[$0]! }
            } else {
                guard fields["inspection_ref"] is NSNull, fields["acknowledgement"] is NSNull else { throw LocalHealthError.invalidProfileRequest }; reference = NSNull()
            }
            values += [action, artifact, trust, policy, reference, fields["acknowledgement"]!]
        case .target:
            guard let action = fields["action"] as? String, ["select", "revoke"].contains(action), let target = id(fields["target_id"]), let artifact = digest(fields["artifact_digest"]) else { throw LocalHealthError.invalidProfileRequest }
            let counters = try ["expected_trust_revision", "expected_policy_generation", "expected_selection_revision", "expected_resource_revision"].map { key -> Int64 in
                guard let value = integer(fields[key], minimum: 0) else { throw LocalHealthError.invalidProfileRequest }; return value
            }
            let selected: Any
            if action == "select" {
                guard id(fields["source_ref"]) != nil, let owner = fields["source_owner_epoch"] as? String, owner.utf8.count == 32,
                      owner.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }), digest(fields["source_selection_sha256"]) != nil,
                      let content = fields["objects"] as? [String: Any], fields["acknowledgement"] as? String == "operator_external_selection" else { throw LocalHealthError.invalidProfileRequest }
                selected = try objects(content)
            } else {
                guard ["source_ref", "source_owner_epoch", "source_selection_sha256", "objects", "acknowledgement"].allSatisfy({ fields[$0] is NSNull }) else { throw LocalHealthError.invalidProfileRequest }; selected = NSNull()
            }
            values += [action, target, artifact] as [Any]
            values += counters.map { $0 as Any }
            values += [fields["source_ref"]!, fields["source_owner_epoch"]!, fields["source_selection_sha256"]!, selected, fields["acknowledgement"]!]
        }
        let bytes = try JSONSerialization.data(withJSONObject: [kind.format, values], options: .withoutEscapingSlashes)
        guard bytes.count <= kind.maximum else { throw LocalHealthError.invalidProfileRequest }
        return HomeExternalProfileOriginal(kind: kind, epoch: epoch, operation: operation, revision: revision, canonical: bytes)
    }
    static func nativeJSON(_ bytes: Data, kind: HomeExternalProfileOriginalKind) throws -> HomeExternalProfileOriginal {
        do {
            guard (1...kind.nativeMaximum).contains(bytes.count) else { throw LocalHealthError.invalidProfileRequest }
            var parser = ExternalOriginalPreflight(bytes: Array(bytes), objects: true); try parser.check()
            guard let fields = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw LocalHealthError.invalidProfileRequest }
            return try encode(fields, kind: kind)
        } catch { throw LocalHealthError.invalidProfileRequest }
    }
    static func decode(_ bytes: Data, kind: HomeExternalProfileOriginalKind) throws -> HomeExternalProfileOriginal { try checked(bytes, kind: kind).0 }
    fileprivate static func checked(_ bytes: Data, kind: HomeExternalProfileOriginalKind) throws -> (HomeExternalProfileOriginal, [String: Any]) {
        do {
            guard (1...kind.maximum).contains(bytes.count) else { throw LocalHealthError.invalidProfileRequest }
            var parser = ExternalOriginalPreflight(bytes: Array(bytes), objects: false); try parser.check()
            guard let root = try JSONSerialization.jsonObject(with: bytes) as? [Any], root.count == 2, root[0] as? String == kind.format,
                  let values = root[1] as? [Any], values.count == (kind == .inspection ? 4 : kind == .trust ? 9 : 15) else { throw LocalHealthError.invalidProfileRequest }
            var fields = map(kind == .inspection ? inspectionKeys : kind == .trust ? trustKeys : targetKeys, values)
            switch kind {
            case .inspection:
                guard let content = values[3] as? [Any], content.count == 4 else { throw LocalHealthError.invalidProfileRequest }
                var native = try nativeObjects(Array(content.dropFirst())); native["reader_basis_sha256"] = content[0]; fields["inspection"] = native
            case .trust:
                if !(values[7] is NSNull) {
                    guard let ref = values[7] as? [Any], ref.count == 5 else { throw LocalHealthError.invalidProfileRequest }; fields["inspection_ref"] = map(refKeys, ref)
                }
            case .target:
                if !(values[13] is NSNull) {
                    guard let content = values[13] as? [Any] else { throw LocalHealthError.invalidProfileRequest }; fields["objects"] = try nativeObjects(content)
                }
            }
            let original = try encode(fields, kind: kind)
            guard original.canonical == bytes else { throw LocalHealthError.invalidProfileRequest }; return (original, fields)
        } catch { throw LocalHealthError.invalidProfileRequest }
    }
    private static func objects(_ fields: [String: Any], withBasis: Bool = false) throws -> [Any] {
        guard exact(fields, ["envelope_ref", "profile", "definitions"] + (withBasis ? ["reader_basis_sha256"] : [])),
              let definitions = fields["definitions"] as? [[String: Any]], definitions.count <= 32 else { throw LocalHealthError.invalidProfileRequest }
        var previous: (String, String)?, identifiers: Set<String> = [], digests: Set<String> = []
        let rows = try definitions.map { row -> [Any] in
            let encoded = try document(row), ref = encoded[0] as! [String], handle = encoded[1] as! [Any]
            guard identifiers.insert(ref[0]).inserted, digests.insert(handle[0] as! String).inserted,
                  previous.map({ $0.0 < ref[0] || ($0.0 == ref[0] && $0.1 < ref[1]) }) ?? true else { throw LocalHealthError.invalidProfileRequest }
            previous = (ref[0], ref[1]); return encoded
        }
        return [try handle(fields["envelope_ref"]), try document(fields["profile"]), rows]
    }
    private static func handle(_ value: Any?) throws -> [Any] {
        guard let fields = value as? [String: Any], exact(fields, ["object_digest", "first_revision"]),
              let sha = digest(fields["object_digest"]), let first = integer(fields["first_revision"], minimum: 1) else { throw LocalHealthError.invalidProfileRequest }; return [sha, first]
    }
    private static func document(_ value: Any?) throws -> [Any] {
        guard let fields = value as? [String: Any], exact(fields, ["reference", "object_ref"]), let ref = fields["reference"] as? [String: Any], exact(ref, ["id", "version", "sha256"]),
              let uri = ref["id"] as? String, ExternalOriginalURI.valid(uri), let version = ref["version"] as? String,
              version.utf8.count <= 17, version.range(of: "^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)$", options: .regularExpression) != nil,
              version.split(separator: ".").allSatisfy({ UInt16($0) != nil }), let sha = digest(ref["sha256"]) else { throw LocalHealthError.invalidProfileRequest }
        return [[uri, version, sha], try handle(fields["object_ref"])]
    }
    private static func nativeObjects(_ values: [Any]) throws -> [String: Any] {
        guard values.count == 3, let definitions = values[2] as? [Any], definitions.count <= 32 else { throw LocalHealthError.invalidProfileRequest }
        return ["envelope_ref": try nativeHandle(values[0]), "profile": try nativeDocument(values[1]), "definitions": try definitions.map(nativeDocument)]
    }
    private static func nativeHandle(_ value: Any) throws -> [String: Any] {
        guard let row = value as? [Any], row.count == 2 else { throw LocalHealthError.invalidProfileRequest }; return map(["object_digest", "first_revision"], row)
    }
    private static func nativeDocument(_ value: Any) throws -> [String: Any] {
        guard let row = value as? [Any], row.count == 2, let ref = row[0] as? [Any], ref.count == 3 else { throw LocalHealthError.invalidProfileRequest }
        return ["reference": map(["id", "version", "sha256"], ref), "object_ref": try nativeHandle(row[1])]
    }
    private static func map(_ keys: [String], _ values: [Any]) -> [String: Any] { Dictionary(uniqueKeysWithValues: zip(keys, values)) }
    private static func exact(_ fields: [String: Any], _ keys: [String]) -> Bool { fields.count == keys.count && Set(fields.keys) == Set(keys) }
    private static func integer(_ value: Any?, minimum: Int64) -> Int64? { LocalHealthClient.profileInteger(value).map(Int64.init).flatMap { $0 >= minimum ? $0 : nil } }
    private static func digest(_ value: Any?) -> String? { (value as? String).flatMap { LocalHealthClient.profileDigest($0) ? $0 : nil } }
    private static func id(_ value: Any?) -> String? { (value as? String).flatMap { LocalHealthClient.profileID($0) ? $0 : nil } }
}

// Pinned Home URI.new metadata grammar; never a transport address parser.
enum ExternalOriginalURI {
    private static let unreserved = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~".utf8)
    private static let sub = Set("!$&'()*+,;=".utf8)
    private static let name = unreserved.union(sub).union([37])
    private static let pchar = name.union([58, 64])
    static func valid(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (2...256).contains(bytes.count), bytes.allSatisfy({ (33...126).contains($0) }), let colon = bytes.firstIndex(of: 58), colon > 0 else { return false }
        let scheme = Array(bytes[..<colon])
        guard alpha(scheme[0]), scheme.allSatisfy({ alpha($0) || (48...57).contains($0) || [43, 45, 46].contains($0) }) else { return false }
        var rest = Array(bytes[(colon + 1)...])
        if let fragment = rest.firstIndex(of: 35) {
            guard rest[(fragment + 1)...].allSatisfy({ pchar.contains($0) || $0 == 47 || $0 == 63 }) else { return false }; rest = Array(rest[..<fragment])
        }
        if let query = rest.firstIndex(of: 63) {
            guard rest[(query + 1)...].allSatisfy({ pchar.contains($0) || $0 == 47 || $0 == 63 }) else { return false }; rest = Array(rest[..<query])
        }
        if rest.starts(with: [47, 47]) {
            rest.removeFirst(2)
            let slash = rest.firstIndex(of: 47) ?? rest.count
            guard rest[slash...].allSatisfy({ pchar.contains($0) || $0 == 47 }) else { return false }
            var authority = Array(rest[..<slash])
            if let at = authority.firstIndex(of: 64) {
                guard authority[..<at].allSatisfy({ name.contains($0) || $0 == 58 }) else { return false }; authority = Array(authority[(at + 1)...])
            }
            if authority.first == 91 {
                guard let close = authority.firstIndex(of: 93) else { return false }
                let host = String(decoding: authority[1..<close], as: UTF8.self)
                var address = in6_addr()
                guard host.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else { return false }
                authority = Array(authority[(close + 1)...])
                let port = authority.firstIndex(of: 58) ?? authority.count
                guard authority[..<port].allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) || $0 == 46 }) else { return false }
                return port == authority.count || validPort(Array(authority[(port + 1)...]))
            }
            let port = authority.firstIndex(of: 58) ?? authority.count
            return authority[..<port].allSatisfy(name.contains) && (port == authority.count || validPort(Array(authority[(port + 1)...])))
        }
        return rest.allSatisfy({ pchar.contains($0) || $0 == 47 })
    }
    private static func validPort(_ bytes: [UInt8]) -> Bool { bytes.count <= 5 && bytes.allSatisfy({ (48...57).contains($0) }) }
    private static func alpha(_ byte: UInt8) -> Bool { (65...90).contains(byte) || (97...122).contains(byte) }
}

// Bound tokens/containers before the complete Foundation tree is allocated.
private struct ExternalOriginalPreflight {
    let bytes: [UInt8], objects: Bool
    private var index = 0, nodes = 0
    init(bytes: [UInt8], objects: Bool) { self.bytes = bytes; self.objects = objects }
    mutating func check() throws { try value(depth: 0); space(); guard index == bytes.count else { throw LocalHealthError.invalidProfileRequest } }
    private mutating func value(depth: Int) throws {
        space(); nodes += 1
        guard nodes <= 4096, index < bytes.count else { throw LocalHealthError.invalidProfileRequest }
        switch bytes[index] {
        case 91, 123:
            let object = bytes[index] == 123, close: UInt8 = object ? 125 : 93
            guard depth < 8, !object || objects else { throw LocalHealthError.invalidProfileRequest }; index += 1; space()
            if take(close) { return }
            var count = 0, names: Set<String> = []
            while true {
                count += 1; guard count <= (object ? 32 : 256) else { throw LocalHealthError.invalidProfileRequest }
                if object {
                    nodes += 1; guard nodes <= 4096 else { throw LocalHealthError.invalidProfileRequest }
                    let key = try string(); guard names.insert(key).inserted else { throw LocalHealthError.invalidProfileRequest }; space(); guard take(58) else { throw LocalHealthError.invalidProfileRequest }
                }
                try value(depth: depth + 1); space()
                if take(close) { return }
                guard take(44) else { throw LocalHealthError.invalidProfileRequest }; space()
            }
        case 34: _ = try string()
        case 110:
            guard index + 4 <= bytes.count, Array(bytes[index..<(index + 4)]) == Array("null".utf8) else { throw LocalHealthError.invalidProfileRequest }; index += 4
        default:
            let start = index
            if take(45) {} // Owner wire accepts signed tokens; narrower fields reject negatives.
            while index < bytes.count, (48...57).contains(bytes[index]) { index += 1 }
            guard (1...20).contains(index - start), let value = Int64(String(decoding: bytes[start..<index], as: UTF8.self)), value != Int64.min else { throw LocalHealthError.invalidProfileRequest }
        }
    }
    private mutating func string() throws -> String {
        guard take(34) else { throw LocalHealthError.invalidProfileRequest }; let start = index - 1
        var escaped = false
        while index < bytes.count {
            let byte = bytes[index]; index += 1
            guard index - start <= 24578 else { throw LocalHealthError.invalidProfileRequest }
            if byte == 34 && !escaped {
                guard let text = try JSONSerialization.jsonObject(with: Data(bytes[start..<index]), options: .fragmentsAllowed) as? String,
                      text.utf8.count <= 4096 else { throw LocalHealthError.invalidProfileRequest }; return text
            }
            if byte == 92 && !escaped { escaped = true } else { escaped = false }
        }
        throw LocalHealthError.invalidProfileRequest
    }
    private mutating func space() { while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 } }
    private mutating func take(_ byte: UInt8) -> Bool { if index < bytes.count && bytes[index] == byte { index += 1; return true }; return false }
}
