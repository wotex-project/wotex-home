import Darwin
import Foundation

enum NativeCoreConnectionError: Error {
    case capacity, expired, unavailable, outcomeUnknown, ownerChanged, custodyConflict
}

enum NativeCoreEnvironment {
    static func values(dataDirectory: URL) throws -> [String: String] {
        guard getuid() != 0, getuid() == geteuid(), dataDirectory.path.hasPrefix("/") else {
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
        return [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": homePath,
            "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8",
            "WOTEX_HOME_DATA_DIR": dataDirectory.path, "RELEASE_DISTRIBUTION": "none",
        ]
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
