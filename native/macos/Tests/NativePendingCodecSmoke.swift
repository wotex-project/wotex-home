import Foundation

private enum PendingSmokeError: Error { case failed }

@main
struct NativePendingCodecSmoke {
    private static let deployment = String(repeating: "a", count: 64)
    private static let owner = String(repeating: "b", count: 64)
    private static let verifier = String(repeating: "c", count: 64)
    private static var context: NativePendingContext {
        NativePendingContext(deployment: deployment, owner: owner, epoch: 7, principal: "operator:fixture")
    }
    private static var contextLiteral: String { "[\"\(deployment)\",\"\(owner)\",7,\"operator:fixture\"]" }

    static func main() throws {
        FileHandle.standardError.write(Data("pending fixture: empty and original inputs\n".utf8))
        let empty = Data("[\"wotex-home.native-pending.v1\",1,[]]".utf8)
        try check(try NativePendingDocument.decode(empty) == NativePendingDocument(revision: 1, entries: []))
        try check(try NativePendingDocument(revision: 1, entries: []).encoded() == empty)
        try refused { try NativePendingDocument.empty.encoded() }
        let vectors: [(NativePendingInput, String)] = [
            (.power(operation: "power:1", target: "lamp:1", revision: 0, on: true), "[\"submit\",\"power:1\",\"lamp:1\",0,true]"),
            (.power(operation: "power:1", target: "lamp:1", revision: 9, on: false), "[\"submit\",\"power:1\",\"lamp:1\",9,false]"),
            (.cancel(operation: "cancel:1"), "[\"cancel\",\"cancel:1\"]"),
            (.issueOverride(operation: "override:1", target: "lamp:1", revision: 9, duration: 86_400_000), "[\"override_issue\",\"override:1\",\"lamp:1\",9,86400000]"),
            (.revokeOverride(operation: "override:1"), "[\"override_revoke\",\"override:1\"]"),
            (.suspend(operation: "rule:1", revision: 9), "[\"activate_rule\",\"rule:1\",9,0]"),
            (.beginMaintenance(operation: "maintenance:1", revision: 0), "[\"begin_maintenance\",\"maintenance:1\",0]"),
            (.endMaintenance(operation: "maintenance:1", revision: 9, beginRevision: 3), "[\"end_maintenance\",\"maintenance:1\",9,3]"),
        ]
        for (input, literal) in vectors {
            let entry = NativePendingEntry(context: context, custody: .manual(verifier: verifier), input: input, phase: .pending)
            let bytes = Data(document(category: input.category.rawValue, input: literal).utf8)
            let expected = NativePendingDocument(revision: 12, entries: [entry])
            try check(try expected.encoded() == bytes)
            try check(try NativePendingDocument.decode(bytes) == expected)
        }
        FileHandle.standardError.write(Data("pending fixture: native references\n".utf8)); try nativeCustody()
        FileHandle.standardError.write(Data("pending fixture: versioned native access\n".utf8)); try targetAccess()
        FileHandle.standardError.write(Data("pending fixture: versioned explicit rules\n".utf8)); try explicitRules()
        FileHandle.standardError.write(Data("pending fixture: schedule originals\n".utf8)); try schedules()
        FileHandle.standardError.write(Data("pending fixture: profile phases\n".utf8)); try profiles()
        FileHandle.standardError.write(Data("pending fixture: bounds and conflicts\n".utf8)); try boundsAndConflicts()
        FileHandle.standardError.write(Data("pending fixture: rejected encodings\n".utf8)); try mutations()
        print("native pending codec independent closed vectors and bounds passed")
    }

    private static func document(category: String, input: String, phase: String = "[\"pending\"]") -> String {
        "[\"wotex-home.native-pending.v1\",12,[[\"\(category)\",\(contextLiteral),[\"manual\",\"\(verifier)\"],\(input),\(phase)]]]"
    }

