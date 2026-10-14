import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class NativeAuthoringViewModel: ObservableObject, CustomReflectable {
    nonisolated var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
    private let preparer: @Sendable (HomeAuthoringOriginalKind, URL, URL?) async throws -> NativeAuthoringPreparedDecision
    private let sender: @Sendable (NativeAuthoringPreparedDecision) async throws -> HomeAuthoringOriginalRead
    let journal: NativePendingCoordinator
    var workAllowed: () -> Bool = { true }
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
         sender: @escaping @Sendable (NativeAuthoringPreparedDecision) async throws -> HomeAuthoringOriginalRead) {
        self.journal = journal; self.preparer = preparer; self.sender = sender
    }
    var canChangeSession: Bool { !busy }
    var canPrepare: Bool { !busy && journal.canStart && workAllowed() && originalURL != nil && (kind == .import ? payloadURL != nil : payloadURL == nil) }
    var canSubmit: Bool { !busy && journal.canStart && workAllowed() && decision != nil && confirmed }
    private func invalidate() { generation &+= 1; decision = nil; details = []; receipt = nil; confirmed = false; error = nil }
    func invalidateSessionView() { invalidate(); status = "Prepare a new decision under the selected local session." }
    func hostDidWake() { invalidate(); status = "Host availability changed. Prepare the original again." }
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
            let result = try await sender(decision)
            guard !Task.isCancelled, current == generation else { return }
            receipt = result; status = "Authoring \(result.kind.rawValue) recorded at revision \(result.revision). Approval and selection are separate."
        } catch {
            guard current == generation else { return }
            self.error = error.localizedDescription
            let uncertain = error is NativeAuthoringDeliveryError || !journal.canStart
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
}
