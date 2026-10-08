import CoreFoundation
import CryptoKit
import Foundation

enum NativeScheduleError: LocalizedError {
    case invalidRecord
    var errorDescription: String? { "Home could not verify the original schedule operation." }
}

// Inert source correspondence. These records contain no clock, proof or bearer.
enum HomeScheduleTrigger: Equatable, Sendable {
    case once(zone: String, digest: String, date: String, time: String, instant: Int64)
    case daily(zone: String, digest: String, time: String, start: Int64, end: Int64?)
    case weekdays(zone: String, digest: String, time: String, days: [Int64], start: Int64, end: Int64?)
    case interval(anchor: Int64, period: Int64, start: Int64, end: Int64?)
    case countdown(boot: String, generation: Int64, start: Int64, duration: Int64)

    fileprivate func record() throws -> [Any] {
        func bounds(_ start: Int64, _ end: Int64?) -> Bool {
            NativeScheduleWire.utc(start) && end.map { NativeScheduleWire.utc($0) && $0 > start } != false
        }
        func calendar(_ zone: String, _ digest: String, _ time: String) -> Bool {
            NativeScheduleWire.zone(zone) && NativeScheduleWire.hash(digest) && NativeScheduleWire.time(time)
        }
        switch self {
        case .once(let zone, let digest, let date, let time, let instant):
            guard calendar(zone, digest, time), NativeScheduleWire.date(date), NativeScheduleWire.utc(instant) else { throw NativeScheduleError.invalidRecord }
            return ["once", zone, digest, date, time, instant]
        case .daily(let zone, let digest, let time, let start, let end):
            guard calendar(zone, digest, time), bounds(start, end) else { throw NativeScheduleError.invalidRecord }
            return ["daily", zone, digest, time, start, end.map { $0 as Any } ?? NSNull()]
        case .weekdays(let zone, let digest, let time, let days, let start, let end):
            guard calendar(zone, digest, time), bounds(start, end), (1...7).contains(days.count),
                  days == Array(Set(days)).sorted(), days.allSatisfy({ (1...7).contains($0) }) else { throw NativeScheduleError.invalidRecord }
            return ["weekdays", zone, digest, time, days, start, end.map { $0 as Any } ?? NSNull()]
        case .interval(let anchor, let period, let start, let end):
            guard NativeScheduleWire.utc(anchor), (60_000...2_678_400_000).contains(period), bounds(start, end) else { throw NativeScheduleError.invalidRecord }
            return ["interval", anchor, period, start, end.map { $0 as Any } ?? NSNull()]
        case .countdown(let boot, let generation, let start, let duration):
            guard NativeRuleOperationWire.identifier(boot), generation > 0,
                  (0...(Int64.max - 86_460_000)).contains(start), (1_000...86_400_000).contains(duration) else { throw NativeScheduleError.invalidRecord }
            return ["countdown", boot, generation, start, duration]
        }
    }
}

struct HomeScheduleSource: Equatable, Sendable {
    let id: String, sourceRevision: Int64, author: String
    let rule: HomeExplicitPowerRule
    let resourceRevision: Int64, lateWindow: Int64, tolerance: Int64
    let trigger: HomeScheduleTrigger

    func encode() throws -> Data {
        guard NativeRuleOperationWire.identifier(id), sourceRevision >= 0,
              NativeRuleOperationWire.identifier(author), rule.valid, resourceRevision >= 0,
              (1_000...60_000).contains(lateWindow), (0...1_000).contains(tolerance) else { throw NativeScheduleError.invalidRecord }
        let body = try NativeScheduleWire.ruleDocument(rule)
        let values: [Any] = ["wotex-home.schedule-source.v1", id, sourceRevision, author,
            rule.id, NativeScheduleWire.digest(body), rule.target, resourceRevision, lateWindow, tolerance, try trigger.record()]
        return try NativeScheduleWire.json(values, limit: 4_096)
    }
}

