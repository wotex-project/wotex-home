import Foundation
import SwiftUI

// Foreground fixtures can choose inert custody and private Store adapters.
// Production delivery always uses the signed broker and its existing custody.
struct NativeAccessClient: Sendable {
    let capture: @Sendable () throws -> LocalCredentialCapture
    let identity: @Sendable (Data) throws -> HomeControllerIdentity
    let target: @Sendable (Data, String) throws -> HomeProfileTarget
    let deliver: @Sendable (NativeTargetChange, Bool) throws -> NativeTargetReply
    init(capture: @escaping @Sendable () throws -> LocalCredentialCapture = { try OperatorCredential.captureOriginal() },
         identity: @escaping @Sendable (Data) throws -> HomeControllerIdentity = { try LocalHealthClient.fetchControllerIdentity(socketPath: LocalHealthClient.defaultSocketPath(), credential: $0) },
         target: @escaping @Sendable (Data, String) throws -> HomeProfileTarget = { try LocalHealthClient.fetchProfileTarget(credential: $0, targetID: $1) },
         deliver: @escaping @Sendable (NativeTargetChange, Bool) throws -> NativeTargetReply = { try NativeBrokerClient.targetAccess($0, lookup: $1) }) {
        self.capture = capture; self.identity = identity; self.target = target; self.deliver = deliver
    }
    static func basis(_ value: HomeProfileTarget) throws -> NativeTargetBasis {
        guard value.status == "active", value.selectionState == "selected", value.identityStatus == "reviewed",
              value.identity != nil, value.currentUse == "usable", value.resourceRevision > 0,
              let binding = value.bindingRevision, binding > 0, value.selectionGeneration > 0,
              let artifact = value.artifactDigest, NativeCoreWire.digest(artifact), let bytes = value.declaration,
              let declaration = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              declaration["id"] as? String == value.targetID, declaration["role"] as? String == "Light",
              declaration["profile_ref"] as? String == value.profileRef,
              let capabilities = declaration["capabilities"] as? [[String: Any]], capabilities.count == 1,
              let power = capabilities.first, power["thing_id"] as? String == value.targetID,
              power["role"] as? String == "Light", power["profile_ref"] as? String == value.profileRef,
              power["key"] as? String == "power", power["value_kind"] as? String == "boolean",
              power["unit"] as? String == "none", power["risk_class"] as? String == "ordinary",
              let operations = power["operations"] as? [String], operations.contains("write") else {
            throw LocalHealthError.server("native_target_unavailable")
        }
        return NativeTargetBasis(resource: Int64(value.resourceRevision), binding: Int64(binding),
            generation: Int64(value.selectionGeneration), artifact: artifact)
    }
}

