import Darwin
import Foundation
import Security

private final class CertificateClockDescriptor: @unchecked Sendable {
    let fd: Int32
    init(_ fd: Int32) { self.fd = fd }
    deinit { Darwin.close(fd) }
}

private struct CertificateClockFileIdentity: Equatable {
    let device: dev_t, inode: ino_t, owner: uid_t, mode: mode_t, links: nlink_t, size: off_t
    let modified: timespec, changed: timespec
    init(_ s: stat) {
        device = s.st_dev; inode = s.st_ino; owner = s.st_uid; mode = s.st_mode; links = s.st_nlink; size = s.st_size
        modified = s.st_mtimespec; changed = s.st_ctimespec
    }
    static func == (a: Self, b: Self) -> Bool {
        a.device == b.device && a.inode == b.inode && a.owner == b.owner && a.mode == b.mode &&
        a.links == b.links && a.size == b.size && a.modified.tv_sec == b.modified.tv_sec &&
        a.modified.tv_nsec == b.modified.tv_nsec && a.changed.tv_sec == b.changed.tv_sec && a.changed.tv_nsec == b.changed.tv_nsec
    }
}

private enum CertificateClockPaths {
    static func physical(_ path: String) throws -> String {
        guard path.hasPrefix("/"), path.utf8.count <= 4096, !path.utf8.contains(0), let p = realpath(path, nil) else {
            throw NativeCertificateClockError.custodyConflict
        }
        defer { free(p) }
        guard let value = String(validatingCString: p), value == path else { throw NativeCertificateClockError.custodyConflict }
        return value
    }
    static func acl(_ path: String) throws -> Data {
        errno = 0
        guard let value = acl_get_link_np(path, ACL_TYPE_EXTENDED) else {
            guard errno == ENOENT else { throw NativeCertificateClockError.custodyConflict }
            return Data()
        }
        defer { acl_free(UnsafeMutableRawPointer(value)) }
        guard acl_valid(value) == 0 else { throw NativeCertificateClockError.custodyConflict }
        var ended = false
        for index in 0..<170 {
            var item: acl_entry_t?; errno = 0
            if acl_get_entry(value, Int32(index), &item) != 0 {
                guard errno == EINVAL else { throw NativeCertificateClockError.custodyConflict }
                ended = true; break
            }
            guard let item else { throw NativeCertificateClockError.custodyConflict }
            var tag = ACL_UNDEFINED_TAG
            guard acl_get_tag_type(item, &tag) == 0 else { throw NativeCertificateClockError.custodyConflict }
            if tag == ACL_EXTENDED_DENY { continue }
            guard tag == ACL_EXTENDED_ALLOW else { throw NativeCertificateClockError.custodyConflict }
            var permissions: acl_permset_t?
            guard acl_get_permset(item, &permissions) == 0, let permissions else { throw NativeCertificateClockError.custodyConflict }
            for permission in [ACL_WRITE_DATA, ACL_APPEND_DATA, ACL_DELETE, ACL_DELETE_CHILD,
                               ACL_WRITE_ATTRIBUTES, ACL_WRITE_EXTATTRIBUTES, ACL_WRITE_SECURITY, ACL_CHANGE_OWNER] {
                guard acl_get_perm_np(permissions, permission) == 0 else { throw NativeCertificateClockError.custodyConflict }
            }
        }
        let size = acl_size(value)
        guard ended, size > 0, size <= 65_536 else { throw NativeCertificateClockError.custodyConflict }
        var bytes = Data(count: size)
        let copied = bytes.withUnsafeMutableBytes { acl_copy_ext($0.baseAddress, value, size) }
        guard copied == size else { throw NativeCertificateClockError.custodyConflict }
        return bytes
    }
}

