import Darwin
import Foundation

private enum StorageSmokeError: Error { case failed }

@main
struct NativePendingStorageSmoke {
    private static var context: NativePendingContext {
        NativePendingContext(deployment: String(repeating: "a", count: 64), owner: String(repeating: "b", count: 64), epoch: 7, principal: "operator:fixture")
    }
    private static var original: NativePendingEntry {
        NativePendingEntry(context: context, custody: .manual(verifier: String(repeating: "c", count: 64)),
            input: .power(operation: "power:original", target: "lamp:1", revision: 9, on: true), phase: .pending)
    }
    static func main() throws {
        guard CommandLine.arguments.count >= 3 else { throw StorageSmokeError.failed }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        switch CommandLine.arguments[2] {
        case "suite":
            try suite(directory)
            let versioned = directory.appendingPathComponent("versioned", isDirectory: true)
            try FileManager.default.createDirectory(at: versioned, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try versionedAccess(versioned)
            let rules = directory.appendingPathComponent("rules", isDirectory: true)
            try FileManager.default.createDirectory(at: rules, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try versionedRules(rules)
            let schedules = directory.appendingPathComponent("schedules", isDirectory: true)
            try FileManager.default.createDirectory(at: schedules, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try versionedSchedules(schedules)
        case "authoring-suite": try versionedAuthoring(directory)
        case "generation-suite": try versionedGeneration(directory)
        case "paired-authoring-suite": try pairedAuthoringSuite(directory)
        case "paired-authoring-race": try race(directory, upgrade: true, pairedAuthoring: true)
        case "paired-authoring-after-crash":
            _ = try NativePendingStorage.retaining(pairedAuthoringEntries()[0], directory: directory, expected: .empty); _exit(0)
        case "paired-authoring-loaded":
            let snapshot = try NativePendingStorage.load(directory: directory)
            try check(snapshot.document.version == .v8 && snapshot.document.revision == 1 && snapshot.document.entries == [pairedAuthoringEntries()[0]])
        case "check-paired-authoring-race":
            let snapshot = try NativePendingStorage.load(directory: directory)
            try check(snapshot.document.revision == 2 && snapshot.document.entries.count == 2 && snapshot.document.entries.contains(original))
            let paired = try pairedAuthoringEntries()[0]
            try check(snapshot.document.version == (snapshot.document.entries.contains(paired) ? .v8 : .v6))
        case "generation-upgrade-race": try race(directory, upgrade: true, generation: true)
        case "generation-authoring-race": try race(directory, upgrade: true, generation: true, generationAuthoring: true)
        case "seed-generation-race":
            try write(directory.appendingPathComponent("native-pending-v1.json").path, NativePendingDocument(revision: 1, entries: [original], version: .v6).encoded())
        case "generation-after-crash":
            _ = try NativePendingStorage.retaining(generationEntries()[0], directory: directory, expected: .empty)
            _exit(0)
        case "generation-loaded":
            let snapshot = try NativePendingStorage.load(directory: directory)
            try check(snapshot.document.version == .v7 && snapshot.document.revision == 1 && snapshot.document.entries == [generationEntries()[0]])
        case "check-generation-upgrade-race", "check-generation-authoring-race":
            let snapshot = try NativePendingStorage.load(directory: directory)
            try check(snapshot.document.revision == 2 && snapshot.document.entries.count == 2 && snapshot.document.entries.contains(original))
            let hasGeneration = snapshot.document.entries.contains { $0.category == .generation }
            try check(snapshot.document.version == (hasGeneration ? .v7 : .v6))
            if hasGeneration { try check(snapshot.document.entries.contains(generationEntries()[0])) }
            else if CommandLine.arguments[2] == "check-generation-authoring-race" { try check(snapshot.document.entries.contains(authoringImport())) }
            else { try check(snapshot.document.entries.contains { $0.input.operationID == "maintenance:race" }) }
        case "before-crash":
            try check(try NativePendingStorage.load(directory: directory) == .empty)
            _exit(0)
        case "after-crash":
            let snapshot = try NativePendingStorage.retaining(original, directory: directory, expected: .empty)
            try check(snapshot.document.revision == 1 && snapshot.document.entries == [original])
            _exit(0)
        case "loaded":
            let snapshot = try NativePendingStorage.load(directory: directory)
            try check(snapshot.document.revision == 1 && snapshot.document.entries == [original])
        case "resolve":
            let first = try NativePendingStorage.load(directory: directory)
            let result = try NativePendingStorage.resolving(original, directory: directory, expected: first)
            try check(result.document.revision == 2 && result.document.entries.isEmpty)
        case "loaded-empty":
            let snapshot = try NativePendingStorage.load(directory: directory)
            try check(snapshot.document.revision == 2 && snapshot.document.entries.isEmpty)
        case "race", "upgrade-race": try race(directory, upgrade: CommandLine.arguments[2] == "upgrade-race")
        case "rule-upgrade-race": try race(directory, upgrade: true, rules: true)
        case "schedule-upgrade-race": try race(directory, upgrade: true, schedules: true)
        case "authoring-upgrade-race": try race(directory, upgrade: true, authoring: true)
        case "seed-authoring-race":
            try write(directory.appendingPathComponent("native-pending-v1.json").path, NativePendingDocument(revision: 1, entries: [original], version: .v5).encoded())
        case "authoring-after-crash":
            _ = try NativePendingStorage.retaining(authoringImport(), directory: directory, expected: .empty)
            _exit(0)
        case "authoring-loaded":
            let snapshot = try NativePendingStorage.load(directory: directory)
            try check(snapshot.document.version == .v6 && snapshot.document.revision == 1 && snapshot.document.entries == [authoringImport()])
            try check(try snapshot.document.entries[0].authoringOperation().1 == Data(repeating: 255, count: 262_144))
        case "check-authoring-upgrade-race":
            let snapshot = try NativePendingStorage.load(directory: directory)
            try check(snapshot.document.revision == 2 && snapshot.document.entries.count == 2 && snapshot.document.entries.contains(original))
            let authoring = snapshot.document.entries.first { $0.category == .authoring }
            try check(snapshot.document.version == (authoring == nil ? .v5 : .v6))
            if let authoring { try check(try authoring.authoringOperation().1?.count == 262_144) }
        case "seed-schedule-race":
            try seedSchedules(directory)
        case "seed-rule-race":
            let first = try NativePendingStorage.retaining(original, directory: directory, expected: .empty)
            let access = NativePendingEntry(context: NativePendingContext(deployment: context.deployment, owner: context.owner, epoch: 7, principal: "native-setup-v1:7:operator"),
                custody: .native(role: .operator, creationRevision: 3, verifier: original.custody.verifier),
                input: .targetAccess(operation: "access:seed", revision: 9, target: "lamp:1", action: .revoke, basis: nil), phase: .pending)
            _ = try NativePendingStorage.retaining(access, directory: directory, expected: first)
        case "check-race":
            let snapshot = try NativePendingStorage.load(directory: directory)
            try check(snapshot.document.revision == 1 && snapshot.document.entries.count == 1)
            try check(["power:race0", "power:race1"].contains(snapshot.document.entries[0].input.operationID))
        case "check-upgrade-race":
            let snapshot = try NativePendingStorage.load(directory: directory)
            try check(snapshot.document.revision == 2 && snapshot.document.entries.count == 2 && snapshot.document.entries.contains(original))
            let winner = snapshot.document.entries.first { $0 != original }!
            try check(["access:race", "rule:race"].contains(winner.input.operationID))
            try check(snapshot.document.version == (winner.category == .access ? .v2 : .v1))
        case "check-rule-upgrade-race":
            let snapshot = try NativePendingStorage.load(directory: directory)
            try check(snapshot.document.revision == 3 && snapshot.document.entries.count == 3 && snapshot.document.entries.contains(original))
            try check(snapshot.document.entries.contains { $0.input.operationID == "access:seed" })
            let winner = snapshot.document.entries.first { $0.category == .rule }!
            if case .explicitRule = winner.input { try check(snapshot.document.version == .v3 && winner.input.operationID == "rule:new") }
            else { try check(snapshot.document.version == .v2 && winner.input.operationID == "rule:race") }
        case "check-schedule-upgrade-race":
            let snapshot = try NativePendingStorage.load(directory: directory)
            try check(snapshot.document.revision == 4 && snapshot.document.entries.count == 4 && snapshot.document.entries.contains(original))
            try check(snapshot.document.entries.contains { $0.input.operationID == "access:seed" })
            try check(snapshot.document.entries.contains { $0.input.operationID == "rule:seed" })
            if snapshot.document.entries.contains(schedule) { try check(snapshot.document.version == .v4) }
            else { try check(snapshot.document.version == .v3 && snapshot.document.entries.contains { $0.input.operationID == "maintenance:race" }) }
        default: throw StorageSmokeError.failed
        }
        print("native pending storage \(CommandLine.arguments[2]) passed")
    }

    private static func suite(_ directory: URL) throws {
        let file = directory.appendingPathComponent("native-pending-v1.json").path
        let lock = directory.appendingPathComponent("native-pending-v1.lock").path
        let unrelated = directory.appendingPathComponent("unrelated-setting").path
        try write(unrelated, Data("unchanged private fixture".utf8))
        try check(try NativePendingStorage.load(directory: directory) == .empty)
        try expected(.conflict) { _ = try NativePendingStorage.confirmingResolution(original, directory: directory, expected: .empty) }
        try check(!FileManager.default.fileExists(atPath: file) && !FileManager.default.fileExists(atPath: lock))
        let first = try NativePendingStorage.retaining(original, directory: directory, expected: .empty)
        try check(first.document.revision == 1 && first.document.entries == [original])
        try check(try NativePendingStorage.load(directory: directory) == first)
        try check(try NativePendingStorage.retaining(original, directory: directory, expected: first) == first)
        try privateFile(file); try privateFile(lock)
        let rule = NativePendingEntry(context: context, custody: original.custody, input: .suspend(operation: "rule:1", revision: 9), phase: .pending)
        try expected(.conflict) { _ = try NativePendingStorage.retaining(rule, directory: directory, expected: .empty) }
        let otherPrincipal = NativePendingEntry(context: NativePendingContext(deployment: context.deployment, owner: context.owner,
            epoch: context.epoch, principal: "operator:other"), custody: original.custody, input: .cancel(operation: "power:other"), phase: .pending)
        try expected(.conflict) { _ = try NativePendingStorage.retaining(otherPrincipal, directory: directory, expected: first) }
        let second = try NativePendingStorage.retaining(rule, directory: directory, expected: first)
        try check(second.document.revision == 2 && second.document.entries.count == 2)
        let third = try NativePendingStorage.resolving(original, directory: directory, expected: second)
        try check(third.document.revision == 3 && third.document.entries == [rule])
        try expected(.conflict) { _ = try NativePendingStorage.resolving(original, directory: directory, expected: third) }
        let empty = try NativePendingStorage.resolving(rule, directory: directory, expected: third)
        try check(empty.document.revision == 4 && empty.document.entries.isEmpty)
        try check(try NativePendingStorage.confirmingResolution(original, directory: directory, expected: empty) == empty)
        try expected(.conflict) { _ = try NativePendingStorage.confirmingResolution(original, directory: directory, expected: third) }
        let newer = try NativePendingStorage.retaining(otherPrincipal, directory: directory, expected: empty)
        try expected(.conflict) { _ = try NativePendingStorage.confirmingResolution(original, directory: directory, expected: newer) }
        try check(try NativePendingStorage.load(directory: directory) == newer)
        let restoredEmpty = try NativePendingStorage.resolving(otherPrincipal, directory: directory, expected: newer)
        try check(FileManager.default.fileExists(atPath: file))
        var profileFields: [String: Any] = ["action": "select", "authority_epoch": 7, "operation_id": "profile:1",
            "expected_revision": 9, "artifact_digest": String(repeating: "d", count: 64), "expected_trust_revision": 2,
            "target_id": "lamp:1", "expected_resource_revision": 4, "expected_binding_revision": 3,
            "expected_selection_generation": 2, "expected_policy_generation": 5, "expected_rule_generation": 6,
            "session_ref": "capture:1", "candidate_ref": "candidate:1", "review_ref": "enrollment:1"]
        let profile = NativePendingEntry(context: context, custody: original.custody,
            input: .profile(preparing: true, operation: try HomeProfileOperation(profileFields)), phase: .pending)
        profileFields["operation_id"] = "profile:modified"
        let retained = try NativePendingStorage.retaining(profile, directory: directory, expected: restoredEmpty)
        let phase = NativePendingPhase.review(token: "review:1", digest: String(repeating: "e", count: 64))
        let reviewed = try NativePendingStorage.changingPhase(of: profile, to: phase, directory: directory, expected: retained)
        let reviewEntry = try profile.changingPhase(phase)
        try check(reviewed.document.revision == 8 && reviewed.document.entries == [reviewEntry])
        try check(try NativePendingStorage.changingPhase(of: reviewEntry, to: phase, directory: directory, expected: reviewed) == reviewed)
        try expected(.conflict) {
            _ = try NativePendingStorage.changingPhase(of: reviewEntry, to: .commitPending(token: "review:other", digest: String(repeating: "e", count: 64)), directory: directory, expected: reviewed)
        }
        let commitPhase = NativePendingPhase.commitPending(token: "review:1", digest: String(repeating: "e", count: 64))
        let committing = try NativePendingStorage.changingPhase(of: reviewEntry, to: commitPhase, directory: directory, expected: reviewed)
        let commitEntry = try profile.changingPhase(commitPhase)
        try check(committing.document.revision == 9 && committing.document.entries == [commitEntry])
        try check(try NativePendingStorage.load(directory: directory) == committing)
        for phase in [NativePendingPhase.pending, phase, .cancelPending(token: "review:1", digest: String(repeating: "e", count: 64))] {
            try expected(.conflict) { _ = try NativePendingStorage.changingPhase(of: commitEntry, to: phase, directory: directory, expected: committing) }
        }
        try expected(.conflict) { _ = try NativePendingStorage.changingPhase(of: profile, to: phase, directory: directory, expected: committing) }
        let lockFD = open(lock, O_RDWR | O_CLOEXEC)
        try check(lockFD >= 0 && flock(lockFD, LOCK_EX | LOCK_NB) == 0)
        try expected(.capacity) { _ = try NativePendingStorage.resolving(commitEntry, directory: directory, expected: committing) }
        let network = try NativeNetworkPreferences.save(directory: directory, expected: .disabled, interface: "en0")
        try check(network.record.revision == 1 && network.record.interface == "en0")
        _ = flock(lockFD, LOCK_UN); _ = Darwin.close(lockFD)
        let replacement = directory.appendingPathComponent("replacement").path
        try write(replacement, committing.document.encoded())
        try check(rename(replacement, file) == 0)
        try expected(.conflict) { _ = try NativePendingStorage.resolving(commitEntry, directory: directory, expected: committing) }
        let current = try NativePendingStorage.load(directory: directory)
        let linked = directory.appendingPathComponent("linked").path
        try check(link(file, linked) == 0)
        try refused { _ = try NativePendingStorage.load(directory: directory) }
        try check(unlink(linked) == 0)
        try check(chmod(file, 0o644) == 0)
        try refused { _ = try NativePendingStorage.load(directory: directory) }
        try check(chmod(file, 0o600) == 0)
        try check(unlink(file) == 0 && symlink(lock, file) == 0)
        try refused { _ = try NativePendingStorage.load(directory: directory) }
        try check(try FileManager.default.destinationOfSymbolicLink(atPath: file) == lock)
        try check(unlink(file) == 0 && mkfifo(file, 0o600) == 0)
        try refused { _ = try NativePendingStorage.load(directory: directory) }
        try check(unlink(file) == 0)
        for bytes in [Data(), Data(repeating: 65, count: 65_537), Data("{}".utf8)] {
            try write(file, bytes)
            try refused { _ = try NativePendingStorage.load(directory: directory) }
        }
        try write(file, current.document.encoded())
        let latest = try NativePendingStorage.load(directory: directory)
        for kind in ["symlink", "fifo", "hardlink", "mode", "content"] {
            try check(unlink(lock) == 0)
            switch kind {
            case "symlink": try check(symlink("unknown", lock) == 0)
            case "fifo": try check(mkfifo(lock, 0o600) == 0)
            case "hardlink": try write(lock, Data()); try check(link(lock, linked) == 0)
            case "mode": try write(lock, Data()); try check(chmod(lock, 0o644) == 0)
            default: try write(lock, Data([1]))
            }
            try refused { _ = try NativePendingStorage.resolving(commitEntry, directory: directory, expected: latest) }
            if kind == "hardlink" { try check(unlink(linked) == 0) }
        }
        try check(unlink(lock) == 0)
        let alias = directory.path + ".alias"
        try check(symlink(directory.path, alias) == 0)
        defer { _ = unlink(alias) }
        try refused { _ = try NativePendingStorage.load(directory: URL(fileURLWithPath: alias)) }
        try check(chmod(directory.path, 0o755) == 0)
        try refused { _ = try NativePendingStorage.load(directory: directory) }
        try check(chmod(directory.path, 0o700) == 0)
        let exhaustedDocument = NativePendingDocument(revision: Int64.max, entries: [commitEntry])
        try write(file, exhaustedDocument.encoded())
        let exhausted = try NativePendingStorage.load(directory: directory)
        try expected(.invalidRecord) { _ = try NativePendingStorage.resolving(commitEntry, directory: directory, expected: exhausted) }
        let entries = (0..<16).map { index in
            NativePendingEntry(context: NativePendingContext(deployment: context.deployment, owner: String(format: "%064x", index),
                epoch: context.epoch, principal: context.principal), custody: original.custody, input: original.input, phase: .pending)
        }
        try write(file, NativePendingDocument(revision: 10, entries: NativePendingDocument.sorted(entries)).encoded())
        let full = try NativePendingStorage.load(directory: directory)
        try expected(.capacity) { _ = try NativePendingStorage.retaining(original, directory: directory, expected: full) }
        try check(try NativePendingStorage.load(directory: directory) == full)
        try check(try NativeNetworkPreferences.load(directory: directory) == network)
        try check(try Data(contentsOf: URL(fileURLWithPath: unrelated)) == Data("unchanged private fixture".utf8))
        try check(!FileManager.default.contentsOfDirectory(atPath: directory.path).contains(where: { $0.hasPrefix(".native-pending-") }))
        try check(Mirror(reflecting: latest).children.isEmpty)
    }

    private static func race(_ directory: URL, upgrade: Bool, rules: Bool = false, schedules: Bool = false, authoring: Bool = false,
                             generation: Bool = false, generationAuthoring: Bool = false, pairedAuthoring: Bool = false) throws {
        guard CommandLine.arguments.count == 4, ["0", "1"].contains(CommandLine.arguments[3]) else { throw StorageSmokeError.failed }
        let index = CommandLine.arguments[3]
        let expected = try NativePendingStorage.load(directory: directory)
        if schedules { try check(expected.document.revision == 3 && expected.document.entries.count == 3 && expected.document.version == .v3) }
        else if rules { try check(expected.document.revision == 2 && expected.document.entries.count == 2 && expected.document.version == .v2) }
        else { try check(upgrade ? expected.document.revision == 1 && expected.document.entries == [original] : expected == .empty) }
        try write(directory.appendingPathComponent("ready-" + index).path, Data())
        // The parent allows six seconds to publish go after both children
        // start. Keep the child's barrier bound beyond that entire interval.
        let deadline = DispatchTime.now().uptimeNanoseconds + 10_000_000_000
        while !FileManager.default.fileExists(atPath: directory.appendingPathComponent("go").path) {
            try check(DispatchTime.now().uptimeNanoseconds < deadline); usleep(10_000)
        }
        let entry: NativePendingEntry
        if pairedAuthoring {
            entry = index == "0" ? try pairedAuthoringEntries()[0] : NativePendingEntry(context: context, custody: original.custody,
                input: .beginMaintenance(operation: "maintenance:race", revision: 9), phase: .pending)
        } else if generation {
            if index == "0" { entry = try generationEntries()[0] }
            else if generationAuthoring { entry = try authoringImport() }
            else { entry = NativePendingEntry(context: context, custody: original.custody,
                input: .beginMaintenance(operation: "maintenance:race", revision: 9), phase: .pending) }
        } else if authoring {
            entry = index == "0" ? try authoringImport() : NativePendingEntry(context: context, custody: original.custody,
                input: .beginMaintenance(operation: "maintenance:race", revision: 9), phase: .pending)
        } else if schedules {
            entry = index == "0" ? schedule : NativePendingEntry(context: context, custody: original.custody,
                input: .beginMaintenance(operation: "maintenance:race", revision: 9), phase: .pending)
        } else if rules && index == "0" {
            entry = NativePendingEntry(context: context, custody: original.custody,
                input: .explicitRule(.review(epoch: 7, operation: "rule:new", expected: 9, rule: HomeExplicitPowerRule(id: "rule:one", sourceRevision: 2, target: "lamp:1", on: true))), phase: .pending)
        } else if upgrade && index == "0" {
            entry = NativePendingEntry(context: NativePendingContext(deployment: context.deployment, owner: context.owner, epoch: 7,
                principal: "native-setup-v1:7:operator"), custody: .native(role: .operator, creationRevision: 3, verifier: original.custody.verifier),
                input: .targetAccess(operation: "access:race", revision: 9, target: "lamp:1", action: .revoke, basis: nil), phase: .pending)
        } else if upgrade {
            entry = NativePendingEntry(context: context, custody: original.custody, input: .suspend(operation: "rule:race", revision: 9), phase: .pending)
        } else {
            entry = NativePendingEntry(context: context, custody: original.custody,
                input: .power(operation: "power:race" + index, target: "lamp:" + index, revision: 9, on: index == "0"), phase: .pending)
        }
        do {
            _ = try NativePendingStorage.retaining(entry, directory: directory, expected: expected)
            print("race_committed")
        } catch NativePendingError.conflict { print("race_refused") }
        catch NativePendingError.capacity { print("race_refused") }
    }
    private static func versionedAccess(_ directory: URL) throws {
        let before = try NativePendingStorage.retaining(original, directory: directory, expected: .empty)
        let beforeBytes = try Data(contentsOf: directory.appendingPathComponent("native-pending-v1.json"))
        try check(before.document.version == .v1 && NativePendingStorage.load(directory: directory) == before)
        try check(try Data(contentsOf: directory.appendingPathComponent("native-pending-v1.json")) == beforeBytes)
        let nativeContext = NativePendingContext(deployment: context.deployment, owner: context.owner, epoch: 7, principal: "native-setup-v1:7:operator")
        let access = NativePendingEntry(context: nativeContext,
            custody: .native(role: .operator, creationRevision: 3, verifier: original.custody.verifier),
            input: .targetAccess(operation: "access:original", revision: 9, target: "lamp:1", action: .grant,
                basis: NativeTargetBasis(resource: 4, binding: 5, generation: 2, artifact: String(repeating: "d", count: 64))), phase: .pending)
        let upgraded = try NativePendingStorage.retaining(access, directory: directory, expected: before)
        try check(upgraded.document.version == .v2 && upgraded.document.revision == 2 &&
            Set(upgraded.document.entries.map(\.input.operationID)) == Set(["power:original", "access:original"]))
        try check(upgraded.document.entries.contains(original) && upgraded.document.entries.contains(access))
        try check(try NativePendingStorage.load(directory: directory) == upgraded)
        try check(try NativePendingStorage.retaining(access, directory: directory, expected: upgraded) == upgraded)
        try expected(.conflict) { _ = try NativePendingStorage.resolving(original, directory: directory, expected: before) }
        try check(try NativePendingStorage.load(directory: directory) == upgraded)
        let remaining = try NativePendingStorage.resolving(access, directory: directory, expected: upgraded)
        try check(remaining.document.version == .v2 && remaining.document.revision == 3 && remaining.document.entries == [original])
        let empty = try NativePendingStorage.resolving(original, directory: directory, expected: remaining)
        try check(empty.document.version == .v2 && empty.document.revision == 4 && empty.document.entries.isEmpty)
        try check(try NativePendingStorage.confirmingResolution(access, directory: directory, expected: empty) == empty)
        let ordinary = try NativePendingStorage.retaining(original, directory: directory, expected: empty)
        try check(ordinary.document.version == .v2 && ordinary.document.revision == 5 && ordinary.document.entries == [original])
        try check(try NativePendingStorage.load(directory: directory) == ordinary)
        try expected(.invalidRecord) {
            _ = try NativePendingStorage.changingPhase(of: access, to: .review(token: "review:one", digest: String(repeating: "e", count: 64)),
                directory: directory, expected: upgraded)
        }
    }
    private static func versionedRules(_ directory: URL) throws {
        let first = try NativePendingStorage.retaining(original, directory: directory, expected: .empty)
        let access = NativePendingEntry(context: NativePendingContext(deployment: context.deployment, owner: context.owner, epoch: 7, principal: "native-setup-v1:7:operator"),
            custody: .native(role: .operator, creationRevision: 3, verifier: original.custody.verifier),
            input: .targetAccess(operation: "access:original", revision: 9, target: "lamp:1", action: .revoke, basis: nil), phase: .pending)
        let second = try NativePendingStorage.retaining(access, directory: directory, expected: first)
        let rule = NativePendingEntry(context: context, custody: original.custody,
            input: .explicitRule(.admit(epoch: 7, operation: "rule:original", expected: 9, rule: HomeExplicitPowerRule(id: "rule:one", sourceRevision: 2, target: "lamp:1", on: true))), phase: .pending)
        let third = try NativePendingStorage.retaining(rule, directory: directory, expected: second)
        try check(third.document.version == .v3 && third.document.revision == 3 && Set(third.document.entries.map(\.input.operationID)) == Set(["power:original", "access:original", "rule:original"]))
        try check(try NativePendingStorage.load(directory: directory) == third && NativePendingStorage.retaining(rule, directory: directory, expected: third) == third)
        try expected(.conflict) { _ = try NativePendingStorage.resolving(original, directory: directory, expected: second) }
        let oldRule = NativePendingEntry(context: context, custody: original.custody, input: .suspend(operation: "rule:old", revision: 9), phase: .pending)
        try expected(.conflict) { _ = try NativePendingStorage.retaining(oldRule, directory: directory, expected: third) }
        let fourth = try NativePendingStorage.resolving(rule, directory: directory, expected: third)
        let fifth = try NativePendingStorage.resolving(access, directory: directory, expected: fourth)
        let sixth = try NativePendingStorage.resolving(original, directory: directory, expected: fifth)
        try check(sixth.document.version == .v3 && sixth.document.revision == 6 && sixth.document.entries.isEmpty)
        try check(try NativePendingStorage.confirmingResolution(rule, directory: directory, expected: sixth) == sixth)
        let seventh = try NativePendingStorage.retaining(original, directory: directory, expected: sixth)
        try check(seventh.document.version == .v3 && seventh.document.revision == 7 && seventh.document.entries == [original])
        try check(try NativePendingStorage.load(directory: directory) == seventh)
    }
    private static var schedule: NativePendingEntry {
        let source = HomeScheduleSource(id: "schedule:one", sourceRevision: 2, author: context.principal,
            rule: HomeExplicitPowerRule(id: "rule:one", sourceRevision: 2, target: "lamp:1", on: true),
            resourceRevision: 4, lateWindow: 10_000, tolerance: 100,
            trigger: .interval(anchor: 100_000, period: 60_000, start: 100_000, end: nil))
        return NativePendingEntry(context: context, custody: original.custody,
            input: .schedule(.admit(epoch: 7, operation: "schedule:original", expected: 9, source: source)), phase: .pending)
    }
    private static func seedSchedules(_ directory: URL) throws {
        let first = try NativePendingStorage.retaining(original, directory: directory, expected: .empty)
        let access = NativePendingEntry(context: NativePendingContext(deployment: context.deployment, owner: context.owner, epoch: 7, principal: "native-setup-v1:7:operator"),
            custody: .native(role: .operator, creationRevision: 3, verifier: original.custody.verifier),
            input: .targetAccess(operation: "access:seed", revision: 9, target: "lamp:1", action: .revoke, basis: nil), phase: .pending)
        let second = try NativePendingStorage.retaining(access, directory: directory, expected: first)
        let rule = NativePendingEntry(context: context, custody: original.custody,
            input: .explicitRule(.review(epoch: 7, operation: "rule:seed", expected: 9,
                rule: HomeExplicitPowerRule(id: "rule:one", sourceRevision: 2, target: "lamp:1", on: true))), phase: .pending)
        _ = try NativePendingStorage.retaining(rule, directory: directory, expected: second)
    }
    private static func versionedSchedules(_ directory: URL) throws {
        try seedSchedules(directory)
        let third = try NativePendingStorage.load(directory: directory)
        let path = directory.appendingPathComponent("native-pending-v1.json")
        let beforeBytes = try Data(contentsOf: path)
        try check(third.document.version == .v3 && third.document.revision == 3)
        try check(try NativePendingStorage.load(directory: directory) == third && Data(contentsOf: path) == beforeBytes)
        let fourth = try NativePendingStorage.retaining(schedule, directory: directory, expected: third)
        try check(fourth.document.version == .v4 && fourth.document.revision == 4 && fourth.document.entries.count == 4)
        try check(third.document.entries.allSatisfy { fourth.document.entries.contains($0) })
        let upgradedBytes = try Data(contentsOf: path)
        try check(try NativePendingStorage.retaining(schedule, directory: directory, expected: fourth) == fourth && Data(contentsOf: path) == upgradedBytes)
        try expected(.conflict) { _ = try NativePendingStorage.resolving(original, directory: directory, expected: third) }
        let changed = NativePendingEntry(context: context, custody: original.custody,
            input: .schedule(.suspend(epoch: 7, operation: "schedule:other", expected: 9)), phase: .pending)
        try expected(.conflict) { _ = try NativePendingStorage.retaining(changed, directory: directory, expected: fourth) }
        try check(try Data(contentsOf: path) == upgradedBytes)
        var snapshot = fourth
        for entry in fourth.document.entries { snapshot = try NativePendingStorage.resolving(entry, directory: directory, expected: snapshot) }
        try check(snapshot.document.version == .v4 && snapshot.document.revision == 8 && snapshot.document.entries.isEmpty)
        try check(try NativePendingStorage.confirmingResolution(schedule, directory: directory, expected: snapshot) == snapshot)
        let ordinary = try NativePendingStorage.retaining(original, directory: directory, expected: snapshot)
        try check(ordinary.document.version == .v4 && ordinary.document.revision == 9 && ordinary.document.entries == [original])
        try check(try NativePendingStorage.load(directory: directory) == ordinary)
    }
    private static func write(_ path: String, _ bytes: Data) throws {
        try bytes.write(to: URL(fileURLWithPath: path)); try check(chmod(path, 0o600) == 0)
    }

    private static func authoringImport() throws -> NativePendingEntry {
        let payload = Data(repeating: 255, count: 262_144), raw = LocalHealthClient.profileSHA(Data(repeating: 255, count: 262_144))
        var frame = Data([87, 79, 72, 65, 1, 1, 0, 4, 0, 0])
        for n in stride(from: 0, to: 64, by: 2) {
            let start = raw.index(raw.startIndex, offsetBy: n), end = raw.index(start, offsetBy: 2)
            frame.append(UInt8(raw[start..<end], radix: 16)!)
        }
        frame.append(payload)
        let fields: [String: Any] = ["authority_epoch": 7, "operation_id": "import:pending", "expected_revision": 9,
            "object": ["kind": "source", "payload_bytes": payload.count, "payload_sha256": raw, "object_digest": LocalHealthClient.profileSHA(frame)]]
        let input = try NativeAuthoringOriginalWire.encode(fields, kind: .import)
        return NativePendingEntry(context: context, custody: original.custody, input: .authoring(input, payload), phase: .pending)
    }
    private static func versionedAuthoring(_ directory: URL) throws {
        let file = directory.appendingPathComponent("native-pending-v1.json")
        let importEntry = try authoringImport()
        for version in [NativePendingVersion.v1, .v2, .v3, .v4, .v5] {
            let bytes = try NativePendingDocument(revision: 1, entries: [original], version: version).encoded()
            try write(file.path, bytes)
            let before = try NativePendingStorage.load(directory: directory)
            try check(before.document.version == version && Data(contentsOf: file) == bytes)
            let after = try NativePendingStorage.retaining(importEntry, directory: directory, expected: before)
            try check(after.document.version == .v6 && after.document.revision == 2 && after.document.entries.contains(original))
            let published = try Data(contentsOf: file)
            try check(published.count > 65_536 && NativePendingDocument.decode(published) == after.document)
            try check(try importEntry.authoringOperation().1 == Data(repeating: 255, count: 262_144))
            try check(try NativePendingStorage.retaining(importEntry, directory: directory, expected: after) == after && Data(contentsOf: file) == published)
            try expected(.conflict) { _ = try NativePendingStorage.resolving(original, directory: directory, expected: before) }
            let empty = try NativePendingStorage.resolving(original, directory: directory,
                expected: NativePendingStorage.resolving(importEntry, directory: directory, expected: after))
            try check(empty.document.version == .v6 && empty.document.entries.isEmpty)
            let later = try NativePendingStorage.retaining(original, directory: directory, expected: empty)
            try check(later.document.version == .v6)
            let older = Data(String(decoding: published, as: UTF8.self).replacingOccurrences(of: "wotex-home.native-pending.v6", with: version.rawValue).utf8)
            try refused { _ = try NativePendingDocument.decode(older) }
        }
        for (kind, name) in [(HomeAuthoringOriginalKind.candidate, "authoring-candidate"), (.review, "authoring-review")] {
            let vector = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "test/fixtures/profiles/" + name + ".json"))) as! [String: Any]
            let value = try NativeAuthoringOriginalWire.nativeJSON(JSONSerialization.data(withJSONObject: vector["input"]!), kind: kind)
            let scoped = NativePendingContext(deployment: context.deployment, owner: context.owner, epoch: value.epoch, principal: context.principal)
            let entry = NativePendingEntry(context: scoped, custody: original.custody, input: .authoring(value, nil), phase: .pending)
            let doc = NativePendingDocument(revision: 1, entries: [entry])
            try check(doc.version == .v6 && NativePendingDocument.decode(doc.encoded()) == doc)
            try refused { _ = try NativePendingDocument(revision: 1, entries: [NativePendingEntry(context: scoped, custody: original.custody, input: .authoring(value, Data([1])), phase: .pending)]).encoded() }
            if kind == .review {
                var fields = try value.fields(), review = fields["review"] as! [String: Any]
                review["evidence"] = (0..<256).map { n in ["instance_path": "/profile/binding", "source_ref": String(repeating: "a", count: 64), "locator": "α" + String(format: "%03d", n) + String(repeating: "x", count: 240)] }
                fields["review"] = review
                let large = try NativeAuthoringOriginalWire.encode(fields, kind: .review)
                try check(large.canonical.count > 65_536)
                let retained = NativePendingEntry(context: scoped, custody: original.custody, input: .authoring(large, nil), phase: .pending)
                let document = NativePendingDocument(revision: 1, entries: [retained])
                try check(try NativePendingDocument.decode(document.encoded()) == document)
            }
        }
        try refused { _ = try NativePendingDocument(revision: 1, entries: [NativePendingEntry(context: context, custody: original.custody, input: importEntry.input, phase: .review(token: "review:one", digest: String(repeating: "d", count: 64)))]).encoded() }
        if case .authoring(let value, _) = importEntry.input {
            for payload in [Data(), Data([255]), Data(repeating: 0, count: 262_144)] {
                try refused { _ = try NativePendingDocument(revision: 1, entries: [NativePendingEntry(context: context, custody: original.custody, input: .authoring(value, payload), phase: .pending)]).encoded() }
            }
            let wrongContext = NativePendingContext(deployment: context.deployment, owner: context.owner, epoch: 8, principal: context.principal)
            try refused { _ = try NativePendingDocument(revision: 1, entries: [NativePendingEntry(context: wrongContext, custody: original.custody, input: importEntry.input, phase: .pending)]).encoded() }
            for (role, creation) in [(NativeCustodyRole.operator, Int64(10)), (.diagnostic, Int64(1))] {
                let native = NativePendingContext(deployment: context.deployment, owner: context.owner, epoch: 7, principal: NativeCoreWire.principal(7, role))
                try refused { _ = try NativePendingDocument(revision: 1, entries: [NativePendingEntry(context: native, custody: .native(role: role, creationRevision: creation, verifier: String(repeating: "c", count: 64)), input: importEntry.input, phase: .pending)]).encoded() }
            }
            let native = NativePendingContext(deployment: context.deployment, owner: context.owner, epoch: 7, principal: NativeCoreWire.principal(7, .operator))
            _ = try NativePendingDocument(revision: 1, entries: [NativePendingEntry(context: native, custody: .native(role: .operator, creationRevision: 3, verifier: String(repeating: "c", count: 64)), input: importEntry.input, phase: .pending)]).encoded()
            let paired = NativePendingContext(deployment: context.deployment, owner: context.owner, epoch: 7, principal: "paired-controller-v1:7:" + String(repeating: "d", count: 64))
            try refused { _ = try NativePendingDocument(revision: 1, entries: [NativePendingEntry(context: paired, custody: .paired(association: String(repeating: "e", count: 64), controller: String(repeating: "f", count: 64), creationRevision: 3, verifier: String(repeating: "c", count: 64)), input: importEntry.input, phase: .pending)], version: .v6).encoded() }
        }
        let entries = (0..<16).map { n in NativePendingEntry(context: NativePendingContext(deployment: context.deployment, owner: String(format: "%064x", n), epoch: 7, principal: context.principal), custody: original.custody, input: importEntry.input, phase: .pending) }
        let full = NativePendingDocument(revision: 1, entries: NativePendingDocument.sorted(entries))
        let fullBytes = try full.encoded()
        try check(fullBytes.count > 5_000_000 && fullBytes.count < 8_388_608 && NativePendingDocument.decode(fullBytes) == full)
        try write(file.path, fullBytes)
        let snapshot = try NativePendingStorage.load(directory: directory)
        try expected(.capacity) { _ = try NativePendingStorage.retaining(importEntry, directory: directory, expected: snapshot) }
        try check(try Data(contentsOf: file) == fullBytes)
        try check(Mirror(reflecting: importEntry.input).children.isEmpty && NativePendingRecoveryAction.lookup.permits(importEntry) && NativePendingRecoveryAction.retry.permits(importEntry) && !NativePendingRecoveryAction.cancelReview.permits(importEntry))
    }
    private static func generationVectors() throws -> [[String: Any]] {
        let data = try Data(contentsOf: URL(fileURLWithPath: "test/fixtures/profiles/native-pending-generation.json"))
        return (try JSONSerialization.jsonObject(with: data) as! [String: Any])["cases"] as! [[String: Any]]
    }
    private static func pairedAuthoringEntries() throws -> [NativePendingEntry] {
        let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "test/fixtures/profiles/native-pending-paired-authoring.json"))) as! [String: Any]
        var entries: [NativePendingEntry] = []
        for vector in fixture["cases"] as! [[String: Any]] {
            let bytes = Data((vector["document"] as! String).utf8)
            try check(LocalHealthClient.profileSHA(bytes) == vector["sha256"] as! String)
            let document = try NativePendingDocument.decode(bytes)
            try check(document.version == .v8 && document.encoded() == bytes)
            if document.entries.count == 1 {
                let entry = document.entries[0]
                try check(entry.custody.isPaired && Mirror(reflecting: entry).children.isEmpty)
                var generationAttempt = false
                if case .generation(let original) = entry.input { generationAttempt = original.kind == .attempt }
                for action in [NativePendingRecoveryAction.lookup, .retry, .cancelReview, .acknowledgeUnknown, .acknowledgeAbsent] {
                    let expected = action == .lookup || action == .retry || action == .acknowledgeAbsent ||
                        (action == .acknowledgeUnknown && generationAttempt)
                    try check(action.permits(entry) == expected)
                }
                if entry.category == .authoring { _ = try entry.authoringOperation() }
                else { _ = try entry.generationOperation() }
                entries.append(entry)
            }
        }
        for vector in fixture["invalid"] as! [[String: Any]] {
            try refused { _ = try NativePendingDocument.decode(Data((vector["document"] as! String).utf8)) }
        }
        return entries
    }
    private static func pairedAuthoringSuite(_ directory: URL) throws {
        let entries = try pairedAuthoringEntries(), file = directory.appendingPathComponent("native-pending-v1.json")
        for version in [NativePendingVersion.v1, .v2, .v3, .v4, .v5, .v6, .v7] {
            try write(file.path, NativePendingDocument(revision: 1, entries: [original], version: version).encoded())
            let before = try NativePendingStorage.load(directory: directory)
            let after = try NativePendingStorage.retaining(entries[0], directory: directory, expected: before)
            try check(after.document.version == .v8 && after.document.revision == 2 && after.document.entries.contains(original))
            try check(try NativePendingStorage.retaining(entries[0], directory: directory, expected: after) == after)
            try expected(.conflict) { _ = try NativePendingStorage.resolving(entries[0], directory: directory, expected: before) }
            let removed = try NativePendingStorage.resolving(entries[0], directory: directory, expected: after)
            let empty = try NativePendingStorage.resolving(original, directory: directory, expected: removed)
            try check(empty.document.version == .v8 && empty.document.entries.isEmpty)
            let local = try NativePendingStorage.retaining(original, directory: directory, expected: empty)
            try check(local.document.version == .v8)
        }
        let retained = try NativePendingStorage.load(directory: directory)
        let content = try Data(contentsOf: file)
        let replacement = directory.appendingPathComponent("inode-replacement")
        try write(replacement.path, content); try check(rename(replacement.path, file.path) == 0)
        try expected(.conflict) { _ = try NativePendingStorage.retaining(entries[0], directory: directory, expected: retained) }
        try check(try Data(contentsOf: file) == content)
    }
    private static func generationEntries() throws -> [NativePendingEntry] {
        try generationVectors().map {
            let bytes = Data(($0["pending_document"] as! String).utf8)
            try check(LocalHealthClient.profileSHA(bytes) == $0["pending_sha256"] as! String)
            let document = try NativePendingDocument.decode(bytes)
            try check(document.version == .v7 && document.revision == 1 && document.entries.count == 1)
            let entry = document.entries[0], value = try entry.generationOperation()
            try check(value.kind.rawValue == $0["kind"] as! String && value.canonical == Data(($0["document"] as! String).utf8))
            try check(try NativePendingDocument(revision: 1, entries: [entry]).encoded() == bytes)
            try check(Mirror(reflecting: entry).children.isEmpty && Mirror(reflecting: entry.input).children.isEmpty)
            try check(NativePendingRecoveryAction.lookup.permits(entry) && NativePendingRecoveryAction.retry.permits(entry) && !NativePendingRecoveryAction.cancelReview.permits(entry))
            try check(NativePendingRecoveryAction.acknowledgeUnknown.permits(entry) == (value.kind == .attempt))
            try check(NativePendingRecoveryAction.acknowledgeAbsent.permits(entry))
            return entry
        }
    }
    private static func versionedGeneration(_ directory: URL) throws {
        let file = directory.appendingPathComponent("native-pending-v1.json")
        let generation = try generationEntries(), entry = generation[0], value = try entry.generationOperation()
        let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "test/fixtures/profiles/native-pending-generation.json"))) as! [String: Any]
        let independent = fixture["mixed"] as! [String: Any], independentBytes = Data((independent["document"] as! String).utf8)
        try check(LocalHealthClient.profileSHA(independentBytes) == independent["sha256"] as! String)
        let independentDocument = try NativePendingDocument.decode(independentBytes)
        try check(independentDocument.entries.count == independent["entries"] as! Int && independentDocument.revision == 13)
        try check(try independentDocument.encoded() == independentBytes)
        try write(file.path, independentBytes)
        let independentSnapshot = try NativePendingStorage.load(directory: directory)
        try check(independentSnapshot.document == independentDocument && Data(contentsOf: file) == independentBytes)
        for version in [NativePendingVersion.v1, .v2, .v3, .v4, .v5, .v6] {
            let bytes = try NativePendingDocument(revision: 1, entries: [original], version: version).encoded()
            try write(file.path, bytes)
            let before = try NativePendingStorage.load(directory: directory)
            try check(before.document.version == version && Data(contentsOf: file) == bytes)
            try check(try NativePendingStorage.retaining(original, directory: directory, expected: before) == before && Data(contentsOf: file) == bytes)
            let after = try NativePendingStorage.retaining(entry, directory: directory, expected: before)
            try check(after.document.version == .v7 && after.document.revision == 2 && after.document.entries.contains(original))
            let published = try Data(contentsOf: file)
            try check(try NativePendingStorage.load(directory: directory) == after && Data(contentsOf: file) == published)
            try check(try NativePendingStorage.retaining(entry, directory: directory, expected: after) == after && Data(contentsOf: file) == published)
            try expected(.conflict) { _ = try NativePendingStorage.resolving(original, directory: directory, expected: before) }
            try refused { _ = try NativePendingDocument(revision: 1, entries: [entry], version: version).encoded() }
            let older = Data(String(decoding: published, as: UTF8.self).replacingOccurrences(of: NativePendingVersion.v7.rawValue, with: version.rawValue).utf8)
            try refused { _ = try NativePendingDocument.decode(older) }
            let empty = try NativePendingStorage.resolving(original, directory: directory,
                expected: NativePendingStorage.resolving(entry, directory: directory, expected: after))
            try check(empty.document.version == .v7 && empty.document.entries.isEmpty)
            let later = try NativePendingStorage.retaining(original, directory: directory, expected: empty)
            try check(later.document.version == .v7 && NativePendingStorage.load(directory: directory) == later)
        }
        for candidate in generation {
            let input = try candidate.generationOperation()
            let native = NativePendingContext(deployment: context.deployment, owner: context.owner, epoch: input.epoch,
                principal: NativeCoreWire.principal(input.epoch, .operator))
            let retained = NativePendingEntry(context: native, custody: .native(role: .operator, creationRevision: 3, verifier: original.custody.verifier),
                input: candidate.input, phase: .pending)
            try check(try NativePendingDocument.decode(NativePendingDocument(revision: 1, entries: [retained]).encoded()).entries == [retained])
            let badContext = NativePendingContext(deployment: native.deployment, owner: native.owner, epoch: input.epoch == 1 ? 2 : 1, principal: "operator:fixture")
            try refused { _ = try NativePendingDocument(revision: 1, entries: [NativePendingEntry(context: badContext, custody: original.custody, input: candidate.input, phase: .pending)]).encoded() }
        }
        let diagnostic = NativePendingContext(deployment: context.deployment, owner: context.owner, epoch: value.epoch,
            principal: NativeCoreWire.principal(value.epoch, .diagnostic))
        try refused { _ = try NativePendingDocument(revision: 1, entries: [NativePendingEntry(context: diagnostic,
            custody: .native(role: .diagnostic, creationRevision: 1, verifier: original.custody.verifier), input: entry.input, phase: .pending)], version: .v7).encoded() }
        let native = NativePendingContext(deployment: context.deployment, owner: context.owner, epoch: value.epoch,
            principal: NativeCoreWire.principal(value.epoch, .operator))
        try refused { _ = try NativePendingDocument(revision: 1, entries: [NativePendingEntry(context: native,
            custody: .native(role: .operator, creationRevision: value.expectedRevision + 1, verifier: original.custody.verifier), input: entry.input, phase: .pending)], version: .v7).encoded() }
        let paired = NativePendingContext(deployment: context.deployment, owner: context.owner, epoch: value.epoch,
            principal: "paired-controller-v1:\(value.epoch):" + String(repeating: "d", count: 64))
        try refused { _ = try NativePendingDocument(revision: 1, entries: [NativePendingEntry(context: paired,
            custody: .paired(association: String(repeating: "e", count: 64), controller: String(repeating: "f", count: 64), creationRevision: 1,
                verifier: original.custody.verifier), input: entry.input, phase: .pending)], version: .v7).encoded() }
        for phase in [NativePendingPhase.review(token: "review:one", digest: String(repeating: "d", count: 64)),
                      .commitPending(token: "review:one", digest: String(repeating: "d", count: 64)),
                      .cancelPending(token: "review:one", digest: String(repeating: "d", count: 64))] {
            try refused { _ = try entry.changingPhase(phase) }
        }
        let importEntry = try authoringImport()
        let mixed = NativePendingDocument(revision: 1, entries: NativePendingDocument.sorted([entry, original, schedule, importEntry]))
        try check(try NativePendingDocument.decode(mixed.encoded()) == mixed)
        // The marker-specific allowance must not bleed from generation to an
        // ordinary entry, or permit action/kind/document substitutes.
        for marker in ["authoring_operation", "schedule_operation", "submit", "unsupported"] {
            let bytes = Data(String(decoding: try mixed.encoded(), as: UTF8.self).replacingOccurrences(of: "generation_operation", with: marker).utf8)
            try refused { _ = try NativePendingDocument.decode(bytes) }
        }
        let oversizedOrdinary = Data(String(decoding: independentBytes, as: UTF8.self).replacingOccurrences(of: "power:original", with: String(repeating: "x", count: 129)).utf8)
        try refused { _ = try NativePendingDocument.decode(oversizedOrdinary) }
        let unknownVersion = Data(String(decoding: independentBytes, as: UTF8.self).replacingOccurrences(of: NativePendingVersion.v7.rawValue, with: "wotex-home.native-pending.v9").utf8)
        try refused { _ = try NativePendingDocument.decode(unknownVersion) }
        try refused { _ = try NativePendingDocument.decode(Data(repeating: 65, count: 8_388_609)) }
        let root = try JSONSerialization.jsonObject(with: entryDocument(entry)) as! [Any]
        for replacement in [String(repeating: "x", count: 32_769), String(repeating: "α", count: 16_385), "\u{0}", "\u{FFFD}", "[]"] {
            var changed = root, entries = root[2] as! [[Any]], input = entries[0][3] as! [Any]
            input[2] = replacement; entries[0][3] = input; changed[2] = entries
            let bytes = try JSONSerialization.data(withJSONObject: changed, options: [.withoutEscapingSlashes])
            try refused { _ = try NativePendingDocument.decode(bytes) }
        }
        let fullEntries = (0..<16).map { n in NativePendingEntry(context: NativePendingContext(deployment: context.deployment,
            owner: String(format: "%064x", n), epoch: entry.context.epoch, principal: entry.context.principal), custody: entry.custody, input: entry.input, phase: .pending) }
        let full = NativePendingDocument(revision: 1, entries: NativePendingDocument.sorted(fullEntries))
        try write(file.path, full.encoded())
        let snapshot = try NativePendingStorage.load(directory: directory), fullBytes = try Data(contentsOf: file)
        try expected(.capacity) { _ = try NativePendingStorage.retaining(entry, directory: directory, expected: snapshot) }
        try check(try Data(contentsOf: file) == fullBytes)
        try refused { _ = try NativePendingDocument(revision: 1, entries: NativePendingDocument.sorted(fullEntries + [entry])).encoded() }
        try write(file.path, entryDocument(entry))
        let first = try NativePendingStorage.load(directory: directory)
        var fields = try value.fields(); fields["operation_id"] = "generation:newer"
        let newer = NativePendingEntry(context: entry.context, custody: entry.custody,
            input: .generation(try NativeGenerationOriginalWire.encode(fields, kind: value.kind)), phase: .pending)
        try expected(.conflict) { _ = try NativePendingStorage.retaining(newer, directory: directory, expected: first) }
        let empty = try NativePendingStorage.resolving(entry, directory: directory, expected: first)
        let later = try NativePendingStorage.retaining(newer, directory: directory, expected: empty)
        try expected(.conflict) { _ = try NativePendingStorage.confirmingResolution(entry, directory: directory, expected: later) }
        try expected(.conflict) { _ = try NativePendingStorage.resolving(entry, directory: directory, expected: first) }
        try check(try NativePendingStorage.load(directory: directory) == later)
        try privateFile(file.path)
    }
    private static func entryDocument(_ entry: NativePendingEntry) throws -> Data {
        try NativePendingDocument(revision: 1, entries: [entry]).encoded()
    }
    private static func privateFile(_ path: String) throws {
        var info = stat()
        try check(lstat(path, &info) == 0 && info.st_uid == getuid() && info.st_nlink == 1 &&
            info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) && info.st_mode & 0o777 == 0o600)
    }
    private static func check(_ value: Bool, line: UInt = #line) throws {
        if !value { FileHandle.standardError.write(Data("native pending storage check failed at line \(line)\n".utf8)); throw StorageSmokeError.failed }
    }
    private static func expected(_ expected: NativePendingError, _ body: () throws -> Void) throws {
        do { try body() }
        catch let error as NativePendingError where error == expected { return }
        throw StorageSmokeError.failed
    }
    private static func refused(_ body: () throws -> Void) throws {
        do { try body() } catch is NativePendingError { return }
        throw StorageSmokeError.failed
    }
}
