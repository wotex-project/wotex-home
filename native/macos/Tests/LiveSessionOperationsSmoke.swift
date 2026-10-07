import AppKit
import Foundation
import SwiftUI

private final class OperationCredentialSource: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Data
    init(_ value: Data) { self.value = value }
    func load() -> Data { lock.withLock { value } }
    func replace(_ replacement: Data) { lock.withLock { value = replacement } }
}
private enum OperationSmokeError: Error { case failed, assertion(Int) }

@main
struct LiveSessionOperationsSmoke {
    @MainActor
    static func main() async {
        do { try await run() }
        catch OperationSmokeError.assertion(let line) { print("{\"complete\":false,\"line\":\(line)}") }
        catch { print("{\"complete\":false,\"line\":0}") }
    }
    @MainActor
    private static func run() async throws {
        guard [4, 5].contains(CommandLine.arguments.count), let line = readLine(),
              let secret = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: String],
              let original = decode(secret["operator"]), let replacement = decode(secret["reader"]) else { throw OperationSmokeError.failed }
        let path = CommandLine.arguments[1]; let mode = CommandLine.arguments[2]
        let source = OperationCredentialSource(original)
        let journal = NativePendingCoordinator(persistence: NativePendingPersistence(directory: URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)),
            capture: { LocalCredentialCapture(bytes: source.load(), nativeReference: nil) }, socketPath: { path })
        await journal.loadIfNeeded()
        let model = HealthViewModel(credentialLoader: { source.load() }, socketPath: { path }, journal: journal)
        journal.didResolve = { [weak model] in model?.originalResolved($0) }
        let setup = NativeSetupViewModel()
        setup.changesAllowed = { model.canChangeSession }
        model.refresh(); try await finished(model)
        try require(model.things.count == 1 && model.canChangeSession && model.error == nil)
        let thing = model.things[0]
        let category = mode.split(separator: "-")[0]
        let missing = mode.contains("-missing-")
        switch category {
        case "power": model.stagePower(thing, on: true)
        case "cancel":
            if missing { model.authorityEpochInput = "1"; model.operationIDInput = "cancel:never-issued" }
            else {
                model.stagePower(thing, on: false); try await finished(model)
                try require(!model.hasUnconfirmedOperation)
            }
            model.cancelPendingRequest()
        case "override": model.issueOverride(thing)
        case "revoke":
            if missing { model.overrideAuthorityEpochInput = "1"; model.overrideOperationIDInput = "override:never-issued" }
            else {
                model.issueOverride(thing); try await finished(model)
                try require(!model.hasUnconfirmedOperation)
            }
            model.revokeOverride()
        case "rule": model.suspendRules()
        default: throw OperationSmokeError.failed
        }
        try await finished(model)
        try require(model.hasUnconfirmedOperation && !model.canChangeSession && journal.entries.count == 1 && !journal.canStart)
        let secondWindow = HealthViewModel(credentialLoader: { source.load() }, socketPath: { path }, journal: journal)
        secondWindow.refresh(); try await finished(secondWindow)
        secondWindow.stagePower(thing, on: false); secondWindow.issueOverride(thing); secondWindow.suspendRules()
        try require(!secondWindow.stageBusy && !secondWindow.overrideBusy && !secondWindow.ruleBusy && secondWindow.operationIDInput.isEmpty && secondWindow.ruleOperationIDInput.isEmpty)
        try require(Mirror(reflecting: model).children.isEmpty)
        source.replace(replacement)
        // Production session guards refuse before any broker/Keychain work.
        setup.role = .transfer; setup.select(); setup.endSession(); setup.selectManual()
        try require(!setup.busy && setup.session == "Manual credential mode")
        let operation: String
        switch category {
        case "power", "cancel": operation = model.operationIDInput
        case "override", "revoke": operation = model.overrideOperationIDInput
        default: operation = model.ruleOperationIDInput
        }
        // A new request cannot overwrite a retained original in this category.
        switch category {
        case "power": model.stagePower(thing, on: false); try require(model.operationIDInput == operation)
        case "override": model.issueOverride(thing); try require(model.overrideOperationIDInput == operation)
        case "rule": model.suspendRules(); try require(model.ruleOperationIDInput == operation)
        default: break
        }
        try require(model.hasUnconfirmedOperation)
        if CommandLine.arguments.count == 5 {
            let entry = journal.entries[0]
            if mode == "power-retry" { try await render(journal) }
            let action: NativePendingRecoveryAction = mode.hasSuffix("lookup") ? .lookup : .retry
            await journal.recover(entry, action: action, custody: { _ in replacement }, execute: NativePendingRecoveryOperations.execute)
            try require(journal.error != nil && journal.entries == [entry] && model.hasUnconfirmedOperation)
            if mode.hasSuffix("unsubmitted") {
                await journal.recover(entry, action: .lookup, custody: { _ in original }, execute: NativePendingRecoveryOperations.execute)
                try require(journal.error == nil && journal.entries == [entry] && model.hasUnconfirmedOperation)
            }
            await journal.recover(entry, action: action, custody: { _ in original }, execute: NativePendingRecoveryOperations.execute)
            try require(journal.error == nil && model.hasUnconfirmedOperation == missing && journal.entries.isEmpty == !missing)
            let output = try JSONSerialization.data(withJSONObject: ["complete": true, "operation": operation], options: .sortedKeys)
            print(String(decoding: output, as: UTF8.self))
            return
        }
        if mode.hasSuffix("unsubmitted") {
            switch category {
            case "power": model.lookupReceipt()
            case "override": model.lookupOverride()
            default: model.lookupRuleOperation()
            }
            try await finished(model)
            try require(model.hasUnconfirmedOperation && !model.canChangeSession)
        }
        if mode.hasSuffix("direct") {
            if category == "cancel" { model.cancelPendingRequest() } else { model.revokeOverride() }
        } else if !mode.hasSuffix("lookup") {
            switch category {
            case "power", "cancel": model.retryPower()
            case "override", "revoke": model.retryOverride()
            default: model.retryRule()
            }
        } else {
            switch category {
            case "power", "cancel": model.lookupReceipt()
            case "override", "revoke": model.lookupOverride()
            default: model.lookupRuleOperation()
            }
        }
        try await finished(model)
        if missing {
            try require(model.hasUnconfirmedOperation && !model.canChangeSession)
            if category == "cancel" { model.lookupReceipt() } else { model.lookupOverride() }
            try await finished(model)
            try require(model.hasUnconfirmedOperation && !model.canChangeSession)
            // Finish with an exact retry frame so the parent can compare the
            // original typed request after the read-only missing lookup.
            if category == "cancel" { model.retryPower() } else { model.retryOverride() }
            try await finished(model)
            try require(model.hasUnconfirmedOperation && !model.canChangeSession)
            let output = try JSONSerialization.data(withJSONObject: ["complete": true, "operation": operation], options: .sortedKeys)
            print(String(decoding: output, as: UTF8.self))
            return
        }
        try require(!model.hasUnconfirmedOperation && model.canChangeSession && journal.entries.isEmpty && journal.canStart)
        let retained = try NativePendingStorage.load(directory: URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true))
        try require(retained.document.entries.isEmpty && retained.document.revision >= 2)
        model.invalidateSessionView()
        try require(model.things.isEmpty && model.observations.isEmpty && model.overrides.isEmpty)
        let priorPowerID = model.operationIDInput
        model.stagePower(thing, on: false)
        try require(!model.stageBusy && model.operationIDInput == priorPowerID)
        let output = try JSONSerialization.data(withJSONObject: ["complete": true, "operation": operation], options: .sortedKeys)
        print(String(decoding: output, as: UTF8.self))
    }
    @MainActor
    private static func finished(_ model: HealthViewModel) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + 10_000_000_000
        while model.busy || model.stageBusy || model.receiptBusy || model.overrideBusy || model.ruleBusy {
            try require(DispatchTime.now().uptimeNanoseconds < deadline)
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    private static func decode(_ text: String?) -> Data? {
        guard let text else { return nil }
        return Data(base64Encoded: text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "=")
    }
    @MainActor
    private static func render(_ journal: NativePendingCoordinator) async throws {
        _ = NSApplication.shared
        let view = NSHostingView(rootView: NativePendingPanel(journal: journal, recoveryAllowed: true).padding(24)
            .frame(width: 880, height: 300, alignment: .topLeading).background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .light))
        view.frame = NSRect(x: 0, y: 0, width: 880, height: 300)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(150)); view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw OperationSmokeError.failed }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let bytes = bitmap.representation(using: .png, properties: [:]) else { throw OperationSmokeError.failed }
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { root.deleteLastPathComponent() }
        let directory = root.appendingPathComponent("_build/native", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try bytes.write(to: directory.appendingPathComponent("pending-panel-preview.png"), options: .atomic)
    }
    private static func require(_ value: Bool, line: Int = #line) throws { if !value { throw OperationSmokeError.assertion(line) } }
}
