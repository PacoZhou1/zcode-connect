#if RELAY_RECOVERY_SELF_TESTS
import Foundation

private actor RecoveryEvents {
    var bridgeEvents: [BridgeEnvelope] = []
    var failureCode: String?
    func append(_ value: BridgeEnvelope) { bridgeEvents.append(value) }
    func failed(_ error: any Error) { failureCode = (error as? BridgeFailure)?.code ?? (error as? RelayFailure)?.code ?? String(describing: error) }
}

private struct RecoveryFixture {
    let socket: MockRelaySocket
    let client: RelayClient
    let adapter: RelayRemoteTransport
    let bridge: RelayBridge
    let bootstrap: RelayBootstrap
    let events: RecoveryEvents
    let observer: Task<Void, Never>
    let directory: URL
    func close() async {
        observer.cancel(); await client.disconnect(); await adapter.shutdown()
        try? FileManager.default.removeItem(at: directory)
    }
}

@main private struct RelayRecoverySelfTests {
    static let pairingURL = "https://zcode.z.ai/remote/v4?sid=mock-desktop&hash=mock-pairing-value-0123456789-abcdef"
    static func waitUntil(_ predicate: () async -> Bool, seconds: Double = 0.8) async throws {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline { if await predicate() { return }; try await Task.sleep(for: .milliseconds(10)) }
    }
    static func fixture(timeout: Double = 0.2) async throws -> RecoveryFixture {
        let socket = MockRelaySocket(), client = try RelayClient(clientID: "recovery-test-client", transport: socket, requestTimeout: timeout)
        try await client.connect(pairing: RelayPairing(scannedURL: pairingURL), confirmedControllerReplacement: true)
        let bootstrap = try await client.bootstrap(), bridge = try await client.openWorkspace(key: "/workspace")
        let directory = FileManager.default.temporaryDirectory.appending(path: "zcode-recovery-test-" + UUID().uuidString)
        let adapter = try await RelayRemoteTransport(client: client, bootstrap: bootstrap, bridge: bridge, hostName: "In-memory recovery fixture", journalDirectory: directory)
        let events = RecoveryEvents(), observer = Task { do { try await adapter.events(after: nil) { await events.append($0) } } catch { await events.failed(error) } }
        let _: RelayJSON = try await adapter.get("v1/sessions/session-test")
        try await waitUntil { await events.bridgeEvents.contains { $0.type == "ready" } }
        // The foreground facade has installed its observer before a fault is injected.
        try await Task.sleep(for: .milliseconds(20))
        return .init(socket: socket, client: client, adapter: adapter, bridge: bridge, bootstrap: bootstrap, events: events, observer: observer, directory: directory)
    }
    static func result(_ name: String, passed: Bool, _ facts: [String: RelayJSON]) -> RelayJSON {
        .object(facts.merging(["name": .string(name), "passed": .bool(passed)]) { _, next in next })
    }
    static func failedRecovery(_ behavior: String) async throws -> RelayJSON {
        let f = try await fixture()
        try await f.socket.sendOnlineText(from: 10, to: 11, ordinal: 2, text: " baseline live")
        try await waitUntil { await f.client.currentProjection(sessionID: "session-test")?.sequence == 11 }
        let baseline = await f.client.currentProjection(sessionID: "session-test")?.rows.first?["text"].string
        await f.socket.setRecoveryBehavior(behavior)
        try await f.socket.sendRecoveryGap(ordinal: 3)
        try await waitUntil { await f.client.state == .disconnected }
        let disconnected = await f.client.state == .disconnected
        var staleRefresh: String?
        if !disconnected {
            try await f.socket.sendOnlineText(from: 11, to: 12, ordinal: 4, text: " MUST NOT BE LOST")
            try await Task.sleep(for: .milliseconds(30))
            let detail: RelayJSON = try await f.adapter.get("v1/sessions/session-test")
            staleRefresh = detail["messages"].array?.first?["text"].string
        }
        let calls = await f.socket.recoveryRequests, connections = await f.socket.socketConnectCount
        let code = await f.events.failureCode, commands = await f.socket.sentCommandCount
        let answer = result("resync_" + behavior + "_ends_stale_online_stream", passed: baseline == "Hello baseline live" && disconnected && code == "relay_resync_failed" && calls == 1 && connections == 1 && commands == 0,
            ["baselineLiveText": baseline.map(RelayJSON.string) ?? .null, "disconnected": .bool(disconnected), "streamFailure": code.map(RelayJSON.string) ?? .null, "resyncCalls": .int(calls), "socketConnects": .int(connections), "modelCommands": .int(commands), "ordinaryRefreshTextIfStillConnected": staleRefresh.map(RelayJSON.string) ?? .null])
        await f.close(); return answer
    }
    static func snapshotBeforeMissingAck() async throws -> RelayJSON {
        let f = try await fixture(); await f.socket.setRecoveryBehavior("snapshotThenDropAck")
        try await f.socket.sendRecoveryGap()
        try await waitUntil { await f.client.currentProjection(sessionID: "session-test")?.sequence == 20 }
        try await Task.sleep(for: .milliseconds(350))
        try await f.socket.sendOnlineText(from: 20, to: 21, ordinal: 4, text: " and live tail")
        try await waitUntil { await f.client.currentProjection(sessionID: "session-test")?.sequence == 21 }
        let connected = await f.client.bridge == f.bridge, code = await f.events.failureCode
        let text = await f.client.currentProjection(sessionID: "session-test")?.rows.first?["text"].string
        let answer = result("valid_recovery_snapshot_survives_late_missing_ack", passed: connected && code == nil && text == "Recovered complete text and live tail", ["connected": .bool(connected), "streamFailure": code.map(RelayJSON.string) ?? .null, "text": text.map(RelayJSON.string) ?? .null])
        await f.close(); return answer
    }
    static func replacementError() async throws -> RelayJSON {
        let f = try await fixture(); try await f.socket.kick()
        try await waitUntil { await f.events.failureCode != nil }
        let replaced = await f.client.state == .replaced, code = await f.events.failureCode
        let connects = await f.socket.socketConnectCount
        let answer = result("controller_replaced_reaches_facade_without_reconnect", passed: replaced && code == "controller_replaced" && connects == 1, ["clientReplaced": .bool(replaced), "facadeError": code.map(RelayJSON.string) ?? .null, "socketConnects": .int(connects)])
        await f.close(); return answer
    }
    static func trafficWithoutHeartbeatAck() async throws -> RelayJSON {
        let f = try await fixture(); await f.socket.setDropHeartbeats(true)
        for index in 0..<5 {
            try await Task.sleep(for: .seconds(8))
            try await f.socket.sendOnlineText(from: 10 + index, to: 11 + index, ordinal: 2 + index, text: " synthetic live progress")
        }
        let online = await f.client.state != .disconnected
        let code = await f.events.failureCode
        let answer = result("incoming_data_prevents_false_heartbeat_timeout", passed: online && code == nil, ["stillConnectedAfter40Seconds": .bool(online), "heartbeatAcksSuppressed": .bool(true)])
        await f.close(); return answer
    }
    static func transportLoss(heartbeat: Bool) async throws -> RelayJSON {
        let f = try await fixture(), start = ContinuousClock.now
        if heartbeat { await f.socket.setDropHeartbeats(true) } else { await f.socket.failReceive() }
        try await waitUntil({ await f.events.failureCode != nil }, seconds: heartbeat ? 42 : 0.8)
        let elapsed = ContinuousClock.now - start
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let disconnected = await f.client.state == .disconnected, code = await f.events.failureCode, connects = await f.socket.socketConnectCount
        let expected = heartbeat ? "relay_heartbeat_timeout" : "relay_transport_failed"
        let answer = result(heartbeat ? "heartbeat_deadline_ends_stream_without_reconnect" : "receive_network_loss_ends_stream_without_reconnect", passed: disconnected && code == expected && connects == 1 && (!heartbeat || (seconds >= 29 && seconds <= 41)), ["disconnected": .bool(disconnected), "facadeError": code.map(RelayJSON.string) ?? .null, "socketConnects": .int(connects), "elapsedSeconds": .number(seconds)])
        await f.close(); return answer
    }
    static func newerRecoveryAttempt() async throws -> RelayJSON {
        let f = try await fixture(timeout: 0.35)
        await f.socket.setRecoveryBehavior("snapshotThenDropAck"); try await f.socket.sendRecoveryGap()
        try await waitUntil { await f.client.currentProjection(sessionID: "session-test")?.sequence == 20 }
        try await Task.sleep(for: .milliseconds(200))
        await f.socket.setRecoveryBehavior("ackOnly"); try await f.socket.sendRecoveryGap(ordinal: 4)
        try await waitUntil { await f.socket.recoveryRequests == 2 }
        // The first RPC has now timed out while the second recovery still has time left.
        try await Task.sleep(for: .milliseconds(230))
        let survivedOldTimeout = await f.client.bridge == f.bridge
        if survivedOldTimeout { try await f.socket.sendRecoverySnapshot(sequence: 30, ordinal: 5) }
        try await Task.sleep(for: .milliseconds(250))
        let connected = await f.client.bridge == f.bridge, sequence = await f.client.currentProjection(sessionID: "session-test")?.sequence
        let answer = result("late_error_from_recovered_attempt_cannot_cancel_new_recovery", passed: survivedOldTimeout && connected && sequence == 30, ["survivedOldTimeout": .bool(survivedOldTimeout), "connected": .bool(connected), "sequence": sequence.map(RelayJSON.int) ?? .null])
        await f.close(); return answer
    }
    static func obsoleteRecovery(_ reconnect: Bool) async throws -> RelayJSON {
        let f = try await fixture(); await f.socket.setRecoveryBehavior("ackOnly")
        try await f.socket.sendRecoveryGap(); try await waitUntil { await f.socket.recoveryRequests == 1 }
        try await Task.sleep(for: .milliseconds(25))
        await f.adapter.shutdown()
        if reconnect {
            await f.client.disconnect()
            try await f.client.connect(pairing: RelayPairing(scannedURL: pairingURL), confirmedControllerReplacement: true)
            _ = try await f.client.bootstrap()
        }
        let next = try await f.client.openWorkspace(key: "/workspace")
        _ = try await f.client.subscribe(sessionID: "session-test", resume: false)
        try await Task.sleep(for: .milliseconds(450))
        let connected = await f.client.bridge == next, different = next != f.bridge, calls = await f.socket.socketConnectCount
        let answer = result(reconnect ? "obsolete_recovery_cannot_close_explicit_new_connection" : "obsolete_recovery_cannot_close_new_workspace_generation", passed: connected && different && calls == (reconnect ? 2 : 1), ["newWorkspaceStillAttached": .bool(connected), "bridgeChanged": .bool(different), "socketConnects": .int(calls)])
        await f.close(); return answer
    }
    static func uncertainCommandSurvivesRecoveryFailure() async throws -> RelayJSON {
        let f = try await fixture()
        let body: [String: JSONValue] = ["text": .string("One in-memory command"), "inputId": .string("recovery-retained-input")]
        await f.socket.dropAcknowledgement()
        let send = Task {
            do { let _: RelayJSON = try await f.adapter.mutate("v1/sessions/session-test/messages", body: body); return "unexpected-success" }
            catch { return (error as? BridgeFailure)?.code ?? "unknown" }
        }
        try await waitUntil { await f.socket.commands["recovery-retained-input"] != nil }
        let original = await f.socket.commandEnvelopes["recovery-retained-input"]
        await f.socket.setRecoveryBehavior("reject"); try await f.socket.sendRecoveryGap()
        let firstError = await send.value
        await f.adapter.shutdown()
        try await waitUntil { await f.client.state == .disconnected }
        try await f.client.connect(pairing: RelayPairing(scannedURL: pairingURL), confirmedControllerReplacement: true)
        let bootstrap = try await f.client.bootstrap(), bridge = try await f.client.openWorkspace(key: "/workspace")
        let restored = try await RelayRemoteTransport(client: f.client, bootstrap: bootstrap, bridge: bridge, hostName: "Restored in-memory fixture", journalDirectory: f.directory)
        let recovered: RelayJSON = try await restored.mutate("v1/sessions/session-test/messages", body: body)
        let count = await f.socket.sentCommandCount, same = await f.socket.commandEnvelopes["recovery-retained-input"] == original
        let queries = await f.socket.calls.filter { $0 == "queryConversationCommandsV4" }.count
        let answer = result("uncertain_input_reconciles_original_id_after_explicit_reconnect", passed: firstError == "relay_resync_failed" && recovered["accepted"].bool == true && same && original != nil && count == 1 && queries == 1,
            ["firstError": .string(firstError), "recoveredAccepted": recovered["accepted"], "sameOriginalEnvelope": .bool(same), "mockSendCommandCount": .int(count), "queryCalls": .int(queries), "actualModelRequests": .int(0)])
        await restored.shutdown(); await f.close(); return answer
    }
    static func main() async throws {
        var checks: [RelayJSON] = []
        for behavior in ["timeout", "ackOnly", "reject"] { checks.append(try await failedRecovery(behavior)) }
        checks.append(try await snapshotBeforeMissingAck())
        checks.append(try await replacementError())
        checks.append(try await obsoleteRecovery(false))
        checks.append(try await obsoleteRecovery(true))
        checks.append(try await newerRecoveryAttempt())
        checks.append(try await uncertainCommandSurvivesRecoveryFailure())
        checks.append(try await trafficWithoutHeartbeatAck())
        checks.append(try await transportLoss(heartbeat: false))
        checks.append(try await transportLoss(heartbeat: true))
        let passed = checks.allSatisfy { $0["passed"].bool == true }
        let output: RelayJSON = .object(["passed": .bool(passed), "checkedAt": .string(ISO8601DateFormatter().string(from: Date())), "checks": .array(checks), "realAccountConnected": .bool(false), "realNetwork": .bool(false), "modelCommands": .int(0)])
        let bytes = try output.data()
        if let path = CommandLine.arguments.dropFirst().first { try bytes.write(to: URL(fileURLWithPath: path), options: .atomic) }
        print(String(data: bytes, encoding: .utf8)!)
        if !passed { exit(1) }
    }
}
#endif