    private static func nativeCustody() throws {
        let zeroVerifier = "66687aadf862bd776c8fc18b8e9f8e20089714856ee233b3902a591d0d5f2925"
        for role in NativeCustodyRole.allCases {
            let principal = "native-setup-v1:7:\(role.rawValue)"
            let nativeContext = NativePendingContext(deployment: deployment, owner: owner, epoch: 7, principal: principal)
            let custody = NativePendingCustody.native(role: role, creationRevision: 3, verifier: zeroVerifier)
            let entry = NativePendingEntry(context: nativeContext, custody: custody, input: .cancel(operation: "cancel:1"), phase: .pending)
            let literal = "[\"wotex-home.native-pending.v1\",12,[[\"power\",[\"\(deployment)\",\"\(owner)\",7,\"\(principal)\"],[\"native\",\"\(role.rawValue)\",3,\"\(zeroVerifier)\"],[\"cancel\",\"cancel:1\"],[\"pending\"]]]]"
            try check(try NativePendingDocument(revision: 12, entries: [entry]).encoded() == Data(literal.utf8))
            try check(try NativePendingDocument.decode(Data(literal.utf8)).entries == [entry])
            try check(custody.matches(Data(repeating: 0, count: 32)) && !custody.matches(Data(repeating: 1, count: 32)))
            let original = try custody.nativeOriginal(context: nativeContext)
            try check(original.receipt.principal == principal && original.receipt.revision == 3 && original.verifier == zeroVerifier)
            try check(!NativePendingCustody.manual(verifier: zeroVerifier).valid(context: nativeContext))
            try check(!custody.valid(context: context))
            try check(Mirror(reflecting: entry).children.isEmpty && Mirror(reflecting: custody).children.isEmpty)
        }
        let identity = HomeControllerIdentity(deploymentID: deployment, ownerID: owner, authorityEpoch: 7, revision: 999, principalID: "operator:fixture")
        try check(context.matches(identity))
        for changed in [
            HomeControllerIdentity(deploymentID: verifier, ownerID: owner, authorityEpoch: 7, revision: 999, principalID: identity.principalID),
            HomeControllerIdentity(deploymentID: deployment, ownerID: verifier, authorityEpoch: 7, revision: 999, principalID: identity.principalID),
            HomeControllerIdentity(deploymentID: deployment, ownerID: owner, authorityEpoch: 8, revision: 999, principalID: identity.principalID),
            HomeControllerIdentity(deploymentID: deployment, ownerID: owner, authorityEpoch: 7, revision: 999, principalID: "operator:other"),
        ] { try check(!context.matches(changed)) }
    }

    private static func profiles() throws {
        for action in ["approve", "revoke", "revoke_selection", "select"] {
            var dictionary: [String: Any] = ["action": action, "authority_epoch": 7, "operation_id": "profile:1",
                "expected_revision": 9, "artifact_digest": verifier, "expected_trust_revision": 2]
            var flat = "\"\(action)\",7,\"profile:1\",9,\"\(verifier)\",2"
            if action == "revoke_selection" || action == "select" {
                dictionary["target_id"] = "lamp:1"; dictionary["expected_resource_revision"] = 4
                dictionary["expected_selection_generation"] = 2
            }
            if action == "revoke_selection" { flat += ",\"lamp:1\",4,2" }
            if action == "select" {
                dictionary["expected_binding_revision"] = 3; dictionary["expected_policy_generation"] = 5
                dictionary["expected_rule_generation"] = 6; dictionary["session_ref"] = "capture:1"
                dictionary["candidate_ref"] = "candidate:1"; dictionary["review_ref"] = "enrollment:1"
                flat += ",\"lamp:1\",4,3,2,5,6,\"capture:1\",\"candidate:1\",\"enrollment:1\""
            }
            let operation = try HomeProfileOperation(dictionary)
            for preparing in action == "select" ? [false, true] : [false] {
                let input = NativePendingInput.profile(preparing: preparing, operation: operation)
                let entry = NativePendingEntry(context: context, custody: .manual(verifier: verifier), input: input, phase: .pending)
                let bytes = Data(document(category: "profile", input: "[\"\(preparing ? "profile_prepare" : "profile_change")\",\(flat)]").utf8)
                try check(try NativePendingDocument(revision: 12, entries: [entry]).encoded() == bytes)
                try check(try NativePendingDocument.decode(bytes).entries == [entry])
                if action == "select" {
                    for (phase, name) in [(NativePendingPhase.review(token: "review:1", digest: verifier), "review"),
                        (.commitPending(token: "review:1", digest: verifier), "commit_pending"),
                        (.cancelPending(token: "review:1", digest: verifier), "cancel_pending")] {
                        let changed = try entry.changingPhase(phase)
                        let expected = bytes.replacingASCII("[\"pending\"]", with: "[\"\(name)\",\"review:1\",\"\(verifier)\"]")
                        try check(try NativePendingDocument(revision: 12, entries: [changed]).encoded() == expected)
                        try check(changed.input == entry.input && changed.custody == entry.custody && changed.context == entry.context)
                    }
                } else {
                    try refused { try entry.changingPhase(.review(token: "review:1", digest: verifier)) }
                }
            }
            if action != "select" {
                let entry = NativePendingEntry(context: context, custody: .manual(verifier: verifier), input: .profile(preparing: true, operation: operation), phase: .pending)
                try refused { try NativePendingDocument(revision: 1, entries: [entry]).encoded() }
            }
            var wrongEpoch = dictionary; wrongEpoch["authority_epoch"] = 8
            let wrong = NativePendingEntry(context: context, custody: .manual(verifier: verifier), input: .profile(preparing: false, operation: try HomeProfileOperation(wrongEpoch)), phase: .pending)
            try refused { try NativePendingDocument(revision: 1, entries: [wrong]).encoded() }
        }
    }

