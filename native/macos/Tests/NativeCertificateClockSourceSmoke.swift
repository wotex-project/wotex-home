import Foundation

private enum ClockSourceSmokeError: Error { case failed(Int) }

@main
struct NativeCertificateClockSourceSmoke {
    static func main() {
        do {
            try check(CommandLine.arguments.count == 2)
            let bytes = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
            let document = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
            let vectors = document["vectors"] as! [[String: Any]]
            try check(vectors.count == 6)
            try check(try NativeCertificateClockWire.runtime(team: "FIXTURE001", executable: Data(repeating: 49, count: 20),
                bundle: Data(repeating: 50, count: 20)) == document["runtime"] as! String)
            var intervals = 0, continuity = 0
            for vector in vectors {
                let policy = Data((vector["policy"] as! String).utf8)
                let request = Data((vector["request"] as! String).utf8)
                let package = Data((vector["package"] as! String).utf8)
                let receipt = (vector["response_elapsed"] as! NSNumber).int64Value
                let p = try NativeCertificateClockPolicy.decode(policy)
                try check(try p.encoded() == policy)
                try check(try NativeCertificateClockRequest.decode(request).encoded() == request)
                try check(try NativeCertificateClockPackage.decode(package).encoded() == package)
                for row in vector["continuity"] as! [[String: Any]] {
                    try check(NativeCertificateClockWire.continuityAllowed(policy: p,
                        wallElapsed: (row["wall"] as! NSNumber).int64Value,
                        continuousElapsed: (row["continuous"] as! NSNumber).int64Value) == row["expected"] as! Bool)
                    continuity += 1
                }
                if vector["accepted"] as! Bool {
                    let lease = try NativeCertificateClockLease(policy: policy, request: request, package: package, responseElapsed: receipt)
                    try check(lease.customMirror.children.isEmpty)
                    for row in vector["lookups"] as! [[String: Any]] {
                        let elapsed = (row["elapsed"] as! NSNumber).int64Value
                        if let expected = row["expected"] as? [NSNumber] {
                            let found = try lease.bounds(elapsed: elapsed)
                            try check(found == NativeCertificateClockInterval(earliest: expected[0].int64Value, latest: expected[1].int64Value))
                        } else { try refused(.clockUnavailable) { _ = try lease.bounds(elapsed: elapsed) } }
                        intervals += 1
                    }
                    try refused(.expired) { _ = try lease.bounds(elapsed: p.ageMilliseconds) }
                    try refused(.clockUnavailable) { _ = try lease.bounds(elapsed: -1) }
                    if receipt > 0 { try refused(.clockUnavailable) { _ = try lease.bounds(elapsed: receipt - 1) } }
                    try refused(.expired) { _ = try NativeCertificateClockLease(policy: policy, request: request, package: package, responseElapsed: p.responseMilliseconds) }
                    try refused(.clockUnavailable) { _ = try NativeCertificateClockLease(policy: policy, request: request, package: package, responseElapsed: -1) }
                } else {
                    try refused(.clockUnavailable) { _ = try NativeCertificateClockLease(policy: policy, request: request, package: package, responseElapsed: receipt) }
                    intervals += 1
                }
            }
            try mutations(vectors[0])
            print("native certificate clock 6 independent signatures, \(intervals) interval vectors, \(continuity) continuity vectors and closed-document/scope/timing refusals passed")
        } catch ClockSourceSmokeError.failed(let line) {
            FileHandle.standardError.write(Data("native certificate clock assertion failed at line \(line)\n".utf8)); exit(1)
        } catch {
            FileHandle.standardError.write(Data("native certificate clock fixture failed: \(String(reflecting: type(of: error)))\n".utf8)); exit(1)
        }
    }

