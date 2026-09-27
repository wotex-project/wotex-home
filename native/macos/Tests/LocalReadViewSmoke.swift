import Foundation

@main
struct LocalReadViewSmoke {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else { exit(2) }
        let path = CommandLine.arguments[1]
        let mode = CommandLine.arguments[2]
        let credential = Data(repeating: 7, count: 32)

        if mode == "valid" {
            let view = try LocalHealthClient.fetchReadView(socketPath: path, credential: credential)
            guard view.catalogue.watermark == 12,
                  view.catalogue.authorityEpoch == 1,
                  view.catalogue.things.count == 11,
                  view.catalogue.things.first?.id == "light:00",
                  view.catalogue.things.last?.id == "light:10",
                  view.snapshot.watermark == 12,
                  view.snapshot.observations.isEmpty else {
                exit(1)
            }
        } else if mode == "changed" {
            do {
                _ = try LocalHealthClient.fetchReadView(
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