    private static func targetAccess() throws {
        let nativeContext = NativePendingContext(deployment: deployment, owner: owner, epoch: 7, principal: "native-setup-v1:7:operator")
        let custody = NativePendingCustody.native(role: .operator, creationRevision: 3, verifier: verifier)
        let basis = NativeTargetBasis(resource: 4, binding: 5, generation: 2, artifact: String(repeating: "d", count: 64))
        let nativeLiteral = "[\"\(deployment)\",\"\(owner)\",7,\"native-setup-v1:7:operator\"]"
        for (action, pins) in [(NativeTargetChange.Action.grant, ",4,5,2,\"\(basis.artifact)\""), (.revoke, "")] {
            let input = NativePendingInput.targetAccess(operation: "access:one", revision: 9, target: "light:one", action: action,
                basis: action == .grant ? basis : nil)
            let entry = NativePendingEntry(context: nativeContext, custody: custody, input: input, phase: .pending)
            let literal = "[\"wotex-home.native-pending.v2\",12,[[\"access\",\(nativeLiteral),[\"native\",\"operator\",3,\"\(verifier)\"],[\"native_target_\(action.rawValue)\",\"access:one\",9,\"light:one\"\(pins)],[\"pending\"]]]]"
            let bytes = Data(literal.utf8)
            let document = NativePendingDocument(revision: 12, entries: [entry])
            try check(document.version == .v2 && document.encoded() == bytes)
            try check(try NativePendingDocument.decode(bytes) == document)
            try refused { try NativePendingDocument(revision: 12, entries: [entry], version: .v1).encoded() }
            try refused { try NativePendingDocument.decode(bytes.replacingASCII("native-pending.v2", with: "native-pending.v1")) }
            let retainedV5 = try NativePendingDocument.decode(bytes.replacingASCII("native-pending.v2", with: "native-pending.v5"))
            try check(retainedV5.version == .v5 && retainedV5.entries == [entry])
            try refused { try NativePendingDocument.decode(bytes.replacingASCII("native-pending.v2", with: "native-pending.v6")) }
            let change = try entry.targetChange()
            let expected = "[\"wotex-home.native-target-access.v1\",\"\(action.rawValue)\",\"\(deployment)\",\"\(owner)\",7,3,\"\(verifier)\",\"access:one\",9,\"light:one\"\(pins)]"
            try check(try NativeTargetWire.change(change) == Data(expected.utf8))
            if action == .grant {
                try check(try NativeTargetWire.digest(NativeTargetWire.change(change)) == "3cb0cc8dd8705ee7d071c5677ada5c1bd63e71880dfbc9f764e0f027747cebc2")
            }
            let ordinary = NativePendingEntry(context: context, custody: .manual(verifier: verifier), input: .cancel(operation: "cancel:one"), phase: .pending)
            let mixed = NativePendingDocument(revision: 13, entries: NativePendingDocument.sorted([ordinary, entry]))
            try check(try NativePendingDocument.decode(mixed.encoded()) == mixed)
            for role in NativeCustodyRole.allCases where role != .operator {
                let altered = NativePendingEntry(context: NativePendingContext(deployment: deployment, owner: owner, epoch: 7,
                    principal: NativeCoreWire.principal(7, role)), custody: .native(role: role, creationRevision: 3, verifier: verifier), input: input, phase: .pending)
                try refused { try NativePendingDocument(revision: 1, entries: [altered]).encoded() }
            }
            let manual = NativePendingEntry(context: context, custody: .manual(verifier: verifier), input: input, phase: .pending)
            try refused { try NativePendingDocument(revision: 1, entries: [manual]).encoded() }
            try refused { try entry.changingPhase(.review(token: "review:one", digest: verifier)) }
            try refused { try NativePendingDocument.decode(bytes.replacingASCII(",9,\"light:one\"", with: ",2,\"light:one\"")) }
            try refused { try NativePendingDocument.decode(bytes.replacingASCII(",9,\"light:one\"", with: ",9223372036854775807,\"light:one\"")) }
            try refused { try NativePendingDocument.decode(bytes.replacingASCII("light:one", with: "light/one")) }
        }
        let retained = NativePendingDocument(revision: 14, entries: [], version: .v2)
        try check(try retained.encoded() == Data("[\"wotex-home.native-pending.v2\",14,[]]".utf8))
        try check(try NativePendingDocument.decode(retained.encoded()) == retained)
    }

