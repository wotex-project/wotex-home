import AppKit
import Foundation
import SwiftUI

private enum ReceiptSmokeError: Error { case failed(Int), refused }
private final class ReceiptCustodyProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var localCount = 0, clockCount = 0
    func local() throws -> Data { lock.lock(); localCount += 1; lock.unlock(); throw ReceiptSmokeError.refused }
    func capture() throws -> LocalCredentialCapture { _ = try local(); throw ReceiptSmokeError.refused }
    func clock() throws -> NativeControllerCertificateClock { lock.lock(); clockCount += 1; lock.unlock(); throw NativeControllerTLSError.tlsClockUncertain }
    var counts: (Int, Int) { lock.lock(); defer { lock.unlock() }; return (localCount, clockCount) }
}
private actor ReceiptReadProbe {
    enum Mode { case found, absent, refused, expired, held }
    private var mode = Mode.found
    private var release: CheckedContinuation<Void, Never>?
    private(set) var calls = 0
    func configure(_ value: Mode) { mode = value }
    func resume() { release?.resume(); release = nil }
    func read(_ entry: NativePendingEntry) async throws -> NativePairedPowerReceiptRead {
        calls += 1
        let mode = mode
        if mode == .held { await withCheckedContinuation { release = $0 } }
        if mode == .refused { throw ReceiptSmokeError.refused }
        let result: HomeReceiptLookup = mode == .absent ? .notFound : .found(HomeReceipt(authorityEpoch: Int(entry.context.epoch), operationID: entry.input.operationID, disposition: "held", reason: nil, revision: 7))
        return NativePairedPowerReceiptRead(entry: entry, result: result,
            deadline: ContinuousClock.now.advanced(by: mode == .expired ? .seconds(-1) : .seconds(5)))
    }
}

