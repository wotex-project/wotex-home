import Foundation

@main
struct NativeRuleClientSmoke {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else { exit(2) }
        let socket = CommandLine.arguments[1], mode = CommandLine.arguments[2]
        let rule = HomeExplicitPowerRule(id: "rule:one", sourceRevision: 2, target: "light:one", on: true)
        let credential = Data(repeating: 7, count: 32)
        do {
            if mode.hasPrefix("current-") {
                let current = try NativeRuleClient.current(socketPath: socket, credential: credential)
                guard !mode.contains("invalid"), current.principal == "operator:fixture", current.epoch == 7, current.revision == 9 else { exit(1) }
                if mode == "current-inactive" { guard current.rule == nil && current.admissionRevision == 0 else { exit(1) } }
                else { guard current.rule == rule && current.generation == 3 && current.admissionRevision == 4 else { exit(1) } }
            } else if mode.hasPrefix("preview-") {
                let preview = try NativeRuleClient.preview(socketPath: socket, credential: credential, rule: rule)
                guard !mode.contains("invalid"), preview.rule == rule, preview.revision == 9,
                      preview.hasProposalBasis == (mode == "preview-valid") else { exit(1) }
            } else {
                let kind = mode.split(separator: "-").first!
                let original: HomeExplicitRuleOperation
                switch kind {
                case "review": original = .review(epoch: 7, operation: "rule:review", expected: 9, rule: rule)
                case "admit": original = .admit(epoch: 7, operation: "rule:admit", expected: 9, rule: rule)
                case "activate": original = .activate(epoch: 7, operation: "rule:activate", expected: 9, admission: 4)
                case "invoke": original = .invoke(epoch: 7, operation: "rule:invoke", generation: 3, ruleID: "rule:one")
                default: exit(2)
                }
                let result = try NativeRuleClient.deliver(socketPath: socket, credential: credential, original: original,
                    principal: "operator:fixture", lookup: mode.contains("lookup"))
                try result.verify(original: original, principal: "operator:fixture")
                guard !mode.contains("invalid") && !mode.contains("refused") else { exit(1) }
                switch result.receipt {
                case .review(let review): guard kind == "review", review.revision == 10, review.decision == "pending_positive_basis" else { exit(1) }
                case .admission(let admission): guard kind == "admit", admission.revision == 10 else { exit(1) }
                case .activation(let activation): guard kind == "activate", activation.generation == 3, activation.storeRevision == 12, activation.unknownOutcomes == 1 else { exit(1) }
                case .invocation(let request): guard kind == "invoke", request.disposition == "held", request.revision == 10 else { exit(1) }
                case .notFound: guard mode.contains("missing") else { exit(1) }
                }
                let changed = HomeExplicitRuleOperation.invoke(epoch: 8, operation: original.operationID, generation: 3, ruleID: "rule:one")
                do { try result.verify(original: changed, principal: "operator:fixture"); exit(1) } catch LocalHealthError.invalidResponse {}
                do { try result.verify(original: original, principal: "operator:other"); exit(1) } catch LocalHealthError.invalidResponse {}
            }
        } catch LocalHealthError.invalidResponse where mode.contains("invalid") { return }
        catch LocalHealthError.server("permission_denied") where mode.contains("refused") { return }
    }
}
