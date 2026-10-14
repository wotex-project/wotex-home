import AppKit
import Foundation
import SwiftUI

@MainActor
final class NativeExternalReportViewModel: ObservableObject {
    private let reader: @Sendable (String, String) async throws -> HomeExternalReport
    private let monotonic: @Sendable () -> UInt64
    @Published var targetIDInput = "" { didSet { if oldValue != targetIDInput { invalidate() } } }
    @Published var capabilityInput = "" { didSet { if oldValue != capabilityInput { invalidate() } } }
    @Published private(set) var report: HomeExternalReport?
    @Published private(set) var busy = false
    @Published private(set) var status = "Choose an external Thing and channel to read its reported value."
    @Published private(set) var error: String?
    @Published private(set) var presentationExpired = false
    private var generation: UInt64 = 0
    private var startedAt: UInt64 = 0
    private var clockInvalid = false
    private var expiry: Task<Void, Never>?

    init(reader: @escaping @Sendable (String, String) async throws -> HomeExternalReport,
         monotonic: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.reader = reader; self.monotonic = monotonic
    }
    var canRead: Bool { !busy && LocalHealthClient.profileID(targetIDInput) && LocalHealthClient.profileID(capabilityInput) }
    var canChangeSession: Bool { !busy }
    var elapsedMilliseconds: Int64 {
        let now = monotonic()
        guard !clockInvalid, now >= startedAt else { clockInvalid = true; return Int64.max }
        let elapsed = now - startedAt
        return Int64(min(UInt64(Int64.max), elapsed / 1_000_000 + (elapsed % 1_000_000 == 0 ? 0 : 1)))
    }
    var displayedValue: HomeExternalReportedValue? {
        presentationExpired ? nil : report?.displayedValue(elapsedMilliseconds: elapsedMilliseconds)
    }
    var displayedFreshness: String {
        guard let report else { return "missing" }
        return report.freshness == "fresh" && displayedValue == nil ? "expired" : report.freshness
    }
    private func invalidate() { generation &+= 1; expiry?.cancel(); expiry = nil; report = nil; error = nil; presentationExpired = true }
    func invalidateSessionView() { invalidate(); status = "Read the report under the selected session." }
    func hostDidWake() { invalidate(); status = "Host availability changed. Read the report again." }
    func load() async {
        guard canRead else { return }
        let target = targetIDInput, key = capabilityInput, original = generation, started = monotonic()
        expiry?.cancel(); expiry = nil; presentationExpired = true
        busy = true; report = nil; error = nil; status = "Reading reported evidence…"
        defer { busy = false }
        do {
            let result = try await reader(target, key)
            guard !Task.isCancelled, generation == original, target == targetIDInput, key == capabilityInput,
                  result.target == target, result.key == key else { throw LocalHealthError.sessionChanged }
            report = result; startedAt = started; clockInvalid = false; presentationExpired = false
            status = "Reported evidence read."
            if result.freshness == "fresh" {
                let remaining = result.remainingMilliseconds - elapsedMilliseconds
                if remaining <= 0 { presentationExpired = true }
                else {
                    expiry = Task { [weak self] in
                        do { try await Task.sleep(for: .milliseconds(remaining)) } catch { return }
                        guard let self, generation == original, !Task.isCancelled else { return }
                        presentationExpired = true
                    }
                }
            }
        } catch {
            self.error = error.localizedDescription
            status = "Report read unavailable under this session."
        }
    }
}

struct NativeExternalReportPanel: View {
    @ObservedObject var reports: NativeExternalReportViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(reports.status).fixedSize(horizontal: false, vertical: true)
            TextField("External Thing ID", text: $reports.targetIDInput).textFieldStyle(.roundedBorder)
                .accessibilityLabel("External Thing ID")
            TextField("Capability key", text: $reports.capabilityInput).textFieldStyle(.roundedBorder)
                .accessibilityLabel("External capability key")
            Button("Read Report") { Task { await reports.load() } }.disabled(!reports.canRead)
            if let report = reports.report {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    let value = reports.displayedValue
                    let freshness = reports.displayedFreshness
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(report.target) · \(report.key)").font(.headline).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Reported value: \(value?.coordinate ?? "Unknown")").font(.title3)
                            .accessibilityLabel("Reported \(report.key): \(value?.coordinate ?? "unknown")")
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        Text("Freshness: \(freshness)\(report.reason.map { " · " + $0.replacingOccurrences(of: "_", with: " ") } ?? "")")
                            .foregroundStyle(value == nil ? Color.orange : Color.primary).fixedSize(horizontal: false, vertical: true)
                        if let value {
                            Text("Semantic: \(value.semantic)").textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            Text("Consumer: \(value.consumer)").textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            Text("Unit metadata: \(value.unit)").font(.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                        Text("Report \(report.reportRevision.map(String.init) ?? "absent") · Selection \(report.selectionRevision) · Resource \(report.resourceRevision) · Store \(report.revision) · Authority \(report.epoch)")
                            .font(.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }.accessibilityElement(children: .contain)
                }
            }
            if let error = reports.error { Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
        }
    }
}
