import Darwin
import Foundation

private enum PairedSessionSmokeError: Error { case failed(Int) }

private final class SessionClockProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var phases = 0
    func clock() throws -> NativeControllerCertificateClock {
        lock.lock(); count += 1; lock.unlock()
        throw NativeControllerTLSError.tlsClockUncertain
    }
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
    func syntheticClock() throws -> NativeControllerCertificateClock {
        lock.lock(); count += 1; lock.unlock()
        // Inert fixture input only. No production session or qualified host
        // clock is created; late work must stop before opening verification.
        return try NativeControllerCertificateClock(earliest: 0, latest: 1)
    }
    func markPhase() { lock.lock(); phases += 1; lock.unlock() }
    var phaseCalls: Int { lock.lock(); defer { lock.unlock() }; return phases }
}

private final class SessionHeldWork: @unchecked Sendable {
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private var started = false, finished = false
    func pause() throws {
        lock.lock(); started = true; lock.unlock()
        defer { lock.lock(); finished = true; lock.unlock() }
        guard release.wait(timeout: .now() + 6) == .success else { throw PairedSessionSmokeError.failed(#line) }
    }
    func resume() { release.signal() }
    var entered: Bool { lock.lock(); defer { lock.unlock() }; return started }
    var returned: Bool { lock.lock(); defer { lock.unlock() }; return finished }
}

@main
struct NativePairedControllerSessionSmoke {
    static func main() async {
        do {
            let args = CommandLine.arguments
            guard args.count == 3,
                  let vectors = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[1]))) as? [String: Any],
                  let records = vectors["valid_records"] as? [[String: Any]], records.count == 9,
                  let body = records[4]["body"] as? String else { throw PairedSessionSmokeError.failed(#line) }
            let association = try NativeControllerPublicAssociation.decode(Data(body.utf8))
            try correspondence(association)
            try await refusals(association, directory: URL(fileURLWithPath: args[2], isDirectory: true))
            print("native paired session scope, bounded owner and actual unsigned production refusal passed")
        } catch PairedSessionSmokeError.failed(let line) {
            FileHandle.standardError.write(Data("native paired session assertion failed at source line \(line)\n".utf8))
            exit(1)
        } catch {
            FileHandle.standardError.write(Data("native paired session fixture failed\n".utf8))
            exit(1)
        }
    }

    private static func correspondence(_ association: NativeControllerPublicAssociation) throws {
        // Independently authored literals from the public control vector, not
        // projected out of the implementation's association/scope comparison.
        let deployment = String(repeating: "3", count: 64), owner = String(repeating: "4", count: 64)
        let principal = "paired-controller-v1:1:" + String(repeating: "6", count: 64)
        func scope(deployment d: String = deployment, owner o: String = owner, epoch: Int = 1,
                   principal p: String = principal, revision: Int = 1,
                   permissions: [String] = ["control:ordinary", "read"], targets: [String] = ["light:fixture"]) -> HomeControllerScope {
            HomeControllerScope(identity: HomeControllerIdentity(deploymentID: d, ownerID: o,
                authorityEpoch: epoch, revision: revision, principalID: p), permissions: permissions, targetIDs: targets)
        }
        for valid in [scope(), scope(revision: 29), scope(revision: Int.max),
                      scope(permissions: ["read"], targets: []), scope(permissions: ["control:ordinary"], targets: [])] {
            try NativePairedSessionCorrespondence.check(valid, association: association)
        }
        let invalid = [
            scope(deployment: String(repeating: "a", count: 64)), scope(owner: String(repeating: "b", count: 64)),
            scope(epoch: 2), scope(epoch: 0), scope(epoch: -1), scope(epoch: Int.max),
            scope(principal: "paired-controller-v1:1:" + String(repeating: "7", count: 64)),
            scope(principal: "native:operator"), scope(revision: 0), scope(revision: -1),
            scope(permissions: []), scope(permissions: ["host:maintain", "read"]),
            scope(permissions: ["host:transfer"]), scope(permissions: ["unknown"]),
            scope(permissions: ["read", "control:ordinary"]), scope(permissions: ["read", "read"]),
            scope(targets: ["light:other"]), scope(targets: ["light:fixture", "light:other"]),
            scope(targets: ["light:fixture", "light:fixture"]), scope(targets: ["bad target"]),
        ]
        for invalidScope in invalid {
            do {
                try NativePairedSessionCorrespondence.check(invalidScope, association: association)
                throw PairedSessionSmokeError.failed(#line)
            } catch NativePairedSessionError.scopeConflict {}
        }
        let corrupt = NativeControllerPublicAssociation(id: association.id, label: association.label, peer: association.peer,
            scope: association.scope, original: association.original, access: association.access,
            verifier: String(repeating: "0", count: 64))
        do {
            try NativePairedSessionCorrespondence.check(scope(), association: corrupt)
            throw PairedSessionSmokeError.failed(#line)
        } catch NativeControllerAssociationError.invalidRecord {}
    }

    private static func refusals(_ association: NativeControllerPublicAssociation, directory: URL) async throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        try require(descriptor >= 0)
        defer { _ = Darwin.close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        try require(bound == 0 && listen(descriptor, 1) == 0)
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        try require(withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &size) }
        } == 0)
        let flags = fcntl(descriptor, F_GETFL)
        try require(flags >= 0 && fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0)
        let record = try association.changingMetadata(label: "Unsigned fixture",
            endpoint: .init(kind: "ipv4", value: "127.0.0.1"), port: Int64(UInt16(bigEndian: address.sin_port)))
        let first = try NativeControllerAssociationStorage.retaining(record, directory: directory, expected: .empty)
        let selected = try NativeControllerAssociationStorage.selecting(.remote(record.id), directory: directory, expected: first)
        let clock = SessionClockProbe()
        for original in [NativeControllerAssociationSnapshot.empty, first] {
            do {
                _ = try await NativePairedControllerSession.selected(expected: original, clock: clock.clock)
                throw PairedSessionSmokeError.failed(#line)
            } catch NativePairedSessionError.invalidSelection {}
        }
        let started = ContinuousClock.now
        do {
            _ = try await NativePairedControllerSession.selected(expected: selected, clock: clock.clock)
            throw PairedSessionSmokeError.failed(#line)
        } catch NativePairedSessionError.custody(.denied) {}
        try require(started.duration(to: .now) < .seconds(5))
        // Even after its fixture metadata changes, actual unsigned app refusal
        // precedes the fixed production account check, clock and TCP boundary.
        _ = try NativeControllerAssociationStorage.selecting(.local, directory: directory, expected: selected)
        do {
            _ = try await NativePairedControllerSession.selected(expected: selected, clock: clock.clock)
            throw PairedSessionSmokeError.failed(#line)
        } catch NativePairedSessionError.custody(.denied) {}
        let (ready, continuation) = AsyncStream<Void>.makeStream()
        let cancelled = Task.detached {
            var iterator = ready.makeAsyncIterator()
            _ = await iterator.next()
            return try await NativePairedControllerSession.selected(expected: selected, clock: clock.clock)
        }
        cancelled.cancel(); continuation.finish()
        do { _ = try await cancelled.value; throw PairedSessionSmokeError.failed(#line) }
        catch NativeControllerTLSError.cancelled {}
        try require(clock.calls == 0)
        try await boundedOwners(record.peer)
        let accepted = accept(descriptor, nil, nil)
        if accepted >= 0 { _ = Darwin.close(accepted); throw PairedSessionSmokeError.failed(#line) }
        try require(errno == EAGAIN || errno == EWOULDBLOCK)
        // No successful session seal, operator account or SecItem is opened.
    }

    private static func boundedOwners(_ peer: NativeControllerPeer) async throws {
        for mode in ["sdk", "clock", "cancel"] {
            let held = SessionHeldWork(), probe = SessionClockProbe()
            defer { held.resume() }
            let deadline = ContinuousClock.now.advanced(by: mode == "cancel" ? .seconds(3) : .milliseconds(500))
            let started = ContinuousClock.now
            let owner = Task.detached {
                try await NativeControllerDomainClient.perform(peer, credential: Data(repeating: 8, count: 32), clock: {
                    if mode == "clock" { try held.pause() }
                    return try probe.syntheticClock()
                }, exchangeGuard: NativeControllerExchangeGuard { _ in probe.markPhase() }, deadline: deadline) {
                    if mode != "clock" { try held.pause() }
                    return try LocalHealthClient.fetchControllerScope(socketPath: "", credential: Data(repeating: 8, count: 32))
                }
            }
            try await until { held.entered }
            if mode == "cancel" { owner.cancel() }
            do { _ = try await owner.value; throw PairedSessionSmokeError.failed(#line) }
            catch NativeControllerTLSError.outcomeUnknown {}
            try require(started.duration(to: .now) < .seconds(3) && !held.returned)
            held.resume()
            try await until { held.returned }
            try await Task.sleep(for: .milliseconds(100))
            try require(probe.phaseCalls == 0 && probe.calls == (mode == "clock" ? 1 : 0))
        }
        let probe = SessionClockProbe()
        do {
            _ = try await NativeControllerDomainClient.perform(peer, credential: Data(repeating: 8, count: 32),
                clock: probe.syntheticClock, deadline: .now.advanced(by: .milliseconds(-1))) {
                try LocalHealthClient.fetchControllerScope(socketPath: "", credential: Data(repeating: 8, count: 32))
            }
            throw PairedSessionSmokeError.failed(#line)
        } catch NativeControllerTLSError.outcomeUnknown {}
        try require(probe.calls == 0)
    }

    private static func until(_ condition: @escaping @Sendable () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition() {
            try require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private static func require(_ condition: Bool, line: Int = #line) throws {
        guard condition else { throw PairedSessionSmokeError.failed(line) }
    }
}
