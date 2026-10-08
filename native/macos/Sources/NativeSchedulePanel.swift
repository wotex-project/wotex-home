import Foundation
import SwiftUI

enum NativeScheduleKind: String, CaseIterable, Identifiable, Sendable {
    case once, daily, weekdays, interval
    var id: String { rawValue }
    var title: String { switch self { case .once: "Once"; case .daily: "Daily"; case .weekdays: "Selected weekdays"; case .interval: "Fixed interval" } }
}

struct NativeScheduleDraft: Equatable, Sendable {
    var target = "", on = true, kind = NativeScheduleKind.daily
    var zone = "Europe/Stockholm", localDate = "", localTime = "19:00:00"
    var weekdays: [Int64] = [1,2,3,4,5]
    var anchor = Self.minuteNow(), periodMinutes = "1"
    var boundedStart = false, start = Self.minuteNow(), boundedEnd = false, end = Self.minuteNow().addingTimeInterval(86_400)
    var lateSeconds = "10", toleranceMilliseconds = "1000"
    private static func minuteNow() -> Date { Date(timeIntervalSince1970: (Date().timeIntervalSince1970 / 60).rounded(.down) * 60) }
    static func milliseconds(_ date: Date) throws -> Int64 {
        let value = (date.timeIntervalSince1970 * 1_000).rounded(.down)
        guard value.isFinite, value >= 0, value <= Double(NativeScheduleWire.maximumUTC) else { throw NativeScheduleError.invalidRecord }
        return Int64(value)
    }
    static func integer(_ text: String, multiplier: Int64 = 1) throws -> Int64 {
        guard (1...19).contains(text.utf8.count), text.utf8.allSatisfy({ (48...57).contains($0) }),
              text == "0" || !text.hasPrefix("0"), let value = Int64(text) else { throw NativeScheduleError.invalidRecord }
        let (result, overflow) = value.multipliedReportingOverflow(by: multiplier)
        guard !overflow else { throw NativeScheduleError.invalidRecord }
        return result
    }
    func source(id: String, revision: Int64, principal: String, resource: Int64,
                timezone: HomeScheduleTimezone?, choice: Int64?) throws -> HomeScheduleSource {
        let start = kind != .once && boundedStart ? try Self.milliseconds(start) : 0
        let end = kind != .once && boundedEnd ? try Self.milliseconds(end) : nil
        let trigger: HomeScheduleTrigger
        if kind == .interval {
            trigger = .interval(anchor: try Self.milliseconds(anchor), period: try Self.integer(periodMinutes, multiplier: 60_000), start: start, end: end)
        } else {
            guard let timezone, timezone.name == zone, timezone.localDateTime == localDate + "T" + localTime else { throw NativeScheduleError.invalidRecord }
            switch kind {
            case .once:
                guard let instant = choice ?? (timezone.instants.count == 1 ? timezone.instants[0] : nil), timezone.instants.contains(instant) else { throw NativeScheduleError.invalidRecord }
                trigger = .once(zone: zone, digest: timezone.digest, date: localDate, time: localTime, instant: instant)
            case .daily: trigger = .daily(zone: zone, digest: timezone.digest, time: localTime, start: start, end: end)
            case .weekdays: trigger = .weekdays(zone: zone, digest: timezone.digest, time: localTime, days: weekdays, start: start, end: end)
            case .interval: throw NativeScheduleError.invalidRecord
            }
        }
        let source = HomeScheduleSource(id: id, sourceRevision: revision, author: principal,
            rule: HomeExplicitPowerRule(id: "rule:" + id.dropFirst("schedule:".count), sourceRevision: revision, target: target, on: on),
            resourceRevision: resource, lateWindow: try Self.integer(lateSeconds, multiplier: 1_000),
            tolerance: try Self.integer(toleranceMilliseconds), trigger: trigger)
        _ = try source.encode()
        return source
    }
}

enum NativeScheduleDecision: String, Sendable {
    case record, admit, activate, suspend
    var button: String { switch self { case .record: "Record Schedule Screening"; case .admit: "Admit Schedule"; case .activate: "Activate Schedule Admission"; case .suspend: "Suspend Schedule" } }
}

