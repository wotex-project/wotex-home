import Foundation

struct NativePendingSnapshot: Equatable, Sendable, CustomReflectable {
    let document: NativePendingDocument
    fileprivate let file: NativePrivateDocumentSnapshot
    static var empty: Self { Self(document: .empty, file: .empty) }
    var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
}

enum NativePendingStorage {
    static func load() throws -> NativePendingSnapshot {
        try mapped {
            guard let directory = try NativePrivateDocuments.directory(create: false) else { return .empty }
            return try load(directory: directory)
        }
    }
    static func retaining(_ entry: NativePendingEntry, expected: NativePendingSnapshot) throws -> NativePendingSnapshot {
        try mapped {
            guard let directory = try NativePrivateDocuments.directory(create: true) else { throw NativePendingError.unavailable }
            return try retaining(entry, directory: directory, expected: expected)
        }
    }
    static func changingPhase(of entry: NativePendingEntry, to phase: NativePendingPhase,
                              expected: NativePendingSnapshot) throws -> NativePendingSnapshot {
        try mapped {
            guard let directory = try NativePrivateDocuments.directory(create: true) else { throw NativePendingError.unavailable }
            return try changingPhase(of: entry, to: phase, directory: directory, expected: expected)
        }
    }
    static func resolving(_ entry: NativePendingEntry, expected: NativePendingSnapshot) throws -> NativePendingSnapshot {
        try mapped {
            guard let directory = try NativePrivateDocuments.directory(create: true) else { throw NativePendingError.unavailable }
            return try resolving(entry, directory: directory, expected: expected)
        }
    }
    // Only for a caller holding its verified Authority result (or definite
    // first refusal). A reloaded completed removal is confirmed through the
    // same full file CAS; a newer original in its category is never removed.
    static func confirmingResolution(_ entry: NativePendingEntry, expected: NativePendingSnapshot) throws -> NativePendingSnapshot {
        try mapped {
            guard let directory = try NativePrivateDocuments.directory(create: true) else { throw NativePendingError.unavailable }
            return try confirmingResolution(entry, directory: directory, expected: expected)
        }
    }

    // Disposable private fixtures can exercise publication without the real
    // account directory, native custody, API requests or any physical effects.
    static func load(directory: URL) throws -> NativePendingSnapshot {
        try mapped {
            let file = try NativePrivateDocuments.load(directory: directory, kind: .pending)
            return try snapshot(file)
        }
    }
    static func retaining(_ entry: NativePendingEntry, directory: URL, expected: NativePendingSnapshot) throws -> NativePendingSnapshot {
        let entries = expected.document.entries
        if entries.contains(entry) { return try publish(entries, directory: directory, expected: expected) }
        guard entries.count < 16 else { throw NativePendingError.capacity }
        guard !entries.contains(where: { $0.context.deployment == entry.context.deployment && $0.context.owner == entry.context.owner &&
            $0.context.epoch == entry.context.epoch && $0.category == entry.category }) else { throw NativePendingError.conflict }
        return try publish(entries + [entry], directory: directory, expected: expected)
    }
    static func changingPhase(of entry: NativePendingEntry, to phase: NativePendingPhase, directory: URL,
                              expected: NativePendingSnapshot) throws -> NativePendingSnapshot {
        guard let index = expected.document.entries.firstIndex(of: entry) else { throw NativePendingError.conflict }
        guard permitsTransition(from: entry.phase, to: phase) else { throw NativePendingError.conflict }
        var entries = expected.document.entries
        entries[index] = try entry.changingPhase(phase)
        return try publish(entries, directory: directory, expected: expected)
    }
    static func resolving(_ entry: NativePendingEntry, directory: URL, expected: NativePendingSnapshot) throws -> NativePendingSnapshot {
        guard expected.document.entries.contains(entry) else { throw NativePendingError.conflict }
        return try publish(expected.document.entries.filter { $0 != entry }, directory: directory, expected: expected)
    }
    static func confirmingResolution(_ entry: NativePendingEntry, directory: URL, expected: NativePendingSnapshot) throws -> NativePendingSnapshot {
        if expected.document.entries.contains(entry) { return try resolving(entry, directory: directory, expected: expected) }
        guard expected.document.revision > 0, !expected.document.entries.contains(where: { $0.context.deployment == entry.context.deployment &&
            $0.context.owner == entry.context.owner && $0.context.epoch == entry.context.epoch && $0.category == entry.category }) else {
            throw NativePendingError.conflict
        }
        return try publish(expected.document.entries, directory: directory, expected: expected)
    }

    private static func publish(_ entries: [NativePendingEntry], directory: URL, expected: NativePendingSnapshot) throws -> NativePendingSnapshot {
        try mapped {
            let bytes: Data?
            if entries == expected.document.entries { bytes = expected.file.bytes }
            else {
                guard expected.document.revision < Int64.max else { throw NativePendingError.invalidRecord }
                let version: NativePendingVersion = expected.document.version == .v2 || entries.contains { $0.category == .access } ? .v2 : .v1
                bytes = try NativePendingDocument(revision: expected.document.revision + 1, entries: NativePendingDocument.sorted(entries), version: version).encoded()
            }
            let file = try NativePrivateDocuments.replace(directory: directory, kind: .pending, expected: expected.file, bytes: bytes)
            return try snapshot(file)
        }
    }
    private static func snapshot(_ file: NativePrivateDocumentSnapshot) throws -> NativePendingSnapshot {
        NativePendingSnapshot(document: try file.bytes.map(NativePendingDocument.decode) ?? .empty, file: file)
    }
    static func permitsTransition(from original: NativePendingPhase, to next: NativePendingPhase) -> Bool {
        if original == next { return true }
        switch (original, next) {
        case (.pending, .review): return true
        case (.review(let token, let digest), .commitPending(let nextToken, let nextDigest)),
             (.review(let token, let digest), .cancelPending(let nextToken, let nextDigest)):
            return token == nextToken && digest == nextDigest
        default: return false
        }
    }
    private static func mapped<T>(_ body: () throws -> T) throws -> T {
        do { return try body() }
        catch let error as NativePrivateDocumentError {
            switch error {
            case .unavailable: throw NativePendingError.unavailable
            case .invalidRecord: throw NativePendingError.invalidRecord
            case .conflict: throw NativePendingError.conflict
            case .capacity: throw NativePendingError.capacity
            case .outcomeUnknown: throw NativePendingError.outcomeUnknown
            }
        }
    }
}
