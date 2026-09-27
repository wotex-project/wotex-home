import Foundation

@main
struct LocalEnrollmentSmoke {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else { exit(2) }
        let path = CommandLine.arguments[1]
        let mode = CommandLine.arguments[2]
        let credential = Data(repeating: 7, count: 32)

        if mode == "invalid-input" {
            do {
                _ = try LocalHealthClient.fetchEnrollmentStatus(
                    socketPath: path, credential: credential, reviewRef: "bad id"
                )
                exit(1)
            } catch LocalHealthError.invalidEnrollmentRequest {
                return
            }
        }

        do {
            let result = try LocalHealthClient.fetchEnrollmentStatus(
                socketPath: path, credential: credential, reviewRef: "review:1"
            )
            switch (mode, result) {
            case ("current", .found(let review)):
                guard review.reviewRef == "review:1", review.thingID == "light:desk",
                      review.state == "current", review.reviewRevision == 3,
                      review.bindingRevision == 3, review.digestVersion == 2 else { exit(1) }
            case ("superseded", .found(let review)):
                guard review.state == "superseded", review.bindingRevision == 5 else { exit(1) }
            case ("not-found", .notFound):
                return
            default:
                exit(1)
            }
        } catch LocalHealthError.invalidResponse where mode.hasPrefix("invalid-") {
            return
        }
    }
}
