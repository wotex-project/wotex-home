import AppKit
import Darwin
import Foundation
import SwiftUI
import UniformTypeIdentifiers

// The window's endpoint remains the trusted default. A selected private endpoint
// and credential loader let the native harness exercise the actual same-user API
// without installing a Keychain item or contacting a device.
struct ProfilePanelClient: Sendable {
    let socketPath: String?
    init(socketPath: String? = nil) { self.socketPath = socketPath }
    func catalogue(_ credential: Data) throws -> HomeProfileCatalogue {
        if let socketPath { return try LocalHealthClient.fetchProfiles(socketPath: socketPath, credential: credential) }
        return try LocalHealthClient.fetchProfiles(credential: credential)
    }
    func target(_ credential: Data, _ target: String) throws -> HomeProfileTarget {
        if let socketPath { return try LocalHealthClient.fetchProfileTarget(socketPath: socketPath, credential: credential, targetID: target) }
        return try LocalHealthClient.fetchProfileTarget(credential: credential, targetID: target)
    }
    func importBytes(_ credential: Data, _ bytes: Data) throws -> HomeProfileArtifact {
        if let socketPath { return try LocalHealthClient.importProfile(socketPath: socketPath, credential: credential, bytes: bytes) }
        return try LocalHealthClient.importProfile(credential: credential, bytes: bytes)
    }
    func discover(_ credential: Data) throws -> HomeLIFXCapture {
        if let socketPath { return try LocalHealthClient.discoverProfileCandidates(socketPath: socketPath, credential: credential) }
        return try LocalHealthClient.discoverProfileCandidates(credential: credential)
    }
    func interview(_ credential: Data, _ session: String, _ candidate: String) throws -> HomeLIFXInterview {
        if let socketPath { return try LocalHealthClient.interviewProfileCandidate(socketPath: socketPath, credential: credential, session: session, candidate: candidate) }
        return try LocalHealthClient.interviewProfileCandidate(credential: credential, session: session, candidate: candidate)
    }
    func prepare(_ credential: Data, _ input: HomeProfileOperation) throws -> HomeProfilePreparation {
        if let socketPath { return try LocalHealthClient.prepareProfile(socketPath: socketPath, credential: credential, input: input) }
        return try LocalHealthClient.prepareProfile(credential: credential, input: input)
    }
    func change(_ credential: Data, _ input: HomeProfileOperation) throws -> HomeProfileReceipt {
        if let socketPath { return try LocalHealthClient.changeProfile(socketPath: socketPath, credential: credential, input: input) }
        return try LocalHealthClient.changeProfile(credential: credential, input: input)
    }
    func operation(_ credential: Data, _ epoch: Int, _ operation: String, _ input: HomeProfileOperation?) throws -> HomeProfileReceiptLookup {
        if let socketPath { return try LocalHealthClient.fetchProfileOperation(socketPath: socketPath, credential: credential, authorityEpoch: epoch, operationID: operation, input: input) }
        return try LocalHealthClient.fetchProfileOperation(credential: credential, authorityEpoch: epoch, operationID: operation, input: input)
    }
    func review(_ credential: Data, _ token: String, _ input: HomeProfileOperation) throws -> HomeProfileReviewLookup {
        if let socketPath { return try LocalHealthClient.fetchProfileReview(socketPath: socketPath, credential: credential, token: token, input: input) }
        return try LocalHealthClient.fetchProfileReview(credential: credential, token: token, input: input)
    }
    func cancel(_ credential: Data, _ token: String) throws -> Bool {
        if let socketPath { return try LocalHealthClient.cancelProfileReview(socketPath: socketPath, credential: credential, token: token) }
        return try LocalHealthClient.cancelProfileReview(credential: credential, token: token)
    }
    func collect(_ credential: Data) throws -> HomeProfileCollection {
        if let socketPath { return try LocalHealthClient.collectProfiles(socketPath: socketPath, credential: credential) }
        return try LocalHealthClient.collectProfiles(credential: credential)
    }
}

@MainActor
final class ProfilesViewModel: ObservableObject, CustomReflectable {
    nonisolated var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
    nonisolated private let client: ProfilePanelClient
    nonisolated private let credentialLoader: @Sendable () throws -> Data
    let journal: NativePendingCoordinator

