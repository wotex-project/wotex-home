import Foundation
import SwiftUI

enum NativeExternalProfileEntryMode: String, CaseIterable { case guided, file }
struct NativeExternalGuidedObjectRow: Identifiable, Equatable, CustomReflectable {
    let id = UUID()
    var uri = "", version = "", referenceSHA = "", objectDigest = "", firstRevision = ""
    var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
    func fields() throws -> [String: Any] {
        guard uri.utf8.count <= 256, version.utf8.count <= 17, referenceSHA.utf8.count == 64, objectDigest.utf8.count == 64,
              let first = Self.positive(firstRevision) else { throw LocalHealthError.invalidProfileRequest }
        return ["reference": ["id": uri, "version": version, "sha256": referenceSHA], "object_ref": ["object_digest": objectDigest, "first_revision": first]]
    }
    static func positive(_ text: String) -> Int64? {
        guard (1...19).contains(text.utf8.count), let value = Int64(text), value > 0, String(value) == text else { return nil }; return value
    }
}

struct NativeExternalProfileGuidedForm: View {
    @ObservedObject var profiles: NativeExternalProfileViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Guided action", selection: $profiles.action) {
                ForEach(NativeExternalGuidedAction.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            NativeExternalGuidedTextField("New decision operation ID", text: $profiles.decisionOperation)
            Button("New operation ID") { profiles.newOperation() }
            if profiles.action.needsInspection {
                GroupBox("Recorded inspection") {
                    VStack(alignment: .leading) {
                        NativeExternalGuidedTextField("Inspection authority epoch", text: $profiles.inspectionEpoch)
                        NativeExternalGuidedTextField("Inspection operation ID", text: $profiles.inspectionOperation)
                        Text("Prepare reads this actor's exact inspection and artifact. A receipt alone is not approval.")
                            .font(.caption).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if profiles.action == .revokeTrust {
                NativeExternalGuidedTextField("Artifact digest to withdraw", text: $profiles.artifactDigest)
            }
            if profiles.action == .select || profiles.action == .revokeTarget {
                NativeExternalGuidedTextField("External target ID", text: $profiles.targetID)
            }
            if profiles.action == .select { sourceChoices }
            if profiles.action.needsObjects { objectReferences }
            Text("Prepare reads the current controller basis. Review and confirmation happen before any submission.")
                .font(.caption).fixedSize(horizontal: false, vertical: true)
        }.disabled(profiles.busy)
    }
    private var sourceChoices: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button("Read source choices") { Task { await profiles.refreshSources() } }.disabled(!profiles.canRead)
            if let sources = profiles.sources {
                if let owner = sources.ownerEpoch {
                    Text("Source owner: " + owner).font(.caption).textSelection(.enabled)
                    if sources.sources.isEmpty { Text("The current owner publishes no source choices.").font(.caption) }
                    Picker("Source", selection: $profiles.sourceRef) {
                        Text("Choose a source").tag("")
                        ForEach(sources.sources, id: \.reference) { Text($0.reference).tag($0.reference) }
                    }
                    if let choice = sources.sources.first(where: { $0.reference == profiles.sourceRef }) {
                        Text("\(choice.method) · \(choice.trust)").font(.caption)
                        Text("Source selection: " + choice.selectionSHA).font(.caption).textSelection(.enabled)
                        Text("Policy: " + choice.policySHA).font(.caption).textSelection(.enabled)
                    }
                } else { Text("The source owner is unavailable. A cached source is not current authority.").font(.caption) }
            }
        }.fixedSize(horizontal: false, vertical: true)
    }
    private var objectReferences: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Owned imported references").font(.subheadline)
            Text("Use exact import receipts and profile references. Preserve definition order; current ownership and bytes are checked by Home.")
                .font(.caption).fixedSize(horizontal: false, vertical: true)
            GroupBox("Envelope import") {
                VStack {
                    NativeExternalGuidedTextField("Envelope object digest", text: $profiles.envelopeDigest)
                    NativeExternalGuidedTextField("Envelope first import revision", text: $profiles.envelopeFirstRevision)
                }
            }
            NativeExternalObjectReferenceEditor(title: "Profile", row: $profiles.profileFields)
            ForEach($profiles.definitionFields) { $row in
                VStack(alignment: .leading) {
                    NativeExternalObjectReferenceEditor(title: "Definition", row: $row)
                    Button("Remove definition") { profiles.removeDefinition(row.id) }
                }
            }
            Button("Add definition") { profiles.addDefinition() }.disabled(profiles.definitionFields.count >= 32)
            Text("\(profiles.definitionFields.count) of 32 definitions").font(.caption)
        }
    }
}
private struct NativeExternalObjectReferenceEditor: View {
    let title: String
    @Binding var row: NativeExternalGuidedObjectRow
    var body: some View {
        GroupBox(title) {
            VStack {
                NativeExternalGuidedTextField(title + " reference URI", text: $row.uri)
                NativeExternalGuidedTextField(title + " reference version", text: $row.version)
                NativeExternalGuidedTextField(title + " reference SHA", text: $row.referenceSHA)
                NativeExternalGuidedTextField(title + " object digest", text: $row.objectDigest)
                NativeExternalGuidedTextField(title + " first import revision", text: $row.firstRevision)
            }
        }
    }
}

private struct NativeExternalGuidedTextField: View {
    let title: String
    @Binding var text: String
    init(_ title: String, text: Binding<String>) { self.title = title; self._text = text }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).fixedSize(horizontal: false, vertical: true)
            TextField(title, text: $text).accessibilityLabel(title)
        }
    }
}
