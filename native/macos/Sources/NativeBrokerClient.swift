import CryptoKit
import Darwin
import Foundation

enum NativeBrokerClientError: LocalizedError {
    case unavailable, signedPairRequired, expired, invalidResponse, rejected(String)
    var errorDescription: String? {
        switch self {
        case .unavailable: "Home setup is unavailable. Check the background service."
        case .signedPairRequired: "Setup requires the signed Home app and agent."
        case .expired: "Setup timed out. Retry the same role to recover its original session."
        case .invalidResponse: "Home returned an invalid setup response."
        case .rejected(let reason):
            switch reason {
            case "keychain_locked": "Unlock your account, then retry Home setup."
            case "keychain_denied": "Home could not access its private credential custody."
            case "keychain_unavailable": "Home credential custody is unavailable."
            case "custody_conflict": "Home custody conflicts with this role. Resolve custody before retrying."
            case "owner_changed": "The Home controller changed. Refresh setup before selecting a role."
            case "outcome_unknown": "Setup is uncertain. Retry the same role to recover the original credential."
            case "capacity": "Home setup is busy. Retry this role shortly."
            case "expired": "Setup timed out. Retry the same role."
            default: "Home setup is unavailable."
            }
        }
    }
}

enum NativeBrokerClient {
    static func defaultSocketPath() throws -> String {
        guard let home = try? NativeCoreEnvironment.userHome() else { throw NativeBrokerClientError.unavailable }
        let directory = URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("Library/Application Support/WoTExHome", isDirectory: true)
        guard let path = try? NativeProtectedInstallation.physicalPath(directory.path) else { throw NativeBrokerClientError.unavailable }
        return path + "/ipc/native-setup.sock"
    }

    static func status() throws -> NativeControllerScope { try status(socketPath: defaultSocketPath()) }
    static func credential(role: NativeCustodyRole) throws -> NativeCredentialRecord {
        try credential(role: role, socketPath: defaultSocketPath())
    }

    // Explicit private paths support inert foreground socket fixtures. They
    // cannot supply a Team/peer seal or bypass actual signed authentication.
    static func status(socketPath: String) throws -> NativeControllerScope {
        try perform(.status, socketPath: socketPath) { try NativeBrokerWire.status($0) }
    }
    static func credential(role: NativeCustodyRole, socketPath: String) throws -> NativeCredentialRecord {
        let record = try perform(.credential(role), socketPath: socketPath) { try NativeBrokerWire.credential($0, role: role) }
        try register(record)
        return record
    }

    static func endpoint(socketPath: String) throws -> NativeCoreEndpointMetadata {
        try perform(.endpoint, socketPath: socketPath) { try NativeBrokerWire.endpoint($0) }
    }

    static func recover(original: NativeOriginalReference) throws -> NativeCredentialRecord {
        try recover(original: original, socketPath: defaultSocketPath())
    }

    static func targetAccess(_ change: NativeTargetChange, lookup: Bool = false) throws -> NativeTargetReply {
        try targetAccess(change, lookup: lookup, socketPath: defaultSocketPath())
    }

    static func targetAccess(_ change: NativeTargetChange, lookup: Bool = false, socketPath: String) throws -> NativeTargetReply {
        let request: NativeBrokerRequest = lookup ? .accessStatus(change.original, change.operation) : .accessChange(change)
        return try perform(request, socketPath: socketPath) { try NativeTargetWire.reply($0, matching: change) }
    }

    static func recover(original: NativeOriginalReference, socketPath: String) throws -> NativeCredentialRecord {
        guard original.valid else { throw NativeBrokerClientError.invalidResponse }
        let record = try perform(.recover(original), socketPath: socketPath) {
            let record = try NativeBrokerWire.credential($0, role: original.receipt.role)
            guard original.accepts(record) else { throw NativeBrokerClientError.invalidResponse }
            return record
        }
        try register(record)
        return record
    }

    private static func register(_ record: NativeCredentialRecord) throws {
        let original = NativeOriginalReference(receipt: record.receipt,
            verifier: NativeCoreWire.hex(Data(SHA256.hash(data: record.bytes))))
        let reference = try NativeBrokerWire.request(.recover(original))
        try OperatorCredential.retainNativeRequestGuard(record.bytes, reference: reference) { descriptor, deadline in
            let lease = try open(.endpoint, socketPath: defaultSocketPath(), deadline: deadline)
            do {
                let metadata = try NativeBrokerWire.endpoint(lease.response)
                guard original.matches(metadata.scope),
                      try SignedSetupPeer.auditToken(descriptor) == metadata.auditToken else {
                    throw LocalHealthError.wrongPeer
                }
                try lease.current()
                return lease
            } catch {
                lease.finish()
                throw error
            }
        }
    }

    private struct PathIdentity: Equatable, Sendable {
        let device: dev_t
        let inode: ino_t
        init(_ path: String, type: mode_t, mode: mode_t) throws {
            var info = stat()
            guard lstat(path, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o777 == mode,
                  info.st_mode & mode_t(S_IFMT) == type else { throw NativeBrokerClientError.unavailable }
            device = info.st_dev; inode = info.st_ino
        }
    }

