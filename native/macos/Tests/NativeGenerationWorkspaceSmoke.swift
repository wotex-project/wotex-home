import Darwin
import Foundation

private enum WorkspaceAssertion: Error { case failed(Int) }

@main
struct NativeGenerationWorkspaceSmoke {
    static func main() {
        do { try run() }
        catch WorkspaceAssertion.failed(let line) { FileHandle.standardError.write(Data("workspace check failed at line \(line)\n".utf8)); exit(1) }
        catch { FileHandle.standardError.write(Data("workspace check failed\n".utf8)); exit(1) }
    }
    private static func run() throws {
        guard CommandLine.arguments.count >= 3 else { exit(2) }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true), argument = CommandLine.arguments[2]
        let paired = argument.hasPrefix("paired-"), mode = paired ? String(argument.dropFirst(7)) : argument
        let vectors = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: paired ? "test/fixtures/profiles/native-generation-workspace-v2.json" : "test/fixtures/profiles/native-generation-workspace.json"))) as! [String: Any]
        let cases = vectors["cases"] as! [[String: Any]]
        let documents = try cases.map { value -> NativeGenerationWorkspaceDocument in
            let bytes = Data((value["document"] as! String).utf8)
            try require(LocalHealthClient.profileSHA(bytes) == value["sha256"] as! String)
            let document = try NativeGenerationWorkspaceDocument.decode(bytes)
            try require(try document.encoded() == bytes && Mirror(reflecting: document).children.isEmpty && document.entries.allSatisfy { Mirror(reflecting: $0).children.isEmpty })
            return document
        }
        if let invalid = vectors["invalid"] as? [[String: Any]] {
            for vector in invalid { try refused { _ = try NativeGenerationWorkspaceDocument.decode(Data((vector["document"] as! String).utf8)) } }
        }
        let base = documents[0].entries[0], full = documents.first { $0.entries[0].attempts.count == 3 }!.entries[0]
        if mode == "race" || mode == "append-race" || mode == "intent-race" || mode == "archive-race" {
            guard CommandLine.arguments.count == 4 else { exit(2) }
            let index = CommandLine.arguments[3], before = try NativeGenerationWorkspaceStorage.load(directory: directory)
            try Data().write(to: directory.appendingPathComponent("ready-" + index))
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while !FileManager.default.fileExists(atPath: directory.appendingPathComponent("go").path) { try require(ContinuousClock.now < deadline); usleep(10000) }
            do {
                if mode == "race" {
                    _ = try NativeGenerationWorkspaceStorage.retaining(index == "0" ? base : full, directory: directory, expected: before)
                } else if mode == "append-race" {
                    let root = before.document.entries[0]
                    var fields = try full.attempts[0].fields(); fields["operation_id"] = "attempt:race" + index
                    let attempt = try NativeGenerationOriginalWire.encode(fields, kind: .attempt)
                    _ = try NativeGenerationWorkspaceStorage.replacing(root, with: root.appending(attempt), directory: directory, expected: before)
                } else if mode == "intent-race" {
                    let root = before.document.entries[0]
                    let changed = index == "0" ? try root.cancellation(true) : try root.appending(full.attempts[0])
                    _ = try NativeGenerationWorkspaceStorage.replacing(root, with: changed, directory: directory, expected: before)
                } else {
                    let root = before.document.entries[0]
                    if index == "0" { _ = try NativeGenerationWorkspaceStorage.removing(root, directory: directory, expected: before) }
                    else { _ = try NativeGenerationWorkspaceStorage.replacing(root, with: root.cancellation(true), directory: directory, expected: before) }
                }
                print("race_committed")
            } catch NativePendingError.conflict { print("race_refused") }
            catch NativePendingError.capacity { print("race_refused") }
            return
        }
        if mode == "seed" {
            let root = NativeGenerationWorkspaceEntry(context: full.context, custody: full.custody, basisSHA: full.basisSHA, preparation: full.preparation, attempts: [], cancellationPending: false)
            _ = try NativeGenerationWorkspaceStorage.retaining(root, directory: directory, expected: .empty)
            print("workspace seed passed"); return
        }
        if mode == "load" {
            let path = directory.appendingPathComponent("native-generation-workspace-v1.json"), bytes = try Data(contentsOf: path)
            let snapshot = try NativeGenerationWorkspaceStorage.load(directory: directory)
            try require(snapshot.document.revision > 0 && snapshot.document.entries.count <= 1 && Data(contentsOf: path) == bytes)
            print("workspace load passed"); return
        }
        guard mode == "suite" else { exit(2) }
        try malformed(cases.filter { (try? NativeGenerationWorkspaceDocument.decode(Data(($0["document"] as! String).utf8)).entries.count) == 1 })
        try require(try NativeGenerationWorkspaceStorage.load(directory: directory) == .empty)
        let path = directory.appendingPathComponent("native-generation-workspace-v1.json"), lock = directory.appendingPathComponent("native-generation-workspace-v1.lock")
        try require(!FileManager.default.fileExists(atPath: path.path) && !FileManager.default.fileExists(atPath: lock.path))
        let entry = NativeGenerationWorkspaceEntry(context: full.context, custody: full.custody, basisSHA: full.basisSHA, preparation: full.preparation, attempts: [], cancellationPending: false)
        let first = try NativeGenerationWorkspaceStorage.retaining(entry, directory: directory, expected: .empty)
        try require(first.document.version == (paired ? .v2 : .v1))
        let bytes = try Data(contentsOf: path)
        try require(try NativeGenerationWorkspaceStorage.retaining(entry, directory: directory, expected: first) == first && Data(contentsOf: path) == bytes)
        let secondEntry = try entry.appending(full.attempts[0])
        let second = try NativeGenerationWorkspaceStorage.replacing(entry, with: secondEntry, directory: directory, expected: first)
        try refused { _ = try NativeGenerationWorkspaceStorage.removing(entry, directory: directory, expected: first) }
        var current = second, retained = secondEntry
        for attempt in full.attempts.dropFirst() {
            let next = try retained.appending(attempt)
            current = try NativeGenerationWorkspaceStorage.replacing(retained, with: next, directory: directory, expected: current); retained = next
        }
        let intent = try retained.cancellation(true)
        current = try NativeGenerationWorkspaceStorage.replacing(retained, with: intent, directory: directory, expected: current)
        try require(current.document.revision == 5 && current.document.entries[0].cancellationPending && current.document.entries[0].attempts.count == 3)
        try require(try NativeGenerationWorkspaceStorage.replacing(intent, with: intent, directory: directory, expected: current) == current)
        let replacement = directory.appendingPathComponent("replacement")
        try current.document.encoded().write(to: replacement); try require(chmod(replacement.path, 0o600) == 0 && rename(replacement.path, path.path) == 0)
        try refused { _ = try NativeGenerationWorkspaceStorage.removing(intent, directory: directory, expected: current) }
        let reloaded = try NativeGenerationWorkspaceStorage.load(directory: directory)
        let empty = try NativeGenerationWorkspaceStorage.removing(intent, directory: directory, expected: reloaded)
        try require(empty.document.entries.isEmpty && empty.document.revision == 6 && NativeGenerationWorkspaceStorage.load(directory: directory) == empty)
        try refused { _ = try NativeGenerationWorkspaceStorage.removing(intent, directory: directory, expected: empty) }
        let next = try NativeGenerationWorkspaceStorage.retaining(base, directory: directory, expected: empty)
        try require(next.document.revision == 7 && next.document.version == (paired ? .v2 : .v1))
        let fullEntries = (0..<16).map { n in NativeGenerationWorkspaceEntry(context: NativePendingContext(deployment: base.context.deployment, owner: String(format: "%064x", n), epoch: base.context.epoch, principal: base.context.principal), custody: base.custody, basisSHA: base.basisSHA, preparation: base.preparation, attempts: [], cancellationPending: false) }
        try NativeGenerationWorkspaceDocument(revision: 1, entries: NativeGenerationWorkspaceDocument.sorted(fullEntries)).encoded().write(to: path)
        try require(chmod(path.path, 0o600) == 0)
        let capacity = try NativeGenerationWorkspaceStorage.load(directory: directory)
        try refused { _ = try NativeGenerationWorkspaceStorage.retaining(base, directory: directory, expected: capacity) }
        for unsafe in ["mode", "hardlink", "symlink"] {
            let extra = directory.appendingPathComponent("unsafe")
            if unsafe == "mode" { try require(chmod(path.path, 0o644) == 0) }
            if unsafe == "hardlink" { try require(link(path.path, extra.path) == 0) }
            if unsafe == "symlink" { try require(rename(path.path, extra.path) == 0 && symlink(extra.path, path.path) == 0) }
            try refused { _ = try NativeGenerationWorkspaceStorage.load(directory: directory) }
            if unsafe == "mode" { try require(chmod(path.path, 0o600) == 0) }
            if unsafe == "hardlink" { try require(unlink(extra.path) == 0) }
            if unsafe == "symlink" { try require(unlink(path.path) == 0 && rename(extra.path, path.path) == 0) }
        }
        if paired { try upgrade(directory, paired: base) }
        print("workspace independent originals, private CAS, intent and bounds passed")
    }
    private static func malformed(_ cases: [[String: Any]]) throws {
        for c in cases {
            let bytes = Data((c["document"] as! String).utf8), root = try JSONSerialization.jsonObject(with: bytes) as! [Any]
            for altered in [Data([32]) + bytes, bytes + Data([32]), Data(String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: root[0] as! String, with: "wotex-home.native-generation-workspace.v9").utf8), Data([255])] {
                try refused { _ = try NativeGenerationWorkspaceDocument.decode(altered) }
            }
            var entry = (root[2] as! [[Any]])[0]
            for slot in [0, 1, 2, 3, 4, 5] {
                var fields = entry; fields[slot] = NSNull()
                try invalid([root[0], root[1], [fields]])
            }
            for revision: Any in [true, 0, "1", UInt64.max] { try invalid([root[0], revision, root[2]]) }
            let rev = (root[1] as! NSNumber).stringValue
            let floating = Data(String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "\(root[0] as! String)\",\(rev),", with: "\(root[0] as! String)\",\(rev).0,").utf8)
            try refused { _ = try NativeGenerationWorkspaceDocument.decode(floating) }
            var context = entry[0] as! [Any]; context[2] = 0; entry[0] = context; try invalid([root[0], root[1], [entry]])
            let full = try NativeGenerationWorkspaceDocument.decode(bytes).entries[0]
            if full.attempts.count > 1 {
                var changed = (root[2] as! [[Any]])[0]; changed[4] = Array((changed[4] as! [Any]).reversed()); try invalid([root[0], root[1], [changed]])
            }
        }
        try refused { _ = try NativeGenerationWorkspaceDocument.decode(Data(repeating: 65, count: 2_097_153)) }
    }
    private static func invalid(_ value: [Any]) throws {
        let bytes = try JSONSerialization.data(withJSONObject: value, options: [.withoutEscapingSlashes])
        try refused { _ = try NativeGenerationWorkspaceDocument.decode(bytes) }
    }
    private static func upgrade(_ directory: URL, paired: NativeGenerationWorkspaceEntry) throws {
        let path = directory.appendingPathComponent("native-generation-workspace-v1.json")
        let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "test/fixtures/profiles/native-generation-workspace.json"))) as! [String: Any]
        let vector = (fixture["cases"] as! [[String: Any]])[0]
        let original = try NativeGenerationWorkspaceDocument.decode(Data((vector["document"] as! String).utf8)).entries[0]
        let local = NativeGenerationWorkspaceEntry(context: NativePendingContext(deployment: original.context.deployment,
            owner: String(repeating: "e", count: 64), epoch: original.context.epoch, principal: original.context.principal), custody: original.custody,
            basisSHA: original.basisSHA, preparation: original.preparation, attempts: original.attempts, cancellationPending: original.cancellationPending)
        let old = try NativeGenerationWorkspaceDocument(revision: 1, entries: [local], version: .v1).encoded()
        try old.write(to: path); try require(chmod(path.path, 0o600) == 0)
        let before = try NativeGenerationWorkspaceStorage.load(directory: directory)
        try require(before.document.version == .v1 && NativeGenerationWorkspaceStorage.retaining(local, directory: directory, expected: before) == before && Data(contentsOf: path) == old)
        let upgraded = try NativeGenerationWorkspaceStorage.retaining(paired, directory: directory, expected: before)
        try require(upgraded.document.version == .v2 && upgraded.document.revision == 2 && upgraded.document.entries.contains(local))
        try refused { _ = try NativeGenerationWorkspaceStorage.removing(local, directory: directory, expected: before) }
        let onlyLocal = try NativeGenerationWorkspaceStorage.removing(paired, directory: directory, expected: upgraded)
        let empty = try NativeGenerationWorkspaceStorage.removing(local, directory: directory, expected: onlyLocal)
        try require(onlyLocal.document.version == .v2 && empty.document.version == .v2 && empty.document.entries.isEmpty)
        let later = try NativeGenerationWorkspaceStorage.retaining(local, directory: directory, expected: empty)
        try require(later.document.version == .v2)
        try refused { _ = try NativeGenerationWorkspaceDocument(revision: 1, entries: [paired], version: .v1).encoded() }
    }
    private static func require(_ value: Bool, line: Int = #line) throws { if !value { throw WorkspaceAssertion.failed(line) } }
    private static func refused(_ action: () throws -> Void) throws {
        do { try action() } catch let error as NativePendingError { if error == .invalidRecord || error == .conflict || error == .capacity || error == .unavailable { return }; throw error }
        throw WorkspaceAssertion.failed(#line)
    }
}
