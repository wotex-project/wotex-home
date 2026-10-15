import Foundation

struct NativeAuthoringSelections: Sendable {
    let sources: [NativeAuthoringObjectHandle], fixtures: [NativeAuthoringObjectHandle]
    static func read(_ url: URL?) throws -> Self {
        guard let url else { return Self(sources: [], fixtures: []) }
        let bytes = try NativeAuthoringFiles.read(url, maximum: 16384)
        try StrictLocalJSON.check(bytes, maximumDepth: 3)
        guard let root = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              Set(root.keys) == Set(["source_refs", "fixture_refs"]) else { throw LocalHealthError.invalidProfileRequest }
        func handles(_ value: Any?) throws -> [NativeAuthoringObjectHandle] {
            guard let list = value as? [[String: Any]], list.count <= 32 else { throw LocalHealthError.invalidProfileRequest }
            var previous = ""
            return try list.map { item in
                guard Set(item.keys) == Set(["object_digest", "first_revision"]),
                      let digest = item["object_digest"] as? String, LocalHealthClient.profileDigest(digest), digest > previous,
                      let first = LocalHealthClient.profileInteger(item["first_revision"]), first > 0 else { throw LocalHealthError.invalidProfileRequest }
                previous = digest; return NativeAuthoringObjectHandle(digest: digest, firstRevision: first)
            }
        }
        return try Self(sources: handles(root["source_refs"]), fixtures: handles(root["fixture_refs"]))
    }
    func verify(socket: String, credential: Data) throws {
        var frameBytes = 0
        for (kind, handles) in [("source", sources), ("fixture", fixtures)] {
            for handle in handles {
                guard let object = try NativeAuthoringReadClient.fetchObject(socketPath: socket, credential: credential, digest: handle.digest) else {
                    throw LocalHealthError.server("authoring_object_unavailable")
                }
                guard object.summary.kind == kind, object.firstRevision == Int64(handle.firstRevision) else {
                    throw LocalHealthError.server("stale_authoring_reference")
                }
                frameBytes += object.summary.size + 42
                guard frameBytes <= 4194304 else { throw LocalHealthError.server("authoring_limit") }
            }
        }
    }
}
