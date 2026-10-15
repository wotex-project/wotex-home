import CryptoKit
import Foundation

enum NativeCertificateClockError: Error, Equatable {
    case invalidDocument, scopeConflict, invalidSignature, clockUnavailable, expired
    case custodyConflict, capacity, outcomeUnknown
}

// Inert source documents and arithmetic only. None of these values constructs
// an installed source, an actual signing seal or a trusted TLS clock producer.
struct NativeCertificateClockPolicy: Equatable, Sendable {
    let source: String, issuer: String, publicKey: Data, generation: Int64
    let procedure: String, qualification: String, runtime: String
    let responseMilliseconds: Int64, ageMilliseconds: Int64, errorMilliseconds: Int64
    let driftPPM: Int64, discontinuityMilliseconds: Int64

    func encoded() throws -> Data {
        let wire = NativeCertificateClockWire.self
        guard [source, issuer, procedure].allSatisfy(NativeControllerPairingWire.id),
              [qualification, runtime].allSatisfy(NativeControllerPairingWire.digest),
              publicKey.count == 32, generation > 0,
              (1...60_000).contains(responseMilliseconds), (1...600_000).contains(ageMilliseconds),
              (0...1_000).contains(errorMilliseconds), (0...1_000).contains(driftPPM),
              (0...1_000).contains(discontinuityMilliseconds),
              ageMilliseconds > responseMilliseconds + 2 * errorMilliseconds else {
            throw NativeCertificateClockError.invalidDocument
        }
        return try wire.encode([wire.policyFormat, source, issuer, NativeControllerPairingWire.base64(publicKey),
            generation, procedure, qualification, runtime, responseMilliseconds, ageMilliseconds,
            errorMilliseconds, driftPPM, discontinuityMilliseconds])
    }

    static func decode(_ bytes: Data) throws -> Self {
        let a = try NativeCertificateClockWire.decode(bytes)
        guard a.count == 13, a[0] as? String == NativeCertificateClockWire.policyFormat,
              let source = a[1] as? String, let issuer = a[2] as? String,
              let key = NativeControllerPairingWire.unbase64(a[3], minimum: 32, maximum: 32),
              let generation = ControllerPairingJSON.integer(a[4]), let procedure = a[5] as? String,
              let qualification = a[6] as? String, let runtime = a[7] as? String,
              let response = ControllerPairingJSON.integer(a[8]), let age = ControllerPairingJSON.integer(a[9]),
              let error = ControllerPairingJSON.integer(a[10]), let drift = ControllerPairingJSON.integer(a[11]),
              let discontinuity = ControllerPairingJSON.integer(a[12]) else {
            throw NativeCertificateClockError.invalidDocument
        }
        let result = Self(source: source, issuer: issuer, publicKey: key, generation: generation,
            procedure: procedure, qualification: qualification, runtime: runtime, responseMilliseconds: response,
            ageMilliseconds: age, errorMilliseconds: error, driftPPM: drift, discontinuityMilliseconds: discontinuity)
        guard try result.encoded() == bytes else { throw NativeCertificateClockError.invalidDocument }
        return result
    }
}

struct NativeCertificateClockRequest: Equatable, Sendable {
    let runtime: String, challenge: Data, policyDigest: String
    func encoded() throws -> Data {
        guard [runtime, policyDigest].allSatisfy(NativeControllerPairingWire.digest), challenge.count == 32 else {
            throw NativeCertificateClockError.invalidDocument
        }
        return try NativeCertificateClockWire.encode([NativeCertificateClockWire.requestFormat,
            "org.wotex.home", runtime, NativeControllerPairingWire.base64(challenge), policyDigest])
    }
    static func decode(_ bytes: Data) throws -> Self {
        let a = try NativeCertificateClockWire.decode(bytes)
        guard a.count == 5, a[0] as? String == NativeCertificateClockWire.requestFormat,
              a[1] as? String == "org.wotex.home", let runtime = a[2] as? String,
              let challenge = NativeControllerPairingWire.unbase64(a[3], minimum: 32, maximum: 32),
              let policy = a[4] as? String else { throw NativeCertificateClockError.invalidDocument }
        let result = Self(runtime: runtime, challenge: challenge, policyDigest: policy)
        guard try result.encoded() == bytes else { throw NativeCertificateClockError.invalidDocument }
        return result
    }
}

