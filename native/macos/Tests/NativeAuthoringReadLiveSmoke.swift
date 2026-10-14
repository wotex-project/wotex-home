import Foundation

@main
struct NativeAuthoringReadLiveSmoke {
    static func main() throws {
        guard CommandLine.arguments.count == 3, let line = readLine() else { exit(2) }
        let credential = try OperatorCredential.decode(line), socket = CommandLine.arguments[1]
        guard let object = try NativeAuthoringReadClient.fetchObject(socketPath: socket, credential: credential, digest: CommandLine.arguments[2]) else { exit(1) }
        var output: [String: Any] = ["object_digest": object.summary.digest, "payload_sha256": LocalHealthClient.profileSHA(object.payload),
            "payload_bytes": object.payload.count, "first_revision": object.firstRevision]
        for kind in [HomeAuthoringOriginalKind.candidate, .review] {
            guard let value = try NativeAuthoringReadClient.fetchOriginal(socketPath: socket, credential: credential, kind: kind, epoch: 1, operation: kind.rawValue + ":1") else { exit(1) }
            var receipt: [String: Any] = ["authority_epoch": value.epoch, "operation_id": value.operation, "revision": value.revision,
                "input_sha256": value.inputSHA!, "basis_sha256": value.basisSHA!, "source_review": value.sourceReview!, "fixture_status": value.fixtureStatus!]
            if kind == .candidate {
                receipt["assessment_sha256"] = value.resultSHA!; receipt["disposition"] = value.disposition!; receipt["capture_status"] = value.captureStatus!
                if let bundle = value.object { receipt["bundle"] = ["kind": bundle.kind, "object_digest": bundle.digest, "payload_sha256": bundle.payloadSHA, "payload_bytes": bundle.size] }
                else { receipt["bundle"] = NSNull() }
            } else {
                receipt["candidate_revision"] = value.candidateRevision!; receipt["result_sha256"] = value.resultSHA!
                receipt["home_consumption"] = value.consumption!; receipt["proposal_status"] = value.proposalStatus!
            }
            output[kind.member] = receipt
        }
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: output))
    }
}
