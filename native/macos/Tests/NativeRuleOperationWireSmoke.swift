import Foundation

private enum RuleWireSmokeError: Error { case failed }
@main
struct NativeRuleOperationWireSmoke {
    static func main() throws {
        let prefix = "\"wotex-home.explicit-rule-operation.v1\""
        let vectors = [
            "[\(prefix),\"review\",7,\"rule:review\",9,\"rule:one\",2,\"light:one\",false]",
            "[\(prefix),\"admit\",7,\"rule:admit\",9,\"rule:one\",2,\"light:one\",true]",
            "[\(prefix),\"activate\",7,\"rule:activate\",9,4]",
            "[\(prefix),\"activate\",7,\"rule:suspend\",9,0]",
            "[\(prefix),\"invoke\",7,\"rule:invoke\",3,\"rule:one\"]"
        ]
        for literal in vectors { let value = try NativeRuleOperationWire.decode(Data(literal.utf8)); try check(try NativeRuleOperationWire.encode(value) == Data(literal.utf8)) }
        let admitted = try NativeRuleOperationWire.decode(Data(vectors[1].utf8))
        try check(try NativeRuleOperationWire.digest(admitted) == "fc52e2c35a08d3c9dedd9fd58c22135913bd528be565bc0163ea1ae638f8a13a")
        let expected: [String: Any] = ["version": 1, "id": "rule:one", "source_revision": 2,
            "trigger": ["kind": "explicit_request"], "predicate": ["op": "literal_true"],
            "effect": ["target_id": "light:one", "capability_key": "power", "value": ["type": "boolean", "value": true]],
            "authority_class": "automation", "unknown_policy": "block", "ownership_ms": 1, "cooldown_ms": 0, "causal_budget": 1]
        try check(NSDictionary(dictionary: admitted.rule!.source()) == NSDictionary(dictionary: expected))
        for malformed in [vectors[1] + " ", vectors[1].replacingOccurrences(of: "7,", with: "true,"),
            vectors[1].replacingOccurrences(of: ",true]", with: ",1]"), vectors[1].replacingOccurrences(of: ",9,", with: ",09,"),
            vectors[1].replacingOccurrences(of: ",9,", with: ",9.0,"), vectors[1].replacingOccurrences(of: ",9,", with: ",-1,"),
            vectors[1].replacingOccurrences(of: ",9,", with: ",9223372036854775807,"),
            vectors[1].replacingOccurrences(of: "light:one", with: "light/one"), vectors[1].replacingOccurrences(of: "light:one", with: "light:é"),
            vectors[1].replacingOccurrences(of: "light:one", with: String(repeating: "a", count: 129)),
            vectors[1].replacingOccurrences(of: "light:one", with: "light:\\u006fne"),
            vectors[1].replacingOccurrences(of: ",true]", with: ",[true]]"), vectors[1].replacingOccurrences(of: ",true]", with: ",null]"),
            vectors[1].replacingOccurrences(of: ",true]", with: ",{\"code\":true}]"), vectors[1].replacingOccurrences(of: ",true]", with: ",true,0]"),
            vectors[2].replacingOccurrences(of: ",9,4]", with: ",9,10]"), vectors[4].replacingOccurrences(of: ",3,", with: ",0,"),
            "[" + String(repeating: "1,", count: 2100) + "1]"
        ] { try refused { try NativeRuleOperationWire.decode(Data(malformed.utf8)) } }
        print("native explicit rule independent records, digest and source vectors passed")
    }
    private static func check(_ value: Bool) throws { guard value else { throw RuleWireSmokeError.failed } }
    private static func refused<T>(_ block: () throws -> T) throws { do { _ = try block() } catch { return }; throw RuleWireSmokeError.failed }
}
