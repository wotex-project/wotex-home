import Foundation

@main
struct LocalSnapshotSmoke {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else { exit(2) }
        let path = CommandLine.arguments[1]
        let mode = CommandLine.arguments[2]
        let credential = Data(repeating: 7, count: 32)

        if mode == "valid" {
            let snapshot = try LocalHealthClient.fetchSnapshot(
                socketPath: path, credential: credential
            )
            guard snapshot.authorityEpoch == 1,
                  snapshot.watermark == 12,
                  snapshot.observations.count == 2,
                  snapshot.observations[0].valueText == "On",
                  snapshot.observations[1].valueText == "40.0%" else {
                exit(1)
            }
        } else if mode == "changed" {
            do {
                _ = try LocalHealthClient.fetchSnapshot(
                    socketPath: path, credential: credential
                )
                exit(1)
            } catch LocalHealthError.server(let reason) where reason == "resnapshot_required" {
                return
            }
        } else {
            exit(2)
        }
    }
}
