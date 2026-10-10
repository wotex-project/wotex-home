import Foundation
import SwiftUI

enum NativeControllerDriverError: LocalizedError {
    case unavailable, clockUnavailable
    var errorDescription: String? {
        switch self {
        case .unavailable: "Reload controller selection before making another request."
        case .clockUnavailable: "Paired requests need a trusted certificate clock. This controller remains selected."
        }
    }
}

struct NativeControllerLocalReadClient: Sendable {
    let capture: @Sendable () throws -> LocalCredentialCapture
    let socket: @Sendable () -> String
    init(capture: @escaping @Sendable () throws -> LocalCredentialCapture = { try OperatorCredential.captureOriginal() },
         socket: @escaping @Sendable () -> String = { LocalHealthClient.defaultSocketPath() }) {
        self.capture = capture; self.socket = socket
    }
}

// This fence contains public selection metadata only. It never opens custody
// and is not the paired session's authorization seal.
private final class ControllerSelectionFence: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: NativeControllerAssociationSnapshot?
    private var generation = UUID()
    private let check: @Sendable (NativeControllerAssociationSnapshot) throws -> Void
    init(check: @escaping @Sendable (NativeControllerAssociationSnapshot) throws -> Void) { self.check = check }
    func update(_ value: NativeControllerAssociationSnapshot?) {
        lock.lock(); snapshot = value; generation = UUID(); lock.unlock()
    }
    func beginLocal() throws -> @Sendable () throws -> Void {
        lock.lock(); let original = snapshot, originalGeneration = generation; lock.unlock()
        guard let original, original.document.selection == .local else { throw NativeControllerDriverError.unavailable }
        try check(original)
        return { [self] in
            lock.lock(); let current = snapshot, currentGeneration = generation; lock.unlock()
            guard current == original, currentGeneration == originalGeneration else { throw LocalHealthError.sessionChanged }
            try check(original)
        }
    }
}

// One owner for window/menu selection. Construction and metadata loading do
// not acquire a credential, start a controller, or issue an API/device request.
@MainActor
final class NativeControllerSessionDriver: ObservableObject {
    private struct Persistence: Sendable {
        let load: @Sendable () throws -> NativeControllerAssociationSnapshot
        let check: @Sendable (NativeControllerAssociationSnapshot) throws -> Void
        let select: @Sendable (NativeControllerSelection, NativeControllerAssociationSnapshot) throws -> NativeControllerAssociationSnapshot
    }
    private let persistence: Persistence
    nonisolated private let fence: ControllerSelectionFence
    private let certificateClock: (@Sendable () throws -> NativeControllerCertificateClock)?
    private let local: NativeControllerLocalReadClient
    @Published private(set) var snapshot: NativeControllerAssociationSnapshot?
    @Published private(set) var busy = false
    @Published private(set) var needsReload = false
    @Published private(set) var error: String?
    private var generation: UInt64 = 0
    var changesAllowed: () -> Bool = { true }
    var selectionChanged: () -> Void = {}

