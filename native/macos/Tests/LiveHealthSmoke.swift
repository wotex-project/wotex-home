import Foundation

@main
struct LiveHealthSmoke {
    static func main() throws {
        guard CommandLine.arguments.count == 2,
              let encoded = readLine(strippingNewline: true),
              let credential = Data(base64Encoded: encoded
                  .replacingOccurrences(of: "-", with: "+")
                  .replacingOccurrences(of: "_", with: "/") + "="),
              credential.count == 32 else {
            exit(2)
        }

        let health = try LocalHealthClient.fetch(
            socketPath: CommandLine.arguments[1], credential: credential
        )
        guard health.revision >= 1,
              health.authorityEpoch == 1,
              health.activeThings == 0,
              health.activePrincipals == 1,
              health.heldRequests == 0,
              health.writable,
              !health.dispatchEnabled else {
            exit(1)
        }

        let snapshot = try LocalHealthClient.fetchSnapshot(
            socketPath: CommandLine.arguments[1], credential: credential
        )
        guard snapshot.authorityEpoch == health.authorityEpoch,
              snapshot.watermark == health.revision,
              snapshot.observations.isEmpty else {
            exit(1)
        }
    }
}
