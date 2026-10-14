import Foundation

@main
struct NativeAuthoringMutationLiveSmoke {
    @MainActor static func main() async throws {
        guard CommandLine.arguments.count == 5, let line = readLine() else { exit(2) }
        let credential = try OperatorCredential.decode(line), socket = CommandLine.arguments[1]
        let root = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true), mode = CommandLine.arguments[3]
        if mode == "panel-submit" || mode == "panel-refused" {
            guard let kind = HomeAuthoringOriginalKind(rawValue: CommandLine.arguments[4]) else { exit(2) }
            let metadata = root.appendingPathComponent("controller", isDirectory: true)
            try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let capture: @Sendable () throws -> LocalCredentialCapture = { LocalCredentialCapture(bytes: credential, nativeReference: nil) }
            let controller = NativeControllerSessionDriver(directory: metadata, local: NativeControllerLocalReadClient(capture: capture, socket: { socket }))
            controller.installLocalFence(); await controller.reload()
            let journal = NativePendingCoordinator(persistence: NativePendingPersistence(directory: root), capture: capture, socketPath: { socket })
            await journal.reload()
            let model = NativeAuthoringViewModel(journal: journal,
                preparer: { try await controller.prepareAuthoring(kind: $0, originalURL: $1, payloadURL: $2) },
                sender: { try await controller.submitAuthoring($0, journal: journal) })
            model.kind = kind; model.originalURL = root.appendingPathComponent("original.json")
            if kind == .import { model.payloadURL = root.appendingPathComponent("payload.bin") }
            guard model.canPrepare, journal.entries.isEmpty else { exit(1) }
            await model.prepare()
            guard !model.details.isEmpty, !model.canSubmit, journal.entries.isEmpty else {
                FileHandle.standardError.write(Data("native authoring preparation failed: \(model.error ?? "missing review")\n".utf8)); exit(1)
            }
            model.confirmed = true; guard model.canSubmit else { exit(1) }
            await model.submit()
            if mode == "panel-refused" {
                guard model.receipt == nil, model.error != nil, journal.entries.isEmpty, journal.canStart, model.status.contains("refused") else {
                    FileHandle.standardError.write(Data("native initial refusal retained: \(model.error ?? "missing error")\n".utf8)); exit(1)
                }
                print("refused"); return
            }
            if model.receipt != nil {
                guard journal.entries.isEmpty && model.error == nil else { exit(1) }; print("resolved"); return
            }
            guard !journal.entries.isEmpty, model.error != nil, !model.busy, model.status.contains("unconfirmed") else { exit(1) }
            print("unconfirmed"); exit(3)
        }
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
