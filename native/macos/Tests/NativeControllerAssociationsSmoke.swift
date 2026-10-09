import Darwin
import Foundation

private enum AssociationSmokeError: Error { case failed }

@main
struct NativeControllerAssociationsSmoke {
    static func main() {
        do {
            let args = CommandLine.arguments
            guard args.count >= 3 else { throw AssociationSmokeError.failed }
            let fixture = try Data(contentsOf: URL(fileURLWithPath: args[1]))
            guard fixture.count <= 1_048_576, let vectors = try JSONSerialization.jsonObject(with: fixture) as? [String: Any] else {
                throw AssociationSmokeError.failed
            }
            let directory = URL(fileURLWithPath: args[2], isDirectory: true)
            if args.count == 5, args[3] == "publish", let index = Int(args[4]) {
                try publisher(vectors, directory: directory, index: index)
                return
            }
            if args.count == 4, args[3] == "inspect" {
                let snapshot = try NativeControllerAssociationStorage.load(directory: directory)
                try require(snapshot.document.revision == 1 && snapshot.document.records.count == 1 && snapshot.document.selection == .local)
                print("fresh association process \(snapshot.document.records[0].id)")
                return
            }
            guard args.count == 3 else { throw AssociationSmokeError.failed }
            try codecs(vectors)
            try storage(vectors, directory: directory)
            try races(vectors, fixturePath: args[1], directory: directory)
            print("native controller associations independent codec, private CAS, restart and concurrent publication passed")
        } catch {
            FileHandle.standardError.write(Data("native controller associations fixture failed\n".utf8))
            exit(1)
        }
    }

    private static func records(_ vectors: [String: Any]) throws -> [[String: Any]] {
        guard let records = vectors["valid_records"] as? [[String: Any]], records.count == 9 else { throw AssociationSmokeError.failed }
        return records
    }
    private static func record(_ row: [String: Any]) throws -> NativeControllerPublicAssociation {
        guard let body = row["body"] as? String else { throw AssociationSmokeError.failed }
        return try NativeControllerPublicAssociation.decode(Data(body.utf8))
    }
    private static func codecs(_ vectors: [String: Any]) throws {
        for row in try records(vectors) {
            let value = try record(row)
            try require(value.id == row["association_id"] as? String && value.keychainAccount == value.id)
            try require(try String(decoding: value.encoded(), as: UTF8.self) == row["body"] as? String)
            try require(try String(decoding: NativeControllerAssociationsWire.binding(value), as: UTF8.self) == row["binding"] as? String)
        }
        guard let invalid = vectors["invalid_records"] as? [[String: Any]], invalid.count == 54,
              let documents = vectors["valid_documents"] as? [[String: Any]], documents.count == 4,
              let invalidDocuments = vectors["invalid_documents"] as? [[String: Any]], invalidDocuments.count == 16 else { throw AssociationSmokeError.failed }
        for row in invalid {
            guard let body = row["body"] as? String else { throw AssociationSmokeError.failed }
            try refused { _ = try NativeControllerPublicAssociation.decode(Data(body.utf8)) }
        }
        for row in documents {
            guard let body = row["body"] as? String else { throw AssociationSmokeError.failed }
            try require(try NativeControllerAssociationDocument.decode(Data(body.utf8)).encoded() == Data(body.utf8))
        }
        for row in invalidDocuments {
            guard let body = row["body"] as? String else { throw AssociationSmokeError.failed }
            try refused { _ = try NativeControllerAssociationDocument.decode(Data(body.utf8)) }
        }
        try correspondence(vectors)
    }

