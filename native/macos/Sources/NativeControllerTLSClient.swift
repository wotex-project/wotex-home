import Foundation
import Network
import Security
import CryptoKit

enum NativeControllerTLSError: String, Error, Sendable {
    case invalidRecord, invalidTrust, tlsClockUncertain, tlsPeerUnverified
    case tlsPinChanged, tlsHandshakeTimeout, tlsConnectionUnavailable
    case tlsClientInterfaceRequired, cancelled, outcomeUnknown
}

// Optional bounded diagnostics for host checks. Never retain a platform error
// object, certificate, address, invitation or application bytes. This cell
// cannot alter validation or the public outcome, and production supplies none.
final class NativeControllerTLSDiagnostics: @unchecked Sendable, CustomReflectable {
    enum Stage: String, Sendable {
        case preparing, policies, anchors, anchorsOnly, networkFetch, verificationDate
        case trustEvaluation, certificateChain, subjectAltName, pin, clock
        case handshake, negotiatedVersion, recheck, application
    }
    private let lock = NSLock()
    private var stage: Stage = .preparing
    private var status: Int?
    var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
    func record(_ stage: Stage, status: Int? = nil) {
        lock.lock(); defer { lock.unlock() }
        self.stage = stage; self.status = status
    }
    func snapshot() -> (Stage, Int?) {
        lock.lock(); defer { lock.unlock() }
        return (stage, status)
    }
}

// Trusted host input, never a remote API field or a Home clock qualification.
// Additional uncertainty checks cannot replace normal system-time validation.
struct NativeControllerCertificateClock: Sendable {
    private let earliest: Int64
    private let latest: Int64
    private let observed: ContinuousClock.Instant
    private let expires: ContinuousClock.Instant
    init(earliest: Int64, latest: Int64, leaseMilliseconds: Int64 = 15_000) throws {
        guard earliest >= 0, earliest <= latest, latest <= 253_402_300_799_000,
              (1...15_000).contains(leaseMilliseconds) else { throw NativeControllerTLSError.tlsClockUncertain }
        self.earliest = earliest; self.latest = latest
        observed = ContinuousClock.now
        expires = observed.advanced(by: .milliseconds(leaseMilliseconds))
    }
    func bounds() throws -> (Date, Date) {
        let now = ContinuousClock.now
        guard now >= observed, now < expires else { throw NativeControllerTLSError.tlsClockUncertain }
        let duration = observed.duration(to: now).components
        let elapsed = duration.seconds * 1000 + duration.attoseconds / 1_000_000_000_000_000
        guard latest + elapsed <= 253_402_300_799_000 else { throw NativeControllerTLSError.tlsClockUncertain }
        return (Date(timeIntervalSince1970: Double(earliest + elapsed) / 1000),
                Date(timeIntervalSince1970: Double(latest + elapsed) / 1000))
    }
}

// An additional refusal boundary, never a credential/authorization seal.
// Actual signed session composition supplies its own production custody check.
struct NativeControllerExchangeGuard: Sendable, CustomReflectable {
    enum Phase: String, Sendable { case opening, sending, delivering, decoded }
    private let check: @Sendable (Phase) throws -> Void
    init(_ check: @escaping @Sendable (Phase) throws -> Void) { self.check = check }
    var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }

    func validate(_ phase: Phase, until deadline: ContinuousClock.Instant) async throws {
        let owner = ControllerGuardCheck(check: check, phase: phase, deadline: deadline)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { owner.start($0) }
        } onCancel: { owner.cancel() }
    }
}