// Unsealed file mechanics. A supplied directory/runtime can exercise private
// custody, but cannot install a production source or create its TLS clock.
final class NativeCertificateClockDirectory: @unchecked Sendable {
    private struct Ancestor: Equatable {
        let path: String, device: dev_t, inode: ino_t, owner: uid_t, mode: mode_t, acl: Data
        init(_ path: String, temporaryFixture: Bool) throws {
            var s = stat()
            guard lstat(path, &s) == 0, s.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
                  s.st_uid == 0 || s.st_uid == getuid() else { throw NativeCertificateClockError.custodyConflict }
            let stickyFixture = temporaryFixture && s.st_uid == 0 && s.st_mode & mode_t(S_ISVTX) != 0
            guard s.st_mode & 0o022 == 0 || stickyFixture else { throw NativeCertificateClockError.custodyConflict }
            self.path = path; device = s.st_dev; inode = s.st_ino; owner = s.st_uid; mode = s.st_mode
            acl = try CertificateClockPaths.acl(path)
        }
    }
    let url: URL
    private let descriptor: CertificateClockDescriptor
    var fd: Int32 { descriptor.fd }
    private let ancestors: [Ancestor]
    let temporaryFixture: Bool
    init(_ url: URL, temporaryFixture: Bool = false) throws {
        guard getuid() != 0, getuid() == geteuid(), url.isFileURL, url.path == (try CertificateClockPaths.physical(url.path)) else {
            throw NativeCertificateClockError.custodyConflict
        }
        var paths: [Ancestor] = [], current = url
        while true {
            guard paths.count < 64 else { throw NativeCertificateClockError.custodyConflict }
            paths.append(try Ancestor(current.path, temporaryFixture: temporaryFixture))
            if current.path == "/" { break }; current.deleteLastPathComponent()
        }
        guard paths[0].owner == getuid(), paths[0].mode & 0o7777 == 0o700 else { throw NativeCertificateClockError.custodyConflict }
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw NativeCertificateClockError.custodyConflict }
        descriptor = CertificateClockDescriptor(fd)
        self.url = url; ancestors = paths; self.temporaryFixture = temporaryFixture
        try check()
    }
    func check() throws {
        _ = try CertificateClockPaths.physical(url.path)
        for original in ancestors {
            guard try Ancestor(original.path, temporaryFixture: temporaryFixture) == original else { throw NativeCertificateClockError.custodyConflict }
        }
        var s = stat()
        guard fstat(fd, &s) == 0, s.st_dev == ancestors[0].device, s.st_ino == ancestors[0].inode,
              s.st_uid == getuid(), s.st_mode & 0o7777 == 0o700 else { throw NativeCertificateClockError.custodyConflict }
    }
    func child(_ name: String) throws -> NativeCertificateClockDirectory {
        try check()
        guard NativeControllerPairingWire.id(name), mkdirat(fd, name, 0o700) == 0 else { throw NativeCertificateClockError.custodyConflict }
        guard fsync(fd) == 0 else { throw NativeCertificateClockError.outcomeUnknown }
        try check()
        return try NativeCertificateClockDirectory(url.appendingPathComponent(name, isDirectory: true), temporaryFixture: temporaryFixture)
    }
    static func production() throws -> NativeCertificateClockDirectory {
        guard let account = try NativePrivateDocuments.directory(create: false) else { throw NativeCertificateClockError.custodyConflict }
        let parent = try NativeCertificateClockDirectory(account)
        try parent.check()
        let made = mkdirat(parent.fd, "certificate-clock", 0o700)
        guard made == 0 || errno == EEXIST else { throw NativeCertificateClockError.custodyConflict }
        if made == 0, fsync(parent.fd) != 0 { throw NativeCertificateClockError.outcomeUnknown }
        try parent.check()
        return try NativeCertificateClockDirectory(account.appendingPathComponent("certificate-clock", isDirectory: true))
    }
}