    private static func correspondence(_ vectors: [String: Any]) throws {
        guard let data = vectors["correspondence"] as? [String: Any], let invitationBody = data["invitation"] as? String,
              let requestBody = data["request"] as? String, let responseBody = data["delivered"] as? String,
              let label = data["label"] as? String, let expected = data["record"] as? String,
              let permissions = data["permissions"] as? [String], let targets = data["targets"] as? [String] else { throw AssociationSmokeError.failed }
        let invitation = try NativeControllerPairingWire.decodeInvitation(Data(invitationBody.utf8))
        let request = try NativeControllerPairingWire.decodeRequest(Data(requestBody.utf8))
        let access = NativeControllerAccess(permissions: permissions, targets: targets)
        let response = try NativeControllerPairingWire.verifyResponse(Data(responseBody.utf8), request: request, approvedAccess: access)
        guard case .paired(let delivered) = response else { throw AssociationSmokeError.failed }
        let peer = try NativeControllerPeer(invitation: invitation)
        let actual = try NativeControllerPublicAssociation.corresponding(peer: peer, label: label,
            delivered: delivered, request: request, approvedAccess: access)
        try require(try actual.encoded() == Data(expected.utf8))
        let publicText = String(decoding: try actual.encoded(), as: UTF8.self) + String(reflecting: actual)
        try require(!publicText.contains(NativeControllerPairingWire.base64(delivered.credential)))
        try require(!publicText.contains(NativeControllerPairingWire.base64(request.bootstrapSecret)))
        try require(NativeControllerPublicAssociation.keychainService == "org.wotex.home.paired-controller.v1")
        for changed in [
            NativeControllerAssociation(context: delivered.context, deployment: delivered.deployment, owner: delivered.owner,
                epoch: delivered.epoch, principal: "other-principal", revision: delivered.revision, access: access, credential: delivered.credential),
            NativeControllerAssociation(context: delivered.context, deployment: delivered.deployment, owner: delivered.owner,
                epoch: delivered.epoch, principal: delivered.principal, revision: delivered.revision, access: access, credential: request.bootstrapSecret),
            NativeControllerAssociation(context: delivered.context, deployment: delivered.deployment, owner: delivered.owner,
                epoch: delivered.epoch, principal: delivered.principal, revision: delivered.revision, access: access, credential: Data(repeating: 8, count: 31)),
            NativeControllerAssociation(context: .init(controller: delivered.context.controller, invitation: delivered.context.invitation,
                client: delivered.context.client, request: String(repeating: "9", count: 64), requestDigest: delivered.context.requestDigest),
                deployment: delivered.deployment, owner: delivered.owner, epoch: delivered.epoch, principal: delivered.principal,
                revision: delivered.revision, access: access, credential: delivered.credential)
        ] {
            try refused { _ = try NativeControllerPublicAssociation.corresponding(peer: peer, label: label, delivered: changed, request: request, approvedAccess: access) }
        }
        try refused { _ = try NativeControllerPublicAssociation.corresponding(peer: peer, label: label, delivered: delivered,
            request: request, approvedAccess: .init(permissions: ["host:maintain", "read"], targets: [])) }
        let wrong = try NativeControllerPeer(controller: String(repeating: "a", count: 64), identity: peer.identity,
            leafPin: peer.leafPin, trustAnchor: peer.trustAnchor, endpoint: peer.endpoint, port: peer.port)
        try refused { _ = try NativeControllerPublicAssociation.corresponding(peer: wrong, label: label, delivered: delivered, request: request, approvedAccess: access) }
    }

