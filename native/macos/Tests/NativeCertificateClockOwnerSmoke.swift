import CryptoKit
import Darwin
import Foundation

private enum ClockOwnerSmokeError: Error { case failed(Int) }
private final class ClockOwnerProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var began = false, stopped = false, delivered = false
    let release = DispatchSemaphore(value: 0)
    func entered() { lock.withLock { began = true } }
    func retired() { lock.withLock { stopped = true } }
    func published() { lock.withLock { delivered = true } }
    var state: (Bool, Bool, Bool) { lock.withLock { (began, stopped, delivered) } }
}

@main
struct NativeCertificateClockOwnerSmoke {
    static func main() async {
        do {
            try check(CommandLine.arguments.count == 3)
            let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            let vectors = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))) as! [String: Any]
            let first = (vectors["vectors"] as! [[String: Any]])[0]
            let policy = try JSONSerialization.jsonObject(with: Data((first["policy"] as! String).utf8)) as! [Any]
            try await files(root, policy: policy)
            try await deadlines()
            let owner = NativeCertificateClockOwner()
            try check(owner.status().phase == .unavailable && !owner.status().busy && owner.customMirror.children.isEmpty)
            try refused { _ = try owner.clock() }
            for _ in 0..<2 {
                do { _ = try await owner.begin(); throw ClockOwnerSmokeError.failed(#line) }
                catch NativeCertificateClockError.clockUnavailable {}
                try check(!owner.status().busy && owner.status().phase == .withdrawn)
            }
            let fresh = NativeCertificateClockOwner()
            try check(fresh.status().phase == .unavailable)
            try refused { _ = try fresh.clock() }
            print("native clock actual-file custody, volatile generation/withdrawal, original deadlines, retiring capacity and actual unsigned production refusal passed")
        } catch ClockOwnerSmokeError.failed(let line) {
            FileHandle.standardError.write(Data("native clock owner assertion failed at line \(line)\n".utf8)); exit(1)
        } catch {
            FileHandle.standardError.write(Data("native clock owner fixture failed: \(String(reflecting: type(of: error)))\n".utf8)); exit(1)
        }
    }

    private static func files(_ root: URL, policy: [Any]) async throws {
        let source = try generation(root, "accepted", policy: policy)
        let request = source.custody.request.bytes, beginning = source.custody.start
        try check(source.status().phase == .requesting)
        let answer = try response(root, source: source)
        try source.accept(answer, digest: source.custody.digest, check: {})
        try check(source.status().phase == .qualified)
        let copied = try Data(contentsOf: source.custody.request.directory.url.appendingPathComponent("response.json"))
        try check(copied == Data(contentsOf: answer))
        let before = source.status().remainingMilliseconds!
        try await Task.sleep(for: .milliseconds(20))
        try source.accept(answer, digest: source.custody.digest, check: {})
        try check(source.custody.start == beginning && source.custody.request.bytes == request && source.status().remainingMilliseconds! < before)
        _ = try source.sample()
        let oldClock = try NativeControllerCertificateClock(sourceExpiry: source.expires) { try source.sample() }
        _ = try oldClock.bounds()
        let wrong = try response(root, source: source, observed: 1_792_065_600_001)
        try refused { try source.accept(wrong, digest: source.custody.digest, check: {}) }
        try check(source.status().phase == .qualified)
        try refused { try source.accept(answer, digest: String(repeating: "f", count: 64), check: {}) }
        try check(source.status().phase == .qualified)
        source.withdraw()
        do { _ = try oldClock.bounds(); throw ClockOwnerSmokeError.failed(#line) }
        catch NativeControllerTLSError.tlsClockUncertain {}
        try refused { try source.accept(answer, digest: source.custody.digest, check: {}) }
        try check(source.status().phase == .withdrawn)

        let pending = try generation(root, "pending", policy: policy)
        try refused { try pending.accept(answer, digest: String(repeating: "f", count: 64), check: {}) }
        try check(pending.status().phase == .requesting)
        try refused { try pending.accept(answer, digest: pending.custody.digest, check: {}) }
        try check(pending.status().phase == .withdrawn)
        let invalid = try generation(root, "invalid-signature", policy: policy)
        let bad = try response(root, source: invalid, corrupt: true)
        try refused { try invalid.accept(bad, digest: invalid.custody.digest, check: {}) }
        try check(invalid.status().phase == .withdrawn)
        let restarted = try generation(root, "restart", policy: policy)
        try check(restarted.custody.digest != source.custody.digest)
        try refused { try restarted.accept(answer, digest: restarted.custody.digest, check: {}) }

        for target in ["policy", "request", "response", "root", "ancestor", "mode", "hardlink", "symlink"] {
            let value = try generation(root, "replace-" + target, policy: policy, nested: target == "ancestor")
            let input = try response(root, source: value)
            try value.accept(input, digest: value.custody.digest, check: {})
            let oldClock = try NativeControllerCertificateClock(sourceExpiry: value.expires) { try value.sample() }
            if ["root", "ancestor"].contains(target) {
                let directory = target == "root" ? value.custody.root.url : value.custody.root.url.deletingLastPathComponent()
                let retained = directory.appendingPathExtension("retired")
                try FileManager.default.moveItem(at: directory, to: retained)
                try FileManager.default.copyItem(at: retained, to: directory)
                try refused { try value.check() }
                try FileManager.default.removeItem(at: directory)
                try FileManager.default.moveItem(at: retained, to: directory)
            } else {
                let file = target == "policy" ? value.custody.policy.url : target == "response" ?
                    value.custody.request.directory.url.appendingPathComponent("response.json") : value.custody.request.url
                let bytes = try Data(contentsOf: file)
                if target == "mode" {
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                    try refused { try value.check() }
                    try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: file.path)
                } else if target == "hardlink" {
                    let link = file.appendingPathExtension("link")
                    try check(Darwin.link(file.path, link.path) == 0)
                    try refused { try value.check() }
                    try FileManager.default.removeItem(at: link)
                } else {
                    let retained = file.appendingPathExtension("retired")
                    try FileManager.default.moveItem(at: file, to: retained)
                    if target == "symlink" { try FileManager.default.createSymbolicLink(at: file, withDestinationURL: retained) }
                    else { try immutable(bytes, at: file) }
                    try refused { try value.check() }
                    try FileManager.default.removeItem(at: file)
                    try FileManager.default.moveItem(at: retained, to: file)
                }
            }
            try check(value.status().phase == .withdrawn)
            try refused { try value.check() }
            do { _ = try oldClock.bounds(); throw ClockOwnerSmokeError.failed(#line) }
            catch NativeControllerTLSError.tlsClockUncertain {}
        }

        let cumulative = try generation(root, "cumulative", policy: policy)
        try cumulative.accept(response(root, source: cumulative), digest: cumulative.custody.digest, check: {})
        for i in 1...4 { try cumulative.observe(elapsed: Int64(i * 100), wall: cumulative.custody.wall + Int64(i * 102)) }
        try refused { try cumulative.observe(elapsed: 500, wall: cumulative.custody.wall + 510) }
        try refused { try cumulative.observe(elapsed: 600, wall: cumulative.custody.wall + 600) }
        let rollback = try generation(root, "rollback", policy: policy)
        try rollback.observe(elapsed: 1, wall: rollback.custody.wall + 1)
        try refused { try rollback.observe(elapsed: 2, wall: rollback.custody.wall) }

        var short = policy; short[8] = 100; short[9] = 300; short[10] = 0
        let expiring = try generation(root, "age-expiry", policy: short)
        try expiring.accept(response(root, source: expiring), digest: expiring.custody.digest, check: {})
        let clock = try NativeControllerCertificateClock(sourceExpiry: expiring.expires) { try expiring.sample() }
        try await Task.sleep(for: .milliseconds(330))
        try check(expiring.status().phase == .withdrawn)
        do { _ = try clock.bounds(); throw ClockOwnerSmokeError.failed(#line) } catch NativeControllerTLSError.tlsClockUncertain {}
        let responseExpiry = try generation(root, "response-expiry", policy: short)
        try await Task.sleep(for: .milliseconds(120))
        try refused { try responseExpiry.check() }

        let unknown = try generation(root, "publication", policy: policy)
        let unknownAnswer = try response(root, source: unknown)
        try refused {
            try unknown.accept(unknownAnswer, digest: unknown.custody.digest) {
                if FileManager.default.fileExists(atPath: unknown.custody.request.directory.url.appendingPathComponent("response.json").path) {
                    throw NativeCertificateClockError.expired
                }
            }
        }
        try check(unknown.status().phase == .withdrawn)
        try check(FileManager.default.fileExists(atPath: unknown.custody.request.directory.url.appendingPathComponent("response.json").path))
        try refused { _ = try unknown.sample() }

        let capacity = try privateDirectory(root.appendingPathComponent("capacity", isDirectory: true))
        try immutable(encode(policy), at: capacity.appendingPathComponent("policy.json"))
        for i in 0..<63 { _ = try privateDirectory(capacity.appendingPathComponent("retained-\(i)", isDirectory: true)) }
        let directory = try NativeCertificateClockDirectory(capacity, temporaryFixture: true)
        try refused { _ = try NativeCertificateClockCustody.begin(root: directory, runtime: policy[7] as! String, check: {}) }
        try check(try FileManager.default.contentsOfDirectory(atPath: capacity.path).count == 64)
        let unsafe = try privateDirectory(root.appendingPathComponent("unsafe", isDirectory: true))
        try immutable(encode(policy), at: unsafe.appendingPathComponent("policy.json"))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: unsafe.appendingPathComponent("policy.json").path)
        try refused { _ = try NativeCertificateClockCustody.begin(root: NativeCertificateClockDirectory(unsafe, temporaryFixture: true), runtime: policy[7] as! String, check: {}) }
        try check(try FileManager.default.contentsOfDirectory(atPath: unsafe.path).count == 1)
        let mismatch = try privateDirectory(root.appendingPathComponent("runtime", isDirectory: true))
        try immutable(encode(policy), at: mismatch.appendingPathComponent("policy.json"))
        try refused { _ = try NativeCertificateClockCustody.begin(root: NativeCertificateClockDirectory(mismatch, temporaryFixture: true), runtime: String(repeating: "f", count: 64), check: {}) }
        try check(try FileManager.default.contentsOfDirectory(atPath: mismatch.path).count == 1)
        let acl = try generation(root, "acl", policy: policy)
        let chmod = Process(); chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.standardOutput = FileHandle.nullDevice; chmod.standardError = FileHandle.nullDevice
        chmod.arguments = ["+a", "everyone allow write", acl.custody.policy.url.path]
        try chmod.run(); chmod.waitUntilExit(); try check(chmod.terminationStatus == 0)
        try refused { try acl.check() }
        try check(acl.status().phase == .withdrawn)
        let fifo = try generation(root, "fifo", policy: policy)
        let fifoInput = try privateDirectory(root.appendingPathComponent("fifo-input", isDirectory: true)).appendingPathComponent("response.json")
        try check(mkfifo(fifoInput.path, 0o400) == 0)
        try refused { try fifo.accept(fifoInput, digest: fifo.custody.digest, check: {}) }
        try check(fifo.status().phase == .withdrawn)
        let locking = try privateDirectory(root.appendingPathComponent("locking", isDirectory: true))
        try immutable(encode(policy), at: locking.appendingPathComponent("policy.json"))
        let firstLock = try NativeCertificateClockDirectory(locking, temporaryFixture: true)
        let otherLock = try NativeCertificateClockDirectory(locking, temporaryFixture: true)
        try check(flock(firstLock.fd, LOCK_EX | LOCK_NB) == 0)
        do {
            try refused { _ = try NativeCertificateClockCustody.begin(root: otherLock, runtime: policy[7] as! String, check: {}) }
        } catch { _ = flock(firstLock.fd, LOCK_UN); throw error }
        try check(flock(firstLock.fd, LOCK_UN) == 0)
        // A delayed current-source callback keeps its observation coordinate;
        // time spent after sampling must advance the returned interval.
        let delayed = try NativeControllerCertificateClock(sourceExpiry: .now.advanced(by: .seconds(1))) {
            let instant = ContinuousClock.now
            Thread.sleep(forTimeInterval: 0.04)
            return .init(earliest: 1_000_000, latest: 1_000_010, observed: instant, driftPPM: 1000)
        }
        let advanced = try delayed.bounds()
        try check(advanced.0.timeIntervalSince1970 > 1000.02 && advanced.1.timeIntervalSince1970 > 1000.04)
    }

    private static func deadlines() async throws {
        let original = try CertificateClockOperations.shared.reserve()
        CertificateClockOperations.shared.retire(UUID())
        CertificateClockOperations.shared.invalidate(UUID())
        try CertificateClockOperations.shared.check(original, until: .now.advanced(by: .seconds(1)))
        try refused { _ = try CertificateClockOperations.shared.reserve() }
        CertificateClockOperations.shared.retire(original)
        for cancel in [false, true] {
            let gate = CertificateClockOperations.shared, token = try gate.reserve(), probe = ClockOwnerProbe()
            let deadline = ContinuousClock.now.advanced(by: cancel ? .seconds(2) : .milliseconds(100))
            let job = NativeCertificateClockJob<String>(deadline: deadline, invalidated: { gate.invalidate(token) },
                retired: { gate.retire(token); probe.retired() })
            let task = Task {
                do { _ = try await job.run { probe.entered(); probe.release.wait(); return "late" }; probe.published(); throw ClockOwnerSmokeError.failed(#line) }
                catch NativeCertificateClockError.expired {}
            }
            do {
                try await until { probe.state.0 }
                if cancel { task.cancel() }
                try await task.value
                try check(!probe.state.1 && !probe.state.2)
                try refused { _ = try gate.reserve() }
                do { _ = try await NativeCertificateClockOwner().begin(); throw ClockOwnerSmokeError.failed(#line) }
                catch NativeCertificateClockError.capacity {}
            } catch { probe.release.signal(); throw error }
            probe.release.signal()
            try await until { probe.state.1 }
            try check(!probe.state.2)
            let next = try gate.reserve(); gate.retire(next)
        }
        let gate = CertificateClockOperations.shared, token = try gate.reserve(), probe = ClockOwnerProbe()
        let job = NativeCertificateClockJob<Int>(deadline: .now.advanced(by: .seconds(1)), invalidated: { gate.invalidate(token) }, retired: { gate.retire(token); probe.retired() })
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try await job.run { probe.entered(); return 1 }; throw ClockOwnerSmokeError.failed(#line) }
            catch NativeCertificateClockError.expired {}
        }
        try await task.value
        try check(!probe.state.0 && probe.state.1)
        let next = try gate.reserve(); gate.retire(next)
    }
    private static func generation(_ root: URL, _ name: String, policy: [Any], nested: Bool = false) throws -> NativeCertificateClockGeneration {
        var path = try privateDirectory(root.appendingPathComponent(name, isDirectory: true))
        if nested { path = try privateDirectory(path.appendingPathComponent("source", isDirectory: true)) }
        try immutable(encode(policy), at: path.appendingPathComponent("policy.json"))
        return try NativeCertificateClockGeneration(NativeCertificateClockCustody.begin(
            root: NativeCertificateClockDirectory(path, temporaryFixture: true), runtime: policy[7] as! String, check: {}))
    }
    private static func response(_ root: URL, source: NativeCertificateClockGeneration, observed: Int64 = 1_792_065_600_000, corrupt: Bool = false) throws -> URL {
        let request = try NativeCertificateClockRequest.decode(source.custody.request.bytes)
        let unsigned = NativeCertificateClockPackage(request: request, observedUTC: observed, signature: Data(repeating: 0, count: 64))
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 17, count: 32))
        let signature = corrupt ? Data(repeating: 0, count: 64) : try key.signature(for: unsigned.signingBytes())
        let bytes = try NativeCertificateClockPackage(request: request, observedUTC: observed, signature: signature).encoded()
        let directory = try privateDirectory(root.appendingPathComponent("input-" + UUID().uuidString, isDirectory: true))
        let url = directory.appendingPathComponent("signed answer.json"); try immutable(bytes, at: url); return url
    }
    private static func privateDirectory(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]); return url
    }
    private static func immutable(_ bytes: Data, at url: URL) throws {
        try bytes.write(to: url, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: url.path)
    }
    private static func encode(_ a: [Any]) throws -> Data { try JSONSerialization.data(withJSONObject: a, options: [.withoutEscapingSlashes]) }
    private static func until(_ condition: () -> Bool) async throws {
        for _ in 0..<500 { if condition() { return }; try await Task.sleep(for: .milliseconds(2)) }; throw ClockOwnerSmokeError.failed(#line)
    }
    private static func check(_ condition: Bool, line: Int = #line) throws { if !condition { throw ClockOwnerSmokeError.failed(line) } }
    private static func refused(line: Int = #line, _ work: () throws -> Void) throws {
        do { try work() } catch is NativeCertificateClockError { return }; throw ClockOwnerSmokeError.failed(line)
    }
}
