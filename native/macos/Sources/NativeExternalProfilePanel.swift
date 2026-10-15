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
    var canPrepare: Bool { canRead && journal.canStart && originalURL != nil }
    var canSubmit: Bool { canRead && journal.canStart && decision != nil && confirmed }
    private var epoch: Int64? {
        guard let value = Int64(epochInput), value > 0, String(value) == epochInput else { return nil }; return value
    }
    var canLookup: Bool { canRead && epoch != nil && LocalHealthClient.profileID(operationInput) }
    func invalidate(clearReads: Bool = false) {
        generation &+= 1; decision?.retire(); decision = nil; details = []; confirmed = false; receipt = nil; error = nil
        if clearReads { catalogue = nil }
        status = "Prepare the decision again after changes. Retained originals remain in Activity."
    }
    private func begin() -> UInt64 {
        decision?.retire(); decision = nil; details = []; confirmed = false; receipt = nil; error = nil; busy = true; return generation
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
        guard canPrepare, let originalURL else { return }; let kind = kind, current = begin(); defer { busy = false }
        do {
            let value = try await controller.prepareExternalProfile(kind: kind, originalURL: originalURL)
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
                    }.fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }
            Picker("Decision kind", selection: $profiles.kind) {
                Text("Inspection").tag(HomeExternalProfileOriginalKind.inspection)
                Text("Digest trust").tag(HomeExternalProfileOriginalKind.trust)
                Text("Read-only target").tag(HomeExternalProfileOriginalKind.target)
            }.disabled(profiles.busy)
            ViewThatFits(in: .horizontal) {
                HStack { decisionActions }
                VStack(alignment: .leading) { decisionActions }
            }
            if let file = profiles.originalURL { Text("Decision file: " + file.lastPathComponent).font(.caption).lineLimit(2) }
            ForEach(Array(profiles.details.enumerated()), id: \.offset) { _, value in
                Text(value).font(.caption).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            if !profiles.details.isEmpty {
                Toggle("I reviewed this exact decision and its consequences", isOn: $profiles.confirmed).disabled(profiles.busy)
                Button("Submit reviewed decision") { Task { await profiles.submit() } }.disabled(!profiles.canSubmit)
            }
            Divider()
            Text("Original decision history").font(.subheadline)
            TextField("Authority epoch", text: $profiles.epochInput).accessibilityLabel("Original authority epoch")
            TextField("Operation ID", text: $profiles.operationInput).accessibilityLabel("Original operation ID")
            Button("Look up original decision") { Task { await profiles.lookup() } }.disabled(!profiles.canLookup)
            if let receipt = profiles.receipt {
                Text("\(receipt.kind.rawValue.capitalized) · Authority \(receipt.epoch) · \(receipt.operation) · Revision \(receipt.revision)").font(.caption).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                Text("Input SHA: " + receipt.inputSHA).font(.caption).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            if let error = profiles.error { Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true).textSelection(.enabled) }
        }.accessibilityElement(children: .contain).accessibilityLabel("External profile decisions")
    }
    @ViewBuilder private var decisionActions: some View {
        Button("Choose decision file") { profiles.chooseFile() }.disabled(profiles.busy)
        Button("Prepare decision") { Task { await profiles.prepare() } }.disabled(!profiles.canPrepare)
    }
}