    private static func storage(_ vectors: [String: Any], directory: URL) throws {
        let root = directory.appendingPathComponent("storage", isDirectory: true)
        try makeDirectory(root)
        let file = root.appendingPathComponent("native-controllers-v1.json")
        let lock = root.appendingPathComponent("native-controllers-v1.lock")
        let rows = try records(vectors), firstRecord = try record(rows[0])
        try require(try NativeControllerAssociationStorage.load(directory: root) == .empty)
        try require(try NativeControllerAssociationStorage.selecting(.local, directory: root, expected: .empty) == .empty)
        try require(!FileManager.default.fileExists(atPath: file.path))
        let first = try NativeControllerAssociationStorage.retaining(firstRecord, directory: root, expected: .empty)
        try require(first.document == NativeControllerAssociationDocument(revision: 1, selection: .local, records: [firstRecord]))
        let firstBytes = try Data(contentsOf: file)
        try require(try NativeControllerAssociationStorage.retaining(firstRecord, directory: root, expected: first) == first)
        try require(try Data(contentsOf: file) == firstBytes)
        let selected = try NativeControllerAssociationStorage.selecting(.remote(firstRecord.id), directory: root, expected: first)
        try require(selected.document.revision == 2 && selected.document.selection == .remote(firstRecord.id))
        try require(try NativeControllerAssociationStorage.selecting(.remote(firstRecord.id), directory: root, expected: selected) == selected)
        let changed = try NativeControllerAssociationStorage.changingMetadata(id: firstRecord.id, label: "New label",
            endpoint: .init(kind: "dns", value: "controller.example"), port: 5555, directory: root, expected: selected)
        let changedRecord = changed.document.records[0]
        try require(changed.document.revision == 3 && changed.document.selection == selected.document.selection)
        try require(changedRecord.id == firstRecord.id && changedRecord.keychainAccount == firstRecord.keychainAccount &&
            changedRecord.scope == firstRecord.scope && changedRecord.original == firstRecord.original &&
            changedRecord.access == firstRecord.access && changedRecord.verifier == firstRecord.verifier)
        try require(try NativeControllerAssociationsWire.binding(changedRecord) == NativeControllerAssociationsWire.binding(firstRecord))
        try refused(.conflict) { _ = try NativeControllerAssociationStorage.retaining(firstRecord, directory: root, expected: changed) }
        try refused(.conflict) { _ = try NativeControllerAssociationStorage.selecting(.local, directory: root, expected: first) }
        try refused(.invalidRecord) { _ = try NativeControllerAssociationStorage.selecting(.remote(String(repeating: "a", count: 64)), directory: root, expected: changed) }
        try require(try NativeControllerAssociationStorage.load(directory: root) == changed)
        let lockFD = open(lock.path, O_RDWR | O_CLOEXEC)
        try require(lockFD >= 0 && flock(lockFD, LOCK_EX | LOCK_NB) == 0)
        try refused(.capacity) { _ = try NativeControllerAssociationStorage.selecting(.local, directory: root, expected: changed) }
        _ = flock(lockFD, LOCK_UN); _ = Darwin.close(lockFD)
        let changedBytes = try Data(contentsOf: file)
        let replacement = root.appendingPathComponent("replacement")
        try write(replacement, changedBytes)
        try require(rename(replacement.path, file.path) == 0)
        try refused(.conflict) { _ = try NativeControllerAssociationStorage.selecting(changed.document.selection, directory: root, expected: changed) }
        let replaced = try NativeControllerAssociationStorage.load(directory: root)
        try write(file, changedBytes)
        try refused(.conflict) { _ = try NativeControllerAssociationStorage.selecting(replaced.document.selection, directory: root, expected: replaced) }
        try require(chmod(file.path, 0o644) == 0)
        try refused { _ = try NativeControllerAssociationStorage.load(directory: root) }
        try require(chmod(file.path, 0o600) == 0)
        let linked = root.appendingPathComponent("linked")
        try require(link(file.path, linked.path) == 0)
        try refused { _ = try NativeControllerAssociationStorage.load(directory: root) }
        try FileManager.default.removeItem(at: linked)
        try FileManager.default.removeItem(at: file)
        try require(symlink(lock.path, file.path) == 0)
        try refused { _ = try NativeControllerAssociationStorage.load(directory: root) }
        try require(FileManager.default.destinationOfSymbolicLink(atPath: file.path) == lock.path)
        try FileManager.default.removeItem(at: file)
        try require(mkfifo(file.path, 0o600) == 0)
        try refused { _ = try NativeControllerAssociationStorage.load(directory: root) }
        try FileManager.default.removeItem(at: file)
        for bytes in [Data("[\"unknown\",1,[\"local\"],[]]".utf8), Data(repeating: 65, count: 131_073)] {
            try write(file, bytes)
            try refused { _ = try NativeControllerAssociationStorage.load(directory: root) }
            try refused { _ = try NativeControllerAssociationStorage.selecting(.local, directory: root, expected: changed) }
            try require(try Data(contentsOf: file) == bytes)
        }
        try write(file, changedBytes)
        for mutation in ["mode", "link", "content", "symlink", "fifo"] {
            try FileManager.default.removeItem(at: lock)
            switch mutation {
            case "mode": try write(lock, Data()); try require(chmod(lock.path, 0o644) == 0)
            case "link": try write(lock, Data()); try require(link(lock.path, linked.path) == 0)
            case "content": try write(lock, Data([1]))
            case "symlink": try require(symlink("unknown", lock.path) == 0)
            default: try require(mkfifo(lock.path, 0o600) == 0)
            }
            let expected = try NativeControllerAssociationStorage.load(directory: root)
            try refused { _ = try NativeControllerAssociationStorage.selecting(.local, directory: root, expected: expected) }
            try require(try Data(contentsOf: file) == changedBytes)
            if mutation == "link" { try FileManager.default.removeItem(at: linked) }
        }
        try FileManager.default.removeItem(at: lock)
        try write(lock, Data())
        let alias = directory.appendingPathComponent("alias")
        try require(symlink(root.path, alias.path) == 0)
        try refused { _ = try NativeControllerAssociationStorage.load(directory: alias) }
        try require(chmod(root.path, 0o755) == 0)
        try refused { _ = try NativeControllerAssociationStorage.load(directory: root) }
        try require(chmod(root.path, 0o700) == 0)
        guard let documents = vectors["valid_documents"] as? [[String: Any]],
              let exhaustedBody = documents.first(where: { $0["name"] as? String == "maximum_revision" })?["body"] as? String,
              let fullBody = documents.first(where: { $0["name"] as? String == "maximum_capacity" })?["body"] as? String,
              let invalidDocuments = vectors["invalid_documents"] as? [[String: Any]],
              let ninthBody = invalidDocuments.first(where: { $0["name"] as? String == "capacity" })?["body"] as? String,
              let ninthRoot = try JSONSerialization.jsonObject(with: Data(ninthBody.utf8)) as? [Any], let nine = ninthRoot[3] as? [String] else { throw AssociationSmokeError.failed }
        try write(file, Data(exhaustedBody.utf8))
        let exhausted = try NativeControllerAssociationStorage.load(directory: root)
        try require(try NativeControllerAssociationStorage.selecting(.local, directory: root, expected: exhausted) == exhausted)
        try refused(.invalidRecord) { _ = try NativeControllerAssociationStorage.selecting(.remote(firstRecord.id), directory: root, expected: exhausted) }
        try write(file, Data(fullBody.utf8))
        let full = try NativeControllerAssociationStorage.load(directory: root)
        try require(full.document.records.count == 8)
        let candidates = try nine.map { try NativeControllerPublicAssociation.decode(Data($0.utf8)) }
        guard let ninth = candidates.first(where: { candidate in !full.document.records.contains(where: { $0.id == candidate.id }) }) else { throw AssociationSmokeError.failed }
        try refused(.capacity) { _ = try NativeControllerAssociationStorage.retaining(ninth, directory: root, expected: full) }
        try require(try NativeControllerAssociationStorage.load(directory: root) == full)
    }

