import Foundation

@main
struct NativeAuthoringReadSessionSmoke {
    @MainActor static func main() async throws {
        guard CommandLine.arguments.count == 3 else { exit(2) }
        let socket = CommandLine.arguments[1], mode = CommandLine.arguments[2]
        let directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("authoring-selection-" + UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = NativeControllerLocalReadClient(capture: { LocalCredentialCapture(bytes: Data(repeating: 7, count: 32), nativeReference: nil) }, socket: { socket })
        let controller = NativeControllerSessionDriver(directory: directory, local: client)
        controller.installLocalFence(); await controller.reload()
        guard controller.localSelected, !controller.busy else { exit(1) }
        do {
            if mode.hasPrefix("contract-") {
                let result: HomeAuthoringContractRead
                if mode == "contract-cancel" {
                    let pending = Task { try await controller.readAuthoringContract() }
                    try await Task.sleep(for: .milliseconds(25))
                    pending.cancel()
                    result = try await pending.value
                } else { result = try await controller.readAuthoringContract() }
                guard mode == "contract-valid", result.epoch == 1, result.revision == 10,
                      result.principal == "author:fixture", !controller.busy else { exit(1) }
                return
            }
            let result = try await controller.readAuthoring(.original(.review, 1, "operation:1"))
            guard !controller.busy else { exit(1) }
            if mode == "missing" { guard case .original(nil) = result else { exit(1) }; return }
            guard mode == "valid" || mode == "old-epoch", case .original(let receipt?) = result,
                  receipt.epoch == 1, receipt.revision == 4 else { exit(1) }
        } catch LocalHealthError.sessionChanged where mode == "contract-cancel" {
            guard !controller.busy else { exit(1) }
        } catch LocalHealthError.nativeGuardConflict where ["owner-changed", "principal-changed", "epoch-changed", "revision-changed", "receipt-future", "contract-owner-changed", "contract-principal-changed", "contract-epoch-changed", "contract-revision-changed", "contract-future", "contract-old", "contract-actor", "contract-epoch"].contains(mode) {
            guard !controller.busy else { exit(1) }
        } catch LocalHealthError.server("permission_denied") where mode == "refused" || mode == "contract-refused" {
            guard !controller.busy else { exit(1) }
        } catch where mode == "lost" || mode == "contract-lost" { guard !controller.busy else { exit(1) } }
    }
}
