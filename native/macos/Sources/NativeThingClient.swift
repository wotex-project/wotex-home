import CoreFoundation
import Foundation

enum HomeObservedValue: Sendable, Equatable {
    case boolean(Bool), fraction(Int64), kelvin(Int64), hsv(Int64, Int64), xy(Int64, Int64), smoke(String)
    var text: String {
        switch self {
        case .boolean(let value): value ? "On" : "Off"
        case .fraction(let value): String(format: "%.1f%%", Double(value) / 10_000)
        case .kelvin(let value): "\(value) K"
        case .hsv(let hue, let saturation): String(format: "%.1f° · %.1f%%", Double(hue) / 1_000, Double(saturation) / 10_000)
        case .xy(let x, let y): "xy \(x), \(y) ppm"
        case .smoke(let value): "\(value.capitalized) reported"
        }
    }
}

struct HomeInspectedDeclaration: Sendable, Identifiable {
    let key: String, kind: String, unit: String, risk: String, profile: String, evidence: String
    let operations: [String], freshnessMilliseconds: Int64
    let minimum: Int64?, maximum: Int64?, extensions: [String: String]
    var id: String { key }
}

struct HomeInspectedReport: Sendable {
    let value: HomeObservedValue?
    let quality: String, trust: String, sourceEpoch: String, bootEpoch: String
    let sourceSequence: Int64, sourceTime: Int64?, receivedTime: Int64, receivedMonotonic: Int64, revision: Int64
    let receiptEpoch: String?, receiptMonotonic: Int64?
}

struct HomeInspectedCapability: Sendable, Identifiable {
    let declaration: HomeInspectedDeclaration
    let currentValue: HomeObservedValue?, report: HomeInspectedReport?
    let freshness: String, profileStatus: String
    let remainingMilliseconds: Int64, ageMilliseconds: Int64?
    var id: String { declaration.key }
    func displayedFreshness(elapsedMilliseconds: Int64) -> String {
        guard freshness == "fresh" else { return freshness }
        return elapsedMilliseconds >= 0 && elapsedMilliseconds <= remainingMilliseconds ? "fresh" : "stale"
    }
    func displayedValue(elapsedMilliseconds: Int64) -> HomeObservedValue? {
        displayedFreshness(elapsedMilliseconds: elapsedMilliseconds) == "fresh" ? currentValue : nil
    }
}

struct HomeThingInspection: Sendable {
    let principal: String, thingID: String, role: String, profile: String, storeBootEpoch: String
    let epoch: Int64, revision: Int64, resourceRevision: Int64, sampledMilliseconds: Int64
    let capabilities: [HomeInspectedCapability]
}

struct HomeThingRefresh: Sendable {
    let target: String, disposition: String, capabilities: [String], revisions: [Int64]
}

enum NativeThingClient {
    private static let profileDenials: Set<String> = ["profile_selection_unavailable", "profile_selection_revoked", "profile_trust_changed", "profile_author_unavailable", "profile_artifact_unavailable", "profile_basis_changed", "profile_lifecycle_required"]
    static func fetch(socketPath: String, credential: Data, target: String) throws -> HomeThingInspection {
        let response = try LocalHealthClient.thingTransport(socketPath: socketPath, credential: credential, operation: "thing_current", target: target)
        guard Set(response.keys) == Set(["api_version", "outcome", "thing_current"]), let item = response["thing_current"] as? [String: Any],
              Set(item.keys) == Set(["format", "principal_id", "authority_epoch", "store_revision", "store_boot_epoch", "sampled_monotonic_ms", "resource_revision", "declaration", "capabilities"]),
              item["format"] as? String == "wotex-home.thing-current.v1", let principal = identifier(item["principal_id"]), let boot = identifier(item["store_boot_epoch"]),
              let epoch = integer(item["authority_epoch"]), epoch > 0, let revision = integer(item["store_revision"]), revision >= 0,
              let resource = integer(item["resource_revision"]), (0...revision).contains(resource), let sampled = integer(item["sampled_monotonic_ms"]), sampled >= 0,
              let thing = item["declaration"] as? [String: Any], Set(thing.keys) == Set(["id", "role", "profile_ref", "capabilities"]), thing["id"] as? String == target,
              let role = thing["role"] as? String, ["Light", "SmokeDetector"].contains(role), let profile = identifier(thing["profile_ref"]),
              let declarations = thing["capabilities"] as? [[String: Any]], (1...32).contains(declarations.count),
              let rows = item["capabilities"] as? [[String: Any]], rows.count == declarations.count else { throw LocalHealthError.invalidResponse }
        let capabilities = try declarations.map { try declaration($0, target: target, role: role, profile: profile) }.sorted { $0.key < $1.key }
        guard Set(capabilities.map(\.key)).count == capabilities.count, rows.compactMap({ $0["key"] as? String }) == capabilities.map(\.key) else { throw LocalHealthError.invalidResponse }
        let entries = try zip(capabilities, rows).map { try entry($1, declaration: $0, target: target, boot: boot, sampled: sampled, revision: revision) }
        return HomeThingInspection(principal: principal, thingID: target, role: role, profile: profile, storeBootEpoch: boot,
            epoch: epoch, revision: revision, resourceRevision: resource, sampledMilliseconds: sampled, capabilities: entries)
    }