    private static func explicitRules() throws {
        let prefix = "\"wotex-home.explicit-rule-operation.v1\""
        let inputs = [
            "[\(prefix),\"review\",7,\"rule:review\",9,\"rule:one\",2,\"light:one\",false]",
            "[\(prefix),\"admit\",7,\"rule:admit\",9,\"rule:one\",2,\"light:one\",true]",
            "[\(prefix),\"activate\",7,\"rule:activate\",9,4]",
            "[\(prefix),\"invoke\",7,\"rule:invoke\",3,\"rule:one\"]"
        ]
        for literal in inputs {
            let operation = try NativeRuleOperationWire.decode(Data(literal.utf8))
            let input = NativePendingInput.explicitRule(operation)
            let entry = NativePendingEntry(context: context, custody: .manual(verifier: verifier), input: input, phase: .pending)
            let bytes = Data(document(category: "rule", input: literal).replacingOccurrences(of: "native-pending.v1", with: "native-pending.v3").utf8)
            let document = NativePendingDocument(revision: 12, entries: [entry])
            try check(document.version == .v3 && document.encoded() == bytes)
            try check(try NativePendingDocument.decode(bytes) == document && entry.ruleOperation() == operation)
            if operation.kind == "admit" { try check(try NativeRuleOperationWire.digest(entry.ruleOperation()) == "fc52e2c35a08d3c9dedd9fd58c22135913bd528be565bc0163ea1ae638f8a13a") }
            for version in [NativePendingVersion.v1, .v2] {
                try refused { try NativePendingDocument(revision: 12, entries: [entry], version: version).encoded() }
                try refused { try NativePendingDocument.decode(bytes.replacingASCII("native-pending.v3", with: version.rawValue.replacingOccurrences(of: "wotex-home.", with: ""))) }
            }
            let ordinary = NativePendingEntry(context: context, custody: entry.custody, input: .cancel(operation: "power:old"), phase: .pending)
            let mixed = NativePendingDocument(revision: 13, entries: NativePendingDocument.sorted([ordinary, entry]))
            try check(try NativePendingDocument.decode(mixed.encoded()) == mixed)
            let oldRule = NativePendingEntry(context: context, custody: entry.custody, input: .suspend(operation: "rule:old", revision: 9), phase: .pending)
            try refused { try NativePendingDocument(revision: 13, entries: NativePendingDocument.sorted([oldRule, entry])).encoded() }
            try refused { try entry.changingPhase(.review(token: "review:one", digest: verifier)) }
            try refused { try NativePendingDocument.decode(bytes.replacingASCII(",7,\"rule:", with: ",8,\"rule:")) }
            for role in NativeCustodyRole.allCases {
                let native = NativePendingEntry(context: NativePendingContext(deployment: deployment, owner: owner, epoch: 7, principal: NativeCoreWire.principal(7, role)),
                    custody: .native(role: role, creationRevision: 3, verifier: verifier), input: input, phase: .pending)
                if role == .operator { try check(try NativePendingDocument.decode(NativePendingDocument(revision: 1, entries: [native]).encoded()).entries == [native]) }
                else { try refused { try NativePendingDocument(revision: 1, entries: [native]).encoded() } }
            }
        }
        let empty = NativePendingDocument(revision: 14, entries: [], version: .v3)
        try check(try empty.encoded() == Data("[\"wotex-home.native-pending.v3\",14,[]]".utf8))
        try check(try NativePendingDocument.decode(empty.encoded()) == empty)
    }

