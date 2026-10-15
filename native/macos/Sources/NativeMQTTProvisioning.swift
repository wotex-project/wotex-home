import CryptoKit
import Foundation

enum NativeMQTTProvisionError: LocalizedError {
    case invalid, sourceChanged, conflict, hostRunning, unavailable, outcomeUnknown
    var errorDescription: String? {
        switch self {
        case .invalid: "The selected documents did not pass the installed MQTT producer checks."
        case .sourceChanged: "The prepared files or private Home root changed. Prepare the source again."
        case .conflict: "Different policy is already installed. Stop Home and reconcile it before replacement."
        case .hostRunning: "Stop the local background controller before publishing MQTT policy."
        case .unavailable: "Local MQTT setup requires an available protected signed installation and unchanged private files."
        case .outcomeUnknown: "Publication is not confirmed. Retry only this exact prepared source."
        }
    }
}

// Summary values and wire validation are inert. They cannot mint a protected
// release/Keychain seal or authorize a publication by themselves.
struct NativeMQTTProvisionSummary: Equatable, Sendable, CustomReflectable {
    let authoringSHA256: String, sourceSHA256: String
    let basisSHA256: String, rootSHA256: String
    let channels: Int64, authentication: String
    var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
}

enum NativeMQTTProvisionWire {
    static let format = "wotex-home.native-mqtt-provision@1"
    static func prepare(authoring: URL, source: URL) throws -> Data {
        try encode([format, "prepare", path(authoring), path(source)])
    }
    static func publish(authoring: URL, source: URL, original: NativeMQTTProvisionSummary) throws -> Data {
        guard valid(original) else { throw NativeMQTTProvisionError.invalid }
        return try encode([format, "publish", path(authoring), path(source), original.authoringSHA256,
            original.sourceSHA256, original.basisSHA256, original.rootSHA256])
    }
    static func reply(_ bytes: Data, kind: String, original: NativeMQTTProvisionSummary? = nil) throws -> NativeMQTTProvisionSummary {
        let values = try NativeScalarJSON.decode(bytes)
        guard values.first as? String == format else { throw NativeMQTTProvisionError.invalid }
        if values.count == 3, values[1] as? String == "error", let reason = values[2] as? String {
            switch reason {
            case "invalid_native_mqtt_provisioning": throw NativeMQTTProvisionError.invalid
            case "native_mqtt_source_changed": throw NativeMQTTProvisionError.sourceChanged
            case "native_mqtt_publication_conflict": throw NativeMQTTProvisionError.conflict
            case "native_mqtt_host_running": throw NativeMQTTProvisionError.hostRunning
            case "native_mqtt_publication_uncertain": throw NativeMQTTProvisionError.outcomeUnknown
            case "native_mqtt_provisioning_unavailable": throw NativeMQTTProvisionError.unavailable
            default: throw NativeMQTTProvisionError.invalid
            }
        }
        guard ["prepared", "published"].contains(kind), values.count == 8, values[1] as? String == kind,
              let authoring = values[2] as? String, let source = values[3] as? String,
              let basis = values[4] as? String, let root = values[5] as? String,
              let channels = NativeScalarJSON.integer(values[6], minimum: 1),
              let authentication = values[7] as? String else { throw NativeMQTTProvisionError.invalid }
        let result = NativeMQTTProvisionSummary(authoringSHA256: authoring, sourceSHA256: source,
            basisSHA256: basis, rootSHA256: root, channels: channels, authentication: authentication)
        guard valid(result), original == nil || original == result else { throw NativeMQTTProvisionError.invalid }
        return result
    }
    static func refusal(_ bytes: Data) throws -> NativeMQTTProvisionError? {
        let values = try NativeScalarJSON.decode(bytes)
        guard values.count == 3, values[0] as? String == format, values[1] as? String == "error",
              let reason = values[2] as? String else { return nil }
        switch reason {
        case "invalid_native_mqtt_provisioning": return .invalid
        case "native_mqtt_source_changed": return .sourceChanged
        case "native_mqtt_publication_conflict": return .conflict
        case "native_mqtt_host_running": return .hostRunning
        case "native_mqtt_publication_uncertain": return .outcomeUnknown
        case "native_mqtt_provisioning_unavailable": return .unavailable
        default: return nil
        }
    }
    private static func valid(_ value: NativeMQTTProvisionSummary) -> Bool {
        [value.authoringSHA256,value.sourceSHA256,value.basisSHA256,value.rootSHA256].allSatisfy(NativeCoreWire.digest) &&
            (1...32).contains(value.channels) && ["none","password","keychain"].contains(value.authentication)
    }
    private static func path(_ url: URL) throws -> String {
        guard url.isFileURL, url.path.hasPrefix("/"), (1...1024).contains(url.path.utf8.count),
              !url.path.utf8.contains(0), !url.pathComponents.contains(".."), !url.pathComponents.contains(".") else {
            throw NativeMQTTProvisionError.invalid
        }
        return url.path
    }
    private static func encode(_ values: [String]) throws -> Data {
        let bytes = try JSONSerialization.data(withJSONObject: values, options: [.withoutEscapingSlashes])
        guard (1...4096).contains(bytes.count) else { throw NativeMQTTProvisionError.invalid }
        return bytes
    }
}

