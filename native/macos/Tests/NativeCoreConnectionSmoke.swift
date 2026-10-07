import Darwin
import Foundation

private enum CoreSmokeError: Error { case failed }

@main
struct NativeCoreConnectionSmoke {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else { throw CoreSmokeError.failed }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let mode = CommandLine.arguments[2]
        for key in ["ERL_AFLAGS", "ELIXIR_ERL_OPTIONS", "RELEASE_ROOT", "WOTEX_HOME_PHYSICAL_DISPATCH", "WOTEX_HOME_LIFX_INTERFACE"] {
            guard setenv(key, "untrusted_fixture_override", 1) == 0 else { throw CoreSmokeError.failed }
        }
        let environment = try NativeCoreEnvironment.values(dataDirectory: directory)
        try check(Set(environment.keys) == Set(["PATH", "HOME", "LANG", "LC_ALL", "WOTEX_HOME_DATA_DIR", "RELEASE_DISTRIBUTION"]))
        try check(environment["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin" && environment["RELEASE_DISTRIBUTION"] == "none")
        try expected(.unavailable) {
            _ = try NativeCoreConnection(release: directory.appendingPathComponent("missing-executable"), dataDirectory: directory)
        }
        if mode == "signal-stop" || mode == "parent-loss" {
            try lifecycle(directory)
        } else if mode == "actual" {
            try actual(directory)
        } else if mode == "selected-environment" {
            try selectedEnvironment(directory)
        } else {
            try adversarial(directory, mode: mode)
        }
        print("native core pipe \(mode) passed")
    }

    private static func selectedEnvironment(_ directory: URL) throws {
        let first = try NativeNetworkPreferences.save(directory: directory, expected: .disabled, interface: "en0")
        let connection = try NativeCoreConnection(release: directory.appendingPathComponent("core-shim"), dataDirectory: directory)
        defer { _ = connection.close() }
        let original = try connection.identity(deadline: deadline())
        _ = try NativeNetworkPreferences.save(directory: directory, expected: first, interface: "en1")
        try check(try NativeCoreEnvironment.values(dataDirectory: directory)["WOTEX_HOME_LIFX_INTERFACE"] == "en1")
        try check(try connection.identity(deadline: deadline()) == original)
        try check(connection.close())
    }

