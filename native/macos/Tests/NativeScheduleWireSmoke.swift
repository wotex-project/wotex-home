import Foundation

private enum ScheduleWireSmokeError: Error { case failed }
@main
struct NativeScheduleWireSmoke {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { exit(2) }
        let bytes = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        guard bytes.count <= 65_536, let corpus = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              Set(corpus.keys) == Set(["format", "scope", "vectors", "refusals"]),
              corpus["format"] as? String == "wotex-home.native-schedule-input-vectors.v1",
              corpus["scope"] as? String == "inert_schedule_input_correspondence",
              let vectors = corpus["vectors"] as? [[String: String]], let refusals = corpus["refusals"] as? [String] else { throw ScheduleWireSmokeError.failed }
        for vector in vectors {
            guard let document = vector["document"], let digest = vector["digest"] else { throw ScheduleWireSmokeError.failed }
            let original = try NativeScheduleWire.decode(Data(document.utf8))
            try check(try NativeScheduleWire.encode(original) == Data(document.utf8))
            try check(try NativeScheduleWire.digest(original) == digest)
            if let source = original.source {
                try check(source.author == "operator:one" && source.rule.target == "light:one")
                try check(NativeScheduleWire.source(try source.encode(), rule: try NativeScheduleWire.ruleDocument(source.rule)) == source)
            }
        }
        for document in refusals { try refused { try NativeScheduleWire.decode(Data(document.utf8)) } }
        for bytes in [Data([255]), Data(repeating: 91, count: 8_193), Data(("[" + String(repeating: "1,", count: 4_000) + "1]").utf8)] {
            try refused { try NativeScheduleWire.decode(bytes) }
        }
        try check(NativeScheduleWire.date("2000-02-29") && !NativeScheduleWire.date("2100-02-29"))
        try check(NativeScheduleWire.localDateTime("2026-10-25T02:30:00"))
        try check(!NativeScheduleWire.localDateTime("2026-10-25 02:30:00"))
        print("native schedule independent \(vectors.count) records and \(refusals.count) refusals passed")
    }
    private static func check(_ value: Bool) throws { guard value else { throw ScheduleWireSmokeError.failed } }
    private static func refused<T>(_ block: () throws -> T) throws {
        do { _ = try block() } catch NativeScheduleError.invalidRecord { return }
        throw ScheduleWireSmokeError.failed
    }
}
