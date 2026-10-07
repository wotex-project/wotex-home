import AppKit
import Darwin
import Foundation
import SwiftUI

private enum AccessSmokeError: Error { case assertion(UInt) }
private final class AccessCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var value: LocalCredentialCapture
    private var count = 0
    init(_ value: LocalCredentialCapture) { self.value = value }
    func capture() -> LocalCredentialCapture { lock.withLock { count += 1; return value } }
    func replace(_ value: LocalCredentialCapture) { lock.withLock { self.value = value } }
    var calls: Int { lock.withLock { count } }
}

@main
struct NativeAccessPanelSmoke {
    @MainActor
    static func main() async {
        do { try await run() }
        catch AccessSmokeError.assertion(let line) { print("{\"complete\":false,\"line\":\(line)}") }
        catch { print("{\"complete\":false,\"line\":0}") }
    }
    @MainActor
    private static func run() async throws {
        guard CommandLine.arguments.count == 6, let line = readLine(),
              let values = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: String],
              let encoded = values["secret"], let bytes = decode(encoded), let raw = values["reference"],
              case .recover(let reference) = try NativeBrokerWire.request(Data(raw.utf8)) else { throw AccessSmokeError.assertion(#line) }
        let api = CommandLine.arguments[1], accessPath = CommandLine.arguments[2], mode = CommandLine.arguments[4]
        let directory = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
        let capture = LocalCredentialCapture(bytes: bytes, nativeReference: Data(raw.utf8))
        let source = AccessCapture(capture)
        let journal = NativePendingCoordinator(persistence: NativePendingPersistence(directory: directory),
            capture: { source.capture() }, socketPath: { api })
        try require(!journal.canStart && source.calls == 0)
        await journal.loadIfNeeded()
        try require(!journal.needsReload && source.calls == 0)
        let client = NativeAccessClient(capture: { source.capture() },
            identity: { try LocalHealthClient.fetchControllerIdentity(socketPath: api, credential: $0) },
            target: { try LocalHealthClient.fetchProfileTarget(socketPath: api, credential: $0, targetID: $1) },
            deliver: { try exchange(accessPath, change: $0, lookup: $1) })
        let model = NativeAccessViewModel(client: client, journal: journal)
        journal.didResolve = { [weak model] in model?.originalResolved($0) }
        if mode.hasPrefix("restart-") {
            try require(journal.entries.count == 1 && !journal.canStart && source.calls == 0)
            let entry = journal.entries[0]
            await journal.recover(entry, action: mode == "restart-retry" ? .retry : .lookup, custody: { _ in bytes }, execute: { entry, credential, path, action in
                try NativePendingRecoveryOperations.execute(entry, credential: credential, socketPath: path, action: action,
                    nativeAccess: { try exchange(accessPath, change: $0, lookup: $1) })
            })
            try require(journal.error == nil && journal.entries.isEmpty && journal.canStart && source.calls == 0)
            try require(try NativePendingStorage.load(directory: directory).document.version == .v2)
            print("{\"complete\":true}"); return
        }
        model.targetIDInput = "light:fixture"
        await model.review(mode.hasPrefix("revoke") ? .revoke : .grant)
        try require(model.error == nil && model.reviewedAction != nil && !model.canSubmit && journal.entries.isEmpty)
        if mode == "grant-success" { try await preview(model, journal: journal, destination: CommandLine.arguments[5]) }
        if mode == "grant-unavailable" {
            // A structurally valid expanded declaration cannot be granted.
            let snapshot = try LocalHealthClient.fetchProfileTarget(socketPath: api, credential: bytes, targetID: "light:fixture")
            var declaration = try JSONSerialization.jsonObject(with: snapshot.declaration!) as! [String: Any]
            var capabilities = declaration["capabilities"] as! [[String: Any]]
            var extra = capabilities[0]; extra["key"] = "brightness"; extra["value_kind"] = "fraction"; extra["unit"] = "ppm"
            capabilities.append(extra); declaration["capabilities"] = capabilities
            let expanded = HomeProfileTarget(targetID: snapshot.targetID, storeRevision: snapshot.storeRevision, authorityEpoch: snapshot.authorityEpoch,
                policyGeneration: snapshot.policyGeneration, ruleGeneration: snapshot.ruleGeneration, status: snapshot.status,
                profileRef: snapshot.profileRef, resourceRevision: snapshot.resourceRevision, bindingRevision: snapshot.bindingRevision,
                selectionRevision: snapshot.selectionRevision, selectionGeneration: snapshot.selectionGeneration, selectionState: snapshot.selectionState,
                artifactDigest: snapshot.artifactDigest, identity: snapshot.identity, identityStatus: snapshot.identityStatus, currentUse: snapshot.currentUse,
                declaration: try JSONSerialization.data(withJSONObject: declaration), qualificationHead: nil)
            do { _ = try NativeAccessClient.basis(expanded); throw AccessSmokeError.assertion(#line) }
            catch LocalHealthError.server("native_target_unavailable") {}
            model.targetIDInput = "light:other"
            try require(model.reviewedAction == nil && !model.confirmed && !model.canSubmit)
            print("{\"complete\":true}"); return
        }
        model.confirmed = true
        try require(model.canSubmit)
        if mode == "grant-changed-session" {
            source.replace(LocalCredentialCapture(bytes: Data(repeating: 0x71, count: 32), nativeReference: capture.nativeReference))
        } else if mode == "grant-changed-reference" {
            let changed = NativeOriginalReference(receipt: NativeCreationReceipt(deployment: reference.receipt.deployment,
                owner: reference.receipt.owner, epoch: reference.receipt.epoch, role: .operator, principal: reference.receipt.principal,
                revision: reference.receipt.revision + 1), verifier: reference.verifier)
            source.replace(LocalCredentialCapture(bytes: bytes, nativeReference: try NativeBrokerWire.request(.recover(changed))))
        }
        let publicationLock: Int32
        if mode == "grant-publication" {
            publicationLock = open(directory.appendingPathComponent("native-pending-v1.lock").path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
            try require(publicationLock >= 0 && flock(publicationLock, LOCK_EX | LOCK_NB) == 0)
        } else { publicationLock = -1 }
        await model.submit()
        if mode == "grant-changed-session" || mode == "grant-changed-reference" {
            try require(model.error != nil && journal.entries.isEmpty && journal.canStart && !model.unconfirmed)
        } else if mode == "grant-publication" {
            try require(model.error != nil && journal.entries.count == 1 && journal.needsReload && !journal.canStart)
            _ = flock(publicationLock, LOCK_UN); _ = Darwin.close(publicationLock)
            await journal.reload()
            try require(journal.entries.count == 1 && !journal.canStart)
            let entry = journal.entries[0]
            await journal.recover(entry, action: .retry, custody: { _ in bytes }, execute: { entry, credential, path, action in
                try NativePendingRecoveryOperations.execute(entry, credential: credential, socketPath: path, action: action,
                    nativeAccess: { try exchange(accessPath, change: $0, lookup: $1) })
            })
            try require(journal.error == nil && journal.entries.isEmpty && journal.canStart)
        } else if mode.hasSuffix("success") || mode == "grant-stale" || mode == "revoke-unavailable" {
            try require(model.error == nil && !model.unconfirmed && journal.entries.isEmpty && journal.canStart)
        } else {
            try require(model.unconfirmed && journal.entries.count == 1 && !journal.canStart)
            let original = journal.entries[0]
            if mode == "grant-lost" {
                let destination = URL(fileURLWithPath: CommandLine.arguments[5]).deletingPathExtension().path + "-unconfirmed.png"
                try await preview(model, journal: journal, destination: destination)
            }
            if mode == "create-lost" { print("{\"complete\":true}"); return }
            if mode == "grant-refused" {
                for _ in 0..<2 {
                    await model.recover(lookup: false)
                    try require(model.unconfirmed && journal.entries == [original] && !journal.canStart)
                }
            } else {
                let lookup = mode != "grant-unsubmitted"
                if !lookup {
                    await model.recover(lookup: true)
                    try require(model.unconfirmed && journal.entries == [original])
                }
                await model.recover(lookup: lookup)
                try require(model.error == nil && !model.unconfirmed && journal.entries.isEmpty && journal.canStart)
            }
        }
        try require(Mirror(reflecting: model).children.isEmpty)
        print("{\"complete\":true}")
    }
    private static func exchange(_ path: String, change: NativeTargetChange, lookup: Bool) throws -> NativeTargetReply {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw LocalHealthError.transport }
        let connection: NativeSetupConnection
        do { connection = try NativeSetupConnection(fd, accepted: DispatchTime.now().uptimeNanoseconds) }
        catch { _ = Darwin.close(fd); throw error }
        defer { connection.finish() }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX); address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8CString)
        try require(bytes.count <= MemoryLayout.size(ofValue: address.sun_path))
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes.map { UInt8(bitPattern: $0) }) }
        let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        } }
        guard connected == 0 || errno == EINPROGRESS || errno == EAGAIN else { throw LocalHealthError.transport }
        try connection.awaitConnect()
        try connection.writeFrame(lookup ? NativeTargetWire.status(original: change.original, operation: change.operation) : NativeTargetWire.change(change))
        return try NativeTargetWire.reply(connection.readFrame(allowEOF: true), matching: change)
    }
    @MainActor
    private static func preview(_ model: NativeAccessViewModel, journal: NativePendingCoordinator, destination: String) async throws {
        _ = NSApplication.shared
        let view = NSHostingView(rootView: VStack(alignment: .leading, spacing: 20) {
            NativeAccessPanel(access: model); Divider(); NativePendingPanel(journal: journal, recoveryAllowed: true)
        }.padding(24).frame(width: 900, height: 620, alignment: .topLeading).background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .light))
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 620)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(200))
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw AccessSmokeError.assertion(#line) }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let bytes = bitmap.representation(using: .png, properties: [:]) else { throw AccessSmokeError.assertion(#line) }
        try bytes.write(to: URL(fileURLWithPath: destination), options: .atomic)
    }
    private static func require(_ value: Bool, line: UInt = #line) throws { if !value { throw AccessSmokeError.assertion(line) } }
    private static func decode(_ value: String) -> Data? {
        let standard = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        return Data(base64Encoded: standard + String(repeating: "=", count: (4 - standard.count % 4) % 4))
    }
}
