import CryptoKit
import CoreFoundation
import Darwin
import Foundation
import Security

enum LocalHealthError: LocalizedError {
    case invalidCredential
    case noCredential
    case keychain(OSStatus)
    case invalidSocket
    case wrongPeer
    case nativeGuardCapacity
    case nativeGuardConflict
    case sessionChanged
    case transport
    case invalidResponse
    case invalidReceiptRequest
    case invalidEnrollmentRequest
    case invalidOverrideRequest
    case invalidRuleRequest
    case invalidProfileRequest
    case invalidMaintenanceRequest
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidCredential: "Enter the 43-character operator credential."
        case .noCredential: "Import an operator credential to read Home state."
        case .keychain(let status): "Keychain error \(status)."
        case .invalidSocket: "The private Home socket is unavailable."
        case .wrongPeer: "The Home socket is not the expected controller peer."
        case .nativeGuardCapacity: "Home cannot register another native session in this app process."
        case .nativeGuardConflict: "The native credential's original controller context conflicts with this session."
        case .sessionChanged: "The selected credential changed. Refresh before starting another operation."
        case .transport: "Could not complete the local Home request."
        case .invalidResponse: "The host returned an invalid local response."
        case .invalidReceiptRequest: "Enter a valid authority epoch and operation ID."
        case .invalidEnrollmentRequest: "Enter a valid enrollment review reference."
        case .invalidRuleRequest: "Enter a valid rule authority epoch and operation ID."
        case .invalidProfileRequest: "Refresh profile status and retain the original operation inputs."
        case .invalidMaintenanceRequest: "Refresh maintenance status and use a valid original operation identity."
        case .invalidOverrideRequest: "Enter a valid override target, epoch and operation ID."
        case .server(let reason): "Host rejected the local request: \(reason)."
        }
    }
}

protocol NativeAPIRequestLease: AnyObject, Sendable {
    func current() throws
    func finish()
}
typealias NativeAPIRequestGuard = @Sendable (Int32, UInt64) throws -> any NativeAPIRequestLease

// References/callbacks only, no credential bytes or authenticated OS seals.
// A known native hash can never silently return to the manual peer boundary.
private final class NativeRequestGuardRegistry: @unchecked Sendable, CustomReflectable {
    struct Record { let reference: Data?; let guardRequest: NativeAPIRequestGuard? }
    private let lock = NSLock()
    private var records: [String: Record] = [:]
    var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
    private func key(_ credential: Data) -> String { SHA256.hash(data: credential).map { String(format: "%02x", $0) }.joined() }
    func require(_ credential: Data) throws {
        let key = key(credential)
        lock.lock(); defer { lock.unlock() }
        if records[key] == nil {
            guard records.count < 264 else { throw LocalHealthError.nativeGuardCapacity }
            records[key] = Record(reference: nil, guardRequest: nil)
        }
    }
    func retain(_ credential: Data, reference: Data, guardRequest: @escaping NativeAPIRequestGuard) throws {
        let key = key(credential)
        guard credential.count == 32, (1...4096).contains(reference.count) else { throw LocalHealthError.nativeGuardConflict }
        try StrictLocalJSON.check(reference)
        guard let values = try JSONSerialization.jsonObject(with: reference) as? [Any], values.count == 8,
              values[0] as? String == "wotex-home.native-credential-broker.v1", values[1] as? String == "recover",
              let deployment = values[2] as? String, LocalHealthClient.profileDigest(deployment),
              let owner = values[3] as? String, LocalHealthClient.profileDigest(owner),
              let epoch = LocalHealthClient.profileInteger(values[4]), epoch > 0,
              let role = values[5] as? String, ["diagnostic", "operator", "maintenance", "transfer"].contains(role),
              values[6] as? String == key,
              let revision = LocalHealthClient.profileInteger(values[7]), revision > 0,
              try JSONSerialization.data(withJSONObject: values, options: .withoutEscapingSlashes) == reference else {
            throw LocalHealthError.nativeGuardConflict
        }
        lock.lock(); defer { lock.unlock() }
        if let original = records[key]?.reference, original != reference { throw LocalHealthError.nativeGuardConflict }
        guard records[key] != nil || records.count < 264 else { throw LocalHealthError.nativeGuardCapacity }
        records[key] = Record(reference: reference, guardRequest: guardRequest)
    }
    func reference(_ credential: Data) -> Data? {
        let key = key(credential)
        lock.lock(); defer { lock.unlock() }
        return records[key]?.reference
    }
    func contains(_ credential: Data) -> Bool {
        let key = key(credential)
        lock.lock(); defer { lock.unlock() }
        return records[key] != nil
    }
    func acquire(_ credential: Data, descriptor: Int32, deadline: UInt64) throws -> (any NativeAPIRequestLease)? {
        let key = key(credential)
        lock.lock(); let record = records[key]; lock.unlock()
        guard let record else { return nil }
        guard let guardRequest = record.guardRequest else { throw LocalHealthError.wrongPeer }
        return try guardRequest(descriptor, deadline)
    }
}

private final class VolatileCredentialSelection: @unchecked Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    enum Mode { case manual, none, native(Data) }
    struct Snapshot { let identity: UUID; let mode: Mode }
    private let lock = NSLock()
    private var mode: Mode = .manual
    private var identity = UUID()
    var description: String { "private_local_session_selection" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }

    func select(_ value: Mode) {
        let nextIdentity = UUID()
        lock.lock(); mode = value; identity = nextIdentity; lock.unlock()
    }
    func capture() -> Mode { lock.lock(); defer { lock.unlock() }; return mode }
    func snapshot() -> Snapshot { lock.lock(); defer { lock.unlock() }; return Snapshot(identity: identity, mode: mode) }
    func checked<T>(_ snapshot: Snapshot, _ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        guard identity == snapshot.identity else { throw LocalHealthError.sessionChanged }
        return try body()
    }
}

struct LocalCredentialCapture: Sendable, CustomReflectable {
    let bytes: Data
    let nativeReference: Data?
    var verifier: String { LocalHealthClient.profileSHA(bytes) }
    var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
}

enum OperatorCredential {
    private static let service = "org.wotex.home.operator"
    private static let account = "local-api-v1"
    private static let selection = VolatileCredentialSelection()
    private static let requestGuards = NativeRequestGuardRegistry()

    static func selectNative(_ bytes: Data) throws {
        guard bytes.count == 32 else { throw LocalHealthError.invalidCredential }
        let copied = bytes.withUnsafeBytes { Data(bytes: $0.baseAddress!, count: 32) }
        try requestGuards.require(copied)
        selection.select(.native(copied))
    }

    static func retainNativeRequestGuard(_ bytes: Data, reference: Data, guardRequest: @escaping NativeAPIRequestGuard) throws {
        try requestGuards.retain(bytes, reference: reference, guardRequest: guardRequest)
    }
    static func nativeReference(_ bytes: Data) -> Data? { requestGuards.reference(bytes) }
    static func nativeRequestLease(_ bytes: Data, descriptor: Int32, deadline: UInt64) throws -> (any NativeAPIRequestLease)? {
        try requestGuards.acquire(bytes, descriptor: descriptor, deadline: deadline)
    }

    static func endNativeSession() { selection.select(.none) }
    static func selectManual() { selection.select(.manual) }
    static var nativeSessionSelected: Bool {
        if case .native = selection.capture() { return true }
        return false
    }

    private static var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
    }

    static func save(_ encoded: String) throws {
        guard encoded.count == 43,
              encoded.utf8.allSatisfy({
                  (65...90).contains($0) || (97...122).contains($0) ||
                      (48...57).contains($0) || $0 == 45 || $0 == 95
              }),
              let data = Data(base64Encoded: encoded.replacingOccurrences(of: "-", with: "+")
                  .replacingOccurrences(of: "_", with: "/") + "="),
              data.count == 32,
              encode(data) == encoded else {
            throw LocalHealthError.invalidCredential
        }

        var attributes = query
        attributes[kSecValueData as String] = data
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let update = SecItemUpdate(
                query as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
            guard update == errSecSuccess else { throw LocalHealthError.keychain(update) }
        } else if status != errSecSuccess {
            throw LocalHealthError.keychain(status)
        }
        selection.select(.manual)
    }

    static func load() throws -> Data {
        switch selection.capture() {
        case .native(let bytes): return bytes
        case .none: throw LocalHealthError.noCredential
        case .manual: break
        }
        return try manualItem()
    }

    // Native bytes/reference are captured under the same selection lock.
    // Legacy IO happens outside that lock, then the original selection nonce
    // is repeated before publishing a capture. No failed capture selects mode.
    static func captureOriginal() throws -> LocalCredentialCapture {
        let original = selection.snapshot()
        let bytes: Data
        switch original.mode {
        case .native(let value): bytes = value
        case .none: throw LocalHealthError.noCredential
        case .manual: bytes = try manualItem()
        }
        return try selection.checked(original) {
            switch original.mode {
            case .native:
                guard let reference = requestGuards.reference(bytes) else { throw LocalHealthError.wrongPeer }
                return LocalCredentialCapture(bytes: bytes, nativeReference: reference)
            case .manual:
                guard !requestGuards.contains(bytes) else { throw LocalHealthError.nativeGuardConflict }
                return LocalCredentialCapture(bytes: bytes, nativeReference: nil)
            case .none: throw LocalHealthError.noCredential
            }
        }
    }

    static func recoverOriginalManual(verifier: String) throws -> Data {
        guard LocalHealthClient.profileDigest(verifier) else { throw LocalHealthError.invalidCredential }
        let bytes = try manualItem()
        guard !requestGuards.contains(bytes), LocalHealthClient.profileSHA(bytes) == verifier else {
            throw LocalHealthError.nativeGuardConflict
        }
        return bytes
    }

    private static func manualItem() throws -> Data {
        var attributes = query
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        if status == errSecItemNotFound { throw LocalHealthError.noCredential }
        guard status == errSecSuccess else { throw LocalHealthError.keychain(status) }
        guard let data = result as? Data, data.count == 32 else {
            throw LocalHealthError.invalidCredential
        }
        return data
    }

    static func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw LocalHealthError.keychain(status)
        }
    }

    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

struct HomeControllerIdentity: Sendable, Equatable {
    let deploymentID: String
    let ownerID: String
    let authorityEpoch: Int
    let revision: Int
    let principalID: String

    func matchesAuthority(_ original: HomeControllerIdentity) -> Bool {
        deploymentID == original.deploymentID && ownerID == original.ownerID &&
            authorityEpoch == original.authorityEpoch && principalID == original.principalID
    }
}

struct HomeHealth: Sendable {
    let revision: Int
    let authorityEpoch: Int
    let ruleGeneration: Int
    let heldRequests: Int
    let queuedRequests: Int
    let claimedRequests: Int
    let unknownOutcomes: Int
    let activeThings: Int
    let activePrincipals: Int
    let writable: Bool
    let dispatchEnabled: Bool
}

struct HomeObservation: Sendable, Identifiable {
    let thingID: String
    let capabilityKey: String
    let quality: String
    let trust: String
    let valueText: String
    let revision: Int

    var id: String { "\(thingID)/\(capabilityKey)" }
}

struct HomeSnapshot: Sendable {
    let authorityEpoch: Int
    let watermark: Int
    let observations: [HomeObservation]
}

struct HomeThing: Sendable, Identifiable {
    let id: String
    let role: String
    let profileRef: String
    let capabilityCount: Int
    let resourceRevision: Int
    let powerWritable: Bool
}

struct HomeCatalogue: Sendable {
    let authorityEpoch: Int
    let watermark: Int
    let things: [HomeThing]
}

struct HomeReadView: Sendable {
    let catalogue: HomeCatalogue
    let snapshot: HomeSnapshot
}

struct HomeOverride: Sendable, Identifiable {
    let targetID: String
    let operatorID: String
    let authorityEpoch: Int
    let basisRevision: Int
    let remainingMilliseconds: Int
    let operationID: String?

    var id: String { targetID }
}

struct HomeOverrideReceipt: Sendable {
    let operatorID: String
    let authorityEpoch: Int
    let operationID: String
    let targetID: String
    let basisRevision: Int
    let durationMilliseconds: Int
    let issueRevision: Int
    let revokeRevision: Int?
    let active: Bool
    let remainingMilliseconds: Int
}

enum HomeOverrideLookup: Sendable {
    case found(HomeOverrideReceipt)
    case notFound
}

