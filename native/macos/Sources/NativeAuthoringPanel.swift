import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum NativeAuthoringReviewEntry: String, CaseIterable { case file, editor }

enum NativeAuthoringEntryMode: String, CaseIterable { case original, dataImport, manualDraft, review }

struct NativeReviewCitationRow: Identifiable, Sendable, CustomReflectable {
    let id = UUID()
    var path = "", source = "", locator = ""
    var citation: NativeAuthoringCitation { NativeAuthoringCitation(path: path, source: source, locator: locator) }
    var customMirror: Mirror { Mirror(self, children: ["id": id]) }
}
struct NativeReviewUnresolvedRow: Identifiable, Sendable, CustomReflectable {
    let id = UUID()
    var path = ""
    var customMirror: Mirror { Mirror(self, children: ["id": id]) }
}

@MainActor
final class NativeAuthoringViewModel: ObservableObject, CustomReflectable {
    nonisolated var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
    private let preparer: @Sendable (HomeAuthoringOriginalKind, URL, URL?) async throws -> NativeAuthoringPreparedDecision
    private let sender: @Sendable (NativeAuthoringPreparedDecision) async throws -> HomeAuthoringOriginalRead
    private let draftPreparer: (@Sendable (URL) async throws -> NativeAuthoringPreparedDecision)?
    private let draftSender: (@Sendable (NativeAuthoringPreparedDecision) async throws -> NativeOwnedManualDraft)?
    private let assessmentPreparer: (@Sendable (NativeOwnedManualDraft, String) async throws -> NativeAuthoringPreparedDecision)?
    private let reviewPreparer: (@Sendable (Int64, String, URL) async throws -> NativeAuthoringPreparedDecision)?
    private let dataPreparer: (@Sendable (HomeAuthoringObjectKind, URL) async throws -> NativeAuthoringPreparedDecision)?
    private let selectedAssessmentPreparer: (@Sendable (NativeOwnedManualDraft, String, URL?) async throws -> NativeAuthoringPreparedDecision)?
    private let editedReviewPreparer: (@Sendable (Int64, String, NativeAuthoringReviewContent) async throws -> NativeAuthoringPreparedDecision)?
    let journal: NativePendingCoordinator
    var workAllowed: () -> Bool = { true }
    @Published var entryMode: NativeAuthoringEntryMode = .original { didSet { if oldValue != entryMode { invalidate(clearOwned: true) } } }
    @Published var draftURL: URL? { didSet { if oldValue != draftURL { invalidate(clearOwned: true) } } }
    @Published var dataKind: HomeAuthoringObjectKind = .source { didSet { if oldValue != dataKind { invalidate() } } }
    @Published var dataURL: URL? { didSet { if oldValue != dataURL { invalidate() } } }
    @Published var selectionURL: URL? { didSet { if oldValue != selectionURL { invalidate() } } }
    @Published var reviewEntry: NativeAuthoringReviewEntry = .file { didSet { if oldValue != reviewEntry { invalidate() } } }
    @Published var reviewMode: NativeAuthoringReviewMode = .source { didSet { if oldValue != reviewMode { invalidate() } } }
    @Published var reviewCitations: [NativeReviewCitationRow] = [] { didSet { invalidate() } }
    @Published var reviewUnresolved: [NativeReviewUnresolvedRow] = [] { didSet { invalidate() } }
    @Published var reviewEnvelopeDigest = "" { didSet { if Array(oldValue.utf8) != Array(reviewEnvelopeDigest.utf8) { invalidate() } } }
    @Published var reviewEnvelopeRevision = "" { didSet { if Array(oldValue.utf8) != Array(reviewEnvelopeRevision.utf8) { invalidate() } } }
    @Published var reviewURL: URL? { didSet { if oldValue != reviewURL { invalidate() } } }
    @Published var candidateEpochInput = "" { didSet { if oldValue != candidateEpochInput { invalidate() } } }
    @Published var candidateOperationInput = "" { didSet { if Array(oldValue.utf8) != Array(candidateOperationInput.utf8) { invalidate() } } }
    @Published var instruction = "" { didSet { if ownedDraft != nil && Array(oldValue.utf8) != Array(instruction.utf8) { invalidate() } } }
    @Published private(set) var ownedDraft: NativeOwnedManualDraft?
    @Published private(set) var unconfirmed = false
    private var manualAssessment = false
    @Published var kind: HomeAuthoringOriginalKind = .import { didSet { if oldValue != kind { originalURL = nil; payloadURL = nil; invalidate() } } }
    @Published var originalURL: URL? { didSet { if oldValue != originalURL { invalidate() } } }
    @Published var payloadURL: URL? { didSet { if oldValue != payloadURL { invalidate() } } }
    @Published var confirmed = false
    @Published private(set) var busy = false
    @Published private(set) var details: [String] = []
    @Published private(set) var receipt: HomeAuthoringOriginalRead?
    @Published private(set) var status = "Choose a complete original for local authoring. Approval and selection are separate."
    @Published private(set) var error: String?
    private var decision: NativeAuthoringPreparedDecision?
    private var generation: UInt64 = 0
    init(journal: NativePendingCoordinator,
         preparer: @escaping @Sendable (HomeAuthoringOriginalKind, URL, URL?) async throws -> NativeAuthoringPreparedDecision,
         sender: @escaping @Sendable (NativeAuthoringPreparedDecision) async throws -> HomeAuthoringOriginalRead,
         draftPreparer: (@Sendable (URL) async throws -> NativeAuthoringPreparedDecision)? = nil,
         draftSender: (@Sendable (NativeAuthoringPreparedDecision) async throws -> NativeOwnedManualDraft)? = nil,
         assessmentPreparer: (@Sendable (NativeOwnedManualDraft, String) async throws -> NativeAuthoringPreparedDecision)? = nil,
         reviewPreparer: (@Sendable (Int64, String, URL) async throws -> NativeAuthoringPreparedDecision)? = nil,
         dataPreparer: (@Sendable (HomeAuthoringObjectKind, URL) async throws -> NativeAuthoringPreparedDecision)? = nil,
         selectedAssessmentPreparer: (@Sendable (NativeOwnedManualDraft, String, URL?) async throws -> NativeAuthoringPreparedDecision)? = nil,
         editedReviewPreparer: (@Sendable (Int64, String, NativeAuthoringReviewContent) async throws -> NativeAuthoringPreparedDecision)? = nil) {
        self.journal = journal; self.preparer = preparer; self.sender = sender
        self.draftPreparer = draftPreparer; self.draftSender = draftSender; self.assessmentPreparer = assessmentPreparer
        self.reviewPreparer = reviewPreparer; self.dataPreparer = dataPreparer
        self.selectedAssessmentPreparer = selectedAssessmentPreparer; self.editedReviewPreparer = editedReviewPreparer
        reviewEntry = editedReviewPreparer == nil ? .file : .editor
    }
    var canChangeSession: Bool { !busy }
    var supportsManual: Bool { draftPreparer != nil && draftSender != nil && assessmentPreparer != nil }
    var supportsData: Bool { dataPreparer != nil }
    var supportsSelections: Bool { selectedAssessmentPreparer != nil }
    var canPrepareData: Bool { entryMode == .dataImport && supportsData && !busy && journal.canStart && workAllowed() && dataURL != nil }
    var supportsReview: Bool { reviewPreparer != nil || editedReviewPreparer != nil }
    var supportsReviewEditor: Bool { editedReviewPreparer != nil }
    var supportsReviewFile: Bool { reviewPreparer != nil }
    func editedReviewContent() throws -> NativeAuthoringReviewContent {
        let envelope: NativeAuthoringObjectHandle?
        if reviewMode == .complete {
            guard let first = Int(reviewEnvelopeRevision), first > 0, String(first) == reviewEnvelopeRevision else { throw LocalHealthError.invalidProfileRequest }
            envelope = NativeAuthoringObjectHandle(digest: reviewEnvelopeDigest, firstRevision: first)
        } else { envelope = nil }
        let value = NativeAuthoringReviewContent(mode: reviewMode, evidence: reviewCitations.map(\.citation),
            unresolved: reviewUnresolved.map(\.path), envelope: envelope)
        _ = try value.checkedFields(); return value
    }
    var canAddReviewCitation: Bool { !busy && reviewCitations.count < 256 }
    var canAddReviewUnresolved: Bool { !busy && reviewUnresolved.count < 64 }
    func addReviewCitation() { guard canAddReviewCitation else { return }; reviewCitations.append(NativeReviewCitationRow()) }
    func removeReviewCitation(_ id: UUID) { guard !busy else { return }; reviewCitations.removeAll { $0.id == id } }
    func addReviewUnresolved() { guard canAddReviewUnresolved else { return }; reviewUnresolved.append(NativeReviewUnresolvedRow()) }
    func removeReviewUnresolved(_ id: UUID) { guard !busy else { return }; reviewUnresolved.removeAll { $0.id == id } }
    var candidateEpoch: Int64? { guard let value = Int64(candidateEpochInput), value > 0, String(value) == candidateEpochInput else { return nil }; return value }
    var canPrepareReview: Bool { entryMode == .review && supportsReview && !busy && journal.canStart && workAllowed() && candidateEpoch != nil && LocalHealthClient.profileID(candidateOperationInput) && (reviewEntry == .file ? supportsReviewFile && reviewURL != nil : supportsReviewEditor && (try? editedReviewContent()) != nil) }
    var canPrepareManual: Bool { entryMode == .manualDraft && supportsManual && !busy && !unconfirmed && journal.canStart && workAllowed() && (ownedDraft != nil || draftURL != nil) && (ownedDraft == nil || instruction.utf8.count <= 4096) }
    var canPrepare: Bool { entryMode == .original && !busy && journal.canStart && workAllowed() && originalURL != nil && (kind == .import ? payloadURL != nil : payloadURL == nil) }
    var canSubmit: Bool { !busy && journal.canStart && workAllowed() && decision != nil && confirmed }
    private func invalidate(clearOwned: Bool = false) {
        generation &+= 1; decision = nil; details = []; confirmed = false; error = nil
        if clearOwned { ownedDraft = nil; unconfirmed = false }
        receipt = ownedDraft?.receipt
    }
    func invalidateSessionView() { invalidate(clearOwned: true); status = "Prepare a new decision under the selected local session." }
    func hostDidWake() { invalidate(clearOwned: true); status = "Host availability changed. Prepare the original again." }

