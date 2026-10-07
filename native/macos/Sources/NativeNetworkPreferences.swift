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

fileprivate struct NativePreferenceFileIdentity: Equatable, Sendable {
    let device: dev_t, inode: ino_t, owner: uid_t, mode: mode_t, links: nlink_t, size: off_t
    let modifiedSeconds: time_t, modifiedNanoseconds: Int, changedSeconds: time_t, changedNanoseconds: Int
    init(_ info: stat) {
        device = info.st_dev; inode = info.st_ino; owner = info.st_uid; mode = info.st_mode
        links = info.st_nlink; size = info.st_size
        modifiedSeconds = info.st_mtimespec.tv_sec; modifiedNanoseconds = info.st_mtimespec.tv_nsec
        changedSeconds = info.st_ctimespec.tv_sec; changedNanoseconds = info.st_ctimespec.tv_nsec
    }
    func sameObject(_ info: stat) -> Bool { device == info.st_dev && inode == info.st_ino }
}

struct NativeNetworkSnapshot: Equatable, Sendable {
    let record: NativeNetworkRecord
    fileprivate let identity: NativePreferenceFileIdentity?
    fileprivate init(record: NativeNetworkRecord, identity: NativePreferenceFileIdentity?) { self.record = record; self.identity = identity }
    static var disabled: Self { Self(record: NativeNetworkRecord(revision: 0, interface: nil), identity: nil) }
}

// This file contains no credential, device identity or authorization. Only the
// actual OS account's fixed local preference directory is used in production.
enum NativeNetworkPreferences {
    private static let file = "native-network-v1.json"
    private static let lockFile = "native-network-v1.lock"