struct HomeReceipt: Sendable {
    let authorityEpoch: Int
    let operationID: String
    let disposition: String
    let reason: String?
    let revision: Int
}

enum HomeReceiptLookup: Sendable {
    case found(HomeReceipt)
    case notFound
}

struct HomeEnrollmentReview: Sendable {
    let reviewRef: String
    let thingID: String
    let reviewRevision: Int
    let bindingRevision: Int
    let digestVersion: Int
    let state: String
}

enum HomeEnrollmentLookup: Sendable {
    case found(HomeEnrollmentReview)
    case notFound
}

struct HomeRuleStatus: Sendable {
    let authorityEpoch: Int
    let generation: Int
    let admissionRevision: Int
    let state: String
    let reason: String?
}

struct HomeRuleAdmission: Sendable {
    let operationID: String
    let revision: Int
    let artifactDigest: String
}

struct HomeRuleActivation: Sendable {
    let admissionRevision: Int
    let generation: Int
    let revision: Int
    let storeRevision: Int
    let affectedRequests: Int
    let unknownOutcomes: Int
}

enum HomeRuleOperation: Sendable {
    case admission(HomeRuleAdmission)
    case activation(HomeRuleActivation)
    case notFound
}

struct HomeMaintenanceStatus: Sendable {
    let authorityEpoch: Int
    let storeRevision: Int
    let generation: Int
    let beginRevision: Int
    let state: String
}

struct HomeMaintenanceReceipt: Sendable {
    let principalID: String
    let authorityEpoch: Int
    let operationID: String
    let action: String
    let beginRevision: Int
    let revision: Int
    let generation: Int
    let affectedRequests: Int
    let unknownOutcomes: Int
    let state: String
}

enum HomeMaintenanceLookup: Sendable {
    case found(HomeMaintenanceReceipt)
    case notFound
}

enum LocalHealthClient {
    private static let maxResponseBytes = 1_048_576

    static func fetchControllerIdentity(socketPath path: String, credential: Data) throws -> HomeControllerIdentity {
        let response = try request(socketPath: path, credential: credential, operation: "controller_identity")
        guard Set(response.keys) == Set(["api_version", "outcome", "controller_identity"]),
              let item = response["controller_identity"] as? [String: Any],
              Set(item.keys) == Set(["deployment_id", "owner_id", "authority_epoch", "store_revision", "principal_id"]),
              let deployment = item["deployment_id"] as? String, controllerID(deployment),
              let owner = item["owner_id"] as? String, controllerID(owner),
              let epoch = wireInteger(item["authority_epoch"]), epoch > 0,
              let revision = wireInteger(item["store_revision"]), revision >= 0,
              let principal = item["principal_id"] as? String, validID(principal) else {
            throw LocalHealthError.invalidResponse
        }
        return HomeControllerIdentity(deploymentID: deployment, ownerID: owner, authorityEpoch: epoch,
                                      revision: revision, principalID: principal)
    }

    private static func controllerID(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func fetchMaintenanceStatus() throws -> HomeMaintenanceStatus {
        try fetchMaintenanceStatus(socketPath: defaultSocketPath(), credential: OperatorCredential.load())
    }

    static func fetchMaintenanceStatus(socketPath path: String, credential: Data) throws -> HomeMaintenanceStatus {
        let response = try request(socketPath: path, credential: credential, operation: "maintenance_status")
        guard Set(response.keys) == Set(["api_version", "outcome", "maintenance_status"]),
              let item = response["maintenance_status"] as? [String: Any],
              Set(item.keys) == Set(["authority_epoch", "store_revision", "rule_generation", "begin_revision", "state"]),
              let epoch = wireInteger(item["authority_epoch"]), epoch >= 1,
              let store = wireInteger(item["store_revision"]), store >= 0,
              let generation = wireInteger(item["rule_generation"]), (0...store).contains(generation),
              let begin = wireInteger(item["begin_revision"]), (0...store).contains(begin),
              let state = item["state"] as? String,
              (state == "normal" && begin == 0) ||
                  (state == "maintenance" && begin > 0 && generation > 0) else {
            throw LocalHealthError.invalidResponse
        }
        return HomeMaintenanceStatus(authorityEpoch: epoch, storeRevision: store,
            generation: generation, beginRevision: begin, state: state)
    }

    static func beginMaintenance(credential: Data, authorityEpoch: Int, operationID: String,
        expectedRevision: Int) throws -> HomeMaintenanceReceipt {
        try beginMaintenance(socketPath: defaultSocketPath(), credential: credential,
            authorityEpoch: authorityEpoch, operationID: operationID, expectedRevision: expectedRevision)
    }

    static func beginMaintenance(socketPath path: String, credential: Data, authorityEpoch: Int,
        operationID: String, expectedRevision: Int) throws -> HomeMaintenanceReceipt {
        guard authorityEpoch >= 1, validID(operationID), expectedRevision >= 0,
              expectedRevision <= Int.max - 2 else { throw LocalHealthError.invalidMaintenanceRequest }
        let response = try request(socketPath: path, credential: credential, operation: "begin_maintenance",
            fields: ["authority_epoch": authorityEpoch, "operation_id": operationID,
                "expected_revision": expectedRevision])
        let receipt = try decodeMaintenanceReceipt(response, authorityEpoch: authorityEpoch, operationID: operationID)
        guard receipt.action == "begin", receipt.revision > expectedRevision,
              receipt.revision - expectedRevision == receipt.affectedRequests + 2 else {
            throw LocalHealthError.invalidResponse
        }
        return receipt
    }

    static func endMaintenance(credential: Data, authorityEpoch: Int, operationID: String,
        expectedRevision: Int, beginRevision: Int) throws -> HomeMaintenanceReceipt {
        try endMaintenance(socketPath: defaultSocketPath(), credential: credential,
            authorityEpoch: authorityEpoch, operationID: operationID,
            expectedRevision: expectedRevision, beginRevision: beginRevision)
    }

    static func endMaintenance(socketPath path: String, credential: Data, authorityEpoch: Int,
        operationID: String, expectedRevision: Int, beginRevision: Int) throws -> HomeMaintenanceReceipt {
        guard authorityEpoch >= 1, validID(operationID), expectedRevision >= 1,
              expectedRevision < Int.max, (1...expectedRevision).contains(beginRevision) else {
            throw LocalHealthError.invalidMaintenanceRequest
        }
        let response = try request(socketPath: path, credential: credential, operation: "end_maintenance",
            fields: ["authority_epoch": authorityEpoch, "operation_id": operationID,
                "expected_revision": expectedRevision, "begin_revision": beginRevision])
        let receipt = try decodeMaintenanceReceipt(response, authorityEpoch: authorityEpoch, operationID: operationID)
        guard receipt.action == "end", receipt.beginRevision == beginRevision,
              receipt.revision == expectedRevision + 1 else { throw LocalHealthError.invalidResponse }
        return receipt
    }

    static func fetchMaintenanceOperationStatus(authorityEpoch: Int, operationID: String) throws -> HomeMaintenanceLookup {
        try fetchMaintenanceOperationStatus(credential: OperatorCredential.load(),
            authorityEpoch: authorityEpoch, operationID: operationID)
    }

    static func fetchMaintenanceOperationStatus(credential: Data, authorityEpoch: Int,
        operationID: String) throws -> HomeMaintenanceLookup {
        try fetchMaintenanceOperationStatus(socketPath: defaultSocketPath(), credential: credential,
            authorityEpoch: authorityEpoch, operationID: operationID)
    }

    static func fetchMaintenanceOperationStatus(socketPath path: String, credential: Data,
        authorityEpoch: Int, operationID: String) throws -> HomeMaintenanceLookup {
        guard authorityEpoch >= 1, validID(operationID) else { throw LocalHealthError.invalidMaintenanceRequest }
        let response = try request(socketPath: path, credential: credential, operation: "maintenance_operation_status",
            fields: ["authority_epoch": authorityEpoch, "operation_id": operationID], allowNotFound: true)
        if response["outcome"] as? String == "not_found" { return .notFound }
        return .found(try decodeMaintenanceReceipt(response, authorityEpoch: authorityEpoch, operationID: operationID))
    }

    private static func decodeMaintenanceReceipt(_ response: [String: Any], authorityEpoch: Int,
        operationID: String) throws -> HomeMaintenanceReceipt {
        guard Set(response.keys) == Set(["api_version", "outcome", "maintenance_receipt"]),
              let item = response["maintenance_receipt"] as? [String: Any],
              Set(item.keys) == Set(["principal_id", "authority_epoch", "operation_id", "action", "begin_revision",
                  "revision", "rule_generation", "affected_requests", "unknown_outcomes", "state"]),
              let principal = item["principal_id"] as? String, validID(principal),
              wireInteger(item["authority_epoch"]) == authorityEpoch,
              item["operation_id"] as? String == operationID,
              let action = item["action"] as? String, ["begin", "end"].contains(action),
              let revision = wireInteger(item["revision"]), revision >= 1,
              let begin = wireInteger(item["begin_revision"]), (1...revision).contains(begin),
              let generation = wireInteger(item["rule_generation"]), (1...revision).contains(generation),
              let affected = wireInteger(item["affected_requests"]), (0...1024).contains(affected),
              let unknown = wireInteger(item["unknown_outcomes"]), (0...affected).contains(unknown),
              let state = item["state"] as? String,
              (action == "begin" && state == "maintenance" && begin == revision) ||
                  (action == "end" && state == "normal" && begin < revision && affected == 0 && unknown == 0) else {
            throw LocalHealthError.invalidResponse
        }
        return HomeMaintenanceReceipt(principalID: principal, authorityEpoch: authorityEpoch,
            operationID: operationID, action: action, beginRevision: begin, revision: revision,
            generation: generation, affectedRequests: affected, unknownOutcomes: unknown, state: state)
    }

    static func fetchRuleStatus() throws -> HomeRuleStatus {
        try fetchRuleStatus(socketPath: defaultSocketPath(), credential: OperatorCredential.load())
    }

    static func fetchRuleStatus(socketPath path: String, credential: Data) throws -> HomeRuleStatus {
        let response = try request(socketPath: path, credential: credential, operation: "rule_status")
        guard Set(response.keys) == Set(["api_version", "outcome", "rule_status"]),
              let item = response["rule_status"] as? [String: Any],
              Set(item.keys) == Set(["authority_epoch", "rule_generation", "admission_revision", "state", "reason"]),
              let epoch = wireInteger(item["authority_epoch"]), epoch >= 1,
              let generation = wireInteger(item["rule_generation"]), generation >= 0,
              let admission = wireInteger(item["admission_revision"]), admission >= 0,
              let state = item["state"] as? String,
              ["active", "inactive", "suspended"].contains(state) else {
            throw LocalHealthError.invalidResponse
        }
        let reason: String?
        if item["reason"] is NSNull { reason = nil }
        else if let text = item["reason"] as? String, !text.isEmpty, text.utf8.count <= 128 { reason = text }
        else { throw LocalHealthError.invalidResponse }
        guard (state == "inactive" && admission == 0 && reason == nil) ||
              (state == "active" && admission > 0 && reason == nil) ||
              (state == "suspended" && admission > 0 && reason != nil) else {
            throw LocalHealthError.invalidResponse
        }
        return HomeRuleStatus(authorityEpoch: epoch, generation: generation,
            admissionRevision: admission, state: state, reason: reason)
    }

    static func suspendRules(authorityEpoch: Int, operationID: String, expectedRevision: Int) throws -> HomeRuleActivation {
        try suspendRules(socketPath: defaultSocketPath(), credential: OperatorCredential.load(),
            authorityEpoch: authorityEpoch, operationID: operationID, expectedRevision: expectedRevision)
    }

    static func suspendRules(socketPath path: String, credential: Data,
        authorityEpoch: Int, operationID: String, expectedRevision: Int) throws -> HomeRuleActivation {
        guard authorityEpoch >= 1, validID(operationID), expectedRevision >= 0, expectedRevision < Int.max else {
            throw LocalHealthError.invalidRuleRequest
        }
        let response = try request(socketPath: path, credential: credential, operation: "activate_rule",
            fields: ["authority_epoch": authorityEpoch, "operation_id": operationID,
                "expected_revision": expectedRevision, "admission_revision": 0])
        let receipt = try decodeRuleActivation(response, status: false)
        guard receipt.admissionRevision == 0, receipt.revision == expectedRevision + 1 else {
            throw LocalHealthError.invalidResponse
        }
        return receipt
    }

    static func fetchRuleOperationStatus(authorityEpoch: Int, operationID: String) throws -> HomeRuleOperation {
        try fetchRuleOperationStatus(socketPath: defaultSocketPath(), credential: OperatorCredential.load(),
            authorityEpoch: authorityEpoch, operationID: operationID)
    }

    static func fetchRuleOperationStatus(socketPath path: String, credential: Data,
        authorityEpoch: Int, operationID: String) throws -> HomeRuleOperation {
        guard authorityEpoch >= 1, validID(operationID) else { throw LocalHealthError.invalidRuleRequest }
        let response = try request(socketPath: path, credential: credential, operation: "rule_operation_status",
            fields: ["authority_epoch": authorityEpoch, "operation_id": operationID], allowNotFound: true)
        if response["outcome"] as? String == "not_found" { return .notFound }
        guard Set(response.keys) == Set(["api_version", "outcome", "rule_receipt"]),
              let item = response["rule_receipt"] as? [String: Any] else {
            throw LocalHealthError.invalidResponse
        }
        if item["kind"] as? String == "activation" {
            return .activation(try decodeRuleActivation(response, status: true))
        }
        guard Set(item.keys) == Set(["kind", "principal_id", "authority_epoch", "operation_id",
                "revision", "artifact_digest", "profile", "state"]),
              item["kind"] as? String == "admission", item["state"] as? String == "admitted",
              item["profile"] as? String == "home-explicit-light-admission-v1",
              let principal = item["principal_id"] as? String, validID(principal),
              wireInteger(item["authority_epoch"]) == authorityEpoch,
              item["operation_id"] as? String == operationID,
              let revision = wireInteger(item["revision"]), revision >= 1,
              let digest = item["artifact_digest"] as? String,
              digest.utf8.count == 64, digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw LocalHealthError.invalidResponse
        }
        return .admission(HomeRuleAdmission(operationID: operationID, revision: revision, artifactDigest: digest))
    }