@MainActor
final class NativeAccessViewModel: ObservableObject, CustomReflectable {
    nonisolated var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
    nonisolated private let client: NativeAccessClient
    private let journal: NativePendingCoordinator
    @Published var targetIDInput = "" { didSet { if oldValue != targetIDInput { clearReview() } } }
    @Published var confirmed = false
    @Published private(set) var busy = false
    @Published private(set) var status = "Review a Light's power access with the native Operator session."
    @Published private(set) var reviewDetail = ""
    @Published private(set) var error: String?
    @Published private(set) var reviewedAction: NativeTargetChange.Action?
    @Published private(set) var unconfirmed = false
    private struct Review: Sendable {
        let capture: LocalCredentialCapture
        let original: NativeOriginalReference
        let target: String
        let revision: Int64
        let basis: NativeTargetBasis?
        let action: NativeTargetChange.Action
    }
    private var review: Review?
    private var pending: NativePendingOriginal?
    var didChangeAccess: (() -> Void)?
    init(client: NativeAccessClient = NativeAccessClient(), journal: NativePendingCoordinator = .shared) {
        self.client = client; self.journal = journal
    }
    var canReview: Bool { !busy && pending == nil && journal.canStart }
    var canSubmit: Bool { canReview && confirmed && review != nil && review?.target == targetIDInput }
    var canRecover: Bool { !busy && pending != nil && !journal.busy && !journal.needsReload }
    var canChangeSession: Bool { !busy && journal.canStart }
    private func clearReview() { review = nil; reviewedAction = nil; confirmed = false; reviewDetail = "" }
    func invalidateSessionView() {
        if let owner = journal.owner, let context = pending?.entry.context,
           context.deployment != owner.deployment || context.owner != owner.owner || context.epoch != owner.epoch {
            // The shared journal retains the old original. An authenticated new
            // owner may explicitly choose a separate zero-target session.
            pending = nil; unconfirmed = false
        }
        clearReview()
    }
    private func message(_ error: Error) -> String {
        switch error {
        case is NativeSetupWireError, is NativeSetupSocketError: "Home did not confirm the original access request."
        default: error.localizedDescription
        }
    }
    func originalResolved(_ entry: NativePendingEntry) {
        guard let original = pending?.entry, original.context == entry.context,
              original.custody == entry.custody, original.input == entry.input else { return }
        pending = nil; unconfirmed = false; clearReview(); didChangeAccess?()
    }
    func review(_ action: NativeTargetChange.Action) async {
        guard canReview, NativeTargetWire.identifier(targetIDInput) else { return }
        let target = targetIDInput
        busy = true; error = nil; clearReview()
        defer { busy = false }
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                let capture = try self.client.capture()
                guard let reference = capture.nativeReference, case .recover(let original) = try NativeBrokerWire.request(reference),
                      original.valid, original.receipt.role == .operator, original.verifier == capture.verifier else {
                    throw LocalHealthError.server("native_operator_required")
                }
                let identity = try self.client.identity(capture.bytes)
                guard NativePendingContext(deployment: original.receipt.deployment, owner: original.receipt.owner,
                    epoch: original.receipt.epoch, principal: original.receipt.principal).matches(identity),
                    identity.revision >= original.receipt.revision else { throw LocalHealthError.nativeGuardConflict }
                if action == .revoke {
                    return (Review(capture: capture, original: original, target: target, revision: Int64(identity.revision), basis: nil, action: action),
                        "Remove this Operator session's access to \(target).\nAuthority \(identity.authorityEpoch) · Revision \(identity.revision)")
                }
                let snapshot = try self.client.target(capture.bytes, target)
                guard snapshot.targetID == target, snapshot.authorityEpoch == identity.authorityEpoch,
                      snapshot.storeRevision >= identity.revision else { throw LocalHealthError.nativeGuardConflict }
                let basis = try NativeAccessClient.basis(snapshot)
                let detail = "\(target) · Light · Power\n\(snapshot.identity!.manufacturer) · \(snapshot.identity!.model) · firmware \(snapshot.identity!.firmware)\nSelected profile: \(snapshot.profileRef ?? "Unavailable")"
                return (Review(capture: capture, original: original, target: target, revision: Int64(snapshot.storeRevision), basis: basis, action: action), detail)
            }.value
            guard target == targetIDInput else { throw LocalHealthError.sessionChanged }
            review = result.0; reviewedAction = action; reviewDetail = result.1
            status = action == .grant ? "Confirm the reviewed Light and power capability before granting access." : "Confirm removal of this target's access."
        } catch {
            status = "Access review unavailable."
            if case LocalHealthError.server("native_operator_required") = error { self.error = "Select the native Operator session to review access." }
            else { self.error = message(error) }
        }
    }
    func submit() async {
        guard canSubmit, let review else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            let input = NativePendingInput.targetAccess(operation: "access:" + UUID().uuidString.lowercased(), revision: review.revision,
                target: review.target, action: review.action, basis: review.basis)
            let original = try await journal.begin(input, authorityEpoch: Int(review.original.receipt.epoch),
                expectedCredential: review.capture.bytes, expectedNativeReference: review.capture.nativeReference, expectedCapture: review.capture)
            pending = original; unconfirmed = true; confirmed = false
            let change = try original.entry.targetChange()
            guard change.original == review.original else { throw LocalHealthError.nativeGuardConflict }
            let reply = try await Task.detached(priority: .userInitiated) { try self.client.deliver(change, false) }.value
            try await accept(reply, original: original, firstAttempt: true)
        } catch { status = "Access change unconfirmed. Recover its original request."; self.error = message(error) }
    }
    func recover(lookup: Bool) async {
        guard canRecover, let pending else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            let original = try journal.currentOriginal(pending), change = try original.entry.targetChange()
            let reply = try await Task.detached(priority: .userInitiated) { try self.client.deliver(change, lookup) }.value
            try await accept(reply, original: original, firstAttempt: false)
        } catch { status = "Original access recovery unconfirmed. Its input remains retained."; self.error = message(error) }
    }
    private func accept(_ reply: NativeTargetReply, original: NativePendingOriginal, firstAttempt: Bool) async throws {
        let change = try original.entry.targetChange()
        try NativeTargetWire.verify(reply, matching: change)
        switch reply {
        case .receipt(let receipt):
            try await journal.resolving(original)
            originalResolved(original.entry)
            status = "Access \(receipt.action.rawValue) confirmed at revision \(receipt.finalRevision). Refresh Home to read the current target scope."
        case .notFound: status = "No original access receipt confirmed. Look up or retry the same request."
        case .rejected(let reason):
            if firstAttempt && reason != "outcome_unknown" {
                try await journal.resolving(original)
                originalResolved(original.entry)
                status = "Access was refused. Review the current target before starting another request."
            } else { status = "Original access request was refused and remains retained." }
        }
    }
}

struct NativeAccessPanel: View {
    @ObservedObject var access: NativeAccessViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Device access").font(.headline)
            Text(access.status).font(.callout).fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField("Enrolled Light ID", text: $access.targetIDInput).textFieldStyle(.roundedBorder)
                Button("Review Power Access") { Task { await access.review(.grant) } }.disabled(!access.canReview)
                Button("Review Revocation") { Task { await access.review(.revoke) } }.disabled(!access.canReview)
            }.disabled(access.busy || access.unconfirmed)
            if access.reviewedAction != nil {
                Text(access.reviewDetail).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Toggle("I reviewed this target and its access change", isOn: $access.confirmed).disabled(!access.canReview)
                Button(access.reviewedAction == .grant ? "Grant Access" : "Revoke Access") { Task { await access.submit() } }
                    .disabled(!access.canSubmit)
            }
            if access.unconfirmed {
                HStack {
                    Button("Look Up Original Access") { Task { await access.recover(lookup: true) } }
                    Button("Retry Original Access") { Task { await access.recover(lookup: false) } }
                }.disabled(!access.canRecover)
            }
            if let error = access.error { Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            Text("New sessions start without device access. Granting access permits scoped requests; physical dispatch still requires device qualification. Revocation remains available when a profile or device is unavailable.")
                .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
