import Foundation

struct HomeAuthoringContractLimits: Sendable, Equatable {
    let reader: [String: Int64], authoring: [String: Int64]
}

enum HomeAuthoringProducerIdentity: Sendable, Equatable {
    case archive(core: String, runtime: String, profiles: String)
    case runtime(revision: String, core: String, runtime: String, profiles: String)
}

struct HomeAuthoringContractRead: Sendable, CustomReflectable {
    let epoch: Int64, revision: Int64
    let principal: String, contractSHA: String, rawSHA: String, basisSHA: String
    let limits: HomeAuthoringContractLimits
    let producer: HomeAuthoringProducerIdentity
    fileprivate let document: Data
    var customMirror: Mirror {
        Mirror(self, children: ["epoch": epoch, "revision": revision, "principal": principal,
                               "contractSHA": contractSHA, "rawSHA": rawSHA, "basisSHA": basisSHA])
    }
    func contractBytes() -> Data { document }
}

enum NativeAuthoringContractClient {
    private static let readerCeilings: [String: Int64] = ["max_bytes": 262144, "max_depth": 8, "max_nodes": 4096,
        "max_channels": 32, "max_definitions": 32, "max_bindings": 32, "max_dependencies": 32, "max_numeric_digits": 64]
    private static let authoringCeilings: [String: Int64] = ["max_bundle_bytes": 262144, "max_diagnostics": 64,
        "max_report_bytes": 24576, "max_check_steps": 1000000]

    static func fetch(socketPath: String, credential: Data) throws -> HomeAuthoringContractRead {
        guard credential.count == 32 else { throw LocalHealthError.invalidProfileRequest }
        return try decode(LocalHealthClient.authoringReadTransport(socketPath: socketPath, credential: credential,
            operation: "authoring_contract_export", fields: [:]))
    }

    static func decode(_ response: [String: Any]) throws -> HomeAuthoringContractRead {
        guard keys(response, ["api_version", "outcome", "authoring_contract"]),
              LocalHealthClient.profileInteger(response["api_version"]) == 1, response["outcome"] as? String == "ok",
              let value = response["authoring_contract"] as? [String: Any],
              keys(value, ["format", "principal_id", "authority_epoch", "store_revision", "summary", "contract_base64"]),
              value["format"] as? String == "wotex-home.authoring-contract-export@1",
              let epoch = integer(value["authority_epoch"]), epoch > 0,
              let revision = integer(value["store_revision"]), revision >= 0,
              let principal = value["principal_id"] as? String, LocalHealthClient.profileID(principal),
              let summary = value["summary"] as? [String: Any],
              keys(summary, ["format", "contract_sha256", "contract_raw_sha256", "producer", "home_contracts", "limits", "consumption_policy", "basis_sha256"]),
              summary["format"] as? String == "wotex-home.authoring-contract@1",
              summary["consumption_policy"] as? String == "wotex-home.read-only-profile@1",
              let contractSHA = digest(summary["contract_sha256"]), let rawSHA = digest(summary["contract_raw_sha256"]),
              let basisSHA = digest(summary["basis_sha256"]), LocalHealthClient.externalProducerIdentity(summary["producer"]),
              references(summary["home_contracts"]),
              let encoded = value["contract_base64"] as? String, encoded.utf8.count <= 349526,
              let bytes = payload(encoded), (1...262144).contains(bytes.count), String(data: bytes, encoding: .utf8) != nil,
              LocalHealthClient.profileSHA(bytes) == rawSHA,
              LocalHealthClient.profileSHA(Data("wotex.profile.authoring-contract@1\n".utf8) + bytes) == contractSHA else {
            throw LocalHealthError.invalidResponse
        }
        let limits = try checkedLimits(summary["limits"])
        guard let producer = summary["producer"] as? [String: String] else { throw LocalHealthError.invalidResponse }
        let identity: HomeAuthoringProducerIdentity
        if let core = producer["core_archive_sha256"], let runtime = producer["runtime_archive_sha256"], let profiles = producer["profiles_archive_sha256"] {
            identity = .archive(core: core, runtime: runtime, profiles: profiles)
        } else if let revision = producer["source_revision"], let core = producer["core_runtime_sha256"],
                  let runtime = producer["runtime_runtime_sha256"], let profiles = producer["profiles_runtime_sha256"] {
            identity = .runtime(revision: revision, core: core, runtime: runtime, profiles: profiles)
        } else { throw LocalHealthError.invalidResponse }
        try StrictLocalJSON.check(bytes, maximumKeyBytes: 16384, maximumDepth: 32, maximumObjectKeys: 4096)
        guard let document = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              keys(document, ["format", "producer", "schemas", "semantic_rules", "bindings", "contracts", "limits"]),
              document["format"] as? String == "wotex.profile.authoring-contract@1",
              let bindings = document["bindings"] as? [Any], bindings.count <= 32,
              references(document["contracts"]), try checkedLimits(document["limits"]) == limits else { throw LocalHealthError.invalidResponse }
        var nodes = 0
        guard bounded(document, depth: 1, nodes: &nodes) else { throw LocalHealthError.invalidResponse }
        return HomeAuthoringContractRead(epoch: epoch, revision: revision, principal: principal, contractSHA: contractSHA,
            rawSHA: rawSHA, basisSHA: basisSHA, limits: limits, producer: identity, document: bytes)
    }

