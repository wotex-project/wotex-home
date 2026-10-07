import Foundation

private enum TargetSmokeError: Error { case failed }

@main
struct NativeTargetWireSmoke {
    static func main() throws {
        let a = String(repeating: "a", count: 64), b = String(repeating: "b", count: 64)
        let c = String(repeating: "c", count: 64), d = String(repeating: "d", count: 64)
        let grant = "[\"wotex-home.native-target-access.v1\",\"grant\",\"\(a)\",\"\(b)\",7,3,\"\(c)\",\"access:one\",9,\"light:one\",4,5,2,\"\(d)\"]"
        let revoke = "[\"wotex-home.native-target-access.v1\",\"revoke\",\"\(a)\",\"\(b)\",7,3,\"\(c)\",\"access:two\",11,\"light:one\"]"
        let status = "[\"wotex-home.native-target-access.v1\",\"status\",\"\(a)\",\"\(b)\",7,3,\"\(c)\",\"access:one\"]"
        let change = try NativeTargetWire.change(Data(grant.utf8))
        try check(change.action == .grant && change.target == "light:one" && change.basis?.generation == 2)
        try check(try NativeTargetWire.change(change) == Data(grant.utf8))
        let removal = try NativeTargetWire.change(Data(revoke.utf8))
        try check(removal.action == .revoke && removal.basis == nil)
        try check(try NativeTargetWire.change(removal) == Data(revoke.utf8))
        let (original, operation) = try NativeTargetWire.status(Data(status.utf8))
        try check(original == change.original && operation == change.operation)
        try check(try NativeTargetWire.status(original: original, operation: operation) == Data(status.utf8))
        try check(String(reflecting: change) == "private_native_target_change" && Mirror(reflecting: change).children.isEmpty)
        let digest = NativeTargetWire.digest(Data(grant.utf8))
        try check(digest == "3cb0cc8dd8705ee7d071c5677ada5c1bd63e71880dfbc9f764e0f027747cebc2")
        let receipt = "[\"wotex-home.native-target-access.v1\",\"receipt\",\"\(a)\",\"\(b)\",7,\"native-setup-v1:7:operator\",\"access:one\",\"grant\",\"light:one\",\"\(digest)\",9,10,12,2,1]"
        guard case .receipt(let found) = try NativeTargetWire.reply(Data(receipt.utf8), matching: change) else { throw TargetSmokeError.failed }
        try check(found.changeRevision == 10 && found.finalRevision == 12 && found.affected == 2 && found.unknown == 1)
        let missing = status.replacingOccurrences(of: "\"status\"", with: "\"not_found\"")
        try check(try NativeTargetWire.reply(Data(missing.utf8), matching: change) == .notFound)
        for reason in NativeTargetWire.reasons {
            let bytes = Data("[\"wotex-home.native-target-access.v1\",\"error\",\"\(reason)\"]".utf8)
            try check(try NativeTargetWire.reply(bytes, matching: change) == .rejected(reason))
        }
        for malformed in [
            grant.replacingOccurrences(of: ",7,", with: ",7.0,"),
            grant.replacingOccurrences(of: ",7,", with: ",true,"),
            grant.replacingOccurrences(of: ",7,", with: ",07,"),
            grant.replacingOccurrences(of: ",7,", with: ",0,"),
            grant.replacingOccurrences(of: ",7,", with: ",9223372036854775808,"),
            grant.replacingOccurrences(of: ",9,", with: ",9223372036854775807,"),
            grant.replacingOccurrences(of: ",9,", with: ",2,"),
            grant.replacingOccurrences(of: ",4,5,2,", with: ",0,5,2,"),
            grant.replacingOccurrences(of: c, with: c.uppercased()),
            grant.replacingOccurrences(of: "light:one", with: "light/one"),
            grant.replacingOccurrences(of: "access:one", with: String(repeating: "x", count: 129)),
            grant.replacingOccurrences(of: "grant", with: "\\u0067rant"),
            " " + grant, grant + "\n", grant + "[]", "[" + grant + "]",
            "{\"a\":1,\"a\":2}", "[\"wotex-home.native-target-access.v1\",\"grant\",null]",
            "[" + Array(repeating: "0", count: 17).joined(separator: ",") + "]",
            String(repeating: "[", count: 1000) + "0" + String(repeating: "]", count: 1000),
            String(repeating: " ", count: 4097),
        ] { try refused { try NativeTargetWire.change(Data(malformed.utf8)) } }
        for malformed in [
            receipt.replacingOccurrences(of: digest, with: d),
            receipt.replacingOccurrences(of: "native-setup-v1:7:operator", with: "native-setup-v1:7:maintenance"),
            receipt.replacingOccurrences(of: "light:one", with: "light:other"),
            receipt.replacingOccurrences(of: ",9,10,12,2,1]", with: ",9,10,13,2,1]"),
            receipt.replacingOccurrences(of: ",9,10,12,2,1]", with: ",9,10,12,2,3]"),
            receipt.replacingOccurrences(of: ",9,10,12,2,1]", with: ",9,10,1035,1025,0]"),
            receipt.replacingOccurrences(of: "access:one", with: "access:other"),
            missing.replacingOccurrences(of: c, with: d),
            "[\"wotex-home.native-target-access.v1\",\"error\",\"raw_exception\"]",
        ] { try refused { try NativeTargetWire.reply(Data(malformed.utf8), matching: change) } }
        try refused { try NativeTargetWire.reply(Data(receipt.utf8), matching: removal) }
        // The setup/broker's earlier membership bound stays independent.
        try refused { try NativeScalarJSON.decode(Data(grant.utf8)) }
        print("native target independent wire and original receipt vectors passed")
    }

    private static func check(_ value: Bool) throws { guard value else { throw TargetSmokeError.failed } }
    private static func refused<T>(_ call: () throws -> T) throws {
        do { _ = try call() } catch NativeSetupWireError.invalidRecord { return }
        throw TargetSmokeError.failed
    }
}
