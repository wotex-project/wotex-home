import Foundation

struct NativeControllerAssociationSnapshot: Equatable, Sendable, CustomReflectable {
    let document: NativeControllerAssociationDocument
    fileprivate let file: NativePrivateDocumentSnapshot
    static let empty = Self(document: .empty, file: .empty)
    var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
}

// Public metadata only. Every write uses the existing original file CAS. No
// key, credential capture, TLS, API, device worker or host selection runs here.
enum NativeControllerAssociationStorage {
    static func load() throws -> NativeControllerAssociationSnapshot {
        try mapped {
            guard let directory = try NativePrivateDocuments.directory(create: false) else { return .empty }
            return try load(directory: directory)
        }
    }
    static func check(_ expected: NativeControllerAssociationSnapshot) throws {
        try mapped {
            guard let directory = try NativePrivateDocuments.directory(create: false) else {
                guard expected == .empty else { throw NativeControllerAssociationError.conflict }
                return
            }
            try check(expected, directory: directory)
        }
    }
    static func retaining(_ record: NativeControllerPublicAssociation, expected: NativeControllerAssociationSnapshot) throws -> NativeControllerAssociationSnapshot {
        try mapped {
            guard let directory = try NativePrivateDocuments.directory(create: true) else { throw NativeControllerAssociationError.unavailable }
            return try retaining(record, directory: directory, expected: expected)
        }
    }
    static func selecting(_ selection: NativeControllerSelection, expected: NativeControllerAssociationSnapshot) throws -> NativeControllerAssociationSnapshot {
        try mapped {
            guard let directory = try NativePrivateDocuments.directory(create: true) else { throw NativeControllerAssociationError.unavailable }
            return try selecting(selection, directory: directory, expected: expected)
        }
    }
    static func changingMetadata(id: String, label: String, endpoint: NativeControllerAddress, port: Int64,
                                 expected: NativeControllerAssociationSnapshot) throws -> NativeControllerAssociationSnapshot {
        try mapped {
            guard let directory = try NativePrivateDocuments.directory(create: true) else { throw NativeControllerAssociationError.unavailable }
            return try changingMetadata(id: id, label: label, endpoint: endpoint, port: port, directory: directory, expected: expected)
        }
    }

    // Private foreground fixtures exercise real publication without opening
    // the actual account document or manufacturing a credential custody seal.
    static func load(directory: URL) throws -> NativeControllerAssociationSnapshot {
        try mapped { try snapshot(NativePrivateDocuments.load(directory: directory, kind: .controllers)) }
    }
    static func check(_ expected: NativeControllerAssociationSnapshot, directory: URL) throws {
        try mapped {
            _ = try NativePrivateDocuments.replace(directory: directory, kind: .controllers,
                expected: expected.file, bytes: expected.file.bytes)
        }
    }
    static func retaining(_ record: NativeControllerPublicAssociation, directory: URL,
                          expected: NativeControllerAssociationSnapshot) throws -> NativeControllerAssociationSnapshot {
        _ = try record.encoded()
        let records = expected.document.records
        if let existing = records.first(where: { $0.id == record.id }) {
            guard existing == record else { throw NativeControllerAssociationError.conflict }
            return try publish(records: records, selection: expected.document.selection, directory: directory, expected: expected)
        }
        guard records.count < 8 else { throw NativeControllerAssociationError.capacity }
        return try publish(records: records + [record], selection: expected.document.selection, directory: directory, expected: expected)
    }
    static func selecting(_ selection: NativeControllerSelection, directory: URL,
                          expected: NativeControllerAssociationSnapshot) throws -> NativeControllerAssociationSnapshot {
        if case .remote(let id) = selection, !expected.document.records.contains(where: { $0.id == id }) {
            throw NativeControllerAssociationError.invalidRecord
        }
        return try publish(records: expected.document.records, selection: selection, directory: directory, expected: expected)
    }
    static func changingMetadata(id: String, label: String, endpoint: NativeControllerAddress, port: Int64,
                                 directory: URL, expected: NativeControllerAssociationSnapshot) throws -> NativeControllerAssociationSnapshot {
        guard let index = expected.document.records.firstIndex(where: { $0.id == id }) else { throw NativeControllerAssociationError.conflict }
        var records = expected.document.records
        records[index] = try records[index].changingMetadata(label: label, endpoint: endpoint, port: port)
        return try publish(records: records, selection: expected.document.selection, directory: directory, expected: expected)
    }

    private static func publish(records: [NativeControllerPublicAssociation], selection: NativeControllerSelection,
                                directory: URL, expected: NativeControllerAssociationSnapshot) throws -> NativeControllerAssociationSnapshot {
        try mapped {
            let bytes: Data?
            let records = records.sorted { $0.id < $1.id }
            if records == expected.document.records, selection == expected.document.selection { bytes = expected.file.bytes }
            else {
                guard expected.document.revision < Int64.max else { throw NativeControllerAssociationError.invalidRecord }
                bytes = try NativeControllerAssociationDocument(revision: expected.document.revision + 1, selection: selection, records: records).encoded()
            }
            return try snapshot(NativePrivateDocuments.replace(directory: directory, kind: .controllers, expected: expected.file, bytes: bytes))
        }
    }
    private static func snapshot(_ file: NativePrivateDocumentSnapshot) throws -> NativeControllerAssociationSnapshot {
        NativeControllerAssociationSnapshot(document: try file.bytes.map(NativeControllerAssociationDocument.decode) ?? .empty, file: file)
    }
    private static func mapped<T>(_ work: () throws -> T) throws -> T {
        do { return try work() }
        catch let error as NativePrivateDocumentError {
            switch error {
            case .unavailable: throw NativeControllerAssociationError.unavailable
            case .invalidRecord: throw NativeControllerAssociationError.invalidRecord
            case .conflict: throw NativeControllerAssociationError.conflict
            case .capacity: throw NativeControllerAssociationError.capacity
            case .outcomeUnknown: throw NativeControllerAssociationError.outcomeUnknown
            }
        }
    }
}