struct NativeSchedulePanelClient: Sendable {
    let capture: @Sendable () throws -> LocalCredentialCapture
    let identity: @Sendable (Data) throws -> HomeControllerIdentity
    let catalogue: @Sendable (Data) throws -> HomeCatalogue
    let timezone: @Sendable (Data, String, String) throws -> HomeScheduleTimezone
    let current: @Sendable (Data, String) throws -> HomeScheduleCurrent
    let deliver: @Sendable (Data, HomeScheduleOperation, String, Bool) throws -> HomeScheduleResult
    init(capture: @escaping @Sendable () throws -> LocalCredentialCapture = { try OperatorCredential.captureOriginal() },
         identity: @escaping @Sendable (Data) throws -> HomeControllerIdentity = { try LocalHealthClient.fetchControllerIdentity(socketPath: LocalHealthClient.defaultSocketPath(), credential: $0) },
         catalogue: @escaping @Sendable (Data) throws -> HomeCatalogue = { try LocalHealthClient.fetchCatalogue(socketPath: LocalHealthClient.defaultSocketPath(), credential: $0) },
         timezone: @escaping @Sendable (Data, String, String) throws -> HomeScheduleTimezone = { try NativeScheduleClient.timezone(socketPath: LocalHealthClient.defaultSocketPath(), credential: $0, name: $1, local: $2) },
         current: @escaping @Sendable (Data, String) throws -> HomeScheduleCurrent = { try NativeScheduleClient.current(socketPath: LocalHealthClient.defaultSocketPath(), credential: $0, principal: $1) },
         deliver: @escaping @Sendable (Data, HomeScheduleOperation, String, Bool) throws -> HomeScheduleResult = { try NativeScheduleClient.deliver(socketPath: LocalHealthClient.defaultSocketPath(), credential: $0, original: $1, principal: $2, lookup: $3) }) {
        self.capture = capture; self.identity = identity; self.catalogue = catalogue; self.timezone = timezone; self.current = current; self.deliver = deliver
    }
}

