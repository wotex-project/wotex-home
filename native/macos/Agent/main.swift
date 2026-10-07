import Darwin
import Foundation

enum AgentError: Error { case invalidDataDirectory }

func privateDataDirectory() throws -> URL {
    umask(0o077)
    let support = URL(fileURLWithPath: try NativeCoreEnvironment.userHome(), isDirectory: true)
        .appendingPathComponent("Library/Application Support", isDirectory: true)
    let directory = support.appendingPathComponent("WoTExHome", isDirectory: true)
    let path = directory.path

    if mkdir(path, 0o700) != 0 && errno != EEXIST {
        throw AgentError.invalidDataDirectory
    }

    var info = stat()
    guard lstat(path, &info) == 0,
          info.st_uid == getuid(),
          (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
          (info.st_mode & 0o777) == 0o700 else {
        throw AgentError.invalidDataDirectory
    }
    return URL(fileURLWithPath: try NativeProtectedInstallation.physicalPath(path), isDirectory: true)
}

func runAgent(_ shutdown: AgentShutdown) throws -> Int32 {
    // A failed signed installation cannot become a development broker. Only
    // actual ad-hoc self metadata selects the ordinary manual-custody host.
    let development = try? SignedSetupPeer.developmentRelease()
    let installation = development == nil ? try SignedSetupPeer.installedRelease() : nil
    if shutdown.isRequested { return 0 }
    let directory = try privateDataDirectory()
    if let development {
        return try NativeDevelopmentSession(release: development, dataDirectory: directory).run(shutdown: shutdown)
    } else if let installation {
        let broker = try NativeCredentialBroker(installation: installation, dataDirectory: directory)
        shutdown.installAction { broker.requestStop() }
        return broker.run()
    } else { throw AgentError.invalidDataDirectory }
}

let agentShutdown = AgentShutdown()
let agentSignals = terminationSources { agentShutdown.requestStop() }
do {
    let status = try withExtendedLifetime(agentSignals) { try runAgent(agentShutdown) }
    exit(status)
} catch {
    fputs("WoTEx Home agent unavailable\n", stderr)
    exit(1)
}
