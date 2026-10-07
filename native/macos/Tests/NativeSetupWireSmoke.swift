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
        try endpointChecks(scope)
        let credential = Data("[\"wotex-home.native-credential-broker.v1\",\"credential\",\"\(deployment)\",\"\(owner)\",7,\"operator\",\"native-setup-v1:7:operator\",3,\"\(String(repeating: "A", count: 43))\"]".utf8)
        let record = try NativeBrokerWire.credential(credential, role: .operator)
        try check(record.bytes == Data(repeating: 0, count: 32) && record.receipt == decoded)
        try check(try NativeBrokerWire.credential(record) == credential)
        try check(record.description == "private_native_credential_record")
        try check(String(reflecting: record) == "private_native_credential_record")
        try check(Mirror(reflecting: record).children.isEmpty)
        try originalChecks(receipt: decoded, scope: scope, record: record)
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

    private static func endpointChecks(_ scope: NativeControllerScope) throws {
        let request = Data("[\"wotex-home.native-credential-broker.v1\",\"endpoint\"]".utf8)
        try check(try NativeBrokerWire.request(request) == .endpoint)
        try check(try NativeBrokerWire.request(.endpoint) == request)
        let encodedToken = String(repeating: "A", count: 43)
        let literal = "[\"wotex-home.native-credential-broker.v1\",\"endpoint\",\"\(scope.deployment)\",\"\(scope.owner)\",7,9,\"\(encodedToken)\"]"
        let metadata = try NativeBrokerWire.endpoint(Data(literal.utf8))
        try check(metadata.scope == scope && metadata.auditToken == Data(repeating: 0, count: 32))
        try check(try NativeBrokerWire.endpoint(metadata) == Data(literal.utf8))
        try check(Mirror(reflecting: metadata).children.isEmpty)
        for malformed in [
            literal.replacingOccurrences(of: encodedToken, with: encodedToken + "="),
            literal.replacingOccurrences(of: encodedToken, with: String(repeating: "A", count: 42) + "B"),
            literal.replacingOccurrences(of: encodedToken, with: String(repeating: "A", count: 42)),
            literal.replacingOccurrences(of: encodedToken, with: String(repeating: "/", count: 43)),
            literal.replacingOccurrences(of: ",7,", with: ",true,"),
            literal.replacingOccurrences(of: ",7,", with: ",7.0,"),
            literal.replacingOccurrences(of: ",7,", with: ",0,"),
            literal.replacingOccurrences(of: ",9,", with: ",-1,"),
            literal.replacingOccurrences(of: scope.deployment, with: scope.deployment.uppercased()),
            literal.replacingOccurrences(of: scope.owner, with: "short"),
            literal.dropLast() + ",0]", " " + literal, literal + "\n",
        ] { try refused { try NativeBrokerWire.endpoint(Data(malformed.utf8)) } }
        try refused { try NativeBrokerWire.request(Data("[\"wotex-home.native-credential-broker.v1\",\"endpoint\",0]".utf8)) }
    }

    private static func refused<T>(_ operation: () throws -> T) throws {
        do { _ = try operation() }
        catch is NativeSetupWireError { return }
        throw WireSmokeError.failed
    }

    private static func originalChecks(receipt: NativeCreationReceipt, scope: NativeControllerScope,
                                       record: NativeCredentialRecord) throws {
        let verifier = String(repeating: "ab", count: 32)
        let original = NativeOriginalReference(receipt: receipt, verifier: verifier)
        let core = "[\"wotex-home.native-setup-authority.v1\",\"existing\",\"\(receipt.deployment)\",\"\(receipt.owner)\",7,\"operator\",\"\(verifier)\",3]"
        let broker = "[\"wotex-home.native-credential-broker.v1\",\"recover\",\"\(receipt.deployment)\",\"\(receipt.owner)\",7,\"operator\",\"\(verifier)\",3]"
        let found = "[\"wotex-home.native-setup-authority.v1\",\"found\",\"\(receipt.deployment)\",\"\(receipt.owner)\",7,\"operator\",\"native-setup-v1:7:operator\",3]"
        try check(try NativeCoreWire.existingRequest(original) == Data(core.utf8))
        try check(try NativeBrokerWire.request(.recover(original)) == Data(broker.utf8))
        try check(try NativeBrokerWire.request(Data(broker.utf8)) == .recover(original))
        try check(try NativeCoreWire.originalReceipt(Data(found.utf8), scope: scope, original: original) == receipt)
        try refused { try NativeCoreWire.originalReceipt(Data(found.replacingOccurrences(of: "found", with: "ensured").utf8), scope: scope, original: original) }
        try refused { try NativeCoreWire.originalReceipt(Data(found.replacingOccurrences(of: ",3]", with: ",4]").utf8), scope: scope, original: original) }
        for invalid in [
            broker.replacingOccurrences(of: ",3]", with: ",0]"),
            broker.replacingOccurrences(of: ",3]", with: ",true]"),
            broker.replacingOccurrences(of: ",3]", with: ",3.0]"),
            broker.replacingOccurrences(of: ",3]", with: ",9223372036854775808]"),
            broker.replacingOccurrences(of: ",3]", with: ",3,0]"),
            broker.replacingOccurrences(of: verifier, with: verifier.uppercased()),
            broker.replacingOccurrences(of: "operator", with: "qualifier"),
            " " + broker, broker + "\n",
        ] { try refused { try NativeBrokerWire.request(Data(invalid.utf8)) } }
        let matching = NativeOriginalReference(receipt: receipt,
            verifier: "66687aadf862bd776c8fc18b8e9f8e20089714856ee233b3902a591d0d5f2925")
        try check(matching.accepts(record) && !original.accepts(record))
        try check(!matching.accepts(NativeCredentialRecord(receipt: receipt, bytes: Data(repeating: 1, count: 32))))
        let changed = NativeCreationReceipt(deployment: receipt.deployment, owner: receipt.owner,
            epoch: receipt.epoch, role: receipt.role, principal: receipt.principal, revision: receipt.revision + 1)
        try check(!matching.accepts(NativeCredentialRecord(receipt: changed, bytes: record.bytes)))
        for changed in [
            NativeControllerScope(deployment: String(repeating: "c", count: 64), owner: scope.owner, epoch: 7, revision: 9),
            NativeControllerScope(deployment: scope.deployment, owner: String(repeating: "c", count: 64), epoch: 7, revision: 9),
            NativeControllerScope(deployment: scope.deployment, owner: scope.owner, epoch: 8, revision: 9),
            NativeControllerScope(deployment: scope.deployment, owner: scope.owner, epoch: 7, revision: 2),
        ] { try check(!original.matches(changed)) }
        try check(original.matches(scope))
        try check(Mirror(reflecting: original).children.isEmpty && String(reflecting: original) == "private_native_original_reference")
    }
}
