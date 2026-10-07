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
        try perform(.credential(role), socketPath: socketPath) { try NativeBrokerWire.credential($0, role: role) }
    }

    private struct PathIdentity: Equatable {
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
        let started = DispatchTime.now().uptimeNanoseconds
        let suffix = "/ipc/native-setup.sock"
        guard socketPath.hasSuffix(suffix) else { throw NativeBrokerClientError.unavailable }
        let root = String(socketPath.dropLast(suffix.count))
        let ipc = root + "/ipc"
        guard getuid() != 0, getuid() == geteuid(), socketPath == ipc + "/native-setup.sock",
              (try? NativeProtectedInstallation.physicalPath(root)) == root else { throw NativeBrokerClientError.unavailable }
        let rootID = try PathIdentity(root, type: mode_t(S_IFDIR), mode: 0o700)
        let ipcID = try PathIdentity(ipc, type: mode_t(S_IFDIR), mode: 0o700)
        let socketID = try PathIdentity(socketPath, type: mode_t(S_IFSOCK), mode: 0o600)
        func currentPath() throws {
            guard try PathIdentity(root, type: mode_t(S_IFDIR), mode: 0o700) == rootID,
                  try PathIdentity(ipc, type: mode_t(S_IFDIR), mode: 0o700) == ipcID,
                  try PathIdentity(socketPath, type: mode_t(S_IFSOCK), mode: 0o600) == socketID else {
                throw NativeBrokerClientError.unavailable
            }
        }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NativeBrokerClientError.unavailable }
        let connection: NativeSetupConnection
        do { connection = try NativeSetupConnection(fd, accepted: started) }
        catch { _ = Darwin.close(fd); throw NativeBrokerClientError.unavailable }
        defer { connection.finish() }
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
            let value = try decode(response)
            try SignedSetupPeer.current(fd, seal: peer, as: .app)
            try connection.current(); try currentPath()
            return value
        } catch let error as NativeBrokerClientError { throw error }
        catch NativeSetupPeerError.expired { throw NativeBrokerClientError.expired }
        catch is NativeSetupPeerError { throw NativeBrokerClientError.signedPairRequired }
        catch NativeSetupSocketError.expired { throw NativeBrokerClientError.expired }
        catch is NativeSetupWireError { throw NativeBrokerClientError.invalidResponse }
        catch { throw NativeBrokerClientError.unavailable }
    }
}
