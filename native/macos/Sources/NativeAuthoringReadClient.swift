import Foundation

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
