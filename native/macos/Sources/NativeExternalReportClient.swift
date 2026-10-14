import CoreFoundation
import Foundation

struct HomeExternalReportedValue: Sendable {
    let coordinate: String, unit: String, semantic: String, consumer: String
    let source: String, sourceEpoch: String, sequence: String
    let document: Data
}

struct HomeExternalReport: Sendable {
    let target: String, key: String, epoch: Int64, revision: Int64
    let selectionRevision: Int64, resourceRevision: Int64, reportRevision: Int64?
    let freshness: String, reason: String?, ageMilliseconds: Int64?, remainingMilliseconds: Int64
    let value: HomeExternalReportedValue?

    func displayedValue(elapsedMilliseconds: Int64) -> HomeExternalReportedValue? {
        guard freshness == "fresh", elapsedMilliseconds >= 0,
              elapsedMilliseconds < remainingMilliseconds else { return nil }
        return value
    }
    func displayedFreshness(elapsedMilliseconds: Int64) -> String {
        freshness == "fresh" && displayedValue(elapsedMilliseconds: elapsedMilliseconds) == nil ? "expired" : freshness
    }
}

enum NativeExternalReportClient {
    static func fetch(socketPath: String, credential: Data, target: String, key: String) throws -> HomeExternalReport {
        let response = try LocalHealthClient.externalReportTransport(socketPath: socketPath, credential: credential, target: target, key: key)
        return try decode(response, target: target, key: key)
    }

    static func decode(_ response: [String: Any], target: String, key: String) throws -> HomeExternalReport {
        guard LocalHealthClient.profileID(target), LocalHealthClient.profileID(key),
              Set(response.keys) == Set(["api_version", "outcome", "external_report_preview"]),
              integer(response["api_version"]) == 1, response["outcome"] as? String == "ok",
              let item = response["external_report_preview"] as? [String: Any],
              Set(item.keys) == Set(["format", "target_id", "capability_key", "store_revision", "authority_epoch", "selection_revision", "resource_revision", "report_revision", "value", "freshness", "reason", "age_ms", "remaining_ms"]),
              item["format"] as? String == "home-external-reported-value-v1",
              item["target_id"] as? String == target, item["capability_key"] as? String == key,
              let revision = integer(item["store_revision"]), revision >= 0,
              let epoch = integer(item["authority_epoch"]), epoch > 0,
              let selection = integer(item["selection_revision"]), selection > 0, selection <= revision,
              let resource = integer(item["resource_revision"]), resource >= 0, resource <= revision,
              let remaining = integer(item["remaining_ms"]), remaining >= 0,
              item["age_ms"] is NSNull || integer(item["age_ms"]).map({ $0 >= 0 }) == true,
              item["report_revision"] is NSNull || integer(item["report_revision"]).map({ $0 > 0 && $0 <= revision }) == true,
              let freshness = item["freshness"] as? String, ["fresh", "unknown", "stale", "missing"].contains(freshness) else { throw LocalHealthError.invalidResponse }
        let report = integer(item["report_revision"]), age = integer(item["age_ms"])
        let reason: String?, value: HomeExternalReportedValue?
        if freshness == "fresh" {
            guard item["reason"] is NSNull, report != nil, let age, remaining > 0, remaining <= 86_400_000,
                  age <= 86_400_000 - remaining,
                  let raw = item["value"] as? [String: Any] else { throw LocalHealthError.invalidResponse }
            reason = nil; value = try decodeValue(raw, key: key)
        } else {
            guard item["value"] is NSNull, remaining == 0,
                  let cause = item["reason"] as? String, !cause.isEmpty, cause.utf8.count <= 128 else { throw LocalHealthError.invalidResponse }
            if freshness == "missing" { guard report == nil, age == nil else { throw LocalHealthError.invalidResponse } }
            if freshness == "stale" { guard report != nil, age != nil else { throw LocalHealthError.invalidResponse } }
            reason = cause; value = nil
        }
        return HomeExternalReport(target: target, key: key, epoch: epoch, revision: revision,
            selectionRevision: selection, resourceRevision: resource, reportRevision: report,
            freshness: freshness, reason: reason, ageMilliseconds: age, remainingMilliseconds: remaining, value: value)
    }

