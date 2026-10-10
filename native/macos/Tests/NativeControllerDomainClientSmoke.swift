import Foundation

private enum DomainFixtureError: Error { case failed }
private final class DomainChild: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<String, Never>?
    func retain(_ task: Task<String, Never>) { lock.lock(); self.task = task; lock.unlock() }
    func take() -> Task<String, Never>? { lock.lock(); defer { lock.unlock() }; defer { task = nil }; return task }
}

@main
struct NativeControllerDomainClientSmoke {
    static let absent = "/this-path-must-never-be-used/home.sock"
    static func main() async {
        do {
            let header = FileHandle.standardInput.readData(ofLength: 4)
            guard header.count == 4 else { throw DomainFixtureError.failed }
            let size = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard (1...131_072).contains(size),
                  let input = try JSONSerialization.jsonObject(with: FileHandle.standardInput.readData(ofLength: Int(size))) as? [String: Any],
                  let document = input["invitation"] as? String, let key = input["credential"] as? String,
                  let mode = input["mode"] as? String, let expected = input["expected"] as? String else { throw DomainFixtureError.failed }
            let invitation = try NativeControllerPairingWire.decodeInvitation(Data(document.utf8))
            let peer = try NativeControllerPeer(invitation: invitation)
            let credential = try OperatorCredential.decode(key)
            let producer: @Sendable () throws -> NativeControllerCertificateClock = {
                let now = Int64(Date().timeIntervalSince1970 * 1000)
                return try NativeControllerCertificateClock(earliest: now, latest: now)
            }
            let marker = input["marker"] as? String
            let child = DomainChild()
            let started = ContinuousClock.now
            var actual: String
            do {
                if mode == "authority" {
                    guard let socket = input["socket"] as? String, let principal = input["principal"] as? String,
                          let artifact = input["artifact"] as? String else { throw DomainFixtureError.failed }
                    try await authority(peer, credential: credential, clock: producer, socket: socket,
                        principal: principal, artifact: Data(artifact.utf8))
                } else {
                    let task = Task {
                        try await NativeControllerDomainClient.perform(peer, credential: credential, clock: {
                            if mode == "slow-clock" { Thread.sleep(forTimeInterval: 10.2) }
                            return try producer()
                        }) {
                            if mode == "no-exchange" { return "empty" }
                            if mode == "broker" {
                                do { _ = try NativeBrokerClient.defaultSocketPath(); throw DomainFixtureError.failed }
                                catch NativeBrokerClientError.unavailable {}
                                do { _ = try NativeBrokerClient.status(socketPath: absent); throw DomainFixtureError.failed }
                                catch NativeBrokerClientError.unavailable {}
                            }
                            if mode == "concurrent" {
                                child.retain(Task {
                                    do { _ = try LocalHealthClient.fetch(socketPath: absent, credential: credential); return "ok" }
                                    catch { return outcome(error) }
                                })
                                try waitForMarker(marker)
                            }
                            let health = try LocalHealthClient.fetch(socketPath: absent,
                                credential: mode == "mismatch" ? Data(repeating: 8, count: 32) : credential)
                            guard !health.dispatchEnabled else { throw DomainFixtureError.failed }
                            if mode == "late-decode" { Thread.sleep(forTimeInterval: 10.2) }
                            if mode == "outliving" {
                                child.retain(Task {
                                    try? await Task.sleep(for: .milliseconds(200))
                                    do { _ = try LocalHealthClient.fetch(socketPath: absent, credential: credential); return "ok" }
                                    catch { return outcome(error) }
                                })
                            }
                            return "ok"
                        }
                    }
                    if mode == "cancel" {
                        let until = ContinuousClock.now.advanced(by: .seconds(5))
                        while marker.map({ !FileManager.default.fileExists(atPath: $0) }) == true, ContinuousClock.now < until {
                            try await Task.sleep(for: .milliseconds(10))
                        }
                        guard marker.map({ FileManager.default.fileExists(atPath: $0) }) == true else { throw DomainFixtureError.failed }
                        task.cancel()
                    }
                    _ = try await task.value
                }
                actual = "ok"
            } catch { actual = outcome(error) }
            if let task = child.take() {
                let childOutcome = await task.value
                guard childOutcome == (mode == "outliving" ? "invalidRecord" : "outcomeUnknown") else { throw DomainFixtureError.failed }
            }
            let elapsed = started.duration(to: .now).components.seconds
            guard actual == expected, elapsed < 17,
                  !["slow-clock", "late-decode"].contains(mode) || elapsed >= 9 else {
                FileHandle.standardError.write(Data("domain outcome mismatch: \(mode): \(actual)\n".utf8))
                throw DomainFixtureError.failed
            }
            // Outside operation scope the SDK really resumes its normal UDS
            // checks. This path is absent; success would reveal a leaked scope.
            do { _ = try LocalHealthClient.fetch(socketPath: absent, credential: credential); throw DomainFixtureError.failed }
            catch LocalHealthError.invalidSocket {}
            print("native controller domain case passed")
        } catch {
            FileHandle.standardError.write(Data("native controller domain fixture failed\n".utf8))
            exit(1)
        }
    }

