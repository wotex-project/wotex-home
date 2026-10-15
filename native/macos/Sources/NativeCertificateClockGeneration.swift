import Foundation

enum NativeCertificateClockPhase: String, Sendable { case unavailable, requesting, qualified, withdrawn }

struct NativeCertificateClockStatus: Sendable {
    let phase: NativeCertificateClockPhase
    let source: String?, procedure: String?, requestDigest: String?, requestURL: URL?
    let remainingMilliseconds: Int64?
    let busy: Bool
    let error: NativeCertificateClockError?
}

// Volatile, unsealed generation machinery for actual files and elapsed clocks.
// A fixture can exercise it, but cannot install it in the production owner.
final class NativeCertificateClockGeneration: @unchecked Sendable, CustomReflectable {
    let custody: NativeCertificateClockCustody
    let policy: NativeCertificateClockPolicy
    var expires: ContinuousClock.Instant { custody.start.advanced(by: .milliseconds(policy.ageMilliseconds)) }
    private let lock = NSLock()
    private var phase = NativeCertificateClockPhase.requesting
    private var previousElapsed: Int64 = 0, previousWall: Int64
    private var lease: NativeCertificateClockLease?
    private var response: NativeCertificateClockFile?
    private var failure: NativeCertificateClockError?
    var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }

    init(_ custody: NativeCertificateClockCustody) throws {
        self.custody = custody; policy = try NativeCertificateClockPolicy.decode(custody.policy.bytes)
        previousWall = custody.wall
        try custody.check()
    }
    static func wallMilliseconds() throws -> Int64 {
        let value = Date().timeIntervalSince1970 * 1000
        guard value.isFinite, value >= 0, value <= 253_402_300_799_000 else { throw NativeCertificateClockError.clockUnavailable }
        return Int64(value.rounded(.down))
    }
    static func elapsed(_ start: ContinuousClock.Instant, to now: ContinuousClock.Instant) throws -> (low: Int64, high: Int64) {
        guard now >= start else { throw NativeCertificateClockError.clockUnavailable }
        let d = start.duration(to: now).components
        guard d.seconds <= 600 else { throw NativeCertificateClockError.expired }
        let floor = d.seconds * 1000 + d.attoseconds / 1_000_000_000_000_000
        return (floor, floor + (d.attoseconds % 1_000_000_000_000_000 == 0 ? 0 : 1))
    }
    func withdraw(_ error: NativeCertificateClockError = .clockUnavailable) {
        lock.lock(); defer { lock.unlock() }
        phase = .withdrawn; failure = error; lease = nil
    }
    func status(busy: Bool = false) -> NativeCertificateClockStatus {
        lock.lock(); defer { lock.unlock() }
        let elapsed = try? Self.elapsed(custody.start, to: .now).low
        let limit = phase == .requesting ? policy.responseMilliseconds : policy.ageMilliseconds
        if phase != .withdrawn, elapsed == nil || elapsed! >= limit { phase = .withdrawn; failure = .expired; lease = nil }
        return NativeCertificateClockStatus(phase: phase, source: policy.source, procedure: policy.procedure,
            requestDigest: custody.digest, requestURL: custody.request.url,
            remainingMilliseconds: phase == .withdrawn ? nil : max(0, limit - (elapsed ?? limit)), busy: busy, error: failure)
    }
    // This state transition consumes metadata only. Production always samples
    // real wall/continuous coordinates inside its lock; fixtures cannot grant UTC.
    func observe(elapsed: Int64, wall: Int64) throws {
        lock.lock(); defer { lock.unlock() }; try observeLocked(elapsed: elapsed, wall: wall)
    }
    private func observeLocked(elapsed: Int64, wall: Int64) throws {
        guard phase != .withdrawn else { throw failure ?? .clockUnavailable }
        do {
            let limit = phase == .requesting ? policy.responseMilliseconds : policy.ageMilliseconds
            guard elapsed >= previousElapsed, wall >= previousWall else { throw NativeCertificateClockError.clockUnavailable }
            guard elapsed < limit else { throw NativeCertificateClockError.expired }
            let (wholeWall, overflow) = wall.subtractingReportingOverflow(custody.wall)
            guard !overflow,
                  NativeCertificateClockWire.continuityAllowed(policy: policy, wallElapsed: wholeWall, continuousElapsed: elapsed),
                  NativeCertificateClockWire.continuityAllowed(policy: policy, wallElapsed: wall - previousWall,
                    continuousElapsed: elapsed - previousElapsed) else { throw NativeCertificateClockError.clockUnavailable }
            previousElapsed = elapsed; previousWall = wall
        } catch {
            phase = .withdrawn; failure = error as? NativeCertificateClockError ?? .clockUnavailable; lease = nil
            throw failure!
        }
    }
    private func sampled() throws -> (instant: ContinuousClock.Instant, low: Int64, high: Int64) {
        lock.lock(); defer { lock.unlock() }
        let instant = ContinuousClock.now, n = try Self.elapsed(custody.start, to: instant)
        try observeLocked(elapsed: n.low, wall: Self.wallMilliseconds())
        return (instant, n.low, n.high)
    }
    func check() throws {
        do {
            _ = try sampled()
            try custody.check()
            lock.lock(); let response = self.response; lock.unlock()
            try response?.check()
            _ = try sampled()
        } catch {
            let error = error as? NativeCertificateClockError ?? .custodyConflict
            withdraw(error); throw error
        }
    }
    func accept(_ url: URL, digest: String, check: () throws -> Void) throws {
        // A stale UI original has no permission to consume another challenge.
        guard digest == custody.digest else { throw NativeCertificateClockError.scopeConflict }
        try self.check()
        lock.lock(); let already = response; lock.unlock()
        do {
            try check()
            guard url.isFileURL else { throw NativeCertificateClockError.custodyConflict }
            let directory = try NativeCertificateClockDirectory(url.deletingLastPathComponent(), temporaryFixture: custody.root.temporaryFixture)
            let input = try NativeCertificateClockFile(directory: directory, name: url.lastPathComponent)
            if let already {
                guard input.bytes == already.bytes else { throw NativeCertificateClockError.scopeConflict }
                try input.check(); try self.check(); try check()
                return
            }
            let before = try sampled()
            _ = try NativeCertificateClockLease(policy: custody.policy.bytes, request: custody.request.bytes,
                package: input.bytes, responseElapsed: before.high)
            try input.check(); try self.check(); try check()
            let published = try NativeCertificateClockFile.publish(input.bytes, directory: custody.request.directory, name: "response.json") {
                try check(); try input.check(); try self.check()
            }
            try published.check(); try self.check(); try check()
            let receipt = try sampled()
            let lease = try NativeCertificateClockLease(policy: custody.policy.bytes, request: custody.request.bytes,
                package: published.bytes, responseElapsed: receipt.high)
            lock.lock(); defer { lock.unlock() }
            guard phase == .requesting else { throw failure ?? .clockUnavailable }
            phase = .qualified; self.lease = lease; response = published
        } catch {
            if already == nil { withdraw(error as? NativeCertificateClockError ?? .custodyConflict) }
            throw error
        }
    }
    func sample() throws -> NativeControllerCertificateClock.SourceSample {
        do { return try projection() }
        catch {
            let error = error as? NativeCertificateClockError ?? .clockUnavailable
            withdraw(error); throw error
        }
    }
    private func projection() throws -> NativeControllerCertificateClock.SourceSample {
        try check()
        lock.lock(); let lease = self.lease, response = self.response; lock.unlock()
        guard let lease, let response else { throw NativeCertificateClockError.clockUnavailable }
        let sampled = try sampled()
        // The outward receipt coordinate can be one millisecond beyond the
        // floor of the first current coordinate. Clamp only that lower point.
        let low: NativeCertificateClockInterval
        do { low = try lease.bounds(elapsed: sampled.low) }
        catch NativeCertificateClockError.clockUnavailable { low = try lease.bounds(elapsed: sampled.high) }
        let high = try lease.bounds(elapsed: sampled.high)
        guard low.earliest >= 1, high.latest < 253_402_300_799_000 else { withdraw(); throw NativeCertificateClockError.clockUnavailable }
        let result = NativeControllerCertificateClock.SourceSample(earliest: low.earliest - 1, latest: high.latest + 1,
            observed: sampled.instant, driftPPM: policy.driftPPM)
        try response.check(); try check()
        return result
    }
}
