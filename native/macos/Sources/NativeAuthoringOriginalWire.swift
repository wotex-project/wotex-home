import Foundation

enum NativeAuthoringReviewMode: String, CaseIterable, Sendable { case source, complete }

struct NativeAuthoringCitation: Sendable, Equatable, CustomReflectable {
    var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
    let path: String, source: String, locator: String
    var fields: [String: Any] { ["instance_path": path, "source_ref": source, "locator": locator] }
}
struct NativeAuthoringReviewContent: Sendable, CustomReflectable {
    let mode: NativeAuthoringReviewMode, evidence: [NativeAuthoringCitation], unresolved: [String], envelope: NativeAuthoringObjectHandle?
    var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
    func checkedFields() throws -> [String: Any] {
        guard evidence.count <= 256, unresolved.count <= 64,
              evidence.allSatisfy({ $0.path.utf8.count <= 512 && $0.source.utf8.count == 64 && $0.locator.utf8.count <= 256 }),
              unresolved.allSatisfy({ $0.utf8.count <= 512 }) else { throw LocalHealthError.invalidProfileRequest }
        let sorted = evidence.sorted { Self.precedes([$0.path, $0.source, $0.locator], [$1.path, $1.source, $1.locator]) }
        let roots = unresolved.sorted { Self.precedes([$0], [$1]) }
        let fields: [String: Any] = ["mode": mode.rawValue, "evidence": sorted.map(\.fields), "unresolved_paths": roots,
            "envelope_ref": envelope.map { $0.fields as Any } ?? NSNull()]
        try Self.validateFields(fields); return fields
    }
    static func validateFields(_ fields: [String: Any]) throws {
        guard Set(fields.keys) == Set(["mode", "evidence", "unresolved_paths", "envelope_ref"]) else { throw LocalHealthError.invalidProfileRequest }
        var review = fields
        review["candidate_ref"] = ["authority_epoch": 1, "operation_id": "content:check", "revision": 1,
            "input_sha256": String(repeating: "0", count: 64), "assessment_sha256": String(repeating: "0", count: 64)]
        _ = try NativeAuthoringOriginalWire.encode(["authority_epoch": 1, "operation_id": "content:check", "expected_revision": 0, "review": review], kind: .review)
    }
    private static func precedes(_ a: [String], _ b: [String]) -> Bool {
        for (left, right) in zip(a, b) {
            let x = Array(left.utf8), y = Array(right.utf8)
            if x != y { return x.lexicographicallyPrecedes(y) }
        }
        return false
    }
}

struct NativeAuthoringObjectHandle: Sendable {
    let digest: String, firstRevision: Int
    var fields: [String: Any] { ["object_digest": digest, "first_revision": firstRevision] }
}


struct HomeAuthoringOriginal: Sendable, Equatable, CustomReflectable {
    let kind: HomeAuthoringOriginalKind, epoch: Int64, operation: String, expectedRevision: Int64
    let canonical: Data
    var sha: String { LocalHealthClient.profileSHA(canonical) }
    var customMirror: Mirror { Mirror(self, children: ["kind": kind.rawValue, "epoch": epoch, "operation": operation]) }
    fileprivate init(kind: HomeAuthoringOriginalKind, epoch: Int64, operation: String, revision: Int64, canonical: Data) {
        self.kind = kind; self.epoch = epoch; self.operation = operation; self.expectedRevision = revision; self.canonical = canonical
    }
    func fields() throws -> [String: Any] {
        let (checked, fields) = try NativeAuthoringOriginalWire.checked(canonical, kind: kind)
        guard checked == self else { throw LocalHealthError.invalidProfileRequest }; return fields
    }
}

