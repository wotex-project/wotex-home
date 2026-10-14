import Foundation

@main
struct NativeAuthoringMutationLiveSmoke {
    static func main() throws {
        guard CommandLine.arguments.count == 5, let line = readLine() else { exit(2) }
        let credential = try OperatorCredential.decode(line), socket = CommandLine.arguments[1]
        let root = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true), mode = CommandLine.arguments[3]
        var snapshot = try NativePendingStorage.load(directory: root)
        let entry: NativePendingEntry
        if mode == "submit" || mode == "capture" {
            guard snapshot.document.entries.isEmpty, let kind = HomeAuthoringOriginalKind(rawValue: CommandLine.arguments[4]) else { exit(2) }
            let original = try NativeAuthoringOriginalWire.nativeJSON(Data(contentsOf: root.appendingPathComponent("original.json")), kind: kind)
            let payload = kind == .import ? try Data(contentsOf: root.appendingPathComponent("payload.bin")) : nil
            let identity = try LocalHealthClient.fetchControllerIdentity(socketPath: socket, credential: credential)
            entry = NativePendingEntry(context: NativePendingContext(deployment: identity.deploymentID, owner: identity.ownerID,
                epoch: Int64(identity.authorityEpoch), principal: identity.principalID), custody: .manual(verifier: LocalHealthClient.profileSHA(credential)),
                input: .authoring(original, payload), phase: .pending)
            snapshot = try NativePendingStorage.retaining(entry, directory: root, expected: snapshot)
            if mode == "capture" { print("retained"); return }
        } else {
            guard snapshot.document.entries.count == 1 else { exit(2) }; entry = snapshot.document.entries[0]
        }
        do {
            let result = try NativePendingRecoveryOperations.execute(entry, credential: credential, socketPath: socket,
                action: mode == "lookup" ? .lookup : .retry)
            switch result {
            case .resolved:
                snapshot = try NativePendingStorage.resolving(entry, directory: root, expected: snapshot)
                guard snapshot.document.entries.isEmpty && snapshot.document.version == .v6 else { exit(1) }
                print("resolved")
            case .retained: print("retained")
            case .review: exit(1)
            }
        } catch NativeAuthoringDeliveryError.outcomeUnknown {
            guard try NativePendingStorage.load(directory: root) == snapshot else { exit(1) }; print("unconfirmed"); exit(3)
        }
    }
}
