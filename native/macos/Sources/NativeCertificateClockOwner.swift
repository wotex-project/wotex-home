import Foundation

// One aggregate operation slot, including an expired/cancelled worker that is
// still retiring. An observation timeout cannot make another worker admissible.
final class CertificateClockOperations: @unchecked Sendable {
    static let shared = CertificateClockOperations()
    private let lock = NSLock()
    private var token: UUID?, allowed = false
    func reserve() throws -> UUID {
        lock.lock(); defer { lock.unlock() }
        guard token == nil else { throw NativeCertificateClockError.capacity }
        let next = UUID(); token = next; allowed = true; return next
    }
    func check(_ expected: UUID, until deadline: ContinuousClock.Instant) throws {
        lock.lock(); defer { lock.unlock() }
        guard token == expected, allowed, ContinuousClock.now < deadline else { throw NativeCertificateClockError.expired }
    }
    func invalidate(_ expected: UUID) { lock.lock(); defer { lock.unlock() }; if token == expected { allowed = false } }
    func retire(_ expected: UUID) { lock.lock(); defer { lock.unlock() }; if token == expected { token = nil; allowed = false } }
}

// Deadline/cancellation and platform work have independent executors. The
// retirement callback runs only when no worker was scheduled or it actually ends.
final class NativeCertificateClockJob<Value: Sendable>: @unchecked Sendable {
    private let queue = DispatchQueue(label: "home.certificate.clock.deadline")
    private let work = DispatchQueue(label: "home.certificate.clock.platform")
    private let deadline: ContinuousClock.Instant
    private let invalidated: @Sendable () -> Void, retired: @Sendable () -> Void
    private var callback: CheckedContinuation<Value, any Error>?
    private var timer: DispatchSourceTimer?
    private var cancelled = false, ended = false
    init(deadline: ContinuousClock.Instant, invalidated: @escaping @Sendable () -> Void,
         retired: @escaping @Sendable () -> Void) {
        self.deadline = deadline; self.invalidated = invalidated; self.retired = retired
    }
    func run(_ operation: @escaping @Sendable () throws -> Value) async throws -> Value {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    callback = continuation
                    guard !cancelled, ContinuousClock.now < deadline else { invalidated(); retired(); finish(.failure(NativeCertificateClockError.expired)); return }
                    let timer = DispatchSource.makeTimerSource(queue: queue)
                    timer.schedule(deadline: .now() + .milliseconds(25), repeating: .milliseconds(25))
                    timer.setEventHandler { [weak self] in
                        guard let self, !ended, ContinuousClock.now >= deadline else { return }
                        invalidated(); finish(.failure(NativeCertificateClockError.expired))
                    }
                    self.timer = timer; timer.resume()
                    work.async { [self] in
                        let result: Result<Value, any Error>
                        do { result = .success(try operation()) } catch { result = .failure(error) }
                        retired()
                        queue.async { [self] in
                            guard !ended else { return }
                            guard !cancelled, ContinuousClock.now < deadline else { invalidated(); finish(.failure(NativeCertificateClockError.expired)); return }
                            finish(result)
                        }
                    }
                }
            }
        } onCancel: { self.cancel() }
    }
    func cancel() {
        invalidated()
        queue.async { [self] in
            cancelled = true
            if callback != nil { finish(.failure(NativeCertificateClockError.expired)) }
        }
    }
    private func finish(_ result: Result<Value, any Error>) {
        guard !ended else { return }; ended = true
        timer?.cancel(); timer = nil
        let callback = self.callback; self.callback = nil
        callback?.resume(with: result)
    }
}