// Platform custody/file work cannot occupy the deadline/cancellation executor.
// A late result contains only a Boolean and cannot reopen or publish anything.
private final class ControllerGuardCheck: @unchecked Sendable, CustomReflectable {
    private let queue = DispatchQueue(label: "home.controller.guard.owner")
    private let work = DispatchQueue(label: "home.controller.guard.platform")
    private var check: (@Sendable (NativeControllerExchangeGuard.Phase) throws -> Void)?
    private let phase: NativeControllerExchangeGuard.Phase
    private let deadline: ContinuousClock.Instant
    private var continuation: CheckedContinuation<Void, any Error>?
    private var timer: DispatchSourceTimer?
    private var stopped = false
    private var cancelled = false
    var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
    init(check: @escaping @Sendable (NativeControllerExchangeGuard.Phase) throws -> Void,
         phase: NativeControllerExchangeGuard.Phase, deadline: ContinuousClock.Instant) {
        self.check = check; self.phase = phase; self.deadline = deadline
    }
    func start(_ continuation: CheckedContinuation<Void, any Error>) {
        queue.async { [self] in
            self.continuation = continuation
            guard !cancelled, ContinuousClock.now < deadline, let check else { finish(.outcomeUnknown); return }
            // Short continuous-time checks also refuse promptly after host wake;
            // DispatchTime alone would grant another awake-only interval.
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + .milliseconds(50), repeating: .milliseconds(50))
            timer.setEventHandler { [weak self] in
                guard let self, !stopped, ContinuousClock.now >= deadline else { return }
                finish(.outcomeUnknown)
            }
            self.timer = timer; timer.resume()
            let phase = self.phase
            work.async { [weak self] in
                let refused: Bool
                do { try check(phase); refused = false } catch { refused = true }
                self?.queue.async { [weak self] in
                    guard let self, !stopped else { return }
                    guard !cancelled, ContinuousClock.now < deadline else { finish(.outcomeUnknown); return }
                    finish(refused ? .invalidRecord : nil)
                }
            }
        }
    }
    func cancel() {
        queue.async { [self] in
            cancelled = true
            if continuation != nil { finish(.outcomeUnknown) }
        }
    }
    private func finish(_ error: NativeControllerTLSError?) {
        guard !stopped else { return }
        stopped = true; check = nil
        timer?.cancel(); timer = nil
        let callback = continuation; continuation = nil
        if let error { callback?.resume(throwing: error) } else { callback?.resume() }
    }
}

enum NativeControllerTLSClient {
    // One exchange; no automatic retry, Store provisioning or Keychain write.
    static func bootstrap(_ invitation: NativeControllerInvitation, request: NativeControllerBootstrapRequest,
                          clock: NativeControllerCertificateClock, approvedAccess: NativeControllerAccess = .initial,
                          diagnostics: NativeControllerTLSDiagnostics? = nil) async throws -> NativeControllerBootstrapResponse {
        let frame: Data
        do {
            _ = try NativeControllerPairingWire.encode(invitation)
            frame = try NativeControllerPairingWire.frame(request)
        } catch { throw NativeControllerTLSError.invalidRecord }
        guard NativeControllerPairingWire.access(approvedAccess), invitation.controller == request.controller,
              invitation.invitation == request.invitation, invitation.bootstrapSecret == request.bootstrapSecret else { throw NativeControllerTLSError.invalidRecord }
        let peer = try NativeControllerPeer(invitation: invitation)
        let operation = ControllerTLSExchange(peer: peer, frame: frame, clock: clock,
            maximumResponse: NativeControllerPairingWire.maximumBytes, requestMilliseconds: 5_000, diagnostics: diagnostics) { bytes in
                try NativeControllerPairingWire.verifyResponse(bytes, request: request, approvedAccess: approvedAccess)
            }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { operation.start($0) }
        } onCancel: { operation.cancel() }
    }

    // Byte transport for already constructed ordinary API requests. Semantic
    // input/envelope/receipt validation remains in the shared native API codec.
    // This method cannot recover a credential or select a fallback controller.
    static func request(_ peer: NativeControllerPeer, body: Data,
                        clock: NativeControllerCertificateClock,
                        budget: NativeControllerRequestBudget = .ordinary,
                        diagnostics: NativeControllerTLSDiagnostics? = nil,
                        exchangeGuard: NativeControllerExchangeGuard? = nil) async throws -> Data {
        try await request(peer, body: body, clock: clock, budget: budget, diagnostics: diagnostics,
            exchangeGuard: exchangeGuard, validateResponse: { $0 })
    }

    // The bounded native envelope decoder runs under the same request deadline.
    // A verified refusal may be a value; malformed data must throw and remain
    // unknown after send. No validator may introduce I/O, retries or custody.
    static func request<Response: Sendable>(_ peer: NativeControllerPeer, body: Data,
                        clock: NativeControllerCertificateClock,
                        budget: NativeControllerRequestBudget = .ordinary,
                        diagnostics: NativeControllerTLSDiagnostics? = nil,
                        exchangeGuard: NativeControllerExchangeGuard? = nil,
                        validateResponse: @escaping @Sendable (Data) throws -> Response) async throws -> Response {
        guard NativeControllerPairingWire.peer(peer), (1...65_536).contains(body.count) else {
            throw NativeControllerTLSError.invalidRecord
        }
        let size = UInt32(body.count)
        let frame = Data([UInt8(size >> 24), UInt8((size >> 16) & 255), UInt8((size >> 8) & 255), UInt8(size & 255)]) + body
        let operation = ControllerTLSExchange(peer: peer, frame: frame, clock: clock,
            maximumResponse: 1_048_576, requestMilliseconds: budget.rawValue,
            diagnostics: diagnostics, exchangeGuard: exchangeGuard, validate: validateResponse)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { operation.start($0) }
        } onCancel: { operation.cancel() }
    }
}

