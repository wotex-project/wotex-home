import Foundation

private enum WireSmokeError: Error { case failed }

@main
struct NativeSetupWireSmoke {
    static func main() throws {
        let deployment = String(repeating: "a", count: 64)
        let owner = String(repeating: "b", count: 64)
        let scope = NativeControllerScope(deployment: deployment, owner: owner, epoch: 7, revision: 9)
        let identity = "[\"wotex-home.native-setup-authority.v1\",\"identity\",\"\(deployment)\",\"\(owner)\",7,9]"
        try check(try NativeCoreWire.identity(Data(identity.utf8)) == scope)
        try check(String(decoding: NativeCoreWire.identityRequest(), as: UTF8.self) ==
                    "[\"wotex-home.native-setup-authority.v1\",\"identity\"]")
        let expectedEnsure = "[\"wotex-home.native-setup-authority.v1\",\"ensure\",\"\(deployment)\",\"\(owner)\",7,\"operator\",\"\(String(repeating: "ab", count: 32))\"]"
        try check(String(decoding: NativeCoreWire.ensureRequest(scope, role: .operator, verifier: Data(repeating: 0xab, count: 32)), as: UTF8.self) == expectedEnsure)
        let receipt = "[\"wotex-home.native-setup-authority.v1\",\"ensured\",\"\(deployment)\",\"\(owner)\",7,\"operator\",\"native-setup-v1:7:operator\",3]"
        let decoded = try NativeCoreWire.receipt(Data(receipt.utf8), scope: scope, role: .operator)
        try check(decoded.revision == 3 && decoded.principal == "native-setup-v1:7:operator")
        try refused { try NativeCoreWire.receipt(Data(receipt.utf8), scope: scope, role: .transfer) }
        try refused { try NativeCoreWire.receipt(Data(receipt.replacingOccurrences(of: owner, with: deployment).utf8), scope: scope, role: .operator) }

        for role in NativeCustodyRole.allCases {
            let bytes = Data("[\"wotex-home.native-credential-broker.v1\",\"credential\",\"\(role.rawValue)\"]".utf8)
            try check(try NativeBrokerWire.request(bytes) == .credential(role))
            try check(try NativeBrokerWire.request(.credential(role)) == bytes)
        }
        try check(try NativeBrokerWire.request(Data("[\"wotex-home.native-credential-broker.v1\",\"status\"]".utf8)) == .status)
        let status = Data("[\"wotex-home.native-credential-broker.v1\",\"status\",\"\(deployment)\",\"\(owner)\",7,9]".utf8)
        try check(try NativeBrokerWire.status(status) == scope)
        try check(try NativeBrokerWire.status(scope) == status)
        let credential = Data("[\"wotex-home.native-credential-broker.v1\",\"credential\",\"\(deployment)\",\"\(owner)\",7,\"operator\",\"native-setup-v1:7:operator\",3,\"\(String(repeating: "A", count: 43))\"]".utf8)
        let record = try NativeBrokerWire.credential(credential, role: .operator)
        try check(record.bytes == Data(repeating: 0, count: 32) && record.receipt == decoded)
        try check(try NativeBrokerWire.credential(record) == credential)
        try check(record.description == "private_native_credential_record")
        try check(String(reflecting: record) == "private_native_credential_record")
        try check(Mirror(reflecting: record).children.isEmpty)
        try refused { try NativeBrokerWire.credential(credential, role: .diagnostic) }
        let noncanonical = String(decoding: credential, as: UTF8.self).replacingOccurrences(of: String(repeating: "A", count: 43), with: String(repeating: "A", count: 42) + "B")
        try refused { try NativeBrokerWire.credential(Data(noncanonical.utf8), role: .operator) }
        try refused { try NativeBrokerWire.credential(Data(String(decoding: credential, as: UTF8.self).replacingOccurrences(of: "native-setup-v1:7:operator", with: "native-setup-v1:8:operator").utf8), role: .operator) }

        for reason in NativeCoreWire.reasons {
            let body = Data("[\"wotex-home.native-setup-authority.v1\",\"error\",\"\(reason)\"]".utf8)
            try check(try NativeCoreWire.error(body) == reason)
        }
        for reason in NativeBrokerWire.reasons {
            let body = Data("[\"wotex-home.native-credential-broker.v1\",\"error\",\"\(reason)\"]".utf8)
            try check(try NativeBrokerWire.error(reason) == body)
            try check(try NativeBrokerWire.error(body) == reason)
        }
        try refused { try NativeBrokerWire.error("raw_exception") }
        for invalid in [
            identity.replacingOccurrences(of: ",7,", with: ",7.0,"),
            identity.replacingOccurrences(of: ",7,", with: ",true,"),
            identity.replacingOccurrences(of: ",7,", with: ",9223372036854775808,"),
            identity.replacingOccurrences(of: ",7,", with: ",-1,"),
            identity.replacingOccurrences(of: "identity", with: "\\u0069dentity"),
            " " + identity, identity + "\n", "[" + identity + "]", "{\"a\":1,\"a\":2}",
            "[\"a\",0,0,0,0,0,0,0,0,0]", "[\"" + String(repeating: "a", count: 129) + "\",0]",
            String(repeating: "[", count: 2000) + "0" + String(repeating: "]", count: 2000),
        ] {
            try refused { try NativeScalarJSON.decode(Data(invalid.utf8)) }
        }
        try refused { try NativeBrokerWire.request(Data("[\"wotex-home.native-credential-broker.v1\",\"credential\",\"qualifier\"]".utf8)) }
        try refused { try NativeBrokerWire.request(Data("[\"wotex-home.native-credential-broker.v1\",\"status\",0]".utf8)) }
        print("native setup independent wire and rejection vectors passed")
    }

    private static func check(_ value: Bool) throws {
        guard value else { throw WireSmokeError.failed }
    }

    private static func refused<T>(_ operation: () throws -> T) throws {
        do { _ = try operation() }
        catch is NativeSetupWireError { return }
        throw WireSmokeError.failed
    }
}
