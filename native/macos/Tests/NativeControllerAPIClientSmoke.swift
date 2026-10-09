import CryptoKit
import Foundation

private enum ControllerAPIFixtureError: Error { case failed }

@main
struct NativeControllerAPIClientSmoke {
    static func main() async {
        do {
            let header = FileHandle.standardInput.readData(ofLength: 4)
            guard header.count == 4 else { throw ControllerAPIFixtureError.failed }
            let size = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard (1...131_072).contains(size) else { throw ControllerAPIFixtureError.failed }
            let bytes = FileHandle.standardInput.readData(ofLength: Int(size))
            guard bytes.count == Int(size),
                  let input = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  let invitationBody = input["invitation"] as? String,
                  let requestBody = input["request"] as? String,
                  let first = input["earliest"] as? Int64, let last = input["latest"] as? Int64,
                  let expected = input["expected"] as? String else { throw ControllerAPIFixtureError.failed }
            let invitation = try NativeControllerPairingWire.decodeInvitation(Data(invitationBody.utf8))
            let peer = try NativeControllerPeer(invitation: invitation)
            guard Set(Mirror(reflecting: peer).children.compactMap(\.label)) == Set(["controller", "identity", "leafPin", "trustAnchor", "endpoint", "port"]) else {
                throw ControllerAPIFixtureError.failed
            }
            let clock = try NativeControllerCertificateClock(earliest: first, latest: last)
            let diagnostics = NativeControllerTLSDiagnostics()
            let started = ContinuousClock.now
            var actual = ""
            var projection: String?
            do {
                var body = Data(requestBody.utf8)
                var association: NativeControllerAssociation?
                if let bootstrapBody = input["bootstrap"] as? String,
                   let permissions = input["permissions"] as? [String], let targets = input["targets"] as? [String] {
                    let bootstrap = try NativeControllerPairingWire.decodeRequest(Data(bootstrapBody.utf8))
                    let access = NativeControllerAccess(permissions: permissions, targets: targets)
                    let response = try await NativeControllerTLSClient.bootstrap(invitation, request: bootstrap, clock: clock, approvedAccess: access)
                    guard case .paired(let paired) = response, paired.access == access,
                          paired.principal == "paired-controller-v1:\(paired.epoch):\(bootstrap.client)",
                          var original = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                        throw ControllerAPIFixtureError.failed
                    }
                    association = paired
                    original["credential"] = OperatorCredential.encode(paired.credential)
                    body = try JSONSerialization.data(withJSONObject: original)
                }
                let request = try NativeControllerAPIRequest(body: body,
                    allowNotFound: input["allow_not_found"] as? Bool == true)
                guard let original = try JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                      let credential = original["credential"] as? String,
                      !String(reflecting: request).contains(credential),
                      !String(reflecting: peer).contains(OperatorCredential.encode(invitation.bootstrapSecret)) else {
                    throw ControllerAPIFixtureError.failed
                }
                let delayValidation = input["delay_validation"] as? Bool == true
                let task = Task {
                    if delayValidation {
                        return try await NativeControllerTLSClient.request(peer, body: request.body, clock: clock,
                            budget: request.budget, diagnostics: diagnostics) { response in
                            _ = try LocalHealthClient.decodeEnvelope(response, allowNotFound: request.allowNotFound)
                            // Fixture-only deterministic deadline crossing after a
                            // complete, valid reply; production decoding never sleeps.
                            Thread.sleep(forTimeInterval: 0.75)
                            return response
                        }
                    }
                    return try await NativeControllerAPIClient.perform(peer, request: request, clock: clock, diagnostics: diagnostics)
                }
                if input["cancel"] as? Bool == true {
                    if let marker = input["request_marker"] as? String {
                        let expires = ContinuousClock.now.advanced(by: .seconds(5))
                        while !FileManager.default.fileExists(atPath: marker), ContinuousClock.now < expires {
                            try await Task.sleep(for: .milliseconds(10))
                        }
                        guard FileManager.default.fileExists(atPath: marker) else { throw ControllerAPIFixtureError.failed }
                    } else { try await Task.sleep(for: .milliseconds(50)) }
                    task.cancel()
                }
                let response = try await task.value
                if let digest = input["expected_hash"] as? String {
                    guard sha(response) == digest else { throw ControllerAPIFixtureError.failed }
                }
                if let responseBody = input["response"] as? String {
                    let supplied = try JSONSerialization.jsonObject(with: response) as? NSDictionary
                    let expected = try JSONSerialization.jsonObject(with: Data(responseBody.utf8)) as? NSDictionary
                    guard let supplied, let expected, supplied.isEqual(expected) else { throw ControllerAPIFixtureError.failed }
                }
                if input["receipt"] as? Bool == true {
                    let decoded = try LocalHealthClient.decodeEnvelope(response, allowNotFound: false)
                    let mutation = original["mutation"] as? [String: Any] ?? original
                    guard let epoch = LocalHealthClient.profileInteger(mutation["authority_epoch"]),
                          let operation = mutation["operation_id"] as? String,
                          let receipt = decoded["receipt"] as? [String: Any] else { throw ControllerAPIFixtureError.failed }
                    let receiptValue = try LocalHealthClient.decodeReceipt(decoded, authorityEpoch: epoch, operationID: operation)
                    if let association, let socket = input["socket"] as? String {
                        guard association.epoch == epoch, receipt["principal_id"] as? String == association.principal else {
                            throw ControllerAPIFixtureError.failed
                        }
                        let lookup = try LocalHealthClient.fetchReceiptStatus(socketPath: socket, credential: association.credential,
                            authorityEpoch: epoch, operationID: operation)
                        guard case .found(let local) = lookup, local.authorityEpoch == receiptValue.authorityEpoch,
                              local.operationID == receiptValue.operationID, local.disposition == receiptValue.disposition,
                              local.reason == receiptValue.reason, local.revision == receiptValue.revision else {
                            throw ControllerAPIFixtureError.failed
                        }
                        let status = try NativeControllerAPIRequest(credential: association.credential, operation: "status",
                            fields: ["authority_epoch": epoch, "operation_id": operation], allowNotFound: true)
                        let current = try await NativeControllerAPIClient.perform(peer, request: status, clock: clock)
                        let seen = try LocalHealthClient.decodeEnvelope(current, allowNotFound: true)
                        guard let retained = seen["receipt"] as? NSDictionary,
                              retained.isEqual(receipt as NSDictionary) else { throw ControllerAPIFixtureError.failed }
                    }
                    let fields = ["principal_id", "authority_epoch", "operation_id", "disposition", "reason", "revision"]
                    let values = try fields.map { key -> Any in
                        guard let value = receipt[key] else { throw ControllerAPIFixtureError.failed }
                        return value
                    }
                    projection = sha(try JSONSerialization.data(withJSONObject: values, options: .withoutEscapingSlashes))
                }
                actual = "ok"
            } catch let error as NativeControllerTLSError { actual = error.rawValue }
            catch LocalHealthError.server(let reason) {
                guard ["unauthorized", "permission_denied", "outcome_unknown", "invalid_fields", "unsupported_operation"].contains(reason) else {
                    throw ControllerAPIFixtureError.failed
                }
                actual = "server:\(reason)"
            }
            let duration = started.duration(to: .now).components
            let elapsed = duration.seconds * 1000 + duration.attoseconds / 1_000_000_000_000_000
            guard actual == expected, elapsed < 16_500 else {
                let (stage, status) = diagnostics.snapshot()
                FileHandle.standardError.write(Data("controller API expected outcome mismatch: \(actual); stage: \(stage.rawValue); status: \(status.map(String.init) ?? "none")\n".utf8))
                throw ControllerAPIFixtureError.failed
            }
            if input["deadline"] as? Bool == true, elapsed < 4900 { throw ControllerAPIFixtureError.failed }
            if input["review"] as? Bool == true, elapsed < 5800 { throw ControllerAPIFixtureError.failed }
            if let projection { print("native controller API receipt \(projection)") }
            else { print("native controller API case passed") }
        } catch {
            FileHandle.standardError.write(Data("native controller API case failed\n".utf8))
            exit(1)
        }
    }

    private static func sha(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}