    private static func waitForMarker(_ marker: String?) throws {
        guard let marker else { throw DomainFixtureError.failed }
        let until = ContinuousClock.now.advanced(by: .seconds(5))
        while !FileManager.default.fileExists(atPath: marker), ContinuousClock.now < until { Thread.sleep(forTimeInterval: 0.01) }
        guard FileManager.default.fileExists(atPath: marker) else { throw DomainFixtureError.failed }
    }

    private static func outcome(_ error: any Error) -> String {
        if let error = error as? NativeControllerTLSError { return error.rawValue }
        if case LocalHealthError.server(let reason) = error { return "server:" + reason }
        return "unexpected"
    }

    private static func parity<Value: Sendable>(_ peer: NativeControllerPeer, credential: Data,
        clock: @escaping @Sendable () throws -> NativeControllerCertificateClock, socket: String,
        line: Int = #line,
        _ operation: @escaping @Sendable (String) throws -> Value) async throws -> Value {
        let remote: Value
        do {
            remote = try await NativeControllerDomainClient.perform(peer, credential: credential, clock: clock) {
                try operation(absent)
            }
        } catch {
            FileHandle.standardError.write(Data("typed remote check failed at fixture line \(line)\n".utf8))
            throw error
        }
        let local = try operation(socket)
        // Only public typed domain values are compared, never transport cells,
        // request bytes, custody records or bearer credentials; nothing logged.
        guard String(reflecting: remote) == String(reflecting: local) else {
            FileHandle.standardError.write(Data("typed parity mismatch at fixture line \(line)\n".utf8))
            throw DomainFixtureError.failed
        }
        return remote
    }