    private static func checkedLimits(_ raw: Any?) throws -> HomeAuthoringContractLimits {
        guard let limits = raw as? [String: Any], keys(limits, Array(authoringCeilings.keys) + ["reader"]),
              let reader = limits["reader"] as? [String: Any], keys(reader, Array(readerCeilings.keys)) else { throw LocalHealthError.invalidResponse }
        func selected(_ raw: [String: Any], _ ceilings: [String: Int64]) throws -> [String: Int64] {
            var result: [String: Int64] = [:]
            for (key, ceiling) in ceilings {
                guard let value = integer(raw[key]), (1...ceiling).contains(value) else { throw LocalHealthError.invalidResponse }
                result[key] = value
            }
            return result
        }
        return HomeAuthoringContractLimits(reader: try selected(reader, readerCeilings), authoring: try selected(limits, authoringCeilings))
    }
    private static func references(_ raw: Any?) -> Bool {
        guard let values = raw as? [[String: Any]], values.count <= 32, values.allSatisfy(LocalHealthClient.externalReference) else { return false }
        let identifiers = values.compactMap { ($0["id"] as? String).map { Array($0.utf8) } }
        return identifiers.count == values.count && identifiers == identifiers.sorted { $0.lexicographicallyPrecedes($1) }
            && Set(identifiers).count == identifiers.count
    }
    private static func payload(_ encoded: String) -> Data? {
        let standard = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard let bytes = Data(base64Encoded: standard + String(repeating: "=", count: (4 - standard.utf8.count % 4) % 4)),
              bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") == encoded else { return nil }
        return bytes
    }
    private static func bounded(_ value: Any, depth: Int, nodes: inout Int) -> Bool {
        nodes += 1
        guard depth <= 33, nodes <= 50000 else { return false }
        if let map = value as? [String: Any] {
            return depth <= 32 && map.count <= 4096 && map.allSatisfy { $0.key.utf8.count <= 16384 && bounded($0.value, depth: depth + 1, nodes: &nodes) }
        }
        if let array = value as? [Any] {
            return depth <= 32 && array.count <= 4096 && array.allSatisfy { bounded($0, depth: depth + 1, nodes: &nodes) }
        }
        if let text = value as? String { return text.utf8.count <= 16384 }
        return value is NSNull || (value as? NSNumber)?.doubleValue.isFinite == true
    }
    private static func keys(_ map: [String: Any], _ expected: [String]) -> Bool { Set(map.keys) == Set(expected) }
    private static func integer(_ value: Any?) -> Int64? { LocalHealthClient.profileInteger(value).map(Int64.init) }
    private static func digest(_ value: Any?) -> String? { guard let text = value as? String, LocalHealthClient.profileDigest(text) else { return nil }; return text }
}

