import Foundation

@main struct NativeControllerPairingWireSmoke {
    static func check(_ ok: Bool, _ label: String) throws {
        if !ok { throw FixtureFailure(name: label) }
    }
    struct FixtureFailure: Error { let name: String }

    static func base64(_ bytes: Data) -> String {
        bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func context(_ c: NativeControllerPairingContext) -> [String: Any] {
        ["controller_id": c.controller, "invitation_id": c.invitation, "client_id": c.client, "request_id": c.request, "request_digest": c.requestDigest]
    }
    static func normalize(_ response: NativeControllerBootstrapResponse, kind: String) throws -> [String: Any] {
        var result = context(response.context)
        switch response {
        case .paired(let a):
            try check(kind == "paired", "response variant")
            result.merge(["deployment_id": a.deployment, "owner_id": a.owner, "authority_epoch": a.epoch,
                "principal_id": a.principal, "revision": a.revision, "permissions": a.access.permissions,
                "target_ids": a.access.targets, "credential": base64(a.credential)]) { _, right in right }
        case .refused(_, let reason):
            try check(kind == "refused", "response variant")
            result["reason"] = reason
        }
        return result
    }

    static func read(_ kind: String, _ bytes: Data) throws -> (Data, [String: Any]) {
        switch kind {
        case "invitation":
            let a = try NativeControllerPairingWire.decodeInvitation(bytes)
            return (try NativeControllerPairingWire.encode(a), ["controller_id": a.controller,
                "identity": [a.identity.kind, a.identity.value], "leaf_pin": a.leafPin, "trust_anchor": base64(a.trustAnchor),
                "endpoint": [a.endpoint.kind, a.endpoint.value, a.port], "invitation_id": a.invitation, "bootstrap_secret": base64(a.bootstrapSecret)])
        case "request":
            let a = try NativeControllerPairingWire.decodeRequest(bytes)
            return (try NativeControllerPairingWire.encode(a), ["controller_id": a.controller, "invitation_id": a.invitation,
                "client_id": a.client, "request_id": a.request, "client_label": a.label, "bootstrap_secret": base64(a.bootstrapSecret)])
        default:
            let a = try NativeControllerPairingWire.decodeResponse(bytes)
            return (try NativeControllerPairingWire.encode(a), try normalize(a, kind: kind))
        }
    }

    static func hex(_ text: String) -> Data {
        let chars = Array(text.utf8)
        func nibble(_ c: UInt8) -> UInt8 { c <= 57 ? c - 48 : c - 87 }
        return Data(stride(from: 0, to: chars.count, by: 2).map { (nibble(chars[$0]) << 4) | nibble(chars[$0 + 1]) })
    }

    static func frame(_ kind: String, _ bytes: Data) throws -> Data {
        switch kind {
        case "invitation": return try NativeControllerPairingWire.frame(NativeControllerPairingWire.decodeInvitation(bytes))
        case "request": return try NativeControllerPairingWire.frame(NativeControllerPairingWire.decodeRequest(bytes))
        default: return try NativeControllerPairingWire.frame(NativeControllerPairingWire.decodeResponse(bytes))
        }
    }

    static func decodeFrame(_ kind: String, _ bytes: Data) throws -> Data {
        switch kind {
        case "invitation": return try NativeControllerPairingWire.encode(NativeControllerPairingWire.decodeInvitationFrame(bytes))
        case "request": return try NativeControllerPairingWire.encode(NativeControllerPairingWire.decodeRequestFrame(bytes))
        default: return try NativeControllerPairingWire.encode(NativeControllerPairingWire.decodeResponseFrame(bytes))
        }
    }

    static func run() throws {
        guard CommandLine.arguments.count == 2,
              let corpus = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as? [String: Any],
              let valid = corpus["valid"] as? [[String: Any]], let invalid = corpus["invalid"] as? [[String: Any]],
              let joins = corpus["correspondence"] as? [[String: Any]] else { throw FixtureFailure(name: "fixture") }
        for v in valid {
            let name = v["name"] as! String
            let bytes = Data((v["wire"] as! String).utf8)
            let (encoded, value) = try read(v["kind"] as! String, bytes)
            try check(encoded == bytes && NSDictionary(dictionary: value).isEqual(to: v["value"] as! [String: Any]), name)
            try check(encoded.count <= 8192, name)
            let expectedFrame = hex(v["frame_hex"] as! String)
            try check(try frame(v["kind"] as! String, bytes) == expectedFrame, name + " frame")
            try check(try decodeFrame(v["kind"] as! String, expectedFrame) == bytes, name + " frame decode")
            for changed in [Data(expectedFrame.dropLast()), expectedFrame + Data([0])] {
                do {
                    _ = try decodeFrame(v["kind"] as! String, changed)
                    throw FixtureFailure(name: name + " frame length")
                } catch NativeControllerPairingError.invalidRecord {}
            }
        }
        for header in corpus["headers"] as! [[String: Any]] {
            let bytes = hex(header["hex"] as! String)
            if let size = header["size"] as? Int {
                try check(try NativeControllerPairingWire.frameSize(bytes) == size, "frame header")
            } else {
                do {
                    _ = try NativeControllerPairingWire.frameSize(bytes)
                    throw FixtureFailure(name: "invalid frame header")
                } catch NativeControllerPairingError.invalidRecord {}
            }
        }
        for v in invalid {
            do {
                _ = try read(v["kind"] as! String, Data((v["wire"] as! String).utf8))
                throw FixtureFailure(name: v["name"] as! String)
            } catch NativeControllerPairingError.invalidRecord {}
        }
        for v in joins {
            let request = valid.first { $0["name"] as? String == v["request"] as? String }!
            let response = valid.first { $0["name"] as? String == v["response"] as? String }!
            let original = try NativeControllerPairingWire.decodeRequest(Data((request["wire"] as! String).utf8))
            let access = v["approved_access"] as! [String: Any]
            let approved = NativeControllerAccess(permissions: access["permissions"] as! [String], targets: access["target_ids"] as! [String])
            var accepted = false
            do {
                _ = try NativeControllerPairingWire.verifyResponse(Data((response["wire"] as! String).utf8), request: original, approvedAccess: approved)
                accepted = true
            } catch NativeControllerPairingError.invalidRecord {}
            try check(accepted == v["accepted"] as! Bool, v["name"] as! String)
        }
        let original = try NativeControllerPairingWire.decodeRequest(Data((valid.first { $0["name"] as? String == "request_unicode" }!["wire"] as! String).utf8))
        try check(try NativeControllerPairingWire.context(original).requestDigest == corpus["request_digest"] as! String, "complete digest")
        do {
            _ = try NativeControllerPairingWire.decodeInvitation(Data([255]))
            throw FixtureFailure(name: "invalid UTF-8")
        } catch NativeControllerPairingError.invalidRecord {}
        print("native controller pairing 28 records, 158 refusals, 18 exact correspondence cases and bounded frames passed")
    }

    static func main() {
        do { try run() }
        catch let failure as FixtureFailure {
            FileHandle.standardError.write(Data("controller pairing fixture failed: \(failure.name)\n".utf8)); exit(1)
        } catch {
            FileHandle.standardError.write(Data("controller pairing fixture failed\n".utf8)); exit(1)
        }
    }
}
