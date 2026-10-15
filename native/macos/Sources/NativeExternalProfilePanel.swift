import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class NativeExternalProfileViewModel: ObservableObject, CustomReflectable {
    let journal: NativePendingCoordinator
    private let controller: NativeControllerSessionDriver
    private var generation: UInt64 = 0
    private var decision: NativeExternalProfilePreparedDecision?
    var workAllowed: () -> Bool = { true }
    @Published var entryMode: NativeExternalProfileEntryMode = .guided { didSet { if oldValue != entryMode { invalidate() } } }
    @Published var action: NativeExternalGuidedAction = .inspection { didSet { if oldValue != action { invalidate() } } }
    @Published var decisionOperation = "" { didSet { if oldValue != decisionOperation { invalidate() } } }
    @Published var inspectionEpoch = "" { didSet { if oldValue != inspectionEpoch { invalidate() } } }
    @Published var inspectionOperation = "" { didSet { if oldValue != inspectionOperation { invalidate() } } }
    @Published var artifactDigest = "" { didSet { if oldValue != artifactDigest { invalidate() } } }
    @Published var targetID = "" { didSet { if oldValue != targetID { invalidate() } } }
    @Published var sourceRef = "" { didSet { if oldValue != sourceRef { invalidate() } } }
    @Published var envelopeDigest = "" { didSet { if oldValue != envelopeDigest { invalidate() } } }
    @Published var envelopeFirstRevision = "" { didSet { if oldValue != envelopeFirstRevision { invalidate() } } }
    @Published var profileFields = NativeExternalGuidedObjectRow() { didSet { if oldValue != profileFields { invalidate() } } }
    @Published var definitionFields: [NativeExternalGuidedObjectRow] = [] { didSet { if oldValue != definitionFields { invalidate() } } }
    @Published private(set) var sources: HomeExternalSourceCatalogue?
    @Published var kind: HomeExternalProfileOriginalKind = .inspection { didSet { if oldValue != kind { invalidate() } } }
    @Published var originalURL: URL? { didSet { if oldValue != originalURL { invalidate() } } }
    @Published var epochInput = "" { didSet { if oldValue != epochInput { invalidate() } } }
    @Published var operationInput = "" { didSet { if oldValue != operationInput { invalidate() } } }
    @Published var confirmed = false
    @Published private(set) var busy = false
    @Published private(set) var catalogue: HomeExternalProfileCatalogue?
    @Published private(set) var receipt: HomeExternalProfileOriginalRead?
    @Published private(set) var details: [String] = []
    @Published private(set) var status = "Inspect, approve and select separately. Reads and decisions require an explicit action."
    @Published private(set) var error: String?
    nonisolated var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
    init(journal: NativePendingCoordinator, controller: NativeControllerSessionDriver) { self.journal = journal; self.controller = controller }
    var canChangeSession: Bool { !busy }
    var localSelected: Bool { controller.localSelected }
    var canRead: Bool { !busy && workAllowed() }
    var canPrepare: Bool { canRead && journal.canStart && (entryMode == .file ? originalURL != nil : (try? guidedDraft()) != nil) }
    var canSubmit: Bool { canRead && journal.canStart && decision != nil && confirmed }
    private var epoch: Int64? {
        guard let value = Int64(epochInput), value > 0, String(value) == epochInput else { return nil }; return value
    }
    var canLookup: Bool { canRead && epoch != nil && LocalHealthClient.profileID(operationInput) }
    func invalidate(clearReads: Bool = false) {
        generation &+= 1; decision?.retire(); decision = nil; details = []; confirmed = false; receipt = nil; error = nil
        if clearReads { catalogue = nil; sources = nil }
        status = "Prepare the decision again after changes. Retained originals remain in Activity."
    }
    private func begin() -> UInt64 {
        decision?.retire(); decision = nil; details = []; confirmed = false; receipt = nil; error = nil; busy = true; return generation
    }
    func newOperation() { guard !busy else { return }; decisionOperation = "external:" + UUID().uuidString.lowercased() }
    func addDefinition() { guard !busy, definitionFields.count < 32 else { return }; definitionFields.append(NativeExternalGuidedObjectRow()) }
    func removeDefinition(_ id: UUID) { guard !busy else { return }; definitionFields.removeAll { $0.id == id } }
    func useRecordedInspection() {
        guard !busy, let receipt, receipt.kind == .inspection else { return }
        inspectionEpoch = String(receipt.epoch); inspectionOperation = receipt.operation
    }
    func guidedDraft() throws -> NativeExternalProfileDraft {
        guard LocalHealthClient.profileID(decisionOperation) else { throw LocalHealthError.invalidProfileRequest }
        let draft: NativeExternalProfileDraft
        switch action {
        case .inspection: draft = .inspection(operation: decisionOperation, objects: try guidedObjects())
        case .approve:
            guard let epoch = NativeExternalGuidedObjectRow.positive(inspectionEpoch) else { throw LocalHealthError.invalidProfileRequest }
            draft = .approve(operation: decisionOperation, epoch: epoch, inspection: inspectionOperation)
        case .revokeTrust: draft = .revokeTrust(operation: decisionOperation, artifact: artifactDigest)
        case .select:
            guard let epoch = NativeExternalGuidedObjectRow.positive(inspectionEpoch) else { throw LocalHealthError.invalidProfileRequest }
            draft = .select(operation: decisionOperation, epoch: epoch, inspection: inspectionOperation, target: targetID, source: sourceRef, objects: try guidedObjects())
        case .revokeTarget: draft = .revokeTarget(operation: decisionOperation, target: targetID)
        }
        try draft.validate(); return draft
    }
    private func guidedObjects() throws -> NativeExternalProfileObjects {
        guard definitionFields.count <= 32, let first = NativeExternalGuidedObjectRow.positive(envelopeFirstRevision) else { throw LocalHealthError.invalidProfileRequest }
        return try NativeExternalProfileObjects.checked(["envelope_ref": ["object_digest": envelopeDigest, "first_revision": first],
            "profile": try profileFields.fields(), "definitions": try definitionFields.map { try $0.fields() }])
    }
    func refreshSources() async {
        guard canRead else { return }; let current = begin(); defer { busy = false }
        do {
            let value = try await controller.readExternalProfileSources()
            guard !Task.isCancelled, current == generation else { return }
            sources = value; status = "Source choices read at revision \(value.basis.revision). Choose explicitly; Prepare checks them again."
        } catch { if current == generation { sources = nil; self.error = error.localizedDescription; status = "Source choices unavailable." } }
    }
    func chooseFile() {
        guard !busy else { return }
        let picker = NSOpenPanel(); picker.canChooseDirectories = false; picker.allowsMultipleSelection = false; picker.allowedContentTypes = [.json]
        if picker.runModal() == .OK { originalURL = picker.url }
    }
    func refresh() async {
        guard canRead else { return }; let current = begin(); defer { busy = false }
        do {
            let value = try await controller.readExternalProfileCatalogue()
            guard !Task.isCancelled, current == generation else { return }
            catalogue = value; status = "Current catalogue at revision \(value.revision). Approval and target selection remain separate."
        } catch { if current == generation { catalogue = nil; self.error = error.localizedDescription; status = "Catalogue read unavailable." } }
    }
    func lookup() async {
        guard canLookup, let epoch else { return }; let kind = kind, operation = operationInput, current = begin(); defer { busy = false }
        do {
            let value = try await controller.readExternalProfileOriginal(kind: kind, epoch: epoch, operation: operation)
            guard !Task.isCancelled, current == generation else { return }
            receipt = value; status = value.map { "Original \($0.kind.rawValue) confirmed at revision \($0.revision). Current catalogue and target state are separate." } ?? "No matching original is recorded for this actor and identity."
        } catch { if current == generation { self.error = error.localizedDescription; status = "Original lookup unavailable." } }
    }
    func prepare() async {
        guard canPrepare else { return }; let kind = kind, mode = entryMode, originalURL = originalURL, current = begin(); defer { busy = false }
        do {
            let value: NativeExternalProfilePreparedDecision
            if mode == .guided { value = try await controller.prepareExternalProfile(draft: guidedDraft()) }
            else {
                guard let originalURL else { throw LocalHealthError.invalidProfileRequest }
                value = try await controller.prepareExternalProfile(kind: kind, originalURL: originalURL)
            }
            guard !Task.isCancelled, current == generation else { value.retire(); return }
            try value.checkLifetime(); decision = value; details = value.details
            status = "Review this exact decision, then confirm separately. No change has been submitted."
        } catch { if current == generation { self.error = error.localizedDescription; status = "Decision preparation unavailable. Refresh and prepare again." } }
    }
    func submit() async {
        guard canSubmit, let decision else { return }
        let current = generation; busy = true; confirmed = false; error = nil
        defer { busy = false }
        do {
            let result = try await controller.submitExternalProfile(decision, journal: journal)
            guard !Task.isCancelled, current == generation else { return }
            self.decision = nil; details = []; receipt = result
            status = "External \(result.kind.rawValue) recorded at revision \(result.revision). Current approval, target selection and reports remain separate."
        } catch {
            guard current == generation else { return }
            decision.retire(); self.decision = nil; details = []; self.error = error.localizedDescription
            status = "Submission not confirmed. Check the retained original in Activity before new work."
        }
    }
}