@MainActor
final class NativeScheduleViewModel: ObservableObject, CustomReflectable {
    nonisolated var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
    nonisolated private let client: NativeSchedulePanelClient
    private let journal: NativePendingCoordinator
    @Published var draft = NativeScheduleDraft() { didSet { if oldValue != draft { edited() } } }
    @Published var selectedInstant: Int64? { didSet {
        if oldValue != selectedInstant {
            if !settingChoice && sourceRevision < Int64.max { sourceRevision += 1 }
            clearReview()
        }
    } }
    @Published var confirmed = false
    @Published private(set) var sourceRevision: Int64 = 1
    @Published private(set) var busy = false
    @Published private(set) var unconfirmed = false
    @Published private(set) var hasAdmission = false
    @Published private(set) var status = "Draft one scheduled Light power action, then review each decision."
    @Published private(set) var currentDetail = "Refresh schedule readiness under the selected session."
    @Published private(set) var reviewDetail = ""
    @Published private(set) var decision: NativeScheduleDecision?
    @Published private(set) var error: String?
    @Published private(set) var choices: [Int64] = []
    private let scheduleID = "schedule:" + UUID().uuidString.lowercased()
    private var settingChoice = false
    private struct Review: Sendable {
        let capture: LocalCredentialCapture, identity: HomeControllerIdentity
        let decision: NativeScheduleDecision, source: HomeScheduleSource?
        let revision: Int64, admission: Int64
    }
    private var review: Review?, pending: NativePendingOriginal?, admissionHint: NativePendingEntry?, refusedOriginal: NativePendingEntry?
    var didChangeSchedules: (() -> Void)?
    init(client: NativeSchedulePanelClient = NativeSchedulePanelClient(), journal: NativePendingCoordinator = .shared) { self.client = client; self.journal = journal }
    var canReview: Bool { !busy && pending == nil && journal.canStart }
    var canSubmit: Bool { canReview && confirmed && review != nil }
    var canChangeSession: Bool { !busy && journal.canStart }
    private func edited() {
        if sourceRevision < Int64.max { sourceRevision += 1 }
        settingChoice = true; selectedInstant = nil; settingChoice = false; choices = []; clearReview()
    }
    private func clearReview() { review = nil; decision = nil; reviewDetail = ""; confirmed = false }
    func invalidateSessionView() {
        if let scope = journal.owner, let context = pending?.entry.context,
           context.deployment != scope.deployment || context.owner != scope.owner || context.epoch != scope.epoch { pending = nil; unconfirmed = false }
        edited(); admissionHint = nil; hasAdmission = false
        currentDetail = "Refresh schedule readiness under the selected session."
    }
    func originalResolved(_ entry: NativePendingEntry) {
        if refusedOriginal != entry, case .schedule(let original) = entry.input, original.kind == "admit" { admissionHint = entry; hasAdmission = true }
        guard let original = pending?.entry, original.context == entry.context, original.custody == entry.custody, original.input == entry.input else { return }
        pending = nil; unconfirmed = false; clearReview(); didChangeSchedules?()
    }
    private nonisolated static func check(_ capture: LocalCredentialCapture, _ identity: HomeControllerIdentity) throws {
        guard capture.bytes.count == 32 else { throw LocalHealthError.invalidCredential }
        if let reference = capture.nativeReference {
            guard case .recover(let original) = try NativeBrokerWire.request(reference), original.valid,
                  original.receipt.role == .operator, original.verifier == capture.verifier,
                  original.receipt.deployment == identity.deploymentID, original.receipt.owner == identity.ownerID,
                  original.receipt.epoch == identity.authorityEpoch, original.receipt.principal == identity.principalID,
                  identity.revision >= original.receipt.revision else { throw LocalHealthError.nativeGuardConflict }
        }
    }
    func refreshCurrent() async {
        guard canReview else { return }
        busy = true; error = nil; clearReview(); defer { busy = false }
        do {
            let current = try await Task.detached {
                let capture = try self.client.capture(), before = try self.client.identity(capture.bytes)
                try Self.check(capture, before)
                let current = try self.client.current(capture.bytes, before.principalID), after = try self.client.identity(capture.bytes)
                guard after.matchesAuthority(before), after.revision >= before.revision else { throw LocalHealthError.sessionChanged }
                if case .lifecycle(let record) = current {
                    guard record.epoch == before.authorityEpoch, record.revision <= after.revision else { throw LocalHealthError.invalidResponse }
                }
                return current
            }.value
            switch current {
            case .inactive: currentDetail = "No active schedule."
            case .lifecycle(let record):
                currentDetail = "\(record.state.capitalized) schedule basis · Generation \(record.generation) · Admission \(record.admission)"
                if let reason = record.reason { currentDetail += "\n\(reason.replacingOccurrences(of: "_", with: " "))" }
            }
            status = "Current readiness read. It is separate from an immutable original receipt."
        } catch { self.error = error.localizedDescription; status = "Schedule readiness unavailable." }
    }
    func prepare(_ action: NativeScheduleDecision) async {
        guard canReview else { return }
        let draft = draft, revision = sourceRevision, choice = selectedInstant, hint = admissionHint
        if action == .activate && hint == nil { return }
        busy = true; error = nil; clearReview(); defer { busy = false }
        do {
            let prepared = try await Task.detached(priority: .userInitiated) {
                let capture = try self.client.capture(), before = try self.client.identity(capture.bytes)
                try Self.check(capture, before)
                var source: HomeScheduleSource?, timezone: HomeScheduleTimezone?, admission: Int64 = 0
                var detail: String
                switch action {
                case .record, .admit:
                    let catalogue = try self.client.catalogue(capture.bytes)
                    guard catalogue.authorityEpoch == before.authorityEpoch, catalogue.watermark >= before.revision,
                          let thing = catalogue.things.first(where: { $0.id == draft.target }), thing.powerWritable else { throw LocalHealthError.server("schedule_basis_changed") }
                    if draft.kind != .interval {
                        timezone = try self.client.timezone(capture.bytes, draft.zone, draft.localDate + "T" + draft.localTime)
                        if draft.kind == .once && (timezone!.instants.isEmpty || (timezone!.instants.count == 2 && choice == nil)) {
                            let after = try self.client.identity(capture.bytes)
                            guard after.matchesAuthority(before), after.revision >= catalogue.watermark else { throw LocalHealthError.sessionChanged }
                            return (Optional<Review>.none, timezone, "Choose a valid UTC instant before reviewing this one-shot schedule.")
                        }
                    }
                    source = try draft.source(id: self.scheduleID, revision: revision, principal: before.principalID,
                        resource: Int64(thing.resourceRevision), timezone: timezone, choice: choice)
                    detail = Self.describe(source!) + "\n"
                    if let timezone {
                        detail += "\(timezone.name) · \(draft.localTime)\n"
                        detail += timezone.instants.isEmpty ? "This local label is in a gap. Recurring gaps are skipped.\n" : "Resolved UTC: " + timezone.instants.map(Self.instant).joined(separator: ", ") + "\n"
                        if draft.kind != .once { detail += "Recurring folds use the first instant once; gaps are skipped.\n" }
                    }
                    detail += "Missed work is skipped. Screening, admission and activation are separate decisions."
                case .activate:
                    guard let hint, hint.context.matches(before), hint.custody.matches(capture.bytes),
                          case .schedule(let original) = hint.input, original.kind == "admit", let retained = original.source else { throw LocalHealthError.sessionChanged }
                    if case .native = hint.custody {
                        guard capture.nativeReference == (try NativeBrokerWire.request(.recover(hint.custody.nativeOriginal(context: hint.context)))) else { throw LocalHealthError.sessionChanged }
                    } else { guard capture.nativeReference == nil else { throw LocalHealthError.sessionChanged } }
                    let result = try self.client.deliver(capture.bytes, original, before.principalID, true)
                    try result.verify(original: original, principal: before.principalID)
                    guard case .content(let receipt) = result.receipt, receipt.kind == "admit", before.revision >= receipt.revision else { throw LocalHealthError.invalidResponse }
                    source = retained; admission = receipt.revision
                    detail = "Activate retained admission \(admission).\n" + Self.describe(retained) + "\nA current controller clock and the complete admitted basis are checked by Home. Earlier occurrences stay skipped; unsent work is fenced."
                case .suspend:
                    let current = try self.client.current(capture.bytes, before.principalID)
                    if case .lifecycle(let receipt) = current { guard receipt.epoch == before.authorityEpoch else { throw LocalHealthError.sessionChanged } }
                    detail = "Suspend the current schedule and fence unsent work. Packets already handed off cannot be recalled."
                }
                let after = try self.client.identity(capture.bytes)
                guard after.matchesAuthority(before), after.revision >= before.revision else { throw LocalHealthError.sessionChanged }
                return (Optional(Review(capture: capture, identity: after, decision: action, source: source,
                    revision: Int64(after.revision), admission: admission)), timezone, detail)
            }.value
            guard draft == self.draft, revision == sourceRevision, choice == selectedInstant else { throw LocalHealthError.sessionChanged }
            choices = prepared.1?.instants ?? []
            if draft.kind == .once && selectedInstant == nil && choices.count == 1 {
                settingChoice = true; selectedInstant = choices[0]; settingChoice = false
            }
            if let review = prepared.0 { self.review = review; decision = action; reviewDetail = prepared.2; status = "Confirm this reviewed schedule decision before submitting it." }
            else { status = prepared.2 }
        } catch { self.error = error.localizedDescription; status = "Schedule review unavailable." }
    }
    func submit() async {
        guard canSubmit, let review else { return }
        busy = true; error = nil; confirmed = false; defer { busy = false }
        do {
            let operation = "schedule:" + UUID().uuidString.lowercased(), epoch = Int64(review.identity.authorityEpoch)
            let input: HomeScheduleOperation
            switch review.decision {
            case .record: guard let source = review.source else { throw NativeScheduleError.invalidRecord }; input = .review(epoch: epoch, operation: operation, expected: review.revision, source: source)
            case .admit: guard let source = review.source else { throw NativeScheduleError.invalidRecord }; input = .admit(epoch: epoch, operation: operation, expected: review.revision, source: source)
            case .activate: input = .activate(epoch: epoch, operation: operation, expected: review.revision, admission: review.admission)
            case .suspend: input = .suspend(epoch: epoch, operation: operation, expected: review.revision)
            }
            let original = try await journal.begin(.schedule(input), authorityEpoch: Int(epoch), expectedCredential: review.capture.bytes,
                expectedNativeReference: review.capture.nativeReference, expectedController: review.identity)
            pending = original; unconfirmed = true; confirmed = false
            let result = try await Task.detached { try self.client.deliver(original.bytes, input, original.entry.context.principal, false) }.value
            try result.verify(original: input, principal: original.entry.context.principal)
            guard result.receipt != .notFound else { throw LocalHealthError.invalidResponse }
            try await journal.resolving(original); originalResolved(original.entry)
            switch result.receipt {
            case .content(let receipt): status = "Schedule \(receipt.state) at revision \(receipt.revision). Review activation separately."
            case .lifecycle(let receipt): status = "Schedule \(receipt.state) at generation \(receipt.generation). Read readiness and device observations separately."
            case .notFound: break
            }
        } catch {
            if case LocalHealthError.server(let reason) = error, Self.definiteRefusals.contains(reason), let original = pending {
                refusedOriginal = original.entry; defer { refusedOriginal = nil }
                do { try await journal.resolving(original); originalResolved(original.entry); status = "Schedule operation refused. Review the current basis before another decision." }
                catch { status = "Original resolution unconfirmed. Reload pending operations." }
            } else { status = "Schedule operation unconfirmed. Recover its complete original in Pending operations." }
            if pending == nil { clearReview() }
            self.error = error.localizedDescription
        }
    }
    private nonisolated static let definiteRefusals: Set<String> = ["permission_denied", "unauthorized", "invalid_credential", "invalid_schedule_operation", "unsupported_schedule_operation", "schedule_operation_kind_mismatch", "schedule_operation_conflict", "schedule_basis_changed", "schedule_elapsed", "schedule_inactive", "schedule_admission_not_found", "schedule_admission_capacity", "schedule_activation_capacity", "schedule_lifecycle_capacity", "schedule_review_capacity", "unsupported_admission_profile", "resnapshot_required", "stale_authority_epoch", "stale_rule_generation", "maintenance_active", "review_capacity", "review_unavailable", "timezone_basis_changed", "temporal_clock_unavailable", "clock_uncertain", "old_boot", "clock_changed", "invariant_unresolved", "operator_override_active"]
    nonisolated static func instant(_ value: Int64) -> String { ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double(value) / 1_000)) }
    private nonisolated static func describe(_ source: HomeScheduleSource) -> String {
        var detail = "\(source.rule.target) · Power \(source.rule.on ? "On" : "Off") · Source version \(source.sourceRevision)\n"
        var bounds: (Int64, Int64?)?
        switch source.trigger {
        case .once(let zone, _, let date, let time, let due): detail += "Once · \(date) \(time) · \(zone)\nChosen UTC: \(instant(due))"
        case .daily(let zone, _, let time, let start, let end): detail += "Daily · \(time) · \(zone)"; bounds = (start, end)
        case .weekdays(let zone, _, let time, let days, let start, let end):
            let names = ["Mon","Tue","Wed","Thu","Fri","Sat","Sun"]
            detail += days.map { names[Int($0) - 1] }.joined(separator: ", ") + " · \(time) · \(zone)"; bounds = (start, end)
        case .interval(let anchor, let period, let start, let end):
            let cadence = period % 60_000 == 0 ? "\(period / 60_000) minutes" : "\(period) ms"
            detail += "Every \(cadence) · Anchor UTC: \(instant(anchor))"; bounds = (start, end)
        case .countdown(_, _, _, let duration): detail += "Boot-local countdown · \(duration) ms"
        }
        if let (start, end) = bounds {
            detail += "\nStart bound: \(start == 0 ? "none" : instant(start)) · End bound: \(end.map(instant) ?? "none")"
        }
        let late = source.lateWindow % 1_000 == 0 ? "\(source.lateWindow / 1_000) seconds" : "\(source.lateWindow) ms"
        detail += "\nLate window: \(late) · Clock tolerance per side: \(source.tolerance) ms"
        return detail
    }
}

