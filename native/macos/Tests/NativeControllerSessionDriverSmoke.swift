import AppKit
import Darwin
import Foundation
import SwiftUI

private enum DriverAssertion: Error { case failed(Int) }
private final class DriverCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    let bytes: Data
    init(_ bytes: Data) { self.bytes = bytes }
    func capture() -> LocalCredentialCapture {
        lock.lock(); count += 1; lock.unlock()
        return LocalCredentialCapture(bytes: bytes, nativeReference: nil)
    }
    var captures: Int { lock.lock(); defer { lock.unlock() }; return count }
}

@main
struct NativeControllerSessionDriverSmoke {
    @MainActor static func main() async {
        do {
            let args = CommandLine.arguments
            guard args.count == 5, let line = readLine() else { throw DriverAssertion.failed(#line) }
            let bytes = try OperatorCredential.decode(line)
            let metadata = URL(fileURLWithPath: args[2], isDirectory: true)
            let journalDirectory = URL(fileURLWithPath: args[3], isDirectory: true)
            let vectors = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[4]))) as? [String: Any]
            guard let rows = vectors?["valid_records"] as? [[String: Any]], rows.count == 9, let body = rows[4]["body"] as? String else { throw DriverAssertion.failed(#line) }
            let association = try NativeControllerPublicAssociation.decode(Data(body.utf8))
            let source = DriverCapture(bytes), socket = args[1]
            let controller = NativeControllerSessionDriver(directory: metadata,
                local: NativeControllerLocalReadClient(capture: { source.capture() }, socket: { socket }))
            let journal = NativePendingCoordinator(persistence: NativePendingPersistence(directory: journalDirectory),
                capture: { source.capture() }, socketPath: { socket })
            let application = HomeApplicationModel(pending: journal, controller: controller)
            try require(controller.snapshot == nil && source.captures == 0 && !application.busy)
            await controller.loadIfNeeded(); await journal.loadIfNeeded()
            try require(controller.snapshot == .empty && controller.localSelected && source.captures == 0)
            try require(!FileManager.default.fileExists(atPath: metadata.appendingPathComponent("native-controllers-v1.json").path))
            let staleLocalCompletion = try NativeLocalControllerRequestGuard.acquire()
            await controller.reload()
            do { try staleLocalCompletion(); throw DriverAssertion.failed(#line) }
            catch LocalHealthError.sessionChanged {}
            try require(source.captures == 0 && controller.localSelected)

            application.health.refresh()
            try await until { !application.health.busy }
            try require(application.health.error == nil && application.health.things.count == 1 && source.captures == 1)
            let thing = application.health.things[0]
            try require(thing.id == "light:session-fixture" && application.health.dispatchEnabled == false)
            application.things.targetIDInput = thing.id
            await application.things.load()
            try require(application.things.inspection?.thingID == thing.id && application.things.error == nil && source.captures == 2)

            // Original local recovery remains bound to its stored owner even
            // if another process changes the UI's selection afterwards.
            let input = NativePendingInput.power(operation: "power:session-fixture", target: thing.id,
                revision: Int64(thing.resourceRevision), on: true)
            guard let epoch = application.things.inspection?.epoch else { throw DriverAssertion.failed(#line) }
            let retained = try await journal.begin(input, authorityEpoch: Int(epoch), expectedCredential: bytes)
            guard let original = controller.snapshot else { throw DriverAssertion.failed(#line) }
            let retainedAssociation = try NativeControllerAssociationStorage.retaining(association, directory: metadata, expected: original)
            _ = try NativeControllerAssociationStorage.selecting(.remote(association.id), directory: metadata, expected: retainedAssociation)
            do { _ = try await controller.readHome(); throw DriverAssertion.failed(#line) }
            catch NativeControllerAssociationError.conflict {}
            try require(controller.needsReload && controller.error != nil && !controller.localSelected && application.health.things.isEmpty)
            await controller.reload()
            try require(controller.selection == .remote(association.id) && !controller.localSelected && application.health.things.isEmpty)
            let captures = source.captures
            do { _ = try await controller.readHome(); throw DriverAssertion.failed(#line) }
            catch NativeControllerDriverError.clockUnavailable {}
            do { _ = try await controller.readThing(target: thing.id, probe: true); throw DriverAssertion.failed(#line) }
            catch NativeControllerDriverError.clockUnavailable {}
            try require(source.captures == captures && !application.health.canStagePower(thing))
            try require(association.access.permissions.contains("control:ordinary"))
            application.health.stagePower(thing, on: true)
            try require(application.health.operationIDInput.isEmpty && source.captures == captures)
            do { _ = try LocalHealthClient.fetch(socketPath: socket, credential: bytes); throw DriverAssertion.failed(#line) }
            catch NativeControllerDriverError.unavailable {}
            await journal.recover(retained.entry, action: .retry, custody: { entry in
                guard entry.custody == retained.entry.custody else { throw NativePendingError.conflict }
                return bytes
            }, execute: NativePendingRecoveryOperations.execute)
            try require(journal.entries.isEmpty && journal.error == nil && !journal.needsReload)

            // A disabled choice is inert. A stale no-op still checks CAS, and
            // a document selected away and back cannot validate an old fence.
            controller.changesAllowed = { false }
            await controller.select(.local)
            try require(controller.selection == .remote(association.id))
            controller.changesAllowed = { true }
            await controller.select(.local)
            try require(controller.localSelected)
            guard let local = controller.snapshot else { throw DriverAssertion.failed(#line) }
            let remote = try NativeControllerAssociationStorage.selecting(.remote(association.id), directory: metadata, expected: local)
            _ = try NativeControllerAssociationStorage.selecting(.local, directory: metadata, expected: remote)
            await controller.select(.local)
            try require(controller.needsReload && controller.error != nil && !controller.localSelected)
            do { _ = try LocalHealthClient.fetch(socketPath: socket, credential: bytes); throw DriverAssertion.failed(#line) }
            catch NativeControllerDriverError.unavailable {}
            await controller.reload()
            try require(!controller.needsReload && controller.localSelected)

            // Unsafe metadata remains unavailable, rather than an empty/local
            // default, with no credential capture or socket request.
            let file = metadata.appendingPathComponent("native-controllers-v1.json")
            try Data("malformed".utf8).write(to: file)
            await controller.reload()
            try require(controller.needsReload && !controller.localSelected && source.captures == captures)
            try await render(application, path: args[3] + "/selection.png")
            print("native shared controller selection, real local reads, original recovery, CAS and remote no-fallback passed")
        } catch {
            let detail: String
            if case DriverAssertion.failed(let line) = error { detail = "assertion \(line)" }
            else { detail = String(reflecting: type(of: error)) }
            FileHandle.standardError.write(Data("native controller driver fixture failed: \(detail)\n".utf8)); exit(1)
        }
    }
    @MainActor private static func until(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw DriverAssertion.failed(#line) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
    private static func require(_ condition: Bool, line: Int = #line) throws {
        guard condition else { throw DriverAssertion.failed(line) }
    }
    @MainActor private static func render(_ app: HomeApplicationModel, path: String) async throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        let view = NSHostingView(rootView: HomeQuickBar(application: app, openHome: {}))
        view.frame = NSRect(x: 0, y: 0, width: 380, height: 600)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; window.orderFront(nil); defer { window.close() }
        try await Task.sleep(for: .milliseconds(200)); view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw DriverAssertion.failed(#line) }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw DriverAssertion.failed(#line) }
        try png.write(to: URL(fileURLWithPath: path))
    }
}
