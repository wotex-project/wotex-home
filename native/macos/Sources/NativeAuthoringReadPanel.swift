import Foundation
import SwiftUI

@MainActor
final class NativeAuthoringReadViewModel: ObservableObject {
    private let reader: @Sendable (HomeAuthoringReadRequest) async throws -> HomeAuthoringReadResult
    @Published var digestInput = "" { didSet { if oldValue != digestInput { invalidate() } } }
    @Published var kind: HomeAuthoringOriginalKind = .import { didSet { if oldValue != kind { invalidate() } } }
    @Published var epochInput = "" { didSet { if oldValue != epochInput { invalidate() } } }
    @Published var operationInput = "" { didSet { if oldValue != operationInput { invalidate() } } }
    @Published private(set) var object: HomeAuthoringObjectSummary?
    @Published private(set) var firstRevision: Int64?
    @Published private(set) var original: HomeAuthoringOriginalRead?
    @Published private(set) var busy = false
    @Published private(set) var status = "Read an owned object or an inert original receipt."
    @Published private(set) var error: String?
    private var generation: UInt64 = 0

    init(reader: @escaping @Sendable (HomeAuthoringReadRequest) async throws -> HomeAuthoringReadResult) { self.reader = reader }
    var canChangeSession: Bool { !busy }
    var canReadObject: Bool { !busy && LocalHealthClient.profileDigest(digestInput) }
    var epoch: Int64? {
        guard let value = Int64(epochInput), value > 0, String(value) == epochInput else { return nil }; return value
    }
    var canReadOriginal: Bool { !busy && epoch != nil && LocalHealthClient.profileID(operationInput) }
    private func invalidate() { generation &+= 1; object = nil; firstRevision = nil; original = nil; error = nil }
    func invalidateSessionView() { invalidate(); status = "Read history under the selected session." }
    func hostDidWake() { invalidate(); status = "Host availability changed. Read history again." }
    func readObject() async {
        guard canReadObject else { return }; await load(.object(digestInput))
    }
    func readOriginal() async {
        guard canReadOriginal, let epoch else { return }; await load(.original(kind, epoch, operationInput))
    }
    private func load(_ request: HomeAuthoringReadRequest) async {
        let current = generation
        object = nil; firstRevision = nil; original = nil; error = nil; busy = true
        status = "Reading inert authoring history…"
        defer { busy = false }
        do {
            let result = try await reader(request)
            guard !Task.isCancelled, current == generation else { return }
            switch (request, result) {
            case (.object(let digest), .object(let value)):
                guard value == nil || value?.summary.digest == digest else { throw LocalHealthError.invalidResponse }
                object = value?.summary; firstRevision = value?.firstRevision
                status = value == nil ? "Owned object not found." : "Verified owned object metadata."
            case (.original(let kind, let epoch, let operation), .original(let value)):
                guard value == nil || (value?.kind == kind && value?.epoch == epoch && value?.operation == operation) else { throw LocalHealthError.invalidResponse }
                original = value; status = value == nil ? "Original receipt not found." : "Inert original history. Approval and selection are separate."
            default: throw LocalHealthError.invalidResponse
            }
        } catch {
            guard current == generation else { return }
            self.error = error.localizedDescription; status = "Authoring history read unavailable."
        }
    }
}

struct NativeAuthoringReadPanel: View {
    @ObservedObject var authoring: NativeAuthoringReadViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(authoring.status).fixedSize(horizontal: false, vertical: true)
            TextField("Object digest", text: $authoring.digestInput).textFieldStyle(.roundedBorder).accessibilityLabel("Authoring object digest")
            Button("Read Object Metadata") { Task { await authoring.readObject() } }.disabled(!authoring.canReadObject)
            Picker("Original kind", selection: $authoring.kind) {
                ForEach(HomeAuthoringOriginalKind.allCases, id: \.self) { kind in Text(kind.rawValue.capitalized).tag(kind) }
            }.accessibilityLabel("Authoring original kind")
            TextField("Authority epoch", text: $authoring.epochInput).textFieldStyle(.roundedBorder).accessibilityLabel("Authoring original authority epoch")
            TextField("Operation ID", text: $authoring.operationInput).textFieldStyle(.roundedBorder).accessibilityLabel("Authoring original operation ID")
            Button("Read Original Receipt") { Task { await authoring.readOriginal() } }.disabled(!authoring.canReadOriginal)
            if let object = authoring.object {
                summary(object)
                if let revision = authoring.firstRevision { line("First revision", String(revision)) }
            }
            if let original = authoring.original {
                line("Original", "\(original.kind.rawValue) · \(original.epoch) · \(original.operation)")
                line("Revision", String(original.revision))
                if let object = original.object { summary(object) }
                if let revision = original.firstRevision { line("First revision", String(revision)) }
                if let revision = original.candidateRevision { line("Candidate revision", String(revision)) }
                if let value = original.disposition { line("Structural disposition", value) }
                if let value = original.captureStatus { line("Capture", value) }
                if let value = original.sourceReview { line("Source review", value) }
                if let value = original.consumption { line("Home consumption", value) }
                if let value = original.fixtureStatus { line("Fixtures", value) }
                if let value = original.proposalStatus { line("Inert proposal", value) }
                if let value = original.inputSHA { line("Input SHA", value) }
                if let value = original.basisSHA { line("Basis SHA", value) }
                if let value = original.resultSHA { line("Result SHA", value) }
            }
            if let error = authoring.error { Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
        }
    }
    private func summary(_ object: HomeAuthoringObjectSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            line("Object", "\(object.kind) · \(object.size) bytes")
            line("Object digest", object.digest); line("Payload SHA", object.payloadSHA)
        }
    }
    private func line(_ label: String, _ value: String) -> some View {
        Text("\(label): \(value)").textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
    }
}
