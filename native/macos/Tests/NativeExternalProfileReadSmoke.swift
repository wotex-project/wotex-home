import Foundation

@main
struct NativeExternalProfileReadSmoke {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else { exit(2) }
        let socket = CommandLine.arguments[1], parts = CommandLine.arguments[2].split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 5 else { exit(2) }
        let expected = parts[1]
        let credential: Data
        if parts[0].hasPrefix("live-") {
            guard let line = readLine(), let bytes = Data(base64Encoded: line), bytes.count == 32 else { exit(2) }; credential = bytes
        } else { credential = Data(repeating: 7, count: 32) }
        do {
            let category = parts[0].replacingOccurrences(of: "live-", with: "")
            if category == "catalogue" {
                let value = try NativeExternalProfileClient.catalogue(socketPath: socket, credential: credential)
                guard expected == "valid", value.items.count == Int(parts[2]), Mirror(reflecting: value).children.isEmpty,
                      value.items.allSatisfy({ Mirror(reflecting: $0).children.isEmpty }),
                      parts[3].isEmpty || value.items.first?.state == parts[3] else { exit(1) }
            } else {
                guard let kind = HomeExternalProfileOriginalKind(rawValue: category), let epoch = Int64(parts[2]) else { exit(2) }
                let value = try NativeExternalProfileClient.original(socketPath: socket, credential: credential, kind: kind,
                    epoch: epoch, operation: parts[3], expectedInputSHA: parts[4].isEmpty ? nil : parts[4])
                if expected == "missing" { guard value == nil else { exit(1) }; return }
                guard expected == "valid", let value, value.kind == kind, value.epoch == epoch, value.operation == parts[3],
                      value.revision > 0, Mirror(reflecting: value).children.isEmpty, Mirror(reflecting: value.detail).children.isEmpty else { exit(1) }
            }
        } catch LocalHealthError.invalidResponse where expected == "invalid" { return }
        catch LocalHealthError.nativeGuardConflict where expected == "guard" { return }
        catch LocalHealthError.server("permission_denied") where expected == "refused" { return }
        catch LocalHealthError.server("unauthorized") where expected == "unauthorized" { return }
        catch LocalHealthError.invalidProfileRequest where expected == "input" { return }
        catch where expected == "lost" { return }
        catch { FileHandle.standardError.write(Data("unexpected external-profile read failure\n".utf8)); exit(1) }
    }
}