@main
struct NativePairedPowerReceiptSmoke {
    @MainActor static func main() async {
        do {
            let args = CommandLine.arguments
            try check(args.count == 5)
            let root = URL(fileURLWithPath: args[1], isDirectory: true)
            let records = try dictionary(args[2])["valid_records"] as! [[String: Any]]
            let original = try NativeControllerPublicAssociation.decode(Data((records[0]["body"] as! String).utf8))
            let other = try NativeControllerPublicAssociation.decode(Data((records[4]["body"] as! String).utf8))
            let row = (try dictionary(args[3])["valid"] as! [[String: Any]])[0]
            let entry = try NativePendingDocument.decode(Data((row["body"] as! String).utf8)).entries[0]
            let first = try NativeControllerAssociationStorage.retaining(original, directory: root, expected: .empty)
            let both = try NativeControllerAssociationStorage.retaining(other, directory: root, expected: first)
            let selected = try NativeControllerAssociationStorage.selecting(.remote(other.id), directory: root, expected: both)
            try metadata(entry, original: original, other: other, selected: selected)
            let custody = ReceiptCustodyProbe()
            do {
                _ = try await NativePairedControllerSession.readPowerReceipt(entry, associations: selected, clock: custody.clock)
                throw ReceiptSmokeError.failed(#line)
            } catch NativePairedSessionError.custody(.denied) {}
            try check(custody.counts == (0, 0))
            let driver = NativeControllerSessionDriver(directory: root,
                local: NativeControllerLocalReadClient(capture: custody.capture))
            await driver.loadIfNeeded()
            do { _ = try await driver.readPowerReceipt(entry); throw ReceiptSmokeError.failed(#line) }
            catch NativeControllerDriverError.clockUnavailable {}
            try check(driver.selection == .remote(other.id) && !driver.busy && custody.counts == (0, 0))
            try await model(entry, root: root, preview: args[4], custody: custody)
            print("native paired receipt correspondence, unsigned gate, explicit model routing and late delivery passed")
        } catch ReceiptSmokeError.failed(let line) {
            FileHandle.standardError.write(Data("native paired receipt assertion failed at line \(line)\n".utf8)); exit(1)
        } catch {
            FileHandle.standardError.write(Data("native paired receipt fixture failed: \(String(reflecting: type(of: error)))\n".utf8)); exit(1)
        }
    }

    private static func metadata(_ entry: NativePendingEntry, original: NativeControllerPublicAssociation,
                                 other: NativeControllerPublicAssociation, selected: NativeControllerAssociationSnapshot) throws {
        try check(try NativePairedPowerReceiptCorrespondence.association(entry, associations: selected) == original)
        try check(selected.document.selection == .remote(other.id))
        let context = entry.context
        func scope(epoch: Int? = nil, revision: Int = 7, permissions: [String] = ["read"], targets: [String] = []) -> HomeControllerScope {
            HomeControllerScope(identity: HomeControllerIdentity(deploymentID: context.deployment, ownerID: context.owner,
                authorityEpoch: epoch ?? Int(context.epoch), revision: revision, principalID: context.principal), permissions: permissions, targetIDs: targets)
        }
        let receipt = HomeReceiptLookup.found(HomeReceipt(authorityEpoch: Int(context.epoch), operationID: entry.input.operationID,
            disposition: "held", reason: nil, revision: 4))
        try NativePairedPowerReceiptCorrespondence.result(receipt, entry: entry, association: original, before: scope(), after: scope(revision: 8))
        try NativePairedPowerReceiptCorrespondence.result(.notFound, entry: entry, association: original, before: scope(), after: scope())
        for after in [scope(epoch: Int(context.epoch) + 1), scope(revision: 6), scope(permissions: ["control:ordinary"]),
                      scope(permissions: ["control:ordinary", "read"]), scope(targets: ["light:fixture"])] {
            try rejected { try NativePairedPowerReceiptCorrespondence.result(receipt, entry: entry, association: original, before: scope(), after: after) }
        }
        for bad in [HomeReceipt(authorityEpoch: Int(context.epoch) + 1, operationID: entry.input.operationID, disposition: "held", reason: nil, revision: 4),
                    HomeReceipt(authorityEpoch: Int(context.epoch), operationID: "op:substituted", disposition: "held", reason: nil, revision: 4),
                    HomeReceipt(authorityEpoch: Int(context.epoch), operationID: entry.input.operationID, disposition: "held", reason: nil, revision: 8)] {
            try rejected { try NativePairedPowerReceiptCorrespondence.result(.found(bad), entry: entry, association: original, before: scope(), after: scope()) }
        }
        let mutations = [
            NativePendingEntry(context: context, custody: .manual(verifier: original.verifier), input: entry.input, phase: .pending),
            NativePendingEntry(context: context, custody: entry.custody, input: .issueOverride(operation: "op:override", target: "light:fixture", revision: 1, duration: 1000), phase: .pending),
            NativePendingEntry(context: context, custody: entry.custody, input: entry.input, phase: .review(token: "review:1", digest: String(repeating: "a", count: 64))),
            NativePendingEntry(context: context, custody: .paired(association: String(repeating: "f", count: 64), controller: original.peer.controller, creationRevision: original.scope.creationRevision, verifier: original.verifier), input: entry.input, phase: .pending),
            NativePendingEntry(context: context, custody: .paired(association: original.id, controller: String(repeating: "a", count: 64), creationRevision: original.scope.creationRevision, verifier: original.verifier), input: entry.input, phase: .pending),
            NativePendingEntry(context: context, custody: .paired(association: original.id, controller: original.peer.controller, creationRevision: original.scope.creationRevision, verifier: String(repeating: "a", count: 64)), input: entry.input, phase: .pending),
            NativePendingEntry(context: NativePendingContext(deployment: context.deployment, owner: context.owner, epoch: context.epoch + 1, principal: context.principal), custody: entry.custody, input: entry.input, phase: .pending)
        ]
        for bad in mutations { try rejected { _ = try NativePairedPowerReceiptCorrespondence.association(bad, associations: selected) } }
        try rejected { _ = try NativePairedPowerReceiptCorrespondence.association(entry, associations: .empty) }
        let cancel = NativePendingEntry(context: context, custody: entry.custody, input: .cancel(operation: entry.input.operationID), phase: .pending)
        try NativePairedPowerReceiptCorrespondence.checkEntry(cancel)
    }

    @MainActor private static func model(_ entry: NativePendingEntry, root: URL, preview: String, custody: ReceiptCustodyProbe) async throws {
        let probe = ReceiptReadProbe()
        let journal = NativePendingCoordinator(persistence: NativePendingPersistence(directory: root), capture: custody.capture)
        let health = HealthViewModel(credentialLoader: custody.local, journal: journal, pairedReceiptReader: { try await probe.read($0) })
        try check(custody.counts == (0, 0) && !health.hasLastPairedReceipt)
        health.originalResolved(entry)
        try check(health.hasLastPairedReceipt && !health.receiptUsesRecordedPair)
        health.useLastPairedReceipt()
        try check(health.receiptUsesRecordedPair && health.operationIDInput == entry.input.operationID)
        health.lookupReceipt(); health.lookupReceipt()
        try await until { !health.receiptBusy }
        try check(await probe.calls == 1 && health.receiptStatus.contains("held") && health.receiptError == nil)
        try await render(health, preview: preview, width: 480)
        try await render(health, preview: preview, width: 840)
        health.cancelPendingRequest(); health.retryPower()
        try check(custody.counts == (0, 0) && journal.entries.isEmpty)
        for mode in [ReceiptReadProbe.Mode.absent, .refused, .expired] {
            await probe.configure(mode); health.lookupReceipt(); try await until { !health.receiptBusy }
            if mode == .absent { try check(health.receiptStatus.contains("No receipt") && health.receiptError == nil) }
            else { try check(health.receiptError != nil) }
            try check(custody.counts == (0, 0) && journal.entries.isEmpty)
        }
        for invalidation in 0..<3 {
            await probe.configure(.held)
            let before = await probe.calls
            health.useLastPairedReceipt(); health.lookupReceipt(); health.lookupReceipt()
            try await until { await probe.calls == before + 1 }
            switch invalidation {
            case 0: health.operationIDInput = "op:edited"
            case 1: health.invalidateSessionView()
            default:
                let newer = NativePendingEntry(context: entry.context, custody: entry.custody,
                    input: .cancel(operation: "op:newer"), phase: .pending)
                health.originalResolved(newer)
            }
            await probe.resume(); try await until { !health.receiptBusy }
            try check(health.receiptError != nil && custody.counts == (0, 0) && journal.entries.isEmpty)
        }
        health.useLastPairedReceipt(); try check(health.operationIDInput == "op:newer")
        health.operationIDInput = "op:unretained"; health.localReceiptAllowed = { false }
        let before = await probe.calls
        health.lookupReceipt(); try check(!health.receiptBusy && health.receiptError != nil && custody.counts == (0, 0))
        health.receiptRequestsAllowed = { false }; health.useLastPairedReceipt(); health.lookupReceipt()
        try check(await probe.calls == before && health.operationIDInput == "op:unretained")
        let unavailable = HealthViewModel(credentialLoader: custody.local, journal: journal)
        unavailable.originalResolved(entry); unavailable.useLastPairedReceipt(); unavailable.lookupReceipt()
        try await until { !unavailable.receiptBusy }
        try check(unavailable.receiptError != nil && custody.counts == (0, 0))
    }
    @MainActor private static func until(_ condition: () async -> Bool) async throws {
        for _ in 0..<300 { if await condition() { return }; try await Task.sleep(for: .milliseconds(5)) }
        throw ReceiptSmokeError.failed(#line)
    }
    @MainActor private static func render(_ model: HealthViewModel, preview: String, width: CGFloat) async throws {
        _ = NSApplication.shared
        let view = NSHostingView(rootView: NativePowerReceiptPanel(health: model, localSelected: false)
            .padding(20).frame(width: width, height: 480, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .light))
        view.frame = NSRect(x: 0, y: 0, width: width, height: 480)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; window.orderFront(nil); defer { window.close() }
        try await Task.sleep(for: .milliseconds(150)); view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw ReceiptSmokeError.failed(#line) }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw ReceiptSmokeError.failed(#line) }
        try png.write(to: URL(fileURLWithPath: preview).appendingPathComponent("paired-power-receipt-\(Int(width)).png"), options: .atomic)
    }
    private static func dictionary(_ path: String) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as! [String: Any]
    }
    private static func rejected(line: Int = #line, _ operation: () throws -> Void) throws {
        do { try operation() } catch is ReceiptSmokeError { throw ReceiptSmokeError.failed(line) } catch { return }
        throw ReceiptSmokeError.failed(line)
    }
    private static func check(_ condition: Bool, line: Int = #line) throws { if !condition { throw ReceiptSmokeError.failed(line) } }
}
