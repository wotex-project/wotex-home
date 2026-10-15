import Foundation

private enum GenerationSDKAssertion: Error { case failed }

private final class GenerationSDKPeer: NativeDomainTransport, @unchecked Sendable {
    let original: HomeGenerationOriginal, response: [String: Any], mode: String
    private let lock = NSLock()
    private(set) var mutations = 0, reads = 0
    init(original: HomeGenerationOriginal, response: [String: Any], mode: String) {
        self.original = original; self.response = response; self.mode = mode
    }
    func request(body: Data, allowNotFound: Bool) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        try StrictLocalJSON.check(body)
        guard body.count <= 65536, allowNotFound, let request = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              LocalHealthClient.profileInteger(request["api_version"]) == 1,
              request["credential"] as? String == OperatorCredential.encode(Data(repeating: 7, count: 32)),
              let operation = request["operation"] as? String else { throw GenerationSDKAssertion.failed }
        let isSubmit = operation == "authoring_generation_prepare" || operation == "authoring_generation_start"
        let isCancel = operation == "authoring_generation_cancel"
        if isSubmit {
            mutations += 1
            guard Set(request.keys) == Set(["api_version", "operation", "credential", "input"]),
                  let fields = request["input"] as? [String: Any],
                  try NativeGenerationOriginalWire.encode(fields, kind: original.kind) == original,
                  operation == (original.kind == .preparation ? "authoring_generation_prepare" : "authoring_generation_start") else { throw GenerationSDKAssertion.failed }
        } else {
            if isCancel { mutations += 1 } else { reads += 1 }
            guard Set(request.keys) == Set(["api_version", "operation", "credential", "authority_epoch", "operation_id"]),
                  LocalHealthClient.profileInteger(request["authority_epoch"]) == Int(original.epoch),
                  request["operation_id"] as? String == original.operation,
                  operation == (isCancel ? "authoring_generation_cancel" : original.kind == .preparation ? "authoring_generation_status" : "authoring_generation_attempt_status") else { throw GenerationSDKAssertion.failed }
        }
        if isSubmit || isCancel {
            if ["lost_submit", "retry_lost", "lost_cancel"].contains(mode) { throw LocalHealthError.transport }
            if ["malformed_submit", "malformed_cancel"].contains(mode) { return Data("{}".utf8) }
            if ["refused", "refused_cancel", "invalid_reason", "outcome_unknown"].contains(mode) {
                return try json(["api_version": 1, "outcome": "error", "reason": mode == "invalid_reason" ? "private diagnostic\n" : mode == "outcome_unknown" ? "outcome_unknown" : "stale_revision"])
            }
            if ["not_found_submit", "missing_cancel"].contains(mode) { return try missing() }
            if isCancel { return try json(response) }
            let member = original.kind == .preparation ? "authoring_generation_receipt" : "authoring_generation_attempt_receipt"
            var receipt = response[member] as? [String: Any] ?? (response[original.kind == .preparation ? "authoring_generation" : "authoring_generation_attempt"] as! [String: Any])["original"] as! [String: Any]
            if mode == "wrong_receipt" { receipt["revision"] = 999 }
            return try json(["api_version": 1, "outcome": "ok", member: receipt])
        }
        if mode == "missing_lookup" || (mode.hasPrefix("retry_") && reads == 1) { return try missing() }
        if mode == "retry_status_lost" && reads == 2 { throw LocalHealthError.transport }
        return try json(response)
    }
    private func json(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.withoutEscapingSlashes]) }
    private func missing() throws -> Data { try json(["api_version": 1, "outcome": "not_found"]) }
}

