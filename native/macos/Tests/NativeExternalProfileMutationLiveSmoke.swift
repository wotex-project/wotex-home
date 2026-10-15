import Foundation

private enum ExternalLiveFailure: Error { case line(Int) }

@main
struct NativeExternalProfileMutationLiveSmoke {
    @MainActor static func main() async {
        do {
            guard CommandLine.arguments.count == 4, let credentialLine = readLine(), let bytes = Data(base64Encoded: credentialLine), bytes.count == 32,
                  let inputLine = readLine(), let request = try JSONSerialization.jsonObject(with: Data(inputLine.utf8)) as? [String: Any],
                  let kind = HomeExternalProfileOriginalKind(rawValue: request["kind"] as! String), let fields = request["input"] as? [String: Any] else { throw ExternalLiveFailure.line(#line) }
            let socket = CommandLine.arguments[1], root = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true), mode = CommandLine.arguments[3]
            let original = try NativeExternalProfileOriginalWire.encode(fields, kind: kind)
            let coordinator = NativePendingCoordinator(persistence: .init(directory: root), capture: { .init(bytes: bytes, nativeReference: nil) }, socketPath: { socket })
            await coordinator.reload()
            if ["submit", "lost", "stage", "refused", "failed-publication"].contains(mode) {
                let identity = try NativeExternalProfileClient.identity(socketPath: socket, credential: bytes)
                if mode == "failed-publication" {
                    let file = root.appendingPathComponent("native-pending-v1.json")
                    try Data("unsafe".utf8).write(to: file); try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
                    do { _ = try await coordinator.begin(.externalProfile(original), authorityEpoch: Int(original.epoch), expectedController: identity); throw ExternalLiveFailure.line(#line) }
                    catch is ExternalLiveFailure { throw ExternalLiveFailure.line(#line) }
                    catch {}
                    try check(coordinator.needsReload && coordinator.entries.count == 1 && coordinator.entries[0].input == .externalProfile(original))
                    print("external live failed publication retained original"); return
                }
                let pending = try await coordinator.begin(.externalProfile(original), authorityEpoch: Int(original.epoch), expectedController: identity)
                let disk = try NativePendingStorage.load(directory: root)
                try check(disk.document.version == .v9 && disk.document.entries == [pending.entry] && pending.entry.input == .externalProfile(original))
                if mode == "stage" { print("external live staged original"); return }
                do {
                    guard let receipt = try NativeExternalProfileMutationClient.deliver(socketPath: socket, credential: bytes, original: original,
                        expectedController: identity, lookup: false) else { throw ExternalLiveFailure.line(#line) }
                    try NativeExternalProfileMutationClient.verify(receipt, original: original)
                    try check(mode == "submit")
                    try await coordinator.resolving(pending)
                    try check(coordinator.entries.isEmpty && coordinator.snapshot?.document.version == .v9)
                } catch NativeExternalProfileDeliveryError.outcomeUnknown where mode == "lost" {
                    try check(try NativePendingStorage.load(directory: root) == disk && coordinator.entries == [pending.entry])
                } catch LocalHealthError.server(_) where mode == "refused" {
                    try check(try NativePendingStorage.load(directory: root) == disk && coordinator.entries == [pending.entry])
                }
            } else {
                guard let entry = coordinator.entries.first, coordinator.entries.count == 1, entry.input == .externalProfile(original) else { throw ExternalLiveFailure.line(#line) }
                let before = try NativePendingStorage.load(directory: root)
                let action: NativePendingRecoveryAction = mode.hasPrefix("retry") ? .retry : mode == "ack-absent" ? .acknowledgeAbsent : .lookup
                await coordinator.recover(entry, action: action, custody: { _ in bytes }, execute: { entry, credential, path, action in
                    try NativePendingRecoveryOperations.execute(entry, credential: credential, socketPath: path, action: action)
                })
                if mode == "lookup-missing" || mode == "denied" || mode == "retry-lost" {
                    try check(try NativePendingStorage.load(directory: root) == before && coordinator.entries == [entry])
                    try check(mode == "denied" || mode == "retry-lost" ? coordinator.error != nil : coordinator.error == nil)
                } else {
                    try check(coordinator.error == nil && coordinator.entries.isEmpty && coordinator.snapshot?.document.version == .v9 && !coordinator.needsReload)
                    if mode == "ack-absent" { try check(coordinator.status.contains("no operation, cancellation or rollback")) }
                }
            }
            print("external live original workflow passed")
        } catch ExternalLiveFailure.line(let line) {
            FileHandle.standardError.write(Data("external live assertion failed at line \(line)\n".utf8)); exit(1)
        } catch {
            FileHandle.standardError.write(Data("external live workflow failed: \(type(of: error))\n".utf8)); exit(1)
        }
    }
    private static func check(_ value: @autoclosure () throws -> Bool, line: Int = #line) throws {
        guard try value() else { throw ExternalLiveFailure.line(line) }
    }
}