enum NativeControllerRequestBudget: Int64, Sendable { case ordinary = 5_000, review = 10_000 }

// This cell contains only a closed public error. TLS callbacks and connection
// events use different queues; NSLock is the entire shared-state boundary.
private final class ControllerTLSFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var value: NativeControllerTLSError?
    func set(_ error: NativeControllerTLSError) { lock.lock(); defer { lock.unlock() }; value = error }
    func get() -> NativeControllerTLSError? { lock.lock(); defer { lock.unlock() }; return value }
}

// SecTrust and all certificate operations belong exclusively to trustQueue.
// This object receives only public trust + clock, never a secret or bearer.
private final class ControllerTLSVerification: @unchecked Sendable {
    let queue = DispatchQueue(label: "home.controller.tls.verify")
    let failure = ControllerTLSFailure()
    private let identity: NativeControllerAddress
    private let pin: String
    private let anchorBytes: Data
    private let clock: NativeControllerCertificateClock
    private let diagnostics: NativeControllerTLSDiagnostics?
    private var anchor: SecCertificate?
    private var peer: SecTrust?

    init(peer: NativeControllerPeer, clock: NativeControllerCertificateClock, diagnostics: NativeControllerTLSDiagnostics?) {
        identity = peer.identity; pin = peer.leafPin
        anchorBytes = peer.trustAnchor; self.clock = clock
        self.diagnostics = diagnostics
    }

    func prepare(_ completion: @escaping @Sendable (NativeControllerTLSError?) -> Void) {
        queue.async { [self] in
            do {
                _ = try clock.bounds()
                guard let certificate = SecCertificateCreateWithData(nil, anchorBytes as CFData),
                      SecCertificateCopyData(certificate) as Data == anchorBytes else { throw NativeControllerTLSError.invalidTrust }
                try cover(certificate)
                anchor = certificate
                completion(nil)
            } catch { completion(error as? NativeControllerTLSError ?? .invalidTrust) }
        }
    }

