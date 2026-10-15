import Foundation
import SwiftUI

@MainActor
final class NativeGenerationViewModel: ObservableObject, CustomReflectable {
    let workspace: NativeGenerationWorkspaceCoordinator, journal: NativePendingCoordinator
    private let controller: NativeControllerSessionDriver
    var workAllowed: () -> Bool = { true }
    var didAssess: (HomeAuthoringOriginalRead) -> Void = { _ in }
    @Published var fields = NativeGenerationDraftFields() {
        didSet {
            if oldValue.policySHA != fields.policySHA { fields.passages = []; fields.examples = []; fields.remoteConsent = false }
            retireDecision()
        }
    }
    @Published var feedbackConsent = false { didSet { retireDecision() } }
    @Published var confirmed = false
    @Published var cancellationConfirmed = false
    @Published var archiveConfirmed = false
    @Published var archiveUncertaintyConfirmed = false
    @Published var assessmentInstruction = "" { didSet { retireDecision() } }
    @Published private(set) var busy = false
    @Published private(set) var context: NativeGenerationContext?
    @Published private(set) var entry: NativeGenerationWorkspaceEntry?
    @Published private(set) var rootStatus: HomeGenerationStatus?
    @Published private(set) var attemptStatus: HomeGenerationStatus?
    @Published private(set) var decision: NativeGenerationDecision?
    @Published private(set) var assessment: NativeAuthoringPreparedDecision?
    @Published private(set) var status = "Load the local generator configuration explicitly."
    @Published private(set) var error: String?
    private var viewGeneration: UInt64 = 0
    nonisolated var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
    init(controller: NativeControllerSessionDriver, journal: NativePendingCoordinator, workspace: NativeGenerationWorkspaceCoordinator = NativeGenerationWorkspaceCoordinator()) {
        self.controller = controller; self.journal = journal; self.workspace = workspace
    }
    var canChangeSession: Bool { !busy && !workspace.busy }
    var policies: [[String: Any]] { context?.policies ?? [] }
    var selectedPolicy: [String: Any]? { policies.first { $0["policy_sha256"] as? String == fields.policySHA } }
    var canWork: Bool { !busy && !workspace.busy && !workspace.needsReload && workAllowed() }
    private func retireDecision() { viewGeneration &+= 1; decision = nil; assessment = nil; confirmed = false; cancellationConfirmed = false; archiveConfirmed = false; archiveUncertaintyConfirmed = false; error = nil }
    func invalidate() {
        retireDecision(); context = nil; entry = nil; rootStatus = nil; attemptStatus = nil
        fields = NativeGenerationDraftFields(); feedbackConsent = false
        assessmentInstruction = ""
        status = "Selection or host availability changed. Reload current configuration and original status."
    }
    private func run(_ operation: @escaping @MainActor () async throws -> Void) async {
        guard !busy, workAllowed() else { return }; busy = true; error = nil
        defer { busy = false }
        do { try await operation() }
        catch { self.error = error.localizedDescription; status = "Original custody remains retained. Reload metadata or look up the original before continuing." }
    }
    func load() async {
        await run {
            self.retireDecision()
            self.fields = NativeGenerationDraftFields()
            let generation = self.viewGeneration
            self.context = nil; self.entry = nil; self.rootStatus = nil; self.attemptStatus = nil
            try await self.workspace.reload()
            let saved = try await self.controller.loadGenerationWorkspace(self.workspace.entries)
            guard generation == self.viewGeneration else { return }
            self.entry = saved
            if saved == nil {
                let value = try await self.controller.loadGenerationContext()
                guard generation == self.viewGeneration else { return }
                self.context = value
            }
            self.status = self.entry == nil ? "Choose a policy, selections, instruction and explicit budget." : "Saved original workspace loaded. Read its status explicitly."
        }
    }
    func prepareRoot() async {
        guard canWork, journal.canStart, entry == nil, let context else { return }
        await run {
            let generation = self.viewGeneration
            let value = try await self.controller.prepareGeneration(context, fields: self.fields)
            guard generation == self.viewGeneration else { return }
            self.decision = value; self.confirmed = false; self.status = "Review the exact preparation and export consent. Preparation makes no model call."
        }
    }
    func prepareAttempt() async {
        guard canWork, journal.canStart, let entry, !entry.cancellationPending else { return }
        await run {
            let generation = self.viewGeneration
            let value = try await self.controller.prepareGenerationAttempt(entry, feedbackConsent: self.feedbackConsent)
            guard generation == self.viewGeneration else { return }
            self.decision = value; self.confirmed = false; self.status = "Review the explicit attempt. Confirming may export the selected model input."
        }
    }
    func submit() async {
        guard canWork, journal.canStart, confirmed, let decision else { return }
        self.decision = nil; confirmed = false
        await run {
            let generation = self.viewGeneration
            let value = try await self.controller.submitGeneration(decision, workspace: self.workspace, journal: self.journal)
            guard generation == self.viewGeneration else { return }
            self.entry = value; self.rootStatus = nil; self.attemptStatus = nil
            self.status = decision.original.kind == .preparation ? "Preparation recorded. Read its current status before starting." : "Handoff reserved. Use original lookup to learn the result."
        }
    }
    func refresh() async {
        guard canWork, let entry else { return }
        await run {
            self.retireDecision()
            let generation = self.viewGeneration, values = try await self.controller.readGeneration(entry)
            guard generation == self.viewGeneration else { return }
            self.rootStatus = values.0; self.attemptStatus = values.1
            self.status = "Preparation: \(values.0?.state ?? "not found") · Attempt: \(values.1?.state ?? "not found"). Mechanics remain separate from review and approval."
        }
    }
    func restorePending() async {
        guard canWork, journal.canStart, let entry, !entry.cancellationPending else { return }
        await run {
            self.retireDecision(); let generation = self.viewGeneration
            try await self.controller.restoreGenerationPending(entry, workspace: self.workspace, journal: self.journal)
            guard generation == self.viewGeneration else { return }
            self.status = "Unchanged original restored to pending recovery. Choose explicit lookup or retry there; no generation mutation was sent."
        }
    }
    func cancel(retry: Bool) async {
        guard canWork, let entry, (!retry || cancellationConfirmed) else { return }
        cancellationConfirmed = false
        await run {
            let generation = self.viewGeneration
            let value = try await self.controller.cancelGeneration(entry, workspace: self.workspace, retry: retry)
            guard generation == self.viewGeneration else { return }
            self.entry = value; self.rootStatus = nil; self.attemptStatus = nil
            self.status = value.cancellationPending ? "Cancellation remains unconfirmed. Look up the same root or explicitly retry it." : "Cancellation intent reconciled. This does not prove a remote model stopped."
        }
    }
    func prepareAssessment() async {
        guard canWork, journal.canStart, let entry else { return }
        await run {
            let generation = self.viewGeneration
            let value = try await self.controller.prepareGeneratedDraftAssessment(entry, instruction: self.assessmentInstruction)
            guard generation == self.viewGeneration else { return }
            self.assessment = value; self.confirmed = false; self.status = "Review a fresh manual assessment of the owned generated draft."
        }
    }
    func submitAssessment() async {
        guard canWork, journal.canStart, confirmed, let assessment else { return }
        self.assessment = nil; confirmed = false
        await run {
            let generation = self.viewGeneration, value = try await self.controller.submitAuthoring(assessment, journal: self.journal)
            guard generation == self.viewGeneration else { return }
            self.didAssess(value); self.status = "Manual candidate recorded. Continue explicit attribution and review in Local authoring."
        }
    }
    func archive() async {
        guard canWork, journal.canStart, archiveConfirmed, let entry, !entry.cancellationPending else { return }
        let acknowledgedUncertainty = archiveUncertaintyConfirmed
        archiveConfirmed = false; archiveUncertaintyConfirmed = false
        await run {
            let generation = self.viewGeneration
            let values = try await self.controller.readGeneration(entry)
            guard generation == self.viewGeneration, values.1?.state != "running" else { throw NativePendingError.conflict }
            let uncertain = values.0 == nil || (!entry.attempts.isEmpty && (values.1 == nil || (values.1?.state == "unknown" && values.1?.result == nil)))
            guard !uncertain || acknowledgedUncertainty else { throw NativePendingError.conflict }
            try await self.workspace.archive(entry); self.entry = nil; self.invalidate()
            self.status = "Client workspace archived. Controller history remains retained."
        }
    }
}

