import Foundation

struct HomeMappingBinding: Sendable, Hashable {
    let id: String, version: String, sha: String
    var fields: [String: String] { ["id": id, "version": version, "sha256": sha] }
    static func == (a: Self, b: Self) -> Bool {
        Array(a.id.utf8) == Array(b.id.utf8) && Array(a.version.utf8) == Array(b.version.utf8) && Array(a.sha.utf8) == Array(b.sha.utf8)
    }
    func hash(into hasher: inout Hasher) { hasher.combine(Data(id.utf8)); hasher.combine(Data(version.utf8)); hasher.combine(Data(sha.utf8)) }
}

struct HomeMappingGrammar: Sendable, CustomReflectable {
    let bindings: [HomeMappingBinding], limits: HomeAuthoringContractLimits
    let basis: String
    private init(bindings: [HomeMappingBinding], limits: HomeAuthoringContractLimits, basis: String) {
        self.bindings = bindings; self.limits = limits; self.basis = basis
    }
    var customMirror: Mirror { Mirror(self, children: ["bindingCount": bindings.count, "basis": basis]) }
    static func parse(_ contract: HomeAuthoringContractRead) throws -> Self {
        let document = try JSONSerialization.jsonObject(with: contract.contractBytes()) as! [String: Any]
        guard let schemas = document["schemas"] as? [String: Any], let draft = schemas["draft"] as? [String: Any],
              let properties = draft["properties"] as? [String: Any], Set(properties.keys) == Set(["format", "profile", "definitions"]),
              Set(draft["required"] as? [String] ?? []) == Set(["format", "profile", "definitions"]),
              (properties["format"] as? [String: Any])?["const"] as? String == "wotex.profile.draft@1",
              let profile = properties["profile"] as? [String: Any], let profileFields = profile["properties"] as? [String: Any],
              Set(profileFields.keys) == Set(["format", "id", "version", "binding", "fingerprint", "channels", "requires", "annotations"]),
              Set(profile["required"] as? [String] ?? []) == Set(["format", "id", "version", "binding", "fingerprint", "channels", "requires"]),
              (profileFields["format"] as? [String: Any])?["const"] as? String == "wotex.profile@1",
              let records = document["bindings"] as? [[String: Any]], records.count <= min(32, Int(contract.limits.reader["max_bindings"]!)) else {
            throw LocalHealthError.server("mapping_editor_unavailable")
        }
        let bindings = try records.map { value in
            guard let id = value["id"] as? String, let version = value["version"] as? String, let sha = value["sha256"] as? String,
                  LocalHealthClient.externalReference(["id": id, "version": version, "sha256": sha]) else { throw LocalHealthError.invalidResponse }
            return HomeMappingBinding(id: id, version: version, sha: sha)
        }
        guard zip(bindings, bindings.dropFirst()).allSatisfy({ a, b in
            let x = Array(a.id.utf8), y = Array(b.id.utf8)
            return x == y ? Array(a.version.utf8).lexicographicallyPrecedes(Array(b.version.utf8)) : x.lexicographicallyPrecedes(y)
        }) else { throw LocalHealthError.invalidResponse }
        return Self(bindings: bindings, limits: contract.limits, basis: contract.basisSHA)
    }
}

struct NativeMappingDraftFields: Sendable, CustomReflectable {
    var id = "", version = "1.0.0"
    var binding: HomeMappingBinding?
    var fingerprint = "[]", channels = "[]", definitions = "[]", requires = "[]", annotations = ""
    var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
    func payload(grammar: HomeMappingGrammar) throws -> Data {
        guard let binding, grammar.bindings.contains(binding),
              LocalHealthClient.externalReference(["id": id, "version": version, "sha256": String(repeating: "0", count: 64)]) else { throw LocalHealthError.invalidProfileRequest }
        let reader = grammar.limits.reader
        let maximum = Int(reader["max_bytes"]!), depth = Int(reader["max_depth"]!), nodeLimit = Int(reader["max_nodes"]!), stringLimit = min(8192, Int(reader["max_bytes"]!))
        func section(_ text: String, count: Int, object: Bool = false) throws -> Data {
            guard (1...min(262144, maximum)).contains(text.utf8.count) else { throw LocalHealthError.invalidProfileRequest }
            let bytes = Data(text.utf8)
            try StrictLocalJSON.check(bytes, maximumKeyBytes: stringLimit, maximumDepth: depth, maximumObjectKeys: 1024)
            let value = try JSONSerialization.jsonObject(with: bytes)
            if object {
                guard let map = value as? [String: Any], map.count <= count else { throw LocalHealthError.invalidProfileRequest }
            } else { guard let list = value as? [Any], list.count <= count else { throw LocalHealthError.invalidProfileRequest } }
            return bytes
        }
        let fingerprint = try section(fingerprint, count: 32)
        let channels = try section(channels, count: min(32, Int(reader["max_channels"]!)))
        let definitions = try section(definitions, count: min(32, Int(reader["max_definitions"]!)))
        let requires = try section(requires, count: min(32, Int(reader["max_dependencies"]!)))
        let annotations = annotations.isEmpty ? nil : try section(annotations, count: 16, object: true)
        func string(_ value: String) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes]) }
        let reference = try JSONSerialization.data(withJSONObject: binding.fields, options: [.sortedKeys, .withoutEscapingSlashes])
        var bytes = Data("{\"format\":\"wotex.profile.draft@1\",\"profile\":{\"format\":\"wotex.profile@1\",\"id\":".utf8)
        bytes += try string(id); bytes += Data(",\"version\":".utf8); bytes += try string(version)
        bytes += Data(",\"binding\":".utf8); bytes += reference
        bytes += Data(",\"fingerprint\":".utf8); bytes += fingerprint
        bytes += Data(",\"channels\":".utf8); bytes += channels
        bytes += Data(",\"requires\":".utf8); bytes += requires
        if let annotations { bytes += Data(",\"annotations\":".utf8); bytes += annotations }
        bytes += Data("},\"definitions\":".utf8); bytes += definitions; bytes += Data("}".utf8)
        guard bytes.count <= min(262144, maximum) else { throw LocalHealthError.invalidProfileRequest }
        try StrictLocalJSON.check(bytes, maximumKeyBytes: stringLimit, maximumDepth: depth, maximumObjectKeys: 1024)
        let value = try JSONSerialization.jsonObject(with: bytes)
        var nodes = 0
        func bounded(_ value: Any) -> Bool {
            nodes += 1; guard nodes <= nodeLimit else { return false }
            if let map = value as? [String: Any] { return map.count <= 1024 && map.keys.allSatisfy { $0.utf8.count <= stringLimit } && map.values.allSatisfy(bounded) }
            if let list = value as? [Any] { return list.count <= 1024 && list.allSatisfy(bounded) }
            if let text = value as? String { return text.utf8.count <= stringLimit }
            return true
        }
        guard bounded(value) else { throw LocalHealthError.invalidProfileRequest }
        return bytes
    }
}