    private static func schedules() throws {
        guard CommandLine.arguments.count == 2 else { throw PendingSmokeError.failed }
        let fixture = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        try check(fixture.count <= 65_536)
        guard let corpus = try JSONSerialization.jsonObject(with: fixture) as? [String: Any],
              let vectors = corpus["vectors"] as? [[String: String]],
              let refusals = corpus["refusals"] as? [String] else { throw PendingSmokeError.failed }
        try check(vectors.count == 15)
        func quoted(_ text: String) -> String {
            "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        for vector in vectors {
            let original = vector["document"]!
            let operation = try NativeScheduleWire.decode(Data(original.utf8))
            let principal = operation.source?.author ?? "operator:fixture"
            let context = NativePendingContext(deployment: deployment, owner: owner, epoch: operation.epoch, principal: principal)
            let entry = NativePendingEntry(context: context, custody: .manual(verifier: verifier), input: .schedule(operation), phase: .pending)
            let literal = "[\"wotex-home.native-pending.v4\",12,[[\"schedule\",[\"\(deployment)\",\"\(owner)\",\(operation.epoch),\"\(principal)\"],[\"manual\",\"\(verifier)\"],[\"schedule_operation\",\(quoted(original))],[\"pending\"]]]]"
            let bytes = Data(literal.utf8)
            let document = NativePendingDocument(revision: 12, entries: [entry])
            try check(document.version == .v4 && document.encoded() == bytes)
            try check(try NativePendingDocument.decode(bytes) == document && entry.scheduleOperation() == operation)
            for version in [NativePendingVersion.v1, .v2, .v3] {
                try refused { try NativePendingDocument(revision: 12, entries: [entry], version: version).encoded() }
                try refused { try NativePendingDocument.decode(bytes.replacingASCII("wotex-home.native-pending.v4", with: version.rawValue)) }
            }
            let power = NativePendingEntry(context: context, custody: entry.custody, input: .cancel(operation: "power:old"), phase: .pending)
            let rule = NativePendingEntry(context: context, custody: entry.custody, input: .suspend(operation: "rule:old", revision: 9), phase: .pending)
            let mixed = NativePendingDocument(revision: 13, entries: NativePendingDocument.sorted([power, rule, entry]))
            try check(try NativePendingDocument.decode(mixed.encoded()) == mixed)
            let other = NativePendingEntry(context: context, custody: entry.custody,
                input: .schedule(.suspend(epoch: context.epoch, operation: "schedule:other", expected: 9)), phase: .pending)
            try refused { try NativePendingDocument(revision: 13, entries: NativePendingDocument.sorted([entry, other])).encoded() }
            try refused { try entry.changingPhase(.review(token: "review:one", digest: verifier)) }
            let wrongContext = NativePendingContext(deployment: deployment, owner: owner, epoch: operation.epoch == 7 ? 8 : 7, principal: principal)
            let wrong = NativePendingEntry(context: wrongContext, custody: entry.custody, input: entry.input, phase: .pending)
            try refused { try NativePendingDocument(revision: 1, entries: [wrong]).encoded() }
            if operation.source != nil {
                let wrongAuthor = NativePendingEntry(context: NativePendingContext(deployment: deployment, owner: owner, epoch: operation.epoch, principal: "operator:other"),
                    custody: entry.custody, input: entry.input, phase: .pending)
                try refused { try NativePendingDocument(revision: 1, entries: [wrongAuthor]).encoded() }
            }
            // v4's expanded string must not spill into context or legacy IDs.
            try refused { try NativePendingDocument.decode(bytes.replacingASCII(principal, with: String(repeating: "x", count: 129))) }
            try refused { try NativePendingDocument.decode(bytes.replacingASCII("schedule_operation", with: "schedule\\\"operation")) }
            try refused { try NativePendingDocument.decode(bytes.replacingASCII("schedule_operation", with: "schedule\\u005foperation")) }
            if original.contains("\"review\"") {
                try refused { try NativePendingDocument.decode(bytes.replacingASCII("\\\"review\\\"", with: "\\u0022review\\\"")) }
            }
        }
        for role in NativeCustodyRole.allCases {
            let context = NativePendingContext(deployment: deployment, owner: owner, epoch: 7, principal: NativeCoreWire.principal(7, role))
            let entry = NativePendingEntry(context: context, custody: .native(role: role, creationRevision: 3, verifier: verifier),
                input: .schedule(.suspend(epoch: 7, operation: "schedule:one", expected: 9)), phase: .pending)
            if role == .operator { try check(try NativePendingDocument.decode(NativePendingDocument(revision: 1, entries: [entry]).encoded()).entries == [entry]) }
            else { try refused { try NativePendingDocument(revision: 1, entries: [entry]).encoded() } }
            let early = NativePendingEntry(context: context, custody: entry.custody,
                input: .schedule(.suspend(epoch: 7, operation: "schedule:early", expected: 2)), phase: .pending)
            try refused { try NativePendingDocument(revision: 1, entries: [early]).encoded() }
        }
        try check(refusals.count == 61)
        func wrapped(_ original: String) -> Data {
            let literal = document(category: "schedule", input: "[\"schedule_operation\",\(quoted(original))]")
                .replacingOccurrences(of: "native-pending.v1", with: "native-pending.v4")
                .replacingOccurrences(of: contextLiteral, with: contextLiteral.replacingOccurrences(of: "operator:fixture", with: "operator:one"))
            return Data(literal.utf8)
        }
        // Match the corpus author's context, and prove the positive control,
        // so malformed-original refusals cannot pass on an unrelated author guard.
        try check(try NativePendingDocument.decode(wrapped(vectors[0]["document"]!)).entries[0].scheduleOperation().kind == "admit")
        for original in refusals + [String(repeating: "x", count: 8_193)] {
            try refused { try NativePendingDocument.decode(wrapped(original)) }
        }
        let empty = NativePendingDocument(revision: 14, entries: [], version: .v4)
        try check(try empty.encoded() == Data("[\"wotex-home.native-pending.v4\",14,[]]".utf8))
        try check(try NativePendingDocument.decode(empty.encoded()) == empty)
    }

