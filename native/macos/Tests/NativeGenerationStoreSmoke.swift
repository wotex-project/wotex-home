import Foundation

enum GenerationStoreAssertion: Error { case failed(Int) }

enum NativeGenerationStoreSmoke {
    static func run(socket: String, startOnly: Bool = false) throws {
        var stage = #line
        do {
            guard let line = readLine(), let input = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let encoded = input["credential"] as? String, let credential = Data(base64Encoded: encoded),
                  let preparation = input["preparation"] as? [String: Any], let journal = input["journal"] as? String else { throw GenerationStoreAssertion.failed(#line) }
            stage = #line
            let original = try NativeGenerationOriginalWire.encode(preparation, kind: .preparation)
            stage = #line
            let options = try NativeGenerationClient.fetchOptions(socketPath: socket, credential: credential)
            try require(options.epoch == original.epoch && options.revision == original.expectedRevision && options.policyCount == 1)
            stage = #line
            let fields = try options.fields(), row = (fields["policies"] as! [[String: Any]])[0]
            try require(row["policy_sha256"] as? String == preparation["policy_sha256"] as? String && row["provider_present"] as? Bool == true)
            try require(try NativeGenerationClient.status(socketPath: socket, credential: credential, kind: .preparation,
                epoch: original.epoch, operation: original.operation, original: original) == nil)
            stage = #line
            let identity = try LocalHealthClient.fetchControllerIdentity(socketPath: socket, credential: credential)
            let context = NativePendingContext(deployment: identity.deploymentID, owner: identity.ownerID,
                epoch: Int64(identity.authorityEpoch), principal: identity.principalID)
            let custody = NativePendingCustody.manual(verifier: LocalHealthClient.profileSHA(credential))
            let entry = NativePendingEntry(context: context, custody: custody, input: .generation(original), phase: .pending)
            let directory = URL(fileURLWithPath: journal, isDirectory: true)
            stage = #line
            let published = try NativePendingStorage.retaining(entry, directory: directory, expected: .empty)
            try require(published.document.version == .v7 && NativePendingStorage.load(directory: directory) == published)
            stage = #line
            do {
                _ = try NativeGenerationClient.submit(socketPath: socket, credential: credential, original: original)
                throw GenerationStoreAssertion.failed(#line)
            } catch NativeGenerationDeliveryError.outcomeUnknown {}
            guard let prepared = try NativeGenerationClient.status(socketPath: socket, credential: credential, kind: .preparation,
                epoch: original.epoch, operation: original.operation, original: original) else { throw GenerationStoreAssertion.failed(#line) }
            let receipt = prepared.original
            try receipt.matches(original)
            try require(try LocalHealthClient.fetchControllerIdentity(socketPath: socket, credential: credential).revision == Int(receipt.revision))
            stage = #line
            let recovered = try NativePendingRecoveryOperations.execute(entry, credential: credential, socketPath: socket, action: .retry)
            guard case .resolved = recovered else { throw GenerationStoreAssertion.failed(#line) }
            stage = #line
            let empty = try NativePendingStorage.resolving(entry, directory: directory, expected: published)
            try require(try LocalHealthClient.fetchControllerIdentity(socketPath: socket, credential: credential).revision == Int(receipt.revision))
            let attemptInput: [String: Any] = ["authority_epoch": original.epoch, "operation_id": "attempt:native", "expected_revision": receipt.revision,
                "preparation_operation_id": original.operation, "preparation_sha256": original.sha, "attempt": 1,
                "previous_operation_id": NSNull(), "repair_export": false]
            stage = #line
            let attempt = try NativeGenerationOriginalWire.encode(attemptInput, kind: .attempt)
            let pendingAttempt = NativePendingEntry(context: context, custody: custody, input: .generation(attempt), phase: .pending)
            stage = #line
            let retained = try NativePendingStorage.retaining(pendingAttempt, directory: directory, expected: empty)
            stage = #line
            do {
                _ = try NativePendingRecoveryOperations.execute(pendingAttempt, credential: credential, socketPath: socket, action: .retry)
                throw GenerationStoreAssertion.failed(#line)
            } catch NativeGenerationDeliveryError.outcomeUnknown {}
            let handed = try NativePendingRecoveryOperations.execute(pendingAttempt, credential: credential, socketPath: socket, action: .lookup)
            guard case .retained(let detail) = handed else { throw GenerationStoreAssertion.failed(#line) }
            try require(try NativePendingStorage.load(directory: directory) == retained)
            if !startOnly { try require(detail.lowercased().contains("unknown")) }
            if startOnly {
                let absent = try NativePendingRecoveryOperations.execute(pendingAttempt, credential: credential, socketPath: socket, action: .acknowledgeAbsent)
                guard case .retained = absent else { throw GenerationStoreAssertion.failed(#line) }
                try require(try NativePendingStorage.load(directory: directory) == retained)
                print("native generation restart reservation retained")
                return
            }
            stage = #line
            var status: HomeGenerationStatus?
            let deadline = ContinuousClock.now.advanced(by: .seconds(4))
            repeat {
                status = try NativeGenerationClient.status(socketPath: socket, credential: credential, kind: .attempt,
                    epoch: attempt.epoch, operation: attempt.operation, original: attempt)
                if status?.result != nil { break }
                try require(ContinuousClock.now < deadline); Thread.sleep(forTimeInterval: 0.01)
            } while true
            guard let candidate = status?.result, candidate.disposition == "candidate", let assessment = candidate.assessment else { throw GenerationStoreAssertion.failed(#line) }
            let assessmentFields = try assessment.fields()
            try require(assessmentFields["source_review"] as? String == "not_assessed" && assessmentFields["fixture_status"] as? String == "not_supplied")
            stage = #line
            let complete = try NativePendingRecoveryOperations.execute(pendingAttempt, credential: credential, socketPath: socket, action: .retry)
            guard case .resolved = complete else { throw GenerationStoreAssertion.failed(#line) }
            stage = #line
            let resolved = try NativePendingStorage.resolving(pendingAttempt, directory: directory, expected: retained)
            try require(resolved.document.version == .v7 && resolved.document.entries.isEmpty)
            stage = #line
            let cancelled = try NativeGenerationClient.cancel(socketPath: socket, credential: credential, original: original)
            try require(cancelled?.state == "cancelled" && cancelled?.cancellationRevision != nil)
            stage = #line
            let cancellation = cancelled!.knownRevision
            try require(try NativeGenerationClient.cancel(socketPath: socket, credential: credential, original: original)?.knownRevision == cancellation)
            var refused = attemptInput; refused["operation_id"] = "attempt:after-cancel"; refused["expected_revision"] = cancellation
            let refusedOriginal = try NativeGenerationOriginalWire.encode(refused, kind: .attempt)
            let refusedEntry = NativePendingEntry(context: context, custody: custody, input: .generation(refusedOriginal), phase: .pending)
            let refusedSnapshot = try NativePendingStorage.retaining(refusedEntry, directory: directory, expected: resolved)
            do {
                _ = try NativeGenerationClient.submit(socketPath: socket, credential: credential,
                    original: refusedOriginal)
                throw GenerationStoreAssertion.failed(#line)
            } catch LocalHealthError.server(let reason) { try require(reason == "generation_cancelled") }
            try require(try NativePendingStorage.load(directory: directory) == refusedSnapshot)
            let missing = try NativePendingRecoveryOperations.execute(refusedEntry, credential: credential, socketPath: socket, action: .lookup)
            guard case .retained = missing else { throw GenerationStoreAssertion.failed(#line) }
            let acknowledged = try NativePendingRecoveryOperations.execute(refusedEntry, credential: credential, socketPath: socket, action: .acknowledgeAbsent)
            guard case .resolved(let acknowledgement) = acknowledged, acknowledgement.contains("may arrive later") else { throw GenerationStoreAssertion.failed(#line) }
            let cleared = try NativePendingStorage.resolving(refusedEntry, directory: directory, expected: refusedSnapshot)
            try require(cleared.document.version == .v7 && cleared.document.entries.isEmpty)
            try require(try LocalHealthClient.fetchControllerIdentity(socketPath: socket, credential: credential).revision == Int(cancellation))
            print("native generation Store original publication, candidate and cancellation passed")
        } catch let error as GenerationStoreAssertion { throw error }
        catch { throw GenerationStoreAssertion.failed(stage) }
    }
    static func restart(socket: String) throws {
        guard let line = readLine(), let input = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let encoded = input["credential"] as? String, let credential = Data(base64Encoded: encoded),
              let journal = input["journal"] as? String else { throw GenerationStoreAssertion.failed(#line) }
        let directory = URL(fileURLWithPath: journal, isDirectory: true)
        let snapshot = try NativePendingStorage.load(directory: directory)
        try require(snapshot.document.version == .v7 && snapshot.document.entries.count == 1)
        let entry = snapshot.document.entries[0], original = try entry.generationOperation()
        let status = try NativeGenerationClient.status(socketPath: socket, credential: credential, kind: .attempt,
            epoch: original.epoch, operation: original.operation, original: original)
        try require(status?.state == "unknown" && status?.result == nil && status?.resultRevision == nil)
        let before = try LocalHealthClient.fetchControllerIdentity(socketPath: socket, credential: credential)
        let uncertain = try NativePendingRecoveryOperations.execute(entry, credential: credential, socketPath: socket, action: .retry)
        guard case .retained(let unknown) = uncertain, unknown.contains("unknown") else { throw GenerationStoreAssertion.failed(#line) }
        try require(try NativePendingStorage.load(directory: directory) == snapshot)
        let missingAcknowledgement = try NativePendingRecoveryOperations.execute(entry, credential: credential, socketPath: socket, action: .acknowledgeAbsent)
        guard case .retained(let retainedUnknown) = missingAcknowledgement, retainedUnknown.contains("unknown") else { throw GenerationStoreAssertion.failed(#line) }
        try require(try NativePendingStorage.load(directory: directory) == snapshot)
        let result = try NativePendingRecoveryOperations.execute(entry, credential: credential, socketPath: socket, action: .acknowledgeUnknown)
        guard case .resolved(let detail) = result, detail.lowercased().contains("unknown") else { throw GenerationStoreAssertion.failed(#line) }
        let after = try LocalHealthClient.fetchControllerIdentity(socketPath: socket, credential: credential)
        try require(after.revision == before.revision)
        let resolved = try NativePendingStorage.resolving(entry, directory: directory, expected: snapshot)
        try require(resolved.document.version == .v7 && resolved.document.entries.isEmpty)
        print("native generation restart unknown original recovered without resuming provider")
    }
    private static func require(_ condition: Bool, line: Int = #line) throws { if !condition { throw GenerationStoreAssertion.failed(line) } }
}
