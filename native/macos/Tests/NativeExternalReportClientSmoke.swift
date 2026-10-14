import Foundation

@main
struct NativeExternalReportClientSmoke {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else { exit(2) }
        let mode = CommandLine.arguments[2], key = mode.contains("multi") ? "density" : mode == "valid-alias" ? "temperature" : "sample"
        do {
            if mode.hasPrefix("catalogue") {
                let view = try LocalHealthClient.fetchReadView(socketPath: CommandLine.arguments[1], credential: Data(repeating: 7, count: 32))
                guard !mode.contains("invalid"), view.catalogue.things.count == 1, let thing = view.catalogue.things.first,
                      thing.role == "EnvironmentalSensor", !thing.powerWritable, !thing.externalCapabilityKeys.isEmpty,
                      thing.externalCapabilityKeys.count == thing.capabilityCount, view.snapshot.observations.isEmpty else { exit(1) }
                return
            }
            let view = try NativeExternalReportClient.fetch(socketPath: CommandLine.arguments[1], credential: Data(repeating: 7, count: 32), target: "sensor:external", key: key)
            guard !mode.hasPrefix("invalid"), mode != "lost", mode != "refused", view.target == "sensor:external", view.key == key else { exit(1) }
            if mode.hasPrefix("valid") {
                guard view.freshness == "fresh", view.value != nil, view.displayedValue(elapsedMilliseconds: 0) != nil,
                      view.displayedValue(elapsedMilliseconds: 999) != nil, view.displayedValue(elapsedMilliseconds: 1000) == nil,
                      view.displayedValue(elapsedMilliseconds: -1) == nil else { exit(1) }
                if mode == "valid-bool" { guard view.value?.coordinate == "false" else { exit(1) } }
                else if mode == "valid-external" { guard view.value?.coordinate.contains("2500") == true else { exit(1) } }
                else { guard view.value?.coordinate == "2500", view.value?.unit.contains("scale_n") == true else { exit(1) } }
            } else {
                guard view.value == nil, view.remainingMilliseconds == 0, view.displayedValue(elapsedMilliseconds: 0) == nil else { exit(1) }
            }
        } catch LocalHealthError.invalidResponse where mode.contains("invalid") { return }
        catch LocalHealthError.server("permission_denied") where mode == "refused" { return }
        catch where mode == "lost" { return }
    }
}