    private static func boundsAndConflicts() throws {
        var entries: [NativePendingEntry] = []
        for index in 0..<16 {
            let context = NativePendingContext(deployment: deployment, owner: String(format: "%064x", index), epoch: 7, principal: "operator:fixture")
            entries.append(NativePendingEntry(context: context, custody: .manual(verifier: verifier), input: .cancel(operation: "cancel:1"), phase: .pending))
        }
        let document = NativePendingDocument(revision: Int64.max, entries: NativePendingDocument.sorted(entries))
        try check(try NativePendingDocument.decode(document.encoded()) == document)
        entries.append(entries[0])
        try refused { try NativePendingDocument(revision: 1, entries: NativePendingDocument.sorted(entries)).encoded() }
        let first = entries[0]
        let sameOwner = NativePendingEntry(context: NativePendingContext(deployment: first.context.deployment, owner: first.context.owner,
            epoch: first.context.epoch, principal: "operator:other"), custody: first.custody, input: .power(operation: "power:2", target: "lamp:2", revision: 1, on: false), phase: .pending)
        try refused { try NativePendingDocument(revision: 1, entries: NativePendingDocument.sorted([first, sameOwner])).encoded() }
        try refused { try NativePendingDocument(revision: 1, entries: Array(document.entries.reversed())).encoded() }
        let invalid: [NativePendingInput] = [.power(operation: "bad/path", target: "lamp:1", revision: 0, on: true),
            .issueOverride(operation: "override:1", target: "lamp:1", revision: 0, duration: 0),
            .issueOverride(operation: "override:1", target: "lamp:1", revision: 0, duration: 86_400_001),
            .suspend(operation: "rule:1", revision: Int64.max),
            .beginMaintenance(operation: "maintenance:1", revision: Int64.max - 1),
            .endMaintenance(operation: "maintenance:1", revision: 9, beginRevision: 10)]
        for input in invalid {
            let entry = NativePendingEntry(context: context, custody: .manual(verifier: verifier), input: input, phase: .pending)
            try refused { try NativePendingDocument(revision: 1, entries: [entry]).encoded() }
        }
    }