    static func refresh(socketPath: String, credential: Data, target: String) throws -> HomeThingRefresh {
        let response = try LocalHealthClient.thingTransport(socketPath: socketPath, credential: credential, operation: "lifx_refresh", target: target)
        guard Set(response.keys) == Set(["api_version", "outcome", "lifx_refresh"]), let item = response["lifx_refresh"] as? [String: Any],
              Set(item.keys) == Set(["thing_id", "disposition", "capability_keys", "revisions"]), item["thing_id"] as? String == target,
              let disposition = item["disposition"] as? String, ["ok", "duplicate"].contains(disposition), let keys = item["capability_keys"] as? [String],
              (1...32).contains(keys.count), Set(keys).count == keys.count, keys.allSatisfy(LocalHealthClient.profileID),
              let raw = item["revisions"] as? [Any], raw.count == keys.count else { throw LocalHealthError.invalidResponse }
        let revisions = try raw.map { value -> Int64 in guard let revision = integer(value), revision > 0 else { throw LocalHealthError.invalidResponse }; return revision }
        return HomeThingRefresh(target: target, disposition: disposition, capabilities: keys, revisions: revisions)
    }

    private static func declaration(_ raw: [String: Any], target: String, role: String, profile: String) throws -> HomeInspectedDeclaration {
        guard Set(raw.keys) == Set(["thing_id", "role", "key", "value_kind", "unit", "operations", "risk_class", "profile_ref", "evidence_ref", "freshness_ms", "constraints", "extensions"]),
              raw["thing_id"] as? String == target, raw["role"] as? String == role, raw["profile_ref"] as? String == profile,
              let key = identifier(raw["key"]), let evidence = identifier(raw["evidence_ref"]), let kind = raw["value_kind"] as? String,
              let unit = raw["unit"] as? String, let risk = raw["risk_class"] as? String, let operations = raw["operations"] as? [String],
              let freshness = integer(raw["freshness_ms"]), (1...86_400_000).contains(freshness),
              let constraints = raw["constraints"] as? [String: Any], let extensions = raw["extensions"] as? [String: String], extensions.count <= 16,
              extensions.allSatisfy({ $0.key.utf8.count <= 128 && $0.value.utf8.count <= 256 && $0.key.range(of: "^[A-Za-z0-9]+:[A-Za-z0-9._-]+$", options: .regularExpression) != nil }) else { throw LocalHealthError.invalidResponse }
        let expected: (String, String)
        switch (role, key) {
        case ("Light", "power"), ("SmokeDetector", "fault"), ("SmokeDetector", "self_test"): expected = ("boolean", "none")
        case ("Light", "brightness"), ("SmokeDetector", "battery_fraction"): expected = ("fraction", "ppm")
        case ("Light", "colour_hsv"): expected = ("hsv", "mdeg+ppm")
        case ("Light", "colour_xy"): expected = ("xy", "ppm")
        case ("Light", "colour_temperature"): expected = ("kelvin", "K")
        case ("SmokeDetector", "smoke_state"): expected = ("smoke_state", "none")
        default: throw LocalHealthError.invalidResponse
        }
        guard kind == expected.0, unit == expected.1, risk == (role == "Light" ? "ordinary" : "sensitive"),
              !operations.isEmpty, Set(operations).count == operations.count, operations.allSatisfy({ $0 == "read" || (role == "Light" && $0 == "write") }) else { throw LocalHealthError.invalidResponse }
        let minimum: Int64?, maximum: Int64?
        if kind == "kelvin" {
            guard Set(constraints.keys) == Set(["min", "max"]), let min = integer(constraints["min"]), let max = integer(constraints["max"]), min > 0, min <= max, max <= 1_000_000 else { throw LocalHealthError.invalidResponse }
            minimum = min; maximum = max
        } else { guard constraints.isEmpty else { throw LocalHealthError.invalidResponse }; minimum = nil; maximum = nil }
        return HomeInspectedDeclaration(key: key, kind: kind, unit: unit, risk: risk, profile: profile, evidence: evidence, operations: operations,
            freshnessMilliseconds: freshness, minimum: minimum, maximum: maximum, extensions: extensions)
    }

