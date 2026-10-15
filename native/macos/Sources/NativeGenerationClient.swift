import CoreFoundation
import Foundation

enum NativeGenerationDeliveryError: LocalizedError {
    case outcomeUnknown
    var errorDescription: String? { "Generation delivery is uncertain. Look up the retained original before continuing." }
}

struct HomeGenerationAssessment: Sendable, Equatable, CustomReflectable {
    let disposition: String, phase: String, draftSHA: String, bundleSHA: String?
    fileprivate let canonical: Data
    var sha: String { LocalHealthClient.profileSHA(canonical) }
    var customMirror: Mirror { Mirror(self, children: ["disposition": disposition, "phase": phase]) }
    fileprivate init(_ fields: [String: Any], _ bytes: Data) {
        disposition = fields["disposition"] as! String; phase = fields["phase"] as! String
        draftSHA = fields["draft_sha256"] as! String; bundleSHA = fields["bundle_sha256"] as? String; canonical = bytes
    }
    func fields() throws -> [String: Any] {
        let value = try NativeGenerationResultWire.decodeAssessment(canonical)
        guard value == self else { throw LocalHealthError.invalidResponse }
        return try NativeGenerationResultWire.assessmentFields(canonical)
    }
}

struct HomeGenerationResult: Sendable, Equatable, CustomReflectable {
    let disposition: String, reason: String?, assessment: HomeGenerationAssessment?
    fileprivate let canonical: Data
    var customMirror: Mirror { Mirror(self, children: ["disposition": disposition]) }
    fileprivate init(_ fields: [String: Any], _ bytes: Data, _ assessment: HomeGenerationAssessment?) {
        disposition = fields["disposition"] as! String; reason = fields["reason"] as? String
        canonical = bytes; self.assessment = assessment
    }
    func fields() throws -> [String: Any] {
        guard try NativeGenerationResultWire.decode(canonical) == self else { throw LocalHealthError.invalidResponse }
        return try NativeGenerationResultWire.resultFields(canonical)
    }
}

struct HomeGenerationOptions: Sendable, Equatable, CustomReflectable {
    let principal: String, epoch: Int64, revision: Int64, policyCount: Int
    fileprivate let canonical: Data
    var customMirror: Mirror { Mirror(self, children: ["epoch": epoch, "revision": revision, "policyCount": Int64(policyCount)]) }
    fileprivate init(_ fields: [String: Any], _ bytes: Data) {
        principal = fields["principal_id"] as! String; epoch = NativeGenerationResultWire.integer(fields["authority_epoch"], minimum: 1)!
        revision = NativeGenerationResultWire.integer(fields["store_revision"], minimum: 0)!; policyCount = (fields["policies"] as! [Any]).count
        canonical = bytes
    }
    func fields() throws -> [String: Any] {
        guard let fields = try JSONSerialization.jsonObject(with: canonical) as? [String: Any],
              try NativeGenerationClient.options(fields) == self else { throw LocalHealthError.invalidResponse }
        return fields
    }
}

struct HomeGenerationStatus: Sendable, Equatable, CustomReflectable {
    let original: HomeGenerationReservation, state: String
    let cancellationRevision: Int64?, resultRevision: Int64?, result: HomeGenerationResult?
    var knownRevision: Int64 { max(original.revision, cancellationRevision ?? 0, resultRevision ?? 0) }
    var customMirror: Mirror { Mirror(self, children: ["state": state]) }
    fileprivate init(original: HomeGenerationReservation, state: String, cancellation: Int64? = nil,
                     resultRevision: Int64? = nil, result: HomeGenerationResult? = nil) {
        self.original = original; self.state = state; cancellationRevision = cancellation
        self.resultRevision = resultRevision; self.result = result
    }
}

enum HomeGenerationReply: Sendable {
    case options(HomeGenerationOptions), reservation(HomeGenerationReservation), status(HomeGenerationStatus), notFound
}

enum NativeGenerationResultWire {
    private static let assessmentKeys = ["format", "basis_sha256", "draft_sha256", "bundle_sha256", "phase", "disposition", "capture_status", "report", "home_consumption", "source_review", "fixture_status"]
    private static let reportKeys = ["format", "contract_sha256", "candidate_sha256", "disposition", "capture_status", "diagnostics", "truncated"]
    private static let diagnosticKeys = ["phase", "code", "instance_path", "rule_id", "repair"]
    private static let resultKeys = ["disposition", "reason", "draft_ref", "bundle_ref", "assessment"]
    static let outcomes = ["candidate", "unavailable", "invalid_response", "unknown", "deadline_expired", "cancelled", "withdrawn", "capacity"]