struct HomeAuthoringObjectSummary: Sendable, Equatable {
    let kind: String, digest: String, payloadSHA: String, size: Int
}

struct HomeAuthoringObjectRead: Sendable, CustomReflectable {
    let summary: HomeAuthoringObjectSummary, firstRevision: Int64
    let payload: Data
    var customMirror: Mirror { Mirror(self, children: ["summary": summary, "firstRevision": firstRevision]) }
}

enum HomeAuthoringOriginalKind: String, CaseIterable, Sendable {
    case `import`, candidate, review
    var operation: String { "authoring_" + (self == .import ? "object" : rawValue) + "_status" }
    var member: String { "authoring_" + (self == .import ? "object" : rawValue) + "_receipt" }
}

enum HomeAuthoringReadRequest: Sendable, Equatable {
    case object(String)
    case original(HomeAuthoringOriginalKind, Int64, String)
    var valid: Bool {
        switch self {
        case .object(let digest): LocalHealthClient.profileDigest(digest)
        case .original(_, let epoch, let operation): epoch > 0 && LocalHealthClient.profileID(operation)
        }
    }
}

enum HomeAuthoringReadResult: Sendable, CustomReflectable {
    case object(HomeAuthoringObjectRead?)
    case original(HomeAuthoringOriginalRead?)
    var revision: Int64 {
        switch self {
        case .object(let object): object?.firstRevision ?? 0
        case .original(let original): original?.revision ?? 0
        }
    }
    var customMirror: Mirror { Mirror(self, children: ["revision": revision]) }
}

struct HomeAuthoringOriginalRead: Sendable {
    let kind: HomeAuthoringOriginalKind, epoch: Int64, operation: String, revision: Int64
    let object: HomeAuthoringObjectSummary?, firstRevision: Int64?, candidateRevision: Int64?
    let inputSHA: String?, basisSHA: String?, resultSHA: String?
    let disposition: String?, captureStatus: String?, sourceReview: String?, fixtureStatus: String?
    let consumption: String?, proposalStatus: String?
}

enum NativeAuthoringReadClient {
    private static let tags: [String: UInt8] = ["source": 1, "draft": 2, "bundle": 3, "fixture": 4, "contract": 5, "envelope": 6, "profile": 7, "definition": 8]

    static func fetch(socketPath: String, credential: Data, request: HomeAuthoringReadRequest) throws -> HomeAuthoringReadResult {
        switch request {
        case .object(let digest): .object(try fetchObject(socketPath: socketPath, credential: credential, digest: digest))
        case .original(let kind, let epoch, let operation): .original(try fetchOriginal(socketPath: socketPath, credential: credential, kind: kind, epoch: epoch, operation: operation))
        }
    }

    static func fetchObject(socketPath: String, credential: Data, digest: String) throws -> HomeAuthoringObjectRead? {
        guard LocalHealthClient.profileDigest(digest) else { throw LocalHealthError.invalidProfileRequest }
        let response = try LocalHealthClient.authoringReadTransport(socketPath: socketPath, credential: credential,
            operation: "authoring_object_read", fields: ["object_digest": digest])
        return try decodeObject(response, digest: digest)
    }

    static func fetchOriginal(socketPath: String, credential: Data, kind: HomeAuthoringOriginalKind,
                              epoch: Int64, operation: String) throws -> HomeAuthoringOriginalRead? {
        guard epoch > 0, LocalHealthClient.profileID(operation) else { throw LocalHealthError.invalidProfileRequest }
        let response = try LocalHealthClient.authoringReadTransport(socketPath: socketPath, credential: credential,
            operation: kind.operation, fields: ["authority_epoch": epoch, "operation_id": operation])
        return try decodeOriginal(response, kind: kind, epoch: epoch, operation: operation)
    }

