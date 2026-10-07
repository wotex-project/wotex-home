import Darwin
import Foundation

enum NativeCoreConnectionError: Error {
    case capacity, expired, unavailable, outcomeUnknown, ownerChanged, custodyConflict
}

enum NativeCoreEnvironment {
    static func values(dataDirectory: URL) throws -> [String: String] {
        guard dataDirectory.path.hasPrefix("/") else { throw NativeCoreConnectionError.unavailable }
        var environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": try userHome(),
            "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8",
            "WOTEX_HOME_DATA_DIR": dataDirectory.path, "RELEASE_DISTRIBUTION": "none",
        ]
        let preference = try NativeNetworkPreferences.load(directory: dataDirectory)
        if let interface = preference.record.interface { environment["WOTEX_HOME_LIFX_INTERFACE"] = interface }
        return environment
    }

    static func userHome() throws -> String {
        guard getuid() != 0, getuid() == geteuid() else {
            throw NativeCoreConnectionError.unavailable
        }
        var entry = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 16_384)
        let homePath = buffer.withUnsafeMutableBufferPointer { bytes -> String? in
            guard getpwuid_r(getuid(), &entry, bytes.baseAddress, bytes.count, &result) == 0,
                  result != nil, let home = entry.pw_dir else { return nil }
            return String(validatingCString: home)
        }
        guard let homePath, homePath.hasPrefix("/"),
              homePath.utf8.count <= 4096 else { throw NativeCoreConnectionError.unavailable }
        return homePath
    }
}

// Owns one actual child and its original anonymous endpoints. It conveys no
// socket authentication or Keychain proof. The installed caller must first
// validate the fixed bundle; fixtures can exercise this transport in isolation.
final class NativeCoreConnection: @unchecked Sendable {
    private struct PipeIdentity: Equatable {
        let device: dev_t
        let inode: ino_t

        init(_ fd: Int32) throws {
            var info = stat()
            guard fstat(fd, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFIFO) else {
                throw NativeCoreConnectionError.unavailable
            }
            device = info.st_dev; inode = info.st_ino
        }
    }

    private let child: Process
    private let dataDirectory: URL
    private let input: FileHandle
    private let output: FileHandle
    private let inputIdentity: PipeIdentity
    private let outputIdentity: PipeIdentity
    private let lock = NSLock()
    private var ended = false
    private var launched = false
    private var inputClosed = false
    private var outputClosed = false