    func prepareManual() async {
        guard canPrepareManual, let draftPreparer, let assessmentPreparer else { return }
        let current = generation, owned = ownedDraft, file = draftURL, instruction = instruction, selection = selectionURL
        decision = nil; details = []; confirmed = false; error = nil; busy = true
        status = "Checking the draft and current installed authoring basis…"
        defer { busy = false }
        do {
            let prepared: NativeAuthoringPreparedDecision
            if let owned {
                if let selectedAssessmentPreparer { prepared = try await selectedAssessmentPreparer(owned, instruction, selection) }
                else { prepared = try await assessmentPreparer(owned, instruction) }
            }
            else if let file { prepared = try await draftPreparer(file) }
            else { return }
            guard !Task.isCancelled, current == generation else { return }
            manualAssessment = owned != nil; decision = prepared; details = prepared.details
            status = manualAssessment ? "Review this separate manual assessment, then confirm." : "Review this exact draft import, then confirm. Assessment is a separate decision."
        } catch {
            guard current == generation else { return }; self.error = error.localizedDescription; status = "Manual draft preparation unavailable."
        }
    }

    func prepareData() async {
        guard canPrepareData, let file = dataURL, let dataPreparer else { return }
        let current = generation, kind = dataKind
        decision = nil; details = []; receipt = nil; confirmed = false; error = nil; busy = true
        status = "Checking private data and current import authority…"
        defer { busy = false }
        do {
            let value = try await dataPreparer(kind, file)
            guard !Task.isCancelled, current == generation else { return }
            decision = value; details = value.details
            status = "Review this inert data import, then confirm. Assessment and review are separate."
        } catch {
            guard current == generation else { return }
            self.error = error.localizedDescription; status = "Data import preparation unavailable."
        }
    }
    var importedHandleJSON: String? {
        guard let receipt, receipt.kind == .import, let object = receipt.object, let first = receipt.firstRevision,
              let bytes = try? JSONSerialization.data(withJSONObject: ["object_digest": object.digest, "first_revision": Int(first)], options: [.sortedKeys]) else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }

