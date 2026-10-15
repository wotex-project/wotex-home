import Darwin
import Foundation

enum NativeAuthoringFileError: LocalizedError {
    case invalidFile
    var errorDescription: String? { "Choose a private regular file owned by this account with unchanged bytes and no links." }
}

enum NativeAuthoringFiles {
    private struct Identity: Equatable {
        let device: dev_t, inode: ino_t, owner: uid_t, group: gid_t, mode: mode_t, links: nlink_t, size: off_t
        let modifiedSeconds: time_t, modifiedNanos: Int, changedSeconds: time_t, changedNanos: Int
        init(_ value: stat) {
            device = value.st_dev; inode = value.st_ino; owner = value.st_uid; group = value.st_gid
            mode = value.st_mode; links = value.st_nlink; size = value.st_size
            modifiedSeconds = value.st_mtimespec.tv_sec; modifiedNanos = value.st_mtimespec.tv_nsec
            changedSeconds = value.st_ctimespec.tv_sec; changedNanos = value.st_ctimespec.tv_nsec
        }
    }
    static func read(_ url: URL, maximum: Int) throws -> Data {
        guard (1...262_144).contains(maximum) else { throw NativeAuthoringFileError.invalidFile }
        return try read(url, maximum: maximum, mode: 0o600)
    }
    static func readImmutable(_ url: URL, maximum: Int) throws -> Data {
        guard (1...524_288).contains(maximum) else { throw NativeAuthoringFileError.invalidFile }
        return try read(url, maximum: maximum, mode: 0o400)
    }
    private static func read(_ url: URL, maximum: Int, mode: mode_t) throws -> Data {
        guard url.isFileURL, url.path.utf8.count <= 1024, url.path.hasPrefix("/"),
              !url.path.utf8.contains(0),
              !url.pathComponents.contains(".."), !url.pathComponents.contains("."),
              (1...524_288).contains(maximum) else { throw NativeAuthoringFileError.invalidFile }
        let parent = url.deletingLastPathComponent().path
        try noLinks(parent)
        var directory = stat(), named = stat()
        guard lstat(parent, &directory) == 0,
              mode != 0o400 || (directory.st_uid == geteuid() && directory.st_mode & 0o777 == 0o700),
              lstat(url.path, &named) == 0, privateFile(named, maximum: maximum, mode: mode) else { throw NativeAuthoringFileError.invalidFile }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw NativeAuthoringFileError.invalidFile }; defer { _ = close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0, Identity(opened) == Identity(named) else { throw NativeAuthoringFileError.invalidFile }
        var bytes = [UInt8](repeating: 0, count: maximum + 1), cursor = 0
        while cursor < bytes.count {
            let received = bytes.withUnsafeMutableBytes { buffer in Darwin.read(descriptor, buffer.baseAddress!.advanced(by: cursor), buffer.count - cursor) }
            if received < 0 && errno == EINTR { continue }
            guard received >= 0 else { throw NativeAuthoringFileError.invalidFile }
            if received == 0 { break }; cursor += received
        }
        var final = stat(), finalName = stat(), finalDirectory = stat()
        try noLinks(parent)
        guard cursor == named.st_size, cursor <= maximum, fstat(descriptor, &final) == 0, lstat(url.path, &finalName) == 0,
              Identity(final) == Identity(named), Identity(finalName) == Identity(named), lstat(parent, &finalDirectory) == 0,
              mode != 0o400 || (finalDirectory.st_uid == geteuid() && finalDirectory.st_mode & 0o777 == 0o700),
              finalDirectory.st_dev == directory.st_dev, finalDirectory.st_ino == directory.st_ino else { throw NativeAuthoringFileError.invalidFile }
        return Data(bytes.prefix(cursor))
    }
    private static func privateFile(_ value: stat, maximum: Int, mode: mode_t) -> Bool {
        value.st_uid == geteuid() && value.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) &&
            value.st_mode & 0o777 == mode && value.st_nlink == 1 && value.st_size > 0 && value.st_size <= maximum
    }
    private static func noLinks(_ path: String) throws {
        var value = stat()
        guard lstat(path, &value) == 0, value.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { throw NativeAuthoringFileError.invalidFile }
        if path != "/" { try noLinks((path as NSString).deletingLastPathComponent) }
    }
}
