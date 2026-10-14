import Foundation

@main
struct NativeExternalReportSessionSmoke {
    @MainActor static func main() async throws {
        guard CommandLine.arguments.count == 3 else { exit(2) }
        let socket = CommandLine.arguments[1], mode = CommandLine.arguments[2]
        let directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("report-selection-" + UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = NativeControllerLocalReadClient(capture: { LocalCredentialCapture(bytes: Data(repeating: 7, count: 32), nativeReference: nil) }, socket: { socket })
        let controller = NativeControllerSessionDriver(directory: directory, local: client)
        controller.installLocalFence()
        await controller.reload()
        guard controller.localSelected, !controller.busy else { exit(1) }
        do {
            let value = try await controller.readExternalReport(target: "sensor:external", key: "sample")
            guard mode == "valid", value.value?.coordinate == "2500", !controller.busy else { exit(1) }
        } catch LocalHealthError.nativeGuardConflict where mode == "owner-changed" || mode == "epoch-changed" || mode == "revision-changed" {
            guard !controller.busy else { exit(1) }
        } catch LocalHealthError.server("permission_denied") where mode == "refused" {
            guard !controller.busy else { exit(1) }
        } catch where mode == "lost" {
            guard !controller.busy else { exit(1) }
        }
    }
}
