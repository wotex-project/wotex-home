import Darwin
import Foundation

enum NativeNetworkPreferenceError: LocalizedError {
    case unavailable, invalidRecord, conflict, capacity, outcomeUnknown
    var errorDescription: String? {
        switch self {
        case .unavailable: "Home network preferences are unavailable."
        case .invalidRecord: "Home network preferences contain an unsupported setting."
        case .conflict: "Network preferences changed. Refresh before saving."
        case .capacity: "Another window is saving network preferences. Refresh and try again."
        case .outcomeUnknown: "The network preference save is uncertain. Refresh before saving again."
        }
    }
}

struct NativeNetworkRecord: Equatable, Sendable {
    let revision: Int64
    let interface: String?
    private static let format = "wotex-home.native-network.v1"
    static func validName(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        return (1...15).contains(bytes.count) && bytes.first.map(letter) == true && bytes.allSatisfy { letter($0) || (48...57).contains($0) }
    }
    private static func letter(_ byte: UInt8) -> Bool { (65...90).contains(byte) || (97...122).contains(byte) }
    static func decode(_ bytes: Data) throws -> Self {
        guard bytes.count <= 128, let values = try? NativeScalarJSON.decode(bytes),
              values.count >= 3, values[0] as? String == format,
              let revision = NativeScalarJSON.integer(values[1], minimum: 1) else { throw NativeNetworkPreferenceError.invalidRecord }
        if values.count == 3, values[2] as? String == "disabled" { return Self(revision: revision, interface: nil) }
        guard values.count == 4, values[2] as? String == "lifx-read", let name = values[3] as? String,
              validName(name) else { throw NativeNetworkPreferenceError.invalidRecord }
        return Self(revision: revision, interface: name)
    }
    func encoded() throws -> Data {
        guard revision >= 1 else { throw NativeNetworkPreferenceError.invalidRecord }
        if let interface {
            guard Self.validName(interface) else { throw NativeNetworkPreferenceError.invalidRecord }
            return try NativeScalarJSON.encode([Self.format, revision, "lifx-read", interface])
        }
        return try NativeScalarJSON.encode([Self.format, revision, "disabled"])
    }
}

struct NativeNetworkSnapshot: Equatable, Sendable {
    let record: NativeNetworkRecord
    fileprivate let file: NativePrivateDocumentSnapshot
    static var disabled: Self { Self(record: NativeNetworkRecord(revision: 0, interface: nil), file: .empty) }
}

// This file contains no credential, device identity or authorization. Only the
// actual OS account's fixed local preference directory is used in production.
enum NativeNetworkPreferences {
    static func directory(create: Bool) throws -> URL? {
        try mapped { try NativePrivateDocuments.directory(create: create) }
    }
    static func load() throws -> NativeNetworkSnapshot {
        guard let directory = try directory(create: false) else { return .disabled }
        return try load(directory: directory)
    }
    static func save(expected: NativeNetworkSnapshot, interface: String?) throws -> NativeNetworkSnapshot {
        guard let directory = try directory(create: true) else { throw NativeNetworkPreferenceError.unavailable }
        return try save(directory: directory, expected: expected, interface: interface)
    }
    static func load(directory: URL) throws -> NativeNetworkSnapshot {
        try mapped {
            let file = try NativePrivateDocuments.load(directory: directory, kind: .network)
            return try snapshot(file)
        }
    }
    static func save(directory: URL, expected: NativeNetworkSnapshot, interface: String?) throws -> NativeNetworkSnapshot {
        try mapped {
            if let interface, !NativeNetworkRecord.validName(interface) { throw NativeNetworkPreferenceError.invalidRecord }
            let bytes: Data?
            if expected.record.interface == interface { bytes = expected.file.bytes }
            else {
                guard expected.record.revision < Int64.max else { throw NativeNetworkPreferenceError.invalidRecord }
                bytes = try NativeNetworkRecord(revision: expected.record.revision + 1, interface: interface).encoded()
            }
            let file = try NativePrivateDocuments.replace(directory: directory, kind: .network, expected: expected.file, bytes: bytes)
            return try snapshot(file)
        }
    }
    private static func snapshot(_ file: NativePrivateDocumentSnapshot) throws -> NativeNetworkSnapshot {
        NativeNetworkSnapshot(record: try file.bytes.map(NativeNetworkRecord.decode) ?? NativeNetworkRecord(revision: 0, interface: nil), file: file)
    }
    private static func mapped<T>(_ body: () throws -> T) throws -> T {
        do { return try body() }
        catch let error as NativePrivateDocumentError {
            switch error {
            case .unavailable: throw NativeNetworkPreferenceError.unavailable
            case .invalidRecord: throw NativeNetworkPreferenceError.invalidRecord
            case .conflict: throw NativeNetworkPreferenceError.conflict
            case .capacity: throw NativeNetworkPreferenceError.capacity
            case .outcomeUnknown: throw NativeNetworkPreferenceError.outcomeUnknown
            }
        }
    }
}
