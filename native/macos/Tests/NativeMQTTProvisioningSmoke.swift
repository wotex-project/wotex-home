import Darwin
import Foundation

private enum ProvisionSmokeError: Error { case failed }

@main
struct NativeMQTTProvisioningSmoke {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else { throw ProvisionSmokeError.failed }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let mode = CommandLine.arguments[2]
        if mode == "actual" {
            try wire(); try files(directory); try unsigned(directory); try actual(directory)
        } else { try adversarial(directory, mode: mode) }
        print("native MQTT foreground \(mode) passed")
    }

    private static func wire() throws {
        let vectors = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "test/fixtures/mqtt/native-provision.json"))) as! [String: Any]
        let a = URL(fileURLWithPath: "/private/fixture/authoring.json"), s = URL(fileURLWithPath: "/private/fixture/mqtt.json")
        let prepared = try NativeMQTTProvisionWire.reply(Data((vectors["prepared"] as! String).utf8), kind: "prepared")
        try check(try NativeMQTTProvisionWire.prepare(authoring: a, source: s) == Data((vectors["prepare"] as! String).utf8))
        try check(try NativeMQTTProvisionWire.publish(authoring: a, source: s, original: prepared) == Data((vectors["publish"] as! String).utf8))
        try check(try NativeMQTTProvisionWire.reply(Data((vectors["published"] as! String).utf8), kind: "published", original: prepared) == prepared)
        try check(try NativeMQTTProvisionWire.refusal(Data((vectors["conflict"] as! String).utf8)) == .conflict)
        let body = vectors["prepared"] as! String
        for bad in [body + "\n", body.replacingOccurrences(of: ",", with: ", "),
            body.replacingOccurrences(of: ",1,", with: ",true,"), body.replacingOccurrences(of: ",1,", with: ",1.0,"),
            body.replacingOccurrences(of: "\"keychain\"", with: "[]"), body.replacingOccurrences(of: "\"keychain\"", with: "\"other\""),
            body.replacingOccurrences(of: String(repeating: "a", count: 64), with: "bad"), String(repeating: "[", count: 4097)] {
            try rejected { _ = try NativeMQTTProvisionWire.reply(Data(bad.utf8), kind: "prepared") }
        }
        try rejected { _ = try NativeMQTTProvisionWire.reply(Data(body.utf8), kind: "published", original: prepared) }
    }

    private static func files(_ directory: URL) throws {
        let url = directory.appendingPathComponent("private-input.json")
        try Data("fixture".utf8).write(to: url)
        try check(chmod(url.path, 0o400) == 0)
        try check(try NativeAuthoringFiles.readImmutable(url, maximum: 8192) == Data("fixture".utf8))
        try check(chmod(url.path, 0o600) == 0)
        try rejected { _ = try NativeAuthoringFiles.readImmutable(url, maximum: 8192) }
        try check(try NativeAuthoringFiles.read(url, maximum: 8192) == Data("fixture".utf8))
        try check(chmod(url.path, 0o400) == 0)
        let second = url.appendingPathExtension("link")
        try check(link(url.path, second.path) == 0)
        try rejected { _ = try NativeAuthoringFiles.readImmutable(url, maximum: 8192) }
        try check(unlink(second.path) == 0)
        try check(chmod(directory.path, 0o755) == 0)
        try rejected { _ = try NativeAuthoringFiles.readImmutable(url, maximum: 8192) }
        try check(chmod(directory.path, 0o700) == 0)
    }

    private static func unsigned(_ directory: URL) throws {
        do { _ = try SignedSetupPeer.mqttForegroundRelease(); throw ProvisionSmokeError.failed }
        catch is NativeSetupPeerError {}
        do {
            _ = try NativeMQTTProvisioning.prepare(authoring: directory.appendingPathComponent("authoring.json"),
                source: directory.appendingPathComponent("mqtt.json"))
            throw ProvisionSmokeError.failed
        } catch is NativeSetupPeerError {}
    }

    private static func actual(_ directory: URL) throws {
        let data = directory.appendingPathComponent("data", isDirectory: true)
        let a = directory.appendingPathComponent("authoring.json"), s = directory.appendingPathComponent("mqtt.json")
        let release = directory.appendingPathComponent("shim")
        let request = try NativeMQTTProvisionWire.prepare(authoring: a, source: s)
        let bytes = try NativeCoreConnection.provision(release: release, dataDirectory: data, request: request, mayCommit: false)
        let original = try NativeMQTTProvisionWire.reply(bytes, kind: "prepared")
        try check(original.channels == 1 && original.authentication == "none")
        try check(try FileManager.default.contentsOfDirectory(atPath: data.path) == [])
        try reaped(directory)
        let publish = try NativeMQTTProvisionWire.publish(authoring: a, source: s, original: original)
        for attempt in 0..<2 {
            if attempt == 1 { try FileManager.default.removeItem(at: a); try FileManager.default.removeItem(at: s) }
            let result = try NativeCoreConnection.provision(release: release, dataDirectory: data, request: publish, mayCommit: true)
            try check(try NativeMQTTProvisionWire.reply(result, kind: "published", original: original) == original)
            try reaped(directory)
        }
        try check(!FileManager.default.fileExists(atPath: data.appendingPathComponent("home.sqlite").path))
        try check(!FileManager.default.fileExists(atPath: data.appendingPathComponent("ipc").path))
    }

    private static func adversarial(_ directory: URL, mode: String) throws {
        let request = Data(#"["wotex-home.native-mqtt-provision@1","prepare","/private/fixture/a","/private/fixture/s"]"#.utf8)
        let started = DispatchTime.now().uptimeNanoseconds
        do {
            _ = try NativeCoreConnection.provision(release: directory.appendingPathComponent("shim"), dataDirectory: directory,
                request: request, mayCommit: mode != "oversized")
            throw ProvisionSmokeError.failed
        } catch NativeCoreConnectionError.outcomeUnknown { try check(mode != "oversized") }
        catch NativeCoreConnectionError.unavailable { try check(mode == "oversized") }
        if mode == "silent" {
            let elapsed = DispatchTime.now().uptimeNanoseconds - started
            try check(elapsed >= 15_000_000_000 && elapsed < 18_000_000_000)
        }
        try reaped(directory)
    }

    private static func reaped(_ directory: URL) throws {
        let text = try String(contentsOf: directory.appendingPathComponent("child-pid"), encoding: .utf8)
        guard let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw ProvisionSmokeError.failed }
        try check(kill(pid, 0) != 0 && errno == ESRCH)
    }
    private static func rejected(_ operation: () throws -> Void) throws {
        do { try operation() } catch is ProvisionSmokeError { throw ProvisionSmokeError.failed } catch { return }
        throw ProvisionSmokeError.failed
    }
    private static func check(_ value: Bool, line: UInt = #line) throws {
        if !value { FileHandle.standardError.write(Data("native MQTT foreground assertion \(line) failed\n".utf8)); throw ProvisionSmokeError.failed }
    }
}