    private static func decodeRuleActivation(_ response: [String: Any], status: Bool) throws -> HomeRuleActivation {
        var keys: Set<String> = ["admission_revision", "previous_generation", "rule_generation",
            "revision", "store_revision", "affected_requests", "unknown_outcomes", "state"]
        if status { keys.insert("kind") }
        guard Set(response.keys) == Set(["api_version", "outcome", "rule_receipt"]),
              let item = response["rule_receipt"] as? [String: Any], Set(item.keys) == keys,
              !status || item["kind"] as? String == "activation",
              let admission = wireInteger(item["admission_revision"]), admission >= 0,
              let previous = wireInteger(item["previous_generation"]), previous >= 0, previous < Int.max,
              let generation = wireInteger(item["rule_generation"]), generation == previous + 1,
              let revision = wireInteger(item["revision"]), revision >= 1,
              let store = wireInteger(item["store_revision"]), store >= revision,
              let affected = wireInteger(item["affected_requests"]), (0...1024).contains(affected),
              let unknown = wireInteger(item["unknown_outcomes"]), (0...affected).contains(unknown),
              item["state"] as? String == (admission == 0 ? "inactive" : "active") else {
            throw LocalHealthError.invalidResponse
        }
        return HomeRuleActivation(admissionRevision: admission, generation: generation,
            revision: revision, storeRevision: store, affectedRequests: affected, unknownOutcomes: unknown)
    }

    private static func wireInteger(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        guard !["f", "d"].contains(String(cString: number.objCType)) else { return nil }
        return value as? Int
    }

    static func fetchEnrollmentStatus(reviewRef: String) throws -> HomeEnrollmentLookup {
        let credential = try OperatorCredential.load()
        return try fetchEnrollmentStatus(
            socketPath: defaultSocketPath(), credential: credential, reviewRef: reviewRef
        )
    }

    static func fetchEnrollmentStatus(
        socketPath path: String, credential: Data, reviewRef: String
    ) throws -> HomeEnrollmentLookup {
        guard validID(reviewRef) else { throw LocalHealthError.invalidEnrollmentRequest }
        let response = try request(
            socketPath: path, credential: credential, operation: "enrollment_status",
            fields: ["review_ref": reviewRef], allowNotFound: true
        )
        if response["outcome"] as? String == "not_found" { return .notFound }
        guard Set(response.keys) == Set(["api_version", "outcome", "enrollment_review"]),
              let item = response["enrollment_review"] as? [String: Any],
              Set(item.keys) == Set([
                  "review_ref", "thing_id", "review_revision", "binding_revision",
                  "digest_version", "state",
              ]),
              let returnedRef = item["review_ref"] as? String, returnedRef == reviewRef,
              let thingID = item["thing_id"] as? String, validID(thingID),
              let reviewRevision = item["review_revision"] as? Int, reviewRevision >= 1,
              let bindingRevision = item["binding_revision"] as? Int,
              bindingRevision >= reviewRevision,
              let digestVersion = item["digest_version"] as? Int,
              [1, 2].contains(digestVersion),
              let state = item["state"] as? String,
              ["current", "superseded", "revoked"].contains(state) else {
            throw LocalHealthError.invalidResponse
        }
        return .found(HomeEnrollmentReview(
            reviewRef: returnedRef, thingID: thingID,
            reviewRevision: reviewRevision, bindingRevision: bindingRevision,
            digestVersion: digestVersion, state: state
        ))
    }

    static func fetch() throws -> HomeHealth {
        let credential = try OperatorCredential.load()
        return try fetch(socketPath: defaultSocketPath(), credential: credential)
    }

    static func fetch(socketPath path: String, credential: Data) throws -> HomeHealth {
        let response = try request(socketPath: path, credential: credential, operation: "health")
        return try decodeHealth(response)
    }

    static func fetchSnapshot() throws -> HomeSnapshot {
        let credential = try OperatorCredential.load()
        return try fetchSnapshot(socketPath: defaultSocketPath(), credential: credential)
    }

    static func fetchSnapshot(socketPath path: String, credential: Data) throws -> HomeSnapshot {
        try fetchSnapshot(socketPath: path, credential: credential, startingWatermark: nil)
    }

    static func fetchReadView() throws -> HomeReadView {
        let credential = try OperatorCredential.load()
        return try fetchReadView(socketPath: defaultSocketPath(), credential: credential)
    }

    static func fetchReadView(socketPath path: String, credential: Data) throws -> HomeReadView {
        let catalogue = try fetchCatalogue(socketPath: path, credential: credential)
        let snapshot = try fetchSnapshot(
            socketPath: path, credential: credential, startingWatermark: catalogue.watermark
        )
        guard snapshot.authorityEpoch == catalogue.authorityEpoch,
              snapshot.watermark == catalogue.watermark else {
            throw LocalHealthError.invalidResponse
        }
        return HomeReadView(catalogue: catalogue, snapshot: snapshot)
    }

    static func fetchOverrides(targetIDs: [String]) throws -> [HomeOverride] {
        let credential = try OperatorCredential.load()
        return try fetchOverrides(
            socketPath: defaultSocketPath(), credential: credential, targetIDs: targetIDs
        )
    }

    static func fetchOverrides(
        socketPath path: String, credential: Data, targetIDs: [String]
    ) throws -> [HomeOverride] {
        guard targetIDs.count <= 32, Set(targetIDs).count == targetIDs.count,
              targetIDs.allSatisfy(validID) else {
            throw LocalHealthError.invalidReceiptRequest
        }
        let response = try request(
            socketPath: path, credential: credential, operation: "overrides",
            fields: ["target_ids": targetIDs]
        )
        guard Set(response.keys) == Set(["api_version", "outcome", "overrides"]),
              let raw = response["overrides"] as? [[String: Any]],
              raw.count <= targetIDs.count else {
            throw LocalHealthError.invalidResponse
        }
        let requested = Set(targetIDs)
        var seen = Set<String>()
        return try raw.map { item in
            guard Set(item.keys) == Set([
                "target_id", "operator_id", "authority_epoch", "basis_revision",
                "remaining_ms", "operation_id"
            ]),
                  let target = item["target_id"] as? String, requested.contains(target),
                  seen.insert(target).inserted,
                  let operatorID = item["operator_id"] as? String, validID(operatorID),
                  let epoch = item["authority_epoch"] as? Int, epoch >= 1,
                  let revision = item["basis_revision"] as? Int, revision >= 0,
                  let remaining = item["remaining_ms"] as? Int,
                  (1...86_400_000).contains(remaining) else {
                throw LocalHealthError.invalidResponse
            }
            let operationID: String?
            if item["operation_id"] is NSNull {
                operationID = nil
            } else if let value = item["operation_id"] as? String, validID(value) {
                operationID = value
            } else {
                throw LocalHealthError.invalidResponse
            }
            return HomeOverride(
                targetID: target, operatorID: operatorID, authorityEpoch: epoch,
                basisRevision: revision, remainingMilliseconds: remaining,
                operationID: operationID
            )
        }
    }

    static func issueOverride(
        targetID: String, basisRevision: Int, authorityEpoch: Int,
        operationID: String, durationMilliseconds: Int
    ) throws -> HomeOverrideReceipt {
        let credential = try OperatorCredential.load()
        return try issueOverride(
            socketPath: defaultSocketPath(), credential: credential,
            targetID: targetID, basisRevision: basisRevision,
            authorityEpoch: authorityEpoch, operationID: operationID,
            durationMilliseconds: durationMilliseconds
        )
    }

    static func issueOverride(
        socketPath path: String, credential: Data, targetID: String, basisRevision: Int,
        authorityEpoch: Int, operationID: String, durationMilliseconds: Int
    ) throws -> HomeOverrideReceipt {
        guard validID(targetID), validID(operationID), authorityEpoch >= 1,
              basisRevision >= 0, (1...86_400_000).contains(durationMilliseconds) else {
            throw LocalHealthError.invalidOverrideRequest
        }
        let response = try request(
            socketPath: path, credential: credential, operation: "override_issue",
            fields: [
                "authority_epoch": authorityEpoch, "operation_id": operationID,
                "target_id": targetID, "basis_revision": basisRevision,
                "duration_ms": durationMilliseconds,
            ]
        )
        let receipt = try decodeOverrideReceipt(
            response, authorityEpoch: authorityEpoch, operationID: operationID
        )
        guard receipt.targetID == targetID, receipt.basisRevision == basisRevision,
              receipt.durationMilliseconds == durationMilliseconds else {
            throw LocalHealthError.invalidResponse
        }
        return receipt
    }

    static func fetchOverrideStatus(
        authorityEpoch: Int, operationID: String
    ) throws -> HomeOverrideLookup {
        let credential = try OperatorCredential.load()
        return try fetchOverrideStatus(
            socketPath: defaultSocketPath(), credential: credential,
            authorityEpoch: authorityEpoch, operationID: operationID
        )
    }

    static func fetchOverrideStatus(
        socketPath path: String, credential: Data,
        authorityEpoch: Int, operationID: String
    ) throws -> HomeOverrideLookup {
        guard authorityEpoch >= 1, validID(operationID) else {
            throw LocalHealthError.invalidOverrideRequest
        }
        let response = try request(
            socketPath: path, credential: credential, operation: "override_status",
            fields: ["authority_epoch": authorityEpoch, "operation_id": operationID],
            allowNotFound: true
        )
        if response["outcome"] as? String == "not_found" { return .notFound }
        return .found(try decodeOverrideReceipt(
            response, authorityEpoch: authorityEpoch, operationID: operationID
        ))
    }

    static func revokeOverride(
        authorityEpoch: Int, operationID: String
    ) throws -> HomeOverrideLookup {
        let credential = try OperatorCredential.load()
        return try revokeOverride(
            socketPath: defaultSocketPath(), credential: credential,
            authorityEpoch: authorityEpoch, operationID: operationID
        )
    }

    static func revokeOverride(
        socketPath path: String, credential: Data,
        authorityEpoch: Int, operationID: String
    ) throws -> HomeOverrideLookup {
        guard authorityEpoch >= 1, validID(operationID) else {
            throw LocalHealthError.invalidOverrideRequest
        }
        let response = try request(
            socketPath: path, credential: credential, operation: "override_revoke",
            fields: ["authority_epoch": authorityEpoch, "operation_id": operationID],
            allowNotFound: true
        )
        if response["outcome"] as? String == "not_found" { return .notFound }
        return .found(try decodeOverrideReceipt(
            response, authorityEpoch: authorityEpoch, operationID: operationID
        ))
    }