struct NativeMQTTPreparedSource: Sendable, CustomReflectable {
    let summary: NativeMQTTProvisionSummary
    fileprivate let authoring: URL, source: URL, directory: URL
    fileprivate let installation: NativeMQTTForegroundSeal
    var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
}

enum NativeMQTTProvisioning {
    static func prepare(authoring: URL, source: URL) throws -> NativeMQTTPreparedSource {
        let installation = try SignedSetupPeer.mqttForegroundRelease()
        guard let directory = try NativePrivateDocuments.directory(create: true) else { throw NativeMQTTProvisionError.unavailable }
        let a = try NativeAuthoringFiles.readImmutable(authoring, maximum: 262_144)
        let s = try NativeAuthoringFiles.readImmutable(source, maximum: 524_288)
        let request = try NativeMQTTProvisionWire.prepare(authoring: authoring, source: source)
        let reply = try NativeCoreConnection.provision(release: SignedSetupPeer.mqttForegroundExecutable(installation),
            dataDirectory: directory, request: request, mayCommit: false)
        let summary = try NativeMQTTProvisionWire.reply(reply, kind: "prepared")
        guard summary.authoringSHA256 == NativeCoreWire.hex(Data(SHA256.hash(data: a))),
              summary.sourceSHA256 == NativeCoreWire.hex(Data(SHA256.hash(data: s))) else { throw NativeMQTTProvisionError.sourceChanged }
        _ = try SignedSetupPeer.mqttForegroundExecutable(installation)
        return NativeMQTTPreparedSource(summary: summary, authoring: authoring, source: source,
            directory: directory, installation: installation)
    }

    static func importCredential(_ url: URL, for prepared: NativeMQTTPreparedSource) throws {
        guard prepared.summary.authentication == "keychain" else { throw NativeMQTTProvisionError.invalid }
        try recheck(prepared)
        var bytes = try NativeAuthoringFiles.readImmutable(url, maximum: 8192)
        defer { bytes.resetBytes(in: 0..<bytes.count); bytes.removeAll(keepingCapacity: false) }
        let credential = try NativeMQTTCredential(document: bytes)
        try recheck(prepared)
        try NativeMQTTKeychainCustodian().importCredential(credential, source: prepared.summary.sourceSHA256,
            deadline: DispatchTime.now().uptimeNanoseconds + 5_000_000_000)
        try recheck(prepared)
    }

    static func publish(_ prepared: NativeMQTTPreparedSource, confirmingUncertain: Bool = false) throws -> NativeMQTTProvisionSummary {
        if !confirmingUncertain { try recheck(prepared) }
        let release = try SignedSetupPeer.mqttForegroundExecutable(prepared.installation)
        guard try NativePrivateDocuments.directory(create: false) == prepared.directory else { throw NativeMQTTProvisionError.sourceChanged }
        let request = try NativeMQTTProvisionWire.publish(authoring: prepared.authoring, source: prepared.source, original: prepared.summary)
        let bytes: Data
        do { bytes = try NativeCoreConnection.provision(release: release, dataDirectory: prepared.directory, request: request, mayCommit: true) }
        catch NativeCoreConnectionError.outcomeUnknown { throw NativeMQTTProvisionError.outcomeUnknown }
        do { _ = try SignedSetupPeer.mqttForegroundExecutable(prepared.installation) }
        catch { throw NativeMQTTProvisionError.outcomeUnknown }
        if let refusal = try? NativeMQTTProvisionWire.refusal(bytes) { throw refusal }
        do { return try NativeMQTTProvisionWire.reply(bytes, kind: "published", original: prepared.summary) }
        catch { throw NativeMQTTProvisionError.outcomeUnknown }
    }

    private static func recheck(_ prepared: NativeMQTTPreparedSource) throws {
        let release = try SignedSetupPeer.mqttForegroundExecutable(prepared.installation)
        guard try NativePrivateDocuments.directory(create: false) == prepared.directory else { throw NativeMQTTProvisionError.sourceChanged }
        let request = try NativeMQTTProvisionWire.prepare(authoring: prepared.authoring, source: prepared.source)
        let bytes = try NativeCoreConnection.provision(release: release, dataDirectory: prepared.directory, request: request, mayCommit: false)
        let current = try NativeMQTTProvisionWire.reply(bytes, kind: "prepared")
        guard current == prepared.summary else { throw NativeMQTTProvisionError.sourceChanged }
        _ = try SignedSetupPeer.mqttForegroundExecutable(prepared.installation)
    }
}
