import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum NativeAuthoringEntryMode: String, CaseIterable { case original, manualDraft }

@MainActor
final class NativeAuthoringViewModel: ObservableObject, CustomReflectable {
    nonisolated var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
    private let preparer: @Sendable (HomeAuthoringOriginalKind, URL, URL?) async throws -> NativeAuthoringPreparedDecision
    private let sender: @Sendable (NativeAuthoringPreparedDecision) async throws -> HomeAuthoringOriginalRead
    private let draftPreparer: (@Sendable (URL) async throws -> NativeAuthoringPreparedDecision)?
    private let draftSender: (@Sendable (NativeAuthoringPreparedDecision) async throws -> NativeOwnedManualDraft)?
    private let assessmentPreparer: (@Sendable (NativeOwnedManualDraft, String) async throws -> NativeAuthoringPreparedDecision)?
    let journal: NativePendingCoordinator
    var workAllowed: () -> Bool = { true }
    @Published var entryMode: NativeAuthoringEntryMode = .original { didSet { if oldValue != entryMode { invalidate(clearOwned: true) } } }
    @Published var draftURL: URL? { didSet { if oldValue != draftURL { invalidate(clearOwned: true) } } }
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
         assessmentPreparer: (@Sendable (NativeOwnedManualDraft, String) async throws -> NativeAuthoringPreparedDecision)? = nil) {
        self.journal = journal; self.preparer = preparer; self.sender = sender
        self.draftPreparer = draftPreparer; self.draftSender = draftSender; self.assessmentPreparer = assessmentPreparer
    }
    var canChangeSession: Bool { !busy }
    var supportsManual: Bool { draftPreparer != nil && draftSender != nil && assessmentPreparer != nil }
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
        let current = generation, owned = ownedDraft, file = draftURL, instruction = instruction
        decision = nil; details = []; confirmed = false; error = nil; busy = true
        status = "Checking the draft and current installed authoring basis…"
        defer { busy = false }
        do {
            let prepared: NativeAuthoringPreparedDecision
            if let owned { prepared = try await assessmentPreparer(owned, instruction) }
            else if let file { prepared = try await draftPreparer(file) }
            else { return }
            guard !Task.isCancelled, current == generation else { return }
            manualAssessment = owned != nil; decision = prepared; details = prepared.details
            status = manualAssessment ? "Review this separate manual assessment, then confirm." : "Review this exact draft import, then confirm. Assessment is a separate decision."
        } catch {
            guard current == generation else { return }; self.error = error.localizedDescription; status = "Manual draft preparation unavailable."
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
            if authoring.supportsManual {
                Picker("Authoring entry", selection: $authoring.entryMode) {
                    Text("Complete Original").tag(NativeAuthoringEntryMode.original)
                    Text("Manual Draft").tag(NativeAuthoringEntryMode.manualDraft)
                }.disabled(authoring.busy)
            }
            if authoring.entryMode == .manualDraft {
                Button("Choose Private Draft File…") { chooseDraft() }.disabled(authoring.busy)
                if let file = authoring.draftURL { Text("Draft: \(file.lastPathComponent)").fixedSize(horizontal: false, vertical: true) }
                if let owned = authoring.ownedDraft, let summary = owned.receipt.object {
                    Text("Owned draft: \(summary.digest)").textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Text("First revision: \(owned.receipt.firstRevision ?? 0)").font(.caption)
                    Text("Assessment instruction (\(authoring.instruction.utf8.count)/4096 UTF-8 bytes)").font(.caption)
                    TextEditor(text: $authoring.instruction).frame(minHeight: 80, maxHeight: 140).disabled(authoring.busy)
                }
                Button(authoring.ownedDraft == nil ? "Prepare Draft Import" : "Prepare Manual Assessment") { Task { await authoring.prepareManual() } }.disabled(!authoring.canPrepareManual)
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
    private func choose(payload: Bool) {
        let picker = NSOpenPanel(); picker.canChooseFiles = true; picker.canChooseDirectories = false; picker.allowsMultipleSelection = false
        if !payload { picker.allowedContentTypes = [.json] }
        guard picker.runModal() == .OK, let url = picker.url else { return }
        if payload { authoring.payloadURL = url } else { authoring.originalURL = url }
    }
    private func chooseDraft() {
        let picker = NSOpenPanel(); picker.canChooseFiles = true; picker.canChooseDirectories = false; picker.allowsMultipleSelection = false
        picker.allowedContentTypes = [.json]
        guard picker.runModal() == .OK, let url = picker.url else { return }
        authoring.draftURL = url
    }
}