enum HomeScheduleOperation: Equatable, Sendable {
    case review(epoch: Int64, operation: String, expected: Int64, source: HomeScheduleSource)
    case admit(epoch: Int64, operation: String, expected: Int64, source: HomeScheduleSource)
    case activate(epoch: Int64, operation: String, expected: Int64, admission: Int64)
    case suspend(epoch: Int64, operation: String, expected: Int64)
    var kind: String {
        switch self { case .review: "review"; case .admit: "admit"; case .activate: "activate"; case .suspend: "suspend" }
    }
    var epoch: Int64 {
        switch self { case .review(let e, _, _, _), .admit(let e, _, _, _), .activate(let e, _, _, _), .suspend(let e, _, _): e }
    }
    var operationID: String {
        switch self { case .review(_, let o, _, _), .admit(_, let o, _, _), .activate(_, let o, _, _), .suspend(_, let o, _): o }
    }
    var expectedRevision: Int64 {
        switch self { case .review(_, _, let r, _), .admit(_, _, let r, _), .activate(_, _, let r, _), .suspend(_, _, let r): r }
    }
    var source: HomeScheduleSource? {
        switch self { case .review(_, _, _, let s), .admit(_, _, _, let s): s; default: nil }
    }
}

enum NativeScheduleWire {
    static let maximumUTC: Int64 = 253_402_300_739_999
    static let format = "wotex-home.schedule-operation.v1"
    static func utc(_ value: Int64) -> Bool { (0...maximumUTC).contains(value) }
    static func hash(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func digest(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    static func zone(_ value: String) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        return (1...128).contains(value.utf8.count) && parts.allSatisfy { part in
            !part.isEmpty && part.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [95,43,45].contains($0) }
        }
    }
    static func date(_ value: String) -> Bool {
        let b = Array(value.utf8)
        guard b.count == 10, b[4] == 45, b[7] == 45,
              b.enumerated().allSatisfy({ [4,7].contains($0.offset) || (48...57).contains($0.element) }),
              let year = Int(value.prefix(4)), (1970...9999).contains(year),
              let month = Int(value.dropFirst(5).prefix(2)), (1...12).contains(month), let day = Int(value.suffix(2)) else { return false }
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        let days = [31, leap ? 29 : 28, 31,30,31,30,31,31,30,31,30,31]
        return (1...days[month - 1]).contains(day)
    }
    static func time(_ value: String) -> Bool {
        let b = Array(value.utf8)
        guard b.count == 8, b[2] == 58, b[5] == 58,
              b.enumerated().allSatisfy({ [2,5].contains($0.offset) || (48...57).contains($0.element) }),
              let hour = Int(value.prefix(2)), let minute = Int(value.dropFirst(3).prefix(2)), let second = Int(value.suffix(2)) else { return false }
        return (0...23).contains(hour) && (0...59).contains(minute) && (0...59).contains(second)
    }
    static func localDateTime(_ value: String) -> Bool {
        let b = Array(value.utf8)
        return b.count == 19 && b[10] == 84 && date(String(value.prefix(10))) && time(String(value.suffix(8)))
    }
    static func encode(_ input: HomeScheduleOperation) throws -> Data {
        guard input.epoch > 0, NativeRuleOperationWire.identifier(input.operationID),
              (0..<Int64.max).contains(input.expectedRevision) else { throw NativeScheduleError.invalidRecord }
        var values: [Any] = [format, input.kind, input.epoch, input.operationID, input.expectedRevision]
        switch input {
        case .review(_, _, _, let source), .admit(_, _, _, let source):
            values += [String(decoding: try source.encode(), as: UTF8.self), String(decoding: try ruleDocument(source.rule), as: UTF8.self)]
        case .activate(_, _, let expected, let admission):
            guard (1...max(1, expected)).contains(admission), admission <= expected else { throw NativeScheduleError.invalidRecord }
            values += [admission]
        case .suspend: break
        }
        return try json(values, limit: 8_192)
    }
    static func digest(_ input: HomeScheduleOperation) throws -> String { digest(try encode(input)) }
    static func decode(_ bytes: Data) throws -> HomeScheduleOperation {
        let raw = try parsed(bytes, limit: 8_192, depth: 1, members: 7, string: 4_096, objects: false)
        guard let values = raw as? [Any], (5...7).contains(values.count), values[0] as? String == format,
              let kind = values[1] as? String, let epoch = integer(values[2]), let operation = values[3] as? String,
              let expected = integer(values[4]) else { throw NativeScheduleError.invalidRecord }
        let result: HomeScheduleOperation
        switch (kind, values.count) {
        case ("review", 7), ("admit", 7):
            guard let document = values[5] as? String, let rule = values[6] as? String else { throw NativeScheduleError.invalidRecord }
            let source = try source(Data(document.utf8), rule: Data(rule.utf8))
            result = kind == "review" ? .review(epoch: epoch, operation: operation, expected: expected, source: source) : .admit(epoch: epoch, operation: operation, expected: expected, source: source)
        case ("activate", 6):
            guard let admission = integer(values[5]) else { throw NativeScheduleError.invalidRecord }
            result = .activate(epoch: epoch, operation: operation, expected: expected, admission: admission)
        case ("suspend", 5): result = .suspend(epoch: epoch, operation: operation, expected: expected)
        default: throw NativeScheduleError.invalidRecord
        }
        guard try encode(result) == bytes else { throw NativeScheduleError.invalidRecord }
        return result
    }
    static func source(_ bytes: Data, rule: Data) throws -> HomeScheduleSource {
        let raw = try parsed(bytes, limit: 4_096, depth: 3, members: 16, string: 128, objects: false)
        guard let a = raw as? [Any], a.count == 11, a[0] as? String == "wotex-home.schedule-source.v1",
              let id = a[1] as? String, let revision = integer(a[2]), let author = a[3] as? String,
              let ruleID = a[4] as? String, let hash = a[5] as? String, hash == digest(rule), let target = a[6] as? String,
              let resource = integer(a[7]), let late = integer(a[8]), let tolerance = integer(a[9]), let trigger = a[10] as? [Any] else { throw NativeScheduleError.invalidRecord }
        let effect = try decodeRule(rule)
        guard ruleID == effect.id, target == effect.target else { throw NativeScheduleError.invalidRecord }
        let result = HomeScheduleSource(id: id, sourceRevision: revision, author: author, rule: effect,
            resourceRevision: resource, lateWindow: late, tolerance: tolerance, trigger: try decodeTrigger(trigger))
        guard try result.encode() == bytes else { throw NativeScheduleError.invalidRecord }
        return result
    }
    static func ruleDocument(_ rule: HomeExplicitPowerRule) throws -> Data {
        guard rule.valid else { throw NativeScheduleError.invalidRecord }
        return try json(["rules": [try rule.source()]], limit: 2_048)
    }
    private static func decodeRule(_ bytes: Data) throws -> HomeExplicitPowerRule {
        let raw = try parsed(bytes, limit: 2_048, depth: 5, members: 16, string: 128, objects: true)
        guard let root = raw as? [String: Any], let rules = root["rules"] as? [[String: Any]], rules.count == 1,
              let id = rules[0]["id"] as? String, let revision = integer(rules[0]["source_revision"]),
              let effect = rules[0]["effect"] as? [String: Any], let target = effect["target_id"] as? String,
              let value = effect["value"] as? [String: Any], let on = value["value"] as? NSNumber,
              CFGetTypeID(on) == CFBooleanGetTypeID() else { throw NativeScheduleError.invalidRecord }
        let result = HomeExplicitPowerRule(id: id, sourceRevision: revision, target: target, on: on.boolValue)
        guard try ruleDocument(result) == bytes else { throw NativeScheduleError.invalidRecord }
        return result
    }
    private static func decodeTrigger(_ a: [Any]) throws -> HomeScheduleTrigger {
        guard let kind = a.first as? String else { throw NativeScheduleError.invalidRecord }
        func end(_ i: Int) throws -> Int64? {
            if a[i] is NSNull { return nil }; guard let value = integer(a[i]) else { throw NativeScheduleError.invalidRecord }; return value
        }
        switch (kind, a.count) {
        case ("once", 6):
            guard let zone = a[1] as? String, let digest = a[2] as? String, let date = a[3] as? String,
                  let time = a[4] as? String, let instant = integer(a[5]) else { throw NativeScheduleError.invalidRecord }
            return .once(zone: zone, digest: digest, date: date, time: time, instant: instant)
        case ("daily", 6):
            guard let zone = a[1] as? String, let digest = a[2] as? String, let time = a[3] as? String, let start = integer(a[4]) else { throw NativeScheduleError.invalidRecord }
            return .daily(zone: zone, digest: digest, time: time, start: start, end: try end(5))
        case ("weekdays", 7):
            guard let zone = a[1] as? String, let digest = a[2] as? String, let time = a[3] as? String,
                  let days = a[4] as? [Any], let start = integer(a[5]) else { throw NativeScheduleError.invalidRecord }
            let integers = days.compactMap(integer)
            guard integers.count == days.count else { throw NativeScheduleError.invalidRecord }
            return .weekdays(zone: zone, digest: digest, time: time, days: integers, start: start, end: try end(6))
        case ("interval", 5):
            guard let anchor = integer(a[1]), let period = integer(a[2]), let start = integer(a[3]) else { throw NativeScheduleError.invalidRecord }
            return .interval(anchor: anchor, period: period, start: start, end: try end(4))
        case ("countdown", 5):
            guard let boot = a[1] as? String, let generation = integer(a[2]), let start = integer(a[3]), let duration = integer(a[4]) else { throw NativeScheduleError.invalidRecord }
            return .countdown(boot: boot, generation: generation, start: start, duration: duration)
        default: throw NativeScheduleError.invalidRecord
        }
    }
    static func integer(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              !["f", "d"].contains(String(cString: number.objCType)), let result = value as? Int64, result >= 0 else { return nil }
        return result
    }
    static func json(_ value: Any, limit: Int) throws -> Data {
        let bytes = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
        guard bytes.count <= limit else { throw NativeScheduleError.invalidRecord }; return bytes
    }
    // Bound depth, members, strings and numeric tokens before JSON allocation.
    // Supported sources are ASCII; only quote/backslash escapes are needed by
    // the outer document's embedded canonical source and rule strings.
    private static func parsed(_ bytes: Data, limit: Int, depth: Int, members: Int, string: Int, objects: Bool) throws -> Any {
        guard (2...limit).contains(bytes.count) else { throw NativeScheduleError.invalidRecord }
        var stack: [(UInt8, Int)] = [], quoted = false, escaped = false, length = 0, atom = 0
        for byte in bytes {
            if quoted {
                if escaped { guard byte == 34 || byte == 92 else { throw NativeScheduleError.invalidRecord }; escaped = false; length += 1 }
                else if byte == 92 { escaped = true }
                else if byte == 34 { quoted = false; length = 0 }
                else { guard (32...126).contains(byte) else { throw NativeScheduleError.invalidRecord }; length += 1 }
                guard length <= string else { throw NativeScheduleError.invalidRecord }
            } else {
                switch byte {
                case 91, 123:
                    guard stack.count < depth, byte == 91 || objects else { throw NativeScheduleError.invalidRecord }
                    stack.append((byte == 91 ? 93 : 125, 0)); atom = 0
                case 93, 125:
                    guard stack.last?.0 == byte else { throw NativeScheduleError.invalidRecord }; stack.removeLast(); atom = 0
                case 34: quoted = true; length = 0; atom = 0
                case 44:
                    guard let last = stack.popLast(), last.1 + 1 < members else { throw NativeScheduleError.invalidRecord }
                    stack.append((last.0, last.1 + 1)); atom = 0
                case 58: guard objects else { throw NativeScheduleError.invalidRecord }; atom = 0
                case 48...57, 97, 101, 102, 108, 110, 114, 115, 116, 117:
                    atom += 1; guard atom <= 19 else { throw NativeScheduleError.invalidRecord }
                default: throw NativeScheduleError.invalidRecord
                }
            }
        }
        guard !quoted, !escaped, stack.isEmpty, let value = try? JSONSerialization.jsonObject(with: bytes),
              try json(value, limit: limit) == bytes else { throw NativeScheduleError.invalidRecord }
        return value
    }
}