enum NativeAuthoringOriginalWire {
    private static let readers = ["max_bytes", "max_depth", "max_nodes", "max_channels", "max_definitions", "max_bindings", "max_dependencies", "max_numeric_digits"]
    private static let readerCeilings: [Int64] = [262_144, 8, 4096, 32, 32, 32, 32, 64]
    private static let limits = ["max_bundle_bytes", "max_diagnostics", "max_report_bytes", "max_check_steps"]
    private static let limitCeilings: [Int64] = [262_144, 64, 24_576, 1_000_000]
    private static let candidateKeys = ["authority_epoch", "operation_id", "revision", "input_sha256", "assessment_sha256"]
    private static let rootPattern = "\\A/(?:profile/(?:binding|fingerprint/(?:[0-9]|[12][0-9]|3[01])|channels/(?:[0-9]|[12][0-9]|3[01])/(?:selector|semantic|invalid_values|conversion))|definitions/(?:[0-9]|[12][0-9]|3[01])/(?:unit|value_schema))\\z"

    static func decode(_ bytes: Data, kind: HomeAuthoringOriginalKind) throws -> HomeAuthoringOriginal {
        try checked(bytes, kind: kind).0
    }
    static func nativeJSON(_ bytes: Data, kind: HomeAuthoringOriginalKind) throws -> HomeAuthoringOriginal {
        let maximum = kind == .import ? 4096 : kind == .candidate ? 65_536 : 262_144
        guard (1...maximum).contains(bytes.count) else { throw LocalHealthError.invalidProfileRequest }
        try StrictLocalJSON.check(bytes)
        guard let map = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw LocalHealthError.invalidProfileRequest }
        return try encode(map, kind: kind)
    }
    static func encode(_ fields: [String: Any], kind: HomeAuthoringOriginalKind) throws -> HomeAuthoringOriginal {
        let last = kind == .import ? "object" : kind == .candidate ? "request" : "review"
        guard keys(fields, ["authority_epoch", "operation_id", "expected_revision", last]),
              let epoch = integer(fields["authority_epoch"], minimum: 1), let revision = integer(fields["expected_revision"], minimum: 0),
              let operation = fields["operation_id"] as? String, LocalHealthClient.profileID(operation) else { throw LocalHealthError.invalidProfileRequest }
        let content: [Any]
        switch kind {
        case .import: content = try summary(fields[last])
        case .candidate: content = try candidate(fields[last])
        case .review: content = try review(fields[last])
        }
        let bytes = try JSONSerialization.data(withJSONObject: [format(kind), [epoch, operation, revision, content]], options: [.withoutEscapingSlashes])
        guard bytes.count <= maximum(kind) else { throw LocalHealthError.invalidProfileRequest }
        return HomeAuthoringOriginal(kind: kind, epoch: epoch, operation: operation, revision: revision, canonical: bytes)
    }
    fileprivate static func checked(_ bytes: Data, kind: HomeAuthoringOriginalKind) throws -> (HomeAuthoringOriginal, [String: Any]) {
        guard (1...maximum(kind)).contains(bytes.count) else { throw LocalHealthError.invalidProfileRequest }
        try StrictLocalJSON.check(bytes)
        guard let root = try JSONSerialization.jsonObject(with: bytes) as? [Any], root.count == 2, root[0] as? String == format(kind),
              let body = root[1] as? [Any], body.count == 4, let content = body[3] as? [Any] else { throw LocalHealthError.invalidProfileRequest }
        var fields: [String: Any] = ["authority_epoch": body[0], "operation_id": body[1], "expected_revision": body[2]]
        switch kind {
        case .import:
            guard content.count == 4 else { throw LocalHealthError.invalidProfileRequest }
            fields["object"] = map(["kind", "object_digest", "payload_sha256", "payload_bytes"], content)
        case .candidate:
            guard content.count == 7, let sources = content[3] as? [Any], let fixtures = content[4] as? [Any],
                  let selected = content[6] as? [Any], selected.count == 5, let reader = selected[0] as? [Any], reader.count == 8,
                  sources.count <= 32, fixtures.count <= 32 else { throw LocalHealthError.invalidProfileRequest }
            var selectedLimits = map(limits, Array(selected.dropFirst())); selectedLimits["reader"] = map(readers, reader)
            fields["request"] = ["mode": content[0], "contract_digest": content[1], "base_draft_ref": try nativeHandle(content[2]),
                "source_refs": try sources.map(nativeHandle), "fixture_refs": try fixtures.map(nativeHandle), "instruction": content[5], "limits": selectedLimits]
        case .review:
            guard content.count == 5, let candidate = content[1] as? [Any], candidate.count == 5,
                  let evidence = content[2] as? [Any], evidence.count <= 256 else { throw LocalHealthError.invalidProfileRequest }
            let records = try evidence.map { raw -> [String: Any] in
                guard let entry = raw as? [Any], entry.count == 3 else { throw LocalHealthError.invalidProfileRequest }
                return map(["instance_path", "source_ref", "locator"], entry)
            }
            fields["review"] = ["mode": content[0], "candidate_ref": map(candidateKeys, candidate), "evidence": records,
                "unresolved_paths": content[3], "envelope_ref": content[4] is NSNull ? NSNull() : try nativeHandle(content[4])]
        }
        let original = try encode(fields, kind: kind)
        guard original.canonical == bytes else { throw LocalHealthError.invalidProfileRequest }
        return (original, fields)
    }
    private static func summary(_ raw: Any?) throws -> [Any] {
        guard let value = raw as? [String: Any], keys(value, ["kind", "object_digest", "payload_sha256", "payload_bytes"]),
              let kind = value["kind"] as? String, ["source", "draft", "bundle", "fixture", "contract", "envelope", "profile", "definition"].contains(kind),
              let size = integer(value["payload_bytes"], minimum: 1), size <= (["source", "draft", "bundle", "contract"].contains(kind) ? 262_144 : 65_536),
              let object = digest(value["object_digest"]), let payload = digest(value["payload_sha256"]) else { throw LocalHealthError.invalidProfileRequest }
        return [kind, object, payload, size]
    }
    private static func candidate(_ raw: Any?) throws -> [Any] {
        guard let r = raw as? [String: Any], keys(r, ["mode", "contract_digest", "base_draft_ref", "source_refs", "fixture_refs", "instruction", "limits"]),
              r["mode"] as? String == "manual", let contract = digest(r["contract_digest"]), let instruction = r["instruction"] as? String,
              instruction.utf8.count <= 4096,
              instruction.replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\t", with: "").range(of: "\\p{Cc}", options: .regularExpression) == nil,
              let l = r["limits"] as? [String: Any], keys(l, ["reader"] + limits), let reader = l["reader"] as? [String: Any], keys(reader, readers) else { throw LocalHealthError.invalidProfileRequest }
        let readerValues = try selected(reader, fields: readers, ceilings: readerCeilings)
        let limitValues = try selected(l, fields: limits, ceilings: limitCeilings)
        return ["manual", contract, try handle(r["base_draft_ref"]), try handles(r["source_refs"]), try handles(r["fixture_refs"]), instruction, [readerValues] + limitValues.map { $0 as Any }]
    }
    private static func review(_ raw: Any?) throws -> [Any] {
        guard let r = raw as? [String: Any], keys(r, ["mode", "candidate_ref", "evidence", "unresolved_paths", "envelope_ref"]),
              let c = r["candidate_ref"] as? [String: Any], keys(c, candidateKeys), integer(c["authority_epoch"], minimum: 1) != nil,
              integer(c["revision"], minimum: 1) != nil, let operation = c["operation_id"] as? String, LocalHealthClient.profileID(operation),
              digest(c["input_sha256"]) != nil, digest(c["assessment_sha256"]) != nil,
              let records = r["evidence"] as? [[String: Any]], records.count <= 256,
              let paths = r["unresolved_paths"] as? [String], paths.count <= 64, paths.allSatisfy(root), strictlySorted(paths.map { [$0] }) else { throw LocalHealthError.invalidProfileRequest }
        let evidence = try records.map { entry -> [String] in
            guard keys(entry, ["instance_path", "source_ref", "locator"]), let path = entry["instance_path"] as? String, root(path),
                  let source = digest(entry["source_ref"]), let locator = entry["locator"] as? String,
                  (1...256).contains(locator.utf8.count), locator.range(of: "[\\p{Cc}\\p{Cf}]", options: .regularExpression) == nil else { throw LocalHealthError.invalidProfileRequest }
            return [path, source, locator]
        }
        guard strictlySorted(evidence) else { throw LocalHealthError.invalidProfileRequest }
        let envelope: Any
        if r["mode"] as? String == "source", r["envelope_ref"] is NSNull { envelope = NSNull() }
        else if r["mode"] as? String == "complete" { envelope = try handle(r["envelope_ref"]) }
        else { throw LocalHealthError.invalidProfileRequest }
        return [r["mode"]!, candidateKeys.map { c[$0]! }, evidence, paths, envelope]
    }
    private static func selected(_ map: [String: Any], fields: [String], ceilings: [Int64]) throws -> [Int64] {
        try zip(fields, ceilings).map { key, ceiling in
            guard let value = integer(map[key], minimum: 1), value <= ceiling else { throw LocalHealthError.invalidProfileRequest }; return value
        }
    }
    private static func handle(_ raw: Any?) throws -> [Any] {
        guard let h = raw as? [String: Any], keys(h, ["object_digest", "first_revision"]),
              let digest = digest(h["object_digest"]), let first = integer(h["first_revision"], minimum: 1) else { throw LocalHealthError.invalidProfileRequest }; return [digest, first]
    }
    private static func nativeHandle(_ raw: Any) throws -> [String: Any] {
        guard let pair = raw as? [Any], pair.count == 2 else { throw LocalHealthError.invalidProfileRequest }; return map(["object_digest", "first_revision"], pair)
    }
    private static func handles(_ raw: Any?) throws -> [[Any]] {
        guard let values = raw as? [Any], values.count <= 32 else { throw LocalHealthError.invalidProfileRequest }
        let result = try values.map(handle)
        guard strictlySorted(result.map { [$0[0] as! String] }) else { throw LocalHealthError.invalidProfileRequest }; return result
    }
    private static func strictlySorted(_ values: [[String]]) -> Bool {
        guard values.count > 1 else { return true }
        return zip(values, values.dropFirst()).allSatisfy { left, right in
            for (a, b) in zip(left, right) {
                let x = Array(a.utf8), y = Array(b.utf8)
                if x != y { return x.lexicographicallyPrecedes(y) }
            }
            return false
        }
    }
    private static func root(_ string: String) -> Bool { string.utf8.count <= 512 && string.range(of: rootPattern, options: .regularExpression) != nil }
    private static func integer(_ raw: Any?, minimum: Int64) -> Int64? { guard let value = LocalHealthClient.profileInteger(raw).map(Int64.init), value >= minimum else { return nil }; return value }
    private static func digest(_ raw: Any?) -> String? { guard let value = raw as? String, LocalHealthClient.profileDigest(value) else { return nil }; return value }
    private static func keys(_ map: [String: Any], _ expected: [String]) -> Bool { Set(map.keys) == Set(expected) }
    private static func map(_ keys: [String], _ values: [Any]) -> [String: Any] { Dictionary(uniqueKeysWithValues: zip(keys, values)) }
    private static func format(_ kind: HomeAuthoringOriginalKind) -> String { "wotex-home.authoring-" + kind.rawValue + ".v1" }
    private static func maximum(_ kind: HomeAuthoringOriginalKind) -> Int { kind == .import ? 4096 : kind == .candidate ? 32768 : 131072 }
}