    private static func entry(_ item: [String: Any], declaration: HomeInspectedDeclaration, target: String, boot: String, sampled: Int64, revision: Int64) throws -> HomeInspectedCapability {
        guard Set(item.keys) == Set(["key", "current_value", "report", "freshness", "remaining_ms", "age_ms", "profile_status"]), item["key"] as? String == declaration.key,
              let freshness = item["freshness"] as? String, let profile = item["profile_status"] as? String, profile == "usable" || profileDenials.contains(profile),
              let remaining = integer(item["remaining_ms"]), (0...declaration.freshnessMilliseconds).contains(remaining),
              item["age_ms"] is NSNull || integer(item["age_ms"]).map({ $0 >= 0 }) == true else { throw LocalHealthError.invalidResponse }
        let age = integer(item["age_ms"]), report: HomeInspectedReport?
        if item["report"] is NSNull { report = nil }
        else { guard let raw = item["report"] as? [String: Any] else { throw LocalHealthError.invalidResponse }; report = try decodeReport(raw, declaration: declaration, target: target, revision: revision) }
        let expectedAge: Int64?, expectedFreshness: String
        if let report {
            if report.receiptEpoch == boot, let received = report.receiptMonotonic, received <= sampled { expectedAge = sampled - received }
            else { expectedAge = nil }
            if profile != "usable" { expectedFreshness = "profile_unavailable" }
            else if report.quality == "unknown" { expectedFreshness = "unknown" }
            else if report.trust == "synthetic_lab" { expectedFreshness = "synthetic" }
            else if report.receiptEpoch == nil { expectedFreshness = "untimed" }
            else if report.receiptEpoch != boot { expectedFreshness = "old_boot" }
            else if report.receiptMonotonic! > sampled { expectedFreshness = "future" }
            else if expectedAge! > declaration.freshnessMilliseconds { expectedFreshness = "stale" }
            else { expectedFreshness = "fresh" }
        } else { expectedAge = nil; expectedFreshness = profile == "usable" ? "missing" : "profile_unavailable" }
        guard age == expectedAge, freshness == expectedFreshness, remaining == (freshness == "fresh" ? declaration.freshnessMilliseconds - age! : 0) else { throw LocalHealthError.invalidResponse }
        let value: HomeObservedValue?
        if freshness == "fresh" {
            value = try decodeValue(item["current_value"], declaration: declaration)
            guard value == report?.value else { throw LocalHealthError.invalidResponse }
        } else { guard item["current_value"] is NSNull else { throw LocalHealthError.invalidResponse }; value = nil }
        return HomeInspectedCapability(declaration: declaration, currentValue: value, report: report, freshness: freshness, profileStatus: profile, remainingMilliseconds: remaining, ageMilliseconds: age)
    }

