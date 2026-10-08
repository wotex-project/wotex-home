import CoreFoundation
import Foundation

struct HomeScheduleContentReceipt: Equatable, Sendable {
    let kind: String, state: String, principal: String, epoch: Int64, operation: String
    let inputDigest: String, artifactDigest: String, revision: Int64
}

struct HomeScheduleLifecycleReceipt: Equatable, Sendable {
    let kind: String, state: String, principal: String, epoch: Int64, operation: String
    let inputDigest: String, admission: Int64, previousGeneration: Int64, generation: Int64
    let barrierRevision: Int64, revision: Int64, affected: Int64, unknown: Int64
    let reason: String?, initialWatermark: Int64
}

enum HomeScheduleReceipt: Equatable, Sendable {
    case content(HomeScheduleContentReceipt), lifecycle(HomeScheduleLifecycleReceipt), notFound
}

struct HomeScheduleResult: Sendable {
    let original: HomeScheduleOperation, principal: String, receipt: HomeScheduleReceipt
    fileprivate init(original: HomeScheduleOperation, principal: String, receipt: HomeScheduleReceipt) {
        self.original = original; self.principal = principal; self.receipt = receipt
    }
    func verify(original: HomeScheduleOperation, principal: String) throws {
        guard self.original == original, self.principal == principal else { throw LocalHealthError.invalidResponse }
    }
}

enum HomeScheduleCurrent: Equatable, Sendable {
    case inactive, lifecycle(HomeScheduleLifecycleReceipt)
}

struct HomeScheduleTimezone: Equatable, Sendable {
    let name: String, digest: String, localDateTime: String, instants: [Int64]
}

enum NativeScheduleClient {
    private static let contentKeys: Set<String> = ["kind", "state", "principal_id", "authority_epoch", "operation_id", "input_digest", "artifact_digest", "revision"]
    private static let lifecycleKeys: Set<String> = ["kind", "state", "principal_id", "authority_epoch", "operation_id", "input_digest", "admission_revision", "previous_generation", "rule_generation", "barrier_revision", "revision", "affected_requests", "unknown_outcomes", "reason", "initial_watermark"]

    static func deliver(socketPath: String, credential: Data, original: HomeScheduleOperation,
                        principal: String, lookup: Bool) throws -> HomeScheduleResult {
        guard NativeRuleOperationWire.identifier(principal), original.source?.author == nil || original.source?.author == principal else { throw NativeScheduleError.invalidRecord }
        let document = String(decoding: try NativeScheduleWire.encode(original), as: UTF8.self)
        let response = try LocalHealthClient.scheduleTransport(socketPath: socketPath, credential: credential,
            operation: lookup ? "schedule_original_status" : "schedule_" + original.kind,
            fields: ["original_document": document], allowNotFound: lookup)
        if response["outcome"] as? String == "not_found" {
            guard lookup, Set(response.keys) == Set(["api_version", "outcome"]) else { throw LocalHealthError.invalidResponse }
            return HomeScheduleResult(original: original, principal: principal, receipt: .notFound)
        }
        guard Set(response.keys) == Set(["api_version", "outcome", "schedule_receipt"]),
              let item = response["schedule_receipt"] as? [String: Any], item["kind"] as? String == original.kind,
              item["principal_id"] as? String == principal, NativeScheduleWire.integer(item["authority_epoch"]) == original.epoch,
              item["operation_id"] as? String == original.operationID,
              item["input_digest"] as? String == (try NativeScheduleWire.digest(original)) else { throw LocalHealthError.invalidResponse }
        let receipt: HomeScheduleReceipt
        if original.kind == "review" || original.kind == "admit" {
            guard Set(item.keys) == contentKeys, item["state"] as? String == (original.kind == "review" ? "reviewed" : "admitted"),
                  let artifact = item["artifact_digest"] as? String, NativeScheduleWire.hash(artifact),
                  let revision = NativeScheduleWire.integer(item["revision"]), revision - 1 == original.expectedRevision else { throw LocalHealthError.invalidResponse }
            receipt = .content(HomeScheduleContentReceipt(kind: original.kind, state: original.kind == "review" ? "reviewed" : "admitted",
                principal: principal, epoch: original.epoch, operation: original.operationID, inputDigest: try NativeScheduleWire.digest(original), artifactDigest: artifact, revision: revision))
        } else {
            let value = try lifecycle(item, current: false)
            guard value.barrierRevision - 1 == original.expectedRevision else { throw LocalHealthError.invalidResponse }
            switch original {
            case .activate(_, _, _, let admission): guard value.admission == admission else { throw LocalHealthError.invalidResponse }
            case .suspend: guard value.admission == 0 else { throw LocalHealthError.invalidResponse }
            default: throw LocalHealthError.invalidResponse
            }
            receipt = .lifecycle(value)
        }
        return HomeScheduleResult(original: original, principal: principal, receipt: receipt)
    }

