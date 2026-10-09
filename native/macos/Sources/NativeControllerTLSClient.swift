import Foundation
import Network
import Security
import CryptoKit

enum NativeControllerTLSError: String, Error, Sendable {
    case invalidRecord, invalidTrust, tlsClockUncertain, tlsPeerUnverified
    case tlsPinChanged, tlsHandshakeTimeout, tlsConnectionUnavailable
    case tlsClientInterfaceRequired, cancelled, outcomeUnknown
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

enum NativeControllerTLSClient {
    // One exchange; no automatic retry, Store provisioning or Keychain write.
    static func bootstrap(_ invitation: NativeControllerInvitation, request: NativeControllerBootstrapRequest,
                          clock: NativeControllerCertificateClock, approvedAccess: NativeControllerAccess = .initial) async throws -> NativeControllerBootstrapResponse {
        let frame: Data
        do {
            _ = try NativeControllerPairingWire.encode(invitation)
            frame = try NativeControllerPairingWire.frame(request)
        } catch { throw NativeControllerTLSError.invalidRecord }
        guard NativeControllerPairingWire.access(approvedAccess), invitation.controller == request.controller,
              invitation.invitation == request.invitation, invitation.bootstrapSecret == request.bootstrapSecret else { throw NativeControllerTLSError.invalidRecord }
        let operation = ControllerTLSExchange(invitation: invitation, request: request, frame: frame,
            clock: clock, access: approvedAccess)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { operation.start($0) }
        } onCancel: { operation.cancel() }
    }
}

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
    private var anchor: SecCertificate?
    private var peer: SecTrust?

    init(invitation: NativeControllerInvitation, clock: NativeControllerCertificateClock) {
        identity = invitation.identity; pin = invitation.leafPin
        anchorBytes = invitation.trustAnchor; self.clock = clock
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
                guard let anchor,
                      SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, identity.value as CFString)) == errSecSuccess,
                      SecTrustSetAnchorCertificates(trust, [anchor] as CFArray) == errSecSuccess,
                      SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
                      SecTrustSetNetworkFetchAllowed(trust, false) == errSecSuccess else { throw NativeControllerTLSError.tlsPeerUnverified }
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
        guard SecTrustSetVerifyDate(trust, Date() as CFDate) == errSecSuccess,
              SecTrustEvaluateWithError(trust, nil),
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              (1...5).contains(chain.count), let leaf = chain.first,
              let values = SecCertificateCopyValues(leaf, [kSecOIDSubjectAltName] as CFArray, nil) as? [String: Any],
              values[kSecOIDSubjectAltName as String] != nil else { throw NativeControllerTLSError.tlsPeerUnverified }
        let digest = SHA256.hash(data: SecCertificateCopyData(leaf) as Data).map { String(format: "%02x", $0) }.joined()
        guard digest == pin else { throw NativeControllerTLSError.tlsPinChanged }
        for certificate in chain { try cover(certificate) }
        guard let anchor else { throw NativeControllerTLSError.invalidTrust }
        try cover(anchor)
    }

    private func cover(_ certificate: SecCertificate) throws {
        let (first, last) = try clock.bounds()
        guard let values = SecCertificateCopyValues(certificate,
            [kSecOIDX509V1ValidityNotBefore, kSecOIDX509V1ValidityNotAfter] as CFArray, nil) as? [String: Any],
              let lower = date(values[kSecOIDX509V1ValidityNotBefore as String]),
              let upper = date(values[kSecOIDX509V1ValidityNotAfter as String]),
              lower <= first, last <= upper, lower <= upper else { throw NativeControllerTLSError.tlsClockUncertain }
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
private final class ControllerTLSExchange: @unchecked Sendable {
    private let queue = DispatchQueue(label: "home.controller.tls.exchange")
    private let verifier: ControllerTLSVerification
    private let endpoint: NativeControllerAddress
    private let identity: NativeControllerAddress
    private let port: Int64
    private let request: NativeControllerBootstrapRequest
    private let frame: Data
    private let access: NativeControllerAccess
    private let clock: NativeControllerCertificateClock
    private var connection: NWConnection?
    private var continuation: CheckedContinuation<NativeControllerBootstrapResponse, any Error>?
    private var timer: DispatchSourceTimer?
    private var deadline = ContinuousClock.now
    private var checking = false
    private var sent = false
    private var finished = false
    private var cancelled = false

    init(invitation: NativeControllerInvitation, request: NativeControllerBootstrapRequest, frame: Data,
         clock: NativeControllerCertificateClock, access: NativeControllerAccess) {
        verifier = .init(invitation: invitation, clock: clock)
        endpoint = invitation.endpoint; identity = invitation.identity; port = invitation.port
        self.request = request; self.frame = frame; self.clock = clock; self.access = access
    }

    func start(_ continuation: CheckedContinuation<NativeControllerBootstrapResponse, any Error>) {
        queue.async { [self] in
            self.continuation = continuation
            guard !cancelled else { finish(.failure(.cancelled)); return }
            armDeadline()
            verifier.prepare { [self] error in
                queue.async { [self] in
                    guard live() else { return }
                    if let error { finish(.failure(error)); return }
                    connect()
                }
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
            guard !checking, !sent, let connection,
                  let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata,
                  sec_protocol_metadata_get_negotiated_tls_protocol_version(metadata.securityProtocolMetadata) == .TLSv13 else {
                if !checking && !sent { finish(.failure(.tlsPeerUnverified)) }
                return
            }
            checking = true
            verifier.recheck { [self] error in
                queue.async { [self] in
                    guard live() else { return }
                    if let error { finish(.failure(error)); return }
                    do { _ = try clock.bounds() } catch { finish(.failure(.tlsClockUncertain)); return }
                    armDeadline()
                    sent = true // A queued send may have escaped; never retry it.
                    connection.send(content: frame, completion: .contentProcessed { [self] error in
                        guard live() else { return }
                        if error != nil { finish(.failure(.outcomeUnknown)); return }
                        receive(4, buffer: Data(), header: true)
                    })
                }
            }
        case .failed(let error), .waiting(let error):
            let reason: NativeControllerTLSError
            if sent { reason = .outcomeUnknown }
            else if let failure = verifier.failure.get() { reason = failure }
            else if case .tls = error { reason = .tlsPeerUnverified }
            else { reason = .tlsConnectionUnavailable }
            finish(.failure(reason))
        case .cancelled: finish(.failure(sent ? .outcomeUnknown : .cancelled))
        default: break
        }
    }

    private func receive(_ size: Int, buffer: Data, header: Bool) {
        guard live(), let connection else { return }
        let needed = size - buffer.count
        connection.receive(minimumIncompleteLength: needed, maximumLength: needed) { [self] data, _, complete, error in
            guard live() else { return }
            guard error == nil, let data, !data.isEmpty, data.count <= needed else { finish(.failure(.outcomeUnknown)); return }
            let bytes = buffer + data
            if bytes.count < size {
                if complete { finish(.failure(.outcomeUnknown)) }
                else { receive(size, buffer: bytes, header: header) }
                return
            }
            do {
                if header { receive(try NativeControllerPairingWire.frameSize(bytes), buffer: Data(), header: false) }
                else { finish(.success(try NativeControllerPairingWire.verifyResponse(bytes, request: request, approvedAccess: access))) }
            } catch { finish(.failure(.outcomeUnknown)) }
        }
    }

    private func armDeadline() {
        timer?.cancel()
        deadline = ContinuousClock.now.advanced(by: .seconds(5))
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .seconds(5))
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

    private func finish(_ result: Result<NativeControllerBootstrapResponse, NativeControllerTLSError>) {
        guard !finished else { return }
        finished = true
        timer?.cancel(); timer = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel(); connection = nil
        let callback = continuation; continuation = nil
        switch result {
        case .success(let value): callback?.resume(returning: value)
        case .failure(let error): callback?.resume(throwing: error)
        }
    }
}