    private static func decodeOverrideReceipt(
        _ response: [String: Any], authorityEpoch: Int, operationID: String
    ) throws -> HomeOverrideReceipt {
        guard Set(response.keys) == Set(["api_version", "outcome", "override_receipt"]),
              let item = response["override_receipt"] as? [String: Any],
              Set(item.keys) == Set([
                  "operator_id", "authority_epoch", "operation_id", "target_id",
                  "basis_revision", "duration_ms", "issue_revision", "revoke_revision",
                  "active", "remaining_ms",
              ]),
              let operatorID = item["operator_id"] as? String, validID(operatorID),
              let epoch = item["authority_epoch"] as? Int, epoch == authorityEpoch,
              let returnedID = item["operation_id"] as? String, returnedID == operationID,
              let targetID = item["target_id"] as? String, validID(targetID),
              let basis = item["basis_revision"] as? Int, basis >= 0,
              let duration = item["duration_ms"] as? Int,
              (1...86_400_000).contains(duration),
              let issueRevision = item["issue_revision"] as? Int, issueRevision >= 1,
              let active = item["active"] as? Bool,
              let remaining = item["remaining_ms"] as? Int,
              (0...duration).contains(remaining) else {
            throw LocalHealthError.invalidResponse
        }
        let revokeRevision: Int?
        if item["revoke_revision"] is NSNull {
            revokeRevision = nil
        } else if let revision = item["revoke_revision"] as? Int,
                  revision > issueRevision {
            revokeRevision = revision
        } else {
            throw LocalHealthError.invalidResponse
        }
        guard (!active || (remaining > 0 && revokeRevision == nil)),
              (active || remaining == 0) else {
            throw LocalHealthError.invalidResponse
        }
        return HomeOverrideReceipt(
            operatorID: operatorID, authorityEpoch: epoch, operationID: returnedID,
            targetID: targetID, basisRevision: basis,
            durationMilliseconds: duration, issueRevision: issueRevision,
            revokeRevision: revokeRevision, active: active,
            remainingMilliseconds: remaining
        )
    }

    static func fetchReceiptStatus(authorityEpoch: Int, operationID: String) throws -> HomeReceiptLookup {
        let credential = try OperatorCredential.load()
        return try fetchReceiptStatus(
            socketPath: defaultSocketPath(), credential: credential,
            authorityEpoch: authorityEpoch, operationID: operationID
        )
    }

    static func fetchReceiptStatus(
        socketPath path: String, credential: Data, authorityEpoch: Int, operationID: String
    ) throws -> HomeReceiptLookup {
        guard authorityEpoch >= 1, validID(operationID) else {
            throw LocalHealthError.invalidReceiptRequest
        }
        let response = try request(
            socketPath: path, credential: credential, operation: "status",
            fields: ["authority_epoch": authorityEpoch, "operation_id": operationID],
            allowNotFound: true
        )
        if response["outcome"] as? String == "not_found" { return .notFound }
        return .found(try decodeReceipt(response, authorityEpoch: authorityEpoch, operationID: operationID))
    }

    static func cancelRequest(authorityEpoch: Int, operationID: String) throws -> HomeReceiptLookup {
        let credential = try OperatorCredential.load()
        return try cancelRequest(
            socketPath: defaultSocketPath(), credential: credential,
            authorityEpoch: authorityEpoch, operationID: operationID
        )
    }

    static func cancelRequest(
        socketPath path: String, credential: Data, authorityEpoch: Int, operationID: String
    ) throws -> HomeReceiptLookup {
        guard authorityEpoch >= 1, validID(operationID) else {
            throw LocalHealthError.invalidReceiptRequest
        }
        let response = try request(
            socketPath: path, credential: credential, operation: "cancel",
            fields: ["authority_epoch": authorityEpoch, "operation_id": operationID],
            allowNotFound: true
        )
        if response["outcome"] as? String == "not_found" { return .notFound }
        let receipt = try decodeReceipt(
            response, authorityEpoch: authorityEpoch, operationID: operationID
        )
        guard receipt.disposition == "rejected" else {
            throw LocalHealthError.invalidResponse
        }
        return .found(receipt)
    }

    static func submitPower(
        targetID: String, expectedRevision: Int, authorityEpoch: Int,
        operationID: String, on: Bool
    ) throws -> HomeReceipt {
        let credential = try OperatorCredential.load()
        return try submitPower(
            socketPath: defaultSocketPath(), credential: credential, targetID: targetID,
            expectedRevision: expectedRevision, authorityEpoch: authorityEpoch,
            operationID: operationID, on: on
        )
    }

    static func submitPower(
        socketPath path: String, credential: Data, targetID: String,
        expectedRevision: Int, authorityEpoch: Int, operationID: String, on: Bool
    ) throws -> HomeReceipt {
        guard authorityEpoch >= 1, expectedRevision >= 0,
              validID(targetID), validID(operationID) else {
            throw LocalHealthError.invalidReceiptRequest
        }
        let mutation: [String: Any] = [
            "api_version": 1,
            "operation_id": operationID,
            "authority_epoch": authorityEpoch,
            "expected_revision": expectedRevision,
            "target_id": targetID,
            "capability_key": "power",
            "value": ["type": "boolean", "value": on],
        ]
        let response = try request(
            socketPath: path, credential: credential, operation: "submit",
            fields: ["mutation": mutation]
        )
        return try decodeReceipt(response, authorityEpoch: authorityEpoch, operationID: operationID)
    }

    private static func decodeReceipt(
        _ response: [String: Any], authorityEpoch: Int, operationID: String
    ) throws -> HomeReceipt {
        guard Set(response.keys) == Set(["api_version", "outcome", "receipt"]),
              let receipt = response["receipt"] as? [String: Any],
              receipt.count == 6,
              let principalID = receipt["principal_id"] as? String, validID(principalID),
              let epoch = receipt["authority_epoch"] as? Int, epoch == authorityEpoch,
              let returnedID = receipt["operation_id"] as? String, returnedID == operationID,
              let disposition = receipt["disposition"] as? String,
              ["held", "rejected", "queued", "claimed", "dispatching",
               "protocol_accepted", "observed", "contradicted", "failed",
               "outcome_unknown"].contains(disposition),
              let revision = receipt["revision"] as? Int, revision >= 0,
              receipt["reason"] is NSNull ||
                  (receipt["reason"] as? String).map({ $0.utf8.count <= 128 }) == true else {
            throw LocalHealthError.invalidResponse
        }
        return HomeReceipt(
            authorityEpoch: epoch, operationID: returnedID, disposition: disposition,
            reason: receipt["reason"] as? String, revision: revision
        )
    }

    private static func validID(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (1...128).contains(bytes.count) else { return false }
        for (index, byte) in bytes.enumerated() {
            let alphanumeric = (65...90).contains(byte) || (97...122).contains(byte) ||
                (48...57).contains(byte)
            if !alphanumeric && (index == 0 || ![46, 95, 58, 45].contains(byte)) {
                return false
            }
        }
        return true
    }

    private static func fetchSnapshot(
        socketPath path: String, credential: Data, startingWatermark: Int?
    ) throws -> HomeSnapshot {
        var watermark = startingWatermark
        var authorityEpoch: Int?
        var after: [String: String]?
        var observations: [HomeObservation] = []

        // One principal may see 32 Things with 32 capabilities each: 1,024 rows.
        for _ in 0..<11 {
            let response = try request(
                socketPath: path,
                credential: credential,
                operation: "snapshot",
                fields: [
                    "watermark": watermark.map { $0 as Any } ?? NSNull(),
                    "after": after.map { $0 as Any } ?? NSNull(),
                    "page_size": 100,
                ]
            )
            let page = try decodeSnapshot(response)
            if let prior = watermark, prior != page.watermark {
                throw LocalHealthError.invalidResponse
            }
            if let prior = authorityEpoch, prior != page.authorityEpoch {
                throw LocalHealthError.invalidResponse
            }
            watermark = page.watermark
            authorityEpoch = page.authorityEpoch
            observations.append(contentsOf: page.observations)
            guard observations.count <= 1_024 else { throw LocalHealthError.invalidResponse }
            guard let next = page.nextAfter else {
                return HomeSnapshot(
                    authorityEpoch: page.authorityEpoch,
                    watermark: page.watermark,
                    observations: observations
                )
            }
            if next == after { throw LocalHealthError.invalidResponse }
            after = next
        }
        throw LocalHealthError.invalidResponse
    }

    static func fetchCatalogue(socketPath path: String, credential: Data) throws -> HomeCatalogue {
        var watermark: Int?
        var authorityEpoch: Int?
        var after: String?
        var things: [HomeThing] = []

        for _ in 0..<4 {
            let response = try request(
                socketPath: path,
                credential: credential,
                operation: "catalogue",
                fields: [
                    "watermark": watermark.map { $0 as Any } ?? NSNull(),
                    "after": after.map { $0 as Any } ?? NSNull(),
                    "page_size": 10,
                ]
            )
            let page = try decodeCatalogue(response)
            if let prior = watermark, prior != page.watermark {
                throw LocalHealthError.invalidResponse
            }
            if let prior = authorityEpoch, prior != page.authorityEpoch {
                throw LocalHealthError.invalidResponse
            }
            if let prior = after, let first = page.things.first, first.id <= prior {
                throw LocalHealthError.invalidResponse
            }
            watermark = page.watermark
            authorityEpoch = page.authorityEpoch
            things.append(contentsOf: page.things)
            guard things.count <= 32 else { throw LocalHealthError.invalidResponse }
            guard let next = page.nextAfter else {
                return HomeCatalogue(
                    authorityEpoch: page.authorityEpoch,
                    watermark: page.watermark,
                    things: things
                )
            }
            if next == after { throw LocalHealthError.invalidResponse }
            after = next
        }
        throw LocalHealthError.invalidResponse
    }

    static func defaultSocketPath() -> String {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        let directory = support.appendingPathComponent("WoTExHome/ipc", isDirectory: true)
        return directory.appendingPathComponent("home.sock").path
    }

    private static func request(
        socketPath path: String,
        credential: Data,
        operation: String,
        fields: [String: Any] = [:],
        allowNotFound: Bool = false
    ) throws -> [String: Any] {
        guard credential.count == 32 else { throw LocalHealthError.invalidCredential }
        try checkPath((path as NSString).deletingLastPathComponent, path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw LocalHealthError.transport }
        defer { _ = Darwin.close(fd) }
        let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw LocalHealthError.transport
        }