    static func current(socketPath: String, credential: Data, principal: String) throws -> HomeScheduleCurrent {
        guard NativeRuleOperationWire.identifier(principal) else { throw NativeScheduleError.invalidRecord }
        let response = try LocalHealthClient.scheduleTransport(socketPath: socketPath, credential: credential, operation: "schedule_status", fields: [:])
        guard Set(response.keys) == Set(["api_version", "outcome", "schedule_status"]),
              let item = response["schedule_status"] as? [String: Any] else { throw LocalHealthError.invalidResponse }
        if item["state"] as? String == "inactive" {
            guard Set(item.keys) == Set(["state", "activation_revision", "reason"]), NativeScheduleWire.integer(item["activation_revision"]) == 0,
                  item["reason"] is NSNull else { throw LocalHealthError.invalidResponse }
            return .inactive
        }
        let value = try lifecycle(item, current: true)
        guard value.principal == principal else { throw LocalHealthError.invalidResponse }
        return .lifecycle(value)
    }

    static func timezone(socketPath: String, credential: Data, name: String, local: String) throws -> HomeScheduleTimezone {
        guard NativeScheduleWire.zone(name), NativeScheduleWire.localDateTime(local) else { throw NativeScheduleError.invalidRecord }
        let response = try LocalHealthClient.scheduleTransport(socketPath: socketPath, credential: credential, operation: "schedule_timezone", fields: ["zone_name": name, "local_datetime": local])
        guard Set(response.keys) == Set(["api_version", "outcome", "timezone"]), let item = response["timezone"] as? [String: Any],
              Set(item.keys) == Set(["name", "digest", "local_datetime", "instant_count", "first_utc_ms", "second_utc_ms", "basis_scope"]),
              item["name"] as? String == name, item["local_datetime"] as? String == local,
              item["basis_scope"] as? String == "calendar_calculation_only", let digest = item["digest"] as? String, NativeScheduleWire.hash(digest),
              let count = NativeScheduleWire.integer(item["instant_count"]), (0...2).contains(count) else { throw LocalHealthError.invalidResponse }
        var instants: [Int64] = []
        for (index, key) in ["first_utc_ms", "second_utc_ms"].enumerated() {
            if Int64(index) < count {
                guard let instant = NativeScheduleWire.integer(item[key]), NativeScheduleWire.utc(instant),
                      instants.last.map({ $0 < instant }) != false else { throw LocalHealthError.invalidResponse }
                instants.append(instant)
            } else { guard item[key] is NSNull else { throw LocalHealthError.invalidResponse } }
        }
        return HomeScheduleTimezone(name: name, digest: digest, localDateTime: local, instants: instants)
    }

    private static func lifecycle(_ item: [String: Any], current: Bool) throws -> HomeScheduleLifecycleReceipt {
        guard Set(item.keys) == lifecycleKeys, let kind = item["kind"] as? String,
              (current ? ["activate", "suspend", "withdraw"] : ["activate", "suspend"]).contains(kind),
              let state = item["state"] as? String, let principal = item["principal_id"] as? String, NativeRuleOperationWire.identifier(principal),
              let epoch = NativeScheduleWire.integer(item["authority_epoch"]), epoch > 0,
              let operation = item["operation_id"] as? String, NativeRuleOperationWire.identifier(operation),
              let digest = item["input_digest"] as? String, NativeScheduleWire.hash(digest),
              let admission = NativeScheduleWire.integer(item["admission_revision"]), let previous = NativeScheduleWire.integer(item["previous_generation"]),
              let generation = NativeScheduleWire.integer(item["rule_generation"]), generation > 0, generation - 1 == previous,
              let barrier = NativeScheduleWire.integer(item["barrier_revision"]), barrier > 0, admission <= barrier - 1, generation <= barrier,
              let revision = NativeScheduleWire.integer(item["revision"]), revision > barrier,
              let affected = NativeScheduleWire.integer(item["affected_requests"]), affected <= 1_024,
              let unknown = NativeScheduleWire.integer(item["unknown_outcomes"]), unknown <= affected, revision - barrier == affected + 1,
              let watermark = signedInteger(item["initial_watermark"]), watermark == -1 || NativeScheduleWire.utc(watermark) else { throw LocalHealthError.invalidResponse }
        let reason: String?
        if item["reason"] is NSNull { reason = nil }
        else { guard let value = item["reason"] as? String, NativeRuleOperationWire.identifier(value) else { throw LocalHealthError.invalidResponse }; reason = value }
        if current {
            guard ["active", "suspended"].contains(state), state != "active" || (kind == "activate" && reason == nil),
                  state != "suspended" || reason != nil else { throw LocalHealthError.invalidResponse }
        } else {
            guard state == (kind == "activate" ? "activated" : "suspended"), reason == nil else { throw LocalHealthError.invalidResponse }
        }
        if kind == "withdraw" {
            guard operation.hasPrefix("schedule-withdraw:"), NativeScheduleWire.hash(String(operation.dropFirst("schedule-withdraw:".count))) else { throw LocalHealthError.invalidResponse }
        }
        guard kind == "suspend" ? admission == 0 && watermark == -1 : admission > 0,
              kind == "activate" ? NativeScheduleWire.utc(watermark) : watermark == -1 else { throw LocalHealthError.invalidResponse }
        return HomeScheduleLifecycleReceipt(kind: kind, state: state, principal: principal, epoch: epoch, operation: operation,
            inputDigest: digest, admission: admission, previousGeneration: previous, generation: generation,
            barrierRevision: barrier, revision: revision, affected: affected, unknown: unknown, reason: reason, initialWatermark: watermark)
    }

    private static func signedInteger(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              !["f", "d"].contains(String(cString: number.objCType)), let result = value as? Int64,
              number.stringValue == String(result) else { return nil }
        return result
    }
}