    func prepareReview() async {
        guard canPrepareReview, let epoch = candidateEpoch else { return }
        let current = generation, operation = candidateOperationInput, entry = reviewEntry, file = reviewURL
        let content = entry == .editor ? try? editedReviewContent() : nil
        decision = nil; details = []; receipt = nil; confirmed = false; error = nil; busy = true
        status = "Checking the candidate, explicit review and current installed basis…"
        defer { busy = false }
        do {
            let value: NativeAuthoringPreparedDecision
            if entry == .editor, let content, let editedReviewPreparer { value = try await editedReviewPreparer(epoch, operation, content) }
            else if entry == .file, let file, let reviewPreparer { value = try await reviewPreparer(epoch, operation, file) }
            else { throw LocalHealthError.invalidProfileRequest }
            guard !Task.isCancelled, current == generation else { return }
            decision = value; details = value.details
            status = "Review this source/fixture decision, then confirm. Approval and selection are separate."
        } catch {
            guard current == generation else { return }; self.error = error.localizedDescription; status = "Source/fixture review preparation unavailable."
        }
    }
    func prepare() async {
        guard canPrepare, let originalURL else { return }
        let current = generation, requestedKind = kind, requestedPayload = payloadURL
        decision = nil; details = []; receipt = nil; confirmed = false; error = nil; busy = true
        status = "Checking private bytes and selected authoring scope…"
        defer { busy = false }
        do {
            let value = try await preparer(requestedKind, originalURL, requestedPayload)
            guard !Task.isCancelled, current == generation else { return }
            decision = value; details = value.details; status = "Review this exact original, then confirm its separate submission."
        } catch {
            guard current == generation else { return }; self.error = error.localizedDescription; status = "Authoring preparation unavailable."
        }
    }
    func submit() async {
        guard canSubmit, let decision else { return }
        let current = generation
        busy = true; error = nil; confirmed = false; status = "Retaining the original before submission…"
        defer { busy = false; self.decision = nil; details = [] }
        do {
            let result: HomeAuthoringOriginalRead
            var imported: NativeOwnedManualDraft?
            if entryMode == .manualDraft && !manualAssessment {
                guard let draftSender else { throw NativeControllerDriverError.unavailable }
                let value = try await draftSender(decision); imported = value; result = value.receipt
            } else { result = try await sender(decision) }
            guard !Task.isCancelled, current == generation else { return }
            if let imported { ownedDraft = imported }
            receipt = result; status = "Authoring \(result.kind.rawValue) recorded at revision \(result.revision). Approval and selection are separate."
            if imported != nil { status = "Draft import recorded. Prepare and confirm its manual assessment separately." }
        } catch {
            guard current == generation else { return }
            self.error = error.localizedDescription
            let uncertain = error is NativeAuthoringDeliveryError || !journal.canStart
            if entryMode == .manualDraft { unconfirmed = uncertain }
            status = uncertain ? "Authoring submission unconfirmed. Recover its original in Activity." : "Authoring submission refused. Prepare a new reviewed decision."
        }
    }
}

