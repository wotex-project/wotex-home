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
    case transport
    case invalidResponse
    case invalidReceiptRequest
    case invalidEnrollmentRequest
    case invalidOverrideRequest
    case invalidRuleRequest
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidCredential: "Enter the 43-character operator credential."
        case .noCredential: "Import an operator credential to read Home state."
        case .keychain(let status): "Keychain error \(status)."
        case .invalidSocket: "The private Home socket is unavailable."
        case .wrongPeer: "The Home socket belongs to another user."
        case .transport: "Could not complete the local Home request."
        case .invalidResponse: "The host returned an invalid local response."
        case .invalidReceiptRequest: "Enter a valid authority epoch and operation ID."
        case .invalidEnrollmentRequest: "Enter a valid enrollment review reference."
        case .invalidRuleRequest: "Enter a valid rule authority epoch and operation ID."
        case .invalidOverrideRequest: "Enter a valid override target, epoch and operation ID."
        case .server(let reason): "Host rejected the local request: \(reason)."
        }
    }
}

enum OperatorCredential {
    private static let service = "org.wotex.home.operator"
    private static let account = "local-api-v1"

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
    }

    static func load() throws -> Data {
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

enum LocalHealthClient {
    private static let maxResponseBytes = 1_048_576

    static func fetchRuleStatus() throws -> HomeRuleStatus {
        try fetchRuleStatus(socketPath: defaultSocketPath(), credential: OperatorCredential.load())
    }

    static func fetchRuleStatus(socketPath path: String, credential: Data) throws -> HomeRuleStatus {
        let response = try request(socketPath: path, credential: credential, operation: "rule_status")
        guard Set(response.keys) == Set(["api_version", "outcome", "rule_status"]),
              let item = response["rule_status"] as? [String: Any],
              Set(item.keys) == Set(["authority_epoch", "rule_generation", "admission_revision", "state", "reason"]),
              let epoch = ruleInteger(item["authority_epoch"]), epoch >= 1,
              let generation = ruleInteger(item["rule_generation"]), generation >= 0,
              let admission = ruleInteger(item["admission_revision"]), admission >= 0,
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
              ruleInteger(item["authority_epoch"]) == authorityEpoch,
              item["operation_id"] as? String == operationID,
              let revision = ruleInteger(item["revision"]), revision >= 1,
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
              let admission = ruleInteger(item["admission_revision"]), admission >= 0,
              let previous = ruleInteger(item["previous_generation"]), previous >= 0, previous < Int.max,
              let generation = ruleInteger(item["rule_generation"]), generation == previous + 1,
              let revision = ruleInteger(item["revision"]), revision >= 1,
              let store = ruleInteger(item["store_revision"]), store >= revision,
              let affected = ruleInteger(item["affected_requests"]), (0...1024).contains(affected),
              let unknown = ruleInteger(item["unknown_outcomes"]), (0...affected).contains(unknown),
              item["state"] as? String == (admission == 0 ? "inactive" : "active") else {
            throw LocalHealthError.invalidResponse
        }
        return HomeRuleActivation(admissionRevision: admission, generation: generation,
            revision: revision, storeRevision: store, affectedRequests: affected, unknownOutcomes: unknown)
    }

    private static func ruleInteger(_ value: Any?) -> Int? {
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

    private static func defaultSocketPath() -> String {
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
        return try decodeEnvelope(response, allowNotFound: allowNotFound)
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
        guard let value = try? JSONSerialization.jsonObject(with: data),
              let response = value as? [String: Any],
              response["api_version"] as? Int == 1,
              let outcome = response["outcome"] as? String else {
            throw LocalHealthError.invalidResponse
        }
        if outcome == "error" {
            guard let reason = response["reason"] as? String, reason.count <= 128 else {
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