    func install(on options: sec_protocol_options_t) {
        sec_protocol_options_set_verify_block(options, { [self] _, supplied, complete in
            do {
                let trust = sec_trust_copy_ref(supplied).takeRetainedValue()
                guard let anchor else { throw NativeControllerTLSError.invalidTrust }
                try require(.policies, SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, identity.value as CFString)))
                try require(.anchors, SecTrustSetAnchorCertificates(trust, [anchor] as CFArray))
                try require(.anchorsOnly, SecTrustSetAnchorCertificatesOnly(trust, true))
                try require(.networkFetch, SecTrustSetNetworkFetchAllowed(trust, false))
                try validate(trust)
                peer = trust
                complete(true)
            } catch {
                failure.set(error as? NativeControllerTLSError ?? .tlsPeerUnverified)
                complete(false)
            }
        }, queue)
    }

    func recheck(_ completion: @escaping @Sendable (NativeControllerTLSError?) -> Void) {
        queue.async { [self] in
            do {
                guard let peer else { throw NativeControllerTLSError.tlsPeerUnverified }
                try validate(peer)
                completion(nil)
            } catch { completion(error as? NativeControllerTLSError ?? .tlsPeerUnverified) }
        }
    }

    private func validate(_ trust: SecTrust) throws {
        // Always evaluate at normal platform wall time first. A trusted interval
        // cannot backdate an expired peer into acceptance or bypass PKIX errors.
        try require(.verificationDate, SecTrustSetVerifyDate(trust, Date() as CFDate))
        diagnostics?.record(.trustEvaluation)
        var error: CFError?
        guard SecTrustEvaluateWithError(trust, &error) else {
            diagnostics?.record(.trustEvaluation, status: error.map { CFErrorGetCode($0) })
            throw NativeControllerTLSError.tlsPeerUnverified
        }
        diagnostics?.record(.certificateChain)
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              (1...5).contains(chain.count), let leaf = chain.first else { throw NativeControllerTLSError.tlsPeerUnverified }
        diagnostics?.record(.subjectAltName)
        guard let values = SecCertificateCopyValues(leaf, [kSecOIDSubjectAltName] as CFArray, nil) as? [String: Any],
              values[kSecOIDSubjectAltName as String] != nil else { throw NativeControllerTLSError.tlsPeerUnverified }
        diagnostics?.record(.pin)
        let digest = SHA256.hash(data: SecCertificateCopyData(leaf) as Data).map { String(format: "%02x", $0) }.joined()
        guard digest == pin else { throw NativeControllerTLSError.tlsPinChanged }
        for certificate in chain { try cover(certificate) }
        guard let anchor else { throw NativeControllerTLSError.invalidTrust }
        try cover(anchor)
    }

    private func cover(_ certificate: SecCertificate) throws {
        diagnostics?.record(.clock)
        let (first, last) = try clock.bounds()
        guard let values = SecCertificateCopyValues(certificate,
            [kSecOIDX509V1ValidityNotBefore, kSecOIDX509V1ValidityNotAfter] as CFArray, nil) as? [String: Any],
              let lower = date(values[kSecOIDX509V1ValidityNotBefore as String]),
              let upper = date(values[kSecOIDX509V1ValidityNotAfter as String]),
              lower <= first, last <= upper, lower <= upper else { throw NativeControllerTLSError.tlsClockUncertain }
    }

    private func require(_ stage: NativeControllerTLSDiagnostics.Stage, _ status: OSStatus) throws {
        diagnostics?.record(stage, status: Int(status))
        guard status == errSecSuccess else { throw NativeControllerTLSError.tlsPeerUnverified }
    }

    private func date(_ field: Any?) -> Date? {
        guard let field = field as? [String: Any], let type = field[kSecPropertyKeyType as String] as? String,
              type == kSecPropertyTypeDate as String || type == kSecPropertyTypeNumber as String else { return nil }
        if let date = field[kSecPropertyKeyValue as String] as? Date { return date }
        // Security's date property uses CFAbsoluteTime (the 2001 epoch).
        if let number = field[kSecPropertyKeyValue as String] as? NSNumber,
           CFGetTypeID(number) == CFNumberGetTypeID(), number.doubleValue.isFinite {
            return Date(timeIntervalSinceReferenceDate: number.doubleValue)
        }
        return nil
    }
}