    static func assessment(_ fields: [String: Any]) throws -> HomeGenerationAssessment {
        guard exact(fields, assessmentKeys), fields["format"] as? String == "wotex-home.authoring-mechanics@1",
              digest(fields["basis_sha256"]), digest(fields["draft_sha256"]),
              null(fields["bundle_sha256"]) || digest(fields["bundle_sha256"]),
              let phase = fields["phase"] as? String, let disposition = fields["disposition"] as? String,
              ["compatible", "invalid"].contains(disposition),
              fields["capture_status"] as? String == "not_supplied", fields["fixture_status"] as? String == "not_supplied",
              fields["home_consumption"] as? String == "not_assessed", fields["source_review"] as? String == "not_assessed",
              (phase == "finalize" && null(fields["bundle_sha256"]) && disposition == "invalid") ||
                (phase == "validate" && digest(fields["bundle_sha256"])),
              let report = fields["report"] as? [String: Any], exact(report, reportKeys),
              report["format"] as? String == "wotex.profile.validation-report@1", digest(report["contract_sha256"]),
              report["candidate_sha256"] as? String == (fields["bundle_sha256"] as? String ?? fields["draft_sha256"] as? String),
              report["disposition"] as? String == disposition, report["capture_status"] as? String == "not_supplied",
              let truncated = boolean(report["truncated"]), let diagnostics = report["diagnostics"] as? [[String: Any]], diagnostics.count <= 64,
              disposition == "compatible" ? diagnostics.isEmpty && !truncated : !diagnostics.isEmpty else { throw LocalHealthError.invalidResponse }
        for diagnostic in diagnostics {
            guard exact(diagnostic, diagnosticKeys), let phase = diagnostic["phase"] as? String,
                  ["syntax", "shape", "semantic", "binding", "capture"].contains(phase),
                  text(diagnostic["code"], maximum: 128), text(diagnostic["rule_id"], maximum: 128), text(diagnostic["repair"], maximum: 128),
                  diagnostic["instance_path"] as? String == "" || text(diagnostic["instance_path"], maximum: 512) else { throw LocalHealthError.invalidResponse }
        }
        var reportValues = reportKeys.map { report[$0]! }
        reportValues[5] = diagnostics.map { d in diagnosticKeys.map { d[$0]! } }
        var values = assessmentKeys.map { fields[$0]! }; values[7] = reportValues
        let bytes = try canonical(values, maximum: 65_536)
        return HomeGenerationAssessment(fields, bytes)
    }
    static func encode(_ fields: [String: Any]) throws -> HomeGenerationResult {
        guard exact(fields, resultKeys), let disposition = fields["disposition"] as? String, outcomes.contains(disposition) else { throw LocalHealthError.invalidResponse }
        var a: HomeGenerationAssessment?
        if disposition == "candidate" {
            guard null(fields["reason"]), let draft = fields["draft_ref"] as? [String: Any],
                  let raw = fields["assessment"] as? [String: Any] else { throw LocalHealthError.invalidResponse }
            _ = try reference(draft); a = try assessment(raw)
            guard null(fields["bundle_ref"]) == (a!.bundleSHA == nil) else { throw LocalHealthError.invalidResponse }
            if !null(fields["bundle_ref"]) { _ = try reference(fields["bundle_ref"]) }
        } else {
            guard null(fields["draft_ref"]), null(fields["bundle_ref"]), null(fields["assessment"]),
                  disposition == "withdrawn" ? ["actor", "epoch", "maintenance", "policy", "basis", "source", "store"].contains(fields["reason"] as? String ?? "") : null(fields["reason"]) else { throw LocalHealthError.invalidResponse }
        }
        let values: [Any] = [disposition, fields["reason"]!, try optionalReference(fields["draft_ref"]),
            try optionalReference(fields["bundle_ref"]), try a.map { try JSONSerialization.jsonObject(with: $0.canonical) } ?? NSNull()]
        return HomeGenerationResult(fields, try canonical(values, maximum: 131_072), a)
    }
    static func decode(_ bytes: Data) throws -> HomeGenerationResult {
        let result = try encode(resultFields(bytes))
        guard result.canonical == bytes else { throw LocalHealthError.invalidResponse }; return result
    }
    static func decodeAssessment(_ bytes: Data) throws -> HomeGenerationAssessment {
        let result = try assessment(assessmentFields(bytes))
        guard result.canonical == bytes else { throw LocalHealthError.invalidResponse }; return result
    }
    fileprivate static func resultFields(_ bytes: Data) throws -> [String: Any] {
        let values = try array(bytes, count: 5, maximum: 131_072)
        var fields = map(resultKeys, values)
        fields["draft_ref"] = try nativeReference(values[2]); fields["bundle_ref"] = try nativeReference(values[3])
        fields["assessment"] = values[4] is NSNull ? NSNull() : try assessmentNative(values[4])
        return fields
    }
    fileprivate static func assessmentFields(_ bytes: Data) throws -> [String: Any] {
        try assessmentNative(array(bytes, count: 11, maximum: 65_536))
    }
    private static func assessmentNative(_ raw: Any) throws -> [String: Any] {
        guard let values = raw as? [Any], values.count == 11, let r = values[7] as? [Any], r.count == 7,
              let diagnostics = r[5] as? [[Any]], diagnostics.count <= 64,
              diagnostics.allSatisfy({ $0.count == 5 }) else { throw LocalHealthError.invalidResponse }
        var report = map(reportKeys, r); report["diagnostics"] = diagnostics.map { map(diagnosticKeys, $0) }
        var fields = map(assessmentKeys, values); fields["report"] = report; return fields
    }
    private static func reference(_ raw: Any?) throws -> [Any] {
        guard let fields = raw as? [String: Any], exact(fields, ["object_digest", "first_revision"]),
              digest(fields["object_digest"]), let revision = integer(fields["first_revision"], minimum: 1) else { throw LocalHealthError.invalidResponse }
        return [fields["object_digest"]!, revision]
    }
    private static func optionalReference(_ raw: Any?) throws -> Any { null(raw) ? NSNull() : try reference(raw) }
    private static func nativeReference(_ raw: Any) throws -> Any {
        if raw is NSNull { return NSNull() }
        guard let values = raw as? [Any], values.count == 2 else { throw LocalHealthError.invalidResponse }
        return map(["object_digest", "first_revision"], values)
    }
    private static func array(_ bytes: Data, count: Int, maximum: Int) throws -> [Any] {
        guard (1...maximum).contains(bytes.count) else { throw LocalHealthError.invalidResponse }
        try canonicalBounds(bytes)
        guard let values = try JSONSerialization.jsonObject(with: bytes) as? [Any], values.count == count else { throw LocalHealthError.invalidResponse }
        return values
    }
    private static func canonicalBounds(_ bytes: Data) throws {
        let b = Array(bytes)
        var i = 0, nodes = 0, counts: [Int] = []
        while i < b.count {
            let byte = b[i]
            if byte == 32 || byte == 9 || byte == 10 || byte == 13 || byte == 44 { i += 1; continue }
            if byte == 93 {
                guard !counts.isEmpty else { throw LocalHealthError.invalidResponse }
                counts.removeLast(); i += 1; continue
            }
            nodes += 1
            guard nodes <= 4096 else { throw LocalHealthError.invalidResponse }
            if let last = counts.indices.last {
                counts[last] += 1
                guard counts[last] <= 256 else { throw LocalHealthError.invalidResponse }
            }
            if byte == 91 {
                guard counts.count < 8 else { throw LocalHealthError.invalidResponse }
                counts.append(0); i += 1
            } else if byte == 34 {
                let start = i; i += 1
                var escaped = false
                while i < b.count {
                    if !escaped && b[i] == 34 { break }
                    if !escaped && b[i] == 92 { escaped = true } else { escaped = false }
                    i += 1
                    guard i - start <= 4096 * 6 + 1 else { throw LocalHealthError.invalidResponse }
                }
                guard i < b.count, let text = try JSONSerialization.jsonObject(with: Data(b[start...i]), options: .fragmentsAllowed) as? String,
                      text.utf8.count <= 4096 else { throw LocalHealthError.invalidResponse }
                i += 1
            } else {
                guard byte == 45 || (48...57).contains(byte) || byte == 116 || byte == 102 || byte == 110 else { throw LocalHealthError.invalidResponse }
                let start = i
                while i < b.count && ![9, 10, 13, 32, 44, 93].contains(b[i]) {
                    i += 1
                    guard i - start <= 32 else { throw LocalHealthError.invalidResponse }
                }
            }
        }
        guard counts.isEmpty else { throw LocalHealthError.invalidResponse }
    }
    fileprivate static func canonical(_ values: [Any], maximum: Int) throws -> Data {
        let bytes = try JSONSerialization.data(withJSONObject: values, options: [.withoutEscapingSlashes])
        guard bytes.count <= maximum else { throw LocalHealthError.invalidResponse }; return bytes
    }
    fileprivate static func exact(_ fields: [String: Any], _ keys: [String]) -> Bool { Set(fields.keys) == Set(keys) }
    fileprivate static func map(_ keys: [String], _ values: [Any]) -> [String: Any] { Dictionary(uniqueKeysWithValues: zip(keys, values)) }
    fileprivate static func null(_ value: Any?) -> Bool { value is NSNull }
    fileprivate static func integer(_ value: Any?, minimum: Int64) -> Int64? {
        if let value, type(of: value) == Int64.self {
            let integer = value as! Int64
            return integer >= minimum ? integer : nil
        }
        guard let n = LocalHealthClient.profileInteger(value), Int64(n) >= minimum else { return nil }; return Int64(n)
    }
    fileprivate static func digest(_ value: Any?) -> Bool { (value as? String).map(LocalHealthClient.profileDigest) ?? false }
    fileprivate static func boolean(_ value: Any?) -> Bool? {
        guard let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }; return n.boolValue
    }
    private static func text(_ value: Any?, maximum: Int) -> Bool {
        guard let s = value as? String, (1...maximum).contains(s.utf8.count) else { return false }
        return !s.unicodeScalars.contains { $0.properties.generalCategory == .control || $0.properties.generalCategory == .format }
    }
}