    init(client: ProfilePanelClient = ProfilePanelClient(), credentialLoader: @escaping @Sendable () throws -> Data = { try OperatorCredential.load() }, journal: NativePendingCoordinator = .shared) {
        self.client = client; self.credentialLoader = credentialLoader; self.journal = journal
    }
    @Published var targetIDInput = ""
    @Published var selectedDigest = ""
    @Published var selectedCandidate = ""
    @Published var epochInput = ""
    @Published var operationInput = ""
    @Published var identityReviewed = false
    @Published private(set) var busy = false
    @Published private(set) var catalogue: HomeProfileCatalogue?
    @Published private(set) var target: HomeProfileTarget?
    @Published private(set) var imported: HomeProfileArtifact?
    @Published private(set) var capture: HomeLIFXCapture?
    @Published private(set) var interview: HomeLIFXInterview?
    @Published private(set) var review: HomeProfileReview?
    @Published private(set) var status = "Import a profile or refresh local profile state."
    @Published private(set) var receiptDetail = "No profile operation selected."
    @Published private(set) var error: String?
    @Published private(set) var unconfirmed = false
    @Published private(set) var cancellationUnconfirmed = false

    private struct Draft: Sendable {
        let credential: Data
        let input: HomeProfileOperation
        let preparing: Bool
    }
    private struct Original: Sendable {
        let retained: NativePendingOriginal
        let input: HomeProfileOperation
        let preparing: Bool
        var credential: Data { retained.bytes }
    }
    private var pending: Original?
    private var prepared: Original?
    private var snapshotCredential: Data?
    private var captureCredential: Data?
    private var reviewExpiry: UInt64 = 0

    var canStart: Bool { journal.canStart && !busy && pending == nil && prepared == nil }
    var canChangeSession: Bool {
        guard !busy, journal.canStart else { return false }
        let originals = [pending, prepared].compactMap { $0 }
        guard let owner = journal.owner else { return originals.isEmpty }
        return !originals.contains { original in
            let context = original.retained.entry.context
            return context.deployment == owner.deployment && context.owner == owner.owner && context.epoch == owner.epoch
        }
    }
    func invalidateSessionView() {
        if canChangeSession, let owner = journal.owner {
            func current(_ original: Original?) -> Original? {
                guard let original else { return nil }
                let context = original.retained.entry.context
                return context.deployment == owner.deployment && context.owner == owner.owner && context.epoch == owner.epoch ? original : nil
            }
            pending = current(pending); prepared = current(prepared)
            if pending == nil && prepared == nil { review = nil; unconfirmed = false; cancellationUnconfirmed = false; identityReviewed = false }
        }
        invalidateSnapshot(); capture = nil; interview = nil; captureCredential = nil
        status = "Refresh profile state with the selected session."
    }
    var canCommit: Bool { !busy && !cancellationUnconfirmed && identityReviewed && review?.state == "pending" && reviewExpiry > DispatchTime.now().uptimeNanoseconds && prepared?.retained.entry.phase.isHeldReview == true && !journal.busy && !journal.needsReload }
    var selectedItem: HomeProfileItem? { catalogue?.items.first { $0.id == selectedDigest } }
    var canPrepare: Bool {
        canStart && selectedItem?.state == "approved" && selectedItem?.byteAvailability == "available" &&
            target?.targetID == targetIDInput && (target?.status == "absent" || target?.identityStatus == "reviewed") && target?.status != "revoked" &&
            capture != nil && interview?.candidate == selectedCandidate &&
            snapshotCredential != nil && snapshotCredential == captureCredential
    }

