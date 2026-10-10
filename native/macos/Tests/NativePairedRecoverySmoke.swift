import Darwin
import Foundation

private enum PairedRecoverySmokeError: Error { case failed(Int) }
private final class RecoveryClockProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func clock() throws -> NativeControllerCertificateClock {
        lock.lock(); count += 1; lock.unlock()
        throw NativeControllerTLSError.tlsClockUncertain
    }
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
}

@main
struct NativePairedRecoverySmoke {
    static func main() async {
        do {
            let args = CommandLine.arguments
            if args.count == 1 { try await transport(); return }
            guard args.count == 4 || args.count == 5 else { throw PairedRecoverySmokeError.failed(#line) }
            let associations = try dictionary(args[1]), originals = try dictionary(args[2])
            let root = URL(fileURLWithPath: args[3], isDirectory: true)
            if args.count == 5 {
                try require(args[4] == "inspect")
                let snapshot = try NativePendingStorage.load(directory: root)
                try NativePendingStorage.check(snapshot, directory: root)
                try require(snapshot.document.version == .v5 && snapshot.document.entries.count == 1)
                print("fresh original paired journal check passed"); return
            }
            try await metadata(associations: associations, originals: originals, root: root)
            print("native original paired correspondence, cancellation, private CAS and unsigned production refusal passed")
        } catch PairedRecoverySmokeError.failed(let line) {
            FileHandle.standardError.write(Data("native original paired assertion failed at source line \(line)\n".utf8)); exit(1)
        } catch {
            FileHandle.standardError.write(Data("native original paired fixture failed\n".utf8)); exit(1)
        }
    }

    private static func metadata(associations: [String: Any], originals: [String: Any], root: URL) async throws {
        guard let records = associations["valid_records"] as? [[String: Any]], records.count == 9,
              let firstBody = records[0]["body"] as? String, let otherBody = records[4]["body"] as? String,
              let rows = originals["valid"] as? [[String: Any]], let body = rows[0]["body"] as? String,
              let entry = try NativePendingDocument.decode(Data(body.utf8)).entries.first else { throw PairedRecoverySmokeError.failed(#line) }
        let original = try NativeControllerPublicAssociation.decode(Data(firstBody.utf8))
        let other = try NativeControllerPublicAssociation.decode(Data(otherBody.utf8))
        let missing = root.appendingPathComponent("absent", isDirectory: true)
        try refused { try NativePendingStorage.check(.empty, directory: missing) }
        try require(!FileManager.default.fileExists(atPath: missing.path))
        let directory = root.appendingPathComponent("metadata", isDirectory: true)
        try makeDirectory(directory)
        let pending = try NativePendingStorage.retaining(entry, directory: directory, expected: .empty)
        let first = try NativeControllerAssociationStorage.retaining(original, directory: directory, expected: .empty)
        let retained = try NativeControllerAssociationStorage.retaining(other, directory: directory, expected: first)
        for (selection, action) in [(NativeControllerSelection.local, NativePendingRecoveryAction.lookup),
                                    (.remote(other.id), .lookup), (.remote(other.id), .retry)] {
            let expected = try NativeControllerAssociationStorage.selecting(selection, directory: directory,
                expected: NativeControllerAssociationStorage.load(directory: directory))
            try require(try NativePairedRecoveryCorrespondence.association(for: entry, action: action,
                pending: pending, associations: expected) == original)
            let clock = RecoveryClockProbe()
            do {
                _ = try await NativePairedControllerSession.recovering(entry, action: action, pending: pending,
                    associations: expected, clock: clock.clock)
                throw PairedRecoverySmokeError.failed(#line)
            } catch NativePairedSessionError.custody(.denied) {}
            try require(clock.calls == 0)
        }
        try refused { _ = try NativePairedRecoveryCorrespondence.association(for: entry, action: .cancelReview, pending: pending, associations: retained) }
        try refused { _ = try NativePairedRecoveryCorrespondence.association(for: entry, action: .lookup, pending: .empty, associations: retained) }
        try refused { _ = try NativePairedRecoveryCorrespondence.association(for: entry, action: .lookup, pending: pending, associations: .empty) }
        for change in [
            NativePendingEntry(context: entry.context, custody: .paired(association: other.id, controller: other.peer.controller,
                creationRevision: other.scope.creationRevision, verifier: other.verifier), input: entry.input, phase: entry.phase),
            NativePendingEntry(context: entry.context, custody: .paired(association: original.id, controller: String(repeating: "a", count: 64),
                creationRevision: 1, verifier: original.verifier), input: entry.input, phase: entry.phase),
            NativePendingEntry(context: entry.context, custody: .paired(association: original.id, controller: original.peer.controller,
                creationRevision: 2, verifier: original.verifier), input: entry.input, phase: entry.phase),
            NativePendingEntry(context: entry.context, custody: .paired(association: original.id, controller: original.peer.controller,
                creationRevision: 1, verifier: String(repeating: "a", count: 64)), input: entry.input, phase: entry.phase),
            NativePendingEntry(context: NativePendingContext(deployment: entry.context.deployment, owner: entry.context.owner,
                epoch: 2, principal: entry.context.principal), custody: entry.custody, input: entry.input, phase: entry.phase),
            NativePendingEntry(context: entry.context, custody: entry.custody,
                input: .power(operation: "op:substituted", target: "light:fixture", revision: 1, on: true), phase: entry.phase),
            NativePendingEntry(context: entry.context, custody: .manual(verifier: original.verifier), input: entry.input, phase: entry.phase),
        ] { try refused { _ = try NativePairedRecoveryCorrespondence.association(for: change, action: .lookup, pending: pending, associations: retained) } }
        // No selected/local transport can run a paired original, even with its
        // known synthetic fixture key. No broker, socket or signing seal runs.
        try refused { _ = try NativePendingRecoveryOperations.executePaired(entry, association: original,
            credential: Data(repeating: 8, count: 32), action: .lookup) }
        try NativePendingStorage.check(pending, directory: directory)
        let file = directory.appendingPathComponent("native-pending-v1.json")
        let bytes = try Data(contentsOf: file)
        try require(try NativePendingStorage.load(directory: directory) == pending)
        let lock = open(directory.appendingPathComponent("native-pending-v1.lock").path, O_RDWR | O_CLOEXEC)
        try require(lock >= 0 && flock(lock, LOCK_EX | LOCK_NB) == 0)
        try refused { try NativePendingStorage.check(pending, directory: directory) }
        _ = flock(lock, LOCK_UN); _ = Darwin.close(lock)
        let replacement = directory.appendingPathComponent("replacement")
        try write(replacement, bytes)
        try require(rename(replacement.path, file.path) == 0)
        try refused { try NativePendingStorage.check(pending, directory: directory) }
        let replaced = try NativePendingStorage.load(directory: directory)
        try write(file, bytes)
        try refused { try NativePendingStorage.check(replaced, directory: directory) }
        let current = try NativePendingStorage.load(directory: directory)
        try NativePendingStorage.check(current, directory: directory)
        try require(try Data(contentsOf: file) == bytes)
        try require(chmod(file.path, 0o644) == 0)
        try refused { try NativePendingStorage.check(current, directory: directory) }
        try require(chmod(file.path, 0o600) == 0)
        try require(chmod(directory.path, 0o755) == 0)
        try refused { try NativePendingStorage.check(current, directory: directory) }
        try require(chmod(directory.path, 0o700) == 0)
        try require(try Data(contentsOf: file) == bytes)
        try cancellation(original, root: root)
    }

    private static func cancellation(_ association: NativeControllerPublicAssociation, root: URL) throws {
        let directory = root.appendingPathComponent("cancellation", isDirectory: true)
        try makeDirectory(directory)
        let input = try HomeProfileOperation([
            "action": "select", "authority_epoch": 1, "operation_id": "op:original-review", "expected_revision": 3,
            "artifact_digest": String(repeating: "a", count: 64), "expected_trust_revision": 1, "target_id": "light:fixture",
            "expected_resource_revision": 1, "expected_binding_revision": 1, "expected_selection_generation": 0,
            "expected_policy_generation": 1, "expected_rule_generation": 0,
            "session_ref": "session:fixture", "candidate_ref": "candidate:fixture", "review_ref": "review:fixture",
        ])
        let entry = NativePendingEntry(context: context(association), custody: try .paired(from: association),
            input: .profile(preparing: true, operation: input), phase: .review(token: "profile:original-token", digest: String(repeating: "b", count: 64)))
        let before = try NativePendingStorage.retaining(entry, directory: directory, expected: .empty)
        let after = try NativePendingStorage.changingPhase(of: entry,
            to: .cancelPending(token: "profile:original-token", digest: String(repeating: "b", count: 64)), directory: directory, expected: before)
        let next = try NativePairedRecoveryCorrespondence.cancellation(of: entry, action: .cancelReview, before: before, after: after)
        try require(next.context == entry.context && next.custody == entry.custody && next.input == entry.input && next.phase.isCancellation)
        try NativePendingStorage.check(after, directory: directory)
        for action in [NativePendingRecoveryAction.lookup, .retry] {
            try refused { _ = try NativePairedRecoveryCorrespondence.cancellation(of: entry, action: action, before: before, after: after) }
        }
        try refused { _ = try NativePairedRecoveryCorrespondence.cancellation(of: next, action: .cancelReview, before: before, after: after) }
        try refused { _ = try NativePairedRecoveryCorrespondence.cancellation(of: entry, action: .cancelReview, before: before, after: before) }
        for (index, document) in [
            NativePendingDocument(revision: 2, entries: [try entry.changingPhase(.cancelPending(token: "profile:other-token", digest: String(repeating: "b", count: 64)))]),
            NativePendingDocument(revision: 2, entries: [try entry.changingPhase(.cancelPending(token: "profile:original-token", digest: String(repeating: "c", count: 64)))]),
            NativePendingDocument(revision: 3, entries: [next]),
            NativePendingDocument(revision: 2, entries: [], version: .v5),
            NativePendingDocument(revision: 2, entries: [], version: .v4),
            NativePendingDocument(revision: 2, entries: NativePendingDocument.sorted([next,
                NativePendingEntry(context: entry.context, custody: entry.custody,
                    input: .power(operation: "op:other-row", target: "light:fixture", revision: 1, on: true), phase: .pending)])),
        ].enumerated() {
            let path = root.appendingPathComponent("bad-cancellation-\(index)", isDirectory: true)
            try makeDirectory(path)
            try write(path.appendingPathComponent("native-pending-v1.json"), document.encoded())
            let bad = try NativePendingStorage.load(directory: path)
            try refused { _ = try NativePairedRecoveryCorrespondence.cancellation(of: entry, action: .cancelReview, before: before, after: bad) }
        }
    }

    private static func transport() async throws {
        let header = FileHandle.standardInput.readData(ofLength: 4)
        try require(header.count == 4)
        let size = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        try require((1...131_072).contains(size))
        guard let payload = try JSONSerialization.jsonObject(with: FileHandle.standardInput.readData(ofLength: Int(size))) as? [String: Any],
              let mode = payload["mode"] as? String, let document = payload["invitation"] as? String,
              let bootstrapBody = payload["bootstrap"] as? String, let directoryPath = payload["directory"] as? String else {
            throw PairedRecoverySmokeError.failed(#line)
        }
        let directory = URL(fileURLWithPath: directoryPath, isDirectory: true)
        let invitation = try NativeControllerPairingWire.decodeInvitation(Data(document.utf8))
        let peer = try NativeControllerPeer(invitation: invitation)
        let bootstrap = try NativeControllerPairingWire.decodeRequest(Data(bootstrapBody.utf8))
        let clock: @Sendable () throws -> NativeControllerCertificateClock = {
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            return try NativeControllerCertificateClock(earliest: now, latest: now)
        }
        let access = NativeControllerAccess(permissions: ["control:ordinary", "read"], targets: ["light:paired-original"])
        let key: Data, association: NativeControllerPublicAssociation, original: NativePendingEntry
        if mode == "stage" {
            let response = try await NativeControllerTLSClient.bootstrap(invitation, request: bootstrap, clock: clock(), approvedAccess: access)
            guard case .paired(let delivered) = response else { throw PairedRecoverySmokeError.failed(#line) }
            key = delivered.credential
            association = try NativeControllerPublicAssociation.corresponding(peer: peer, label: "Original", delivered: delivered,
                request: bootstrap, approvedAccess: access)
            try writeKey(directory.appendingPathComponent("raw-fixture.key"), key)
            var retained = try NativeControllerAssociationStorage.retaining(association, directory: directory, expected: .empty)
            guard let otherBody = payload["other"] as? String else { throw PairedRecoverySmokeError.failed(#line) }
            let other = try NativeControllerPublicAssociation.decode(Data(otherBody.utf8))
            retained = try NativeControllerAssociationStorage.retaining(other, directory: directory, expected: retained)
            _ = try NativeControllerAssociationStorage.selecting(.remote(other.id), directory: directory, expected: retained)
            original = NativePendingEntry(context: context(association), custody: try .paired(from: association),
                input: .power(operation: "op:original-paired", target: "light:paired-original", revision: 0, on: true), phase: .pending)
            _ = try NativePendingStorage.retaining(original, directory: directory, expected: .empty)
        } else if mode == "wrong-principal" {
            key = Data(repeating: 8, count: 32)
            let delivered = NativeControllerAssociation(context: try NativeControllerPairingWire.context(bootstrap),
                deployment: String(repeating: "3", count: 64), owner: String(repeating: "4", count: 64), epoch: 1,
                principal: "paired-controller-v1:1:" + bootstrap.client, revision: 1, access: access, credential: key)
            association = try NativeControllerPublicAssociation.corresponding(peer: peer, label: "Raw fixture", delivered: delivered,
                request: bootstrap, approvedAccess: access)
            original = NativePendingEntry(context: context(association), custody: try .paired(from: association),
                input: .power(operation: "op:original-paired", target: "light:paired-original", revision: 0, on: true), phase: .pending)
            _ = try NativeControllerAssociationStorage.retaining(association, directory: directory, expected: .empty)
            _ = try NativePendingStorage.retaining(original, directory: directory, expected: .empty)
        } else {
            let path = directory.appendingPathComponent("raw-fixture.key")
            var info = stat()
            try require(lstat(path.path, &info) == 0 && info.st_uid == getuid() && info.st_mode & 0o777 == 0o600 &&
                info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) && info.st_nlink == 1 && info.st_size == 32)
            key = try Data(contentsOf: path)
            let journal = try NativePendingStorage.load(directory: directory)
            guard let entry = journal.document.entries.first else { throw PairedRecoverySmokeError.failed(#line) }
            original = entry
            association = try NativePairedRecoveryCorrespondence.association(for: entry, action: .lookup,
                pending: journal, associations: NativeControllerAssociationStorage.load(directory: directory))
        }
        let journal = try NativePendingStorage.load(directory: directory)
        let associations = try NativeControllerAssociationStorage.load(directory: directory)
        let before = try Data(contentsOf: directory.appendingPathComponent("native-pending-v1.json"))
        let guardCheck = NativeControllerExchangeGuard { _ in
            try NativePendingStorage.check(journal, directory: directory)
            try NativeControllerAssociationStorage.check(associations, directory: directory)
        }
        func execute(_ entry: NativePendingEntry, _ action: NativePendingRecoveryAction) async throws -> NativePendingRecoveryOutcome {
            try await NativeControllerDomainClient.perform(association.peer, credential: key, clock: clock,
                exchangeGuard: guardCheck, deadline: .now.advanced(by: .seconds(15))) {
                try NativePendingRecoveryOperations.executePaired(entry, association: association, credential: key, action: action)
            }
        }
        if mode == "wrong-principal" {
            do { _ = try await execute(original, .lookup); throw PairedRecoverySmokeError.failed(#line) }
            catch NativeControllerTLSError.outcomeUnknown {}
        } else if mode == "revoked" {
            do { _ = try await execute(original, .retry); throw PairedRecoverySmokeError.failed(#line) }
            catch LocalHealthError.server("unauthorized") {}
        } else {
            let current = try await NativeControllerDomainClient.perform(association.peer, credential: key, clock: clock,
                exchangeGuard: guardCheck, deadline: .now.advanced(by: .seconds(15))) {
                try LocalHealthClient.fetchControllerScope(socketPath: "", credential: key)
            }
            try NativePairedSessionCorrespondence.check(current, association: association)
            let result = try await execute(original, mode == "stage" || mode == "retry" ? .retry : .lookup)
            guard case .resolved(let detail) = result, detail.contains("Original request is held") else { throw PairedRecoverySmokeError.failed(#line) }
            if mode == "lookup" {
                let absent = NativePendingEntry(context: original.context, custody: original.custody,
                    input: .power(operation: "op:original-absent", target: "light:paired-original", revision: 0, on: false), phase: .pending)
                guard case .retained = try await execute(absent, .lookup) else { throw PairedRecoverySmokeError.failed(#line) }
            }
        }
        try NativePendingStorage.check(journal, directory: directory)
        try require(try Data(contentsOf: directory.appendingPathComponent("native-pending-v1.json")) == before)
        print("native original paired transport case passed")
    }

    private static func context(_ association: NativeControllerPublicAssociation) -> NativePendingContext {
        NativePendingContext(deployment: association.scope.deployment, owner: association.scope.owner,
            epoch: association.scope.epoch, principal: association.scope.principal)
    }
    private static func dictionary(_ path: String) throws -> [String: Any] {
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        guard bytes.count <= 1_048_576, let value = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw PairedRecoverySmokeError.failed(#line) }
        return value
    }
    private static func makeDirectory(_ path: URL) throws {
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        try require(chmod(path.path, 0o700) == 0)
    }
    private static func write(_ path: URL, _ data: Data) throws {
        try data.write(to: path)
        try require(chmod(path.path, 0o600) == 0)
    }
    private static func writeKey(_ path: URL, _ data: Data) throws {
        try require(data.count == 32)
        let fd = open(path.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        try require(fd >= 0)
        defer { _ = Darwin.close(fd) }
        let count = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, data.count) }
        try require(count == data.count && fsync(fd) == 0)
    }
    private static func require(_ condition: @autoclosure () throws -> Bool, line: Int = #line) throws {
        guard try condition() else { throw PairedRecoverySmokeError.failed(line) }
    }
    private static func refused(_ operation: () throws -> Void) throws {
        do { try operation(); throw PairedRecoverySmokeError.failed(#line) }
        catch is NativePendingError {}
    }
}
