import Darwin
import Foundation

enum AgentError: Error {
    case invalidDataDirectory
    case missingRelease
}

func privateDataDirectory() throws -> URL {
    umask(0o077)
    let support = FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
    )[0]
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
    return directory
}

func releaseExecutable() throws -> URL {
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let contents = executable.deletingLastPathComponent().deletingLastPathComponent()
    let release = contents.appendingPathComponent(
        "Resources/WotexHomeRelease/bin/wotex_home"
    )
    guard FileManager.default.isExecutableFile(atPath: release.path) else {
        throw AgentError.missingRelease
    }
    return release
}

do {
    let directory = try privateDataDirectory()
    let release = try releaseExecutable()
    let child = Process()
    child.executableURL = release
    child.arguments = ["start"]
    var environment = ProcessInfo.processInfo.environment
    environment["WOTEX_HOME_DATA_DIR"] = directory.path
    child.environment = environment

    signal(SIGTERM, SIG_IGN)
    signal(SIGINT, SIG_IGN)
    let term = DispatchSource.makeSignalSource(signal: SIGTERM)
    let interrupt = DispatchSource.makeSignalSource(signal: SIGINT)
    term.setEventHandler { if child.isRunning { child.terminate() } }
    interrupt.setEventHandler { if child.isRunning { child.terminate() } }
    term.resume()
    interrupt.resume()

    try child.run()
    child.waitUntilExit()
    exit(child.terminationStatus)
} catch {
    fputs("WoTEx Home agent could not start: \(error)\n", stderr)
    exit(1)
}
