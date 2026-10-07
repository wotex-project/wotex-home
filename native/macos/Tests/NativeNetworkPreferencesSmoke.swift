import Darwin
import Foundation

private enum PreferenceSmokeError: Error { case failed }

@main
struct NativeNetworkPreferencesSmoke {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { throw PreferenceSmokeError.failed }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try codecs()
        let prefs = directory.appendingPathComponent("preferences", isDirectory: true)
        try FileManager.default.createDirectory(at: prefs, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let file = prefs.appendingPathComponent("native-network-v1.json").path
        let lock = prefs.appendingPathComponent("native-network-v1.lock").path
        try require(setenv("WOTEX_HOME_LIFX_INTERFACE", "inherited0", 1) == 0)
        try require(setenv("WOTEX_HOME_PHYSICAL_DISPATCH", "true", 1) == 0)
        let emptyEnvironment = try NativeCoreEnvironment.values(dataDirectory: prefs)
        try require(emptyEnvironment.count == 6 && emptyEnvironment["WOTEX_HOME_LIFX_INTERFACE"] == nil)
        try require(try NativeNetworkPreferences.load(directory: prefs) == .disabled)
        try require(try NativeNetworkPreferences.save(directory: prefs, expected: .disabled, interface: nil) == .disabled)
        try require(!FileManager.default.fileExists(atPath: file))
        let first = try NativeNetworkPreferences.save(directory: prefs, expected: .disabled, interface: "en0")
        try require(first.record == NativeNetworkRecord(revision: 1, interface: "en0"))
        let selectedEnvironment = try NativeCoreEnvironment.values(dataDirectory: prefs)
        try require(selectedEnvironment.count == 7 && selectedEnvironment["WOTEX_HOME_LIFX_INTERFACE"] == "en0" && selectedEnvironment["WOTEX_HOME_PHYSICAL_DISPATCH"] == nil)
        try require(try String(contentsOfFile: file, encoding: .utf8) == "[\"wotex-home.native-network.v1\",1,\"lifx-read\",\"en0\"]")
        try require(try NativeNetworkPreferences.save(directory: prefs, expected: first, interface: "en0") == first)
        do { _ = try NativeNetworkPreferences.save(directory: prefs, expected: .disabled, interface: "en1"); throw PreferenceSmokeError.failed }
        catch NativeNetworkPreferenceError.conflict {}
        let second = try NativeNetworkPreferences.save(directory: prefs, expected: first, interface: "en1")
        try require(second.record.revision == 2 && second.record.interface == "en1")
        do { _ = try NativeNetworkPreferences.save(directory: prefs, expected: first, interface: "en2"); throw PreferenceSmokeError.failed }
        catch NativeNetworkPreferenceError.conflict {}
        let disabled = try NativeNetworkPreferences.save(directory: prefs, expected: second, interface: nil)
        try require(disabled.record == NativeNetworkRecord(revision: 3, interface: nil))
        try require(try NativeCoreEnvironment.values(dataDirectory: prefs).count == 6)
        let lockFD = open(lock, O_RDWR | O_CLOEXEC)
        try require(lockFD >= 0 && flock(lockFD, LOCK_EX | LOCK_NB) == 0)
        do { _ = try NativeNetworkPreferences.save(directory: prefs, expected: disabled, interface: "en0"); throw PreferenceSmokeError.failed }
        catch NativeNetworkPreferenceError.capacity {}
        _ = flock(lockFD, LOCK_UN); _ = Darwin.close(lockFD)
        try require(try NativeNetworkPreferences.load(directory: prefs) == disabled)
        // Metadata replacement conflicts even when the canonical record is identical.
        let replacement = prefs.appendingPathComponent("replacement").path
        try write(replacement, Data("[\"wotex-home.native-network.v1\",3,\"disabled\"]".utf8))
        try require(rename(replacement, file) == 0)
        do { _ = try NativeNetworkPreferences.save(directory: prefs, expected: disabled, interface: "en0"); throw PreferenceSmokeError.failed }
        catch NativeNetworkPreferenceError.conflict {}
        try FileManager.default.removeItem(atPath: file)
        try require(symlink(lock, file) == 0)
        try refused { _ = try NativeNetworkPreferences.load(directory: prefs) }
        try require(FileManager.default.destinationOfSymbolicLink(atPath: file) == lock)
        try FileManager.default.removeItem(atPath: file)
        try require(mkfifo(file, 0o600) == 0)
        try refused { _ = try NativeNetworkPreferences.load(directory: prefs) }
        try FileManager.default.removeItem(atPath: file)
        try write(file, Data("[\"wotex-home.native-network.v1\",1,\"disabled\"]".utf8))
        let linked = prefs.appendingPathComponent("linked").path
        try require(link(file, linked) == 0)
        try refused { _ = try NativeNetworkPreferences.load(directory: prefs) }
        try FileManager.default.removeItem(atPath: linked)
        try require(chmod(file, 0o644) == 0)
        try refused { _ = try NativeNetworkPreferences.load(directory: prefs) }
        try require(chmod(file, 0o600) == 0)
        try write(file, Data(repeating: 65, count: 129))
        try refused { _ = try NativeNetworkPreferences.load(directory: prefs) }
        try write(file, Data("[\"wotex-home.native-network.v1\",1,\"lifx-read\",\"en-0\"]".utf8))
        try refused { _ = try NativeNetworkPreferences.load(directory: prefs) }
        try refused { _ = try NativeCoreEnvironment.values(dataDirectory: prefs) }
        try FileManager.default.removeItem(atPath: file)
        try FileManager.default.removeItem(atPath: lock)
        try require(symlink("unknown", lock) == 0)
        try refused { _ = try NativeNetworkPreferences.save(directory: prefs, expected: .disabled, interface: "en0") }
        try require(!FileManager.default.fileExists(atPath: file))
        try FileManager.default.removeItem(atPath: lock)
        try require(mkfifo(lock, 0o600) == 0)
        try refused { _ = try NativeNetworkPreferences.save(directory: prefs, expected: .disabled, interface: "en0") }
        try FileManager.default.removeItem(atPath: lock)
        try write(lock, Data())
        try require(link(lock, linked) == 0)
        try refused { _ = try NativeNetworkPreferences.save(directory: prefs, expected: .disabled, interface: "en0") }
        try FileManager.default.removeItem(atPath: linked)
        try write(lock, Data([1]))
        try refused { _ = try NativeNetworkPreferences.save(directory: prefs, expected: .disabled, interface: "en0") }
        try FileManager.default.removeItem(atPath: lock)
        try write(file, Data("[\"wotex-home.native-network.v1\",9223372036854775807,\"disabled\"]".utf8))
        let exhausted = try NativeNetworkPreferences.load(directory: prefs)
        try refused { _ = try NativeNetworkPreferences.save(directory: prefs, expected: exhausted, interface: "en0") }
        let alias = directory.appendingPathComponent("alias").path
        try require(symlink(prefs.path, alias) == 0)
        try refused { _ = try NativeNetworkPreferences.load(directory: URL(fileURLWithPath: alias)) }
        try require(chmod(prefs.path, 0o755) == 0)
        try refused { _ = try NativeNetworkPreferences.load(directory: prefs) }
        try require(chmod(prefs.path, 0o700) == 0)
        print("native network canonical/private preference checks passed")
    }
    private static func codecs() throws {
        for (text, expected) in [
            ("[\"wotex-home.native-network.v1\",1,\"disabled\"]", NativeNetworkRecord(revision: 1, interface: nil)),
            ("[\"wotex-home.native-network.v1\",2,\"lifx-read\",\"en0\"]", NativeNetworkRecord(revision: 2, interface: "en0")),
            ("[\"wotex-home.native-network.v1\",9223372036854775807,\"lifx-read\",\"bridge100\"]", NativeNetworkRecord(revision: Int64.max, interface: "bridge100"))
        ] {
            try require(try NativeNetworkRecord.decode(Data(text.utf8)) == expected)
            try require(try expected.encoded() == Data(text.utf8))
        }
        for text in ["[]", "{}", "[\"wotex-home.native-network.v1\",0,\"disabled\"]", "[\"wotex-home.native-network.v1\",true,\"disabled\"]",
            "[\"wotex-home.native-network.v1\",1.0,\"disabled\"]", "[\"wotex-home.native-network.v1\",01,\"disabled\"]",
            "[\"wotex-home.native-network.v1\",-1,\"disabled\"]", "[\"wotex-home.native-network.v1\",9223372036854775808,\"disabled\"]",
            "[\"wotex-home.native-network.v1\",1,\"disabled\",\"en0\"]", "[\"wotex-home.native-network.v1\",1,\"lifx-read\"]",
            "[\"wotex-home.native-network.v1\",1,\"lifx-write\",\"en0\"]", "[\"wotex-home.native-network.v1\",1,\"lifx-read\",null]",
            "[\"wotex-home.native-network.v1\",1,\"lifx-read\",\"en0\",0]", "[\"wotex-home.native-network.v1\",1,\"lifx-read\",[\"en0\"]]",
            " [\"wotex-home.native-network.v1\",1,\"disabled\"]", "[\"wotex-home.native-network.v1\",1,\"disabled\"]\n"] {
            try refused { _ = try NativeNetworkRecord.decode(Data(text.utf8)) }
        }
        for name in ["", "0en", "en-0", "en_0", "en.0", "en0\n", "en0\0", "én0", String(repeating: "a", count: 16), "../en0"] {
            try require(!NativeNetworkRecord.validName(name))
            try refused { _ = try NativeNetworkRecord(revision: 1, interface: name).encoded() }
        }
    }
    private static func write(_ path: String, _ bytes: Data) throws {
        try bytes.write(to: URL(fileURLWithPath: path))
        try require(chmod(path, 0o600) == 0)
    }
    private static func refused(_ action: () throws -> Void) throws {
        do { try action(); throw PreferenceSmokeError.failed }
        catch is NativeNetworkPreferenceError {}
    }
    private static func require(_ condition: Bool) throws { if !condition { throw PreferenceSmokeError.failed } }
}