// All connection, phase, timer, buffers and continuation mutations occur on
// queue. Trust work uses a separate queue so a blocked platform trust service
// cannot stop this owner from cancelling its socket at the absolute deadline.
private final class ControllerTLSExchange<Response: Sendable>: @unchecked Sendable, CustomReflectable {
    private let queue = DispatchQueue(label: "home.controller.tls.exchange")
    private let verifier: ControllerTLSVerification
    private let endpoint: NativeControllerAddress
    private let identity: NativeControllerAddress
    private let port: Int64
    private var frame: Data
    private let maximumResponse: Int
    private let requestMilliseconds: Int64
    private var validate: (@Sendable (Data) throws -> Response)?
    private let clock: NativeControllerCertificateClock
    private let diagnostics: NativeControllerTLSDiagnostics?
    private var exchangeGuard: NativeControllerExchangeGuard?
    private var guardTask: Task<Void, Never>?
    private var connection: NWConnection?
    private var continuation: CheckedContinuation<Response, any Error>?
    private var timer: DispatchSourceTimer?
    private var deadline = ContinuousClock.now
    private var checking = false
    private var sent = false
    private var finished = false
    private var cancelled = false
    private var received = Data()
    private var expected = 4
    private var readingHeader = true
    var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }

    init(peer: NativeControllerPeer, frame: Data, clock: NativeControllerCertificateClock,
         maximumResponse: Int, requestMilliseconds: Int64,
         diagnostics: NativeControllerTLSDiagnostics?,
         exchangeGuard: NativeControllerExchangeGuard? = nil,
         validate: @escaping @Sendable (Data) throws -> Response) {
        verifier = .init(peer: peer, clock: clock, diagnostics: diagnostics)
        endpoint = peer.endpoint; identity = peer.identity; port = peer.port
        self.frame = frame; self.clock = clock; self.maximumResponse = maximumResponse
        self.requestMilliseconds = requestMilliseconds; self.validate = validate
        self.diagnostics = diagnostics
        self.exchangeGuard = exchangeGuard
    }

    func start(_ continuation: CheckedContinuation<Response, any Error>) {
        queue.async { [self] in
            self.continuation = continuation
            guard !cancelled else { finish(.failure(.cancelled)); return }
            armDeadline(milliseconds: 5_000)
            checked(.opening) { [self] in
                verifier.prepare { [self] error in
                    queue.async { [self] in
                        guard live() else { return }
                        if let error { finish(.failure(error)); return }
                        connect()
                    }
                }
            }
        }
    }

    private func checked(_ phase: NativeControllerExchangeGuard.Phase, then complete: @escaping @Sendable () -> Void) {
        guard let exchangeGuard else { complete(); return }
        let originalDeadline = deadline
        guardTask = Task.detached { [self] in
            let refused: Bool
            do { try await exchangeGuard.validate(phase, until: originalDeadline); refused = false }
            catch { refused = true }
            queue.async { [self] in
                guardTask = nil
                guard live() else { return }
                if refused { finish(.failure(sent ? .outcomeUnknown : .invalidRecord)); return }
                complete()
            }
        }
    }

    func cancel() {
        queue.async { [self] in
            cancelled = true
            if continuation != nil { finish(.failure(sent ? .outcomeUnknown : .cancelled)) }
        }
    }

    private func connect() {
        if endpoint.kind == "ipv6", let prefix = UInt16(endpoint.value.prefix(4), radix: 16),
           (0xfe80...0xfebf).contains(prefix) { finish(.failure(.tlsClientInterfaceRequired)); return }
        guard let port = NWEndpoint.Port(rawValue: UInt16(port)) else { finish(.failure(.invalidRecord)); return }
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv13)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv13)
        sec_protocol_options_set_tls_resumption_enabled(options, false)
        sec_protocol_options_set_tls_false_start_enabled(options, false)
        sec_protocol_options_set_peer_authentication_required(options, true)
        if identity.kind == "dns" { identity.value.withCString { sec_protocol_options_set_tls_server_name(options, $0) } }
        verifier.install(on: options)
        let connection = NWConnection(host: NWEndpoint.Host(endpoint.value), port: port,
            using: NWParameters(tls: tls, tcp: NWProtocolTCP.Options()))
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in self?.state(state) }
        connection.start(queue: queue)
    }

    private func state(_ state: NWConnection.State) {
        guard live() else { return }
        switch state {
        case .ready:
            diagnostics?.record(.negotiatedVersion)
            guard !checking, !sent, let connection,
                  let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata,
                  sec_protocol_metadata_get_negotiated_tls_protocol_version(metadata.securityProtocolMetadata) == .TLSv13 else {
                if !checking && !sent { finish(.failure(.tlsPeerUnverified)) }
                return
            }
            checking = true
            diagnostics?.record(.recheck)
            verifier.recheck { [self] error in
                queue.async { [self] in
                    guard live() else { return }
                    if let error { finish(.failure(error)); return }
                    checked(.sending) { [self] in
                        guard live() else { return }
                        do { _ = try clock.bounds() } catch { finish(.failure(.tlsClockUncertain)); return }
                        armDeadline(milliseconds: requestMilliseconds)
                        sent = true // A queued send may have escaped; never retry it.
                        diagnostics?.record(.application)
                        connection.send(content: frame, completion: .contentProcessed { [self] error in
                            guard live() else { return }
                            if error != nil { finish(.failure(.outcomeUnknown)); return }
                            receive()
                        })
                        frame.removeAll(keepingCapacity: false)
                    }
                }
            }
        case .failed(let error), .waiting(let error):
            let reason: NativeControllerTLSError
            if sent { reason = .outcomeUnknown }
            else if let failure = verifier.failure.get() { reason = failure }
            else if case .tls(let status) = error {
                diagnostics?.record(.handshake, status: Int(status))
                reason = .tlsPeerUnverified
            }
            else { reason = .tlsConnectionUnavailable }
            finish(.failure(reason))
        case .cancelled: finish(.failure(sent ? .outcomeUnknown : .cancelled))
        default: break
        }
    }

    private func receive() {
        guard live(), let connection else { return }
        let needed = expected - received.count
        connection.receive(minimumIncompleteLength: needed, maximumLength: needed) { [self] data, _, complete, error in
            guard live() else { return }
            guard error == nil, let data, !data.isEmpty, data.count <= needed else { finish(.failure(.outcomeUnknown)); return }
            received.append(data)
            if received.count < expected {
                if complete { finish(.failure(.outcomeUnknown)) }
                else { receive() }
                return
            }
            do {
                if readingHeader {
                    let size = received.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                    guard (1...UInt32(maximumResponse)).contains(size) else { throw NativeControllerTLSError.outcomeUnknown }
                    expected = Int(size); readingHeader = false
                    received.removeAll(keepingCapacity: false); received.reserveCapacity(expected)
                    receive()
                } else {
                    guard let validate else { throw NativeControllerTLSError.outcomeUnknown }
                    let response = try validate(received)
                    guard live() else { return }
                    checked(.delivering) { [self] in
                        guard live() else { return }
                        finish(.success(response))
                    }
                }
            } catch { finish(.failure(.outcomeUnknown)) }
        }
    }

    private func armDeadline(milliseconds: Int64) {
        timer?.cancel()
        deadline = ContinuousClock.now.advanced(by: .milliseconds(milliseconds))
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(Int(milliseconds)))
        timer.setEventHandler { [weak self] in
            guard let self, !finished else { return }
            finish(.failure(sent ? .outcomeUnknown : .tlsHandshakeTimeout))
        }
        self.timer = timer
        timer.resume()
    }

    private func live() -> Bool {
        guard !finished else { return false }
        guard ContinuousClock.now < deadline else { finish(.failure(sent ? .outcomeUnknown : .tlsHandshakeTimeout)); return false }
        return true
    }

    private func finish(_ result: Result<Response, NativeControllerTLSError>) {
        guard !finished else { return }
        finished = true
        timer?.cancel(); timer = nil
        guardTask?.cancel(); guardTask = nil; exchangeGuard = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel(); connection = nil
        frame.removeAll(keepingCapacity: false)
        received.removeAll(keepingCapacity: false)
        validate = nil
        let callback = continuation; continuation = nil
        switch result {
        case .success(let value): callback?.resume(returning: value)
        case .failure(let error): callback?.resume(throwing: error)
        }
    }
}
