import AppKit
import SwiftUI

// Metadata drafts used by the state model are inert. Live operations require
// the private prepared source minted behind the actual installation gate.
struct NativeMQTTSetupDraft: Sendable {
    let summary: NativeMQTTProvisionSummary
    fileprivate let prepared: NativeMQTTPreparedSource?
    init(summary: NativeMQTTProvisionSummary) { self.summary = summary; prepared = nil }
    fileprivate init(prepared: NativeMQTTPreparedSource) { self.prepared = prepared; summary = prepared.summary }
}

struct NativeMQTTSetupOperations: Sendable {
    var prepare: @Sendable (URL, URL) async throws -> NativeMQTTSetupDraft
    var importCredential: @Sendable (NativeMQTTSetupDraft, URL) async throws -> Void
    var publish: @Sendable (NativeMQTTSetupDraft, Bool) async throws -> NativeMQTTProvisionSummary
    static let live = NativeMQTTSetupOperations(
        prepare: { a, s in try await Task.detached(priority: .userInitiated) {
            NativeMQTTSetupDraft(prepared: try NativeMQTTProvisioning.prepare(authoring: a, source: s))
        }.value },
        importCredential: { draft, url in
            guard let prepared = draft.prepared else { throw NativeMQTTProvisionError.unavailable }
            try await Task.detached(priority: .userInitiated) { try NativeMQTTProvisioning.importCredential(url, for: prepared) }.value
        },
        publish: { draft, retry in
            guard let prepared = draft.prepared else { throw NativeMQTTProvisionError.unavailable }
            return try await Task.detached(priority: .userInitiated) {
                try NativeMQTTProvisioning.publish(prepared, confirmingUncertain: retry)
            }.value
        })
}

@MainActor
final class NativeMQTTSetupViewModel: ObservableObject {
    @Published private(set) var authoringSelected = false
    @Published private(set) var sourceSelected = false
    @Published private(set) var busy = false
    @Published private(set) var uncertain = false
    @Published private(set) var credentialImported = false
    @Published private(set) var summary: NativeMQTTProvisionSummary?
    @Published private(set) var status = "No MQTT source prepared"
    @Published private(set) var error: String?
    var workAllowed: () -> Bool = { true }
    var localSelected: () -> Bool = { true }
    private var authoring: URL?, source: URL?, draft: NativeMQTTSetupDraft?
    private var generation: UInt64 = 0
    private var publishing = false
    private let operations: NativeMQTTSetupOperations
    init(operations: NativeMQTTSetupOperations = .live) { self.operations = operations }
    var canChangeSession: Bool { !busy && !uncertain }
    var canChoose: Bool { canChangeSession && workAllowed() && localSelected() }
    var canPrepare: Bool { canChoose && authoring != nil && source != nil }
    var canImport: Bool { canChoose && draft?.summary.authentication == "keychain" }
    var canPublish: Bool {
        !busy && localSelected() && workAllowed() && draft != nil &&
            (uncertain || draft?.summary.authentication != "keychain" || credentialImported)
    }
    func selectAuthoring(_ url: URL) {
        guard canChoose else { return }
        clearPreparation(); authoring = url; authoringSelected = true
    }
    func selectSource(_ url: URL) {
        guard canChoose else { return }
        clearPreparation(); source = url; sourceSelected = true
    }
    func prepare() {
        guard canPrepare, let authoring, let source else { return }
        clearPreparation(); let original = generation
        busy = true
        Task {
            do {
                guard original == generation, localSelected() else { throw NativeMQTTProvisionError.sourceChanged }
                let prepared = try await operations.prepare(authoring, source)
                if original == generation && localSelected() {
                    draft = prepared; summary = prepared.summary
                    status = "Source prepared. Review its digest, channels and authentication."
                }
            } catch { if original == generation { self.error = message(error) } }
            busy = false
        }
    }
    func importCredential(_ url: URL) {
        guard canImport, let draft else { return }
        let original = generation
        busy = true; error = nil; credentialImported = false
        Task {
            do {
                guard original == generation, localSelected() else { throw NativeMQTTProvisionError.sourceChanged }
                try await operations.importCredential(draft, url)
                if original == generation && localSelected() {
                    credentialImported = true; status = "Broker credential imported for this exact prepared source."
                }
            } catch { if original == generation { self.error = message(error) } }
            busy = false
        }
    }
    func publish() {
        guard canPublish, let draft else { return }
        let original = generation, retry = uncertain
        busy = true; publishing = true; error = nil
        Task {
            do {
                guard original == generation, localSelected() else { throw NativeMQTTProvisionError.sourceChanged }
                let result = try await operations.publish(draft, retry)
                guard result == draft.summary else { throw NativeMQTTProvisionError.outcomeUnknown }
                if original == generation && localSelected() {
                    uncertain = false
                    status = "Policy installed for the next Home start. Restart explicitly, then review and reselect its current target."
                }
            } catch {
                if original == generation {
                    if retry || (error as? NativeMQTTProvisionError) == .outcomeUnknown { uncertain = true }
                    self.error = (error as? NativeMQTTProvisionError) == .outcomeUnknown ? nil : message(error)
                    if uncertain { status = "Publication is not confirmed. Keep this original and retry only identical policy." }
                }
            }
            publishing = false; busy = false
        }
    }
    func invalidate() {
        generation &+= 1
        if publishing || uncertain {
            uncertain = true
            status = "Publication is not confirmed. Return to the local controller and retry the original."
        } else { clearPreparation() }
    }
    private func clearPreparation() {
        generation &+= 1; draft = nil; summary = nil; credentialImported = false; error = nil
        status = "Choose private authoring and MQTT source files, then prepare them."
    }
    private func message(_ error: Error) -> String {
        if let error = error as? NativeMQTTProvisionError { return error.errorDescription! }
        if let error = error as? NativeKeychainError {
            switch error {
            case .locked: return "Keychain is locked. Unlock it and explicitly retry credential import."
            case .denied: return "Keychain denied broker credential custody. Check the signed installation."
            case .custodyConflict: return "A different credential already occupies this exact source account. Reconcile custody before retrying."
            default: return "Broker credential custody is unavailable. Explicit retry never replaces an existing item."
            }
        }
        return NativeMQTTProvisionError.unavailable.errorDescription!
    }
}

