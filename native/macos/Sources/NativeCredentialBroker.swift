import Foundation

enum NativeBrokerSession {
    static func run(_ connection: NativeSetupConnection, core: NativeCoreConnection, custodian: NativeKeychainCustodian) {
        defer { connection.finish() }
        let peer: NativeSetupPeerSeal
        do {
            try connection.current()
            peer = try SignedSetupPeer.connected(connection.descriptor, as: .agent)
            try connection.current()
        } catch { return } // No pre-authentication frame or log.
        do {
            let request = try NativeBrokerWire.request(connection.readFrame())
            try SignedSetupPeer.current(connection.descriptor, seal: peer, as: .agent)
            try connection.current()
            let scope = try core.identity(deadline: connection.deadline)
            let response: Data
            switch request {
            case .status:
                response = try NativeBrokerWire.status(scope)
            case .credential(let role):
                let secret = try custodian.obtain(scope: scope, role: role, socket: connection.descriptor,
                                                 peer: peer, deadline: connection.deadline)
                try SignedSetupPeer.current(connection.descriptor, seal: peer, as: .agent)
                try connection.current()
                let receipt = try core.ensure(scope: scope, role: role, verifier: secret.verifier, deadline: connection.deadline)
                let current = try core.identity(deadline: connection.deadline)
                let record = try secret.delivery(receipt: receipt, currentScope: current, socket: connection.descriptor,
                                                 peer: peer, deadline: connection.deadline)
                response = try NativeBrokerWire.credential(record)
            }
            try SignedSetupPeer.current(connection.descriptor, seal: peer, as: .agent)
            try connection.current()
            try connection.writeFrame(response)
            try? connection.waitForEOF()
        } catch {
            // No raw exception, request, verifier or credential becomes a log or
            // wire reason. A lost reply reconciles the same item on a fresh peer.
            guard (try? connection.current()) != nil,
                  (try? SignedSetupPeer.current(connection.descriptor, seal: peer, as: .agent)) != nil,
                  let response = try? NativeBrokerWire.error(reason(error)) else { return }
            try? connection.writeFrame(response)
            try? connection.waitForEOF()
        }
    }

    private static func reason(_ error: Error) -> String {
        switch error {
        case NativeCoreConnectionError.capacity, NativeKeychainError.capacity: "capacity"
        case NativeCoreConnectionError.expired, NativeKeychainError.expired, NativeSetupSocketError.expired,
             NativeSetupPeerError.expired: "expired"
        case NativeCoreConnectionError.outcomeUnknown: "outcome_unknown"
        case NativeCoreConnectionError.ownerChanged, NativeKeychainError.ownerChanged: "owner_changed"
        case NativeCoreConnectionError.custodyConflict, NativeKeychainError.custodyConflict: "custody_conflict"
        case NativeKeychainError.locked: "keychain_locked"
        case NativeKeychainError.denied: "keychain_denied"
        case NativeKeychainError.unavailable: "keychain_unavailable"
        case NativeSetupWireError.invalidRecord, NativeSetupSocketError.invalidRequest: "invalid_request"
        default: "setup_unavailable"
        }
    }
}

final class NativeCredentialBroker: @unchecked Sendable {
    private let core: NativeCoreConnection
    private let listener: NativeSetupListener
    private let custodian = NativeKeychainCustodian()
    private let stopLock = NSLock()
    private var stopped = false

    init(installation: NativeInstalledReleaseSeal, dataDirectory: URL) throws {
        try SignedSetupPeer.currentInstalledRelease(installation)
        let core = try NativeCoreConnection(release: installation.executable, dataDirectory: dataDirectory)
        do {
            _ = try core.identity(deadline: DispatchTime.now().uptimeNanoseconds + 5_000_000_000)
            try SignedSetupPeer.currentInstalledRelease(installation)
            listener = try NativeSetupListener(dataDirectory: dataDirectory)
        } catch { _ = core.close(); throw error }
        self.core = core
    }

    func requestStop() { stopLock.lock(); stopped = true; stopLock.unlock() }
    private var shouldStop: Bool { stopLock.lock(); defer { stopLock.unlock() }; return stopped }

    func run() -> Int32 {
        var active: [NativeSetupConnection] = []
        var failed = false
        while !shouldStop && core.childIsRunning {
            active.removeAll { $0.isFinished }
            for connection in active where DispatchTime.now().uptimeNanoseconds >= connection.deadline { connection.expire() }
            do {
                if let connection = try listener.accept() {
                    // Backlog four, two actual workers, no waiter/replacement
                    // pool. Blocked Security calls retain their finite slot.
                    if active.count >= 2 { connection.finish() }
                    else {
                        active.append(connection)
                        let core = core; let custodian = custodian
                        DispatchQueue.global().async { NativeBrokerSession.run(connection, core: core, custodian: custodian) }
                    }
                }
                Thread.sleep(forTimeInterval: 0.02)
            } catch { failed = true; break }
        }
        for connection in active { connection.expire() }
        listener.close()
        let reaped = core.close()
        // The caller exits this native process immediately. Workers blocked in
        // an OS call still own their shutdown descriptors until reaped/exit.
        return !failed && reaped && shouldStop ? 0 : 1
    }
}
