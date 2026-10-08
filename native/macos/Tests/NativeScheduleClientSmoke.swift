import Foundation

@main
struct NativeScheduleClientSmoke {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else { exit(2) }
        let socket = CommandLine.arguments[1], mode = CommandLine.arguments[2]
        let credential = Data(repeating: 7, count: 32), principal = "operator:one"
        let rule = HomeExplicitPowerRule(id: "rule:one", sourceRevision: 2, target: "light:one", on: true)
        let source = HomeScheduleSource(id: "schedule:one", sourceRevision: 2, author: principal, rule: rule,
            resourceRevision: 4, lateWindow: 10_000, tolerance: 100, trigger: .interval(anchor: 100_000, period: 60_000, start: 100_000, end: nil))
        do {
            if mode.hasPrefix("current-") {
                let current = try NativeScheduleClient.current(socketPath: socket, credential: credential, principal: principal)
                guard !mode.contains("invalid") else { exit(1) }
                if mode == "current-inactive" { guard current == .inactive else { exit(1) } }
                else { guard case .lifecycle(let receipt) = current, receipt.principal == principal,
                             receipt.generation == 3, receipt.revision == 13 else { exit(1) } }
            } else if mode.hasPrefix("timezone-") {
                let value = try NativeScheduleClient.timezone(socketPath: socket, credential: credential, name: "Europe/Stockholm", local: "2026-10-25T02:30:00")
                guard !mode.contains("invalid"), value.name == "Europe/Stockholm", value.digest == String(repeating: "a", count: 64),
                      value.instants.count == (mode == "timezone-gap" ? 0 : mode == "timezone-fold" ? 2 : 1) else { exit(1) }
            } else {
                let kind = String(mode.split(separator: "-").first!)
                let original: HomeScheduleOperation
                switch kind {
                case "review": original = .review(epoch: 7, operation: "schedule:review", expected: 9, source: source)
                case "admit": original = .admit(epoch: 7, operation: "schedule:admit", expected: 9, source: source)
                case "activate": original = .activate(epoch: 7, operation: "schedule:activate", expected: 9, admission: 8)
                case "suspend": original = .suspend(epoch: 7, operation: "schedule:suspend", expected: 9)
                default: exit(2)
                }
                if mode.contains("invalid-input") {
                    _ = try NativeScheduleClient.deliver(socketPath: socket, credential: credential, original: original, principal: "operator:other", lookup: false)
                    exit(1)
                }
                if mode.contains("lost-then-lookup") {
                    do { _ = try NativeScheduleClient.deliver(socketPath: socket, credential: credential, original: original, principal: principal, lookup: false); exit(1) }
                    catch LocalHealthError.transport {}
                }
                let result = try NativeScheduleClient.deliver(socketPath: socket, credential: credential, original: original,
                    principal: principal, lookup: mode.contains("lookup"))
                try result.verify(original: original, principal: principal)
                guard !mode.contains("invalid") && !mode.contains("refused") else { exit(1) }
                switch result.receipt {
                case .content(let receipt): guard ["review", "admit"].contains(kind), receipt.revision == 10 else { exit(1) }
                case .lifecycle(let receipt): guard ["activate", "suspend"].contains(kind), receipt.revision == 13, receipt.unknown == 1 else { exit(1) }
                case .notFound: guard mode.contains("missing") else { exit(1) }
                }
                do { try result.verify(original: .suspend(epoch: 8, operation: original.operationID, expected: 9), principal: principal); exit(1) } catch LocalHealthError.invalidResponse {}
                do { try result.verify(original: original, principal: "operator:other"); exit(1) } catch LocalHealthError.invalidResponse {}
            }
        } catch LocalHealthError.invalidResponse where mode.contains("invalid") { return }
        catch NativeScheduleError.invalidRecord where mode.contains("invalid-input") { return }
        catch LocalHealthError.server("permission_denied") where mode.contains("refused") { return }
    }
}
