import SwiftUI

@MainActor
final class NativeNetworkViewModel: ObservableObject {
    nonisolated private let directory: URL?
    nonisolated private let inventory: @Sendable () throws -> [String]
    init(directory: URL? = nil, inventory: @escaping @Sendable () throws -> [String] = { try NativeNetworkInventory.names() }) {
        self.directory = directory; self.inventory = inventory
    }
    @Published var selected = ""
    @Published private(set) var busy = false
    @Published private(set) var names: [String] = []
    @Published private(set) var status = "No network preference check yet"
    @Published private(set) var error: String?
    private var snapshot: NativeNetworkSnapshot?
    var changesAllowed: () -> Bool = { true }
    var savedUnavailable: String? { snapshot?.record.interface.flatMap { names.contains($0) ? nil : $0 } }
    var canSave: Bool { !busy && snapshot != nil && (selected.isEmpty || names.contains(selected)) }

    func refresh() {
        guard !busy else { return }
        busy = true; error = nil
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    let preference = try self.directory.map { try NativeNetworkPreferences.load(directory: $0) } ?? NativeNetworkPreferences.load()
                    return (preference, try self.inventory())
                }.value
                snapshot = result.0; names = result.1; selected = result.0.record.interface ?? ""
                status = summary(result.0)
                if savedUnavailable != nil { status += " The saved interface is unavailable; choose another or disable capture." }
            } catch {
                snapshot = nil; names = []; status = "Network preferences unavailable"; self.error = error.localizedDescription
            }
            busy = false
        }
    }
    func save() {
        guard canSave, changesAllowed(), let original = snapshot else { return }
        let chosen = selected
        busy = true; error = nil
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    if !chosen.isEmpty, !(try self.inventory()).contains(chosen) { throw NativeNetworkPreferenceError.unavailable }
                    if let directory = self.directory { return try NativeNetworkPreferences.save(directory: directory, expected: original, interface: chosen.isEmpty ? nil : chosen) }
                    return try NativeNetworkPreferences.save(expected: original, interface: chosen.isEmpty ? nil : chosen)
                }.value
                snapshot = result; status = summary(result) + " Stop and enable Home to apply it."
            } catch {
                snapshot = nil // No automatic overwrite/retry after conflict or uncertainty.
                status = "Preference save not confirmed. Refresh before saving again."
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
    private func summary(_ value: NativeNetworkSnapshot) -> String {
        if let name = value.record.interface { return "Next start: read-only LIFX discovery on \(name)." }
        return "Next start: device discovery disabled."
    }
}

struct NativeNetworkPanel: View {
    @ObservedObject var network: NativeNetworkViewModel
    var changesAllowed: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Device network").font(.headline)
            Text(network.status).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Picker("Discovery", selection: $network.selected) {
                    Text("Disabled").tag("")
                    ForEach(network.names, id: \.self) { Text($0).tag($0) }
                    if let unavailable = network.savedUnavailable { Text("\(unavailable) (unavailable)").tag(unavailable).disabled(true) }
                }.frame(maxWidth: 300).disabled(network.busy || !changesAllowed)
                Button("Refresh Interfaces") { network.refresh() }.disabled(network.busy)
                Button("Save for Next Start") { network.save() }.disabled(!network.canSave || !changesAllowed)
            }
            Text("Choose your local device network. Saving configures the next Home start; Discover Devices starts a separate read-only search. Enrollment, access and physical qualification are separate steps.")
                .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error = network.error { Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
        }
    }
}