final class NativeCertificateClockFile: @unchecked Sendable, CustomReflectable {
    let directory: NativeCertificateClockDirectory, name: String, bytes: Data
    private let descriptor: CertificateClockDescriptor
    private var fd: Int32 { descriptor.fd }
    private let identity: CertificateClockFileIdentity, acl: Data
    var url: URL { directory.url.appendingPathComponent(name) }
    var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
    init(directory: NativeCertificateClockDirectory, name: String) throws {
        try directory.check()
        guard Self.nameAllowed(name) else { throw NativeCertificateClockError.custodyConflict }
        let fd = openat(directory.fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw NativeCertificateClockError.custodyConflict }
        let descriptor = CertificateClockDescriptor(fd)
        do {
            var s = stat()
            guard fstat(fd, &s) == 0, s.st_uid == getuid(), s.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  s.st_mode & 0o7777 == 0o400, s.st_nlink == 1, (1...4096).contains(s.st_size) else { throw NativeCertificateClockError.custodyConflict }
            self.directory = directory; self.name = name; self.descriptor = descriptor; identity = CertificateClockFileIdentity(s)
            acl = try CertificateClockPaths.acl(directory.url.appendingPathComponent(name).path)
            bytes = try Self.read(fd, count: Int(s.st_size))
            try check()
        } catch { throw error }
    }
    func check() throws {
        try directory.check()
        var opened = stat(), named = stat()
        guard fstat(fd, &opened) == 0, fstatat(directory.fd, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              CertificateClockFileIdentity(opened) == identity, CertificateClockFileIdentity(named) == identity,
              try CertificateClockPaths.acl(url.path) == acl, try Self.read(fd, count: Int(identity.size)) == bytes else {
            throw NativeCertificateClockError.custodyConflict
        }
        try directory.check()
        guard fstat(fd, &opened) == 0, fstatat(directory.fd, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              CertificateClockFileIdentity(opened) == identity, CertificateClockFileIdentity(named) == identity else {
            throw NativeCertificateClockError.custodyConflict
        }
    }
    private static func read(_ fd: Int32, count: Int) throws -> Data {
        let capacity = count + 1
        var bytes = Data(count: capacity), offset = 0
        while offset < capacity {
            let received = bytes.withUnsafeMutableBytes { pread(fd, $0.baseAddress!.advanced(by: offset), capacity - offset, off_t(offset)) }
            if received < 0 && errno == EINTR { continue }
            guard received >= 0 else { throw NativeCertificateClockError.custodyConflict }
            if received == 0 { break }; offset += received
        }
        guard offset == count else { throw NativeCertificateClockError.custodyConflict }
        return bytes.prefix(count)
    }
    private static func nameAllowed(_ name: String) -> Bool {
        (1...255).contains(name.utf8.count) && ![".", ".."].contains(name) && !name.utf8.contains(0) && !name.contains("/")
    }
    static func publish(_ bytes: Data, directory: NativeCertificateClockDirectory, name: String,
                        check: () throws -> Void) throws -> NativeCertificateClockFile {
        guard (1...4096).contains(bytes.count), nameAllowed(name) else { throw NativeCertificateClockError.invalidDocument }
        try check(); try directory.check()
        let fd = openat(directory.fd, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o400)
        guard fd >= 0 else { throw NativeCertificateClockError.custodyConflict }
        defer { Darwin.close(fd) }
        do {
            var offset = 0
            while offset < bytes.count {
                try check(); try directory.check()
                let written = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: offset), bytes.count - offset) }
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw NativeCertificateClockError.outcomeUnknown }; offset += written
            }
            guard fsync(fd) == 0, fsync(directory.fd) == 0 else { throw NativeCertificateClockError.outcomeUnknown }
            try check(); try directory.check()
            let result = try NativeCertificateClockFile(directory: directory, name: name)
            var opened = stat(), named = stat()
            guard fstat(fd, &opened) == 0, fstatat(directory.fd, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
                  CertificateClockFileIdentity(opened) == CertificateClockFileIdentity(named), result.bytes == bytes else {
                throw NativeCertificateClockError.outcomeUnknown
            }
            try check(); try result.check()
            return result
        } catch { throw NativeCertificateClockError.outcomeUnknown }
    }
}

struct NativeCertificateClockCustody: Sendable, CustomReflectable {
    let root: NativeCertificateClockDirectory, policy: NativeCertificateClockFile, request: NativeCertificateClockFile
    let start: ContinuousClock.Instant, wall: Int64
    var digest: String { NativeCertificateClockWire.hash(request.bytes) }
    var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
    func check() throws { try root.check(); try policy.check(); try request.check() }
    static func begin(root: NativeCertificateClockDirectory, runtime: String, check: () throws -> Void) throws -> Self {
        try check(); try root.check()
        guard flock(root.fd, LOCK_EX | LOCK_NB) == 0 else { throw NativeCertificateClockError.capacity }
        defer { _ = flock(root.fd, LOCK_UN) }
        let policy = try NativeCertificateClockFile(directory: root, name: "policy.json")
        let value = try NativeCertificateClockPolicy.decode(policy.bytes)
        guard value.runtime == runtime else { throw NativeCertificateClockError.scopeConflict }
        guard try FileManager.default.contentsOfDirectory(atPath: root.url.path).count < 64 else { throw NativeCertificateClockError.capacity }
        var challenge = Data(count: 32)
        guard challenge.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }) == errSecSuccess else {
            throw NativeCertificateClockError.clockUnavailable
        }
        let request = try NativeCertificateClockRequest(runtime: runtime, challenge: challenge,
            policyDigest: NativeCertificateClockWire.hash(policy.bytes)).encoded()
        let start = ContinuousClock.now, wall = try NativeCertificateClockGeneration.wallMilliseconds()
        try check(); try policy.check()
        let child = try root.child("request-" + UUID().uuidString.lowercased())
        let file = try NativeCertificateClockFile.publish(request, directory: child, name: "request.json") {
            try check(); try root.check(); try policy.check()
        }
        guard try FileManager.default.contentsOfDirectory(atPath: root.url.path).count <= 64 else { throw NativeCertificateClockError.capacity }
        let result = Self(root: root, policy: policy, request: file, start: start, wall: wall)
        try check(); try result.check()
        return result
    }
}
