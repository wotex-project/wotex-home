import Foundation

enum NativeAuthoringDeliveryError: LocalizedError {
    case outcomeUnknown
    var errorDescription: String? { "Authoring delivery is unconfirmed. Look up the retained original before retrying." }
}

enum NativeAuthoringMutationClient {
    static func deliver(socketPath: String, credential: Data, original: HomeAuthoringOriginal,
                        payload: Data?, lookup: Bool) throws -> HomeAuthoringOriginalRead? {
        _ = try NativePendingAuthoring.checked(original, payload: payload)
        guard credential.count == 32 else { throw LocalHealthError.invalidCredential }
        if lookup {
            let result = try NativeAuthoringReadClient.fetchOriginal(socketPath: socketPath, credential: credential,
                kind: original.kind, epoch: original.epoch, operation: original.operation)
            if let result { try verify(result, original: original) }; return result
        }
        let input = try original.fields()
        if original.kind == .candidate {
            return try final(socketPath, credential, original: original, operation: "authoring_candidate_assess", fields: ["input": input], ref: nil)
        }
        let operation = original.kind == .import ? "authoring_object_import" : "authoring_candidate_review"
        let refField = original.kind == .import ? "upload_ref" : "input_ref"
        var fields: [String: Any] = original.kind == .import ? ["input": input, "upload_ref": NSNull()] :
            ["authority_epoch": original.epoch, "operation_id": original.operation, "input_sha256": original.sha, "input_ref": NSNull()]
        do {
            let response = try LocalHealthClient.authoringMutationTransport(socketPath: socketPath, credential: credential, operation: operation, fields: fields)
            guard let result = try NativeAuthoringReadClient.decodeOriginal(response, kind: original.kind, epoch: original.epoch, operation: original.operation) else { throw LocalHealthError.invalidResponse }
            try verify(result, original: original); return result
        } catch LocalHealthError.server("authoring_upload_required") {
            let bytes = original.kind == .import ? payload! : original.canonical
            let ref = try upload(socketPath, credential, bytes: bytes, purpose: original.kind == .import ? "import_payload" : "review_original")
            fields[refField] = ref
            return try final(socketPath, credential, original: original, operation: operation, fields: fields, ref: ref)
        }
    }

    static func verify(_ result: HomeAuthoringOriginalRead, original: HomeAuthoringOriginal) throws {
        let fields = try original.fields()
        guard result.kind == original.kind, result.epoch == original.epoch, result.operation == original.operation,
              original.expectedRevision < Int64.max, result.revision == original.expectedRevision + 1 else { throw LocalHealthError.invalidResponse }
        if original.kind == .import {
            guard let raw = fields["object"] as? [String: Any], let object = result.object,
                  object.kind == raw["kind"] as? String, object.digest == raw["object_digest"] as? String,
                  object.payloadSHA == raw["payload_sha256"] as? String,
                  object.size == LocalHealthClient.profileInteger(raw["payload_bytes"]) else { throw LocalHealthError.invalidResponse }
        } else {
            guard result.inputSHA == original.sha else { throw LocalHealthError.invalidResponse }
            if original.kind == .review {
                guard let review = fields["review"] as? [String: Any], let candidate = review["candidate_ref"] as? [String: Any],
                      result.candidateRevision == LocalHealthClient.profileInteger(candidate["revision"]).map(Int64.init) else { throw LocalHealthError.invalidResponse }
            }
        }
    }

    private static func final(_ socket: String, _ credential: Data, original: HomeAuthoringOriginal,
                              operation: String, fields: [String: Any], ref: [String: Any]?) throws -> HomeAuthoringOriginalRead {
        do {
            let response = try LocalHealthClient.authoringMutationTransport(socketPath: socket, credential: credential, operation: operation, fields: fields)
            guard let result = try NativeAuthoringReadClient.decodeOriginal(response, kind: original.kind, epoch: original.epoch, operation: original.operation) else { throw LocalHealthError.invalidResponse }
            try verify(result, original: original)
            cleanup(socket, credential, ref: ref); return result
        } catch LocalHealthError.server(let reason) {
            if reason == "outcome_unknown" { throw NativeAuthoringDeliveryError.outcomeUnknown }
            cleanup(socket, credential, ref: ref); throw LocalHealthError.server(reason)
        } catch { throw NativeAuthoringDeliveryError.outcomeUnknown }
    }

