import Darwin
import Foundation

enum NativePrivateDocumentError: Error { case unavailable, invalidRecord, conflict, capacity, outcomeUnknown }

enum NativePrivateDocumentKind {
    case network, pending
    fileprivate var file: String { self == .network ? "native-network-v1.json" : "native-pending-v1.json" }
    fileprivate var lockFile: String { self == .network ? "native-network-v1.lock" : "native-pending-v1.lock" }
    fileprivate var prefix: String { self == .network ? ".native-network-" : ".native-pending-" }
    fileprivate var limit: Int { self == .network ? 128 : 65_536 }
}

private struct NativePrivateFileIdentity: Equatable, Sendable {
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

struct NativePrivateDocumentSnapshot: Equatable, Sendable, CustomReflectable {
    let bytes: Data?
    fileprivate let identity: NativePrivateFileIdentity?
    fileprivate init(bytes: Data?, identity: NativePrivateFileIdentity?) { self.bytes = bytes; self.identity = identity }
    static var empty: Self { Self(bytes: nil, identity: nil) }
    var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
}

// Fixed document names only. Callers validate their closed data codecs; this
// layer owns private descriptors, bounded reads and original publication CAS.
enum NativePrivateDocuments {
    static func directory(create: Bool) throws -> URL? {
        let path = URL(fileURLWithPath: try NativeCoreEnvironment.userHome(), isDirectory: true)
            .appendingPathComponent("Library/Application Support/WoTExHome", isDirectory: true).path
        var info = stat()
        if lstat(path, &info) != 0 {
            guard errno == ENOENT else { throw NativePrivateDocumentError.unavailable }
            if !create { return nil }
            guard mkdir(path, 0o700) == 0, lstat(path, &info) == 0 else { throw NativePrivateDocumentError.unavailable }
        }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), info.st_uid == getuid(), info.st_mode & 0o777 == 0o700 else {
            throw NativePrivateDocumentError.unavailable
        }
        return URL(fileURLWithPath: try physicalPath(path), isDirectory: true)
    }
    static func load(directory: URL, kind: NativePrivateDocumentKind) throws -> NativePrivateDocumentSnapshot {
        let root = try Directory(directory.path); defer { root.close() }
        return try read(root, kind: kind)
    }
    static func replace(directory: URL, kind: NativePrivateDocumentKind, expected: NativePrivateDocumentSnapshot,
                        bytes: Data?) throws -> NativePrivateDocumentSnapshot {
        if let bytes, !(1...kind.limit).contains(bytes.count) { throw NativePrivateDocumentError.invalidRecord }
        let root = try Directory(directory.path); defer { root.close() }
        let lock = openat(root.fd, kind.lockFile, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw NativePrivateDocumentError.unavailable }
        defer { _ = Darwin.close(lock) }
        let lockID = try regular(lock, limit: 0)
        try current(root, name: kind.lockFile, fd: lock, identity: lockID)
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK { throw NativePrivateDocumentError.capacity }
            throw NativePrivateDocumentError.unavailable
        }
        defer { _ = flock(lock, LOCK_UN) }
        try current(root, name: kind.lockFile, fd: lock, identity: lockID)
        let original = try read(root, kind: kind)
        guard original == expected else { throw NativePrivateDocumentError.conflict }
        if original.bytes == bytes { return original }
        guard let bytes else { throw NativePrivateDocumentError.invalidRecord }
        let temporary = kind.prefix + UUID().uuidString.lowercased()
        let fd = openat(root.fd, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw NativePrivateDocumentError.unavailable }
        var opened = stat()
        guard fstat(fd, &opened) == 0 else { _ = Darwin.close(fd); throw NativePrivateDocumentError.unavailable }
        let temporaryID = NativePrivateFileIdentity(opened)
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
            guard count > 0 else { throw NativePrivateDocumentError.unavailable }
            offset += count
        }
        let written = try regular(fd, limit: kind.limit)
        guard written.size == bytes.count, fsync(fd) == 0 else { throw NativePrivateDocumentError.unavailable }
        try current(root, name: temporary, fd: fd, identity: written)
        try current(root, name: kind.lockFile, fd: lock, identity: lockID)
        guard try read(root, kind: kind) == original else { throw NativePrivateDocumentError.conflict }
        guard renameat(root.fd, temporary, root.fd, kind.file) == 0 else { throw NativePrivateDocumentError.unavailable }
        do {
            guard fsync(root.fd) == 0 else { throw NativePrivateDocumentError.outcomeUnknown }
            try current(root, name: kind.lockFile, fd: lock, identity: lockID)
            let result = try read(root, kind: kind)
            guard result.bytes == bytes, let identity = result.identity,
                  identity.device == written.device, identity.inode == written.inode else { throw NativePrivateDocumentError.outcomeUnknown }
            return result
        } catch { throw NativePrivateDocumentError.outcomeUnknown }
    }

    private static func read(_ root: Directory, kind: NativePrivateDocumentKind) throws -> NativePrivateDocumentSnapshot {
        try root.current()
        let fd = openat(root.fd, kind.file, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 {
            guard errno == ENOENT else { throw NativePrivateDocumentError.unavailable }
            try root.current()
            var named = stat()
            guard fstatat(root.fd, kind.file, &named, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else { throw NativePrivateDocumentError.unavailable }
            return .empty
        }
        defer { _ = Darwin.close(fd) }
        let identity = try regular(fd, limit: kind.limit)
        guard identity.size >= 1 else { throw NativePrivateDocumentError.invalidRecord }
        try current(root, name: kind.file, fd: fd, identity: identity)
        var bytes = Data(); var buffer = [UInt8](repeating: 0, count: min(4096, kind.limit + 1))
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0, bytes.count + count <= kind.limit else { throw NativePrivateDocumentError.invalidRecord }
            if count == 0 { break }; bytes.append(contentsOf: buffer.prefix(count))
        }
        try current(root, name: kind.file, fd: fd, identity: identity)
        guard bytes.count == identity.size else { throw NativePrivateDocumentError.unavailable }
        return NativePrivateDocumentSnapshot(bytes: bytes, identity: identity)
    }
    private static func regular(_ fd: Int32, limit: Int) throws -> NativePrivateFileIdentity {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_mode & 0o777 == 0o600, info.st_nlink == 1, info.st_size >= 0, info.st_size <= limit else {
            throw NativePrivateDocumentError.unavailable
        }
        return NativePrivateFileIdentity(info)
    }
    private static func current(_ root: Directory, name: String, fd: Int32, identity: NativePrivateFileIdentity) throws {
        try root.current()
        var opened = stat(); var named = stat()
        guard fstat(fd, &opened) == 0, fstatat(root.fd, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              NativePrivateFileIdentity(opened) == identity, NativePrivateFileIdentity(named) == identity else {
            throw NativePrivateDocumentError.unavailable
        }
    }
    private static func physicalPath(_ path: String) throws -> String {
        guard !path.utf8.contains(0), let resolved = realpath(path, nil) else { throw NativePrivateDocumentError.unavailable }
        defer { free(resolved) }
        guard let result = String(validatingCString: resolved) else { throw NativePrivateDocumentError.unavailable }
        return result
    }
    private final class Directory {
        let path: String, fd: Int32, device: dev_t, inode: ino_t
        init(_ path: String) throws {
            guard getuid() != 0, getuid() == geteuid(), path.hasPrefix("/"), try physicalPath(path) == path else { throw NativePrivateDocumentError.unavailable }
            let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw NativePrivateDocumentError.unavailable }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o777 == 0o700,
                  info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { _ = Darwin.close(fd); throw NativePrivateDocumentError.unavailable }
            self.path = path; self.fd = fd; device = info.st_dev; inode = info.st_ino
        }
        func current() throws {
            guard try physicalPath(path) == path else { throw NativePrivateDocumentError.unavailable }
            for named in [false, true] {
                var info = stat()
                guard (named ? lstat(path, &info) : fstat(fd, &info)) == 0,
                      info.st_dev == device, info.st_ino == inode, info.st_uid == getuid(),
                      info.st_mode & 0o777 == 0o700, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { throw NativePrivateDocumentError.unavailable }
            }
        }
        func close() { _ = Darwin.close(fd) }
    }
}