    private static func decodeValue(_ item: [String: Any], key: String) throws -> HomeExternalReportedValue {
        var nodes = 0
        guard bounded(item, depth: 0, nodes: &nodes),
              Set(item.keys) == Set(["affordance", "capture_digest", "channel_id", "closure_sha256", "compiler_ref", "consumption_sha256", "continuity", "contract_ref", "contract_sha256", "format", "interpretation", "normalized_value", "profile_sha256", "quality", "quality_reason", "receipt_time", "semantic", "sequence", "source_epoch", "source_ref", "source_time", "unit", "value_kind"]),
              item["format"] as? String == "wotex-home.external-value@1",
              let channel = item["channel_id"] as? String, LocalHealthClient.profileID(channel),
              item["quality"] as? String == "usable", item["quality_reason"] is NSNull,
              let continuity = item["continuity"] as? String, ["baseline", "continuous"].contains(continuity),
              let interpretation = item["interpretation"] as? String, ["profile_declared", "unconverted"].contains(interpretation),
              let source = item["source_ref"] as? String, LocalHealthClient.profileID(source),
              let sourceEpoch = hex(item["source_epoch"], count: 32),
              let sequence = item["sequence"] as? String, UInt64(sequence) != nil, canonicalUnsigned(sequence),
              let semantic = reference(item["semantic"]), let consumer = reference(item["contract_ref"]), reference(item["compiler_ref"]) != nil,
              ["capture_digest", "closure_sha256", "consumption_sha256", "contract_sha256", "profile_sha256"].allSatisfy({ hex(item[$0], count: 64) != nil }),
              let affordance = item["affordance"] as? [String: Any], Set(affordance.keys) == Set(["kind", "name"]),
              let affordanceKind = affordance["kind"] as? String, ["property", "event", "action"].contains(affordanceKind),
              let name = affordance["name"] as? String, LocalHealthClient.profileID(name),
              let receipt = item["receipt_time"] as? [String: Any], Set(receipt.keys) == Set(["epoch", "monotonic_us"]),
              hex(receipt["epoch"], count: 32) != nil, signedString(receipt["monotonic_us"]) != nil,
              item["source_time"] is NSNull || item["source_time"] is [String: Any],
              item["unit"] is NSNull || item["unit"] is [String: Any],
              let normalized = item["normalized_value"] as? [String: Any], let type = normalized["type"] as? String, type != "null",
              let kind = item["value_kind"] as? String, ["integer", "boolean", "external"].contains(kind) else { throw LocalHealthError.invalidResponse }
        let coordinate: String
        switch kind {
        case "integer":
            guard Set(normalized.keys) == Set(["type", "value"]), type == "sint",
                  let value = signedString(normalized["value"]), item["unit"] is [String: Any] else { throw LocalHealthError.invalidResponse }
            coordinate = value
        case "boolean":
            guard Set(normalized.keys) == Set(["type", "value"]), type == "boolean", item["unit"] is NSNull,
                  let value = normalized["value"] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { throw LocalHealthError.invalidResponse }
            coordinate = value.boolValue ? "true" : "false"
        default: coordinate = try json(normalized)
        }
        let document = try JSONSerialization.data(withJSONObject: item, options: [.sortedKeys, .withoutEscapingSlashes])
        guard document.count <= 65_536 else { throw LocalHealthError.invalidResponse }
        return HomeExternalReportedValue(coordinate: coordinate, unit: try json(item["unit"]!), semantic: semantic, consumer: consumer,
            source: source, sourceEpoch: sourceEpoch, sequence: sequence, document: document)
    }

    private static func integer(_ value: Any?) -> Int64? { LocalHealthClient.profileInteger(value).map(Int64.init) }
    private static func signedString(_ value: Any?) -> String? {
        guard let text = value as? String, let number = Int64(text), String(number) == text else { return nil }; return text
    }
    private static func canonicalUnsigned(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy({ (48...57).contains($0) }) && (value == "0" || value.first != "0")
    }
    private static func hex(_ value: Any?, count: Int) -> String? {
        guard let text = value as? String, text.utf8.count == count,
              text.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }; return text
    }
    private static func reference(_ value: Any?) -> String? {
        guard let raw = value as? [String: Any], Set(raw.keys) == Set(["id", "version", "sha256"]),
              let id = raw["id"] as? String, !id.isEmpty, id.utf8.count <= 256, URL(string: id)?.scheme != nil,
              id.range(of: "[\\p{Cc}\\p{Cf}]", options: .regularExpression) == nil,
              let version = raw["version"] as? String, version.utf8.count <= 17,
              version.range(of: "^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)$", options: .regularExpression) != nil,
              version.split(separator: ".").allSatisfy({ UInt16($0) != nil }),
              hex(raw["sha256"], count: 64) != nil else { return nil }; return id
    }
    private static func json(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
        guard let text = String(data: data, encoding: .utf8) else { throw LocalHealthError.invalidResponse }; return text
    }
    private static func bounded(_ value: Any, depth: Int, nodes: inout Int) -> Bool {
        nodes += 1
        guard depth <= 8, nodes <= 4096 else { return false }
        if let map = value as? [String: Any] {
            guard map.count <= 256 else { return false }
            return map.allSatisfy { key, value in key.utf8.count <= 4096 && bounded(value, depth: depth + 1, nodes: &nodes) }
        }
        if let values = value as? [Any] {
            guard values.count <= 256 else { return false }
            return values.allSatisfy { bounded($0, depth: depth + 1, nodes: &nodes) }
        }
        if let text = value as? String { return text.utf8.count <= 4096 }
        return value is NSNull || value is NSNumber
    }
}