    static func decodeObject(_ response: [String: Any], digest: String) throws -> HomeAuthoringObjectRead? {
        guard LocalHealthClient.profileDigest(digest) else { throw LocalHealthError.invalidProfileRequest }
        guard let raw = try member(response, key: "authoring_object") else { return nil }
        guard keys(raw, ["object", "first_revision", "payload_base64"]),
              let first = positive(raw["first_revision"]),
              let encoded = raw["payload_base64"] as? String, encoded.utf8.count <= 349_526,
              encoded.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else { throw LocalHealthError.invalidResponse }
        let object = try summary(raw["object"])
        let base64 = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard let payload = Data(base64Encoded: base64 + String(repeating: "=", count: (4 - base64.count % 4) % 4)),
              payload.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") == encoded,
              payload.count == object.size, LocalHealthClient.profileSHA(payload) == object.payloadSHA,
              let tag = tags[object.kind] else { throw LocalHealthError.invalidResponse }
        var frame = Data([87, 79, 72, 65, 1, tag])
        let size = UInt32(payload.count)
        frame.append(contentsOf: [UInt8((size >> 24) & 255), UInt8((size >> 16) & 255), UInt8((size >> 8) & 255), UInt8(size & 255)])
        for position in stride(from: 0, to: 64, by: 2) {
            let start = object.payloadSHA.index(object.payloadSHA.startIndex, offsetBy: position)
            let end = object.payloadSHA.index(start, offsetBy: 2)
            guard let byte = UInt8(object.payloadSHA[start..<end], radix: 16) else { throw LocalHealthError.invalidResponse }
            frame.append(byte)
        }
        frame.append(payload)
        guard object.digest == digest, LocalHealthClient.profileSHA(frame) == digest else { throw LocalHealthError.invalidResponse }
        return HomeAuthoringObjectRead(summary: object, firstRevision: first, payload: payload)
    }