    private static func mutations() throws {
        let valid = document(category: "power", input: "[\"submit\",\"power:1\",\"lamp:1\",0,true]")
        let malformedInputs: [String] = [" " + valid, valid + "\n", valid + "[]", valid.replacingOccurrences(of: ",12,", with: ",0,"),
            valid.replacingOccurrences(of: ",12,", with: ",true,"), valid.replacingOccurrences(of: ",12,", with: ",12.0,"),
            valid.replacingOccurrences(of: ",12,", with: ",012,"), valid.replacingOccurrences(of: ",12,", with: ",-12,"),
            valid.replacingOccurrences(of: ",12,", with: ",9223372036854775808,"),
            valid.replacingOccurrences(of: "true", with: "1"), valid.replacingOccurrences(of: "true", with: "null"),
            valid.replacingOccurrences(of: "true", with: "[true]"), valid.replacingOccurrences(of: "\"pending\"", with: "true"),
            valid.replacingOccurrences(of: "\"power\"", with: "\"override\""), valid.replacingOccurrences(of: "submit", with: "\\u0073ubmit"),
            valid.replacingOccurrences(of: "lamp:1", with: String(repeating: "a", count: 129)),
            valid.replacingOccurrences(of: "operator:fixture", with: "native-setup-v1:7:operator"),
            valid.replacingOccurrences(of: verifier, with: verifier.uppercased()),
            String(repeating: "[", count: 5) + "0" + String(repeating: "]", count: 5),
            "[" + Array(repeating: "0", count: 33).joined(separator: ",") + "]", String(repeating: " ", count: 65_537),
            "{\"a\":1,\"a\":2}", valid.replacingOccurrences(of: "lamp:1", with: "灯"),
            valid.replacingOccurrences(of: "lamp:1", with: "lamp\u{0}:1"),
        ]
        for malformed in malformedInputs { try refused { try NativePendingDocument.decode(Data(malformed.utf8)) } }
        let rule = document(category: "rule", input: "[\"activate_rule\",\"rule:1\",9,1]")
        try refused { try NativePendingDocument.decode(Data(rule.utf8)) }
    }

    private static func check(_ value: Bool, line: UInt = #line) throws {
        if !value { FileHandle.standardError.write(Data("native pending codec check failed at line \(line)\n".utf8)); throw PendingSmokeError.failed }
    }
    private static func refused<T>(_ body: () throws -> T) throws {
        do { _ = try body() } catch NativePendingError.invalidRecord { return }
        throw PendingSmokeError.failed
    }
}

private extension Data {
    func replacingASCII(_ original: String, with replacement: String) -> Data {
        Data(String(decoding: self, as: UTF8.self).replacingOccurrences(of: original, with: replacement).utf8)
    }
}