    static func directory(create: Bool) throws -> URL? {
        let path = URL(fileURLWithPath: try NativeCoreEnvironment.userHome(), isDirectory: true)
            .appendingPathComponent("Library/Application Support/WoTExHome", isDirectory: true).path
        var info = stat()
        if lstat(path, &info) != 0 {
            guard errno == ENOENT else { throw NativeNetworkPreferenceError.unavailable }
            if !create { return nil }
            guard mkdir(path, 0o700) == 0, lstat(path, &info) == 0 else { throw NativeNetworkPreferenceError.unavailable }
        }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), info.st_uid == getuid(), info.st_mode & 0o777 == 0o700 else {
            throw NativeNetworkPreferenceError.unavailable
        }
        return URL(fileURLWithPath: try physicalPath(path), isDirectory: true)
    }
    static func load() throws -> NativeNetworkSnapshot {
        guard let directory = try directory(create: false) else { return .disabled }
        return try load(directory: directory)
    }
    static func save(expected: NativeNetworkSnapshot, interface: String?) throws -> NativeNetworkSnapshot {
        guard let directory = try directory(create: true) else { throw NativeNetworkPreferenceError.unavailable }
        return try save(directory: directory, expected: expected, interface: interface)
    }

    // Disposable foreground fixtures may supply a private directory. This does
    // not select an interface socket, authorize a peer or create native custody.
    static func load(directory: URL) throws -> NativeNetworkSnapshot {
        let root = try Directory(directory.path); defer { root.close() }
        return try read(root)
    }
    static func save(directory: URL, expected: NativeNetworkSnapshot, interface: String?) throws -> NativeNetworkSnapshot {
        if let interface, !NativeNetworkRecord.validName(interface) { throw NativeNetworkPreferenceError.invalidRecord }
        let root = try Directory(directory.path); defer { root.close() }
        let lock = openat(root.fd, lockFile, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw NativeNetworkPreferenceError.unavailable }
        defer { _ = Darwin.close(lock) }
        let lockID = try regular(lock, limit: 0)
        try current(root, name: lockFile, fd: lock, identity: lockID)
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK { throw NativeNetworkPreferenceError.capacity }
            throw NativeNetworkPreferenceError.unavailable
        }
        defer { _ = flock(lock, LOCK_UN) }
        try current(root, name: lockFile, fd: lock, identity: lockID)
        let original = try read(root)
        guard original == expected else { throw NativeNetworkPreferenceError.conflict }
        if original.record.interface == interface { return original }
        guard original.record.revision < Int64.max else { throw NativeNetworkPreferenceError.invalidRecord }
        let next = NativeNetworkRecord(revision: original.record.revision + 1, interface: interface)
        let bytes = try next.encoded()
        let temporary = ".native-network-" + UUID().uuidString.lowercased()
        let fd = openat(root.fd, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw NativeNetworkPreferenceError.unavailable }
        var opened = stat()
        guard fstat(fd, &opened) == 0 else { _ = Darwin.close(fd); throw NativeNetworkPreferenceError.unavailable }
        let temporaryID = NativePreferenceFileIdentity(opened)
        defer {
            _ = Darwin.close(fd)
            var named = stat()
            if (try? root.current()) != nil, fstatat(root.fd, temporary, &named, AT_SYMLINK_NOFOLLOW) == 0, temporaryID.sameObject(named) {
                _ = unlinkat(root.fd, temporary, 0)
            }
        }
        var offset = 0
        while offset < bytes.count {
            let count = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: offset), bytes.count - offset) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw NativeNetworkPreferenceError.unavailable }
            offset += count
        }
        let written = try regular(fd, limit: 128)
        guard written.size == bytes.count, fsync(fd) == 0 else { throw NativeNetworkPreferenceError.unavailable }
        try current(root, name: temporary, fd: fd, identity: written)
        try current(root, name: lockFile, fd: lock, identity: lockID)
        guard try read(root) == original else { throw NativeNetworkPreferenceError.conflict }
        guard renameat(root.fd, temporary, root.fd, file) == 0 else { throw NativeNetworkPreferenceError.unavailable }
        do {
            guard fsync(root.fd) == 0 else { throw NativeNetworkPreferenceError.outcomeUnknown }
            try current(root, name: lockFile, fd: lock, identity: lockID)
            let result = try read(root)
            guard result.record == next, let resultID = result.identity, resultID.device == written.device, resultID.inode == written.inode else {
                throw NativeNetworkPreferenceError.outcomeUnknown
            }
            return result
        } catch { throw NativeNetworkPreferenceError.outcomeUnknown }
    }

    private static func read(_ root: Directory) throws -> NativeNetworkSnapshot {
        try root.current()
        let fd = openat(root.fd, file, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 {
            guard errno == ENOENT else { throw NativeNetworkPreferenceError.unavailable }
            try root.current()
            var named = stat()
            guard fstatat(root.fd, file, &named, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else { throw NativeNetworkPreferenceError.unavailable }
            return .disabled
        }
        defer { _ = Darwin.close(fd) }
        let identity = try regular(fd, limit: 128)
        guard identity.size >= 1 else { throw NativeNetworkPreferenceError.invalidRecord }
        try current(root, name: file, fd: fd, identity: identity)
        var bytes = Data(); var buffer = [UInt8](repeating: 0, count: 129)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0, bytes.count + count <= 128 else { throw NativeNetworkPreferenceError.invalidRecord }
            if count == 0 { break }; bytes.append(contentsOf: buffer.prefix(count))
        }
        try current(root, name: file, fd: fd, identity: identity)
        guard bytes.count == identity.size else { throw NativeNetworkPreferenceError.unavailable }
        return NativeNetworkSnapshot(record: try NativeNetworkRecord.decode(bytes), identity: identity)
    }
    private static func regular(_ fd: Int32, limit: Int) throws -> NativePreferenceFileIdentity {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_mode & 0o777 == 0o600, info.st_nlink == 1, info.st_size >= 0, info.st_size <= limit else {
            throw NativeNetworkPreferenceError.unavailable
        }
        return NativePreferenceFileIdentity(info)
    }
    private static func current(_ root: Directory, name: String, fd: Int32, identity: NativePreferenceFileIdentity) throws {
        try root.current()
        var opened = stat(); var named = stat()
        guard fstat(fd, &opened) == 0, fstatat(root.fd, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              NativePreferenceFileIdentity(opened) == identity, NativePreferenceFileIdentity(named) == identity else {
            throw NativeNetworkPreferenceError.unavailable
        }
    }
    private static func physicalPath(_ path: String) throws -> String {
        guard !path.utf8.contains(0), let resolved = realpath(path, nil) else { throw NativeNetworkPreferenceError.unavailable }
        defer { free(resolved) }
        guard let result = String(validatingCString: resolved) else { throw NativeNetworkPreferenceError.unavailable }
        return result
    }
    private final class Directory {
        let path: String, fd: Int32, device: dev_t, inode: ino_t
        init(_ path: String) throws {
            guard getuid() != 0, getuid() == geteuid(), path.hasPrefix("/"), try physicalPath(path) == path else { throw NativeNetworkPreferenceError.unavailable }
            let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw NativeNetworkPreferenceError.unavailable }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o777 == 0o700,
                  info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { _ = Darwin.close(fd); throw NativeNetworkPreferenceError.unavailable }
            self.path = path; self.fd = fd; device = info.st_dev; inode = info.st_ino
        }
        func current() throws {
            guard try physicalPath(path) == path else { throw NativeNetworkPreferenceError.unavailable }
            for named in [false, true] {
                var info = stat()
                guard (named ? lstat(path, &info) : fstat(fd, &info)) == 0,
                      info.st_dev == device, info.st_ino == inode, info.st_uid == getuid(),
                      info.st_mode & 0o777 == 0o700, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { throw NativeNetworkPreferenceError.unavailable }
            }
        }
        func close() { _ = Darwin.close(fd) }
    }
}