struct NativeMQTTSetupPanel: View {
    @ObservedObject var mqtt: NativeMQTTSetupViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Prepare one local MQTT observation source. Files must be private, immutable documents. Publishing grants no profile trust or device access.")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack { fileControls }
                VStack(alignment: .leading) { fileControls }
            }
            Text("Authoring: \(mqtt.authoringSelected ? "selected" : "not selected") · MQTT source: \(mqtt.sourceSelected ? "selected" : "not selected")")
                .font(.footnote).foregroundStyle(.secondary)
            Button("Prepare Source") { mqtt.prepare() }.disabled(!mqtt.canPrepare)
            if let summary = mqtt.summary {
                Text("\(summary.channels) observation channel\(summary.channels == 1 ? "" : "s") · \(authentication(summary.authentication))")
                    .font(.subheadline.weight(.semibold))
                Text("Source digest").font(.caption).foregroundStyle(.secondary)
                Text(summary.sourceSHA256).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Authoring digest").font(.caption).foregroundStyle(.secondary)
                Text(summary.authoringSHA256).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if summary.authentication == "keychain" {
                    Button(mqtt.credentialImported ? "Import Same Broker Credential…" : "Import Broker Credential…") { chooseCredential() }
                        .disabled(!mqtt.canImport)
                    Text(mqtt.credentialImported ? "Credential imported for this source." : "Import a separate private broker credential document before publication.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else if summary.authentication == "password" {
                    Text("Password-file mode requires its separate private credential to be provisioned before publication.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Button(mqtt.uncertain ? "Retry Identical Publication" : "Publish for Next Start") { mqtt.publish() }
                    .disabled(!mqtt.canPublish)
            }
            Text(mqtt.status).font(.callout).foregroundStyle(mqtt.uncertain ? Color.orange : Color.primary)
                .fixedSize(horizontal: false, vertical: true)
            if mqtt.busy { ProgressView().controlSize(.small).accessibilityLabel("Local MQTT setup in progress") }
            if let error = mqtt.error { Text(error).foregroundStyle(mqtt.uncertain ? .orange : .red).fixedSize(horizontal: false, vertical: true) }
            Text("Stop the background controller before publication. Restart explicitly to apply policy; a new source epoch requires current-target reselection. TLS verifies the broker, not sensor identity or sample age.")
                .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    private var fileControls: some View {
        Group {
            Button("Choose Authoring File…") { if let url = choose() { mqtt.selectAuthoring(url) } }.disabled(!mqtt.canChoose)
            Button("Choose MQTT File…") { if let url = choose() { mqtt.selectSource(url) } }.disabled(!mqtt.canChoose)
        }
    }
    private func chooseCredential() { if let url = choose() { mqtt.importCredential(url) } }
    private func choose() -> URL? {
        guard mqtt.canChoose else { return nil }
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }
    private func authentication(_ value: String) -> String {
        switch value { case "keychain": "Keychain with verified TLS"; case "password": "Private password file with verified TLS"; default: "Anonymous broker" }
    }
}