        var address = sockaddr_un()
        let pathBytes = Array(path.utf8) + [0]
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw LocalHealthError.invalidSocket
        }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            bytes.copyBytes(from: pathBytes)
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connected != 0 {
            guard errno == EINPROGRESS || errno == EAGAIN else {
                throw LocalHealthError.invalidSocket
            }
            try waitFor(fd, Int16(POLLOUT), deadline: deadline)
            var connectionError: Int32 = 0
            var errorSize = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &connectionError, &errorSize) == 0,
                  connectionError == 0 else {
                throw LocalHealthError.invalidSocket
            }
        }

        var peerUID = uid_t.max
        var peerGID = gid_t.max
        guard getpeereid(fd, &peerUID, &peerGID) == 0, peerUID == geteuid() else {
            throw LocalHealthError.wrongPeer
        }

        let nativeLease = try OperatorCredential.nativeRequestLease(credential, descriptor: fd, deadline: deadline)
        defer { nativeLease?.finish() }
        try nativeLease?.current()

        var request: [String: Any] = [
            "api_version": 1,
            "operation": operation,
            "credential": OperatorCredential.encode(credential),
        ]
        for (key, value) in fields {
            guard request[key] == nil else { throw LocalHealthError.invalidResponse }
            request[key] = value
        }
        let body = try JSONSerialization.data(withJSONObject: request)
        guard body.count <= 65_536 else { throw LocalHealthError.transport }
        var length = UInt32(body.count).bigEndian
        let header = withUnsafeBytes(of: &length) { Data($0) }
        try writeAll(fd, header, deadline: deadline)
        try writeAll(fd, body, deadline: deadline)

        let responseHeader = try readExactly(fd, 4, deadline: deadline)
        let responseLength = responseHeader.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard responseLength > 0 && responseLength <= maxResponseBytes else {
            throw LocalHealthError.invalidResponse
        }
        let response = try readExactly(fd, Int(responseLength), deadline: deadline)
        try nativeLease?.current()
        return try decodeEnvelope(response, allowNotFound: allowNotFound)
    }

    // The explicit-rule SDK constructs and validates its closed typed input.
    // Reuse this client's original peer lease, deadline and strict framing.
    static func ruleTransport(socketPath: String, credential: Data, operation: String,
                              fields: [String: Any], allowNotFound: Bool = false) throws -> [String: Any] {
        guard ["review_rules", "record_rule_review", "admit_rule", "activate_rule", "invoke_rule", "rule_original_status", "rule_current"].contains(operation) else {
            throw LocalHealthError.invalidRuleRequest
        }
        return try request(socketPath: socketPath, credential: credential, operation: operation, fields: fields, allowNotFound: allowNotFound)
    }

    private static func checkPath(_ directory: String, _ socketPath: String) throws {
        var parent = stat()
        var child = stat()
        guard lstat(directory, &parent) == 0,
              parent.st_uid == geteuid(),
              (parent.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              (parent.st_mode & 0o777) == 0o700,
              lstat(socketPath, &child) == 0,
              child.st_uid == geteuid(),
              (child.st_mode & mode_t(S_IFMT)) == mode_t(S_IFSOCK),
              (child.st_mode & 0o777) == 0o600 else {
            throw LocalHealthError.invalidSocket
        }
    }

    private static func waitFor(_ fd: Int32, _ event: Int16, deadline: UInt64) throws {
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { throw LocalHealthError.transport }
            let remaining = (deadline - now + 999_999) / 1_000_000
            let timeout = Int32(min(remaining, UInt64(Int32.max)))
            var descriptor = pollfd(fd: fd, events: event, revents: 0)
            let result = Darwin.poll(&descriptor, 1, timeout)
            if result < 0 && errno == EINTR { continue }
            guard result > 0 else { throw LocalHealthError.transport }
            if descriptor.revents & event != 0 { return }
            throw LocalHealthError.transport
        }
    }

    private static func writeAll(_ fd: Int32, _ data: Data, deadline: UInt64) throws {
        var offset = 0
        while offset < data.count {
            try waitFor(fd, Int16(POLLOUT), deadline: deadline)
            let written = data.withUnsafeBytes { bytes in
                Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), data.count - offset)
            }
            if written < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            guard written > 0 else { throw LocalHealthError.transport }
            offset += written
        }
    }

    private static func readExactly(_ fd: Int32, _ count: Int, deadline: UInt64) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            try waitFor(fd, Int16(POLLIN), deadline: deadline)
            let received = bytes.withUnsafeMutableBytes { buffer in
                Darwin.read(fd, buffer.baseAddress!.advanced(by: offset), count - offset)
            }
            if received < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            guard received > 0 else { throw LocalHealthError.transport }
            offset += received
        }
        return Data(bytes)
    }

    private static func decodeEnvelope(_ data: Data, allowNotFound: Bool) throws -> [String: Any] {
        try StrictLocalJSON.check(data)
        guard let value = try? JSONSerialization.jsonObject(with: data),
              let response = value as? [String: Any],
              wireInteger(response["api_version"]) == 1,
              let outcome = response["outcome"] as? String else {
            throw LocalHealthError.invalidResponse
        }
        if outcome == "error" {
            guard Set(response.keys) == Set(["api_version", "outcome", "reason"]),
                  let reason = response["reason"] as? String, !reason.isEmpty, reason.utf8.count <= 128 else {
                throw LocalHealthError.invalidResponse
            }
            throw LocalHealthError.server(reason)
        }
        if outcome == "not_found", allowNotFound {
            guard Set(response.keys) == Set(["api_version", "outcome"]) else {
                throw LocalHealthError.invalidResponse
            }
            return response
        }
        guard outcome == "ok" else { throw LocalHealthError.invalidResponse }
        return response
    }

    private static func decodeHealth(_ response: [String: Any]) throws -> HomeHealth {
        guard let health = response["health"] as? [String: Any],
              let revision = health["store_revision"] as? Int, revision >= 0,
              let epoch = health["authority_epoch"] as? Int, epoch >= 0,
              let ruleGeneration = health["rule_generation"] as? Int, ruleGeneration >= 0,
              let held = health["held_requests"] as? Int, held >= 0,
              let queued = health["queued_requests"] as? Int, queued >= 0,
              let claimed = health["claimed_requests"] as? Int, claimed >= 0,
              let unknown = health["unknown_outcomes"] as? Int, unknown >= 0,
              let things = health["active_things"] as? Int, things >= 0,
              let principals = health["active_principals"] as? Int, principals >= 0,
              let writable = health["writable"] as? Bool,
              let dispatch = health["dispatch_enabled"] as? Bool else {
            throw LocalHealthError.invalidResponse
        }
        return HomeHealth(
            revision: revision,
            authorityEpoch: epoch,
            ruleGeneration: ruleGeneration,
            heldRequests: held,
            queuedRequests: queued,
            claimedRequests: claimed,
            unknownOutcomes: unknown,
            activeThings: things,
            activePrincipals: principals,
            writable: writable,
            dispatchEnabled: dispatch
        )
    }

    private struct SnapshotPage {
        let authorityEpoch: Int
        let watermark: Int
        let observations: [HomeObservation]
        let nextAfter: [String: String]?
    }

    private struct CataloguePage {
        let authorityEpoch: Int
        let watermark: Int
        let things: [HomeThing]
        let nextAfter: String?
    }

    private static func decodeCatalogue(_ response: [String: Any]) throws -> CataloguePage {
        guard let catalogue = response["catalogue"] as? [String: Any],
              let epoch = catalogue["authority_epoch"] as? Int, epoch >= 1,
              let watermark = catalogue["watermark"] as? Int, watermark >= 0,
              let rawItems = catalogue["items"] as? [[String: Any]],
              rawItems.count <= 10,
              let rawAfter = catalogue["next_after"] else {
            throw LocalHealthError.invalidResponse
        }

        let things = try rawItems.map(decodeThing)
        for (previous, current) in zip(things, things.dropFirst())
        where current.id <= previous.id {
            throw LocalHealthError.invalidResponse
        }
        let nextAfter: String?
        if rawAfter is NSNull {
            nextAfter = nil
        } else if let cursor = rawAfter as? String,
                  !things.isEmpty,
                  things.last?.id == cursor {
            nextAfter = cursor
        } else {
            throw LocalHealthError.invalidResponse
        }

        return CataloguePage(
            authorityEpoch: epoch,
            watermark: watermark,
            things: things,
            nextAfter: nextAfter
        )
    }

    private static func decodeThing(_ raw: [String: Any]) throws -> HomeThing {
        guard let id = raw["id"] as? String, validID(id),
              let role = raw["role"] as? String,
              role == "Light" || role == "SmokeDetector",
              let profile = raw["profile_ref"] as? String, !profile.isEmpty,
              let capabilities = raw["capabilities"] as? [[String: Any]],
              (1...32).contains(capabilities.count),
              let revision = raw["resource_revision"] as? Int, revision >= 0 else {
            throw LocalHealthError.invalidResponse
        }
        return HomeThing(
            id: id,
            role: role,
            profileRef: profile,
            capabilityCount: capabilities.count,
            resourceRevision: revision,
            powerWritable: role == "Light" && capabilities.filter { capability in
                capability["key"] as? String == "power" &&
                    capability["thing_id"] as? String == id &&
                    capability["role"] as? String == role &&
                    capability["profile_ref"] as? String == profile &&
                    capability["value_kind"] as? String == "boolean" &&
                    capability["risk_class"] as? String == "ordinary" &&
                    (capability["operations"] as? [String])?.contains("write") == true
            }.count == 1
        )
    }

    private static func decodeSnapshot(_ response: [String: Any]) throws -> SnapshotPage {
        guard let snapshot = response["snapshot"] as? [String: Any],
              let epoch = snapshot["authority_epoch"] as? Int, epoch >= 1,
              let watermark = snapshot["watermark"] as? Int, watermark >= 0,
              let rawItems = snapshot["items"] as? [[String: Any]],
              rawItems.count <= 100,
              let rawAfter = snapshot["next_after"] else {
            throw LocalHealthError.invalidResponse
        }

        let observations = try rawItems.map(decodeObservation)
        let nextAfter: [String: String]?
        if rawAfter is NSNull {
            nextAfter = nil
        } else if let cursor = rawAfter as? [String: String],
                  cursor.count == 2,
                  let thing = cursor["thing_id"], !thing.isEmpty,
                  let capability = cursor["capability_key"], !capability.isEmpty,
                  !observations.isEmpty,
                  observations.last?.thingID == thing,
                  observations.last?.capabilityKey == capability {
            nextAfter = cursor
        } else {
            throw LocalHealthError.invalidResponse
        }

        return SnapshotPage(
            authorityEpoch: epoch,
            watermark: watermark,
            observations: observations,
            nextAfter: nextAfter
        )
    }

    private static func decodeObservation(_ raw: [String: Any]) throws -> HomeObservation {
        guard let thing = raw["thing_id"] as? String, !thing.isEmpty,
              let capability = raw["capability_key"] as? String, !capability.isEmpty,
              let quality = raw["quality"] as? String,
              quality == "reported" || quality == "unknown",
              let trust = raw["trust"] as? String,
              ["unauthenticated_local", "authenticated_device", "bridge_attested", "synthetic_lab"]
                  .contains(trust),
              let revision = raw["revision"] as? Int, revision >= 0,
              let value = raw["value"] else {
            throw LocalHealthError.invalidResponse
        }

        let text: String
        if quality == "unknown" {
            guard value is NSNull else { throw LocalHealthError.invalidResponse }
            text = "Unknown"
        } else {
            guard let map = value as? [String: Any] else {
                throw LocalHealthError.invalidResponse
            }
            text = try valueText(map)
        }

        return HomeObservation(
            thingID: thing,
            capabilityKey: capability,
            quality: quality,
            trust: trust,
            valueText: text,
            revision: revision
        )
    }

    private static func valueText(_ value: [String: Any]) throws -> String {
        switch value["type"] as? String {
        case "boolean":
            guard let on = value["value"] as? Bool else { break }
            return on ? "On" : "Off"
        case "fraction":
            guard let ppm = value["ppm"] as? Int, (0...1_000_000).contains(ppm) else { break }
            return String(format: "%.1f%%", Double(ppm) / 10_000.0)
        case "kelvin":
            guard let kelvin = value["kelvin"] as? Int, kelvin > 0 else { break }
            return "\(kelvin) K"
        case "hsv":
            guard let hue = value["hue_mdeg"] as? Int, (0..<360_000).contains(hue),
                  let saturation = value["saturation_ppm"] as? Int,
                  (0...1_000_000).contains(saturation) else { break }
            return String(format: "%.1f° · %.1f%%", Double(hue) / 1_000.0,
                          Double(saturation) / 10_000.0)
        case "xy":
            guard let x = value["x_ppm"] as? Int, let y = value["y_ppm"] as? Int,
                  x >= 0, y >= 0, x + y <= 1_000_000 else { break }
            return "xy \(x), \(y) ppm"
        case "smoke_state":
            guard let state = value["state"] as? String,
                  state == "clear" || state == "alarm" else { break }
            return state == "alarm" ? "Alarm reported" : "Clear reported"
        default:
            break
        }
        throw LocalHealthError.invalidResponse
    }
}

// Check duplicate names and container depth before Foundation allocates a response.
// Key strings are decoded, so escaped aliases cannot hide a repeated name.
enum StrictLocalJSON {
    static func check(_ data: Data) throws {
        let bytes = Array(data)
        var stack: [(object: Bool, key: Bool, names: Set<String>)] = []
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 34 {
                let start = index
                index += 1
                var escaped = false
                while index < bytes.count {
                    let next = bytes[index]
                    if !escaped && next == 34 { break }
                    if !escaped && next == 92 { escaped = true } else { escaped = false }
                    index += 1
                }
                guard index < bytes.count else { throw LocalHealthError.invalidResponse }
                if let last = stack.indices.last, stack[last].object, stack[last].key {
                    guard index - start <= 1_024,
                          let name = try JSONSerialization.jsonObject(with: Data(bytes[start...index]), options: .fragmentsAllowed) as? String,
                          stack[last].names.count < 256, stack[last].names.insert(name).inserted else {
                        throw LocalHealthError.invalidResponse
                    }
                    stack[last].key = false
                }
            } else if byte == 123 || byte == 91 {
                guard stack.count < 16 else { throw LocalHealthError.invalidResponse }
                stack.append((byte == 123, byte == 123, []))
            } else if byte == 125 || byte == 93 {
                guard let last = stack.last, last.object == (byte == 125) else { throw LocalHealthError.invalidResponse }
                stack.removeLast()
            } else if byte == 44, let last = stack.indices.last, stack[last].object {
                stack[last].key = true
            }
            index += 1
        }
        guard stack.isEmpty else { throw LocalHealthError.invalidResponse }
    }
}