struct NativeExternalProfilePanel: View {
    @ObservedObject var profiles: NativeExternalProfileViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("External profile decisions").font(.headline)
            Text(profiles.status).font(.callout).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            if !profiles.localSelected { Text("External profile decisions are currently available on This Mac.").font(.footnote) }
            Button("Refresh external catalogue") { Task { await profiles.refresh() } }.disabled(!profiles.canRead)
            if let catalogue = profiles.catalogue {
                Text("Catalogue revision \(catalogue.revision) · Policy \(catalogue.policyGeneration)").font(.caption)
                ForEach(catalogue.items, id: \.artifact) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(item.id) · \(item.version) · \(item.state)")
                        Text("Artifact \(item.artifact) · Trust revision \(item.trustRevision)").font(.caption)
                        Button("Use artifact digest") { profiles.artifactDigest = item.artifact }.disabled(profiles.busy)
                    }.fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }
            Picker("Decision entry", selection: $profiles.entryMode) {
                Text("Guided").tag(NativeExternalProfileEntryMode.guided)
                Text("Complete decision file").tag(NativeExternalProfileEntryMode.file)
            }.disabled(profiles.busy)
            if profiles.entryMode == .guided {
                NativeExternalProfileGuidedForm(profiles: profiles)
                Button("Prepare guided decision") { Task { await profiles.prepare() } }.disabled(!profiles.canPrepare)
            } else {
                kindPicker
                ViewThatFits(in: .horizontal) {
                    HStack { decisionActions }
                    VStack(alignment: .leading) { decisionActions }
                }
                if let file = profiles.originalURL { Text("Decision file: " + file.lastPathComponent).font(.caption).lineLimit(2) }
            }
            ForEach(Array(profiles.details.enumerated()), id: \.offset) { _, value in
                Text(value).font(.caption).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            if !profiles.details.isEmpty {
                Toggle("I reviewed this exact decision and its consequences", isOn: $profiles.confirmed).disabled(profiles.busy)
                Button("Submit reviewed decision") { Task { await profiles.submit() } }.disabled(!profiles.canSubmit)
            }
            Divider()
            Text("Original decision history").font(.subheadline)
            kindPicker
            TextField("Authority epoch", text: $profiles.epochInput).accessibilityLabel("Original authority epoch")
            TextField("Operation ID", text: $profiles.operationInput).accessibilityLabel("Original operation ID")
            Button("Look up original decision") { Task { await profiles.lookup() } }.disabled(!profiles.canLookup)
            if let receipt = profiles.receipt {
                Text("\(receipt.kind.rawValue.capitalized) · Authority \(receipt.epoch) · \(receipt.operation) · Revision \(receipt.revision)").font(.caption).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                Text("Input SHA: " + receipt.inputSHA).font(.caption).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                if receipt.kind == .inspection { Button("Use recorded inspection for guided decision") { profiles.useRecordedInspection() }.disabled(profiles.busy) }
            }
            if let error = profiles.error { Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true).textSelection(.enabled) }
        }.accessibilityElement(children: .contain).accessibilityLabel("External profile decisions")
    }
    private var kindPicker: some View {
        Picker("Original kind", selection: $profiles.kind) {
            Text("Inspection").tag(HomeExternalProfileOriginalKind.inspection)
            Text("Digest trust").tag(HomeExternalProfileOriginalKind.trust)
            Text("Read-only target").tag(HomeExternalProfileOriginalKind.target)
        }.disabled(profiles.busy)
    }
    @ViewBuilder private var decisionActions: some View {
        Button("Choose decision file") { profiles.chooseFile() }.disabled(profiles.busy)
        Button("Prepare decision") { Task { await profiles.prepare() } }.disabled(!profiles.canPrepare)
    }
}