    private static func mutations(_ vector: [String: Any]) throws {
        let policy = Data((vector["policy"] as! String).utf8), request = Data((vector["request"] as! String).utf8)
        let package = Data((vector["package"] as! String).utf8)
        let originalPolicy = try array(policy), originalRequest = try array(request), originalPackage = try array(package)
        func lease(_ p: Data = policy, _ r: Data = request, _ answer: Data = package) throws {
            _ = try NativeCertificateClockLease(policy: p, request: r, package: answer, responseElapsed: 0)
        }
        let policyChanges: [Any] = ["wotex-home.schedule-clock-policy.v1", "other:source", "other:issuer",
            NativeControllerPairingWire.base64(Data(repeating: 3, count: 32)), 2, "other:procedure",
            String(repeating: "b", count: 64), String(repeating: "b", count: 64), 2000, 11000, 20, 200, 6]
        for index in originalPolicy.indices {
            var changed = originalPolicy; changed[index] = policyChanges[index]
            try refused { try lease(encode(changed)) }
        }
        let requestChanges: [Any] = ["wotex-home.controller-clock-request.v1", "org.wotex.home.agent",
            String(repeating: "b", count: 64), NativeControllerPairingWire.base64(Data(repeating: 3, count: 32)), String(repeating: "b", count: 64)]
        for index in originalRequest.indices {
            var changed = originalRequest; changed[index] = requestChanges[index]
            try refused { try lease(policy, encode(changed)) }
        }
        var record = originalPackage[1] as! [Any]
        for index in record.indices {
            var changed = record
            changed[index] = index == 5 ? 1_792_065_600_001 : "substituted"
            var answer = originalPackage; answer[1] = changed
            try refused { try lease(policy, request, encode(answer)) }
        }
        var wrongSignature = originalPackage
        wrongSignature[2] = NativeControllerPairingWire.base64(Data(repeating: 0, count: 64))
        try refused(.invalidSignature) { try lease(policy, request, encode(wrongSignature)) }
        var wrongKey = originalPolicy
        wrongKey[3] = NativeControllerPairingWire.base64(Data(repeating: 3, count: 32))
        let wrongPolicy = try encode(wrongKey)
        var changedRequest = originalRequest; changedRequest[4] = NativeCertificateClockWire.hash(wrongPolicy)
        record[4] = changedRequest[4]
        var changedAnswer = originalPackage; changedAnswer[1] = record
        try refused(.invalidSignature) { try lease(wrongPolicy, encode(changedRequest), encode(changedAnswer)) }

        for bytes in [policy, request, package] {
            var expanded = try array(bytes); expanded.append("extra")
            let bad = [Data(" ".utf8) + bytes, bytes + Data("\n".utf8), Data(bytes.dropLast()),
                try encode(expanded), Data("[[[[1]]]]".utf8), Data(repeating: 91, count: 4097)]
            for item in bad { try refused { try lease(item, item, item) } }
        }
        for json in ["[true]", "[null]", "[1.0]", "[1e0]", "[-1]", "[9223372036854775808]",
                     "[\"\\u0061\"]", "{\"a\":1}", "[\"" + String(repeating: "a", count: 129) + "\"]",
                     "[" + Array(repeating: "1", count: 17).joined(separator: ",") + "]"] {
            try refused(.invalidDocument) { _ = try NativeCertificateClockWire.decode(Data(json.utf8)) }
        }
        for invalid: Any in [true, NSNull(), -1, Double.nan, ["key": "value"], String(repeating: "a", count: 129)] {
            try refused(.invalidDocument) { _ = try NativeCertificateClockWire.encode([invalid]) }
        }
        for index in [3, 4, 8, 9, 10, 11, 12] {
            var changed = originalPolicy
            changed[index] = index == 3 ? "AA==" : (index == 4 ? Int64(0) : Int64.max)
            try refused(.invalidDocument) { _ = try NativeCertificateClockPolicy.decode(encode(changed)) }
        }
        var maximumGeneration = originalPolicy; maximumGeneration[4] = Int64.max
        try check(try NativeCertificateClockPolicy.decode(encode(maximumGeneration)).generation == Int64.max)
        var padded = originalRequest; padded[3] = (padded[3] as! String) + "="
        try refused(.invalidDocument) { _ = try NativeCertificateClockRequest.decode(encode(padded)) }
        try refused(.invalidDocument) { _ = try NativeCertificateClockWire.runtime(team: "bad", executable: Data([1]), bundle: Data([2])) }
        try refused(.invalidDocument) { _ = try NativeCertificateClockWire.runtime(team: "FIXTURE001", executable: Data(), bundle: Data([2])) }
        // Rolling two-ms corrections alone pass; the original cumulative check
        // independently refuses their total. Neither result establishes UTC.
        let p = try NativeCertificateClockPolicy.decode(policy)
        try check(NativeCertificateClockWire.continuityAllowed(policy: p, wallElapsed: 1002, continuousElapsed: 1000))
        try check(!NativeCertificateClockWire.continuityAllowed(policy: p, wallElapsed: 10010, continuousElapsed: 9990))
    }
    private static func array(_ bytes: Data) throws -> [Any] { try JSONSerialization.jsonObject(with: bytes) as! [Any] }
    private static func encode(_ value: [Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.withoutEscapingSlashes]) }
    private static func check(_ condition: Bool, line: Int = #line) throws { if !condition { throw ClockSourceSmokeError.failed(line) } }
    private static func refused(_ expected: NativeCertificateClockError? = nil, line: Int = #line, _ work: () throws -> Void) throws {
        do { try work() } catch let error as NativeCertificateClockError {
            try check(expected == nil || expected == error, line: line); return
        }
        throw ClockSourceSmokeError.failed(line)
    }
}