// Only this parameterless production owner can install its private current
// source. There is no supplied directory, runtime, clock or signing backend.
final class NativeCertificateClockOwner: @unchecked Sendable, CustomReflectable {
    private let lock = NSLock()
    private let sampling = NSLock()
    private var generation: NativeCertificateClockGeneration?
    private var operation: UUID?
    private var operationAllowed = false, workerDone = false, delivered = false
    private var error: NativeCertificateClockError?
    private var timer: DispatchSourceTimer?
    var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
    init() {}
    deinit { timer?.cancel(); generation?.withdraw(); if let operation { CertificateClockOperations.shared.invalidate(operation) } }
    func status() -> NativeCertificateClockStatus {
        lock.lock(); let source = generation, busy = operation != nil, error = self.error; lock.unlock()
        if let source { return source.status(busy: busy) }
        return NativeCertificateClockStatus(phase: busy ? .requesting : (error == nil ? .unavailable : .withdrawn),
            source: nil, procedure: nil, requestDigest: nil, requestURL: nil, remainingMilliseconds: nil, busy: busy, error: error)
    }
    func withdraw() {
        lock.lock(); let source = generation, operation = self.operation; error = .clockUnavailable; operationAllowed = false
        timer?.cancel(); timer = nil; lock.unlock()
        if let operation { CertificateClockOperations.shared.invalidate(operation) }
        source?.withdraw()
    }
    func begin() async throws -> NativeCertificateClockStatus {
        guard !Task.isCancelled else { throw NativeCertificateClockError.expired }
        let token = try reserve(begin: true), deadline = ContinuousClock.now.advanced(by: .seconds(5))
        let job: NativeCertificateClockJob<NativeCertificateClockGeneration> = job(token, deadline: deadline)
        do {
            let source = try await job.run { [self] in
                try check(token, deadline: deadline)
                let runtime = try Self.runtime()
                try check(token, deadline: deadline)
                let root = try NativeCertificateClockDirectory.production()
                let custody = try NativeCertificateClockCustody.begin(root: root, runtime: runtime) { try self.check(token, deadline: deadline) }
                let source = try NativeCertificateClockGeneration(custody)
                guard try Self.runtime() == runtime else { throw NativeCertificateClockError.scopeConflict }
                try source.check(); try check(token, deadline: deadline)
                return source
            }
            guard !Task.isCancelled, ContinuousClock.now < deadline else { source.withdraw(); throw NativeCertificateClockError.expired }
            try complete(token, deadline: deadline, installing: source)
            startTimer(source)
            guard !Task.isCancelled else { withdraw(); throw NativeCertificateClockError.expired }
            return status()
        } catch {
            fail(token, error: error); throw error as? NativeCertificateClockError ?? .clockUnavailable
        }
    }
    func importResponse(_ url: URL, requestDigest: String) async throws -> NativeCertificateClockStatus {
        guard !Task.isCancelled else { throw NativeCertificateClockError.expired }
        let source = lock.withLock { generation }
        guard let source else { throw NativeCertificateClockError.clockUnavailable }
        guard requestDigest == source.custody.digest else { throw NativeCertificateClockError.scopeConflict }
        let token = try reserve(begin: false), deadline = ContinuousClock.now.advanced(by: .seconds(5))
        let job: NativeCertificateClockJob<Void> = job(token, deadline: deadline)
        do {
            try await job.run { [self] in
                try check(token, deadline: deadline)
                try validate(source)
                try source.accept(url, digest: requestDigest) { try self.check(token, deadline: deadline) }
                try validate(source); try check(token, deadline: deadline)
            }
            guard !Task.isCancelled, ContinuousClock.now < deadline else { source.withdraw(); throw NativeCertificateClockError.expired }
            try complete(token, deadline: deadline)
            guard !Task.isCancelled else { withdraw(); throw NativeCertificateClockError.expired }
            return status()
        } catch {
            fail(token, error: error); throw error as? NativeCertificateClockError ?? .clockUnavailable
        }
    }
    func clock() throws -> NativeControllerCertificateClock {
        lock.lock(); let source = generation, busy = operation != nil; lock.unlock()
        guard !busy, let source, source.status().phase == .qualified else { throw NativeCertificateClockError.clockUnavailable }
        try validate(source)
        return try NativeControllerCertificateClock(sourceExpiry: source.expires) { [weak self, weak source] in
            guard let self, let source else { throw NativeCertificateClockError.clockUnavailable }
            try self.validate(source)
            let value = try source.sample()
            try self.validate(source)
            return value
        }
    }
    private static func runtime() throws -> String {
        let facts = try SignedSetupPeer.certificateClockSigningIdentity()
        return try NativeCertificateClockWire.runtime(team: facts.team, executable: facts.executable, bundle: facts.bundle)
    }
    private func validate(_ source: NativeCertificateClockGeneration) throws {
        // A stuck platform call retains this slot. Repeated requests can only
        // refuse capacity, rather than accumulating abandoned signing workers.
        guard sampling.try() else { throw NativeCertificateClockError.capacity }
        defer { sampling.unlock() }
        do {
            lock.lock(); let same = generation === source; lock.unlock()
            guard same, source.status().phase != .withdrawn else { throw NativeCertificateClockError.clockUnavailable }
            guard try Self.runtime() == source.policy.runtime else { throw NativeCertificateClockError.scopeConflict }
            try source.check()
            guard try Self.runtime() == source.policy.runtime else { throw NativeCertificateClockError.scopeConflict }
            lock.lock(); let repeated = generation === source; lock.unlock()
            guard repeated else { throw NativeCertificateClockError.clockUnavailable }
        } catch { source.withdraw(error as? NativeCertificateClockError ?? .clockUnavailable); throw error }
    }
    private func reserve(begin: Bool) throws -> UUID {
        lock.lock(); defer { lock.unlock() }
        guard operation == nil else { throw NativeCertificateClockError.capacity }
        if begin, let generation, [.requesting, .qualified].contains(generation.status().phase) { throw NativeCertificateClockError.capacity }
        if !begin, generation == nil { throw NativeCertificateClockError.clockUnavailable }
        let token = try CertificateClockOperations.shared.reserve()
        operation = token; operationAllowed = true; workerDone = false; delivered = false; error = nil; return token
    }
    private func job<Value: Sendable>(_ token: UUID, deadline: ContinuousClock.Instant) -> NativeCertificateClockJob<Value> {
        NativeCertificateClockJob(deadline: deadline, invalidated: { [weak self] in self?.invalidate(token) },
            retired: { [weak self] in CertificateClockOperations.shared.retire(token); self?.workerRetired(token) })
    }
    private func workerRetired(_ token: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard operation == token else { return }
        workerDone = true
        if delivered { operation = nil; operationAllowed = false }
    }
    private func check(_ token: UUID, deadline: ContinuousClock.Instant) throws { try CertificateClockOperations.shared.check(token, until: deadline) }
    private func complete(_ token: UUID, deadline: ContinuousClock.Instant,
                          installing source: NativeCertificateClockGeneration? = nil) throws {
        lock.lock(); defer { lock.unlock() }
        guard operation == token, operationAllowed, !Task.isCancelled, ContinuousClock.now < deadline else {
            source?.withdraw(.expired); throw NativeCertificateClockError.expired
        }
        if let source { generation = source }
        error = nil; delivered = true; operationAllowed = false
        if workerDone { operation = nil }
    }
    private func invalidate(_ token: UUID) {
        CertificateClockOperations.shared.invalidate(token)
        lock.lock(); let current = operation == token, source = generation
        if current { operationAllowed = false }; lock.unlock()
        if current { source?.withdraw(.expired) }
    }
    private func fail(_ token: UUID, error: any Error) {
        CertificateClockOperations.shared.invalidate(token)
        lock.lock(); defer { lock.unlock() }
        if operation == token {
            operationAllowed = false; delivered = true; self.error = error as? NativeCertificateClockError ?? .clockUnavailable
            if workerDone { operation = nil }
        }
    }
    private func startTimer(_ source: NativeCertificateClockGeneration) {
        lock.lock(); defer { lock.unlock() }
        guard generation === source, source.status().phase != .withdrawn else { return }
        timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "home.certificate.clock.continuity"))
        timer.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            lock.lock(); let source = generation; lock.unlock()
            guard let source else { return }
            do { try source.check() } catch { source.withdraw(error as? NativeCertificateClockError ?? .clockUnavailable) }
        }
        self.timer = timer; timer.resume()
    }
}