    private static func upload(_ socket: String, _ credential: Data, bytes: Data, purpose: String) throws -> [String: Any] {
        let id = "upload:" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let input: [String: Any] = ["upload_id": id, "purpose": purpose, "payload_bytes": bytes.count, "payload_sha256": LocalHealthClient.profileSHA(bytes)]
        let first: [String: Any]
        do { first = try LocalHealthClient.authoringMutationTransport(socketPath: socket, credential: credential, operation: "authoring_upload_begin", fields: ["upload": input]) }
        catch LocalHealthError.server(let reason) { throw LocalHealthError.server(reason) }
        catch { first = try LocalHealthClient.authoringMutationTransport(socketPath: socket, credential: credential, operation: "authoring_upload_status", fields: ["upload_id": id]) }
        let status = try uploadStatus(first, input: input)
        guard status["state"] as? String == "uploading", LocalHealthClient.profileInteger(status["next_offset"]) == 0,
              let owner = status["owner_epoch"] as? String else { throw LocalHealthError.invalidResponse }
        let ref: [String: Any] = ["owner_epoch": owner, "upload_id": id]
        for offset in stride(from: 0, to: bytes.count, by: 32_768) {
            let chunk = bytes.subdata(in: offset..<min(offset + 32_768, bytes.count))
            let fields: [String: Any] = ["upload_ref": ref, "offset": offset, "chunk_base64": NativePendingAuthoring.base64(chunk)]
            var response: [String: Any]
            var recovered = false
            do { response = try LocalHealthClient.authoringMutationTransport(socketPath: socket, credential: credential, operation: "authoring_upload_chunk", fields: fields) }
            catch LocalHealthError.server(let reason) { throw LocalHealthError.server(reason) }
            catch { recovered = true; response = try LocalHealthClient.authoringMutationTransport(socketPath: socket, credential: credential, operation: "authoring_upload_status", fields: ["upload_id": id]) }
            var current = try uploadStatus(response, input: input)
            guard current["owner_epoch"] as? String == owner else { throw LocalHealthError.invalidResponse }
            if recovered, current["state"] as? String == "uploading", LocalHealthClient.profileInteger(current["next_offset"]) == offset {
                response = try LocalHealthClient.authoringMutationTransport(socketPath: socket, credential: credential, operation: "authoring_upload_chunk", fields: fields)
                current = try uploadStatus(response, input: input)
            }
            guard current["owner_epoch"] as? String == owner,
                  LocalHealthClient.profileInteger(current["next_offset"]) == offset + chunk.count,
                  current["state"] as? String == (offset + chunk.count == bytes.count ? "ready" : "uploading") else { throw LocalHealthError.invalidResponse }
        }
        return ref
    }
    private static func uploadStatus(_ response: [String: Any], input: [String: Any]) throws -> [String: Any] {
        guard Set(response.keys) == Set(["api_version", "outcome", "authoring_upload"]), LocalHealthClient.profileInteger(response["api_version"]) == 1,
              response["outcome"] as? String == "ok", let raw = response["authoring_upload"] as? [String: Any],
              Set(raw.keys) == Set(["format", "owner_epoch", "upload_id", "purpose", "payload_bytes", "payload_sha256", "next_offset", "state", "remaining_ms"]),
              raw["format"] as? String == "home-authoring-upload-v1", raw["upload_id"] as? String == input["upload_id"] as? String,
              raw["purpose"] as? String == input["purpose"] as? String, raw["payload_sha256"] as? String == input["payload_sha256"] as? String,
              let size = LocalHealthClient.profileInteger(raw["payload_bytes"]), size == input["payload_bytes"] as? Int,
              let offset = LocalHealthClient.profileInteger(raw["next_offset"]), (0...size).contains(offset),
              let remaining = LocalHealthClient.profileInteger(raw["remaining_ms"]), (0...60_000).contains(remaining),
              let owner = raw["owner_epoch"] as? String, owner.utf8.count == 32, owner.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              let state = raw["state"] as? String, ["uploading", "ready", "checked_out", "consumed", "cancelled", "expired", "invalid"].contains(state) else { throw LocalHealthError.invalidResponse }
        return raw
    }
    private static func cleanup(_ socket: String, _ credential: Data, ref: [String: Any]?) {
        guard let ref else { return }
        _ = try? LocalHealthClient.authoringMutationTransport(socketPath: socket, credential: credential, operation: "authoring_upload_cancel", fields: ["upload_ref": ref])
    }
}
