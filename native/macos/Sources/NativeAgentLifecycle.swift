import Darwin
import Foundation

final class AgentShutdown: @unchecked Sendable {
    private let lock = NSLock()
    private var stopping = false
    private var action: (@Sendable () -> Void)?

    func installAction(_ action: @escaping @Sendable () -> Void) {
        lock.lock(); self.action = action; let requested = stopping; lock.unlock()
        if requested { action() }
    }
    func requestStop() {
        lock.lock(); stopping = true; let callback = action; lock.unlock()
        callback?()
    }
    var isRequested: Bool { lock.lock(); defer { lock.unlock() }; return stopping }
}

func terminationSources(_ stop: @escaping @Sendable () -> Void) -> [DispatchSourceSignal] {
    signal(SIGTERM, SIG_IGN); signal(SIGINT, SIG_IGN)
    return [SIGTERM, SIGINT].map { number in
        let source = DispatchSource.makeSignalSource(signal: number)
        source.setEventHandler(handler: stop)
        source.resume()
        return source
    }
}

// Normal Home/manual-custody development, using only identity and pipe lifetime.
// No listener, native provisioning, Keychain operation or authentication seal.
final class NativeDevelopmentSession {
    private let core: NativeCoreConnection

    init(release: URL, dataDirectory: URL) throws {
        let core = try NativeCoreConnection(release: release, dataDirectory: dataDirectory)
        do { _ = try core.identity(deadline: DispatchTime.now().uptimeNanoseconds + 5_000_000_000) }
        catch { _ = core.close(); throw error }
        self.core = core
    }

    func run(shutdown: AgentShutdown) -> Int32 {
        while core.childIsRunning && !shutdown.isRequested { Thread.sleep(forTimeInterval: 0.02) }
        let reaped = core.close()
        return reaped && shutdown.isRequested ? 0 : 1
    }
}