    init(certificateClock: (@Sendable () throws -> NativeControllerCertificateClock)? = nil, directory: URL? = nil,
         local: NativeControllerLocalReadClient = NativeControllerLocalReadClient()) {
        let persistence: Persistence
        if let directory {
            // Foreground fixture metadata only; this cannot create a signed
            // paired session or redirect the production custody factory.
            persistence = Persistence(load: { try NativeControllerAssociationStorage.load(directory: directory) },
                check: { try NativeControllerAssociationStorage.check($0, directory: directory) },
                select: { try NativeControllerAssociationStorage.selecting($0, directory: directory, expected: $1) })
        } else {
            persistence = Persistence(load: { try NativeControllerAssociationStorage.load() },
                check: { try NativeControllerAssociationStorage.check($0) },
                select: { try NativeControllerAssociationStorage.selecting($0, expected: $1) })
        }
        self.persistence = persistence; fence = ControllerSelectionFence(check: persistence.check)
        self.certificateClock = certificateClock
        self.local = local
    }
    var selection: NativeControllerSelection? { snapshot?.document.selection }
    var records: [NativeControllerPublicAssociation] { snapshot?.document.records ?? [] }
    var localSelected: Bool { selection == .local && !needsReload }
    var pairedRecoveryAvailable: Bool { certificateClock != nil && snapshot != nil && !needsReload }
    var label: String {
        guard let snapshot, !needsReload else { return "Controller selection unavailable" }
        switch snapshot.document.selection {
        case .local: return "This Mac"
        case .remote(let id): return snapshot.document.records.first(where: { $0.id == id })?.label ?? "Paired controller unavailable"
        }
    }
    var status: String {
        if needsReload || snapshot == nil { return "Reload saved controller metadata before making requests." }
        if localSelected { return "Local session on this Mac." }
        return certificateClock == nil ? "Selected paired controller · Trusted certificate clock unavailable" : "Selected paired controller · Refresh to authenticate current access"
    }
    nonisolated func installLocalFence() {
        NativeLocalControllerRequestGuard.install { [fence] in try fence.beginLocal() }
    }
    func loadIfNeeded() async { if snapshot == nil && !needsReload { await reload() } }
    func reload() async {
        guard !busy else { return }
        busy = true; error = nil; generation &+= 1; fence.update(nil); selectionChanged()
        defer { busy = false }
        do {
            let persistence = persistence
            let value = try await Task.detached { try persistence.load() }.value
            guard !Task.isCancelled else { throw NativeControllerDriverError.unavailable }
            snapshot = value; needsReload = false; fence.update(value)
        } catch { fail(error) }
    }
    func select(_ selection: NativeControllerSelection) async {
        guard !busy, !needsReload, changesAllowed(), let original = snapshot else { return }
        busy = true; error = nil; generation &+= 1; fence.update(nil); selectionChanged()
        defer { busy = false }
        do {
            let persistence = persistence
            let value = try await Task.detached { try persistence.select(selection, original) }.value
            guard !Task.isCancelled else { throw NativeControllerDriverError.unavailable }
            snapshot = value; fence.update(value)
        } catch { fail(error) }
    }
    private func fail(_ error: Error) {
        needsReload = true; fence.update(nil); self.error = error.localizedDescription
    }
    private func current(_ original: NativeControllerAssociationSnapshot, generation: UInt64, checkMetadata: Bool = true) throws {
        guard !Task.isCancelled, !needsReload, self.generation == generation, snapshot == original else { throw LocalHealthError.sessionChanged }
        if checkMetadata { try persistence.check(original) }
    }
    private func selected(_ original: NativeControllerAssociationSnapshot) async throws -> NativePairedControllerSession {
        guard let certificateClock else { throw NativeControllerDriverError.clockUnavailable }
        return try await NativePairedControllerSession.selected(expected: original, clock: certificateClock)
    }
    func readHome() async throws -> NativeHomeRead {
        try await metadataChecked { try await homeForSelection() }
    }
    private func metadataChecked<Value: Sendable>(_ read: () async throws -> Value) async throws -> Value {
        do { return try await read() }
        catch {
            if error is NativeControllerAssociationError { fail(error); selectionChanged() }
            throw error
        }
    }
    private func homeForSelection() async throws -> NativeHomeRead {
        guard !busy, !needsReload, let original = snapshot else { throw NativeControllerDriverError.unavailable }
        busy = true; defer { busy = false }
        let generation = generation
        let result: NativeHomeRead
        var paired: NativePairedControllerSession?
        switch original.document.selection {
        case .local:
            let completion = try fence.beginLocal()
            let local = local
            result = try await Task.detached {
                let capture = try local.capture()
                let result = try Self.home(socket: local.socket(), credential: capture.bytes, local: true, reference: capture.nativeReference)
                try completion(); return result
            }.value
        case .remote:
            let session = try await selected(original)
            paired = session
            result = try await session.perform { credential in
                try Self.home(socket: "", credential: credential, local: false, identity: session.scope.identity)
            }
        }
        if let paired { try await paired.current() }
        try current(original, generation: generation, checkMetadata: paired == nil)
        try paired?.deliveryCurrent()
        if let paired {
            let basis = try NativePairedPowerViewBasis.deriving(paired, associations: original, view: result.view, generation: generation)
            return NativeHomeRead(health: result.health, view: result.view, overrides: result.overrides, localCredential: nil, pairedPower: basis)
        }
        return result
    }
    nonisolated private static func home(socket: String, credential: Data, local: Bool,
                                        identity: HomeControllerIdentity? = nil, reference: Data? = nil) throws -> NativeHomeRead {
        let before = try LocalHealthClient.fetchControllerIdentity(socketPath: socket, credential: credential)
        try nativeCapture(reference, credential: credential, identity: before)
        if let identity {
            guard before.matchesAuthority(identity), before.revision >= identity.revision else { throw LocalHealthError.nativeGuardConflict }
        }
        let health = try LocalHealthClient.fetch(socketPath: socket, credential: credential)
        let view = try LocalHealthClient.fetchReadView(socketPath: socket, credential: credential)
        let overrides = try LocalHealthClient.fetchOverrides(socketPath: socket, credential: credential, targetIDs: view.catalogue.things.map(\.id))
        let after = try LocalHealthClient.fetchControllerIdentity(socketPath: socket, credential: credential)
        guard before.matchesAuthority(after), health.authorityEpoch == before.authorityEpoch,
              view.catalogue.authorityEpoch == before.authorityEpoch, after.revision >= view.catalogue.watermark else {
            throw LocalHealthError.nativeGuardConflict
        }
        return NativeHomeRead(health: health, view: view, overrides: overrides, localCredential: local ? credential : nil)
    }
    func readThing(target: String, probe: Bool) async throws -> (HomeThingInspection, HomeThingRefresh?) {
        try await metadataChecked { try await thingForSelection(target: target, probe: probe) }
    }
    private func thingForSelection(target: String, probe: Bool) async throws -> (HomeThingInspection, HomeThingRefresh?) {
        guard !busy, !needsReload, let original = snapshot else { throw NativeControllerDriverError.unavailable }
        busy = true; defer { busy = false }
        let generation = generation
        let result: (HomeThingInspection, HomeThingRefresh?)
        var paired: NativePairedControllerSession?
        switch original.document.selection {
        case .local:
            let completion = try fence.beginLocal()
            let local = local
            result = try await Task.detached {
                let capture = try local.capture()
                let result = try Self.thing(target: target, probe: probe, socket: local.socket(), credential: capture.bytes, reference: capture.nativeReference)
                try completion(); return result
            }.value
        case .remote:
            let session = try await selected(original)
            paired = session
            result = try await session.perform { credential in
                try Self.thing(target: target, probe: probe, socket: "", credential: credential, identity: session.scope.identity)
            }
        }
        if let paired { try await paired.current() }
        try current(original, generation: generation, checkMetadata: paired == nil)
        try paired?.deliveryCurrent()
        return result
    }
    nonisolated private static func thing(target: String, probe: Bool, socket: String, credential: Data,
                                         identity: HomeControllerIdentity? = nil, reference: Data? = nil) throws -> (HomeThingInspection, HomeThingRefresh?) {
        let before = try LocalHealthClient.fetchControllerIdentity(socketPath: socket, credential: credential)
        try nativeCapture(reference, credential: credential, identity: before)
        if let identity {
            guard before.matchesAuthority(identity), before.revision >= identity.revision else { throw LocalHealthError.nativeGuardConflict }
        }
        let refreshed = probe ? try NativeThingClient.refresh(socketPath: socket, credential: credential, target: target) : nil
        let view = try NativeThingClient.fetch(socketPath: socket, credential: credential, target: target)
        let after = try LocalHealthClient.fetchControllerIdentity(socketPath: socket, credential: credential)
        guard before.matchesAuthority(after), view.thingID == target, view.principal == before.principalID,
              view.epoch == before.authorityEpoch, view.revision >= before.revision, after.revision >= view.revision,
              refreshed == nil || refreshed?.target == target else { throw LocalHealthError.nativeGuardConflict }
        return (view, refreshed)
    }
    nonisolated private static func nativeCapture(_ reference: Data?, credential: Data, identity: HomeControllerIdentity) throws {
        guard let reference else { return }
        guard case .recover(let original) = try NativeBrokerWire.request(reference), original.valid,
              original.verifier == LocalHealthClient.profileSHA(credential),
              original.receipt.deployment == identity.deploymentID, original.receipt.owner == identity.ownerID,
              original.receipt.epoch == identity.authorityEpoch, original.receipt.principal == identity.principalID,
              identity.revision >= original.receipt.revision else { throw LocalHealthError.nativeGuardConflict }
    }
    func recover(_ entry: NativePendingEntry, action: NativePendingRecoveryAction, journal: NativePendingCoordinator) async {
        guard pairedRecoveryAvailable, let snapshot, let certificateClock else { return }
        await journal.recoverPaired(entry, action: action, associations: snapshot, clock: certificateClock)
    }
    func submitPower(view: NativePairedPowerViewBasis, thing: HomeThing, on: Bool, operation: String,
                     journal: NativePendingCoordinator) async throws -> NativePairedRecoveryPublication {
        guard !busy, !needsReload, let original = snapshot, original == view.associations,
              generation == view.generation, view.permits(thing) else { throw NativeControllerDriverError.unavailable }
        busy = true; defer { busy = false }
        let session = try await selected(original)
        do { try NativePairedPowerCorrespondence.check(session.scope, original: view.scope, thing: thing, things: view.things) }
        catch { selectionChanged(); throw error }
        try current(original, generation: view.generation, checkMetadata: false)
        let input = NativePendingInput.power(operation: operation, target: thing.id, revision: Int64(thing.resourceRevision), on: on)
        let publication = try await journal.submittingPaired(input, session: session)
        do {
            try current(original, generation: view.generation, checkMetadata: false)
            try publication.deliveryCurrent()
            return publication
        } catch {
            journal.pairedDeliveryUnconfirmed(publication)
            throw error
        }
    }
}

struct NativeControllerSelectionPanel: View {
    @ObservedObject var controller: NativeControllerSessionDriver
    var changesAllowed: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Controller", selection: Binding(get: { controller.needsReload ? nil : controller.selection }, set: { selection in
                if let selection { Task { await controller.select(selection) } }
            })) {
                if controller.needsReload || controller.snapshot == nil { Text("Unavailable").tag(Optional<NativeControllerSelection>.none) }
                Text("This Mac").tag(Optional(NativeControllerSelection.local))
                ForEach(controller.records, id: \.id) { record in Text(record.label).tag(Optional(NativeControllerSelection.remote(record.id))) }
            }.pickerStyle(.menu).disabled(!changesAllowed || controller.busy || controller.needsReload || controller.snapshot == nil)
            Text(controller.status).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error = controller.error { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            if controller.needsReload { Button("Reload Controller Selection") { Task { await controller.reload() } }.disabled(!changesAllowed || controller.busy) }
        }
    }
}
