import Darwin
import AppKit
import Foundation
import SwiftUI

private enum PairedPendingSmokeError: Error { case failed(Int) }
private final class PairedPendingCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func record() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

@main
struct NativePendingPairedSmoke {
    @MainActor static func main() async {
        do {
            guard CommandLine.arguments.count >= 4 else { throw PairedPendingSmokeError.failed(#line) }
            let vectors = try dictionary(CommandLine.arguments[1]), associations = try dictionary(CommandLine.arguments[2])
            let root = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
            if CommandLine.arguments.count == 5 {
                try child(vectors, root: root, mode: CommandLine.arguments[4]); return
            }
            try codecs(vectors, associations: associations)
            try await storage(vectors, root: root)
            try races(root: root)
            print("native paired pending independent codec, original joins, private CAS, restart, races and local recovery refusal passed")
        } catch PairedPendingSmokeError.failed(let line) {
            FileHandle.standardError.write(Data("native paired pending assertion failed at source line \(line)\n".utf8)); exit(1)
        } catch {
            FileHandle.standardError.write(Data("native paired pending fixture failed\n".utf8)); exit(1)
        }
    }
    private static func dictionary(_ path: String) throws -> [String: Any] {
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        guard bytes.count <= 1_048_576, let result = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw PairedPendingSmokeError.failed(#line) }
        return result
    }
    private static func document(_ row: [String: Any]) throws -> NativePendingDocument {
        guard let body = row["body"] as? String else { throw PairedPendingSmokeError.failed(#line) }
        return try NativePendingDocument.decode(Data(body.utf8))
    }
    private static func original(_ vectors: [String: Any]) throws -> NativePendingEntry {
        guard let rows = vectors["valid"] as? [[String: Any]], let first = rows.first,
              let result = try document(first).entries.first else { throw PairedPendingSmokeError.failed(#line) }
        return result
    }
    private static func ordinary() -> NativePendingEntry {
        .init(context: .init(deployment: String(repeating: "d", count: 64), owner: String(repeating: "e", count: 64), epoch: 2, principal: "local-second"),
            custody: .manual(verifier: String(repeating: "f", count: 64)), input: .cancel(operation: "local-second"), phase: .pending)
    }
    private static func codecs(_ vectors: [String: Any], associations: [String: Any]) throws {
        guard let valid = vectors["valid"] as? [[String: Any]], valid.count == 7,
              let invalid = vectors["invalid"] as? [[String: Any]], invalid.count == 31,
              let rows = associations["valid_records"] as? [[String: Any]], let body = rows[0]["body"] as? String else { throw PairedPendingSmokeError.failed(#line) }
        for row in valid {
            let parsed = try document(row)
            try require(parsed.version == .v5 && String(decoding: try parsed.encoded(), as: UTF8.self) == row["body"] as? String)
        }
        for row in invalid { try refused(.invalidRecord) { _ = try document(row) } }
        let association = try NativeControllerPublicAssociation.decode(Data(body.utf8)), entry = try original(vectors)
        try require(entry.custody == (try NativePendingCustody.paired(from: association)))
        try require(entry.custody.matches(association: association, context: entry.context))
        let edited = try association.changingMetadata(label: "Renamed", endpoint: .init(kind: "dns", value: "moved.local"), port: 5555)
        try require(entry.custody.matches(association: edited, context: entry.context))
        for row in rows.dropFirst(2) {
            guard let body = row["body"] as? String else { throw PairedPendingSmokeError.failed(#line) }
            try require(!entry.custody.matches(association: NativeControllerPublicAssociation.decode(Data(body.utf8)), context: entry.context))
        }
        for wrong in [
            NativePendingCustody.paired(association: String(repeating: "0", count: 64), controller: association.peer.controller, creationRevision: 1, verifier: association.verifier),
            .paired(association: association.id, controller: String(repeating: "0", count: 64), creationRevision: 1, verifier: association.verifier),
            .paired(association: association.id, controller: association.peer.controller, creationRevision: 2, verifier: association.verifier),
            .paired(association: association.id, controller: association.peer.controller, creationRevision: 1, verifier: String(repeating: "0", count: 64)),
        ] { try require(!wrong.matches(association: association, context: entry.context)) }
        let wrongContext = NativePendingContext(deployment: entry.context.deployment, owner: entry.context.owner, epoch: 2, principal: entry.context.principal)
        try require(!entry.custody.matches(association: association, context: wrongContext))
        try refused(.invalidRecord) { _ = try entry.custody.nativeOriginal(context: entry.context) }
    }
    @MainActor private static func storage(_ vectors: [String: Any], root: URL) async throws {
        let directory = root.appendingPathComponent("storage", isDirectory: true)
        try make(directory)
        guard let oldBody = vectors["original_v4"] as? String else { throw PairedPendingSmokeError.failed(#line) }
        let file = directory.appendingPathComponent("native-pending-v1.json")
        try write(file, Data(oldBody.utf8))
        let old = try NativePendingStorage.load(directory: directory), entry = try original(vectors)
        try require(old.document.version == .v4 && old.document.entries.count == 1)
        let upgraded = try NativePendingStorage.retaining(entry, directory: directory, expected: old)
        try require(upgraded.document.version == .v5 && upgraded.document.revision == 2 &&
            upgraded.document.entries.contains(old.document.entries[0]) && upgraded.document.entries.contains(entry))
        let bytes = try Data(contentsOf: file)
        try require(try NativePendingStorage.retaining(entry, directory: directory, expected: upgraded) == upgraded)
        try require(try Data(contentsOf: file) == bytes)
        try refused(.conflict) { _ = try NativePendingStorage.retaining(ordinary(), directory: directory, expected: old) }
        let calls = PairedPendingCalls()
        let coordinator = NativePendingCoordinator(persistence: .init(directory: directory), capture: {
            calls.record(); throw NativePendingError.unavailable
        }, socketPath: { calls.record(); return "/private/tmp/woh-paired-never-open.sock" })
        await coordinator.reload()
        for action in [NativePendingRecoveryAction.lookup, .retry, .cancelReview] {
            await coordinator.recover(entry, action: action, custody: { _ in
                calls.record(); return Data(repeating: 8, count: 32)
            }, execute: { _, _, _, _ in calls.record(); return .retained("fixture") })
            try refused(.unavailable) { _ = try NativePendingRecoveryOperations.execute(entry, credential: Data(repeating: 8, count: 32),
                socketPath: "/private/tmp/woh-paired-never-open.sock", action: action) }
            try refused(.unavailable) { _ = try NativePendingRecoveryOperations.execute(entry, credential: Data(repeating: 8, count: 32),
                socketPath: "/private/tmp/woh-paired-never-open.sock", action: action,
                nativeAccess: { _, _ in calls.record(); throw NativePendingError.unavailable }) }
        }
        try require(calls.count == 0 && coordinator.snapshot == upgraded && !coordinator.busy && !coordinator.needsReload)
        try require(try Data(contentsOf: file) == bytes)
        try await render(coordinator)
        let remaining = try NativePendingStorage.resolving(entry, directory: directory, expected: upgraded)
        try require(remaining.document.version == .v5 && remaining.document.entries == old.document.entries)
        let empty = try NativePendingStorage.resolving(old.document.entries[0], directory: directory, expected: remaining)
        try require(empty.document.version == .v5 && empty.document.entries.isEmpty)
        let later = try NativePendingStorage.retaining(old.document.entries[0], directory: directory, expected: empty)
        try require(later.document.version == .v5)
        try require(try NativePendingStorage.load(directory: directory) == later)
        try require(try finish(launch(directory, "inspect-local")) == "paired pending restart metadata passed")
    }
    @MainActor private static func render(_ coordinator: NativePendingCoordinator) async throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let content = NativePendingPanel(journal: coordinator, recoveryAllowed: true).padding(20)
            .frame(width: 480, height: 430, alignment: .topLeading).background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .dark)
        let hosting = NSHostingView(rootView: content)
        hosting.frame = NSRect(x: 0, y: 0, width: 480, height: 430)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(200))
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { throw PairedPendingSmokeError.failed(#line) }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let bytes = bitmap.representation(using: .png, properties: [:]) else { throw PairedPendingSmokeError.failed(#line) }
        let output = URL(fileURLWithPath: "_build/native/paired-pending-preview.png")
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: output)
    }
    private static func races(root: URL) throws {
        let vectors = try dictionary(CommandLine.arguments[1])
        guard let old = vectors["original_v4"] as? String else { throw PairedPendingSmokeError.failed(#line) }
        for index in 0..<12 {
            let directory = root.appendingPathComponent("race-\(index)", isDirectory: true)
            try make(directory); try write(directory.appendingPathComponent("native-pending-v1.json"), Data(old.utf8))
            var children: [(Process, Pipe)] = []
            defer { children.forEach(cleanup) }
            for mode in ["ordinary", "paired"] { children.append(try launch(directory, mode)) }
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while !["ordinary", "paired"].allSatisfy({ FileManager.default.fileExists(atPath: directory.appendingPathComponent("ready-" + $0).path) }) {
                try require(ContinuousClock.now < deadline && children.allSatisfy { $0.0.isRunning })
                Thread.sleep(forTimeInterval: 0.005)
            }
            try write(directory.appendingPathComponent("go"), Data())
            let outcomes = try children.map(finish)
            try require(outcomes.filter { $0 == "published" }.count == 1 && outcomes.filter { $0 == "refused" }.count == 1)
            let loaded = try NativePendingStorage.load(directory: directory)
            try require(loaded.document.revision == 2 && loaded.document.entries.count == 2)
            try require(loaded.document.version == (loaded.document.entries.contains { $0.custody.isPaired } ? .v5 : .v4))
            try require(try finish(launch(directory, "inspect-race")) == "paired pending restart metadata passed")
        }
    }
    private static func child(_ vectors: [String: Any], root: URL, mode: String) throws {
        let snapshot = try NativePendingStorage.load(directory: root)
        if mode.hasPrefix("inspect-") {
            if mode == "inspect-local" { try require(snapshot.document.version == .v5 && snapshot.document.entries.count == 1 && !snapshot.document.entries[0].custody.isPaired) }
            else { try require(snapshot.document.revision == 2 && snapshot.document.entries.count == 2 && snapshot.document.version ==
                (snapshot.document.entries.contains { $0.custody.isPaired } ? .v5 : .v4)) }
            print("paired pending restart metadata passed"); return
        }
        try require(snapshot.document.version == .v4 && snapshot.document.revision == 1)
        try write(root.appendingPathComponent("ready-" + mode), Data())
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !FileManager.default.fileExists(atPath: root.appendingPathComponent("go").path) {
            try require(ContinuousClock.now < deadline); Thread.sleep(forTimeInterval: 0.005)
        }
        do {
            _ = try NativePendingStorage.retaining(mode == "paired" ? original(vectors) : ordinary(), directory: root, expected: snapshot)
            print("published")
        } catch NativePendingError.conflict { print("refused") }
        catch NativePendingError.capacity { print("refused") }
    }
    private static func launch(_ root: URL, _ mode: String) throws -> (Process, Pipe) {
        let child = Process(), pipe = Pipe()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = [CommandLine.arguments[1], CommandLine.arguments[2], root.path, mode]
        child.standardOutput = pipe; child.standardError = pipe; try child.run(); return (child, pipe)
    }
    private static func finish(_ child: (Process, Pipe)) throws -> String {
        defer { cleanup(child) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while child.0.isRunning { try require(ContinuousClock.now < deadline); Thread.sleep(forTimeInterval: 0.005) }
        child.0.waitUntilExit()
        let bytes = child.1.fileHandleForReading.readDataToEndOfFile()
        try require(child.0.terminationStatus == 0 && bytes.count <= 4096)
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private static func cleanup(_ child: (Process, Pipe)) {
        if child.0.isRunning { _ = kill(child.0.processIdentifier, SIGKILL) }; try? child.1.fileHandleForReading.close()
    }
    private static func make(_ root: URL) throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
    private static func write(_ file: URL, _ bytes: Data) throws { try bytes.write(to: file); try require(chmod(file.path, 0o600) == 0) }
    private static func refused(_ expected: NativePendingError, _ work: () throws -> Void) throws {
        do { try work(); throw PairedPendingSmokeError.failed(#line) }
        catch let actual as NativePendingError {
            switch (actual, expected) {
            case (.invalidRecord, .invalidRecord), (.conflict, .conflict), (.unavailable, .unavailable): break
            default: throw PairedPendingSmokeError.failed(#line)
            }
        }
    }
    private static func require(_ value: Bool, line: Int = #line) throws { if !value { throw PairedPendingSmokeError.failed(line) } }
}
