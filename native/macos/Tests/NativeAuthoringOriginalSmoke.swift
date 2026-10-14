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
                if kind == .review {
                    var fields = try value.fields()
                    let review = fields["review"] as! [String: Any]
                    let citations = (review["evidence"] as! [[String: Any]]).reversed().map {
                        NativeAuthoringCitation(path: $0["instance_path"] as! String, source: $0["source_ref"] as! String, locator: $0["locator"] as! String)
                    }
                    let envelope = (review["envelope_ref"] as? [String: Any]).map {
                        NativeAuthoringObjectHandle(digest: $0["object_digest"] as! String, firstRevision: LocalHealthClient.profileInteger($0["first_revision"])!)
                    }
                    let content = NativeAuthoringReviewContent(mode: NativeAuthoringReviewMode(rawValue: review["mode"] as! String)!, evidence: citations,
                        unresolved: Array((review["unresolved_paths"] as! [String]).reversed()), envelope: envelope)
                    var canonical = try content.checkedFields(); canonical["candidate_ref"] = review["candidate_ref"]
                    fields["review"] = canonical
                    guard try NativeAuthoringOriginalWire.encode(fields, kind: .review) == value,
                          Mirror(reflecting: content).children.isEmpty,
                          citations.allSatisfy({ Mirror(reflecting: $0).children.isEmpty }) else { exit(1) }
                }
            } catch {
                guard !valid else { FileHandle.standardError.write(Data("native authoring original case \(index) refused: \(error)\n".utf8)); exit(1) }
            }
        }
        print("native authoring \(cases.count) complete-original cases passed")
    }
}
