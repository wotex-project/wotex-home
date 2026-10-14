import Foundation

enum NativePendingAuthoring {
    static func checked(_ original: HomeAuthoringOriginal, payload: Data?) throws -> HomeAuthoringOriginal {
        do {
            let fields = try original.fields()
            if original.kind == .import {
                guard let payload, (1...262_144).contains(payload.count), let summary = fields["object"] as? [String: Any],
                      let digest = summary["object_digest"] as? String else { throw NativePendingError.invalidRecord }
                let response: [String: Any] = ["api_version": 1, "outcome": "ok", "authoring_object": ["object": summary, "first_revision": 1, "payload_base64": base64(payload)]]
                guard try NativeAuthoringReadClient.decodeObject(response, digest: digest)?.payload == payload else { throw NativePendingError.invalidRecord }
            } else { guard payload == nil else { throw NativePendingError.invalidRecord } }
            return original
        } catch { throw NativePendingError.invalidRecord }
    }
    static func base64(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func decodeBase64(_ string: String) throws -> Data {
        guard (1...349_526).contains(string.utf8.count), string.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else { throw NativePendingError.invalidRecord }
        let ordinary = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard let bytes = Data(base64Encoded: ordinary + String(repeating: "=", count: (4 - ordinary.count % 4) % 4)), base64(bytes) == string else { throw NativePendingError.invalidRecord }
        return bytes
    }
}
