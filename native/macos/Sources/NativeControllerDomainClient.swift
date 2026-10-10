import Foundation

enum NativeControllerDomainClient {
    // This is a transport boundary, not a signed Keychain/current-session seal.
    // The caller supplies a fixed typed SDK operation and trusted host clock.
    static func perform<Value: Sendable>(_ peer: NativeControllerPeer, credential: Data,
        clock: @escaping @Sendable () throws -> NativeControllerCertificateClock,
        exchangeGuard: NativeControllerExchangeGuard? = nil,
        operation: @escaping @Sendable () throws -> Value) async throws -> Value {
        guard credential.count == 32, NativeControllerPairingWire.peer(peer),
              NativeDomainTransportScope.current == nil else { throw NativeControllerTLSError.invalidRecord }
        let bridge = ControllerDomainBridge(peer: peer, credential: credential, clock: clock, exchangeGuard: exchangeGuard)
        return try await withTaskCancellationHandler {
            let worker = Task.detached {
                try NativeDomainTransportScope.$current.withValue(bridge) {
                    do {
                        let value = try operation()
                        try bridge.complete()
                        return value
                    } catch {
                        try bridge.complete(error: error)
                        throw error
                    }
                }
            }
            let value = try await worker.value
            try await bridge.validateDelivery()
            // Cancellation may arrive after the worker's terminal check while
            // its owner is still awaiting delivery. Never publish that value.
            guard !Task.isCancelled else { throw NativeControllerTLSError.outcomeUnknown }
            try bridge.deliveryCurrent()
            return value
        } onCancel: { bridge.cancel() }
    }
}

// A private bounded rendezvous. The synchronous SDK worker and async network
// owner never wait on one another's executor. NSLock owns all mutable state.
private final class ControllerDomainReply: @unchecked Sendable, CustomReflectable {
    private let lock = NSLock()
    private let ready = DispatchSemaphore(value: 0)
    private var result: Result<Data, any Error>?
    private var task: Task<Void, Never>?
    private var stopped = false
    var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }

    func install(_ task: Task<Void, Never>) {
        lock.lock()
        if stopped { lock.unlock(); task.cancel(); return }
        self.task = task
        lock.unlock()
    }
    func publish(_ result: Result<Data, any Error>) {
        lock.lock()
        guard !stopped, self.result == nil else { lock.unlock(); return }
        self.result = result
        lock.unlock()
        ready.signal()
    }
    func stop() {
        lock.lock()
        stopped = true
        result = nil
        let task = self.task
        self.task = nil
        lock.unlock()
        task?.cancel()
        ready.signal()
    }
    func wait(until deadline: ContinuousClock.Instant) throws -> Data {
        // DispatchTime pauses during host sleep. Small waits recheck the
        // continuous deadline on wake rather than granting a new awake budget.
        while true {
            let remaining = ContinuousClock.now.duration(to: deadline).components
            let nanoseconds = remaining.seconds * 1_000_000_000 + remaining.attoseconds / 1_000_000_000
            guard nanoseconds > 0 else { throw NativeControllerTLSError.outcomeUnknown }
            if ready.wait(timeout: .now() + .nanoseconds(Int(min(nanoseconds, 50_000_000)))) == .success { break }
        }
        guard ContinuousClock.now < deadline else { throw NativeControllerTLSError.outcomeUnknown }
        lock.lock()
        let result = stopped ? nil : self.result
        self.result = nil
        self.task = nil
        lock.unlock()
        guard let result else { throw NativeControllerTLSError.outcomeUnknown }
        return try result.get()
    }
}

private final class ControllerDomainBridge: NativeDomainTransport, @unchecked Sendable, CustomReflectable {
    private let lock = NSLock()
    private let peer: NativeControllerPeer
    private var credential: Data
    private let clock: @Sendable () throws -> NativeControllerCertificateClock
    private let exchangeGuard: NativeControllerExchangeGuard?
    private var active: ControllerDomainReply?
    private var lastDeadline: ContinuousClock.Instant?
    private var stopped = false
    private var cancelled = false
    var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
    init(peer: NativeControllerPeer, credential: Data,
         clock: @escaping @Sendable () throws -> NativeControllerCertificateClock,
         exchangeGuard: NativeControllerExchangeGuard?) {
        self.peer = peer; self.credential = credential; self.clock = clock; self.exchangeGuard = exchangeGuard
    }

    func request(body: Data, allowNotFound: Bool) throws -> Data {
        let request = try NativeControllerAPIRequest(body: body, allowNotFound: allowNotFound)
        guard let object = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let encoded = object["credential"] as? String else { throw NativeControllerTLSError.invalidRecord }
        let requestedCredential = try OperatorCredential.decode(encoded)
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(5_000 + request.budget.rawValue))
        let reply = ControllerDomainReply()
        lock.lock()
        guard !stopped, !cancelled, active == nil, credential == requestedCredential else {
            let error: NativeControllerTLSError = cancelled ? .outcomeUnknown : .invalidRecord
            lock.unlock()
            throw error
        }
        active = reply; lastDeadline = deadline
        lock.unlock()
        defer {
            reply.stop()
            lock.lock()
            if active === reply { active = nil }
            lock.unlock()
        }
        let task = Task.detached { [peer, clock, exchangeGuard] in
            do {
                try Task.checkCancellation()
                let currentClock = try clock()
                guard ContinuousClock.now < deadline else { throw NativeControllerTLSError.outcomeUnknown }
                try Task.checkCancellation()
                let bytes = try await NativeControllerAPIClient.perform(peer, request: request, clock: currentClock,
                    exchangeGuard: exchangeGuard)
                guard ContinuousClock.now < deadline else { throw NativeControllerTLSError.outcomeUnknown }
                try Task.checkCancellation()
                reply.publish(.success(bytes))
            } catch {
                let failure: any Error
                if error is CancellationError { failure = NativeControllerTLSError.outcomeUnknown }
                else if error is NativeControllerTLSError || error is LocalHealthError { failure = error }
                else { failure = NativeControllerTLSError.tlsClockUncertain }
                reply.publish(.failure(failure))
            }
        }
        reply.install(task)
        return try reply.wait(until: deadline)
    }

    func cancel() {
        lock.lock()
        cancelled = true; stopped = true
        let reply = active
        credential = Data()
        lock.unlock()
        reply?.stop()
    }

    func deliveryCurrent() throws {
        _ = try deliveryDeadline()
    }

    func validateDelivery() async throws {
        let deadline = try deliveryDeadline()
        if let exchangeGuard {
            do { try await exchangeGuard.validate(.decoded, until: deadline) }
            catch { throw NativeControllerTLSError.outcomeUnknown }
        }
        try deliveryCurrent()
    }

    private func deliveryDeadline() throws -> ContinuousClock.Instant {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled, let deadline = lastDeadline, ContinuousClock.now < deadline else {
            throw NativeControllerTLSError.outcomeUnknown
        }
        return deadline
    }

    func complete(error: (any Error)? = nil) throws {
        lock.lock()
        let deadline = lastDeadline
        let uncertain = cancelled || active != nil || (deadline.map { ContinuousClock.now >= $0 } ?? false)
        stopped = true
        let reply = active
        credential = Data()
        lock.unlock()
        reply?.stop()
        if uncertain { throw NativeControllerTLSError.outcomeUnknown }
        if error == nil, deadline == nil { throw NativeControllerTLSError.invalidRecord }
        if let error = error as? LocalHealthError, case .invalidResponse = error {
            throw NativeControllerTLSError.outcomeUnknown
        }
    }
}