struct HomeLIFXCandidate: Sendable, Identifiable {
    let reference: String
    let interfaceID: String
    let endpoint: String
    let claimedStableID: String?
    var id: String { reference }
}

struct HomeLIFXCapture: Sendable {
    let session: String
    let candidates: [HomeLIFXCandidate]
}

struct HomeLIFXInterview: Sendable {
    let candidate: String
    let identity: HomeProfileIdentity
}

struct HomeProfileOperation: Equatable, Sendable {
    static let commonFields = ["action", "authority_epoch", "operation_id", "expected_revision", "artifact_digest", "expected_trust_revision"]
    static let selectionFields = ["target_id", "expected_resource_revision", "expected_binding_revision", "expected_selection_generation", "expected_policy_generation", "expected_rule_generation", "session_ref", "candidate_ref", "review_ref"]
    static let revocationFields = ["target_id", "expected_resource_revision", "expected_selection_generation"]
    let bytes: Data
    let action: String
    let authorityEpoch: Int
    let operationID: String
    let expectedRevision: Int
    let artifactDigest: String
    let expectedTrustRevision: Int
    let inputDigest: String

    init(_ input: [String: Any]) throws {
        guard let action = input["action"] as? String, ["approve", "revoke", "select", "revoke_selection"].contains(action) else { throw LocalHealthError.invalidProfileRequest }
        let fields = Self.commonFields + (action == "select" ? Self.selectionFields : action == "revoke_selection" ? Self.revocationFields : [])
        guard Set(input.keys) == Set(fields),
              let epoch = LocalHealthClient.profileInteger(input["authority_epoch"]), epoch >= 1,
              let operation = input["operation_id"] as? String, LocalHealthClient.profileID(operation),
              let digest = input["artifact_digest"] as? String, LocalHealthClient.profileDigest(digest),
              let expected = LocalHealthClient.profileInteger(input["expected_revision"]), expected >= 0,
              let trust = LocalHealthClient.profileInteger(input["expected_trust_revision"]), trust >= 0 else { throw LocalHealthError.invalidProfileRequest }
        for field in fields.dropFirst() where !["operation_id", "artifact_digest"].contains(field) {
            if field == "authority_epoch" || field.hasPrefix("expected_") {
                guard let value = LocalHealthClient.profileInteger(input[field]), value >= 0 else { throw LocalHealthError.invalidProfileRequest }
            } else {
                guard let value = input[field] as? String, LocalHealthClient.profileID(value) else { throw LocalHealthError.invalidProfileRequest }
            }
        }
        self.bytes = try JSONSerialization.data(withJSONObject: input, options: .sortedKeys)
        self.action = action; self.authorityEpoch = epoch; self.operationID = operation
        self.expectedRevision = expected; self.artifactDigest = digest; self.expectedTrustRevision = trust
        let canonical = try JSONSerialization.data(withJSONObject: ["wotex-home.profile-operation.v1", fields.map { input[$0]! }], options: .withoutEscapingSlashes)
        self.inputDigest = LocalHealthClient.profileSHA(canonical)
    }

    func fields() throws -> [String: Any] {
        guard let input = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw LocalHealthError.invalidProfileRequest }
        return input
    }
}

struct HomeProfileArtifact: Sendable {
    let artifactDigest: String
    let projectionDigest: String
    let registryDigest: String
    let id: String
    let version: String
    let binding: String
    var profileRef: String { id + ":" + version }
}

struct HomeProfileItem: Sendable, Identifiable {
    let artifact: HomeProfileArtifact
    let trustRevision: Int
    let trustGeneration: Int
    let trustAuthor: String
    let state: String
    let byteAvailability: String
    var id: String { artifact.artifactDigest }
}

struct HomeProfileCatalogue: Sendable {
    let storeRevision: Int
    let authorityEpoch: Int
    let policyGeneration: Int
    let items: [HomeProfileItem]
}

struct HomeProfileIdentity: Sendable, Equatable {
    let stableID: String
    let manufacturer: String
    let model: String
    let firmware: String
    var description: String { "\(stableID) · \(manufacturer) · \(model) · firmware \(firmware)" }
}

struct HomeProfileTarget: Sendable {
    let targetID: String
    let storeRevision: Int
    let authorityEpoch: Int
    let policyGeneration: Int
    let ruleGeneration: Int
    let status: String
    let profileRef: String?
    let resourceRevision: Int
    let bindingRevision: Int?
    let selectionRevision: Int
    let selectionGeneration: Int
    let selectionState: String
    let artifactDigest: String?
    let identity: HomeProfileIdentity?
    let identityStatus: String
    let currentUse: String
    let declaration: Data?
    let qualificationHead: Data?
}

struct HomeProfileReview: Sendable {
    let token: String
    let digest: String
    let state: String
    let remainingMilliseconds: Int
    let prior: HomeProfileIdentity?
    let captured: HomeProfileIdentity
    let summary: Data
    let basis: Data
    let targetID: String
    let artifactDigest: String
}

struct HomeProfileReceipt: Sendable {
    let authorityEpoch: Int
    let operationID: String
    let action: String
    let inputDigest: String
    let expectedRevision: Int
    let artifactDigest: String
    let finalRevision: Int
    let changedTargets: Int
    let invalidatedRequests: Int
    let unknownOutcomes: Int
    let previousTrustRevision: Int
    let trustGeneration: Int
    let policyGeneration: Int
}

enum HomeProfilePreparation: Sendable { case review(HomeProfileReview), committed(HomeProfileReceipt) }
enum HomeProfileReceiptLookup: Sendable { case found(HomeProfileReceipt), notFound }
enum HomeProfileReviewLookup: Sendable { case found(HomeProfileReview), notFound }

struct HomeProfileCollection: Sendable {
    let removedObjects: Int
    let removedBytes: Int
    let objectCount: Int
    let totalBytes: Int
    let digests: [String]
}

extension LocalHealthClient {
    static func profileInteger(_ value: Any?) -> Int? { wireInteger(value) }
    static func profileID(_ value: String) -> Bool { validID(value) }
    static func profileDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func profileSHA(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }

    static func discoverProfileCandidates(credential: Data) throws -> HomeLIFXCapture {
        try discoverProfileCandidates(socketPath: defaultSocketPath(), credential: credential)
    }
    static func discoverProfileCandidates(socketPath: String, credential: Data) throws -> HomeLIFXCapture {
        let response = try request(socketPath: socketPath, credential: credential, operation: "lifx_discover")
        let raw = try profileObject(response, "capture", keys: ["session_ref", "candidates"])
        let session = try profileString(raw, "session_ref")
        guard let rows = raw["candidates"] as? [[String: Any]], rows.count <= 128 else { throw LocalHealthError.invalidResponse }
        var seen: Set<String> = []
        let candidates = try rows.map { row in
            guard Set(row.keys) == Set(["candidate_ref", "interface_id", "source_endpoint", "claimed_stable_id", "trust_class"]), row["trust_class"] as? String == "untrusted_network",
                  let endpoint = row["source_endpoint"] as? String, !endpoint.isEmpty, endpoint.utf8.count <= 256,
                  endpoint.utf8.allSatisfy({ (48...57).contains($0) || $0 == 46 || $0 == 58 }) else { throw LocalHealthError.invalidResponse }
            let reference = try profileString(row, "candidate_ref"); let interface = try profileString(row, "interface_id")
            let stable = try profileNullableString(row, "claimed_stable_id")
            guard seen.insert(reference).inserted else { throw LocalHealthError.invalidResponse }
            return HomeLIFXCandidate(reference: reference, interfaceID: interface, endpoint: endpoint, claimedStableID: stable)
        }
        return HomeLIFXCapture(session: session, candidates: candidates)
    }
    static func interviewProfileCandidate(credential: Data, session: String, candidate: String) throws -> HomeLIFXInterview {
        try interviewProfileCandidate(socketPath: defaultSocketPath(), credential: credential, session: session, candidate: candidate)
    }
    static func interviewProfileCandidate(socketPath: String, credential: Data, session: String, candidate: String) throws -> HomeLIFXInterview {
        guard validID(session), validID(candidate) else { throw LocalHealthError.invalidProfileRequest }
        let response = try request(socketPath: socketPath, credential: credential, operation: "lifx_interview", fields: ["session_ref": session, "candidate_ref": candidate])
        let raw = try profileObject(response, "interview", keys: ["candidate_ref", "transport", "manufacturer_reported", "model_reported", "firmware_reported", "stable_id_claim", "packaged_profiles"])
        guard raw["candidate_ref"] as? String == candidate, raw["transport"] as? String == "udp",
              let profiles = raw["packaged_profiles"] as? [[String: Any]], profiles.count <= 64 else { throw LocalHealthError.invalidResponse }
        guard let stable = raw["stable_id_claim"] as? String, let manufacturer = raw["manufacturer_reported"] as? String, let model = raw["model_reported"] as? String, let firmware = raw["firmware_reported"] as? String,
              let identity = try profileIdentity(["stable_id": stable, "manufacturer": manufacturer, "model": model, "firmware": firmware], allowNil: false) else { throw LocalHealthError.invalidResponse }
        var seenProfiles: Set<String> = []
        for profile in profiles {
            guard Set(profile.keys) == Set(["profile_ref", "transport", "manufacturer", "model", "firmware_versions", "qualification_ref", "qualification_status", "capability_keys"]),
                  profile["transport"] as? String == "udp", profile["manufacturer"] as? String == identity.manufacturer, profile["model"] as? String == identity.model,
                  profile["qualification_status"] as? String == "pending_physical_evidence",
                  let versions = profile["firmware_versions"] as? [String], versions.count <= 32, Set(versions).count == versions.count, versions.contains(identity.firmware), versions.allSatisfy(validID),
                  let keys = profile["capability_keys"] as? [String], (1...32).contains(keys.count), Set(keys).count == keys.count, keys.allSatisfy(validID) else { throw LocalHealthError.invalidResponse }
            let reference = try profileString(profile, "profile_ref")
            guard seenProfiles.insert(reference).inserted else { throw LocalHealthError.invalidResponse }
            _ = try profileString(profile, "qualification_ref")
        }
        return HomeLIFXInterview(candidate: candidate, identity: identity)
    }

    static func importProfile(credential: Data, bytes: Data) throws -> HomeProfileArtifact {
        try importProfile(socketPath: defaultSocketPath(), credential: credential, bytes: bytes)
    }
    static func importProfile(socketPath: String, credential: Data, bytes: Data) throws -> HomeProfileArtifact {
        guard (1...32_768).contains(bytes.count), String(data: bytes, encoding: .utf8) != nil else { throw LocalHealthError.invalidProfileRequest }
        let response = try request(socketPath: socketPath, credential: credential, operation: "profile_import", fields: ["artifact_base64": OperatorCredential.encode(bytes)])
        let item = try profileObject(response, "profile_artifact", keys: ["artifact_digest", "projection_digest", "registry_digest", "id", "version", "profile_ref", "binding", "authority_changed"])
        guard profileBoolean(item["authority_changed"]) == false else { throw LocalHealthError.invalidResponse }
        let artifact = try profileArtifact(item)
        guard artifact.artifactDigest == profileSHA(bytes), item["profile_ref"] as? String == artifact.profileRef else { throw LocalHealthError.invalidResponse }
        return artifact
    }