    private static func perform<T>(_ request: NativeBrokerRequest, socketPath: String,
                                   decode: (Data) throws -> T) throws -> T {
        let lease = try open(request, socketPath: socketPath)
        defer { lease.finish() }
        do {
            let value = try decode(lease.response)
            try lease.current()
            return value
        } catch { throw mapped(error) }
    }

    private final class ReplyLease: NativeAPIRequestLease, @unchecked Sendable {
        let response: Data
        private let connection: NativeSetupConnection
        private let peer: NativeSetupPeerSeal
        private let currentPath: @Sendable () throws -> Void
        init(response: Data, connection: NativeSetupConnection, peer: NativeSetupPeerSeal,
             currentPath: @escaping @Sendable () throws -> Void) {
            self.response = response; self.connection = connection; self.peer = peer; self.currentPath = currentPath
        }
        deinit { finish() }
        func current() throws {
            do {
                try connection.current(); try currentPath()
                try SignedSetupPeer.current(connection.descriptor, seal: peer, as: .app)
                try connection.current(); try currentPath()
            } catch { throw NativeBrokerClient.mapped(error) }
        }
        func finish() { connection.finish() }
    }

    private static func open(_ request: NativeBrokerRequest, socketPath: String,
                             deadline requestedDeadline: UInt64? = nil) throws -> ReplyLease {
        let started = DispatchTime.now().uptimeNanoseconds
        let deadline = min(started + 5_000_000_000, requestedDeadline ?? UInt64.max)
        guard deadline > started, deadline >= 5_000_000_000 else { throw NativeBrokerClientError.expired }
        let suffix = "/ipc/native-setup.sock"
        guard socketPath.hasSuffix(suffix) else { throw NativeBrokerClientError.unavailable }
        let root = String(socketPath.dropLast(suffix.count))
        let ipc = root + "/ipc"
        guard getuid() != 0, getuid() == geteuid(), socketPath == ipc + "/native-setup.sock",
              (try? NativeProtectedInstallation.physicalPath(root)) == root else { throw NativeBrokerClientError.unavailable }
        let rootID = try PathIdentity(root, type: mode_t(S_IFDIR), mode: 0o700)
        let ipcID = try PathIdentity(ipc, type: mode_t(S_IFDIR), mode: 0o700)
        let socketID = try PathIdentity(socketPath, type: mode_t(S_IFSOCK), mode: 0o600)
        let currentPath: @Sendable () throws -> Void = {
            guard try PathIdentity(root, type: mode_t(S_IFDIR), mode: 0o700) == rootID,
                  try PathIdentity(ipc, type: mode_t(S_IFDIR), mode: 0o700) == ipcID,
                  try PathIdentity(socketPath, type: mode_t(S_IFSOCK), mode: 0o600) == socketID else {
                throw NativeBrokerClientError.unavailable
            }
        }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NativeBrokerClientError.unavailable }
        let connection: NativeSetupConnection
        do { connection = try NativeSetupConnection(fd, accepted: deadline - 5_000_000_000) }
        catch { _ = Darwin.close(fd); throw NativeBrokerClientError.unavailable }
        do {
            var address = sockaddr_un()
            let bytes = Array(socketPath.utf8CString)
            guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw NativeBrokerClientError.unavailable }
            address.sun_family = sa_family_t(AF_UNIX); address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes.map { UInt8(bitPattern: $0) }) }
            try connection.current(); try currentPath()
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            if result != 0 {
                guard errno == EINPROGRESS || errno == EAGAIN else { throw NativeBrokerClientError.unavailable }
                try connection.awaitConnect()
            }
            try connection.current(); try currentPath()
            let peer = try SignedSetupPeer.connected(fd, as: .app)
            try connection.current(); try currentPath()
            try SignedSetupPeer.current(fd, seal: peer, as: .app)
            try connection.writeFrame(NativeBrokerWire.request(request))
            let response = try connection.readFrame(allowEOF: true)
            try SignedSetupPeer.current(fd, seal: peer, as: .app)
            try connection.current(); try currentPath()
            if let reason = try? NativeBrokerWire.error(response) { throw NativeBrokerClientError.rejected(reason) }
            let lease = ReplyLease(response: response, connection: connection, peer: peer, currentPath: currentPath)
            try lease.current()
            return lease
        } catch {
            connection.finish()
            throw mapped(error)
        }
    }

    private static func mapped(_ error: Error) -> Error {
        switch error {
        case let error as NativeBrokerClientError: return error
        case NativeSetupPeerError.expired, NativeSetupSocketError.expired: return NativeBrokerClientError.expired
        case is NativeSetupPeerError: return NativeBrokerClientError.signedPairRequired
        case is NativeSetupWireError: return NativeBrokerClientError.invalidResponse
        default: return NativeBrokerClientError.unavailable
        }
    }
}