    private static func authority(_ peer: NativeControllerPeer, credential: Data,
        clock: @escaping @Sendable () throws -> NativeControllerCertificateClock, socket: String,
        principal: String, artifact: Data) async throws {
        let health = try await parity(peer, credential: credential, clock: clock, socket: socket) {
            try LocalHealthClient.fetch(socketPath: $0, credential: credential)
        }
        guard !health.dispatchEnabled else { throw DomainFixtureError.failed }
        let epoch = health.authorityEpoch
        _ = try await parity(peer, credential: credential, clock: clock, socket: socket) {
            try LocalHealthClient.fetchControllerIdentity(socketPath: $0, credential: credential)
        }
        let view = try await parity(peer, credential: credential, clock: clock, socket: socket) {
            try LocalHealthClient.fetchReadView(socketPath: $0, credential: credential)
        }
        guard let target = view.catalogue.things.first(where: { $0.id == "light:native-domain" }) else { throw DomainFixtureError.failed }
        let power = try await parity(peer, credential: credential, clock: clock, socket: socket) {
            try LocalHealthClient.submitPower(socketPath: $0, credential: credential, targetID: "light:native-domain",
                expectedRevision: 0, authorityEpoch: epoch, operationID: "op:domain-power", on: true)
        }
        guard ["held", "rejected"].contains(power.disposition) else { throw DomainFixtureError.failed }
        _ = try await parity(peer, credential: credential, clock: clock, socket: socket) {
            try LocalHealthClient.fetchReceiptStatus(socketPath: $0, credential: credential,
                authorityEpoch: epoch, operationID: "op:domain-power")
        }
        _ = try await parity(peer, credential: credential, clock: clock, socket: socket) {
            try LocalHealthClient.fetchReceiptStatus(socketPath: $0, credential: credential,
                authorityEpoch: epoch, operationID: "op:domain-absent")
        }
        _ = try await parity(peer, credential: credential, clock: clock, socket: socket) {
            try LocalHealthClient.fetchMaintenanceStatus(socketPath: $0, credential: credential)
        }
        let imported = try await parity(peer, credential: credential, clock: clock, socket: socket) {
            try LocalHealthClient.importProfile(socketPath: $0, credential: credential, bytes: artifact)
        }
        let beforeProfile = try LocalHealthClient.fetch(socketPath: socket, credential: credential).revision
        let profileMaintenance = try await parity(peer, credential: credential, clock: clock, socket: socket) {
            try LocalHealthClient.beginMaintenance(socketPath: $0, credential: credential, authorityEpoch: epoch,
                operationID: "op:domain-profile-begin", expectedRevision: beforeProfile)
        }
        let profile = try HomeProfileOperation(["action": "approve", "authority_epoch": epoch,
            "operation_id": "op:domain-profile", "expected_revision": profileMaintenance.revision,
            "artifact_digest": imported.artifactDigest, "expected_trust_revision": 0])
        _ = try await parity(peer, credential: credential, clock: clock, socket: socket) {
            try LocalHealthClient.changeProfile(socketPath: $0, credential: credential, input: profile)
        }
        _ = try await parity(peer, credential: credential, clock: clock, socket: socket) {
            try LocalHealthClient.fetchProfileOperation(socketPath: $0, credential: credential,
                authorityEpoch: epoch, operationID: profile.operationID, input: profile)
        }
        let afterProfile = try LocalHealthClient.fetch(socketPath: socket, credential: credential).revision
        _ = try await parity(peer, credential: credential, clock: clock, socket: socket) {
            try LocalHealthClient.endMaintenance(socketPath: $0, credential: credential, authorityEpoch: epoch,
                operationID: "op:domain-profile-end", expectedRevision: afterProfile, beginRevision: profileMaintenance.beginRevision)
        }
        _ = try await parity(peer, credential: credential, clock: clock, socket: socket) {
            try LocalHealthClient.fetchProfiles(socketPath: $0, credential: credential)
        }
        _ = try await parity(peer, credential: credential, clock: clock, socket: socket) {
            try NativeRuleClient.current(socketPath: $0, credential: credential)
        }
        let rule = HomeExplicitPowerRule(id: "rule:domain", sourceRevision: 1, target: "light:native-domain", on: true)
        _ = try await parity(peer, credential: credential, clock: clock, socket: socket) {
            try NativeRuleClient.preview(socketPath: $0, credential: credential, rule: rule)
        }
        let beforeRule = try LocalHealthClient.fetch(socketPath: socket, credential: credential).revision
        let original = HomeExplicitRuleOperation.review(epoch: Int64(epoch), operation: "op:domain-review",
            expected: Int64(beforeRule), rule: rule)
        _ = try await parity(peer, credential: credential, clock: clock, socket: socket) {
            try NativeRuleClient.deliver(socketPath: $0, credential: credential, original: original, principal: principal, lookup: false)
        }
        _ = try await parity(peer, credential: credential, clock: clock, socket: socket) {
            try NativeRuleClient.deliver(socketPath: $0, credential: credential, original: original, principal: principal, lookup: true)
        }
        let beforeAdmission = try LocalHealthClient.fetch(socketPath: socket, credential: credential).revision
        let admission = HomeExplicitRuleOperation.admit(epoch: Int64(epoch), operation: "op:domain-admit",
            expected: Int64(beforeAdmission), rule: rule)
        let admitted = try await parity(peer, credential: credential, clock: clock, socket: socket) {
            try NativeRuleClient.deliver(socketPath: $0, credential: credential, original: admission, principal: principal, lookup: false)
        }
        guard case .admission(let ruleReceipt) = admitted.receipt else { throw DomainFixtureError.failed }
        let beforeActivation = try LocalHealthClient.fetch(socketPath: socket, credential: credential).revision
        let activation = HomeExplicitRuleOperation.activate(epoch: Int64(epoch), operation: "op:domain-activate",
            expected: Int64(beforeActivation), admission: Int64(ruleReceipt.revision))
        let activated = try await parity(peer, credential: credential, clock: clock, socket: socket) {
            try NativeRuleClient.deliver(socketPath: $0, credential: credential, original: activation, principal: principal, lookup: false)
        }
        guard case .activation(let generation) = activated.receipt else { throw DomainFixtureError.failed }
        let invocation = HomeExplicitRuleOperation.invoke(epoch: Int64(epoch), operation: "op:domain-invoke",
            generation: Int64(generation.generation), ruleID: rule.id)
        _ = try await parity(peer, credential: credential, clock: clock, socket: socket) {
            try NativeRuleClient.deliver(socketPath: $0, credential: credential, original: invocation, principal: principal, lookup: false)
        }
        _ = try await parity(peer, credential: credential, clock: clock, socket: socket) {
            try NativeScheduleClient.current(socketPath: $0, credential: credential, principal: principal)
        }
        let timezone = try await parity(peer, credential: credential, clock: clock, socket: socket) {
            try NativeScheduleClient.timezone(socketPath: $0, credential: credential, name: "Etc/UTC", local: "2030-01-01T08:00:00")
        }
        guard timezone.instants.count == 1 else { throw DomainFixtureError.failed }
        let beforeSchedule = try LocalHealthClient.fetch(socketPath: socket, credential: credential).revision
        let source = HomeScheduleSource(id: "schedule:domain", sourceRevision: 1, author: principal, rule: rule,
            resourceRevision: Int64(target.resourceRevision), lateWindow: 10_000, tolerance: 100,
            trigger: .interval(anchor: 100_000, period: 60_000, start: 100_000, end: nil))
        let schedule = HomeScheduleOperation.review(epoch: Int64(epoch), operation: "op:domain-schedule",
            expected: Int64(beforeSchedule), source: source)
        _ = try await parity(peer, credential: credential, clock: clock, socket: socket) {
            try NativeScheduleClient.deliver(socketPath: $0, credential: credential, original: schedule, principal: principal, lookup: false)
        }
        _ = try await parity(peer, credential: credential, clock: clock, socket: socket) {
            try NativeScheduleClient.deliver(socketPath: $0, credential: credential, original: schedule, principal: principal, lookup: true)
        }
        let beforeScheduleAdmission = try LocalHealthClient.fetch(socketPath: socket, credential: credential).revision
        let scheduleAdmission = HomeScheduleOperation.admit(epoch: Int64(epoch), operation: "op:domain-schedule-admit",
            expected: Int64(beforeScheduleAdmission), source: source)
        let scheduleAdmitted = try await parity(peer, credential: credential, clock: clock, socket: socket) {
            try NativeScheduleClient.deliver(socketPath: $0, credential: credential, original: scheduleAdmission, principal: principal, lookup: false)
        }
        guard case .content(let scheduleReceipt) = scheduleAdmitted.receipt else { throw DomainFixtureError.failed }
        _ = try await parity(peer, credential: credential, clock: clock, socket: socket) {
            try NativeScheduleClient.source(socketPath: $0, credential: credential, revision: scheduleReceipt.revision, principal: principal)
        }
        let beforeScheduleActivation = try LocalHealthClient.fetch(socketPath: socket, credential: credential).revision
        let scheduleActivation = HomeScheduleOperation.activate(epoch: Int64(epoch), operation: "op:domain-schedule-activate",
            expected: Int64(beforeScheduleActivation), admission: scheduleReceipt.revision)
        _ = try await parity(peer, credential: credential, clock: clock, socket: socket) {
            try NativeScheduleClient.deliver(socketPath: $0, credential: credential, original: scheduleActivation, principal: principal, lookup: false)
        }
        let beforeScheduleSuspension = try LocalHealthClient.fetch(socketPath: socket, credential: credential).revision
        let scheduleSuspension = HomeScheduleOperation.suspend(epoch: Int64(epoch), operation: "op:domain-schedule-suspend",
            expected: Int64(beforeScheduleSuspension))
        _ = try await parity(peer, credential: credential, clock: clock, socket: socket) {
            try NativeScheduleClient.deliver(socketPath: $0, credential: credential, original: scheduleSuspension, principal: principal, lookup: false)
        }
        let beforeMaintenance = try LocalHealthClient.fetch(socketPath: socket, credential: credential).revision
        let maintenance = try await parity(peer, credential: credential, clock: clock, socket: socket) {
            try LocalHealthClient.beginMaintenance(socketPath: $0, credential: credential, authorityEpoch: epoch,
                operationID: "op:domain-maintenance", expectedRevision: beforeMaintenance)
        }
        _ = try await parity(peer, credential: credential, clock: clock, socket: socket) {
            try LocalHealthClient.fetchMaintenanceOperationStatus(socketPath: $0, credential: credential,
                authorityEpoch: epoch, operationID: "op:domain-maintenance")
        }
        _ = try await parity(peer, credential: credential, clock: clock, socket: socket) {
            try LocalHealthClient.endMaintenance(socketPath: $0, credential: credential, authorityEpoch: epoch,
                operationID: "op:domain-maintenance-end", expectedRevision: maintenance.revision, beginRevision: maintenance.beginRevision)
        }
    }
}
