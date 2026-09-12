#if RELAY_AUTH_SELF_TESTS
import Foundation

@main private struct RelayAuthSelfTests {
    static func main() async throws {
        let expected = try RelayJSON(data: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        var checks: [RelayJSON] = []
        let vectors = try (expected["vectors"].array ?? []).map { item -> RelayJSON in
            let pairing = try RelayPairing(scannedURL: item.requiringString("url"))
            let proof = try pairing.challengeProof(nonce: item.requiringString("nonce"))
            return .object(["sid": item["sid"], "matchesOfficialFunction": .bool(proof == item["proof"].string)])
        }
        checks.append(.object(["name": .string("production_hmac_matches_current_official_functions"), "passed": .bool(vectors.count == 3 && vectors.allSatisfy { $0["matchesOfficialFunction"].bool == true }), "vectors": .array(vectors)]))

        let socket = MockRelaySocket(), client = try RelayClient(clientID: "auth-envelope-test", transport: socket, requestTimeout: 2)
        let mockVector = expected["vectors"].array!.first { $0["sid"].string == "mock-desktop" }!
        try await client.connect(pairing: RelayPairing(scannedURL: mockVector.requiringString("url")), confirmedControllerReplacement: true)
        _ = try await client.bootstrap(); _ = try await client.openWorkspace(key: "/workspace")
        // Exercise sendIPC's fragment batch, in addition to the single app/data path.
        _ = try await client.rpc("zcode-task", "listTasks", ["syntheticEnvelopePadding": .string(String(repeating: "x", count: 700_000))])
        let deadline = ContinuousClock.now + .seconds(12)
        while ContinuousClock.now < deadline {
            let sent = await socket.serializedOutgoingEnvelopes
            if sent.contains(where: { (try? RelayJSON(data: Data($0.utf8)))?["type"].string == "pair_status_query" }) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let serialized = await socket.serializedOutgoingEnvelopes
        let frames = try serialized.map { try RelayJSON(data: Data($0.utf8)) }
        let summaries = zip(serialized, frames).map { raw, frame -> RelayJSON in
            let range = raw.range(of: #""client_ts":[0-9]+(?=[,}])"#, options: .regularExpression)
            return .object(["type": frame["type"], "subtype": frame["payload"]["zcode_type"], "fragmentIndex": frame["payload"]["fragmentIndex"], "fragmentCount": frame["payload"]["fragmentCount"], "clientTimestamp": frame["client_ts"], "integerJSONToken": .bool(range != nil && frame["client_ts"].integer != nil)])
        }
        let singleData = frames.contains { $0["payload"]["zcode_type"].string == "bootstrap-request" }
        let batch = frames.filter { $0["payload"]["zcode_type"].string == "rpc-frame" && $0["payload"]["fragmentCount"].integer == 2 }
        let types = Set(frames.compactMap { $0["type"].string })
        let complete = types.isSuperset(of: ["auth_init", "auth_response", "data", "pair_status_query"]) && singleData && batch.count == 2
        let exactProof = frames.first { $0["type"].string == "auth_response" }?["proof"] == mockVector["proof"]
        checks.append(.object(["name": .string("actual_socket_serialization_has_integer_timestamps_on_all_five_paths"), "passed": .bool(complete && exactProof && summaries.allSatisfy { $0["integerJSONToken"].bool == true }), "allPathsCaptured": .bool(complete), "batchFragmentCount": .int(batch.count), "actualAuthResponseMatchesOfficialProof": .bool(exactProof), "envelopes": .array(summaries)]))

        let auth = RelayFailure.rejected(code: "AUTH_FAILED", paired: false)
        checks.append(.object(["name": .string("safe_auth_failed_code_is_visible"), "passed": .bool(auth.code == "relay_rejected" && auth.message.contains("AUTH_FAILED"))]))
        let invalid = ["https://invalid.example/?hash=synthetic-sensitive", String(repeating: "A", count: 65)]
        checks.append(.object(["name": .string("url_and_overlong_rejection_codes_are_hidden"), "passed": .bool(invalid.allSatisfy { !RelayFailure.rejected(code: $0, paired: false).message.contains($0) })]))
        try await socket.kick()
        for _ in 0..<100 { if await client.state == .replaced { break }; try await Task.sleep(for: .milliseconds(10)) }
        let replaced = RelayFailure.rejected(code: "KICKED", paired: true)
        let terminalState = await client.state
        checks.append(.object(["name": .string("kicked_retains_controller_replaced_and_terminal_state"), "passed": .bool(replaced.code == "controller_replaced" && replaced.outcomeUncertain && terminalState == .replaced)]))
        await client.disconnect()
        let output: RelayJSON = .object(["checkedAt": .string(ISO8601DateFormatter().string(from: Date())), "passed": .bool(checks.allSatisfy { $0["passed"].bool == true }), "checks": .array(checks), "realNetwork": .bool(false), "realCredentials": .bool(false), "modelRequests": .int(0)])
        let bytes = try output.data(); try bytes.write(to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .atomic)
        print(String(data: bytes, encoding: .utf8)!)
        if output["passed"].bool != true { exit(1) }
    }
}
#endif