    func refresh() {
        guard !busy else { return }
        let requested = targetIDInput
        busy = true; error = nil; catalogue = nil; target = nil; snapshotCredential = nil
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    let credential = try self.credentialLoader()
                    let catalogue = try self.client.catalogue(credential)
                    let target = requested.isEmpty ? nil : try self.client.target(credential, requested)
                    if let target, target.storeRevision != catalogue.storeRevision || target.authorityEpoch != catalogue.authorityEpoch || target.policyGeneration != catalogue.policyGeneration { throw LocalHealthError.server("resnapshot_required") }
                    return (credential, catalogue, target)
                }.value
                snapshotCredential = result.0; catalogue = result.1; target = result.2
                status = "Profile state at revision \(result.1.storeRevision) · Authority \(result.1.authorityEpoch)."
                if selectedDigest.isEmpty { selectedDigest = imported?.artifactDigest ?? result.1.items.first?.id ?? "" }
            } catch { status = "Profile state unavailable."; self.error = error.localizedDescription }
            busy = false
        }
    }

    func chooseImport() {
        guard canStart else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { importBytes(try ProfileFileReader.read(url)) }
        catch { self.error = error.localizedDescription }
    }

    func importBytes(_ bytes: Data) {
        guard canStart else { return }
        busy = true; error = nil
        Task {
            do {
                let artifact = try await Task.detached(priority: .userInitiated) {
                    try self.client.importBytes(self.credentialLoader(), bytes)
                }.value
                imported = artifact; selectedDigest = artifact.artifactDigest
                invalidateSnapshot()
                status = "Imported \(artifact.profileRef). Refresh state before local approval."
            } catch { status = "Profile import not confirmed; importing the same bytes is safe to repeat."; self.error = error.localizedDescription }
            busy = false
        }
    }

    func approveImported() {
        guard canStart, let imported, let catalogue, let credential = snapshotCredential else { return }
        let trust = catalogue.items.first { $0.id == imported.artifactDigest }?.trustRevision ?? 0
        startChange(action: "approve", digest: imported.artifactDigest, trust: trust, catalogue: catalogue, credential: credential)
    }

    func revokeArtifact() {
        guard canStart, let item = selectedItem, let catalogue, let credential = snapshotCredential else { return }
        startChange(action: "revoke", digest: item.id, trust: item.trustRevision, catalogue: catalogue, credential: credential)
    }

    func revokeTarget() {
        guard canStart, let target, target.targetID == targetIDInput, target.selectionState == "selected", let digest = target.artifactDigest,
              let item = catalogue?.items.first(where: { $0.id == digest }), let catalogue, let credential = snapshotCredential else { return }
        startChange(action: "revoke_selection", digest: digest, trust: item.trustRevision, catalogue: catalogue, credential: credential, target: target)
    }

    private func startChange(action: String, digest: String, trust: Int, catalogue: HomeProfileCatalogue, credential: Data, target: HomeProfileTarget? = nil) {
        do {
            var fields: [String: Any] = ["action": action, "authority_epoch": catalogue.authorityEpoch, "operation_id": "profile:" + UUID().uuidString.lowercased(), "expected_revision": catalogue.storeRevision, "artifact_digest": digest, "expected_trust_revision": trust]
            if let target {
                guard target.storeRevision == catalogue.storeRevision, target.policyGeneration == catalogue.policyGeneration, target.authorityEpoch == catalogue.authorityEpoch else { throw LocalHealthError.server("resnapshot_required") }
                fields.merge(["target_id": target.targetID, "expected_resource_revision": target.resourceRevision, "expected_selection_generation": target.selectionGeneration]) { _, new in new }
            }
            let original = Draft(credential: credential, input: try HomeProfileOperation(fields), preparing: false)
            send(original)
        } catch { self.error = error.localizedDescription }
    }

    func discover() {
        guard canStart else { return }
        busy = true; error = nil; capture = nil; interview = nil; captureCredential = nil
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    let credential = try self.credentialLoader()
                    return (credential, try self.client.discover(credential))
                }.value
                captureCredential = result.0; capture = result.1; selectedCandidate = result.1.candidates.first?.id ?? ""
                status = result.1.candidates.isEmpty ? "No candidate reported on the host's configured interface." : "Choose a reported candidate and interview it."
            } catch { status = "Discovery unavailable."; self.error = error.localizedDescription }
            busy = false
        }
    }

    func interviewSelected() {
        guard canStart, let capture, let credential = captureCredential, capture.candidates.contains(where: { $0.id == selectedCandidate }) else { return }
        let candidate = selectedCandidate
        busy = true; error = nil; interview = nil
        Task {
            do {
                interview = try await Task.detached(priority: .userInitiated) { try self.client.interview(credential, capture.session, candidate) }.value
                status = "Reported identity is ready for profile preparation."
            } catch { status = "Interview unavailable; evidence has not been renewed."; self.error = error.localizedDescription }
            busy = false
        }
    }

    func prepareSelection() {
        guard canPrepare, let catalogue, let target, let item = selectedItem, let capture, let credential = snapshotCredential,
              let binding = target.bindingRevision else { error = "Refresh an absent or reviewed target and interview its candidate first."; return }
        do {
            guard target.storeRevision == catalogue.storeRevision, target.authorityEpoch == catalogue.authorityEpoch, target.policyGeneration == catalogue.policyGeneration else { throw LocalHealthError.server("resnapshot_required") }
            let input = try HomeProfileOperation(["action": "select", "authority_epoch": catalogue.authorityEpoch, "operation_id": "profile:" + UUID().uuidString.lowercased(), "expected_revision": catalogue.storeRevision, "artifact_digest": item.id, "expected_trust_revision": item.trustRevision, "target_id": target.targetID, "expected_resource_revision": target.resourceRevision, "expected_binding_revision": binding, "expected_selection_generation": target.selectionGeneration, "expected_policy_generation": catalogue.policyGeneration, "expected_rule_generation": target.ruleGeneration, "session_ref": capture.session, "candidate_ref": selectedCandidate, "review_ref": "profile-review:" + UUID().uuidString.lowercased()])
            send(Draft(credential: credential, input: input, preparing: true))
        } catch { self.error = error.localizedDescription }
    }

    func commitSelection() {
        guard canCommit, let original = prepared, let review else { return }
        busy = true; error = nil
        Task {
            do {
                let retained = try await journal.changingPhase(original.retained, to: .commitPending(token: review.token, digest: review.digest))
                let committing = Original(retained: retained, input: original.input, preparing: false)
                prepared = nil; self.review = nil; identityReviewed = false
                pending = committing; unconfirmed = true; invalidateSnapshot()
                await perform(committing)
            } catch { self.error = error.localizedDescription; receiptDetail = "Commit intent not confirmed. Reload the original records before continuing." }
            busy = false
        }
    }

    private func send(_ draft: Draft) {
        guard canStart else { return }
        busy = true; error = nil
        epochInput = String(draft.input.authorityEpoch); operationInput = draft.input.operationID
        invalidateSnapshot()
        Task {
            do {
                let retained = try await journal.begin(.profile(preparing: draft.preparing, operation: draft.input),
                    authorityEpoch: draft.input.authorityEpoch, expectedCredential: draft.credential)
                let original = Original(retained: retained, input: draft.input, preparing: draft.preparing)
                pending = original; unconfirmed = true
                await perform(original)
            } catch { self.error = error.localizedDescription; receiptDetail = "Original publication not confirmed. Reload its records before continuing." }
            busy = false
        }
    }

    private func perform(_ original: Original, recovering: Bool = false) async {
        let started = DispatchTime.now().uptimeNanoseconds
        do {
            if case .review = original.retained.entry.phase {
                self.error = "Look up or cancel the original review. A retained review cannot create a new approval."
                receiptDetail = "Original review retained."
                return
            }
            if case .cancelPending(let token, _) = original.retained.entry.phase {
                let cancelled = try await Task.detached(priority: .userInitiated) { try self.client.cancel(original.credential, token) }.value
                guard cancelled else { status = "Cancellation remains unresolved. The original proposal is no longer held."; return }
                try await journal.resolving(original.retained)
                status = "Original proposal cancelled. Cancellation changes no selection."
            } else if original.preparing {
                let result = try await Task.detached(priority: .userInitiated) { try self.client.prepare(original.credential, original.input) }.value
                switch result {
                case .review(let review):
                    let retained = try await journal.changingPhase(original.retained, to: .review(token: review.token, digest: review.digest))
                    self.review = review; prepared = Original(retained: retained, input: original.input, preparing: true); identityReviewed = false
                    reviewExpiry = started + UInt64(review.remainingMilliseconds) * 1_000_000
                    capture = nil; interview = nil; captureCredential = nil
                    status = "Review this exact captured identity and profile before committing."
                    receiptDetail = "Proposal \(review.token) · \(original.input.operationID) · \(review.remainingMilliseconds) ms remaining at last check."
                case .committed(let receipt):
                    try await journal.resolving(original.retained)
                    receiptDetail = receiptSummary(receipt); status = "Original committed selection recovered. Refresh current profile state."
                }
            } else {
                let receipt = try await Task.detached(priority: .userInitiated) { try self.client.change(original.credential, original.input) }.value
                try await journal.resolving(original.retained)
                receiptDetail = receiptSummary(receipt); status = "Profile operation committed. Refresh current profile state."
            }
            pending = nil; unconfirmed = false
        } catch {
            if !recovering, case LocalHealthError.server(let reason) = error, reason != "outcome_unknown" {
                do {
                    try await journal.resolving(original.retained)
                    pending = nil; unconfirmed = false
                    receiptDetail = "Host rejected \(original.input.operationID). Refresh state before another operation."
                } catch { self.error = error.localizedDescription; receiptDetail = "Original rejection retained; journal resolution is not confirmed."; return }
            } else {
                receiptDetail = "Not confirmed · Authority \(original.input.authorityEpoch) · \(original.input.operationID). Resolve this original operation."
            }
            self.error = error.localizedDescription
        }
    }

    func retryOriginal() {
        guard !busy, !journal.busy, !journal.needsReload, let pending else { return }
        busy = true; error = nil
        Task {
            do {
                let retained = try journal.currentOriginal(pending.retained)
                let original = Original(retained: retained, input: pending.input,
                    preparing: pending.preparing && retained.entry.phase == .pending)
                self.pending = original
                await perform(original, recovering: true)
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }

    func lookupOperation() {
        guard !busy, let epoch = Int(epochInput), epoch > 0 else { return }
        let operation = operationInput
        let original = [pending, prepared].compactMap { $0 }.first { $0.input.authorityEpoch == epoch && $0.input.operationID == operation }
        busy = true; error = nil
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) { try self.client.operation(original?.credential ?? self.credentialLoader(), epoch, operation, original?.input) }.value
                switch result {
                case .found(let receipt):
                    receiptDetail = receiptSummary(receipt)
                    if let original { try await journal.resolving(original.retained); pending = nil; prepared = nil; review = nil; unconfirmed = false; cancellationUnconfirmed = false; identityReviewed = false; invalidateSnapshot() }
                case .notFound: receiptDetail = "No receipt for this original scope. A pending operation may be retried with its exact inputs."
                }
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }

    func refreshReview() {
        guard !busy, let original = prepared, let review else { return }
        busy = true; error = nil
        let started = DispatchTime.now().uptimeNanoseconds
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) { try self.client.review(original.credential, review.token, original.input) }.value
                switch result {
                case .found(let fresh): self.review = fresh; cancellationUnconfirmed = original.retained.entry.phase.isCancellation; reviewExpiry = min(reviewExpiry, started + UInt64(fresh.remainingMilliseconds) * 1_000_000)
                case .notFound:
                    pending = original; unconfirmed = true
                    prepared = nil; self.review = nil; identityReviewed = false; cancellationUnconfirmed = false
                    status = "Proposal is no longer held. Resolve its original operation before another change."
                }
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }

    func cancelReview() {
        guard !busy, !journal.busy, !journal.needsReload, let original = prepared, let review else { return }
        busy = true; error = nil; cancellationUnconfirmed = true
        Task {
            do {
                let retained = try await journal.changingPhase(original.retained, to: .cancelPending(token: review.token, digest: review.digest))
                let cancelling = Original(retained: retained, input: original.input, preparing: original.preparing)
                prepared = cancelling
                let cancelled = try await Task.detached(priority: .userInitiated) { try self.client.cancel(cancelling.credential, review.token) }.value
                if cancelled {
                    try await journal.resolving(retained)
                    prepared = nil; self.review = nil; identityReviewed = false; cancellationUnconfirmed = false
                    status = "Pending proposal cancelled. Cancellation changes no selection."
                } else {
                    pending = cancelling; unconfirmed = true
                    prepared = nil; self.review = nil; identityReviewed = false; cancellationUnconfirmed = false
                    status = "Proposal is no longer held. Resolve its original operation before another change."
                }
            } catch { self.error = error.localizedDescription; status = "Cancellation not confirmed. Reload if needed, then check or cancel the original proposal again." }
            busy = false
        }
    }

    func collect() {
        guard canStart else { return }
        busy = true; error = nil
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) { try self.client.collect(self.credentialLoader()) }.value
                status = "Collected \(result.removedObjects) inert objects (\(result.removedBytes) bytes); \(result.objectCount) objects remain."
            } catch { status = "Collection not confirmed. Repeat collection to check remaining objects."; self.error = error.localizedDescription }
            busy = false
        }
    }

    private func invalidateSnapshot() { catalogue = nil; target = nil; snapshotCredential = nil }
    private func receiptSummary(_ receipt: HomeProfileReceipt) -> String {
        "\(receipt.action) at revision \(receipt.finalRevision) · \(receipt.changedTargets) targets changed · \(receipt.invalidatedRequests) requests invalidated · \(receipt.unknownOutcomes) unknown outcomes at that barrier · \(receipt.operationID)."
    }
}