    static func fetchProfiles(credential: Data) throws -> HomeProfileCatalogue {
        try fetchProfiles(socketPath: defaultSocketPath(), credential: credential)
    }
    static func fetchProfiles(socketPath: String, credential: Data) throws -> HomeProfileCatalogue {
        let response = try request(socketPath: socketPath, credential: credential, operation: "profiles")
        let raw = try profileObject(response, "profile_catalogue", keys: ["store_revision", "authority_epoch", "policy_generation", "items"])
        let revision = try profileCounter(raw, "store_revision")
        let epoch = try profileCounter(raw, "authority_epoch", minimum: 1)
        let policy = try profileCounter(raw, "policy_generation", maximum: 1_024)
        guard let rows = raw["items"] as? [[String: Any]], rows.count <= 64 else { throw LocalHealthError.invalidResponse }
        var seen: Set<String> = []; var labels: Set<String> = []
        let items = try rows.map { row in
            guard Set(row.keys) == Set(["artifact_digest", "projection_digest", "registry_digest", "id", "version", "binding", "trust_revision", "trust_generation", "trust_author", "state", "byte_availability", "qualification_status"]),
                  let state = row["state"] as? String, ["approved", "revoked", "author_unavailable"].contains(state),
                  let availability = row["byte_availability"] as? String, ["available", "unavailable"].contains(availability),
                  row["qualification_status"] as? String == "pending_physical_evidence" else { throw LocalHealthError.invalidResponse }
            let artifact = try profileArtifact(row)
            let trust = try profileCounter(row, "trust_revision", minimum: 1, maximum: revision)
            let generation = try profileCounter(row, "trust_generation", minimum: 1, maximum: policy)
            let author = try profileString(row, "trust_author")
            guard seen.insert(artifact.artifactDigest).inserted, labels.insert(artifact.profileRef).inserted else { throw LocalHealthError.invalidResponse }
            return HomeProfileItem(artifact: artifact, trustRevision: trust, trustGeneration: generation, trustAuthor: author, state: state, byteAvailability: availability)
        }
        return HomeProfileCatalogue(storeRevision: revision, authorityEpoch: epoch, policyGeneration: policy, items: items)
    }