    private static func decodeReport(_ raw: [String: Any], declaration: HomeInspectedDeclaration, target: String, revision: Int64) throws -> HomeInspectedReport {
        guard Set(raw.keys) == Set(["thing_id", "capability_key", "profile_ref", "evidence_ref", "value", "quality", "trust", "source_epoch", "source_sequence", "boot_epoch", "source_time_utc_ms", "received_time_utc_ms", "received_monotonic_ms", "revision", "received_store_boot_epoch", "received_store_monotonic_ms"]),
              raw["thing_id"] as? String == target, raw["capability_key"] as? String == declaration.key, raw["profile_ref"] as? String == declaration.profile, raw["evidence_ref"] as? String == declaration.evidence,
              let quality = raw["quality"] as? String, ["reported", "unknown"].contains(quality), let trust = raw["trust"] as? String,
              ["unauthenticated_local", "authenticated_device", "bridge_attested", "synthetic_lab"].contains(trust),
              let source = identifier(raw["source_epoch"]), let boot = identifier(raw["boot_epoch"]), let sequence = integer(raw["source_sequence"]), sequence >= 0,
              let receivedTime = integer(raw["received_time_utc_ms"]), receivedTime >= 0, let receivedMono = integer(raw["received_monotonic_ms"]), receivedMono >= 0,
              let reportRevision = integer(raw["revision"]), (1...max(1, revision)).contains(reportRevision), reportRevision <= revision,
              raw["source_time_utc_ms"] is NSNull || integer(raw["source_time_utc_ms"]).map({ $0 >= 0 }) == true else { throw LocalHealthError.invalidResponse }
        let receiptEpoch: String?, receiptMono: Int64?
        if raw["received_store_boot_epoch"] is NSNull {
            guard raw["received_store_monotonic_ms"] is NSNull else { throw LocalHealthError.invalidResponse }; receiptEpoch = nil; receiptMono = nil
        } else {
            guard let epoch = identifier(raw["received_store_boot_epoch"]), let ms = integer(raw["received_store_monotonic_ms"]), ms >= 0 else { throw LocalHealthError.invalidResponse }; receiptEpoch = epoch; receiptMono = ms
        }
        let value: HomeObservedValue?
        if quality == "unknown" { guard raw["value"] is NSNull else { throw LocalHealthError.invalidResponse }; value = nil }
        else { value = try decodeValue(raw["value"], declaration: declaration) }
        return HomeInspectedReport(value: value, quality: quality, trust: trust, sourceEpoch: source, bootEpoch: boot, sourceSequence: sequence,
            sourceTime: integer(raw["source_time_utc_ms"]), receivedTime: receivedTime, receivedMonotonic: receivedMono, revision: reportRevision, receiptEpoch: receiptEpoch, receiptMonotonic: receiptMono)
    }

    private static func decodeValue(_ value: Any?, declaration: HomeInspectedDeclaration) throws -> HomeObservedValue {
        guard let raw = value as? [String: Any], raw["type"] as? String == declaration.kind else { throw LocalHealthError.invalidResponse }
        switch declaration.kind {
        case "boolean":
            guard Set(raw.keys) == Set(["type", "value"]), let number = raw["value"] as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { break }; return .boolean(number.boolValue)
        case "fraction":
            guard Set(raw.keys) == Set(["type", "ppm"]), let value = integer(raw["ppm"]), (0...1_000_000).contains(value) else { break }; return .fraction(value)
        case "kelvin":
            guard Set(raw.keys) == Set(["type", "kelvin"]), let value = integer(raw["kelvin"]), let min = declaration.minimum, let max = declaration.maximum, (min...max).contains(value) else { break }; return .kelvin(value)
        case "hsv":
            guard Set(raw.keys) == Set(["type", "hue_mdeg", "saturation_ppm"]), let hue = integer(raw["hue_mdeg"]), (0..<360_000).contains(hue), let saturation = integer(raw["saturation_ppm"]), (0...1_000_000).contains(saturation) else { break }; return .hsv(hue, saturation)
        case "xy":
            guard Set(raw.keys) == Set(["type", "x_ppm", "y_ppm"]), let x = integer(raw["x_ppm"]), (0...1_000_000).contains(x), let y = integer(raw["y_ppm"]), (0...1_000_000 - x).contains(y) else { break }; return .xy(x, y)
        case "smoke_state":
            guard Set(raw.keys) == Set(["type", "state"]), let state = raw["state"] as? String, ["clear", "alarm"].contains(state) else { break }; return .smoke(state)
        default: break
        }
        throw LocalHealthError.invalidResponse
    }
    private static func integer(_ value: Any?) -> Int64? { LocalHealthClient.profileInteger(value).map(Int64.init) }
    private static func identifier(_ value: Any?) -> String? { guard let string = value as? String, LocalHealthClient.profileID(string) else { return nil }; return string }
}