struct NativeGenerationPanel: View {
    @ObservedObject var generation: NativeGenerationViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Generation drafts stay inert until separately assessed, reviewed and admitted.").font(.callout)
            Text(generation.status).fixedSize(horizontal: false, vertical: true)
            if let error = generation.error { Text(error).foregroundStyle(.red) }
            Button("Load Generator Configuration and Workspace") { Task { await generation.load() } }.disabled(generation.busy || !generation.workAllowed())
            if generation.entry == nil, generation.context != nil { preparationEditor }
            if let entry = generation.entry { workspaceControls(entry) }
            if let decision = generation.decision {
                ForEach(decision.details, id: \.self) { Text($0).font(.caption).textSelection(.enabled) }
                if let draft = decision.feedbackDraft { Text("Exact prior draft selected for feedback"); ScrollView { Text(draft).textSelection(.enabled) }.frame(maxHeight: 180) }
                if let a = decision.feedbackAssessment { Text("Prior mechanics: \(a.disposition) · SHA \(a.sha)") }
                Toggle("Confirm this exact original and its export choice", isOn: $generation.confirmed)
                Button(decision.original.kind == .preparation ? "Record Preparation" : "Start This Attempt") { Task { await generation.submit() } }.disabled(!generation.confirmed || !generation.canWork || !generation.journal.canStart)
            }
            if let assessment = generation.assessment {
                ForEach(assessment.details, id: \.self) { Text($0).font(.caption) }
                Toggle("Confirm this fresh manual assessment", isOn: $generation.confirmed)
                Button("Submit Manual Assessment") { Task { await generation.submitAssessment() } }.disabled(!generation.confirmed || !generation.canWork || !generation.journal.canStart)
            }
        }
    }
    private var preparationEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Installed policy", selection: $generation.fields.policySHA) {
                Text("Choose a policy").tag("")
                ForEach(generation.policies.indices, id: \.self) { index in
                    let p = generation.policies[index], provider = p["provider"] as! [String: Any]
                    Text("\(provider["id"] as! String) · \(provider["model_id"] as! String) · \(provider["locality"] as! String)").tag(p["policy_sha256"] as! String)
                }
            }
            if let policy = generation.selectedPolicy {
                selections(policy["passages"] as! [[String: Any]], passages: true)
                selections(policy["examples"] as! [[String: Any]], passages: false)
                Text(verbatim: limitsDescription(policy)).font(.caption)
                if (policy["provider"] as! [String: Any])["locality"] as? String == "remote" {
                    Toggle("Allow export of these selections and instruction to this remote model", isOn: $generation.fields.remoteConsent)
                }
            }
            TextEditor(text: $generation.fields.instruction).frame(minHeight: 70, maxHeight: 140)
            HStack {
                TextField("Attempts (1–3)", text: $generation.fields.attempts)
                TextField("Attempt milliseconds", text: $generation.fields.attemptMS)
                TextField("Total milliseconds", text: $generation.fields.totalMS)
            }.textFieldStyle(.roundedBorder)
            Button("Prepare Original for Confirmation") { Task { await generation.prepareRoot() } }.disabled(!generation.canWork || !generation.journal.canStart)
        }.disabled(generation.busy)
    }
    private func selections(_ rows: [[String: Any]], passages: Bool) -> some View {
        VStack(alignment: .leading) {
            Text(passages ? "Permitted source passages" : "Permitted fixture examples").font(.headline)
            ForEach(rows.indices, id: \.self) { index in
                let row = rows[index]
                Toggle(selectionDescription(row, passages: passages), isOn: Binding(get: {
                    passages ? generation.fields.passages.contains(index) : generation.fields.examples.contains(index)
                }, set: { value in
                    if passages { if value { generation.fields.passages.insert(index) } else { generation.fields.passages.remove(index) } }
                    else { if value { generation.fields.examples.insert(index) } else { generation.fields.examples.remove(index) } }
                })).font(.caption)
            }
        }
    }
    private func selectionDescription(_ row: [String: Any], passages: Bool) -> String {
        let ref = passages ? row["reference"] as! [String: Any] : row
        let revision = LocalHealthClient.profileInteger(ref["first_revision"])!
        let range = passages ? " · Byte \(LocalHealthClient.profileInteger(row["offset"])!) + \(LocalHealthClient.profileInteger(row["length"])!)" : ""
        return "\(ref["object_digest"] as! String) · First revision \(revision)\(range)"
    }
    private func limitsDescription(_ policy: [String: Any]) -> String {
        let limits = policy["limits"] as! [String: Any]
        return "Passages: \(LocalHealthClient.profileInteger(limits["max_passages"])!) · Each: \(LocalHealthClient.profileInteger(limits["max_passage_bytes"])!) bytes · All: \(LocalHealthClient.profileInteger(limits["max_passages_bytes"])!) bytes · Examples: \(LocalHealthClient.profileInteger(limits["max_examples"])!) · All examples: \(LocalHealthClient.profileInteger(limits["max_examples_bytes"])!) bytes · Model input: \(LocalHealthClient.profileInteger(limits["max_input_bytes"])!) bytes"
    }
    private func workspaceControls(_ entry: NativeGenerationWorkspaceEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Original root \(entry.preparation.operation) · \(entry.attempts.count) attempts").font(.caption).textSelection(.enabled)
            if let fields = try? entry.preparation.fields(), let projection = fields["projection"] as? [String: Any], let budget = fields["budget"] as? [String: Any] {
                DisclosureGroup("Retained model input and budget") {
                    Text(verbatim: "Provider SHA \(fields["provider_sha256"] as! String) · Remote export \(fields["remote_export"] as! Bool)").font(.caption)
                    Text(verbatim: projection["instruction"] as! String).textSelection(.enabled)
                    Text(verbatim: limitsDescription(projection)).font(.caption)
                    Text(verbatim: "Attempts \(LocalHealthClient.profileInteger(budget["attempts"])!) · Attempt \(LocalHealthClient.profileInteger(budget["attempt_ms"])!) ms · Total \(LocalHealthClient.profileInteger(budget["total_ms"])!) ms").font(.caption)
                    let passages = projection["passages"] as! [[String: Any]], examples = projection["examples"] as! [[String: Any]]
                    ForEach(passages.indices, id: \.self) { Text(verbatim: selectionDescription(passages[$0], passages: true)).font(.caption) }
                    ForEach(examples.indices, id: \.self) { Text(verbatim: selectionDescription(examples[$0], passages: false)).font(.caption) }
                }
            }
            Button("Read Original Generation Status") { Task { await generation.refresh() } }.disabled(!generation.canWork)
            Button("Restore Original to Pending Recovery") { Task { await generation.restorePending() } }.disabled(!generation.canWork || !generation.journal.canStart || entry.cancellationPending)
            if let result = generation.attemptStatus?.result {
                Text("Recorded outcome: \(result.disposition)")
                if let a = result.assessment, let fields = try? a.fields(), let report = fields["report"] as? [String: Any], let diagnostics = report["diagnostics"] as? [[String: Any]] {
                    ForEach(diagnostics.indices, id: \.self) { i in Text(verbatim: "\(diagnostics[i]["code"] as! String) · \(diagnostics[i]["instance_path"] as! String) · \(diagnostics[i]["repair"] as! String)").font(.caption).textSelection(.enabled) }
                }
            }
            if !entry.attempts.isEmpty { Toggle("Confirm export of the prior invalid draft and report for repair", isOn: $generation.feedbackConsent) }
            Button(entry.attempts.isEmpty ? "Prepare Initial Attempt" : "Prepare Explicit Repair") { Task { await generation.prepareAttempt() } }.disabled(!generation.canWork || !generation.journal.canStart || entry.cancellationPending)
            Toggle("Confirm cancellation of this original preparation", isOn: $generation.cancellationConfirmed)
            Button(entry.cancellationPending ? "Retry Original Cancellation" : "Cancel Original Preparation") { Task { await generation.cancel(retry: true) } }.disabled(!generation.canWork || !generation.cancellationConfirmed)
            if entry.cancellationPending { Button("Look Up Original Cancellation") { Task { await generation.cancel(retry: false) } }.disabled(!generation.canWork) }
            TextField("Manual assessment instruction", text: $generation.assessmentInstruction).textFieldStyle(.roundedBorder)
            Button("Assess This Generated Draft") { Task { await generation.prepareAssessment() } }.disabled(!generation.canWork || !generation.journal.canStart || generation.attemptStatus?.result?.disposition != "candidate")
            Toggle("Archive this client workspace after original work is reconciled", isOn: $generation.archiveConfirmed)
            Toggle("If status is missing or unknown, acknowledge uncertainty and that a later result may arrive", isOn: $generation.archiveUncertaintyConfirmed)
            Button("Archive Client Workspace") { Task { await generation.archive() } }.disabled(!generation.canWork || !generation.journal.canStart || !generation.archiveConfirmed)
        }
    }
}
