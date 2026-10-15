import Foundation

private enum PairedExternalFailure: Error { case line(Int) }
private final class PairedExternalCalls: @unchecked Sendable {
    private let lock = NSLock(); private var value = 0
    func record() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}
private final class PairedExternalProbe: NativeDomainTransport, @unchecked Sendable {
    let base: any NativeDomainTransport, original: HomeExternalProfileOriginal, drop: Bool
    private let lock = NSLock(); private var mutations = 0, statuses = 0, calls = 0
    init(_ base: any NativeDomainTransport, original: HomeExternalProfileOriginal, drop: Bool) { self.base = base; self.original = original; self.drop = drop }
    var counts: (Int, Int, Int) { lock.lock(); defer { lock.unlock() }; return (mutations, statuses, calls) }
    func request(body: Data, allowNotFound: Bool) throws -> Data {
        lock.lock(); calls += 1; lock.unlock()
        let request = try JSONSerialization.jsonObject(with: body) as! [String: Any], op = request["operation"] as! String
        let mutation = ["external_profile_inspect", "external_trust_change", "external_target_change"].contains(op)
        if mutation {
            try NativePairedExternalProfileSmoke.check(op == (original.kind == .inspection ? "external_profile_inspect" : "external_\(original.kind.rawValue)_change"))
            let member = original.kind == .inspection ? "inspection" : "change"
            try NativePairedExternalProfileSmoke.check(Set(request.keys) == Set(["api_version", "credential", "operation", member]))
            try NativePairedExternalProfileSmoke.check(NSDictionary(dictionary: request[member] as! [String: Any]).isEqual(to: original.fields()))
            lock.lock(); mutations += 1; let prior = statuses; lock.unlock()
            try NativePairedExternalProfileSmoke.check(prior > 0)
        } else if op == original.kind.operation {
            try NativePairedExternalProfileSmoke.check(request["operation_id"] as? String == original.operation || op == "external_inspection_status")
            if request["operation_id"] as? String == original.operation { lock.lock(); statuses += 1; lock.unlock() }
        }
        let response = try base.request(body: body, allowNotFound: allowNotFound)
        if mutation && drop {
            try NativePairedExternalProfileSmoke.check((try JSONSerialization.jsonObject(with: response) as! [String: Any])["outcome"] as? String == "ok")
            throw LocalHealthError.invalidResponse
        }
        return response
    }
}
// Change only live scope replies from the real TLS owner; never a signing seal.
private final class PairedExternalScopeFault: NativeDomainTransport, @unchecked Sendable {
    let base: any NativeDomainTransport, kind: String
    private let lock = NSLock(); private var scopes = 0
    init(_ base: any NativeDomainTransport, kind: String) { self.base = base; self.kind = kind }
    var hits: Int { lock.lock(); defer { lock.unlock() }; return scopes }
    func request(body: Data, allowNotFound: Bool) throws -> Data {
        let response = try base.request(body: body, allowNotFound: allowNotFound)
        let request = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        guard request["operation"] as? String == "controller_scope" else { return response }
        lock.lock(); scopes += 1; let count = scopes; lock.unlock()
        guard count == 3 else { return response }
        var result = try JSONSerialization.jsonObject(with: response) as! [String: Any], scope = result["controller_scope"] as! [String: Any]
        switch kind {
        case "narrow": scope["permissions"] = (scope["permissions"] as! [String]).filter { $0 != "host:maintain" }
        case "widen": scope["permissions"] = ((scope["permissions"] as! [String]) + ["read"]).sorted()
        case "revision": scope["store_revision"] = (scope["store_revision"] as! NSNumber).int64Value - 1
        default: scope["owner_id"] = String(repeating: "a", count: 64)
        }
        result["controller_scope"] = scope
        return try JSONSerialization.data(withJSONObject: result, options: .sortedKeys)
    }
}
@main
struct NativePairedExternalProfileSmoke {
    static func main() async {
        do {
            let header = FileHandle.standardInput.readData(ofLength: 4)
            try check(header.count == 4)
            let size = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }; try check((1...131072).contains(size))
            let input = try JSONSerialization.jsonObject(with: FileHandle.standardInput.readData(ofLength: Int(size))) as! [String: Any]
            let root = URL(fileURLWithPath: input["directory"] as! String), mode = input["mode"] as! String
            let clock: @Sendable () throws -> NativeControllerCertificateClock = {
                let now = Int64(Date().timeIntervalSince1970 * 1000); return try NativeControllerCertificateClock(earliest: now, latest: now)
            }
            if mode == "stage" {
                let invitation = try NativeControllerPairingWire.decodeInvitation(Data((input["invitation"] as! String).utf8))
                let request = try NativeControllerPairingWire.decodeRequest(Data((input["bootstrap"] as! String).utf8))
                let access = NativeControllerAccess(permissions: ["enroll:review", "host:maintain", "profile:manage"], targets: [])
                guard case .paired(let delivered) = try await NativeControllerTLSClient.bootstrap(invitation, request: request, clock: clock(), approvedAccess: access) else { throw PairedExternalFailure.line(#line) }
                let association = try NativeControllerPublicAssociation.corresponding(peer: NativeControllerPeer(invitation: invitation), label: "External fixture", delivered: delivered, request: request, approvedAccess: access)
                let stored = try NativeControllerAssociationStorage.retaining(association, directory: root, expected: .empty)
                _ = try NativeControllerAssociationStorage.selecting(.remote(association.id), directory: root, expected: stored)
                try delivered.credential.write(to: root.appendingPathComponent("raw-fixture.key")); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: root.appendingPathComponent("raw-fixture.key").path)
                print("paired external fixture passed"); return
            }
            var saved = try NativeControllerAssociationStorage.load(directory: root)
            let association = saved.document.records[0]
            if mode == "recover" { saved = try NativeControllerAssociationStorage.selecting(.local, directory: root, expected: saved) }
            if mode == "unsigned" { saved = try NativeControllerAssociationStorage.selecting(.remote(association.id), directory: root, expected: saved) }
            let associations = saved
            let credential = try NativeAuthoringFiles.read(root.appendingPathComponent("raw-fixture.key"), maximum: 32)
            let kind = HomeExternalProfileOriginalKind(rawValue: input["kind"] as! String)!
            let original = try NativeExternalProfileOriginalWire.encode(input["input"] as! [String: Any], kind: kind)
            let directory = root.appendingPathComponent(input["journal"] as! String)
            if !FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
            let context = NativePendingContext(deployment: association.scope.deployment, owner: association.scope.owner, epoch: association.scope.epoch, principal: association.scope.principal)
            let entry = NativePendingEntry(context: context, custody: try .paired(from: association), input: .externalProfile(original), phase: .pending)
            do { _ = try NativePendingRecoveryOperations.external(entry, credential: credential, socketPath: "/private/tmp/paired-external-never.sock", action: .lookup); throw PairedExternalFailure.line(#line) } catch NativePendingError.unavailable {}
            if mode == "unsigned" {
                let clockCalls = PairedExternalCalls()
                let noClock: @Sendable () throws -> NativeControllerCertificateClock = { clockCalls.record(); throw NativeControllerTLSError.tlsClockUncertain }
                do { _ = try await NativePairedControllerSession.selected(expected: associations, clock: noClock); throw PairedExternalFailure.line(#line) } catch NativePairedSessionError.custody(.denied) {}
                let pending = try NativePendingStorage.retaining(entry, directory: directory, expected: .empty)
                for action in [NativePendingRecoveryAction.lookup, .retry, .acknowledgeAbsent] {
                    try check(action.permits(entry))
                    do { _ = try await NativePairedControllerSession.recovering(entry, action: action, pending: pending, associations: associations, clock: noClock); throw PairedExternalFailure.line(#line) } catch NativePairedSessionError.custody(.denied) {}
                }
                for action in [NativePendingRecoveryAction.cancelReview, .acknowledgeUnknown] { try check(!action.permits(entry)) }
                try check(clockCalls.count == 0 && NativePendingStorage.load(directory: directory) == pending)
                let refused = PairedExternalCalls()
                do { _ = try await NativePairedControllerSession.selected(expected: associations, clock: noClock, additionalCheck: { refused.record(); throw LocalHealthError.sessionChanged }); throw PairedExternalFailure.line(#line) } catch NativePairedSessionError.custody(.denied) {}
                try check(refused.count == 1 && clockCalls.count == 0)
                print("paired external fixture passed"); return
            }
            if mode == "revoked" {
                let before = try NativePendingStorage.load(directory: directory)
                do { _ = try await NativeControllerDomainClient.perform(association.peer, credential: credential, clock: clock) {
                    try NativePendingRecoveryOperations.executePairedExternal(entry, association: association, credential: credential, action: .lookup)
                }; throw PairedExternalFailure.line(#line) } catch LocalHealthError.server("unauthorized") {}
                try check(NativePendingStorage.load(directory: directory) == before)
                print("paired external fixture passed"); return
            }
            let guided = mode == "lost" ? try draft(original, reference: input["inspection_ref"] as? [String: Any]) : nil
            try await NativeControllerDomainClient.perform(association.peer, credential: credential, clock: clock) {
                let scope = try LocalHealthClient.fetchControllerScope(socketPath: "", credential: credential)
                let basis = NativePairedAuthoringBasis(association: association, scope: scope)
                let before = try NativePendingStorage.load(directory: directory)
                guard let base = NativeDomainTransportScope.current else { throw PairedExternalFailure.line(#line) }
                let probe = PairedExternalProbe(base, original: original, drop: mode == "lost")
                try NativeDomainTransportScope.$current.withValue(probe) {
                    if mode == "lost" {
                        guard let draft = guided else { throw PairedExternalFailure.line(#line) }
                        let prepared = try NativePairedExternalProfileClient.prepare(basis, credential: credential, draft: draft)
                        try check(prepared.original == original)
                        let filePrepared = try NativePairedExternalProfileClient.prepare(basis, credential: credential, kind: kind) { original }
                        try check(filePrepared.original == original)
                        try NativePairedExternalProfileClient.validate(original, draft: draft, reviewed: basis, identity: prepared.identity, fresh: basis, credential: credential)
                        if kind == .target, draft.kind == .target, (try original.fields())["action"] as? String == "select" {
                            try check(NativePairedExternalProfileClient.sources(basis, credential: credential).sources.count == 1)
                        }
                        try refusals(basis, credential: credential, draft: draft, original: original, entry: entry, probe: probe)
                        let captured = try NativePairedCaptureCorrespondence.entry(input: .externalProfile(original), scope: scope, association: association, pending: before)
                        try check(captured == entry)
                        let retained = try NativePendingStorage.retaining(entry, directory: directory, expected: before)
                        try NativePairedCaptureCorrespondence.publication(of: entry, before: before, after: retained)
                        do { _ = try NativePendingRecoveryOperations.executePairedExternal(entry, association: association, credential: credential, action: .retry); throw PairedExternalFailure.line(#line) } catch NativeExternalProfileDeliveryError.outcomeUnknown {}
                        try check(probe.counts.0 == 1 && NativePendingStorage.load(directory: directory) == retained)
                    } else {
                        let expected = mode == "absence" ? try NativePendingStorage.retaining(entry, directory: directory, expected: before) : before
                        try check(expected.document.version == .v9 && expected.document.entries == [entry])
                        try check(NativePairedRecoveryCorrespondence.association(for: entry, action: .lookup, pending: expected, associations: associations) == association)
                        if mode == "recover" { try check(associations.document.selection == .local) }
                        let result = try NativePendingRecoveryOperations.executePairedExternal(entry, association: association, credential: credential, action: .lookup)
                        if mode == "absence" {
                            guard case .missing = result else { throw PairedExternalFailure.line(#line) }
                            guard case .acknowledgedAbsent = try NativePendingRecoveryOperations.executePairedExternal(entry, association: association, credential: credential, action: .acknowledgeAbsent) else { throw PairedExternalFailure.line(#line) }
                        } else {
                            guard let receipt = result.receipt else { throw PairedExternalFailure.line(#line) }; try NativeExternalProfileMutationClient.verify(receipt, original: original)
                            guard let acknowledged = try NativePendingRecoveryOperations.executePairedExternal(entry, association: association, credential: credential, action: .acknowledgeAbsent).receipt else { throw PairedExternalFailure.line(#line) }
                            try NativeExternalProfileMutationClient.verify(acknowledged, original: original)
                        }
                        let next = try NativePendingStorage.resolving(entry, directory: directory, expected: expected)
                        _ = try NativePairedRecoveryCorrespondence.publication(of: entry, outcome: mode == "absence" ? .resolved("fixture absence") : result.outcome, before: expected, after: next)
                        try check(probe.counts.0 == 0 && next.document.version == .v9 && next.document.entries.isEmpty)
                    }
                }
            }
            print("paired external fixture passed")
        } catch PairedExternalFailure.line(let line) { FileHandle.standardError.write(Data("paired external assertion at line \(line)\n".utf8)); exit(1) }
        catch { FileHandle.standardError.write(Data("paired external fixture failed: \(String(reflecting: type(of: error)))\n".utf8)); exit(1) }
    }
    private static func refusals(_ basis: NativePairedAuthoringBasis, credential: Data, draft: NativeExternalProfileDraft,
                                 original: HomeExternalProfileOriginal, entry: NativePendingEntry, probe: PairedExternalProbe) throws {
        let before = probe.counts
        for permission in original.kind == .target ? ["profile:manage", "enroll:review"] : ["profile:manage"] {
            let scope = HomeControllerScope(identity: basis.scope.identity, permissions: basis.scope.permissions.filter { $0 != permission }, targetIDs: basis.scope.targetIDs)
            let missing = NativePairedAuthoringBasis(association: basis.association, scope: scope)
            var loads = 0
            do { _ = try NativePairedExternalProfileClient.prepare(missing, credential: credential, kind: original.kind) { loads += 1; return original }; throw PairedExternalFailure.line(#line) } catch NativePairedSessionError.scopeConflict {}
            try check(loads == 0)
            do { try NativePairedSessionCorrespondence.checkProfileScope(scope, entry: entry); throw PairedExternalFailure.line(#line) } catch NativePairedSessionError.scopeConflict {}
        }
        do { _ = try NativePairedExternalProfileClient.prepare(basis, credential: credential, draft: .revokeTrust(operation: "bad/id", artifact: String(repeating: "a", count: 64))); throw PairedExternalFailure.line(#line) } catch LocalHealthError.invalidProfileRequest {}
        for action in [NativePendingRecoveryAction.cancelReview, .acknowledgeUnknown] {
            do { _ = try NativePendingRecoveryOperations.executePairedExternal(entry, association: basis.association, credential: credential, action: action); throw PairedExternalFailure.line(#line) } catch NativePendingError.invalidRecord {}
        }
        try check(probe.counts == before)
        for kind in ["narrow", "widen", "revision", "owner"] {
            let fault = PairedExternalScopeFault(probe, kind: kind)
            do {
                _ = try NativeDomainTransportScope.$current.withValue(fault) { try NativePairedExternalProfileClient.prepare(basis, credential: credential, draft: draft) }
                throw PairedExternalFailure.line(#line)
            } catch NativePairedSessionError.scopeConflict {}
            try check(fault.hits == 3 && probe.counts.0 == before.0)
        }
    }
    private static func draft(_ original: HomeExternalProfileOriginal, reference: [String: Any]?) throws -> NativeExternalProfileDraft {
        let f = try original.fields(), op = original.operation
        if original.kind == .inspection { return .inspection(operation: op, objects: try NativeExternalProfileObjects.checked((f["inspection"] as! [String: Any]).filter { ["envelope_ref", "profile", "definitions"].contains($0.key) })) }
        if original.kind == .trust {
            if f["action"] as? String == "revoke" { return .revokeTrust(operation: op, artifact: f["artifact_digest"] as! String) }
            return .approve(operation: op, epoch: (reference!["authority_epoch"] as! NSNumber).int64Value, inspection: reference!["operation_id"] as! String)
        }
        if f["action"] as? String == "revoke" { return .revokeTarget(operation: op, target: f["target_id"] as! String) }
        return .select(operation: op, epoch: (reference!["authority_epoch"] as! NSNumber).int64Value, inspection: reference!["operation_id"] as! String, target: f["target_id"] as! String, source: f["source_ref"] as! String, objects: try NativeExternalProfileObjects.checked(f["objects"] as! [String: Any]))
    }
    static func check(_ value: @autoclosure () throws -> Bool, line: Int = #line) throws { guard try value() else { throw PairedExternalFailure.line(line) } }
}
