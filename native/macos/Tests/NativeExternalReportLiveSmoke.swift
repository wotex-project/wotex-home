import Foundation

@main
struct NativeExternalReportLiveSmoke {
    static func main() throws {
        guard CommandLine.arguments.count == 3, let line = readLine() else { exit(2) }
        let credential = try OperatorCredential.decode(line)
        let catalogue = try LocalHealthClient.fetchReadView(socketPath: CommandLine.arguments[1], credential: credential)
        guard let thing = catalogue.catalogue.things.first(where: { $0.id == "sensor:external" }),
              !thing.powerWritable, thing.externalCapabilityKeys.contains(CommandLine.arguments[2]) else { exit(1) }
        let view = try NativeExternalReportClient.fetch(socketPath: CommandLine.arguments[1], credential: credential,
            target: "sensor:external", key: CommandLine.arguments[2])
        guard let value = view.value, view.freshness == "fresh" else { exit(1) }
        let output: [String: Any] = ["coordinate": value.coordinate, "unit": value.unit,
            "semantic": value.semantic, "consumer": value.consumer, "report_revision": view.reportRevision!,
            "selection_revision": view.selectionRevision, "age_ms": view.ageMilliseconds!, "remaining_ms": view.remainingMilliseconds]
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: output))
    }
}