struct NativeSchedulePanel: View {
    @ObservedObject var schedules: NativeScheduleViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Schedules").font(.headline)
            Text(schedules.status).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 10) {
                field("Enrolled Light", prompt: "Home ID", text: $schedules.draft.target)
                Toggle("Set Power On", isOn: $schedules.draft.on)
                Picker("Repeat", selection: $schedules.draft.kind) { ForEach(NativeScheduleKind.allCases) { Text($0.title).tag($0) } }
                if schedules.draft.kind == .interval {
                    DatePicker("Anchor in UTC", selection: $schedules.draft.anchor).environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)
                    field("Period in whole minutes", prompt: "1–44,640", text: $schedules.draft.periodMinutes)
                } else {
                    field("IANA time zone", prompt: "Europe/Stockholm", text: $schedules.draft.zone)
                    field(schedules.draft.kind == .once ? "Local date" : "Date for calendar preview", prompt: "YYYY-MM-DD", text: $schedules.draft.localDate)
                    field("Local time", prompt: "HH:MM:SS", text: $schedules.draft.localTime)
                    if schedules.draft.kind == .weekdays { weekdayControls }
                    if schedules.draft.kind == .once && !schedules.choices.isEmpty {
                        Picker("Chosen UTC instant", selection: $schedules.selectedInstant) {
                            Text("Choose an instant").tag(Optional<Int64>.none)
                            ForEach(schedules.choices, id: \.self) { Text(NativeScheduleViewModel.instant($0)).tag(Optional($0)) }
                        }
                    }
                }
                if schedules.draft.kind != .once {
                    Toggle("Set a start bound", isOn: $schedules.draft.boundedStart)
                    if schedules.draft.boundedStart { DatePicker("Start in UTC", selection: $schedules.draft.start).environment(\.timeZone, TimeZone(secondsFromGMT: 0)!) }
                    Toggle("Set an end bound", isOn: $schedules.draft.boundedEnd)
                    if schedules.draft.boundedEnd { DatePicker("End in UTC", selection: $schedules.draft.end).environment(\.timeZone, TimeZone(secondsFromGMT: 0)!) }
                }
                field("Late window in seconds", prompt: "1–60", text: $schedules.draft.lateSeconds)
                field("Clock uncertainty per side in milliseconds", prompt: "0–1000", text: $schedules.draft.toleranceMilliseconds)
            }.disabled(!schedules.canReview)
            ViewThatFits(in: .horizontal) { HStack { contentControls }; VStack(alignment: .leading) { contentControls } }.disabled(!schedules.canReview)
            ViewThatFits(in: .horizontal) { HStack { lifecycleControls }; VStack(alignment: .leading) { lifecycleControls } }.disabled(!schedules.canReview)
            if let decision = schedules.decision {
                Text(schedules.reviewDetail).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Toggle("I reviewed this schedule decision", isOn: $schedules.confirmed).disabled(!schedules.canReview)
                Button(decision.button) { Task { await schedules.submit() } }.disabled(!schedules.canSubmit)
            }
            Divider()
            Text(schedules.currentDetail).fixedSize(horizontal: false, vertical: true)
            Button("Refresh Schedule Readiness") { Task { await schedules.refreshCurrent() } }.disabled(!schedules.canReview)
            if let error = schedules.error { Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            Text("Home checks one scheduled absolute power effect. Automatic running awaits runtime admission. Activation requires a qualified controller clock; device dispatch requires physical qualification. Countdown admission is currently unavailable.")
                .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func field(_ label: String, prompt: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.callout).fixedSize(horizontal: false, vertical: true)
            TextField(prompt, text: text).textFieldStyle(.roundedBorder).accessibilityLabel(label)
        }
    }
    private var contentControls: some View {
        Group {
            Button("Review Schedule Screening") { Task { await schedules.prepare(.record) } }
            Button("Review Schedule Admission") { Task { await schedules.prepare(.admit) } }
        }
    }
    private var lifecycleControls: some View {
        Group {
            Button("Review Schedule Activation") { Task { await schedules.prepare(.activate) } }.disabled(!schedules.hasAdmission)
            Button("Review Schedule Suspension") { Task { await schedules.prepare(.suspend) } }
        }
    }
    private var weekdayControls: some View {
        ViewThatFits(in: .horizontal) { HStack { weekdays }; VStack(alignment: .leading) { weekdays } }
    }
    private var weekdays: some View {
        ForEach(Array(zip(1...7, ["Mon","Tue","Wed","Thu","Fri","Sat","Sun"])), id: \.0) { day, name in
            Toggle(name, isOn: Binding(get: { schedules.draft.weekdays.contains(Int64(day)) }, set: { selected in
                var days = Set(schedules.draft.weekdays); if selected { days.insert(Int64(day)) } else { days.remove(Int64(day)) }
                schedules.draft.weekdays = days.sorted()
            }))
        }
    }
}

enum HomeRulesMode: String, CaseIterable, Identifiable {
    case explicit, schedule
    var id: String { rawValue }
    var title: String { self == .explicit ? "Explicit action" : "Schedule" }
}