    private static func lifecycle(_ directory: URL) throws {
        let early = AgentShutdown()
        let callback = DispatchSemaphore(value: 0)
        early.requestStop()
        early.installAction { callback.signal() }
        try check(early.isRequested && callback.wait(timeout: .now() + 1) == .success)
        let shutdown = AgentShutdown()
        let signals = terminationSources { shutdown.requestStop() }
        let session = try NativeDevelopmentSession(release: directory.appendingPathComponent("core-shim"), dataDirectory: directory)
        try Data("ready".utf8).write(to: directory.appendingPathComponent("parent-ready"))
        let status = withExtendedLifetime(signals) { session.run(shutdown: shutdown) }
        try check(status == 0)
        try check(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("ipc/home.sock").path))
        try check(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("ipc/native-setup.sock").path))
    }

    private static func actual(_ directory: URL) throws {
        let connection = try NativeCoreConnection(release: directory.appendingPathComponent("core-shim"), dataDirectory: directory)
        let firstScope = try connection.identity(deadline: deadline())
        try check(firstScope.epoch == 1 && firstScope.revision == 0)
        let missingReceipt = NativeCreationReceipt(deployment: firstScope.deployment, owner: firstScope.owner,
            epoch: 1, role: .operator, principal: "native-setup-v1:1:operator", revision: 1)
        let missing = NativeOriginalReference(receipt: missingReceipt, verifier: String(repeating: "91", count: 32))
        try expected(.ownerChanged) { _ = try connection.existing(original: missing, scope: firstScope, deadline: deadline()) }
        try check(try connection.identity(deadline: deadline()).revision == 0)
        let verifier = Data(repeating: 0x91, count: 32) // Inert synthetic verifier, never a real credential.
        let receipt = try connection.ensure(scope: firstScope, role: .operator, verifier: verifier, deadline: deadline())
        try check(receipt.revision == 1 && receipt.principal == "native-setup-v1:1:operator")
        let unchanged = try connection.ensure(scope: firstScope, role: .operator, verifier: verifier, deadline: deadline())
        try check(unchanged == receipt)
        let original = NativeOriginalReference(receipt: receipt, verifier: NativeCoreWire.hex(verifier))
        let currentScope = try connection.identity(deadline: deadline())
        try check(try connection.existing(original: original, scope: currentScope, deadline: deadline()) == receipt)
        try expected(.custodyConflict) {
            _ = try connection.existing(original: NativeOriginalReference(receipt: receipt, verifier: String(repeating: "92", count: 32)), scope: currentScope, deadline: deadline())
        }
        try expected(.custodyConflict) {
            _ = try connection.ensure(scope: firstScope, role: .operator, verifier: Data(repeating: 0x92, count: 32), deadline: deadline())
        }
        let changed = NativeControllerScope(deployment: firstScope.deployment, owner: String(repeating: "f", count: 64), epoch: 1, revision: 0)
        try expected(.ownerChanged) {
            _ = try connection.ensure(scope: changed, role: .operator, verifier: verifier, deadline: deadline())
        }
        try check(try connection.identity(deadline: deadline()).revision == 1)
        try check(connection.close())
        try check(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("ipc/home.sock").path))
        try expected(.unavailable) { _ = try connection.identity(deadline: deadline()) }
        let reopened = try NativeCoreConnection(release: directory.appendingPathComponent("core-shim"), dataDirectory: directory)
        let scope = try reopened.identity(deadline: deadline())
        try check(scope.deployment == firstScope.deployment && scope.owner == firstScope.owner && scope.revision == 1)
        try check(try reopened.existing(original: original, scope: scope, deadline: deadline()) == receipt)
        try check(try reopened.ensure(scope: scope, role: .operator, verifier: verifier, deadline: deadline()) == receipt)
        try check(reopened.close())
    }

    private static func adversarial(_ directory: URL, mode: String) throws {
        let connection = try NativeCoreConnection(release: directory.appendingPathComponent("core-shim"), dataDirectory: directory)
        defer { _ = connection.close() }
        let scope = NativeControllerScope(deployment: String(repeating: "a", count: 64),
                                          owner: String(repeating: "b", count: 64), epoch: 1, revision: 0)
        let started = DispatchTime.now().uptimeNanoseconds
        if mode == "wrong-receipt" {
            try expected(.outcomeUnknown) {
                _ = try connection.ensure(scope: scope, role: .operator, verifier: Data(repeating: 0, count: 32), deadline: deadline())
            }
        } else if mode == "expired" {
            try expected(.expired) { _ = try connection.identity(deadline: started) }
        } else if mode == "capacity" {
            let completed = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                do { _ = try connection.identity(deadline: DispatchTime.now().uptimeNanoseconds + 800_000_000) }
                catch {}
                completed.signal()
            }
            let marker = directory.appendingPathComponent("request-seen").path
            while !FileManager.default.fileExists(atPath: marker) && DispatchTime.now().uptimeNanoseconds < started + 2_000_000_000 { usleep(10_000) }
            try check(FileManager.default.fileExists(atPath: marker))
            try expected(.capacity) { _ = try connection.identity(deadline: deadline()) }
            try check(completed.wait(timeout: .now() + 5) == .success)
        } else {
            try expected(.unavailable) {
                _ = try connection.identity(deadline: started + 800_000_000)
            }
            try check(DispatchTime.now().uptimeNanoseconds - started < 5_000_000_000)
            try expected(.unavailable) { _ = try connection.identity(deadline: deadline()) }
        }
        try check(connection.close())
        let pidFile = directory.appendingPathComponent("child-pid")
        if let text = try? String(contentsOf: pidFile, encoding: .utf8), let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            errno = 0
            try check(kill(pid, 0) == -1 && errno == ESRCH)
        }
    }

    private static func deadline() -> UInt64 { DispatchTime.now().uptimeNanoseconds + 5_000_000_000 }
    private static func check(_ value: Bool, line: UInt = #line) throws {
        if !value { fputs("native core fixture check failed at line \(line)\n", stderr); throw CoreSmokeError.failed }
    }
    private static func expected(_ expected: NativeCoreConnectionError, _ body: () throws -> Void) throws {
        do { try body() }
        catch let error as NativeCoreConnectionError where error == expected { return }
        throw CoreSmokeError.failed
    }
}
