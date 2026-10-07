import Darwin
import Foundation

enum NativeSetupSocketError: Error { case unavailable, expired, invalidRequest }

final class NativeSetupConnection: @unchecked Sendable {
    let descriptor: Int32
    let deadline: UInt64
    private let device: dev_t
    private let inode: ino_t
    private let lock = NSLock()
    private var expired = false
    private var closed = false
    private var completed = false

    init(_ descriptor: Int32, accepted: UInt64) throws {
        self.descriptor = descriptor
        let (deadline, overflow) = accepted.addingReportingOverflow(5_000_000_000)
        var info = stat()
        guard !overflow, fstat(descriptor, &info) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK) else { throw NativeSetupSocketError.unavailable }
        self.deadline = deadline; device = info.st_dev; inode = info.st_ino
        let flags = fcntl(descriptor, F_GETFL)
        let fdFlags = fcntl(descriptor, F_GETFD)
        var noSignal: Int32 = 1
        guard flags >= 0, fdFlags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0,
              fcntl(descriptor, F_SETFD, fdFlags | FD_CLOEXEC) == 0,
              setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw NativeSetupSocketError.unavailable
        }
    }

    deinit { finish() }
    var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return completed }

    func current() throws {
        lock.lock(); defer { lock.unlock() }
        try currentLocked()
    }

    // Shutdown wakes IO and prevents publication, but the active worker keeps
    // its original descriptor until completion. No accepted fd can reuse it.
    func expire() {
        lock.lock(); defer { lock.unlock() }
        if !closed { expired = true; _ = Darwin.shutdown(descriptor, SHUT_RDWR) }
    }

    func finish() {
        lock.lock(); defer { lock.unlock() }
        if !closed { _ = Darwin.close(descriptor); closed = true }
        completed = true
    }

    func readFrame() throws -> Data {
        let header = try receive(4)
        let size = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard size >= 1, size <= 4096 else { throw NativeSetupSocketError.invalidRequest }
        let bytes = try receive(Int(size))
        var extra: UInt8 = 0
        lock.lock(); defer { lock.unlock() }
        try currentLocked()
        let count = recv(descriptor, &extra, 1, MSG_PEEK | MSG_DONTWAIT)
        guard count < 0, errno == EAGAIN else { throw NativeSetupSocketError.invalidRequest }
        return bytes
    }

    func writeFrame(_ bytes: Data) throws {
        guard bytes.count >= 1, bytes.count <= 4096 else { throw NativeSetupSocketError.invalidRequest }
        let size = UInt32(bytes.count)
        var frame = Data([UInt8(size >> 24), UInt8((size >> 16) & 255), UInt8((size >> 8) & 255), UInt8(size & 255)])
        frame.append(bytes)
        var offset = 0
        while offset < frame.count {
            try ready(Int16(POLLOUT))
            lock.lock()
            let count: Int
            do {
                try currentLocked()
                count = frame.withUnsafeBytes { send(descriptor, $0.baseAddress!.advanced(by: offset), frame.count - offset, 0) }
            } catch { lock.unlock(); throw error }
            let failure = errno
            lock.unlock()
            if count < 0 && (failure == EAGAIN || failure == EINTR) { continue }
            guard count > 0 else { throw NativeSetupSocketError.unavailable }
            offset += count
        }
        try current()
    }

    private func receive(_ size: Int) throws -> Data {
        var bytes = Data(count: size)
        var offset = 0
        while offset < size {
            try ready(Int16(POLLIN))
            lock.lock()
            let count: Int
            do {
                try currentLocked()
                count = bytes.withUnsafeMutableBytes { recv(descriptor, $0.baseAddress!.advanced(by: offset), size - offset, 0) }
            } catch { lock.unlock(); throw error }
            let failure = errno
            lock.unlock()
            if count < 0 && (failure == EAGAIN || failure == EINTR) { continue }
            guard count > 0 else { throw NativeSetupSocketError.unavailable }
            offset += count
        }
        return bytes
    }

    private func ready(_ events: Int16) throws {
        while true {
            try current()
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { throw NativeSetupSocketError.expired }
            let milliseconds = Int32(min((deadline - now + 999_999) / 1_000_000, 100))
            var item = pollfd(fd: descriptor, events: events, revents: 0)
            let result = poll(&item, 1, milliseconds)
            if result < 0 && errno == EINTR { continue }
            guard result >= 0, item.revents & Int16(POLLERR | POLLNVAL) == 0 else { throw NativeSetupSocketError.unavailable }
            if result == 0 { continue }
            guard item.revents & events != 0 else { throw NativeSetupSocketError.unavailable }
            try current()
            return
        }
    }

    private func currentLocked() throws {
        guard !expired, DispatchTime.now().uptimeNanoseconds < deadline else { throw NativeSetupSocketError.expired }
        var info = stat()
        guard !closed, fstat(descriptor, &info) == 0,
              info.st_dev == device, info.st_ino == inode,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK) else { throw NativeSetupSocketError.unavailable }
    }
}

