import Foundation

extension NativePendingRecoveryOperations {
    // A transport adapter, never a signed session constructor. The production
    // original-purpose session fixes this runner and its exact retained input.
    static func executePaired(_ entry: NativePendingEntry, association: NativeControllerPublicAssociation,
                              credential: Data, action: NativePendingRecoveryAction) throws -> NativePendingRecoveryOutcome {
        guard let transport = NativeDomainTransportScope.current else { throw NativePendingError.unavailable }
        guard entry.custody.isPaired, entry.category != .access, action.permits(entry),
              entry.custody.matches(association: association, context: entry.context),
              entry.custody.matches(credential),
              action != .cancelReview || entry.phase.isCancellation else { throw NativePendingError.invalidRecord }
        _ = try NativePendingDocument(revision: 1, entries: [entry]).encoded()
        let guarded = PairedOriginalReplyTransport(base: transport, principal: entry.context.principal)
        return try NativeDomainTransportScope.$current.withValue(guarded) {
            try executeOrdinary(entry, credential: credential, socketPath: "", action: action,
                nativeAccess: { _, _ in throw NativePendingError.unavailable })
        }
    }
}

// The ordinary power DTO intentionally omits receipt principal. Check it before
// passing unchanged bytes to that existing decoder; no reply is normalized.
private struct PairedOriginalReplyTransport: NativeDomainTransport, CustomReflectable {
    let base: any NativeDomainTransport
    let principal: String
    var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
    func request(body: Data, allowNotFound: Bool) throws -> Data {
        let bytes = try base.request(body: body, allowNotFound: allowNotFound)
        guard let response = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            throw LocalHealthError.invalidResponse
        }
        if let receipt = response["receipt"] as? [String: Any] {
            guard receipt["principal_id"] as? String == principal else { throw LocalHealthError.invalidResponse }
        }
        return bytes
    }
}