    private static func races(_ vectors: [String: Any], fixturePath: String, directory: URL) throws {
        let expectedIDs = Set(try [0, 2].map { try record(records(vectors)[$0]).id })
        for iteration in 0..<20 {
            let race = directory.appendingPathComponent("race-\(iteration)", isDirectory: true)
            try makeDirectory(race)
            var children: [(Process, Pipe)] = []
            defer { children.forEach(cleanup) }
            for index in [0, 2] { children.append(try launch([fixturePath, race.path, "publish", String(index)])) }
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while !(FileManager.default.fileExists(atPath: race.appendingPathComponent("ready-0").path) &&
                    FileManager.default.fileExists(atPath: race.appendingPathComponent("ready-2").path)) {
                guard ContinuousClock.now < deadline, children.allSatisfy({ $0.0.isRunning }) else { throw AssociationSmokeError.failed }
                Thread.sleep(forTimeInterval: 0.005)
            }
            try write(race.appendingPathComponent("go"), Data("ready".utf8))
            let outcomes = try children.map { try finish($0) }
            try require(outcomes.filter { $0.hasPrefix("published ") }.count == 1)
            try require(outcomes.filter { ["conflict", "capacity"].contains($0) }.count == 1)
            let snapshot = try NativeControllerAssociationStorage.load(directory: race)
            try require(snapshot.document.revision == 1 && snapshot.document.records.count == 1 && expectedIDs.contains(snapshot.document.records[0].id))
            let seen = try finish(launch([fixturePath, race.path, "inspect"]))
            try require(seen == "fresh association process \(snapshot.document.records[0].id)")
        }
    }
    private static func publisher(_ vectors: [String: Any], directory: URL, index: Int) throws {
        let rows = try records(vectors)
        guard rows.indices.contains(index) else { throw AssociationSmokeError.failed }
        let candidate = try record(rows[index])
        let original = try NativeControllerAssociationStorage.load(directory: directory)
        try require(original == .empty)
        try write(directory.appendingPathComponent("ready-\(index)"), Data("ready".utf8))
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !FileManager.default.fileExists(atPath: directory.appendingPathComponent("go").path) {
            guard ContinuousClock.now < deadline else { throw AssociationSmokeError.failed }
            Thread.sleep(forTimeInterval: 0.005)
        }
        do {
            let published = try NativeControllerAssociationStorage.retaining(candidate, directory: directory, expected: original)
            try require(published.document.records == [candidate] && published.document.revision == 1)
            print("published \(candidate.id)")
        } catch NativeControllerAssociationError.conflict { print("conflict") }
        catch NativeControllerAssociationError.capacity { print("capacity") }
    }
    private static func launch(_ args: [String]) throws -> (Process, Pipe) {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = args; process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        return (process, pipe)
    }
    private static func finish(_ child: (Process, Pipe)) throws -> String {
        defer { cleanup(child) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while child.0.isRunning {
            guard ContinuousClock.now < deadline else { throw AssociationSmokeError.failed }
            Thread.sleep(forTimeInterval: 0.005)
        }
        child.0.waitUntilExit()
        let bytes = child.1.fileHandleForReading.readDataToEndOfFile()
        try require(child.0.terminationStatus == 0 && bytes.count <= 4096)
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private static func cleanup(_ child: (Process, Pipe)) {
        if child.0.isRunning { _ = kill(child.0.processIdentifier, SIGKILL) }
        try? child.1.fileHandleForReading.close()
    }
    private static func write(_ file: URL, _ bytes: Data) throws {
        try bytes.write(to: file); try require(chmod(file.path, 0o600) == 0)
    }
    private static func makeDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    private static func refused(_ expected: NativeControllerAssociationError? = nil, _ work: () throws -> Void) throws {
        do { try work(); throw AssociationSmokeError.failed }
        catch let actual as NativeControllerAssociationError {
            if let expected {
                switch (actual, expected) {
                case (.invalidRecord, .invalidRecord), (.conflict, .conflict), (.capacity, .capacity), (.unavailable, .unavailable), (.outcomeUnknown, .outcomeUnknown): break
                default: throw AssociationSmokeError.failed
                }
            }
        }
    }
    private static func require(_ condition: Bool) throws { if !condition { throw AssociationSmokeError.failed } }
}