struct NativeAuthoringPanel: View {
    @ObservedObject var authoring: NativeAuthoringViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(authoring.status).fixedSize(horizontal: false, vertical: true)
            Text("Authoring records data and review history. Approval and selection are separate.").font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if authoring.supportsManual || authoring.supportsReview || authoring.supportsData {
                Picker("Authoring entry", selection: $authoring.entryMode) {
                    Text("Complete Original").tag(NativeAuthoringEntryMode.original)
                    if authoring.supportsData { Text("Data Import").tag(NativeAuthoringEntryMode.dataImport) }
                    if authoring.supportsManual { Text("Manual Draft").tag(NativeAuthoringEntryMode.manualDraft) }
                    if authoring.supportsReview { Text("Source / Fixture Review").tag(NativeAuthoringEntryMode.review) }
                }.disabled(authoring.busy)
            }
            if authoring.entryMode == .dataImport {
                Picker("Data kind", selection: $authoring.dataKind) {
                    ForEach(HomeAuthoringObjectKind.allCases, id: \.self) { kind in Text(kind.rawValue.capitalized).tag(kind) }
                }.disabled(authoring.busy)
                Button("Choose Private Data File…") { chooseData() }.disabled(authoring.busy)
                if let file = authoring.dataURL { Text("Data: \(file.lastPathComponent)").fixedSize(horizontal: false, vertical: true) }
                Button("Prepare Data Import") { Task { await authoring.prepareData() } }.disabled(!authoring.canPrepareData)
            } else if authoring.entryMode == .manualDraft {
                Button("Choose Private Draft File…") { chooseDraft() }.disabled(authoring.busy)
                if let file = authoring.draftURL { Text("Draft: \(file.lastPathComponent)").fixedSize(horizontal: false, vertical: true) }
                if let owned = authoring.ownedDraft, let summary = owned.receipt.object {
                    Text("Owned draft: \(summary.digest)").textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Text("First revision: \(owned.receipt.firstRevision ?? 0)").font(.caption)
                    if authoring.supportsSelections {
                        Button("Choose Source / Fixture Selection File…") { chooseSelection() }.disabled(authoring.busy)
                        if let file = authoring.selectionURL {
                            Text("Selections: \(file.lastPathComponent)").fixedSize(horizontal: false, vertical: true)
                            Button("Clear Selections") { authoring.selectionURL = nil }.disabled(authoring.busy)
                        }
                    }
                    Text("Assessment instruction (\(authoring.instruction.utf8.count)/4096 UTF-8 bytes)").font(.caption)
                    TextEditor(text: $authoring.instruction).frame(minHeight: 80, maxHeight: 140).disabled(authoring.busy)
                }
                Button(authoring.ownedDraft == nil ? "Prepare Draft Import" : "Prepare Manual Assessment") { Task { await authoring.prepareManual() } }.disabled(!authoring.canPrepareManual)
            } else if authoring.entryMode == .review {
                Text("Candidate authority epoch").font(.caption)
                TextField("Candidate authority epoch", text: $authoring.candidateEpochInput).textFieldStyle(.roundedBorder)
                Text("Candidate operation ID").font(.caption)
                TextField("Candidate operation ID", text: $authoring.candidateOperationInput).textFieldStyle(.roundedBorder)
                if authoring.supportsReviewEditor {
                    Picker("Review content entry", selection: $authoring.reviewEntry) {
                        Text("Editor").tag(NativeAuthoringReviewEntry.editor)
                        if authoring.supportsReviewFile { Text("Private File").tag(NativeAuthoringReviewEntry.file) }
                    }.disabled(authoring.busy)
                }
                if authoring.reviewEntry == .editor { reviewEditor }
                else {
                    Button("Choose Private Review Content…") { chooseReview() }.disabled(authoring.busy)
                    if let file = authoring.reviewURL { Text("Review content: \(file.lastPathComponent)").fixedSize(horizontal: false, vertical: true) }
                }
                Button("Prepare Source / Fixture Review") { Task { await authoring.prepareReview() } }.disabled(!authoring.canPrepareReview)
            } else {
            Picker("Authoring kind", selection: $authoring.kind) {
                ForEach(HomeAuthoringOriginalKind.allCases, id: \.self) { kind in Text(kind.rawValue.capitalized).tag(kind) }
            }.accessibilityLabel("Authoring submission kind")
            Button("Choose Original File…") { choose(payload: false) }.disabled(authoring.busy)
            if let file = authoring.originalURL { Text("Original: \(file.lastPathComponent)").fixedSize(horizontal: false, vertical: true) }
            if authoring.kind == .import {
                Button("Choose Payload File…") { choose(payload: true) }.disabled(authoring.busy)
                if let file = authoring.payloadURL { Text("Payload: \(file.lastPathComponent)").fixedSize(horizontal: false, vertical: true) }
            }
            Button("Prepare Authoring Decision") { Task { await authoring.prepare() } }.disabled(!authoring.canPrepare)
            }
            ForEach(Array(authoring.details.enumerated()), id: \.offset) { _, detail in
                Text(detail).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            if !authoring.details.isEmpty {
                Toggle("I reviewed this original and its Store basis", isOn: $authoring.confirmed)
                    .accessibilityLabel("Confirm exact authoring original and Store basis")
                Button("Submit Reviewed Original") { Task { await authoring.submit() } }.disabled(!authoring.canSubmit)
            }
            if let receipt = authoring.receipt {
                if let object = receipt.object, let first = receipt.firstRevision {
                    Text("Imported \(object.kind): \(object.digest)").textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Text("First revision: \(first)").font(.caption)
                    Button("Copy Object Handle") {
                        guard let text = authoring.importedHandleJSON else { return }
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
                    }.disabled(authoring.busy)
                }
                Text("\(receipt.kind.rawValue.capitalized) · Authority \(receipt.epoch) · \(receipt.operation)").textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                if let value = receipt.disposition { Text("Structural disposition: \(value)") }
                if let value = receipt.captureStatus { Text("Capture: \(value)") }
                if let value = receipt.sourceReview { Text("Source review: \(value)") }
                if let value = receipt.consumption { Text("Home consumption: \(value)") }
                if let value = receipt.fixtureStatus { Text("Fixtures: \(value)") }
                if let value = receipt.proposalStatus { Text("Inert proposal: \(value)") }
            }
            if let error = authoring.error { Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
        }
    }
    private var reviewEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Review mode", selection: $authoring.reviewMode) {
                Text("Source Attribution").tag(NativeAuthoringReviewMode.source)
                Text("Complete Proposal").tag(NativeAuthoringReviewMode.complete)
            }
            Text("Source citations (\(authoring.reviewCitations.count)/256)").font(.headline)
            ForEach($authoring.reviewCitations) { $row in
                VStack(alignment: .leading, spacing: 6) {
                    Text("Draft root path").font(.caption)
                    TextField("/profile/binding", text: $row.path).textFieldStyle(.roundedBorder)
                    Text("Selected source digest").font(.caption)
                    TextField("Source object digest", text: $row.source).textFieldStyle(.roundedBorder)
                    Text("Locator (\(row.locator.utf8.count)/256 UTF-8 bytes)").font(.caption)
                    TextField("Explicit source locator", text: $row.locator).textFieldStyle(.roundedBorder)
                    Button("Remove Citation") { authoring.removeReviewCitation(row.id) }
                }.padding(8).background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }
            Button("Add Citation") { authoring.addReviewCitation() }.disabled(!authoring.canAddReviewCitation)
            Text("Unresolved roots (\(authoring.reviewUnresolved.count)/64)").font(.headline)
            ForEach($authoring.reviewUnresolved) { $row in
                VStack(alignment: .leading, spacing: 6) {
                    Text("Unresolved draft root").font(.caption)
                    TextField("/profile/channels/0/semantic", text: $row.path).textFieldStyle(.roundedBorder)
                    Button("Remove Unresolved Root") { authoring.removeReviewUnresolved(row.id) }
                }
            }
            Button("Add Unresolved Root") { authoring.addReviewUnresolved() }.disabled(!authoring.canAddReviewUnresolved)
            if authoring.reviewMode == .complete {
                Text("Owned envelope digest").font(.caption)
                TextField("Envelope object digest", text: $authoring.reviewEnvelopeDigest).textFieldStyle(.roundedBorder)
                Text("Envelope first revision").font(.caption)
                TextField("Positive original revision", text: $authoring.reviewEnvelopeRevision).textFieldStyle(.roundedBorder)
            }
            Text("Citations must name sources already selected by this candidate. Rows are sorted for the original; duplicates refuse.")
                .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.disabled(authoring.busy)
    }
    private func choose(payload: Bool) {
        let picker = NSOpenPanel(); picker.canChooseFiles = true; picker.canChooseDirectories = false; picker.allowsMultipleSelection = false
        if !payload { picker.allowedContentTypes = [.json] }
        guard picker.runModal() == .OK, let url = picker.url else { return }
        if payload { authoring.payloadURL = url } else { authoring.originalURL = url }
    }
    private func chooseData() {
        let picker = NSOpenPanel(); picker.canChooseFiles = true; picker.canChooseDirectories = false; picker.allowsMultipleSelection = false
        guard picker.runModal() == .OK, let url = picker.url else { return }
        authoring.dataURL = url
    }
    private func chooseSelection() {
        let picker = NSOpenPanel(); picker.canChooseFiles = true; picker.canChooseDirectories = false; picker.allowsMultipleSelection = false
        picker.allowedContentTypes = [.json]
        guard picker.runModal() == .OK, let url = picker.url else { return }
        authoring.selectionURL = url
    }
    private func chooseDraft() {
        let picker = NSOpenPanel(); picker.canChooseFiles = true; picker.canChooseDirectories = false; picker.allowsMultipleSelection = false
        picker.allowedContentTypes = [.json]
        guard picker.runModal() == .OK, let url = picker.url else { return }
        authoring.draftURL = url
    }
    private func chooseReview() {
        let picker = NSOpenPanel(); picker.canChooseFiles = true; picker.canChooseDirectories = false; picker.allowsMultipleSelection = false
        picker.allowedContentTypes = [.json]
        guard picker.runModal() == .OK, let url = picker.url else { return }
        authoring.reviewURL = url
    }
}
