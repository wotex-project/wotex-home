import AppKit
import Foundation
import SwiftUI

final class FixtureCredentialSource: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Data
    init(_ value: Data) { self.value = value }
    func load() -> Data { lock.withLock { value } }
    func replace(_ replacement: Data) { lock.withLock { value = replacement } }
}

@main
struct LiveProfilesPanelSmoke {
    @MainActor
    static func main() async throws {
        guard CommandLine.arguments.count == 4, let line = readLine(),
              let data = line.data(using: .utf8),
              let secret = try JSONSerialization.jsonObject(with: data) as? [String: String],
              let first = secret["operator"], let second = secret["manager"],
              let original = decode(first), let replacement = decode(second) else { exit(2) }
        let path = CommandLine.arguments[1]; let mode = CommandLine.arguments[2]
        let source = FixtureCredentialSource(original)
        let model = ProfilesViewModel(client: ProfilePanelClient(socketPath: path), credentialLoader: { source.load() })
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { root.deleteLastPathComponent() }
        let url = root.appendingPathComponent("test/support/profiles/lifx-power.json")
        let bytes = try ProfileFileReader.read(url)
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        let link = directory.appendingPathComponent("source-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        do { _ = try ProfileFileReader.read(link); exit(1) } catch LocalHealthError.invalidProfileRequest {}
        model.targetIDInput = "light:native:profile"
        model.importBytes(bytes); try await finished(model)
        try require(model.imported != nil && model.canStart && model.catalogue == nil)
        model.refresh(); try await finished(model)
        try require(model.target?.status == "absent" && model.target?.bindingRevision == 0)
        model.approveImported(); try await finished(model, allowError: mode == "lost-approval")
        let approvalID = model.operationInput
        if mode == "lost-approval" { try await resolve(model, source: source, replacement: replacement, original: original) }
        try require(model.canStart && !model.unconfirmed)
        try await prepare(model)
        if mode == "lost-preparation" {
            try require(model.unconfirmed && !model.canStart)
            let operation = model.operationInput
            source.replace(replacement)
            model.retryOriginal(); try await finished(model)
            try require(model.operationInput == operation && model.review != nil && !model.unconfirmed)
            source.replace(original)
        }
        try require(model.review != nil && !model.canCommit && !model.canStart)
        if mode == "happy" {
            try await preview(model, destination: CommandLine.arguments[3])
        }
        if mode == "expired" {
            try await Task.sleep(for: .milliseconds(750))
            model.identityReviewed = true
            try require(!model.canCommit)
            model.refreshReview(); try await finished(model)
            try require(model.review == nil && model.unconfirmed && !model.canStart)
            model.lookupOperation(); try await finished(model)
            try require(model.unconfirmed)
            model.retryOriginal(); try await finished(model, allowError: true)
            try require(!model.unconfirmed && model.canStart)
            try await prepare(model)
        }
        if mode == "lost-cancellation" {
            model.cancelReview(); try await finished(model, allowError: true)
            try require(model.cancellationUnconfirmed && !model.canCommit && !model.canStart)
            source.replace(replacement)
            model.refreshReview(); try await finished(model)
            try require(model.unconfirmed && model.review == nil && !model.canStart)
            model.lookupOperation(); try await finished(model)
            try require(model.unconfirmed)
            model.retryOriginal(); try await finished(model, allowError: true)
            try require(!model.unconfirmed && model.canStart)
            source.replace(original)
            try await prepare(model)
        }
        let selectionID = model.operationInput
        model.identityReviewed = true
        try require(model.canCommit)
        model.commitSelection(); try await finished(model, allowError: mode == "lost-selection")
        if mode == "lost-selection" { try await resolve(model, source: source, replacement: replacement, original: original) }
        try require(model.review == nil && model.canStart && model.catalogue == nil)
        model.refresh(); try await finished(model)
        try require(model.target?.selectionGeneration == 1 && model.target?.resourceRevision == 1 && model.target?.qualificationHead == nil)
        let currentUse = model.target!.currentUse
        try require(currentUse == (mode == "missing-bytes" ? "profile_artifact_unavailable" : "usable"))
        model.revokeTarget(); try await finished(model)
        let revocationID = model.operationInput
        model.refresh(); try await finished(model)
        try require(model.target?.selectionState == "revoked" && model.target?.selectionGeneration == 2 && model.target?.currentUse == "profile_selection_revoked")
        model.lookupOperation(); try await finished(model)
        model.collect(); try await finished(model)
        let result: [String: Any] = ["mode": mode, "approval_id": approvalID, "selection_id": selectionID, "revocation_id": revocationID, "target_id": "light:native:profile", "prior_current_use": currentUse, "complete": true]
        let output = try JSONSerialization.data(withJSONObject: result, options: .sortedKeys)
        print(String(decoding: output, as: UTF8.self))
    }

    @MainActor
    private static func preview(_ model: ProfilesViewModel, destination: String) async throws {
        _ = NSApplication.shared
        let view = NSHostingView(rootView: ScrollView {
            PortableProfilesPanel(profiles: model).padding(20)
        }.frame(width: 900, height: 900).background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .light))
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 900)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Portable profile review fixture"
        window.contentView = view
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(200))
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw LocalHealthError.invalidResponse }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw LocalHealthError.invalidResponse }
        try data.write(to: URL(fileURLWithPath: destination), options: .atomic)
    }

    @MainActor
    private static func prepare(_ model: ProfilesViewModel) async throws {
        model.refresh(); try await finished(model)
        model.discover(); try await finished(model)
        model.interviewSelected(); try await finished(model)
        try require(model.canPrepare)
        model.prepareSelection(); try await finished(model, allowError: true)
    }

    @MainActor
    private static func resolve(_ model: ProfilesViewModel, source: FixtureCredentialSource, replacement: Data, original: Data) async throws {
        try require(model.unconfirmed && !model.canStart)
        let operation = model.operationInput
        source.replace(replacement)
        model.approveImported()
        try require(model.operationInput == operation)
        model.lookupOperation(); try await finished(model)
        try require(!model.unconfirmed && model.canStart)
        source.replace(original)
    }

    @MainActor
    private static func finished(_ model: ProfilesViewModel, allowError: Bool = false) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while model.busy {
            guard ContinuousClock.now < deadline else { throw LocalHealthError.transport }
            try await Task.sleep(for: .milliseconds(5))
        }
        if !allowError { try require(model.error == nil) }
    }

    private static func require(_ condition: Bool) throws {
        guard condition else { throw LocalHealthError.invalidResponse }
    }
    private static func decode(_ value: String) -> Data? {
        let bytes = Data(base64Encoded: value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "=")
        guard bytes?.count == 32 else { return nil }; return bytes
    }
}
