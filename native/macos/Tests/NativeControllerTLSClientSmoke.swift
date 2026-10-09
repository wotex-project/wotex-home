import Foundation

private enum ControllerTLSFixtureError: Error { case failed }

@main
struct NativeControllerTLSClientSmoke {
    static func main() async {
        do {
            try await checkClock()
            let header = FileHandle.standardInput.readData(ofLength: 4)
            guard header.count == 4 else { throw ControllerTLSFixtureError.failed }
            let size = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard (1...32_768).contains(size) else { throw ControllerTLSFixtureError.failed }
            let bytes = FileHandle.standardInput.readData(ofLength: Int(size))
            guard bytes.count == Int(size),
                  let input = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  let invitationBody = input["invitation"] as? String,
                  let requestBody = input["request"] as? String,
                  let first = input["earliest"] as? Int64, let last = input["latest"] as? Int64,
                  let expected = input["expected"] as? String else { throw ControllerTLSFixtureError.failed }
            let invitation = try NativeControllerPairingWire.decodeInvitation(Data(invitationBody.utf8))
            let request = try NativeControllerPairingWire.decodeRequest(Data(requestBody.utf8))
            let clock = try NativeControllerCertificateClock(earliest: first, latest: last)
            let diagnostics = NativeControllerTLSDiagnostics()
            let started = DispatchTime.now().uptimeNanoseconds
            var actual = ""
            do {
                let task = Task { try await NativeControllerTLSClient.bootstrap(invitation, request: request, clock: clock, diagnostics: diagnostics) }
                if input["cancel"] as? Bool == true {
                    try await Task.sleep(for: .milliseconds(50))
                    task.cancel()
                }
                let response = try await task.value
                switch response {
                case .paired(let association):
                    guard association.access == .initial,
                          association.credential != request.bootstrapSecret else { throw ControllerTLSFixtureError.failed }
                    if let scope = input["pairing_scope"] as? [String: Any],
                       let deployment = scope["deployment_id"] as? String,
                       let owner = scope["owner_id"] as? String,
                       let epoch = scope["authority_epoch"] as? Int64,
                       let originalRevision = scope["expected_revision"] as? Int64 {
                        guard association.deployment == deployment, association.owner == owner,
                              association.epoch == epoch, association.revision == originalRevision + 1,
                              association.principal == "paired-controller-v1:\(epoch):\(request.client)",
                              association.credential.count == 32,
                              association.credential != Data(repeating: 8, count: 32) else { throw ControllerTLSFixtureError.failed }
                    } else {
                        guard association.principal == "paired-client",
                              association.credential == Data(repeating: 8, count: 32) else { throw ControllerTLSFixtureError.failed }
                    }
                    actual = "paired"
                case .refused(_, let reason):
                    guard reason == (input["expected_refusal"] as? String ?? "confirmation_denied") else { throw ControllerTLSFixtureError.failed }
                    actual = "refused"
                }
            } catch let error as NativeControllerTLSError { actual = error.rawValue }
            let elapsed = (DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            guard actual == expected, elapsed < 6500 else {
                let (stage, status) = diagnostics.snapshot()
                FileHandle.standardError.write(Data("controller TLS expected outcome mismatch: \(actual); stage: \(stage.rawValue); status: \(status.map(String.init) ?? "none")\n".utf8))
                throw ControllerTLSFixtureError.failed
            }
            let (stage, _) = diagnostics.snapshot()
            if expected == "paired" || expected == "refused", stage != .application { throw ControllerTLSFixtureError.failed }
            if ["wrong_name", "common_name_only", "uri_name_only", "wrong_purpose", "expired", "future", "unknown_critical", "unknown_ca", "corrupt"].contains(input["variant"] as? String ?? ""),
               stage != .trustEvaluation { throw ControllerTLSFixtureError.failed }
            if input["deadline"] as? Bool == true, elapsed < 4900 { throw ControllerTLSFixtureError.failed }
            print("native controller TLS case passed")
        } catch {
            FileHandle.standardError.write(Data("native controller TLS case failed\n".utf8))
            exit(1)
        }
    }

    private static func checkClock() async throws {
        for (first, last, lease) in [(Int64(-1), Int64(0), Int64(1)), (2, 1, 1), (0, 1, 0),
                                    (0, 1, 15_001), (0, 253_402_300_799_001, 1)] {
            do {
                _ = try NativeControllerCertificateClock(earliest: first, latest: last, leaseMilliseconds: lease)
                throw ControllerTLSFixtureError.failed
            } catch NativeControllerTLSError.tlsClockUncertain { }
        }
        let clock = try NativeControllerCertificateClock(earliest: 1000, latest: 2000)
        let (first, last) = try clock.bounds()
        guard first.timeIntervalSince1970 >= 1, last.timeIntervalSince(first) == 1 else { throw ControllerTLSFixtureError.failed }
        let expired = try NativeControllerCertificateClock(earliest: 1000, latest: 1000, leaseMilliseconds: 1)
        try await Task.sleep(for: .milliseconds(5))
        do { _ = try expired.bounds(); throw ControllerTLSFixtureError.failed }
        catch NativeControllerTLSError.tlsClockUncertain { }
    }
}