    static func decodeOriginal(_ response: [String: Any], kind: HomeAuthoringOriginalKind,
                               epoch: Int64, operation: String) throws -> HomeAuthoringOriginalRead? {
        guard epoch > 0, LocalHealthClient.profileID(operation) else { throw LocalHealthError.invalidProfileRequest }
        guard let raw = try member(response, key: kind.member) else { return nil }
        guard integer(raw["authority_epoch"]) == epoch, raw["operation_id"] as? String == operation,
              let revision = positive(raw["revision"]) else { throw LocalHealthError.invalidResponse }
        switch kind {
        case .import:
            guard keys(raw, ["authority_epoch", "operation_id", "object", "first_revision", "revision"]),
                  let first = positive(raw["first_revision"]), first <= revision else { throw LocalHealthError.invalidResponse }
            return HomeAuthoringOriginalRead(kind: kind, epoch: epoch, operation: operation, revision: revision,
                object: try summary(raw["object"]), firstRevision: first, candidateRevision: nil,
                inputSHA: nil, basisSHA: nil, resultSHA: nil, disposition: nil, captureStatus: nil,
                sourceReview: nil, fixtureStatus: nil, consumption: nil, proposalStatus: nil)
        case .candidate:
            guard keys(raw, ["authority_epoch", "operation_id", "revision", "input_sha256", "basis_sha256", "assessment_sha256", "disposition", "capture_status", "bundle", "source_review", "fixture_status"]),
                  let input = digest(raw["input_sha256"]), let basis = digest(raw["basis_sha256"]), let result = digest(raw["assessment_sha256"]),
                  let disposition = choice(raw["disposition"], ["compatible", "invalid"]),
                  raw["capture_status"] as? String == "not_supplied", raw["source_review"] as? String == "not_assessed",
                  let fixture = choice(raw["fixture_status"], ["not_supplied", "not_assessed"]) else { throw LocalHealthError.invalidResponse }
            let bundle = raw["bundle"] is NSNull ? nil : try summary(raw["bundle"])
            guard bundle == nil || bundle?.kind == "bundle" else { throw LocalHealthError.invalidResponse }
            return HomeAuthoringOriginalRead(kind: kind, epoch: epoch, operation: operation, revision: revision,
                object: bundle, firstRevision: nil, candidateRevision: nil, inputSHA: input, basisSHA: basis, resultSHA: result,
                disposition: disposition, captureStatus: "not_supplied", sourceReview: "not_assessed", fixtureStatus: fixture,
                consumption: nil, proposalStatus: nil)
        case .review:
            guard keys(raw, ["authority_epoch", "operation_id", "revision", "input_sha256", "candidate_revision", "basis_sha256", "result_sha256", "source_review", "home_consumption", "fixture_status", "proposal_status"]),
                  let candidate = positive(raw["candidate_revision"]), candidate < revision,
                  let input = digest(raw["input_sha256"]), let basis = digest(raw["basis_sha256"]), let result = digest(raw["result_sha256"]),
                  let source = choice(raw["source_review"], ["attributed", "incomplete", "ambiguous"]),
                  let consumption = choice(raw["home_consumption"], ["not_assessed", "matched"]),
                  let fixture = choice(raw["fixture_status"], ["not_supplied", "not_assessed", "passed", "failed", "incomplete"]),
                  let proposal = raw["proposal_status"] as? String,
                  proposal == (source == "attributed" && consumption == "matched" && fixture == "passed" ? "complete" : "incomplete") else { throw LocalHealthError.invalidResponse }
            return HomeAuthoringOriginalRead(kind: kind, epoch: epoch, operation: operation, revision: revision,
                object: nil, firstRevision: nil, candidateRevision: candidate, inputSHA: input, basisSHA: basis, resultSHA: result,
                disposition: nil, captureStatus: nil, sourceReview: source, fixtureStatus: fixture, consumption: consumption, proposalStatus: proposal)
        }
    }

    private static func member(_ response: [String: Any], key: String) throws -> [String: Any]? {
        guard integer(response["api_version"]) == 1 else { throw LocalHealthError.invalidResponse }
        if response["outcome"] as? String == "not_found" {
            guard keys(response, ["api_version", "outcome"]) else { throw LocalHealthError.invalidResponse }; return nil
        }
        guard keys(response, ["api_version", "outcome", key]), response["outcome"] as? String == "ok",
              let value = response[key] as? [String: Any] else { throw LocalHealthError.invalidResponse }
        return value
    }
    private static func summary(_ raw: Any?) throws -> HomeAuthoringObjectSummary {
        guard let raw = raw as? [String: Any], keys(raw, ["kind", "object_digest", "payload_sha256", "payload_bytes"]),
              let kind = raw["kind"] as? String, tags[kind] != nil,
              let object = digest(raw["object_digest"]), let payload = digest(raw["payload_sha256"]),
              let size = positive(raw["payload_bytes"]), size <= (["source", "draft", "bundle", "contract"].contains(kind) ? 262_144 : 65_536) else { throw LocalHealthError.invalidResponse }
        return HomeAuthoringObjectSummary(kind: kind, digest: object, payloadSHA: payload, size: Int(size))
    }
    private static func keys(_ value: [String: Any], _ expected: [String]) -> Bool { Set(value.keys) == Set(expected) }
    private static func integer(_ value: Any?) -> Int64? { LocalHealthClient.profileInteger(value).map(Int64.init) }
    private static func positive(_ value: Any?) -> Int64? { guard let number = integer(value), number > 0 else { return nil }; return number }
    private static func digest(_ value: Any?) -> String? { guard let text = value as? String, LocalHealthClient.profileDigest(text) else { return nil }; return text }
    private static func choice(_ value: Any?, _ choices: [String]) -> String? { guard let text = value as? String, choices.contains(text) else { return nil }; return text }
}
