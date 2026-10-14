import Foundation

private enum AuthoringMutationAssertion: Error { case failed(Int) }
private final class AuthoringMutationPeer: NativeDomainTransport, @unchecked Sendable {
    let original: HomeAuthoringOriginal, payload: Data?, receipt: [String: Any], mode: String
    private let lock = NSLock()
    private var id: String?, cursor = 0, lost = false, committed = false
    private(set) var commits = 0, chunks = 0, cancellations = 0
    private var bytes: Data { original.kind == .import ? payload! : original.canonical }
    private let owner = String(repeating: "a", count: 32)
    init(original: HomeAuthoringOriginal, payload: Data?, receipt: [String: Any], mode: String) {
        self.original = original; self.payload = payload; self.receipt = receipt; self.mode = mode
    }
    func request(body: Data, allowNotFound: Bool) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard body.count <= 65_536, let request = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              LocalHealthClient.profileInteger(request["api_version"]) == 1,
              request["credential"] as? String == Data(repeating: 7, count: 32).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: ""),
              let operation = request["operation"] as? String else { throw AuthoringMutationAssertion.failed(#line) }
        let fields = request.filter { !["api_version", "operation", "credential"].contains($0.key) }
        let result: [String: Any]
        switch operation {
        case original.kind.operation:
            try require(Set(fields.keys) == Set(["authority_epoch", "operation_id"]) && LocalHealthClient.profileInteger(fields["authority_epoch"]) == Int(original.epoch) && fields["operation_id"] as? String == original.operation)
            result = committed || mode == "replay" ? received() : ["api_version": 1, "outcome": "not_found"]
        case "authoring_upload_begin":
            try require(Set(fields.keys) == Set(["upload"]))
            let upload = fields["upload"] as! [String: Any]
            try require(Set(upload.keys) == Set(["upload_id", "purpose", "payload_bytes", "payload_sha256"]))
            guard let newID = upload["upload_id"] as? String, newID.hasPrefix("upload:"), newID.count == 39,
                  newID.dropFirst(7).utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw AuthoringMutationAssertion.failed(#line) }
            try require(id == nil && upload["purpose"] as? String == (original.kind == .import ? "import_payload" : "review_original") &&
                LocalHealthClient.profileInteger(upload["payload_bytes"]) == bytes.count && upload["payload_sha256"] as? String == LocalHealthClient.profileSHA(bytes))
            id = newID
            if mode == "lost-begin" { throw LocalHealthError.transport }
            result = uploadReply()
        case "authoring_upload_status":
            try require(Set(fields.keys) == Set(["upload_id"]) && fields["upload_id"] as? String == id)
            result = uploadReply(changedOwner: mode == "changed-owner")
        case "authoring_upload_chunk":
            chunks += 1
            try require(Set(fields.keys) == Set(["upload_ref", "offset", "chunk_base64"]))
            try reference(fields["upload_ref"])
            guard let offset = LocalHealthClient.profileInteger(fields["offset"]), let encoded = fields["chunk_base64"] as? String else { throw AuthoringMutationAssertion.failed(#line) }
            let chunk = try NativePendingAuthoring.decodeBase64(encoded)
            try require(offset == cursor && chunk == bytes.subdata(in: cursor..<min(cursor + 32_768, bytes.count)))
            if !lost && mode == "lost-before" { lost = true; throw LocalHealthError.transport }
            if mode == "stale-success" { return try encodedJSON(uploadReply()) }
            cursor += chunk.count
            if !lost && ["lost-after", "changed-owner"].contains(mode) { lost = true; throw LocalHealthError.transport }
            result = uploadReply()
        case "authoring_upload_cancel":
            try require(Set(fields.keys) == Set(["upload_ref"])); try reference(fields["upload_ref"])
            cancellations += 1
            if mode == "cleanup-failed" { throw LocalHealthError.transport }
            result = uploadReply()
        case "authoring_object_import", "authoring_candidate_review", "authoring_candidate_assess":
            if original.kind == .candidate {
                try require(operation == "authoring_candidate_assess" && Set(fields.keys) == Set(["input"]))
                try require(NSDictionary(dictionary: fields["input"] as! [String: Any]).isEqual(to: original.fields()))
            } else {
                let refKey = original.kind == .import ? "upload_ref" : "input_ref"
                if original.kind == .import {
                    try require(operation == "authoring_object_import" && Set(fields.keys) == Set(["input", refKey]))
                    try require(NSDictionary(dictionary: fields["input"] as! [String: Any]).isEqual(to: original.fields()))
                } else {
                    try require(operation == "authoring_candidate_review" && Set(fields.keys) == Set(["authority_epoch", "operation_id", "input_sha256", refKey]))
                    try require(LocalHealthClient.profileInteger(fields["authority_epoch"]) == Int(original.epoch) && fields["operation_id"] as? String == original.operation && fields["input_sha256"] as? String == original.sha)
                }
                if fields[refKey] is NSNull {
                    if mode == "replay" { return try encodedJSON(received()) }
                    return try encodedJSON(["api_version": 1, "outcome": "error", "reason": "authoring_upload_required"])
                }
                try reference(fields[refKey]); try require(cursor == bytes.count)
            }
            try require(!committed); committed = true; commits += 1
            if mode == "lost-final" { throw LocalHealthError.transport }
            if mode == "malformed-final" { return Data("{}".utf8) }
            if mode == "refused-final" { return try encodedJSON(["api_version": 1, "outcome": "error", "reason": "stale_revision"]) }
            if mode == "wrong-receipt" { var changed = receipt; changed["revision"] = 999; return try encodedJSON(["api_version": 1, "outcome": "ok", original.kind.member: changed]) }
            result = received()
        default: throw AuthoringMutationAssertion.failed(#line)
        }
        return try encodedJSON(result)
    }
    private func received() -> [String: Any] { ["api_version": 1, "outcome": "ok", original.kind.member: receipt] }
    private func uploadReply(changedOwner: Bool = false) -> [String: Any] {
        ["api_version": 1, "outcome": "ok", "authoring_upload": ["format": "home-authoring-upload-v1", "owner_epoch": changedOwner ? String(repeating: "b", count: 32) : owner,
            "upload_id": id!, "purpose": original.kind == .import ? "import_payload" : "review_original", "payload_bytes": bytes.count, "payload_sha256": LocalHealthClient.profileSHA(bytes),
            "next_offset": cursor, "state": cursor == bytes.count ? "ready" : "uploading", "remaining_ms": 59_000]]
    }
    private func reference(_ raw: Any?) throws {
        guard let ref = raw as? [String: Any] else { throw AuthoringMutationAssertion.failed(#line) }
        try require(Set(ref.keys) == Set(["owner_epoch", "upload_id"]) && ref["owner_epoch"] as? String == owner && ref["upload_id"] as? String == id)
    }
    private func require(_ value: Bool, line: Int = #line) throws { guard value else { throw AuthoringMutationAssertion.failed(line) } }
    private func encodedJSON(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
}

@main
struct NativeAuthoringMutationSmoke {
    static func main() throws {
        guard CommandLine.arguments.count == 2,
              let cases = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as? [[String: Any]] else { exit(2) }
        for entry in cases {
            let kind = HomeAuthoringOriginalKind(rawValue: entry["kind"] as! String)!, mode = entry["mode"] as! String
            let original = try NativeAuthoringOriginalWire.decode(Data(base64Encoded: entry["canonical"] as! String)!, kind: kind)
            let payload = (entry["payload"] as? String).flatMap { Data(base64Encoded: $0) }
            let peer = AuthoringMutationPeer(original: original, payload: payload, receipt: entry["receipt"] as! [String: Any], mode: mode)
            try NativeDomainTransportScope.$current.withValue(peer) {
                do {
                    let result = try NativeAuthoringMutationClient.deliver(socketPath: "", credential: Data(repeating: 7, count: 32), original: original, payload: payload, lookup: mode == "missing")
                    if mode == "missing" { guard result == nil && peer.commits == 0 else { throw AuthoringMutationAssertion.failed(#line) }; return }
                    guard ["valid", "lost-begin", "lost-before", "lost-after", "cleanup-failed", "replay"].contains(mode), result != nil,
                          peer.commits == (mode == "replay" ? 0 : 1) else { throw AuthoringMutationAssertion.failed(#line) }
                } catch NativeAuthoringDeliveryError.outcomeUnknown {
                    guard ["lost-final", "malformed-final", "wrong-receipt"].contains(mode), peer.commits == 1, peer.cancellations == 0 else { throw AuthoringMutationAssertion.failed(#line) }
                    let result = try NativeAuthoringMutationClient.deliver(socketPath: "", credential: Data(repeating: 7, count: 32), original: original, payload: payload, lookup: true)
                    guard result != nil && peer.commits == 1 else { throw AuthoringMutationAssertion.failed(#line) }
                } catch LocalHealthError.server("stale_revision") where mode == "refused-final" { guard peer.cancellations == (kind == .candidate ? 0 : 1) else { throw AuthoringMutationAssertion.failed(#line) } }
                catch LocalHealthError.invalidResponse where mode == "stale-success" || mode == "changed-owner" {
                    guard peer.commits == 0, peer.chunks == 1 else { throw AuthoringMutationAssertion.failed(#line) }
                }
            }
        }
        print("native authoring \(cases.count) mutation transfer and original-recovery peer cases passed")
    }
}
