import Foundation

@main
struct NativeThingClientSmoke {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else { exit(2) }
        let socket = CommandLine.arguments[1], mode = CommandLine.arguments[2], credential = Data(repeating: 7, count: 32)
        do {
            if mode.hasPrefix("refresh-") {
                let result = try NativeThingClient.refresh(socketPath: socket, credential: credential, target: "light:fixture")
                guard !mode.contains("invalid"), result.target == "light:fixture", result.capabilities == ["power"], result.revisions == [9] else { exit(1) }
            } else {
                let result = try NativeThingClient.fetch(socketPath: socket, credential: credential, target: "light:fixture")
                guard !mode.contains("invalid"), result.principal == "reader:fixture", result.epoch == 7, result.revision == 9, result.resourceRevision == 2,
                      result.capabilities.count == 1, let entry = result.capabilities.first else { exit(1) }
                if mode == "view-value" { guard entry.freshness == "fresh", entry.currentValue != nil, !(entry.currentValue?.text.isEmpty ?? true) else { exit(1) }; return }
                let expected = String(mode.dropFirst("view-".count))
                guard entry.freshness == expected else { exit(1) }
                if expected == "fresh" {
                    guard entry.report?.sourceEpoch == "source:fixture", entry.report?.bootEpoch == "adapter:fixture", entry.report?.receivedMonotonic == 999_999_999,
                          entry.currentValue == .boolean(true), entry.remainingMilliseconds == 4_900,
                          entry.displayedValue(elapsedMilliseconds: 4_900) == .boolean(true), entry.displayedValue(elapsedMilliseconds: 4_901) == nil,
                          entry.displayedFreshness(elapsedMilliseconds: -1) == "stale" else { exit(1) }
                } else { guard entry.currentValue == nil, entry.displayedValue(elapsedMilliseconds: 0) == nil, entry.remainingMilliseconds == 0 else { exit(1) } }
            }
        } catch LocalHealthError.invalidResponse where mode.contains("invalid") { return }
        catch LocalHealthError.server("permission_denied") where mode == "view-refused" { return }
    }
}