enum ProfileFileReader {
    static func read(_ url: URL) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var before = stat()
        guard lstat(url.path, &before) == 0, before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), (1...32_768).contains(Int(before.st_size)) else { throw LocalHealthError.invalidProfileRequest }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw LocalHealthError.invalidProfileRequest }
        defer { _ = Darwin.close(fd) }
        var opened = stat()
        guard fstat(fd, &opened) == 0, opened.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), opened.st_dev == before.st_dev, opened.st_ino == before.st_ino, opened.st_size == before.st_size else { throw LocalHealthError.invalidProfileRequest }
        var bytes = Data(); var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0, bytes.count + count <= 32_768 else { throw LocalHealthError.invalidProfileRequest }
            if count == 0 { break }; bytes.append(contentsOf: buffer.prefix(count))
        }
        var after = stat(); var named = stat()
        guard bytes.count == Int(before.st_size), fstat(fd, &after) == 0, lstat(url.path, &named) == 0,
              after.st_size == before.st_size, after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec, after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
              named.st_dev == before.st_dev, named.st_ino == before.st_ino, named.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw LocalHealthError.invalidProfileRequest }
        return bytes
    }
}

struct PortableProfilesPanel: View {
    @StateObject private var profiles: ProfilesViewModel
    @ObservedObject private var journal: NativePendingCoordinator
    init(profiles: ProfilesViewModel = ProfilesViewModel()) {
        _profiles = StateObject(wrappedValue: profiles)
        _journal = ObservedObject(wrappedValue: profiles.journal)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Portable device profiles").font(.headline)
            Text(profiles.status).font(.callout).textSelection(.enabled)
            ViewThatFits(in: .horizontal) {
                HStack { importControls; refreshControls }
                VStack(alignment: .leading) { importControls; refreshControls }
            }
            TextField("Home Thing ID to inspect or enroll", text: $profiles.targetIDInput).disabled(profiles.busy || profiles.unconfirmed || profiles.review != nil)
            if let imported = profiles.imported { Text("Imported \(imported.profileRef) · \(imported.artifactDigest)").font(.caption).textSelection(.enabled) }
            if let catalogue = profiles.catalogue {
                Picker("Exact approved profile", selection: $profiles.selectedDigest) {
                    Text("Choose a profile").tag("")
                    ForEach(catalogue.items) { item in Text("\(item.artifact.profileRef) · \(item.state) · bytes \(item.byteAvailability)").tag(item.id) }
                }.disabled(!profiles.canStart)
                if let item = profiles.selectedItem { Text("Raw digest \(item.id) · Trust revision \(item.trustRevision) · \(item.trustAuthor)").font(.caption).textSelection(.enabled) }
            }
            if let target = profiles.target {
                Text("\(target.targetID) · \(target.status) · Resource \(target.resourceRevision) · Selection \(target.selectionGeneration) \(target.selectionState)").font(.callout)
                Text("Profile use: \(target.currentUse). This does not establish execution admission or a physical result.").font(.footnote).foregroundStyle(.secondary)
                if let identity = target.identity { Text("Reviewed identity: \(identity.description)").font(.callout).textSelection(.enabled) }
                else if target.identityStatus == "review_required" { Text("This existing target needs a fresh enrollment review before profile selection.").foregroundStyle(.orange) }
                if let head = target.qualificationHead { DisclosureGroup("Retained qualification evidence") { Text(String(decoding: head, as: UTF8.self)).font(.caption.monospaced()).textSelection(.enabled) } }
            }
            ViewThatFits(in: .horizontal) {
                HStack { selectionControls; revocationControls }
                VStack(alignment: .leading) { selectionControls; revocationControls }
            }
            if let capture = profiles.capture {
                Picker("Reported candidate", selection: $profiles.selectedCandidate) {
                    Text("Choose a candidate").tag("")
                    ForEach(capture.candidates) { candidate in Text("\(candidate.claimedStableID ?? "Unidentified") · \(candidate.endpoint) · \(candidate.interfaceID)").tag(candidate.id) }
                }.disabled(!profiles.canStart)
            }
            if let interview = profiles.interview { Text("Reported: \(interview.identity.description) · Legacy TOFU").font(.callout).textSelection(.enabled) }
            if let review = profiles.review {
                Divider()
                Text("Review \(review.targetID)").font(.headline)
                Text("Prior: \(review.prior?.description ?? "No enrolled target")")
                Text("Captured: \(review.captured.description)").textSelection(.enabled)
                Text("Exact artifact: \(review.artifactDigest)").font(.caption).textSelection(.enabled)
                DisclosureGroup("Capability changes and invalidation") { Text(String(decoding: review.summary, as: UTF8.self)).font(.caption.monospaced()).textSelection(.enabled) }
                Text("Physical qualification is pending. Selection grants no control. Old reports and qualification are invalidated; handed-off outcomes remain uncertain.").font(.footnote).foregroundStyle(.orange)
                Toggle("I reviewed this exact identity and profile", isOn: $profiles.identityReviewed)
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    ViewThatFits(in: .horizontal) {
                        HStack { reviewControls }
                        VStack(alignment: .leading) { reviewControls }
                    }
                    if !profiles.canCommit && profiles.identityReviewed { Text("Check the original proposal if its review window has elapsed.").font(.footnote).foregroundStyle(.secondary) }
                }
            }
            if profiles.unconfirmed { Button("Retry original inputs and credential") { profiles.retryOriginal() }.disabled(profiles.busy) }
            ViewThatFits(in: .horizontal) {
                HStack { receiptControls }
                VStack(alignment: .leading) { receiptControls }
            }
            Text(profiles.receiptDetail).font(.callout).textSelection(.enabled)
            if let error = profiles.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            Text("Approval, selection and physical qualification are separate. Changes require the host's active maintenance barrier and profile permissions. Pending requests and their original custody references are retained privately. Recovery needs that original custody; changing sessions cannot resolve another session's operation.").font(.footnote).foregroundStyle(.secondary)
        }
    }
    private var importControls: some View {
        HStack {
            Button("Import profile file") { profiles.chooseImport() }.disabled(!profiles.canStart)
            Button("Approve imported digest") { profiles.approveImported() }.disabled(!profiles.canStart || profiles.imported == nil || profiles.catalogue == nil)
        }
    }
    private var refreshControls: some View {
        HStack { Button("Refresh profile state") { profiles.refresh() }.disabled(profiles.busy); Button("Collect inert files") { profiles.collect() }.disabled(!profiles.canStart) }
    }
    private var selectionControls: some View {
        HStack {
            Button("Discover Devices") { profiles.discover() }.disabled(!profiles.canStart)
            Button("Interview selected") { profiles.interviewSelected() }.disabled(!profiles.canStart || profiles.capture == nil || profiles.selectedCandidate.isEmpty)
            Button("Prepare selection") { profiles.prepareSelection() }.disabled(!profiles.canPrepare)
        }
    }
    private var revocationControls: some View {
        HStack {
            Button("Revoke target selection") { profiles.revokeTarget() }.disabled(!profiles.canStart || profiles.target?.selectionState != "selected")
            Button("Revoke artifact approval") { profiles.revokeArtifact() }.disabled(!profiles.canStart || profiles.selectedItem?.state != "approved")
        }
    }
    private var reviewControls: some View {
        Group {
            Button("Commit reviewed selection") { profiles.commitSelection() }.disabled(!profiles.canCommit)
            Button("Check original proposal") { profiles.refreshReview() }.disabled(profiles.busy)
            Button("Cancel original proposal") { profiles.cancelReview() }.disabled(profiles.busy)
        }
    }
    private var receiptControls: some View {
        Group {
            TextField("Original authority epoch", text: $profiles.epochInput).frame(maxWidth: 170)
            TextField("Original profile operation ID", text: $profiles.operationInput)
            Button("Look up original receipt") { profiles.lookupOperation() }.disabled(profiles.busy || profiles.operationInput.isEmpty)
        }
    }
}