    static func fetchProfileTarget(credential: Data, targetID: String) throws -> HomeProfileTarget {
        try fetchProfileTarget(socketPath: defaultSocketPath(), credential: credential, targetID: targetID)
    }
    static func fetchProfileTarget(socketPath: String, credential: Data, targetID: String) throws -> HomeProfileTarget {
        guard validID(targetID) else { throw LocalHealthError.invalidProfileRequest }
        let response = try request(socketPath: socketPath, credential: credential, operation: "profile_target", fields: ["thing_id": targetID])
        let raw = try profileObject(response, "profile_target", keys: ["target_id", "store_revision", "authority_epoch", "policy_generation", "rule_generation", "status", "profile_ref", "declaration", "resource_revision", "binding_revision", "identity", "identity_status", "selection_revision", "selection_generation", "selection_state", "artifact_digest", "current_use", "qualification_head"])
        let revision = try profileCounter(raw, "store_revision")
        let epoch = try profileCounter(raw, "authority_epoch", minimum: 1)
        let policy = try profileCounter(raw, "policy_generation", maximum: 1_024)
        let rules = try profileCounter(raw, "rule_generation", minimum: 1, maximum: revision)
        let resource = try profileCounter(raw, "resource_revision", maximum: revision)
        let selection = try profileCounter(raw, "selection_revision", maximum: revision)
        let generation = try profileCounter(raw, "selection_generation", maximum: selection)
        guard raw["target_id"] as? String == targetID,
              let status = raw["status"] as? String, ["absent", "active", "revoked"].contains(status),
              let state = raw["selection_state"] as? String, ["absent", "selected", "revoked"].contains(state),
              let identityStatus = raw["identity_status"] as? String, ["absent", "reviewed", "review_required"].contains(identityStatus),
              let use = raw["current_use"] as? String, ["usable", "target_unavailable", "profile_selection_unavailable", "profile_selection_revoked", "profile_trust_changed", "profile_author_unavailable", "profile_artifact_unavailable", "profile_basis_changed", "profile_lifecycle_required"].contains(use) else { throw LocalHealthError.invalidResponse }
        let binding: Int?
        if raw["binding_revision"] is NSNull { binding = nil }
        else { binding = try profileCounter(raw, "binding_revision", maximum: revision) }
        let profile = try profileNullableString(raw, "profile_ref")
        let digest = try profileNullableDigest(raw, "artifact_digest")
        let identity = try profileIdentity(raw["identity"], allowNil: true)
        let declaration: Data?
        if raw["declaration"] is NSNull { declaration = nil }
        else {
            guard let declarationProfile = profile, let value = raw["declaration"] as? [String: Any], Set(value.keys) == Set(["id", "role", "profile_ref", "capabilities"]),
                  value["id"] as? String == targetID, value["profile_ref"] as? String == profile,
                  let role = value["role"] as? String, ["Light", "SmokeDetector"].contains(role),
                  let capabilities = value["capabilities"] as? [[String: Any]], (1...32).contains(capabilities.count) else { throw LocalHealthError.invalidResponse }
            try profileDeclaration(capabilities, target: targetID, role: role, profile: declarationProfile)
            declaration = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted])
        }
        let head: Data?
        if raw["qualification_head"] is NSNull { head = nil }
        else {
            guard let value = raw["qualification_head"] as? [String: Any], Set(value.keys) == Set(["profile_ref", "resource_revision", "identity_digest", "basis_digest", "registry_digest", "runtime_digest", "evidence_ref", "status", "revision"]),
                  let qstate = value["status"] as? String, ["qualified", "revoked"].contains(qstate) else { throw LocalHealthError.invalidResponse }
            _ = try profileString(value, "profile_ref"); _ = try profileString(value, "evidence_ref")
            _ = try profileCounter(value, "revision", minimum: 1, maximum: revision)
            _ = try profileCounter(value, "resource_revision", maximum: resource)
            for field in ["identity_digest", "basis_digest", "registry_digest", "runtime_digest"] { _ = try profileDigestField(value, field) }
            head = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted])
        }
        guard (state == "absent" && generation == 0 && selection == 0 && digest == nil) || (state != "absent" && generation > 0 && selection > 0 && digest != nil),
              (identityStatus == "reviewed" && identity != nil && (binding ?? 0) > 0) || (identityStatus != "reviewed" && identity == nil) else { throw LocalHealthError.invalidResponse }
        if status == "absent" {
            guard profile == nil, declaration == nil, resource == 0, binding == 0, identityStatus == "absent", state == "absent", head == nil, use == "target_unavailable" else { throw LocalHealthError.invalidResponse }
        } else {
            guard profile != nil, declaration != nil, identityStatus != "absent", status != "revoked" || use == "target_unavailable", state != "revoked" || use != "usable" else { throw LocalHealthError.invalidResponse }
        }
        return HomeProfileTarget(targetID: targetID, storeRevision: revision, authorityEpoch: epoch, policyGeneration: policy, ruleGeneration: rules, status: status, profileRef: profile, resourceRevision: resource, bindingRevision: binding, selectionRevision: selection, selectionGeneration: generation, selectionState: state, artifactDigest: digest, identity: identity, identityStatus: identityStatus, currentUse: use, declaration: declaration, qualificationHead: head)
    }

    static func prepareProfile(credential: Data, input: HomeProfileOperation) throws -> HomeProfilePreparation {
        try prepareProfile(socketPath: defaultSocketPath(), credential: credential, input: input)
    }
    static func prepareProfile(socketPath: String, credential: Data, input: HomeProfileOperation) throws -> HomeProfilePreparation {
        guard input.action == "select" else { throw LocalHealthError.invalidProfileRequest }
        let response = try request(socketPath: socketPath, credential: credential, operation: "profile_prepare", fields: ["selection": try input.fields()])
        if response["profile_receipt"] != nil { return .committed(try profileReceipt(response, input: input)) }
        return .review(try profileReview(response, input: input))
    }
    static func changeProfile(credential: Data, input: HomeProfileOperation) throws -> HomeProfileReceipt {
        try changeProfile(socketPath: defaultSocketPath(), credential: credential, input: input)
    }
    static func changeProfile(socketPath: String, credential: Data, input: HomeProfileOperation) throws -> HomeProfileReceipt {
        let response = try request(socketPath: socketPath, credential: credential, operation: "profile_change", fields: ["change": try input.fields()])
        return try profileReceipt(response, input: input)
    }
    static func fetchProfileOperation(credential: Data, authorityEpoch: Int, operationID: String, input: HomeProfileOperation? = nil) throws -> HomeProfileReceiptLookup {
        try fetchProfileOperation(socketPath: defaultSocketPath(), credential: credential, authorityEpoch: authorityEpoch, operationID: operationID, input: input)
    }
    static func fetchProfileOperation(socketPath: String, credential: Data, authorityEpoch: Int, operationID: String, input: HomeProfileOperation? = nil) throws -> HomeProfileReceiptLookup {
        guard authorityEpoch > 0, validID(operationID), input == nil || (input?.authorityEpoch == authorityEpoch && input?.operationID == operationID) else { throw LocalHealthError.invalidProfileRequest }
        let response = try request(socketPath: socketPath, credential: credential, operation: "profile_operation_status", fields: ["authority_epoch": authorityEpoch, "operation_id": operationID], allowNotFound: true)
        if response["outcome"] as? String == "not_found" { return .notFound }
        let receipt = try profileReceipt(response, input: input)
        guard receipt.authorityEpoch == authorityEpoch, receipt.operationID == operationID else { throw LocalHealthError.invalidResponse }
        return .found(receipt)
    }
    static func fetchProfileReview(credential: Data, token: String, input: HomeProfileOperation? = nil) throws -> HomeProfileReviewLookup {
        try fetchProfileReview(socketPath: defaultSocketPath(), credential: credential, token: token, input: input)
    }
    static func fetchProfileReview(socketPath: String, credential: Data, token: String, input: HomeProfileOperation? = nil) throws -> HomeProfileReviewLookup {
        guard validID(token) else { throw LocalHealthError.invalidProfileRequest }
        let response = try request(socketPath: socketPath, credential: credential, operation: "profile_review_status", fields: ["review_token": token], allowNotFound: true)
        if response["outcome"] as? String == "not_found" { return .notFound }
        let review = try profileReview(response, input: input)
        guard review.token == token else { throw LocalHealthError.invalidResponse }
        return .found(review)
    }
    static func cancelProfileReview(credential: Data, token: String) throws -> Bool {
        try cancelProfileReview(socketPath: defaultSocketPath(), credential: credential, token: token)
    }
    static func cancelProfileReview(socketPath: String, credential: Data, token: String) throws -> Bool {
        guard validID(token) else { throw LocalHealthError.invalidProfileRequest }
        let response = try request(socketPath: socketPath, credential: credential, operation: "profile_review_cancel", fields: ["review_token": token], allowNotFound: true)
        if response["outcome"] as? String == "not_found" { return false }
        guard Set(response.keys) == Set(["api_version", "outcome", "profile_review_cancelled"]), profileBoolean(response["profile_review_cancelled"]) == true else { throw LocalHealthError.invalidResponse }
        return true
    }
    static func collectProfiles(credential: Data) throws -> HomeProfileCollection {
        try collectProfiles(socketPath: defaultSocketPath(), credential: credential)
    }
    static func collectProfiles(socketPath: String, credential: Data) throws -> HomeProfileCollection {
        let response = try request(socketPath: socketPath, credential: credential, operation: "profiles_collect")
        let raw = try profileObject(response, "profile_collection", keys: ["removed_objects", "removed_bytes", "object_count", "total_bytes", "digests"])
        let removed = try profileCounter(raw, "removed_objects", maximum: 128)
        let removedBytes = try profileCounter(raw, "removed_bytes", maximum: 4_194_304)
        let count = try profileCounter(raw, "object_count", maximum: 128)
        let total = try profileCounter(raw, "total_bytes", maximum: 4_194_304)
        guard let digests = raw["digests"] as? [String], digests.count <= count, Set(digests).count == digests.count, digests.allSatisfy(profileDigest), digests == digests.sorted() else { throw LocalHealthError.invalidResponse }
        return HomeProfileCollection(removedObjects: removed, removedBytes: removedBytes, objectCount: count, totalBytes: total, digests: digests)
    }

    private static func profileReceipt(_ response: [String: Any], input: HomeProfileOperation?) throws -> HomeProfileReceipt {
        let raw = try profileObject(response, "profile_receipt", keys: ["authority_epoch", "operation_id", "action", "input_digest", "expected_revision", "artifact_digest", "final_revision", "changed_targets", "invalidated_requests", "unknown_outcomes", "previous_trust_revision", "trust_generation", "policy_generation"])
        let epoch = try profileCounter(raw, "authority_epoch", minimum: 1)
        let operation = try profileString(raw, "operation_id")
        let action = try profileString(raw, "action")
        let expected = try profileCounter(raw, "expected_revision")
        let final = try profileCounter(raw, "final_revision", minimum: 1)
        let changed = try profileCounter(raw, "changed_targets", maximum: 64)
        let invalidated = try profileCounter(raw, "invalidated_requests", maximum: 1_024)
        let unknown = try profileCounter(raw, "unknown_outcomes", maximum: invalidated)
        let previous = try profileCounter(raw, "previous_trust_revision", maximum: expected)
        let generation = try profileCounter(raw, "trust_generation", minimum: 1)
        let policy = try profileCounter(raw, "policy_generation", minimum: 1, maximum: 1_024)
        let digest = try profileDigestField(raw, "artifact_digest")
        let inputDigest = try profileDigestField(raw, "input_digest")
        guard ["approve", "revoke", "select", "revoke_selection"].contains(action), final > expected,
              action != "approve" || (changed == 0 && invalidated == 0 && unknown == 0 && final - expected == 1),
              !["select", "revoke_selection"].contains(action) || changed == 1, generation <= policy else { throw LocalHealthError.invalidResponse }
        if let input {
            guard epoch == input.authorityEpoch, operation == input.operationID, action == input.action, expected == input.expectedRevision, digest == input.artifactDigest, previous == input.expectedTrustRevision, inputDigest == input.inputDigest else { throw LocalHealthError.invalidResponse }
        }
        return HomeProfileReceipt(authorityEpoch: epoch, operationID: operation, action: action, inputDigest: inputDigest, expectedRevision: expected, artifactDigest: digest, finalRevision: final, changedTargets: changed, invalidatedRequests: invalidated, unknownOutcomes: unknown, previousTrustRevision: previous, trustGeneration: generation, policyGeneration: policy)
    }

    private static func profileReview(_ response: [String: Any], input: HomeProfileOperation?) throws -> HomeProfileReview {
        let raw = try profileObject(response, "profile_review", keys: ["review_token", "review_digest", "state", "remaining_ms", "summary", "identity", "basis"])
        let token = try profileString(raw, "review_token"); let digest = try profileDigestField(raw, "review_digest")
        let remaining = try profileCounter(raw, "remaining_ms", maximum: 60_000)
        guard let state = raw["state"] as? String, ["pending", "checked_out"].contains(state),
              let identity = raw["identity"] as? [String: Any], Set(identity.keys) == Set(["prior", "captured", "method"]), identity["method"] as? String == "legacy_tofu",
              let basis = raw["basis"] as? [String: Any], Set(basis.keys) == Set(["principal_id", "authority_epoch", "store_revision", "profile_policy_generation", "rule_generation", "maintenance_revision", "target_id", "resource_revision", "binding_revision", "selection_revision", "selection_generation", "trust_revision", "trust_generation", "artifact_digest", "projection_digest", "registry_digest", "profile_ref"]),
              let summary = raw["summary"] as? [String: Any] else { throw LocalHealthError.invalidResponse }
        let prior = try profileIdentity(identity["prior"], allowNil: true)
        guard let captured = try profileIdentity(identity["captured"], allowNil: false) else { throw LocalHealthError.invalidResponse }
        let target = try profileString(basis, "target_id"); let rawDigest = try profileDigestField(basis, "artifact_digest")
        _ = try profileString(basis, "principal_id"); _ = try profileString(basis, "profile_ref")
        _ = try profileDigestField(basis, "projection_digest"); _ = try profileDigestField(basis, "registry_digest")
        let revision = try profileCounter(basis, "store_revision", minimum: 1)
        for field in ["authority_epoch", "profile_policy_generation", "rule_generation", "maintenance_revision", "trust_revision", "trust_generation"] { _ = try profileCounter(basis, field, minimum: 1, maximum: field == "authority_epoch" ? Int.max : revision) }
        for field in ["resource_revision", "binding_revision", "selection_revision", "selection_generation"] { _ = try profileCounter(basis, field, maximum: revision) }
        guard (prior == nil && profileInteger(basis["resource_revision"]) == 0 && profileInteger(basis["binding_revision"]) == 0 && profileInteger(basis["selection_generation"]) == 0 && profileInteger(basis["selection_revision"]) == 0) || (prior != nil && (profileInteger(basis["binding_revision"]) ?? 0) > 0),
              prior == nil || (prior?.stableID == captured.stableID && prior?.manufacturer == captured.manufacturer && prior?.model == captured.model) else { throw LocalHealthError.invalidResponse }
        try profileSummary(summary, basis: basis, initial: prior == nil)
        if let input {
            let fields = try input.fields()
            let pairs = ["authority_epoch": "authority_epoch", "expected_revision": "store_revision", "expected_trust_revision": "trust_revision", "expected_resource_revision": "resource_revision", "expected_binding_revision": "binding_revision", "expected_selection_generation": "selection_generation", "expected_policy_generation": "profile_policy_generation", "expected_rule_generation": "rule_generation"]
            guard input.action == "select", target == fields["target_id"] as? String, rawDigest == input.artifactDigest, pairs.allSatisfy({ profileInteger(fields[$0.key]) == profileInteger(basis[$0.value]) }) else { throw LocalHealthError.invalidResponse }
        }
        return HomeProfileReview(token: token, digest: digest, state: state, remainingMilliseconds: remaining, prior: prior, captured: captured,
            summary: try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]), basis: try JSONSerialization.data(withJSONObject: basis, options: .sortedKeys), targetID: target, artifactDigest: rawDigest)
    }

    private static func profileDeclaration(_ capabilities: [[String: Any]], target: String, role: String, profile: String) throws {
        var keys: Set<String> = []
        let schema: [String: (String, String)] = role == "Light" ? ["power": ("boolean", "none"), "brightness": ("fraction", "ppm"), "colour_hsv": ("hsv", "mdeg+ppm"), "colour_xy": ("xy", "ppm"), "colour_temperature": ("kelvin", "K")] : ["smoke_state": ("smoke_state", "none"), "fault": ("boolean", "none"), "self_test": ("boolean", "none"), "battery_fraction": ("fraction", "ppm")]
        for capability in capabilities {
            guard Set(capability.keys) == Set(["thing_id", "role", "key", "value_kind", "unit", "operations", "risk_class", "profile_ref", "evidence_ref", "freshness_ms", "constraints", "extensions"]),
                  capability["thing_id"] as? String == target, capability["role"] as? String == role,
                  capability["profile_ref"] as? String == profile, let key = capability["key"] as? String,
                  keys.insert(key).inserted, let allowed = schema[key], capability["value_kind"] as? String == allowed.0, capability["unit"] as? String == allowed.1,
                  capability["risk_class"] as? String == (role == "Light" ? "ordinary" : "sensitive"),
                  let operations = capability["operations"] as? [String], !operations.isEmpty, Set(operations).count == operations.count,
                  operations.allSatisfy({ $0 == "read" || ($0 == "write" && role == "Light") }),
                  capability["constraints"] is [String: Any], capability["extensions"] is [String: Any] else { throw LocalHealthError.invalidResponse }
            _ = try profileString(capability, "evidence_ref")
            _ = try profileCounter(capability, "freshness_ms", minimum: 1, maximum: 86_400_000)
        }
    }

    private static func profileSummary(_ raw: [String: Any], basis: [String: Any], initial: Bool) throws {
        guard Set(raw.keys) == Set(["status", "identity_method", "qualification_status", "current_profile_ref", "proposed_profile_ref", "removed_capabilities", "capabilities", "new_control_grants", "invalidation", "handed_off_outcomes"]),
              raw["status"] as? String == "pending_authenticated_selection", raw["identity_method"] as? String == "legacy_tofu", raw["qualification_status"] as? String == "pending_physical_evidence",
              raw["proposed_profile_ref"] as? String == basis["profile_ref"] as? String, profileBoolean(raw["new_control_grants"]) == false,
              raw["invalidation"] as? [String] == ["qualification", "current_reports", "source_grants", "unsent_requests", "rule_policy"], raw["handed_off_outcomes"] as? String == "preserve_uncertainty",
              let removed = raw["removed_capabilities"] as? [String], removed.count <= 32, Set(removed).count == removed.count, removed.allSatisfy(validID),
              let capabilities = raw["capabilities"] as? [[String: Any]], capabilities.count == 1 else { throw LocalHealthError.invalidResponse }
        let current = try profileNullableString(raw, "current_profile_ref")
        guard initial == (current == nil), !initial || removed.isEmpty else { throw LocalHealthError.invalidResponse }
        let power = capabilities[0]
        guard Set(power.keys) == Set(["key", "previous_operations", "proposed_operations", "previous_freshness_ms", "proposed_freshness_ms", "value_kind", "unit", "risk_class"]),
              power["key"] as? String == "power", power["proposed_operations"] as? [String] == ["read", "write"],
              power["value_kind"] as? String == "boolean", power["unit"] as? String == "none", power["risk_class"] as? String == "ordinary",
              profileInteger(power["proposed_freshness_ms"]) == 5_000,
              let previous = power["previous_operations"] as? [String], Set(previous).count == previous.count, previous.allSatisfy({ ["read", "write"].contains($0) }) else { throw LocalHealthError.invalidResponse }
        if initial { guard previous.isEmpty, power["previous_freshness_ms"] is NSNull else { throw LocalHealthError.invalidResponse } }
        else { guard Set(previous) == Set(["read", "write"]), (try profileCounter(power, "previous_freshness_ms", minimum: 1)) >= 5_000 else { throw LocalHealthError.invalidResponse } }
    }

    private static func profileObject(_ response: [String: Any], _ key: String, keys: Set<String>) throws -> [String: Any] {
        guard Set(response.keys) == Set(["api_version", "outcome", key]), let raw = response[key] as? [String: Any], Set(raw.keys) == keys else { throw LocalHealthError.invalidResponse }
        return raw
    }
    private static func profileCounter(_ raw: [String: Any], _ key: String, minimum: Int = 0, maximum: Int = Int.max) throws -> Int {
        guard let value = wireInteger(raw[key]), value >= minimum, value <= maximum else { throw LocalHealthError.invalidResponse }
        return value
    }
    private static func profileString(_ raw: [String: Any], _ key: String) throws -> String {
        guard let value = raw[key] as? String, validID(value) else { throw LocalHealthError.invalidResponse }; return value
    }
    private static func profileDigestField(_ raw: [String: Any], _ key: String) throws -> String {
        let value = try profileString(raw, key); guard profileDigest(value) else { throw LocalHealthError.invalidResponse }; return value
    }
    private static func profileNullableString(_ raw: [String: Any], _ key: String) throws -> String? {
        if raw[key] is NSNull { return nil }; return try profileString(raw, key)
    }
    private static func profileNullableDigest(_ raw: [String: Any], _ key: String) throws -> String? {
        if raw[key] is NSNull { return nil }; return try profileDigestField(raw, key)
    }
    private static func profileBoolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }; return number.boolValue
    }
    private static func profileArtifact(_ raw: [String: Any]) throws -> HomeProfileArtifact {
        let digest = try profileDigestField(raw, "artifact_digest"); let projection = try profileDigestField(raw, "projection_digest"); let registry = try profileDigestField(raw, "registry_digest")
        let id = try profileString(raw, "id"); let version = try profileString(raw, "version")
        guard raw["binding"] as? String == "lifx-direct-power-v1", validID(id + ":" + version) else { throw LocalHealthError.invalidResponse }
        return HomeProfileArtifact(artifactDigest: digest, projectionDigest: projection, registryDigest: registry, id: id, version: version, binding: "lifx-direct-power-v1")
    }
    private static func profileIdentity(_ value: Any?, allowNil: Bool) throws -> HomeProfileIdentity? {
        if value is NSNull, allowNil { return nil }
        guard let raw = value as? [String: Any], Set(raw.keys) == Set(["stable_id", "manufacturer", "model", "firmware"]) else { throw LocalHealthError.invalidResponse }
        if allowNil, raw.values.allSatisfy({ $0 is NSNull }) { return nil }
        let stable = try profileString(raw, "stable_id"); let manufacturer = try profileString(raw, "manufacturer"); let model = try profileString(raw, "model"); let firmware = try profileString(raw, "firmware")
        guard stable.hasPrefix("lifx:"), stable.utf8.count == 17, stable.dropFirst(5).utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw LocalHealthError.invalidResponse }
        return HomeProfileIdentity(stableID: stable, manufacturer: manufacturer, model: model, firmware: firmware)
    }
}