enum NativeGenerationClient {
    static let operations = ["authoring_generation_options", "authoring_generation_prepare", "authoring_generation_status",
        "authoring_generation_start", "authoring_generation_attempt_status", "authoring_generation_cancel"]
    static func fetchOptions(socketPath: String, credential: Data) throws -> HomeGenerationOptions {
        let reply = try decode(transport(socketPath, credential, operations[0], [:]), operation: operations[0])
        guard case .options(let options) = reply else { throw LocalHealthError.invalidResponse }; return options
    }
    static func status(socketPath: String, credential: Data, kind: HomeGenerationOriginalKind, epoch: Int64,
                       operation: String, original: HomeGenerationOriginal? = nil) throws -> HomeGenerationStatus? {
        guard epoch > 0, LocalHealthClient.profileID(operation), original.map({ $0.kind == kind && $0.epoch == epoch && $0.operation == operation }) != false else { throw LocalHealthError.invalidProfileRequest }
        if let original { _ = try original.fields() }
        let route = kind == .preparation ? operations[2] : operations[4]
        let reply = try decode(transport(socketPath, credential, route, ["authority_epoch": epoch, "operation_id": operation]),
            operation: route, epoch: epoch, id: operation, original: original)
        if case .notFound = reply { return nil }
        guard case .status(let status) = reply else { throw LocalHealthError.invalidResponse }; return status
    }
    static func submit(socketPath: String, credential: Data, original: HomeGenerationOriginal) throws -> HomeGenerationReservation {
        guard credential.count == 32 else { throw LocalHealthError.invalidCredential }
        let fields = try original.fields(), route = original.kind == .preparation ? operations[1] : operations[3]
        do {
            let reply = try decode(transport(socketPath, credential, route, ["input": fields]), operation: route, original: original)
            guard case .reservation(let receipt) = reply else { throw LocalHealthError.invalidResponse }; return receipt
        } catch LocalHealthError.server(let reason) {
            if reason == "outcome_unknown" { throw NativeGenerationDeliveryError.outcomeUnknown }; throw LocalHealthError.server(reason)
        } catch { throw NativeGenerationDeliveryError.outcomeUnknown }
    }
    static func cancel(socketPath: String, credential: Data, original: HomeGenerationOriginal) throws -> HomeGenerationStatus? {
        guard credential.count == 32 else { throw LocalHealthError.invalidCredential }
        guard original.kind == .preparation else { throw LocalHealthError.invalidProfileRequest }; _ = try original.fields()
        do {
            let reply = try decode(transport(socketPath, credential, operations[5], ["authority_epoch": original.epoch, "operation_id": original.operation]),
                operation: operations[5], epoch: original.epoch, id: original.operation, original: original)
            if case .notFound = reply { return nil }
            guard case .status(let value) = reply else { throw LocalHealthError.invalidResponse }; return value
        } catch LocalHealthError.server(let reason) {
            if reason == "outcome_unknown" { throw NativeGenerationDeliveryError.outcomeUnknown }; throw LocalHealthError.server(reason)
        } catch { throw NativeGenerationDeliveryError.outcomeUnknown }
    }
    static func deliver(socketPath: String, credential: Data, original: HomeGenerationOriginal, lookup: Bool) throws -> HomeGenerationStatus? {
        if let result = try status(socketPath: socketPath, credential: credential, kind: original.kind, epoch: original.epoch, operation: original.operation, original: original) { return result }
        if lookup { return nil }
        _ = try submit(socketPath: socketPath, credential: credential, original: original)
        do {
            guard let result = try status(socketPath: socketPath, credential: credential, kind: original.kind, epoch: original.epoch, operation: original.operation, original: original) else { throw NativeGenerationDeliveryError.outcomeUnknown }
            return result
        } catch { throw NativeGenerationDeliveryError.outcomeUnknown }
    }
    private static func transport(_ socket: String, _ credential: Data, _ operation: String, _ fields: [String: Any]) throws -> [String: Any] {
        try LocalHealthClient.generationTransport(socketPath: socket, credential: credential, operation: operation, fields: fields)
    }
    static func decode(_ response: [String: Any], operation: String, epoch: Int64? = nil, id: String? = nil,
                       original: HomeGenerationOriginal? = nil) throws -> HomeGenerationReply {
        guard operations.contains(operation), NativeGenerationResultWire.integer(response["api_version"], minimum: 1) == 1 else { throw LocalHealthError.invalidResponse }
        if response["outcome"] as? String == "error" {
            guard NativeGenerationResultWire.exact(response, ["api_version", "outcome", "reason"]), let reason = response["reason"] as? String, validReason(reason) else { throw LocalHealthError.invalidResponse }
            throw LocalHealthError.server(reason)
        }
        if response["outcome"] as? String == "not_found" {
            guard operation != operations[0], NativeGenerationResultWire.exact(response, ["api_version", "outcome"]) else { throw LocalHealthError.invalidResponse }; return .notFound
        }
        let member = operation == operations[0] ? operations[0] : operation == operations[1] ? "authoring_generation_receipt" :
            operation == operations[3] ? "authoring_generation_attempt_receipt" : operation == operations[4] ? "authoring_generation_attempt" : "authoring_generation"
        guard response["outcome"] as? String == "ok", NativeGenerationResultWire.exact(response, ["api_version", "outcome", member]),
              let fields = response[member] as? [String: Any] else { throw LocalHealthError.invalidResponse }
        if operation == operations[0] { return .options(try options(fields)) }
        let kind: HomeGenerationOriginalKind = (operation == operations[3] || operation == operations[4]) ? .attempt : .preparation
        if operation == operations[1] || operation == operations[3] {
            guard let original, original.kind == kind else { throw LocalHealthError.invalidResponse }
            let receipt = try NativeGenerationOriginalWire.reservation(fields, kind: kind); try receipt.matches(original); return .reservation(receipt)
        }
        let expected = kind == .preparation ? ["original", "state", "cancellation_revision"] : ["original", "state", "result", "result_revision"]
        guard NativeGenerationResultWire.exact(fields, expected), let raw = fields["original"] as? [String: Any], let state = fields["state"] as? String else { throw LocalHealthError.invalidResponse }
        let receipt = try NativeGenerationOriginalWire.reservation(raw, kind: kind)
        guard receipt.epoch == (epoch ?? original?.epoch), receipt.operation == (id ?? original?.operation) else { throw LocalHealthError.invalidResponse }
        if let original { try receipt.matches(original) }
        if kind == .preparation {
            guard ["prepared", "expired", "retired", "cancelled"].contains(state), operation != operations[5] || state == "cancelled" else { throw LocalHealthError.invalidResponse }
            let cancellation = NativeGenerationResultWire.integer(fields["cancellation_revision"], minimum: 1)
            guard state == "cancelled" ? cancellation.map({ $0 > receipt.revision }) == true : NativeGenerationResultWire.null(fields["cancellation_revision"]) else { throw LocalHealthError.invalidResponse }
            return .status(HomeGenerationStatus(original: receipt, state: state, cancellation: cancellation))
        }
        if NativeGenerationResultWire.null(fields["result"]) {
            guard NativeGenerationResultWire.null(fields["result_revision"]), ["running", "unknown", "cancelled"].contains(state) else { throw LocalHealthError.invalidResponse }
            return .status(HomeGenerationStatus(original: receipt, state: state))
        }
        guard let rawResult = fields["result"] as? [String: Any], let revision = NativeGenerationResultWire.integer(fields["result_revision"], minimum: 1), revision > receipt.revision else { throw LocalHealthError.invalidResponse }
        let result = try NativeGenerationResultWire.encode(rawResult)
        guard state == result.disposition else { throw LocalHealthError.invalidResponse }
        return .status(HomeGenerationStatus(original: receipt, state: state, resultRevision: revision, result: result))
    }
    static func options(_ fields: [String: Any]) throws -> HomeGenerationOptions {
        guard NativeGenerationResultWire.exact(fields, ["format", "principal_id", "authority_epoch", "store_revision", "policies"]),
              fields["format"] as? String == "wotex-home.generation-options@1", let principal = fields["principal_id"] as? String, LocalHealthClient.profileID(principal),
              NativeGenerationResultWire.integer(fields["authority_epoch"], minimum: 1) != nil,
              NativeGenerationResultWire.integer(fields["store_revision"], minimum: 0) != nil,
              let policies = fields["policies"] as? [[String: Any]], policies.count <= 32 else { throw LocalHealthError.invalidResponse }
        var previous: String?
        for p in policies {
            guard NativeGenerationResultWire.exact(p, ["provider", "provider_sha256", "policy_sha256", "remote_export", "passages", "examples", "limits", "provider_present"]),
                  let provider = p["provider"] as? [String: Any], NativeGenerationResultWire.exact(provider, ["id", "model_id", "adapter_sha256", "locality"]),
                  let id = provider["id"] as? String, LocalHealthClient.profileID(id),
                  let model = provider["model_id"] as? String, LocalHealthClient.profileID(model),
                  NativeGenerationResultWire.digest(provider["adapter_sha256"]), let locality = provider["locality"] as? String, ["local", "remote"].contains(locality),
                  NativeGenerationResultWire.boolean(p["provider_present"]) != nil, let remote = NativeGenerationResultWire.boolean(p["remote_export"]),
                  locality != "local" || !remote, previous.map({ $0 < id }) != false else { throw LocalHealthError.invalidResponse }
            previous = id
            let providerValues: [Any] = [id, model, provider["adapter_sha256"]!, locality]
            let providerBytes = try NativeGenerationResultWire.canonical(providerValues, maximum: 4096)
            guard p["provider_sha256"] as? String == LocalHealthClient.profileSHA(Data("wotex-home.generation-provider@1\n".utf8) + providerBytes) else { throw LocalHealthError.invalidResponse }
            let projection: [String: Any] = ["contract_digest": String(repeating: "0", count: 64), "instruction": "", "passages": p["passages"]!, "examples": p["examples"]!, "limits": p["limits"]!]
            let dummy: [String: Any] = ["authority_epoch": 1, "operation_id": "metadata:policy", "expected_revision": 0,
                "provider_sha256": p["provider_sha256"]!, "policy_sha256": String(repeating: "0", count: 64), "remote_export": remote,
                "projection": projection, "budget": ["attempts": 1, "attempt_ms": 1, "total_ms": 1]]
            let checked: HomeGenerationOriginal
            do { checked = try NativeGenerationOriginalWire.encode(dummy, kind: .preparation) }
            catch { throw LocalHealthError.invalidResponse }
            let root = try JSONSerialization.jsonObject(with: checked.canonical) as! [Any], values = root[1] as! [Any], pv = values[6] as! [Any]
            let policyBytes = try NativeGenerationResultWire.canonical([principal, providerValues, remote, pv[2], pv[3], pv[4]], maximum: 32768)
            guard p["policy_sha256"] as? String == LocalHealthClient.profileSHA(Data("wotex-home.generation-policy@1\n".utf8) + policyBytes) else { throw LocalHealthError.invalidResponse }
        }
        let bytes = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys, .withoutEscapingSlashes])
        guard bytes.count <= 1_048_576 else { throw LocalHealthError.invalidResponse }; return HomeGenerationOptions(fields, bytes)
    }
    static func validReason(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        return (1...128).contains(bytes.count) && (97...122).contains(bytes[0]) && bytes.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }
    }
}