struct NativeCertificateClockPackage: Equatable, Sendable, CustomReflectable {
    let request: NativeCertificateClockRequest, observedUTC: Int64, signature: Data
    var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
    func recordBytes() throws -> Data {
        _ = try request.encoded()
        guard (0...253_402_300_199_000).contains(observedUTC) else { throw NativeCertificateClockError.invalidDocument }
        return try NativeCertificateClockWire.encode([NativeCertificateClockWire.recordFormat,
            "org.wotex.home", request.runtime, NativeControllerPairingWire.base64(request.challenge), request.policyDigest, observedUTC])
    }
    func signingBytes() throws -> Data {
        var result = Data(NativeCertificateClockWire.recordFormat.utf8)
        result.append(0); result.append(try recordBytes())
        return result
    }
    func encoded() throws -> Data {
        guard signature.count == 64 else { throw NativeCertificateClockError.invalidDocument }
        return try NativeCertificateClockWire.encode([NativeCertificateClockWire.packageFormat,
            NativeCertificateClockWire.decode(recordBytes()), NativeControllerPairingWire.base64(signature)])
    }
    static func decode(_ bytes: Data) throws -> Self {
        let a = try NativeCertificateClockWire.decode(bytes)
        guard a.count == 3, a[0] as? String == NativeCertificateClockWire.packageFormat,
              let record = a[1] as? [Any], record.count == 6,
              record[0] as? String == NativeCertificateClockWire.recordFormat, record[1] as? String == "org.wotex.home",
              let runtime = record[2] as? String,
              let challenge = NativeControllerPairingWire.unbase64(record[3], minimum: 32, maximum: 32),
              let policy = record[4] as? String, let utc = ControllerPairingJSON.integer(record[5]),
              let signature = NativeControllerPairingWire.unbase64(a[2], minimum: 64, maximum: 64) else {
            throw NativeCertificateClockError.invalidDocument
        }
        let result = Self(request: .init(runtime: runtime, challenge: challenge, policyDigest: policy), observedUTC: utc, signature: signature)
        guard try result.encoded() == bytes else { throw NativeCertificateClockError.invalidDocument }
        return result
    }
}

struct NativeCertificateClockInterval: Equatable, Sendable {
    let earliest: Int64, latest: Int64
}

struct NativeCertificateClockLease: Sendable, CustomReflectable {
    private let policy: Data, request: Data, package: Data, responseElapsed: Int64
    var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
    init(policy: Data, request: Data, package: Data, responseElapsed: Int64) throws {
        _ = try Self.calculate(policy: policy, request: request, package: package,
            responseElapsed: responseElapsed, elapsed: responseElapsed)
        self.policy = policy; self.request = request; self.package = package; self.responseElapsed = responseElapsed
    }
    func bounds(elapsed: Int64) throws -> NativeCertificateClockInterval {
        try Self.calculate(policy: policy, request: request, package: package, responseElapsed: responseElapsed, elapsed: elapsed)
    }
    private static func calculate(policy: Data, request: Data, package: Data, responseElapsed: Int64,
                                  elapsed: Int64) throws -> NativeCertificateClockInterval {
        let p = try NativeCertificateClockPolicy.decode(policy), r = try NativeCertificateClockRequest.decode(request)
        let answer = try NativeCertificateClockPackage.decode(package)
        guard r.runtime == p.runtime, r.policyDigest == NativeCertificateClockWire.hash(policy), answer.request == r else {
            throw NativeCertificateClockError.scopeConflict
        }
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: p.publicKey),
              try key.isValidSignature(answer.signature, for: answer.signingBytes()) else {
            throw NativeCertificateClockError.invalidSignature
        }
        guard responseElapsed >= 0, elapsed >= responseElapsed else { throw NativeCertificateClockError.clockUnavailable }
        guard responseElapsed < p.responseMilliseconds, elapsed < p.ageMilliseconds else { throw NativeCertificateClockError.expired }
        let drift = (elapsed * p.driftPPM + 999_999) / 1_000_000
        let error = p.errorMilliseconds + p.discontinuityMilliseconds + 2
        let first = answer.observedUTC + elapsed - responseElapsed - error - drift
        let last = answer.observedUTC + elapsed + error + drift
        guard first >= 0, first <= last, last <= 253_402_300_799_000 else { throw NativeCertificateClockError.clockUnavailable }
        return NativeCertificateClockInterval(earliest: first, latest: last)
    }
}