// Socket ownership alone authenticates nobody and performs no core/Keychain
// operation. The installed broker separately requires its private release seal.
final class NativeSetupListener {
    private struct Directory {
        let path: String
        let fd: Int32
        let device: dev_t
        let inode: ino_t

        init(_ path: String) throws {
            guard getuid() != 0, getuid() == geteuid(), path.hasPrefix("/"),
                  (try? NativeProtectedInstallation.physicalPath(path)) == path else { throw NativeSetupSocketError.unavailable }
            let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw NativeSetupSocketError.unavailable }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o777 == 0o700,
                  info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
                _ = Darwin.close(fd); throw NativeSetupSocketError.unavailable
            }
            self.path = path; self.fd = fd; device = info.st_dev; inode = info.st_ino
        }

        func current() throws {
            for named in [false, true] {
                var info = stat()
                let status = named ? lstat(path, &info) : fstat(fd, &info)
                guard status == 0, info.st_dev == device, info.st_ino == inode,
                      info.st_uid == getuid(), info.st_mode & 0o777 == 0o700,
                      info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { throw NativeSetupSocketError.unavailable }
            }
        }
    }

    private let data: Directory
    private let ipc: Directory
    private let descriptor: Int32
    private let path: String
    private let device: dev_t
    private let inode: ino_t
    private var closed = false

    init(dataDirectory: URL) throws {
        data = try Directory(dataDirectory.path)
        do {
            let ipcPath = dataDirectory.appendingPathComponent("ipc", isDirectory: true).path
            if mkdirat(data.fd, "ipc", 0o700) != 0 && errno != EEXIST { throw NativeSetupSocketError.unavailable }
            ipc = try Directory(ipcPath)
        } catch { _ = Darwin.close(data.fd); throw error }
        path = ipc.path + "/native-setup.sock"
        let bytes = Array(path.utf8CString)
        var address = sockaddr_un()
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            _ = Darwin.close(ipc.fd); _ = Darwin.close(data.fd); throw NativeSetupSocketError.unavailable
        }
        var existing = stat()
        errno = 0
        guard lstat(path, &existing) != 0, errno == ENOENT else {
            _ = Darwin.close(ipc.fd); _ = Darwin.close(data.fd); throw NativeSetupSocketError.unavailable
        }
        descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            _ = Darwin.close(ipc.fd); _ = Darwin.close(data.fd); throw NativeSetupSocketError.unavailable
        }
        var created: stat?
        let boundDescriptor = descriptor
        do {
            try data.current(); try ipc.current()
            address.sun_family = sa_family_t(AF_UNIX); address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes.map { UInt8(bitPattern: $0) }) }
            let status = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(boundDescriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard status == 0 else { throw NativeSetupSocketError.unavailable }
            var info = stat()
            guard lstat(path, &info) == 0, info.st_uid == getuid(),
                  info.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK) else { throw NativeSetupSocketError.unavailable }
            created = info
            guard chmod(path, 0o600) == 0, listen(descriptor, 4) == 0,
                  fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0,
                  fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else { throw NativeSetupSocketError.unavailable }
            var repeated = stat()
            guard lstat(path, &repeated) == 0, repeated.st_dev == info.st_dev, repeated.st_ino == info.st_ino,
                  repeated.st_mode & 0o777 == 0o600 else { throw NativeSetupSocketError.unavailable }
            try data.current(); try ipc.current()
            device = info.st_dev; inode = info.st_ino
        } catch {
            if let created {
                var now = stat()
                if (try? data.current()) != nil, (try? ipc.current()) != nil,
                   lstat(path, &now) == 0, now.st_dev == created.st_dev, now.st_ino == created.st_ino {
                    _ = unlinkat(ipc.fd, "native-setup.sock", 0)
                }
            }
            _ = Darwin.close(descriptor); _ = Darwin.close(ipc.fd); _ = Darwin.close(data.fd)
            throw error
        }
    }

    deinit { close() }
    var socketPath: String { path }

    func current() throws {
        guard !closed else { throw NativeSetupSocketError.unavailable }
        try data.current(); try ipc.current()
        var info = stat()
        guard lstat(path, &info) == 0, info.st_dev == device, info.st_ino == inode,
              info.st_uid == getuid(), info.st_mode & 0o777 == 0o600,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK) else { throw NativeSetupSocketError.unavailable }
    }

    func accept() throws -> NativeSetupConnection? {
        try current()
        let accepted = DispatchTime.now().uptimeNanoseconds
        let fd = Darwin.accept(descriptor, nil, nil)
        if fd < 0 && (errno == EAGAIN || errno == EINTR) { return nil }
        guard fd >= 0 else { throw NativeSetupSocketError.unavailable }
        do { try current(); return try NativeSetupConnection(fd, accepted: accepted) }
        catch { _ = Darwin.close(fd); throw error }
    }

    func close() {
        guard !closed else { return }
        if (try? current()) != nil { _ = unlinkat(ipc.fd, "native-setup.sock", 0) }
        _ = Darwin.close(descriptor); _ = Darwin.close(ipc.fd); _ = Darwin.close(data.fd)
        closed = true
    }
}
