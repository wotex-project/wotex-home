import Foundation

// Public metadata correspondence only, never a credential or session seal.
enum NativePairedRecoveryCorrespondence {
    static func association(for entry: NativePendingEntry, action: NativePendingRecoveryAction,
                            pending: NativePendingSnapshot,
                            associations: NativeControllerAssociationSnapshot) throws -> NativeControllerPublicAssociation {
        guard entry.custody.isPaired, entry.category != .access, action.permits(entry),
              pending.document.entries.contains(entry),
              case .paired(let id, _, _, _) = entry.custody,
              let association = associations.document.records.first(where: { $0.id == id }),
              entry.custody.matches(association: association, context: entry.context) else {
            throw NativePendingError.conflict
        }
        _ = try NativePendingDocument(revision: 1, entries: [entry]).encoded()
        return association
    }

    static func cancellation(of entry: NativePendingEntry, action: NativePendingRecoveryAction,
                             before: NativePendingSnapshot, after: NativePendingSnapshot) throws -> NativePendingEntry {
        guard action == .cancelReview, entry.custody.isPaired, before.document.entries.contains(entry),
              case .review(let token, let digest) = entry.phase,
              before.document.version == .v5, after.document.version == .v5,
              before.document.revision > 0, before.document.revision < Int64.max,
              after.document.revision == before.document.revision + 1 else { throw NativePendingError.conflict }
        let next = try entry.changingPhase(.cancelPending(token: token, digest: digest))
        guard after.document.entries == before.document.entries.map({ $0 == entry ? next : $0 }) else {
            throw NativePendingError.conflict
        }
        _ = try after.document.encoded()
        return next
    }
}
