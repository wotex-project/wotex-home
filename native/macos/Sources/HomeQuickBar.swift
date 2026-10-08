import SwiftUI

struct HomeQuickBar: View {
    @ObservedObject var application: HomeApplicationModel
    var openHome: () -> Void
    private var health: HealthViewModel { application.health }
    private var journal: NativePendingCoordinator { application.pending }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("WoTEx Home", systemImage: "house.fill").font(.headline)
                    Spacer()
                    Button { health.refresh() } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("Refresh Home reports").help("Refresh Home reports")
                        .disabled(application.busy)
                }
                Text(application.setup.session).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(health.summary).font(.callout).fixedSize(horizontal: false, vertical: true)
                if let enabled = health.dispatchEnabled {
                    Label(enabled ? "Physical dispatch enabled" : "Physical dispatch disabled", systemImage: enabled ? "antenna.radiowaves.left.and.right" : "pause.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error = health.error { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            }.padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if journal.needsReload || !journal.entries.isEmpty || journal.error != nil {
                        HomeSection(title: "Recovery") { NativePendingPanel(journal: journal, recoveryAllowed: !application.busy) }
                    }
                    if health.unknownWarning {
                        Label(health.executionDetail, systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Things").font(.headline).accessibilityAddTraits(.isHeader)
                        if health.things.isEmpty {
                            Text(health.dispatchEnabled == nil ? "Refresh to show enrolled Things in your session. Use Home to set up devices and access." : "No enrolled Things in this session. Use Home to review devices and access.")
                                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(health.things) { thing in thingRow(thing) }
                    }
                    if !health.operationIDInput.isEmpty {
                        HomeSection(title: "Last power request") {
                            Text("Authority " + health.authorityEpochInput).font(.caption).foregroundStyle(.secondary)
                            if let detail = health.powerRequestDetail { Text(detail).font(.callout).fixedSize(horizontal: false, vertical: true) }
                            Text(health.receiptStatus).font(.callout).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                            if let error = health.receiptError { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                            Button("Look Up Original Receipt") { health.lookupReceipt() }.disabled(application.busy)
                        }
                    }
                    Text("On and Off request power. Stored reports can be stale; a held or queued receipt does not confirm a device changed.")
                        .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack {
                Button("Open Home", action: openHome).keyboardShortcut("o")
                Spacer()
                Button("Quit UI") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
            }.padding(12)
        }.frame(width: 380, height: 600)
            .background(Color(nsColor: .windowBackgroundColor))
            .task { await journal.loadIfNeeded() }
    }
    private func thingRow(_ thing: HomeThing) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(thing.id, systemImage: thing.role == "Light" ? "lightbulb" : "sensor")
                .font(.headline).fixedSize(horizontal: false, vertical: true)
            Text(thing.role).font(.caption).foregroundStyle(.secondary)
            if let report = health.observations.first(where: { $0.thingID == thing.id && $0.capabilityKey == "power" }) {
                Text("Stored power: " + report.valueText).font(.callout)
                Text(report.quality + " · " + report.trust).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if thing.powerWritable { Text("Stored power: Unknown").font(.callout).foregroundStyle(.secondary) }
            if thing.powerWritable {
                HStack(spacing: 8) {
                    Button("On") { health.stagePower(thing, on: true) }
                        .accessibilityLabel("Request power On for " + thing.id)
                    Button("Off") { health.stagePower(thing, on: false) }
                        .accessibilityLabel("Request power Off for " + thing.id)
                    Spacer()
                }.buttonStyle(.bordered).disabled(!health.canStagePower(thing))
            } else { Text("Read-only Thing · Inspect in Home").font(.caption).foregroundStyle(.secondary) }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
            .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5) }
    }
}
