import Foundation

@main
struct NativeGenerationOriginalSmoke {
    static func main() throws {
        guard CommandLine.arguments.count == 2,
              let cases = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as? [[String: Any]] else { exit(2) }
        for (index, entry) in cases.enumerated() {
            guard let kind = HomeGenerationOriginalKind(rawValue: entry["kind"] as? String ?? ""),
                  let mode = entry["mode"] as? String, let valid = entry["valid"] as? Bool,
                  let spelling = entry["bytes"] as? String, let bytes = Data(base64Encoded: spelling) else { exit(2) }
            do {
                if mode == "receipt" || mode == "receipt_match" || mode == "receipt_native" {
                    let result: HomeGenerationReservation
                    if mode == "receipt_native" {
                        try StrictLocalJSON.check(bytes)
                        guard let fields = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { failed(index, "receipt map shape") }
                        result = try NativeGenerationOriginalWire.reservation(fields, kind: kind)
                    } else { result = try NativeGenerationOriginalWire.decodeReservation(bytes, kind: kind) }
                    if mode == "receipt_match" {
                        guard let original = entry["original"] as? String, let document = Data(base64Encoded: original) else { exit(2) }
                        try result.matches(NativeGenerationOriginalWire.decode(document, kind: kind))
                    }
                    guard valid else { failed(index, "accepted invalid receipt") }
                    if mode != "receipt_native" { guard result.canonical == bytes else { failed(index, "receipt bytes changed") } }
                } else {
                    let value = try mode == "native" ? NativeGenerationOriginalWire.nativeJSON(bytes, kind: kind) : NativeGenerationOriginalWire.decode(bytes, kind: kind)
                    guard valid, let expected = entry["canonical"] as? String, let canonical = Data(base64Encoded: expected),
                          value.canonical == canonical, value.sha == entry["sha"] as? String,
                          try NativeGenerationOriginalWire.encode(value.fields(), kind: kind) == value,
                          try NativeGenerationOriginalWire.decode(value.canonical, kind: kind) == value,
                          !String(reflecting: value).contains("canonical"), !String(reflecting: value).contains("private-canary") else { failed(index, "original correspondence") }
                }
            } catch {
                if valid { failed(index, "valid case refused") }
            }
        }
        print("native generation \(cases.count) complete-original and reservation cases passed")
    }
    private static func failed(_ index: Int, _ reason: String) -> Never {
        FileHandle.standardError.write(Data("native generation case \(index): \(reason)\n".utf8)); exit(1)
    }
}