enum NativeCertificateClockWire {
    static let policyFormat = "wotex-home.native-certificate-clock-policy.v1"
    static let requestFormat = "wotex-home.native-certificate-clock-request.v1"
    static let recordFormat = "wotex-home.native-certificate-clock-record.v1"
    static let packageFormat = "wotex-home.native-certificate-clock-package.v1"
    static func hash(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }

    // This pure digest describes input facts only. Production must obtain and
    // recheck them from actual-self protected signing, never an injected map.
    static func runtime(team: String, executable: Data, bundle: Data) throws -> String {
        guard team.utf8.count == 10, team.utf8.allSatisfy({ (65...90).contains($0) || (48...57).contains($0) }),
              (1...64).contains(executable.count), (1...64).contains(bundle.count) else {
            throw NativeCertificateClockError.invalidDocument
        }
        return try hash(encode(["wotex-home.native-certificate-clock-runtime.v1", team,
            NativeControllerPairingWire.base64(executable), NativeControllerPairingWire.base64(bundle)]))
    }

    // One comparison is inert. The owner must check both rolling and original
    // deltas, retain withdrawal irreversibly, and revalidate all private custody.
    static func continuityAllowed(policy: NativeCertificateClockPolicy, wallElapsed: Int64, continuousElapsed: Int64) -> Bool {
        guard (try? policy.encoded()) != nil, wallElapsed >= 0, continuousElapsed >= 0,
              continuousElapsed < policy.ageMilliseconds else { return false }
        let (difference, overflow) = wallElapsed.subtractingReportingOverflow(continuousElapsed)
        guard !overflow, difference != Int64.min else { return false }
        let drift = (continuousElapsed * policy.driftPPM + 999_999) / 1_000_000
        return abs(difference) <= policy.discontinuityMilliseconds + drift + 2
    }
    static func decode(_ bytes: Data) throws -> [Any] {
        do {
            let result = try ControllerPairingJSON.decode(bytes, maximumBytes: 4096)
            guard valid(result, depth: 0) else { throw NativeCertificateClockError.invalidDocument }
            return result
        } catch { throw NativeCertificateClockError.invalidDocument }
    }
    static func encode(_ value: [Any]) throws -> Data {
        do {
            guard valid(value, depth: 0) else { throw NativeCertificateClockError.invalidDocument }
            return try ControllerPairingJSON.encode(value, maximumBytes: 4096)
        } catch { throw NativeCertificateClockError.invalidDocument }
    }
    private static func valid(_ value: Any, depth: Int) -> Bool {
        if let a = value as? [Any] { return depth < 3 && a.count <= 16 && a.allSatisfy { valid($0, depth: depth + 1) } }
        if let s = value as? String {
            return s.utf8.count <= 128 && s.utf8.allSatisfy { (32...126).contains($0) && $0 != 34 && $0 != 92 }
        }
        return ControllerPairingJSON.integer(value) != nil
    }
}
