import Foundation

// Exact ordinary request bytes survive transport/cancellation unchanged.
// This record contains a bearer and must not enter files or diagnostics.
struct NativeControllerAPIRequest: Sendable, CustomReflectable {
    let body: Data
    let operation: String
    let allowNotFound: Bool
    var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
    var budget: NativeControllerRequestBudget {
        ["review_rules", "record_rule_review", "admit_rule", "schedule_review", "schedule_admit",
         "schedule_activate", "schedule_suspend"].contains(operation) ? .review : .ordinary
    }

    init(credential: Data, operation: String, fields: [String: Any] = [:], allowNotFound: Bool = false) throws {
        try self.init(body: LocalHealthClient.requestBody(credential: credential, operation: operation, fields: fields),
            allowNotFound: allowNotFound)
    }

    init(body: Data, allowNotFound: Bool = false) throws {
        guard (1...65_536).contains(body.count) else { throw NativeControllerTLSError.invalidRecord }
        do {
            try StrictLocalJSON.check(body)
            guard let request = try JSONSerialization.jsonObject(with: body) as? [String: Any],
                  LocalHealthClient.profileInteger(request["api_version"]) == 1,
                  let operation = request["operation"] as? String, LocalHealthClient.profileID(operation),
                  let credential = request["credential"] as? String else { throw NativeControllerTLSError.invalidRecord }
            _ = try OperatorCredential.decode(credential)
            self.body = body; self.operation = operation; self.allowNotFound = allowNotFound
        } catch { throw NativeControllerTLSError.invalidRecord }
    }
}

enum NativeControllerAPIClient {
    private enum Response: Sendable { case body(Data), refusal(String) }
    // Shared native envelope decoding retains exact server refusals. Broken
    // replies after a possible send remain unknown; this method never retries.
    static func perform(_ peer: NativeControllerPeer, request: NativeControllerAPIRequest,
                        clock: NativeControllerCertificateClock,
                        diagnostics: NativeControllerTLSDiagnostics? = nil) async throws -> Data {
        let allowNotFound = request.allowNotFound // Capture only public decoding policy, never the bearer-bearing request.
        let response: Response = try await NativeControllerTLSClient.request(peer, body: request.body,
            clock: clock, budget: request.budget, diagnostics: diagnostics) { bytes in
            do {
                _ = try LocalHealthClient.decodeEnvelope(bytes, allowNotFound: allowNotFound)
                return .body(bytes)
            } catch LocalHealthError.server(let reason) { return .refusal(reason) }
            catch { throw NativeControllerTLSError.outcomeUnknown }
        }
        switch response {
        case .body(let bytes): return bytes
        case .refusal(let reason): throw LocalHealthError.server(reason)
        }
    }
}
