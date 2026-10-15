import Foundation

private enum ExternalOriginalAssertion: Error { case failed(String) }

@main
struct NativeExternalProfileOriginalSmoke {
    static func main() {
        do {
            if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--uri-parity" {
                let cases = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))) as! [[String: Any]]
                for (index, vector) in cases.enumerated() {
                    do {
                        let original = try NativeExternalProfileOriginalWire.encode(vector["input"] as! [String: Any], kind: .inspection)
                        guard let document = vector["document"] as? String, original.canonical == Data(document.utf8) else { throw ExternalOriginalAssertion.failed("uri-\(index)") }
                    } catch LocalHealthError.invalidProfileRequest {
                        guard vector["document"] is NSNull else { throw ExternalOriginalAssertion.failed("uri-\(index)") }
                    }
                }
                print("native URI parity passed \(cases.count) pinned owner cases"); return
            }
            guard CommandLine.arguments.count == 2, let corpus = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as? [String: Any] else { throw ExternalOriginalAssertion.failed("arguments") }
            let valid = corpus["valid"] as! [[String: Any]], invalid = corpus["invalid"] as! [[String: Any]], wire = corpus["invalid_wire"] as! [[String: Any]], json = corpus["invalid_json"] as! [[String: Any]]
            guard valid.count == 43 && invalid.count == 163 && wire.count == 68 && json.count == 7 else { throw ExternalOriginalAssertion.failed("counts") }
            for vector in valid {
                let label = vector["id"] as! String, kind = HomeExternalProfileOriginalKind(rawValue: vector["kind"] as! String)!, fields = vector["input"] as! [String: Any]
                let encoded = try NativeExternalProfileOriginalWire.encode(fields, kind: kind)
                guard encoded.canonical == Data((vector["document"] as! String).utf8), encoded.sha == vector["sha256"] as? String,
                      try NativeExternalProfileOriginalWire.decode(encoded.canonical, kind: kind) == encoded,
                      try JSONSerialization.data(withJSONObject: encoded.fields(), options: .sortedKeys) == JSONSerialization.data(withJSONObject: fields, options: .sortedKeys),
                      Mirror(reflecting: encoded).children.isEmpty else { throw ExternalOriginalAssertion.failed(label) }
                let native = try JSONSerialization.data(withJSONObject: fields, options: [.prettyPrinted, .sortedKeys])
                guard try NativeExternalProfileOriginalWire.nativeJSON(native, kind: kind) == encoded else { throw ExternalOriginalAssertion.failed(label) }
            }
            for vector in invalid {
                do {
                    _ = try NativeExternalProfileOriginalWire.encode(vector["input"] as! [String: Any], kind: HomeExternalProfileOriginalKind(rawValue: vector["kind"] as! String)!)
                    throw ExternalOriginalAssertion.failed(vector["id"] as! String)
                } catch LocalHealthError.invalidProfileRequest {}
            }
            for (vectors, native) in [(wire, false), (json, true)] {
                for vector in vectors {
                    let bytes = Data(base64Encoded: vector["payload_base64"] as! String)!, kind = HomeExternalProfileOriginalKind(rawValue: vector["kind"] as! String)!
                    do {
                        if native { _ = try NativeExternalProfileOriginalWire.nativeJSON(bytes, kind: kind) }
                        else { _ = try NativeExternalProfileOriginalWire.decode(bytes, kind: kind) }
                        throw ExternalOriginalAssertion.failed(vector["id"] as! String)
                    } catch LocalHealthError.invalidProfileRequest {}
                }
            }
            print("native external originals passed 43 valid, 163 input, 68 wire and 7 JSON refusal cases")
        } catch ExternalOriginalAssertion.failed(let label) { FileHandle.standardError.write(Data("external original case failed: \(label)\n".utf8)); exit(1) }
        catch { FileHandle.standardError.write(Data("external original codec failed\n".utf8)); exit(1) }
    }
}
