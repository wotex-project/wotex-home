import Darwin
import Foundation

private enum AuthoringFileAssertion: Error { case failed(Int) }
@main
struct NativeAuthoringFilesSmoke {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { exit(2) }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let file = root.appendingPathComponent("source.bin"), alias = root.appendingPathComponent("alias.bin"), hard = root.appendingPathComponent("hard.bin")
        let bytes = Data([0, 255, 10, 13, 34])
        try bytes.write(to: file); try check(chmod(file.path, 0o600) == 0)
        try check(try NativeAuthoringFiles.read(file, maximum: 5) == bytes)
        try refused { _ = try NativeAuthoringFiles.read(file, maximum: 4) }
        try check(chmod(file.path, 0o644) == 0); try refused { _ = try NativeAuthoringFiles.read(file, maximum: 5) }
        try check(chmod(file.path, 0o600) == 0)
        try check(symlink(file.path, alias.path) == 0); try refused { _ = try NativeAuthoringFiles.read(alias, maximum: 5) }
        try check(link(file.path, hard.path) == 0); try refused { _ = try NativeAuthoringFiles.read(file, maximum: 5) }; try check(unlink(hard.path) == 0)
        let folderAlias = root.appendingPathComponent("linked", isDirectory: true)
        try check(symlink(root.path, folderAlias.path) == 0); try refused { _ = try NativeAuthoringFiles.read(folderAlias.appendingPathComponent("source.bin"), maximum: 5) }
        try refused { _ = try NativeAuthoringFiles.read(root, maximum: 5) }
        try refused { _ = try NativeAuthoringFiles.read(URL(fileURLWithPath: file.path + "\0ignored"), maximum: 5) }
        try refused { _ = try NativeAuthoringFiles.read(URL(string: "https://example.test/source.bin")!, maximum: 5) }
        try refused { _ = try NativeAuthoringFiles.read(file, maximum: 0) }
        try Data().write(to: file); try refused { _ = try NativeAuthoringFiles.read(file, maximum: 5) }
        let large = Data(repeating: 255, count: 262_144)
        try large.write(to: file); try check(try NativeAuthoringFiles.read(file, maximum: 262_144) == large)
        try Data(repeating: 255, count: 262_145).write(to: file); try refused { _ = try NativeAuthoringFiles.read(file, maximum: 262_144) }
        try check(try Data(contentsOf: file).count == 262_145)
        print("native authoring private file descriptor, links, modes, binary bytes and bounds passed")
    }
    private static func check(_ value: Bool, line: Int = #line) throws { guard value else { throw AuthoringFileAssertion.failed(line) } }
    private static func refused(_ body: () throws -> Void) throws {
        do { try body() } catch NativeAuthoringFileError.invalidFile { return }; throw AuthoringFileAssertion.failed(#line)
    }
}