@main
struct NativeGenerationSDKSmoke {
    static func main() throws {
        #if !WOH_NATIVE_SDK_WIRE_ONLY
        if CommandLine.arguments.count == 3 && ["--store", "--start-only", "--restart"].contains(CommandLine.arguments[1]) {
            do {
                if CommandLine.arguments[1] == "--restart" { try NativeGenerationStoreSmoke.restart(socket: CommandLine.arguments[2]) }
                else { try NativeGenerationStoreSmoke.run(socket: CommandLine.arguments[2], startOnly: CommandLine.arguments[1] == "--start-only") }
            }
            catch GenerationStoreAssertion.failed(let line) { FileHandle.standardError.write(Data("native generation Store check failed at line \(line)\n".utf8)); exit(1) }
            catch { FileHandle.standardError.write(Data("native generation Store check failed\n".utf8)); exit(1) }
            return
        }
        #endif
        guard CommandLine.arguments.count == 2,
              let cases = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as? [[String: Any]] else { exit(2) }
        for (index, v) in cases.enumerated() {
            guard let encoded = v["bytes"] as? String, let bytes = Data(base64Encoded: encoded),
                  let valid = v["valid"] as? Bool, let mode = v["mode"] as? String else { exit(2) }
            do {
                if mode == "peer" {
                    try peer(v)
                } else if mode == "result" {
                    let value = try NativeGenerationResultWire.decode(bytes)
                    guard try NativeGenerationResultWire.encode(value.fields()) == value else { throw GenerationSDKAssertion.failed }
                } else if mode == "assessment" {
                    let value = try NativeGenerationResultWire.decodeAssessment(bytes)
                    guard try NativeGenerationResultWire.assessment(value.fields()) == value else { throw GenerationSDKAssertion.failed }
                } else {
                    guard bytes.count <= 1_048_576 else { throw LocalHealthError.invalidResponse }
                    try StrictLocalJSON.check(bytes)
                    guard let response = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                          let operation = v["operation"] as? String else { throw LocalHealthError.invalidResponse }
                    let original: HomeGenerationOriginal?
                    if let document = v["original"] as? String, let kind = HomeGenerationOriginalKind(rawValue: v["kind"] as? String ?? "") {
                        original = try NativeGenerationOriginalWire.decode(Data(document.utf8), kind: kind)
                    } else { original = nil }
                    let native = mode == "native_integer" ? nativeIntegers(response) as! [String: Any] : response
                    if mode == "native_integer", let original {
                        guard try NativeGenerationOriginalWire.encode(nativeIntegers(original.fields()) as! [String: Any], kind: original.kind) == original else { throw GenerationSDKAssertion.failed }
                    }
                    let reply = try NativeGenerationClient.decode(native, operation: operation, original: original)
                    if case .options(let value) = reply { _ = try value.fields(); guard !String(reflecting: value).contains("canonical") else { throw GenerationSDKAssertion.failed } }
                    if valid, case .status(let value) = reply, let result = value.result {
                        guard try NativeGenerationResultWire.decode(Data((v["result_document"] as! String).utf8)) == result,
                              !String(reflecting: result).contains("canonical") else { throw GenerationSDKAssertion.failed }
                        if let a = result.assessment {
                            guard try NativeGenerationResultWire.decodeAssessment(Data((v["assessment_document"] as! String).utf8)) == a,
                                  !String(reflecting: a).contains("quoted") else { throw GenerationSDKAssertion.failed }
                        }
                    }
                }
                if !valid { failed(index, "accepted malformed value") }
            } catch { if valid { failed(index, "valid value refused") } }
        }
        print("native generation \(cases.count) SDK codec and original-delivery cases passed")
    }
    private static func peer(_ v: [String: Any]) throws {
        let original = try NativeGenerationOriginalWire.decode(Data((v["original"] as! String).utf8), kind: HomeGenerationOriginalKind(rawValue: v["kind"] as! String)!)
        let mode = v["peer"] as! String, response = v["response"] as! [String: Any]
        let peer = GenerationSDKPeer(original: original, response: response, mode: mode)
        try NativeDomainTransportScope.$current.withValue(peer) {
            if ["lookup", "missing_lookup", "replay", "retry_missing", "retry_lost", "retry_status_lost"].contains(mode) {
                do {
                    let status = try NativeGenerationClient.deliver(socketPath: "", credential: Data(repeating: 7, count: 32), original: original, lookup: mode == "lookup" || mode == "missing_lookup")
                    guard !["retry_lost", "retry_status_lost"].contains(mode), (status == nil) == (mode == "missing_lookup") else { throw GenerationSDKAssertion.failed }
                } catch NativeGenerationDeliveryError.outcomeUnknown {
                    guard ["retry_lost", "retry_status_lost"].contains(mode) else { throw GenerationSDKAssertion.failed }
                }
                guard peer.mutations == (mode.hasPrefix("retry_") ? 1 : 0), peer.reads == (["retry_missing", "retry_status_lost"].contains(mode) ? 2 : 1) else { throw GenerationSDKAssertion.failed }
            } else {
                do {
                    if mode.contains("cancel") || mode == "cancel" {
                        let result = try NativeGenerationClient.cancel(socketPath: "", credential: Data(repeating: 7, count: 32), original: original)
                        guard ["cancel", "missing_cancel"].contains(mode), (result == nil) == (mode == "missing_cancel") else { throw GenerationSDKAssertion.failed }
                    } else {
                        _ = try NativeGenerationClient.submit(socketPath: "", credential: Data(repeating: 7, count: 32), original: original)
                        guard mode == "submit" else { throw GenerationSDKAssertion.failed }
                    }
                } catch NativeGenerationDeliveryError.outcomeUnknown {
                    guard ["lost_submit", "malformed_submit", "wrong_receipt", "invalid_reason", "not_found_submit", "outcome_unknown", "lost_cancel", "malformed_cancel"].contains(mode) else { throw GenerationSDKAssertion.failed }
                } catch LocalHealthError.server(let reason) {
                    guard ["refused", "refused_cancel"].contains(mode), reason == "stale_revision" else { throw GenerationSDKAssertion.failed }
                }
                guard peer.mutations == 1 && peer.reads == 0 else { throw GenerationSDKAssertion.failed }
            }
        }
    }
    private static func nativeIntegers(_ value: Any) -> Any {
        if let fields = value as? [String: Any] { return fields.mapValues(nativeIntegers) }
        if let values = value as? [Any] { return values.map(nativeIntegers) }
        if let number = value as? NSNumber, let integer = LocalHealthClient.profileInteger(number) { return Int64(integer) }
        return value
    }
    private static func failed(_ index: Int, _ reason: String) -> Never {
        FileHandle.standardError.write(Data("native generation SDK case \(index): \(reason)\n".utf8)); exit(1)
    }
}
