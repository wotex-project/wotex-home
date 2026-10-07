import CryptoKit
import Darwin
import Foundation

private enum BrokerSmokeError: Error { case failed }

@main
struct NativeBrokerSocketSmoke {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { throw BrokerSmokeError.failed }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let core = try NativeCoreConnection(release: root.appendingPathComponent("core-shim"), dataDirectory: root)
        defer { _ = core.close() }
        let custodian = NativeKeychainCustodian()
        fputs("broker fixture: listener ownership\n", stderr)
        let directory = try privateDirectory(root, "owned")
        let listener = try NativeSetupListener(dataDirectory: directory)
        try check(!FileManager.default.fileExists(atPath: root.appendingPathComponent("core-request").path))
        try rejected { try NativeSetupListener(dataDirectory: directory) }
        fputs("broker fixture: unsigned refusal\n", stderr)
        let original = NativeOriginalReference(receipt: NativeCreationReceipt(deployment: String(repeating: "a", count: 64),
            owner: String(repeating: "b", count: 64), epoch: 1, role: .operator, principal: "native-setup-v1:1:operator", revision: 1),
            verifier: String(repeating: "c", count: 64))
        for request in [Data(), Data([0, 0, 16, 1]), frame(Data("[\"wotex-home.native-credential-broker.v1\",\"credential\",\"operator\"]".utf8)),
                        frame(try NativeBrokerWire.request(.recover(original))), frame(try NativeBrokerWire.request(.endpoint))] {
            let client = try connect(listener.socketPath)
            defer { _ = Darwin.close(client) }
            if !request.isEmpty { try write(client, request) }
            guard let server = try listener.accept() else { throw BrokerSmokeError.failed }
            NativeBrokerSession.run(server, core: core, custodian: custodian)
            try check(server.isFinished)
            var response: UInt8 = 0
            let count = recv(client, &response, 1, MSG_DONTWAIT)
            try check(count == 0 || (count == -1 && errno == ECONNRESET))
            try check(!FileManager.default.fileExists(atPath: root.appendingPathComponent("core-request").path))
        }
        try unsignedClient(listener)
        try missingNativeGuard(listener)
        fputs("broker fixture: framing\n", stderr)
        try framing(listener)
        try replySocketLifetime(listener)
        fputs("broker fixture: expiry\n", stderr)
        try expiry(listener)
        try drippedHeader(listener)
        let owned = listener.socketPath
        listener.close()
        try check(!FileManager.default.fileExists(atPath: owned))
        fputs("broker fixture: path replacement\n", stderr)
        try paths(root)
        try check(core.close())
        print("native broker socket ownership and unsigned refusal passed")
    }

    private static func framing(_ listener: NativeSetupListener) throws {
        let body = Data("[\"wotex-home.native-credential-broker.v1\",\"status\"]".utf8)
        let client = try connect(listener.socketPath)
        defer { _ = Darwin.close(client) }
        try write(client, frame(body))
        guard let server = try listener.accept() else { throw BrokerSmokeError.failed }
        defer { server.finish() }
        try check(try server.readFrame() == body)
        let response = Data("[\"wotex-home.native-credential-broker.v1\",\"error\",\"invalid_request\"]".utf8)
        try server.writeFrame(response)
        var received = [UInt8](repeating: 0, count: response.count + 4)
        let count = recv(client, &received, received.count, MSG_DONTWAIT)
        try check(count == received.count && Data(received) == frame(response))
        for invalid in [Data([0, 0, 16, 1]), Data([0, 0, 0, 0]), frame(body) + frame(body)] {
            let fd = try connect(listener.socketPath)
            defer { _ = Darwin.close(fd) }
            try write(fd, invalid)
            guard let connection = try listener.accept() else { throw BrokerSmokeError.failed }
            try rejected { try connection.readFrame() }
            connection.finish()
        }
    }

    private static func unsignedClient(_ listener: NativeSetupListener) throws {
        for role in NativeCustodyRole.allCases {
            do {
                _ = try NativeBrokerClient.credential(role: role, socketPath: listener.socketPath)
                throw BrokerSmokeError.failed
            } catch NativeBrokerClientError.signedPairRequired {}
            if let accepted = try listener.accept() {
                defer { accepted.finish() }
                var byte: UInt8 = 0
                try check(recv(accepted.descriptor, &byte, 1, MSG_DONTWAIT) == 0)
            }
            try listener.current()
            let original = NativeOriginalReference(receipt: NativeCreationReceipt(deployment: String(repeating: "a", count: 64),
                owner: String(repeating: "b", count: 64), epoch: 1, role: role, principal: NativeCoreWire.principal(1, role), revision: 1),
                verifier: String(repeating: "c", count: 64))
            do {
                _ = try NativeBrokerClient.recover(original: original, socketPath: listener.socketPath)
                throw BrokerSmokeError.failed
            } catch NativeBrokerClientError.signedPairRequired {}
            if let accepted = try listener.accept() {
                defer { accepted.finish() }
                var byte: UInt8 = 0
                try check(recv(accepted.descriptor, &byte, 1, MSG_DONTWAIT) == 0)
            }
            try listener.current()
        }
        do {
            _ = try NativeBrokerClient.status(socketPath: listener.socketPath)
            throw BrokerSmokeError.failed
        } catch NativeBrokerClientError.signedPairRequired {}
        if let accepted = try listener.accept() {
            defer { accepted.finish() }
            var byte: UInt8 = 0
            try check(recv(accepted.descriptor, &byte, 1, MSG_DONTWAIT) == 0)
        }
        try listener.current()
        do {
            _ = try NativeBrokerClient.endpoint(socketPath: listener.socketPath)
            throw BrokerSmokeError.failed
        } catch NativeBrokerClientError.signedPairRequired {}
        if let accepted = try listener.accept() {
            defer { accepted.finish() }
            var byte: UInt8 = 0
            try check(recv(accepted.descriptor, &byte, 1, MSG_DONTWAIT) == 0)
        }
        try listener.current()
    }

    private static func missingNativeGuard(_ listener: NativeSetupListener) throws {
        let path = String(listener.socketPath.dropLast("native-setup.sock".count)) + "home.sock"
        let server = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        try check(server >= 0)
        defer { _ = Darwin.close(server) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX); address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8CString)
        try check(bytes.count <= MemoryLayout.size(ofValue: address.sun_path))
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes.map { UInt8(bitPattern: $0) }) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(server, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        try check(bound == 0)
        defer { _ = unlink(path) }
        try check(chmod(path, 0o600) == 0 && listen(server, 1) == 0 && fcntl(server, F_SETFL, O_NONBLOCK) == 0)
        let credential = Data(repeating: 0x31, count: 32) // Inert memory selection, no authenticated custody.
        try OperatorCredential.selectNative(credential)
        for mode in 0..<4 {
            if mode == 1 { OperatorCredential.selectManual() }
            if mode == 2 { OperatorCredential.endNativeSession() }
            if mode == 3 {
                let original = NativeOriginalReference(receipt: NativeCreationReceipt(deployment: String(repeating: "a", count: 64),
                    owner: String(repeating: "b", count: 64), epoch: 1, role: .operator, principal: "native-setup-v1:1:operator", revision: 1),
                    verifier: NativeCoreWire.hex(Data(SHA256.hash(data: credential))))
                let reference = try NativeBrokerWire.request(.recover(original))
                // Negative guard only; this fixture never supplies a signing seal.
                try OperatorCredential.retainNativeRequestGuard(credential, reference: reference) { _, _ in throw LocalHealthError.wrongPeer }
                try check(OperatorCredential.nativeReference(credential) == reference)
                try OperatorCredential.selectNative(credential)
                let captured = try OperatorCredential.captureOriginal()
                try check(captured.bytes == credential && captured.nativeReference == reference && captured.verifier == original.verifier)
                try check(Mirror(reflecting: captured).children.isEmpty)
                let conflicting = NativeOriginalReference(receipt: NativeCreationReceipt(deployment: original.receipt.deployment,
                    owner: String(repeating: "d", count: 64), epoch: 1, role: .operator, principal: original.receipt.principal, revision: 1),
                    verifier: original.verifier)
                do {
                    try OperatorCredential.retainNativeRequestGuard(credential, reference: NativeBrokerWire.request(.recover(conflicting))) { _, _ in throw LocalHealthError.wrongPeer }
                    throw BrokerSmokeError.failed
                } catch LocalHealthError.nativeGuardConflict {}
                try check(OperatorCredential.nativeReference(credential) == reference)
            }
            do {
                _ = try LocalHealthClient.fetch(socketPath: path, credential: credential)
                throw BrokerSmokeError.failed
            } catch LocalHealthError.wrongPeer {}
            let accepted = Darwin.accept(server, nil, nil)
            try check(accepted >= 0)
            defer { _ = Darwin.close(accepted) }
            var byte: UInt8 = 0
            try check(recv(accepted, &byte, 1, MSG_DONTWAIT) == 0)
        }
        for index in 0..<263 {
            var value = UInt64(index).bigEndian
            let bytes = withUnsafeBytes(of: &value) { Data($0) } + Data(repeating: 0, count: 24)
            try OperatorCredential.selectNative(bytes)
        }
        do {
            try OperatorCredential.selectNative(Data(repeating: 0x32, count: 32))
            throw BrokerSmokeError.failed
        } catch LocalHealthError.nativeGuardCapacity {}
        OperatorCredential.endNativeSession()
    }

    private static func replySocketLifetime(_ listener: NativeSetupListener) throws {
        let fd = try connect(listener.socketPath)
        let client = try NativeSetupConnection(fd, accepted: DispatchTime.now().uptimeNanoseconds)
        defer { client.finish() }
        guard let server = try listener.accept() else { throw BrokerSmokeError.failed }
        defer { server.finish() }
        let token = try SignedSetupPeer.auditToken(fd) // Kernel bytes, never a signed seal.
        let response = Data("[\"wotex-home.native-credential-broker.v1\",\"error\",\"invalid_request\"]".utf8)
        let completed = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            do { try server.writeFrame(response); try server.waitForEOF() }
            catch {}
            server.finish(); completed.signal()
        }
        try check(try client.readFrame(allowEOF: true) == response)
        try check(try SignedSetupPeer.auditToken(fd) == token)
        client.finish()
        try check(completed.wait(timeout: .now() + 2) == .success)
    }

    private static func expiry(_ listener: NativeSetupListener) throws {
        let client = try connect(listener.socketPath)
        defer { _ = Darwin.close(client) }
        guard let server = try listener.accept() else { throw BrokerSmokeError.failed }
        let fd = server.descriptor
        server.expire()
        try rejected { try server.current() }
        try check(fcntl(fd, F_GETFD) >= 0 && !server.isFinished)
        let another = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        try check(another >= 0 && another != fd)
        _ = Darwin.close(another)
        server.finish()
        try check(server.isFinished && fcntl(fd, F_GETFD) == -1 && errno == EBADF)
        // Construct an already expired original accepted connection. Parsing
        // cannot establish a fresh deadline even when bytes are available.
        let lateClient = try connect(listener.socketPath)
        defer { _ = Darwin.close(lateClient) }
        guard let accepted = try listener.accept() else { throw BrokerSmokeError.failed }
        let duplicate = dup(accepted.descriptor)
        try check(duplicate >= 0)
        let late = try NativeSetupConnection(duplicate, accepted: DispatchTime.now().uptimeNanoseconds - 6_000_000_000)
        defer { late.finish(); accepted.finish() }
        try rejected { try late.readFrame() }
    }

    private static func paths(_ root: URL) throws {
        for kind in ["regular", "symlink"] {
            let dir = try privateDirectory(root, kind)
            let ipc = try privateDirectory(dir, "ipc")
            let path = ipc.appendingPathComponent("native-setup.sock")
            if kind == "regular" { try Data("foreign fixture".utf8).write(to: path) }
            else { try check(symlink("/usr/bin/true", path.path) == 0) }
            try rejected { try NativeSetupListener(dataDirectory: dir) }
            var info = stat()
            try check(lstat(path.path, &info) == 0)
            if kind == "regular" { try check(try Data(contentsOf: path) == Data("foreign fixture".utf8)) }
            else { try check(info.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK)) }
        }
        let dir = try privateDirectory(root, "replacement")
        let listener = try NativeSetupListener(dataDirectory: dir)
        let path = listener.socketPath
        try check(rename(path, path + ".original") == 0)
        try Data("replacement fixture".utf8).write(to: URL(fileURLWithPath: path))
        try rejected { try listener.current() }
        listener.close()
        try check(try Data(contentsOf: URL(fileURLWithPath: path)) == Data("replacement fixture".utf8))
        let exposed = try privateDirectory(root, "nonprivate")
        try check(chmod(exposed.path, 0o755) == 0)
        try rejected { try NativeSetupListener(dataDirectory: exposed) }
        let renamed = try privateDirectory(root, "renamed")
        let active = try NativeSetupListener(dataDirectory: renamed)
        let moved = renamed.path + ".moved"
        try check(rename(renamed.path, moved) == 0)
        try rejected { try active.current() }
        active.close()
        var retained = stat()
        try check(lstat(moved + "/ipc/native-setup.sock", &retained) == 0)
    }

    private static func drippedHeader(_ listener: NativeSetupListener) throws {
        let client = try connect(listener.socketPath)
        defer { _ = Darwin.close(client) }
        guard let accepted = try listener.accept() else { throw BrokerSmokeError.failed }
        let fd = dup(accepted.descriptor)
        try check(fd >= 0)
        let started = DispatchTime.now().uptimeNanoseconds
        let connection = try NativeSetupConnection(fd, accepted: started - 4_200_000_000)
        defer { connection.finish(); accepted.finish() }
        let complete = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            for value: UInt8 in [0, 0, 0, 64] {
                var byte = value
                _ = send(client, &byte, 1, 0)
                usleep(300_000)
            }
            complete.signal()
        }
        try rejected { try connection.readFrame() }
        let elapsed = DispatchTime.now().uptimeNanoseconds - started
        try check(elapsed >= 700_000_000 && elapsed < 1_500_000_000)
        try check(complete.wait(timeout: .now() + 2) == .success)
    }

    private static func privateDirectory(_ root: URL, _ name: String) throws -> URL {
        let result = root.appendingPathComponent(name, isDirectory: true)
        try check(mkdir(result.path, 0o700) == 0)
        return result
    }

    private static func connect(_ path: String) throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        try check(fd >= 0)
        var noSignal: Int32 = 1
        try check(setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX); address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8CString)
        try check(bytes.count <= MemoryLayout.size(ofValue: address.sun_path))
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes.map { UInt8(bitPattern: $0) }) }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if result != 0 { _ = Darwin.close(fd); throw BrokerSmokeError.failed }
        return fd
    }

    private static func frame(_ body: Data) -> Data {
        let size = UInt32(body.count)
        return Data([UInt8(size >> 24), UInt8((size >> 16) & 255), UInt8((size >> 8) & 255), UInt8(size & 255)]) + body
    }
    private static func write(_ fd: Int32, _ bytes: Data) throws {
        let result = bytes.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
        try check(result == bytes.count)
    }
    private static func check(_ value: Bool, line: UInt = #line) throws {
        if !value { fputs("native broker fixture check failed at line \(line)\n", stderr); throw BrokerSmokeError.failed }
    }
    private static func rejected<T>(_ body: () throws -> T) throws {
        do { _ = try body() }
        catch is NativeSetupSocketError { return }
        throw BrokerSmokeError.failed
    }
}