    // Only trusted host composition supplies a release path. Socket records
    // cannot choose these arguments or environment. A development fixture may
    // supply an executable shim for the same constant release invocation.
    init(release: URL, dataDirectory: URL) throws {
        self.dataDirectory = dataDirectory
        let process = Process()
        let incoming = Pipe()
        let outgoing = Pipe()
        process.executableURL = release
        process.arguments = ["eval", "WotexHome.NativeSetup.CoreHost.main()"]
        process.environment = try NativeCoreEnvironment.values(dataDirectory: dataDirectory)
        process.standardInput = incoming
        process.standardOutput = outgoing
        process.standardError = FileHandle.standardError
        input = incoming.fileHandleForWriting
        output = outgoing.fileHandleForReading
        child = process
        inputIdentity = try PipeIdentity(input.fileDescriptor)
        outputIdentity = try PipeIdentity(output.fileDescriptor)
        do {
            for fd in [input.fileDescriptor, output.fileDescriptor] {
                let flags = fcntl(fd, F_GETFL)
                guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
                    throw NativeCoreConnectionError.unavailable
                }
                let descriptorFlags = fcntl(fd, F_GETFD)
                guard descriptorFlags >= 0, fcntl(fd, F_SETFD, descriptorFlags | FD_CLOEXEC) == 0 else {
                    throw NativeCoreConnectionError.unavailable
                }
            }
            guard fcntl(input.fileDescriptor, F_SETNOSIGPIPE, 1) == 0,
                  fcntl(input.fileDescriptor, F_GETNOSIGPIPE) == 1 else {
                throw NativeCoreConnectionError.unavailable
            }
            try process.run()
            launched = true
            // Foundation duplicates child endpoints. Close our unused ends so
            // parent EOF and child EOF retain their actual ownership meaning.
            try incoming.fileHandleForReading.close()
            try outgoing.fileHandleForWriting.close()
        } catch {
            _ = closeLocked()
            throw NativeCoreConnectionError.unavailable
        }
    }

    deinit { _ = close() }
    var childIsRunning: Bool { child.isRunning }

    func identity(deadline: UInt64) throws -> NativeControllerScope {
        try exchange(body: NativeCoreWire.identityRequest(), deadline: deadline, mayCommit: false) {
            try NativeCoreWire.identity($0)
        }
    }

    func ensure(scope: NativeControllerScope, role: NativeCustodyRole, verifier: Data,
                deadline: UInt64) throws -> NativeCreationReceipt {
        try exchange(body: NativeCoreWire.ensureRequest(scope, role: role, verifier: verifier),
                     deadline: deadline, mayCommit: true) {
            try NativeCoreWire.receipt($0, scope: scope, role: role)
        }
    }

    func existing(original: NativeOriginalReference, scope: NativeControllerScope,
                  deadline: UInt64) throws -> NativeCreationReceipt {
        guard original.matches(scope) else { throw NativeCoreConnectionError.ownerChanged }
        return try exchange(body: NativeCoreWire.existingRequest(original), deadline: deadline, mayCommit: false) {
            try NativeCoreWire.originalReceipt($0, scope: scope, original: original)
        }
    }

    func targetAccess(request: NativeBrokerRequest, original: NativeOriginalReference, operation: String,
                      mayCommit: Bool, deadline: UInt64) throws -> Data {
        guard original.valid, original.receipt.role == .operator else { throw NativeSetupWireError.invalidRecord }
        switch request {
        case .accessChange(let change):
            guard mayCommit, change.original == original, change.operation == operation else { throw NativeSetupWireError.invalidRecord }
        case .accessStatus(let reference, let identifier):
            guard !mayCommit, reference == original, identifier == operation else { throw NativeSetupWireError.invalidRecord }
        default: throw NativeSetupWireError.invalidRecord
        }
        return try exchange(body: NativeBrokerWire.request(request), deadline: deadline, mayCommit: mayCommit) {
            _ = try NativeTargetWire.reply($0, original: original, operation: operation)
            return $0
        }
    }

    // Correlates a kernel peer only with the already owned original child.
    // This method sends no bytes and authenticates no native app/agent signer.
    func endpointAuditToken(deadline requested: UInt64) throws -> Data {
        guard lock.try() else { throw NativeCoreConnectionError.capacity }
        defer { lock.unlock() }
        let now = DispatchTime.now().uptimeNanoseconds
        let (cap, overflow) = now.addingReportingOverflow(5_000_000_000)
        guard !overflow, requested > now else { throw NativeCoreConnectionError.expired }
        let deadline = min(requested, cap)
        try current(deadline); try quiet()
        let root = dataDirectory.path
        let pins = try [EndpointPin(root, type: mode_t(S_IFDIR), mode: 0o700),
                        EndpointPin(root + "/ipc", type: mode_t(S_IFDIR), mode: 0o700),
                        EndpointPin(root + "/ipc/home.sock", type: mode_t(S_IFSOCK), mode: 0o600)]
        for pin in pins { try pin.current() }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NativeCoreConnectionError.unavailable }
        defer { _ = Darwin.close(fd) }
        let flags = fcntl(fd, F_GETFL)
        let descriptorFlags = fcntl(fd, F_GETFD)
        guard flags >= 0, descriptorFlags >= 0,
              fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0,
              fcntl(fd, F_SETFD, descriptorFlags | FD_CLOEXEC) == 0 else { throw NativeCoreConnectionError.unavailable }
        var address = sockaddr_un()
        let path = root + "/ipc/home.sock"
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw NativeCoreConnectionError.unavailable }
        address.sun_family = sa_family_t(AF_UNIX); address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes.map { UInt8(bitPattern: $0) }) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connected != 0 {
            guard errno == EINPROGRESS || errno == EAGAIN else { throw NativeCoreConnectionError.unavailable }
            try ready(fd, events: Int16(POLLOUT), deadline: deadline)
            var error: Int32 = 0; var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0,
                  length == MemoryLayout<Int32>.size, error == 0 else { throw NativeCoreConnectionError.unavailable }
        }
        let token = try ownedEndpoint(fd, deadline: deadline)
        for pin in pins { try pin.current() }
        guard try ownedEndpoint(fd, deadline: deadline) == token else { throw NativeCoreConnectionError.unavailable }
        try quiet(); try current(deadline)
        return token
    }

    private func ownedEndpoint(_ fd: Int32, deadline: UInt64) throws -> Data {
        try current(deadline); try quiet()
        var uid: uid_t = 0; var gid: gid_t = 0
        var pid: pid_t = 0; var pidLength = socklen_t(MemoryLayout<pid_t>.size)
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid(),
              getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &pidLength) == 0,
              pidLength == MemoryLayout<pid_t>.size, pid == child.processIdentifier else { throw NativeCoreConnectionError.unavailable }
        var words = [UInt32](repeating: 0, count: 8); var length = socklen_t(32)
        let status = words.withUnsafeMutableBytes { getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, $0.baseAddress, &length) }
        guard status == 0, length == 32 else { throw NativeCoreConnectionError.unavailable }
        try current(deadline); try quiet()
        return words.withUnsafeBytes { Data($0) }
    }

    private struct EndpointPin {
        let path: String, type: mode_t, mode: mode_t, device: dev_t, inode: ino_t
        init(_ path: String, type: mode_t, mode: mode_t) throws {
            guard let resolved = realpath(path, nil) else { throw NativeCoreConnectionError.unavailable }
            defer { free(resolved) }
            guard String(validatingCString: resolved) == path else { throw NativeCoreConnectionError.unavailable }
            var info = stat()
            guard lstat(path, &info) == 0, info.st_uid == getuid(), info.st_mode & mode_t(S_IFMT) == type,
                  info.st_mode & 0o777 == mode else { throw NativeCoreConnectionError.unavailable }
            self.path = path; self.type = type; self.mode = mode; device = info.st_dev; inode = info.st_ino
        }
        func current() throws {
            let current = try Self(path, type: type, mode: mode)
            guard current.device == device, current.inode == inode else { throw NativeCoreConnectionError.unavailable }
        }
    }

    // Close can wait only for the one bounded transaction, never a waiter pool.
    // Failed reaping keeps this owner ended; it can never restart another child.
    @discardableResult
    func close() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return closeLocked()
    }

    private func exchange<T>(body: Data, deadline requested: UInt64, mayCommit: Bool,
                             decode: (Data) throws -> T) throws -> T {
        guard lock.try() else { throw NativeCoreConnectionError.capacity }
        defer { lock.unlock() }
        guard !ended else { throw NativeCoreConnectionError.unavailable }
        let now = DispatchTime.now().uptimeNanoseconds
        let (cap, overflow) = now.addingReportingOverflow(5_000_000_000)
        guard !overflow, requested > now else { throw NativeCoreConnectionError.expired }
        let deadline = min(requested, cap)
        var started = false
        do {
            try current(deadline)
            try quiet()
            let length = UInt32(body.count)
            var frame = Data([UInt8(length >> 24), UInt8((length >> 16) & 255),
                              UInt8((length >> 8) & 255), UInt8(length & 255)])
            frame.append(body)
            try send(frame, deadline: deadline, started: &started)
            let header = try receive(4, deadline: deadline)
            let size = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard size >= 1, size <= 4096 else { throw NativeCoreConnectionError.unavailable }
            let reply = try receive(Int(size), deadline: deadline)
            try current(deadline)
            try quiet()
            if let reason = try? NativeCoreWire.error(reply) {
                switch reason {
                case "native_owner_changed": throw NativeCoreConnectionError.ownerChanged
                case "native_custody_conflict": throw NativeCoreConnectionError.custodyConflict
                case "outcome_unknown": throw NativeCoreConnectionError.outcomeUnknown
                default: throw NativeCoreConnectionError.unavailable
                }
            }
            let value = try decode(reply)
            try current(deadline)
            return value
        } catch let error as NativeCoreConnectionError
            where error == .ownerChanged || error == .custodyConflict {
            // These closed policy failures leave the original core available.
            throw error
        } catch {
            _ = closeLocked()
            if mayCommit && started { throw NativeCoreConnectionError.outcomeUnknown }
            throw NativeCoreConnectionError.unavailable
        }
    }

    private func current(_ deadline: UInt64) throws {
        guard DispatchTime.now().uptimeNanoseconds < deadline else { throw NativeCoreConnectionError.expired }
        guard !ended, !inputClosed, !outputClosed, child.isRunning,
              try PipeIdentity(input.fileDescriptor) == inputIdentity,
              try PipeIdentity(output.fileDescriptor) == outputIdentity else {
            throw NativeCoreConnectionError.unavailable
        }
    }

    private func ready(_ fd: Int32, events: Int16, deadline: UInt64) throws {
        while true {
            try current(deadline)
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { throw NativeCoreConnectionError.expired }
            let left = deadline - now
            let milliseconds = Int32(min((left + 999_999) / 1_000_000, 100))
            var item = pollfd(fd: fd, events: events, revents: 0)
            let result = poll(&item, 1, milliseconds)
            if result < 0 && errno == EINTR { continue }
            guard result >= 0, item.revents & Int16(POLLERR | POLLNVAL) == 0 else {
                throw NativeCoreConnectionError.unavailable
            }
            if result == 0 { continue }
            guard item.revents & events != 0 else { throw NativeCoreConnectionError.unavailable }
            try current(deadline)
            return
        }
    }

    private func send(_ bytes: Data, deadline: UInt64, started: inout Bool) throws {
        var offset = 0
        while offset < bytes.count {
            try ready(input.fileDescriptor, events: Int16(POLLOUT), deadline: deadline)
            let count = bytes.withUnsafeBytes {
                Darwin.write(input.fileDescriptor, $0.baseAddress!.advanced(by: offset), bytes.count - offset)
            }
            if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            guard count > 0 else { throw NativeCoreConnectionError.unavailable }
            started = true; offset += count
        }
    }

    private func quiet() throws {
        var item = pollfd(fd: output.fileDescriptor, events: Int16(POLLIN), revents: 0)
        var result: Int32
        repeat { result = poll(&item, 1, 0) } while result < 0 && errno == EINTR
        guard result == 0, item.revents == 0 else { throw NativeCoreConnectionError.unavailable }
    }

    private func receive(_ size: Int, deadline: UInt64) throws -> Data {
        var bytes = Data(count: size)
        var offset = 0
        while offset < size {
            try ready(output.fileDescriptor, events: Int16(POLLIN), deadline: deadline)
            let count = bytes.withUnsafeMutableBytes {
                Darwin.read(output.fileDescriptor, $0.baseAddress!.advanced(by: offset), size - offset)
            }
            if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            guard count > 0 else { throw NativeCoreConnectionError.unavailable }
            offset += count
        }
        return bytes
    }

    private func closeLocked() -> Bool {
        ended = true
        if !inputClosed { try? input.close(); inputClosed = true }
        if child.isRunning {
            wait(milliseconds: 2000)
            if child.isRunning { child.terminate(); wait(milliseconds: 1000) }
            if child.isRunning { _ = kill(child.processIdentifier, SIGKILL); wait(milliseconds: 1000) }
        }
        if !outputClosed { try? output.close(); outputClosed = true }
        guard !child.isRunning else { return false }
        if launched { child.waitUntilExit() }
        return true
    }

    private func wait(milliseconds: UInt64) {
        let deadline = DispatchTime.now().uptimeNanoseconds + milliseconds * 1_000_000
        while child.isRunning && DispatchTime.now().uptimeNanoseconds < deadline { usleep(10_000) }
    }
}
