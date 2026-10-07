import Foundation

@main
struct LocalHealthSmoke {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else { exit(2) }
        let path = CommandLine.arguments[1]
        let mode = CommandLine.arguments[2]
        let credential = Data(repeating: 7, count: 32)

        if mode == "identity-valid" {
            let identity = try LocalHealthClient.fetchControllerIdentity(socketPath: path, credential: credential)
            guard identity.deploymentID == String(repeating: "a", count: 64),
                  identity.ownerID == String(repeating: "b", count: 64),
                  identity.authorityEpoch == 2, identity.revision == 19,
                  identity.principalID == "fixture:reader" else { exit(1) }
            let newer = HomeControllerIdentity(deploymentID: identity.deploymentID, ownerID: identity.ownerID,
                authorityEpoch: identity.authorityEpoch, revision: 20, principalID: identity.principalID)
            guard newer.matchesAuthority(identity), newer != identity else { exit(1) }
            for changed in [
                HomeControllerIdentity(deploymentID: String(repeating: "c", count: 64), ownerID: identity.ownerID,
                    authorityEpoch: 2, revision: 19, principalID: identity.principalID),
                HomeControllerIdentity(deploymentID: identity.deploymentID, ownerID: String(repeating: "c", count: 64),
                    authorityEpoch: 2, revision: 19, principalID: identity.principalID),
                HomeControllerIdentity(deploymentID: identity.deploymentID, ownerID: identity.ownerID,
                    authorityEpoch: 3, revision: 19, principalID: identity.principalID),
                HomeControllerIdentity(deploymentID: identity.deploymentID, ownerID: identity.ownerID,
                    authorityEpoch: 2, revision: 19, principalID: "fixture:replacement"),
            ] { guard !changed.matchesAuthority(identity) else { exit(1) } }
        } else if mode == "identity-invalid" {
            do {
                _ = try LocalHealthClient.fetchControllerIdentity(socketPath: path, credential: credential)
                exit(1)
            } catch LocalHealthError.invalidResponse { return }
        } else if mode == "identity-refused" {
            do {
                _ = try LocalHealthClient.fetchControllerIdentity(socketPath: path, credential: credential)
                exit(1)
            } catch LocalHealthError.server("unauthorized") { return }
        } else if mode == "valid" {
            let health = try LocalHealthClient.fetch(socketPath: path, credential: credential)
            guard health.revision == 12,
                  health.authorityEpoch == 1,
                  health.ruleGeneration == 4,
                  health.heldRequests == 2,
                  health.queuedRequests == 1,
                  health.claimedRequests == 1,
                  health.unknownOutcomes == 1,
                  health.activeThings == 3,
                  health.activePrincipals == 1,
                  health.writable,
                  !health.dispatchEnabled else {
                exit(1)
            }
        } else if mode == "invalid" {
            do {
                _ = try LocalHealthClient.fetch(socketPath: path, credential: credential)
                exit(1)
            } catch LocalHealthError.invalidResponse {
                return
            }
        } else if mode == "slow" {
            let start = DispatchTime.now().uptimeNanoseconds
            do {
                _ = try LocalHealthClient.fetch(socketPath: path, credential: credential)
                exit(1)
            } catch LocalHealthError.transport {
                let elapsed = DispatchTime.now().uptimeNanoseconds - start
                guard elapsed >= 4_000_000_000, elapsed < 7_000_000_000 else { exit(1) }
                return
            }
        } else {
            exit(2)
        }
    }
}
