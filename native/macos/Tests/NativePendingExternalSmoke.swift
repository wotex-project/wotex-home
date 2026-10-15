import Darwin
import Foundation

private enum ExternalPendingFailure: Error { case line(Int) }
private final class ExternalPendingCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func record() { lock.lock(); defer { lock.unlock() }; value += 1 }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

@main
struct NativePendingExternalSmoke {
    @MainActor static func main() async {
        do {
            let args = CommandLine.arguments
            guard args.count >= 3 else { throw ExternalPendingFailure.line(#line) }
            let corpus = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[1]))) as! [String: Any]
            let directory = URL(fileURLWithPath: args[2], isDirectory: true)
            if args.count > 3 { try child(corpus, directory: directory, mode: args[3]); return }
            try codecs(corpus)
            try await storage(corpus, directory: directory)
            try processes(corpus, directory: directory)
            print("external pending 182 valid/276 invalid vectors, private CAS, restart, races and custody guards passed")
        } catch ExternalPendingFailure.line(let line) {
            FileHandle.standardError.write(Data("external pending assertion failed at line \(line)\n".utf8)); exit(1)
        } catch {
            FileHandle.standardError.write(Data("external pending check failed: \(type(of: error))\n".utf8)); exit(1)
        }
    }
    private static func check(_ value: @autoclosure () throws -> Bool, line: Int = #line) throws {
        guard try value() else { throw ExternalPendingFailure.line(line) }
    }
    private static func refused(_ operation: () throws -> Void, line: Int = #line) throws {
        do { try operation() } catch is ExternalPendingFailure { throw ExternalPendingFailure.line(line) }
        catch { return }
        throw ExternalPendingFailure.line(line)
    }
    private static func rows(_ corpus: [String: Any]) -> [[String: Any]] { corpus["valid"] as! [[String: Any]] }
    private static func document(_ row: [String: Any]) throws -> NativePendingDocument {
        try NativePendingDocument.decode(Data((row["document"] as! String).utf8))
    }
    private static func external(_ corpus: [String: Any], custody: String = "manual") throws -> NativePendingEntry {
        try document(rows(corpus).first { ($0["name"] as! String) == "inspection-temperature-inspection-" + custody }!).entries[0]
    }
    private static func ordinary(_ suffix: String = "one") -> NativePendingEntry {
        NativePendingEntry(context: .init(deployment: String(repeating: "d", count: 64), owner: String(repeating: suffix == "race" ? "9" : "e", count: 64), epoch: 7, principal: "operator:fixture"),
            custody: .manual(verifier: String(repeating: "f", count: 64)), input: .cancel(operation: "ordinary:" + suffix), phase: .pending)
    }
    private static func codecs(_ corpus: [String: Any]) throws {
        try check(rows(corpus).count == 182 && (corpus["invalid"] as! [[String: Any]]).count == 276)
        for row in rows(corpus) {
            let decoded = try document(row), bytes = Data((row["document"] as! String).utf8)
            try check(try decoded.encoded() == bytes)
            try check(LocalHealthClient.profileSHA(bytes) == row["sha256"] as! String)
            try check(Mirror(reflecting: decoded).children.isEmpty)
            for entry in decoded.entries where entry.category == .externalProfile {
                let original = try entry.externalProfileOperation()
                try check(original.epoch == entry.context.epoch && original.operation == entry.input.operationID)
                try check(Mirror(reflecting: entry).children.isEmpty && Mirror(reflecting: entry.input).children.isEmpty && Mirror(reflecting: original).children.isEmpty)
                for action in [NativePendingRecoveryAction.lookup, .retry, .cancelReview, .acknowledgeAbsent, .acknowledgeUnknown] {
                    let expected = action == .lookup || action == .retry || action == .acknowledgeAbsent
                    try check(action.permits(entry) == expected)
                }
            }
        }
        for row in corpus["invalid"] as! [[String: Any]] {
            do { _ = try document(row) }
            catch NativePendingError.invalidRecord { continue }
            throw ExternalPendingFailure.line(#line)
        }
        let base = rows(corpus)[0]["document"] as! String
        for data in [Data((base + "\n").utf8), Data(base.replacingOccurrences(of: "external_profile_operation", with: "external_profile_operation ").utf8),
                     Data([0xff]), Data(repeating: 32, count: 8_388_609)] {
            try refused { _ = try NativePendingDocument.decode(data) }
        }
        // Exercise scanner limits in the exact permitted document slot, plus
        // a neighboring slot and a second row after a large original.
        let entry = try external(corpus)
        for kind in HomeExternalProfileOriginalKind.allCases {
            let malformed: [Any] = ["wotex-home.native-pending.v9", 1, [["external_profile", [entry.context.deployment, entry.context.owner, 1, "operator:fixture"], ["manual", entry.custody.verifier], ["external_profile_operation", kind.rawValue, String(repeating: "x", count: kind.maximum + 1)], ["pending"]]]]
            try refused { _ = try NativePendingDocument.decode(JSONSerialization.data(withJSONObject: malformed, options: .withoutEscapingSlashes)) }
        }
        let neighboring = ordinary(String(repeating: "x", count: 129))
        try refused { _ = try NativePendingDocument(revision: 1, entries: NativePendingDocument.sorted([entry, neighboring])).encoded() }
        for version in [NativePendingVersion.v1, .v2, .v3, .v4, .v5, .v6, .v7, .v8] {
            try refused { _ = try NativePendingDocument(revision: 1, entries: [entry], version: version).encoded() }
        }
    }
    @MainActor private static func storage(_ corpus: [String: Any], directory: URL) async throws {
        let entry = try external(corpus)
        for version in [NativePendingVersion.v1, .v2, .v3, .v4, .v5, .v6, .v7, .v8] {
            let root = try make(directory, "upgrade-" + version.rawValue)
            try write(root.appendingPathComponent("native-pending-v1.json"), NativePendingDocument(revision: 1, entries: [ordinary()], version: version).encoded())
            let before = try NativePendingStorage.load(directory: root)
            let after = try NativePendingStorage.retaining(entry, directory: root, expected: before)
            try check(after.document.version == .v9 && after.document.revision == 2 && after.document.entries == NativePendingDocument.sorted([ordinary(), entry]))
            try check(try NativePendingStorage.retaining(entry, directory: root, expected: after) == after)
            try refused { _ = try NativePendingStorage.resolving(ordinary(), directory: root, expected: before) }
            let resolved = try NativePendingStorage.resolving(entry, directory: root, expected: after)
            try check(resolved.document.version == .v9 && resolved.document.entries == [ordinary()])
            let empty = try NativePendingStorage.resolving(ordinary(), directory: root, expected: resolved)
            try check(empty.document.version == .v9 && empty.document.entries.isEmpty)
            let later = try NativePendingStorage.retaining(ordinary("later"), directory: root, expected: empty)
            try check(later.document.version == .v9 && later.document.revision == 5)
            try refused { _ = try NativePendingStorage.changingPhase(of: entry, to: .review(token: "token", digest: String(repeating: "a", count: 64)), directory: root, expected: after) }
        }
        let maxRoot = try make(directory, "max")
        try write(maxRoot.appendingPathComponent("native-pending-v1.json"), NativePendingDocument(revision: Int64.max, entries: [entry]).encoded())
        let maximum = try NativePendingStorage.load(directory: maxRoot)
        try check(try NativePendingStorage.retaining(entry, directory: maxRoot, expected: maximum) == maximum)
        try refused { _ = try NativePendingStorage.resolving(entry, directory: maxRoot, expected: maximum) }

        // Generic paired correspondence must retain v9 even when its original
        // belongs to an older category. No signed custody is manufactured.
        let pairedOrdinary = NativePendingEntry(context: .init(deployment: String(repeating: "3", count: 64), owner: String(repeating: "4", count: 64), epoch: 1, principal: "paired-controller-v1:1:" + String(repeating: "6", count: 64)),
            custody: .paired(association: String(repeating: "1", count: 64), controller: String(repeating: "2", count: 64), creationRevision: 1, verifier: String(repeating: "c", count: 64)), input: .cancel(operation: "ordinary:paired"), phase: .pending)
        let pairedRoot = try make(directory, "paired-correspondence")
        let seed = try NativePendingStorage.retaining(entry, directory: pairedRoot, expected: .empty)
        let captured = try NativePendingStorage.retaining(pairedOrdinary, directory: pairedRoot, expected: seed)
        try NativePairedCaptureCorrespondence.publication(of: pairedOrdinary, before: seed, after: captured)
        let resolved = try NativePendingStorage.resolving(pairedOrdinary, directory: pairedRoot, expected: captured)
        _ = try NativePairedRecoveryCorrespondence.publication(of: pairedOrdinary, outcome: .resolved("fixture"), before: captured, after: resolved)
        try check(resolved.document.version == .v9 && resolved.document.entries == [entry])
        _ = try NativePairedRecoveryCorrespondence.publication(of: pairedOrdinary, outcome: .retained("fixture"), before: captured, after: captured)
        try refused { _ = try NativePairedRecoveryCorrespondence.publication(of: pairedOrdinary, outcome: .resolved("fixture"), before: captured, after: seed) }
        try await refusals(corpus, directory: directory)
    }
    @MainActor private static func refusals(_ corpus: [String: Any], directory: URL) async throws {
        let calls = ExternalPendingCalls(), root = try make(directory, "capture-refusal")
        let coordinator = NativePendingCoordinator(persistence: .init(directory: root), capture: {
            calls.record(); throw NativePendingError.unavailable
        }, socketPath: { calls.record(); return "/private/tmp/external-pending-never.sock" })
        await coordinator.reload()
        let entry = try external(corpus)
        do { _ = try await coordinator.begin(entry.input, authorityEpoch: 1); throw ExternalPendingFailure.line(#line) }
        catch NativePendingError.unavailable {}
        try check(calls.count == 1 && coordinator.snapshot == .empty && !coordinator.needsReload)
        for custody in ["manual", "native", "paired"] {
            let root = try make(directory, "refusal-" + custody), entry = try external(corpus, custody: custody)
            let stored = try NativePendingStorage.retaining(entry, directory: root, expected: .empty)
            let coordinator = NativePendingCoordinator(persistence: .init(directory: root), capture: { calls.record(); throw NativePendingError.unavailable },
                socketPath: { calls.record(); return "/private/tmp/external-pending-never.sock" })
            await coordinator.reload()
            for action in [NativePendingRecoveryAction.lookup, .retry, .cancelReview, .acknowledgeUnknown, .acknowledgeAbsent] {
                let before = calls.count
                await coordinator.recover(entry, action: action, custody: { _ in calls.record(); throw NativePendingError.unavailable }, execute: { _, _, _, _ in calls.record(); throw NativePendingError.unavailable })
                await coordinator.recoverPaired(entry, action: action, associations: .empty, clock: { calls.record(); throw NativePendingError.unavailable })
                try refused { _ = try NativePendingRecoveryOperations.execute(entry, credential: Data(repeating: 8, count: 32), socketPath: "/private/tmp/external-pending-never.sock", action: action) }
                if entry.custody.isPaired {
                    do { _ = try await NativePairedControllerSession.recovering(entry, action: action, pending: stored, associations: .empty, clock: { calls.record(); throw NativePendingError.unavailable }); throw ExternalPendingFailure.line(#line) }
                    catch is ExternalPendingFailure { throw ExternalPendingFailure.line(#line) }
                    catch {}
                }
                try check(calls.count == before + (!entry.custody.isPaired && action.permits(entry) ? 1 : 0))
                try check(coordinator.needsReload == (entry.custody.isPaired && action.permits(entry)))
                if coordinator.needsReload { await coordinator.reload() }
            }
            try check(coordinator.snapshot == stored && !coordinator.needsReload && !coordinator.busy)
            try check(try NativePendingStorage.load(directory: root) == stored)
        }
    }
    private static func processes(_ corpus: [String: Any], directory: URL) throws {
        let root = try make(directory, "restart")
        let writer = try start(root, mode: "retain-exit")
        try finish(writer)
        try finish(start(root, mode: "reload"))
        for kind in ["external", "ordinary"] {
            let root = try make(directory, "race-" + kind)
            let seed = try NativePendingDocument(revision: 1, entries: [ordinary()], version: .v8).encoded()
            try write(root.appendingPathComponent("native-pending-v1.json"), seed)
            let first = try start(root, mode: "race-external-0"), second = try start(root, mode: "race-" + kind + "-1")
            let deadline = Date().addingTimeInterval(10)
            while !FileManager.default.fileExists(atPath: root.appendingPathComponent("ready-0").path) || !FileManager.default.fileExists(atPath: root.appendingPathComponent("ready-1").path) {
                guard Date() < deadline else { first.terminate(); second.terminate(); throw ExternalPendingFailure.line(#line) }
                Thread.sleep(forTimeInterval: 0.01)
            }
            try write(root.appendingPathComponent("go"), Data())
            first.waitUntilExit(); second.waitUntilExit()
            try check([first.terminationStatus, second.terminationStatus].sorted() == [0, 3])
            let result = try NativePendingStorage.load(directory: root)
            try check(result.document.revision == 2 && result.document.entries.count == 2 && result.document.entries.contains(ordinary()))
            let winner = result.document.entries.first { $0 != ordinary() }!
            try check(winner.input.operationID == "race:0" || winner.input.operationID == "race:1" || winner.input.operationID == "ordinary:race")
            try check(result.document.version == (winner.category == .externalProfile ? .v9 : .v8))
            try finish(start(root, mode: "reload-race"))
        }
    }
    private static func child(_ corpus: [String: Any], directory: URL, mode: String) throws {
        let entry = try external(corpus)
        switch mode {
        case "retain-exit":
            _ = try NativePendingStorage.retaining(entry, directory: directory, expected: .empty); _exit(0)
        case "reload":
            let result = try NativePendingStorage.load(directory: directory)
            try check(result.document.version == .v9 && result.document.revision == 1 && result.document.entries == [entry])
        case "reload-race":
            let result = try NativePendingStorage.load(directory: directory)
            try check(result.document.revision == 2 && result.document.entries.count == 2 && result.document.entries.contains(ordinary()))
        default:
            let before = try NativePendingStorage.load(directory: directory), index = mode.hasSuffix("0") ? "0" : "1"
            let contender: NativePendingEntry
            if mode.hasPrefix("race-ordinary") { contender = ordinary("race") }
            else {
                var fields = try entry.externalProfileOperation().fields(); fields["operation_id"] = "race:" + index
                contender = NativePendingEntry(context: entry.context, custody: entry.custody,
                    input: .externalProfile(try NativeExternalProfileOriginalWire.encode(fields, kind: .inspection)), phase: .pending)
            }
            try write(directory.appendingPathComponent("ready-" + index), Data())
            let deadline = Date().addingTimeInterval(10)
            while !FileManager.default.fileExists(atPath: directory.appendingPathComponent("go").path) {
                guard Date() < deadline else { throw ExternalPendingFailure.line(#line) }; Thread.sleep(forTimeInterval: 0.01)
            }
            do { _ = try NativePendingStorage.retaining(contender, directory: directory, expected: before) }
            catch NativePendingError.conflict { _exit(3) }
            catch NativePendingError.capacity { _exit(3) }
        }
    }
    private static func start(_ directory: URL, mode: String) throws -> Process {
        let process = Process(); process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = [CommandLine.arguments[1], directory.path, mode]; try process.run(); return process
    }
    private static func finish(_ process: Process) throws {
        process.waitUntilExit(); try check(process.terminationReason == .exit && process.terminationStatus == 0)
    }
    private static func make(_ directory: URL, _ name: String) throws -> URL {
        let root = directory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]); return root
    }
    private static func write(_ url: URL, _ data: Data) throws {
        try data.write(to: url); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
