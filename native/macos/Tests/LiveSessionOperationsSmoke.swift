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
        guard CommandLine.arguments.count == 3, let line = readLine(),
              let secret = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: String],
              let original = decode(secret["operator"]), let replacement = decode(secret["reader"]) else { throw OperationSmokeError.failed }
        let path = CommandLine.arguments[1]; let mode = CommandLine.arguments[2]
        let source = OperationCredentialSource(original)
        let model = HealthViewModel(credentialLoader: { source.load() }, socketPath: { path })
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
        try require(model.hasUnconfirmedOperation && !model.canChangeSession)
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
        try require(!model.hasUnconfirmedOperation && model.canChangeSession)
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
    private static func require(_ value: Bool, line: Int = #line) throws { if !value { throw OperationSmokeError.assertion(line) } }
}
