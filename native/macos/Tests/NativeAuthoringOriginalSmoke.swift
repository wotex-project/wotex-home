import Foundation

@main
struct NativeAuthoringOriginalSmoke {
    static func main() throws {
        guard CommandLine.arguments.count == 2,
              let cases = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as? [[String: Any]] else { exit(2) }
        for (index, entry) in cases.enumerated() {
            guard let kind = HomeAuthoringOriginalKind(rawValue: entry["kind"] as? String ?? ""),
                  let spelling = entry["bytes"] as? String, let bytes = Data(base64Encoded: spelling),
                  let valid = entry["valid"] as? Bool, let mode = entry["mode"] as? String else { exit(2) }
            do {
                let value = try mode == "native" ? NativeAuthoringOriginalWire.nativeJSON(bytes, kind: kind) : NativeAuthoringOriginalWire.decode(bytes, kind: kind)
                guard valid, let expected = entry["canonical"] as? String, let canonical = Data(base64Encoded: expected), value.canonical == canonical,
                      value.sha == entry["sha"] as? String, value.kind == kind,
                      try NativeAuthoringOriginalWire.encode(value.fields(), kind: kind) == value,
                      try NativeAuthoringOriginalWire.decode(value.canonical, kind: kind) == value,
                      !String(reflecting: value).contains("canonical"), !String(reflecting: value).contains("private-canary") else {
                    FileHandle.standardError.write(Data("native authoring original case \(index) mismatched\n".utf8)); exit(1)
                }
            } catch {
                guard !valid else { FileHandle.standardError.write(Data("native authoring original case \(index) refused: \(error)\n".utf8)); exit(1) }
            }
        }
        print("native authoring \(cases.count) complete-original cases passed")
    }
}
