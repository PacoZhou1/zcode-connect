#if RELAY_COLD_OPEN_SELF_TESTS
import Foundation

private struct ColdRead: Sendable {
    var value: RelayJSON = .null
    var error: String?
    var json: RelayJSON { .object(["error": error.map(RelayJSON.string) ?? .null, "value": value]) }
}
private struct ColdFixture {
    let socket: MockRelaySocket
    let client: RelayClient
    let adapter: RelayRemoteTransport
    let directory: URL
    func close() async {
        await adapter.shutdown(); await client.disconnect()
        try? FileManager.default.removeItem(at: directory)
    }
}

@main private struct RelayColdOpenSelfTests {
    static let session = "session-test"
    static func fixture(cold: Bool = true) async throws -> ColdFixture {
        let socket = MockRelaySocket(), client = try RelayClient(clientID: "cold-open-fixture", transport: socket, requestTimeout: 2)
        if cold { await socket.makeSessionCold(session) }
        let pairing = try RelayPairing(scannedURL: "https://zcode.z.ai/remote/v4?sid=mock-desktop&hash=mock-pairing-value-0123456789-abcdef")
        try await client.connect(pairing: pairing, confirmedControllerReplacement: true)
        let bootstrap = try await client.bootstrap(), bridge = try await client.openWorkspace(key: "/workspace")
        let directory = FileManager.default.temporaryDirectory.appending(path: "relay-cold-open-" + UUID().uuidString)
        let adapter = try await RelayRemoteTransport(client: client, bootstrap: bootstrap, bridge: bridge, hostName: "Synthetic cold-open fixture", journalDirectory: directory)
        let _: RelayJSON = try await adapter.get("v1/sessions")
        return .init(socket: socket, client: client, adapter: adapter, directory: directory)
    }
    static func read(_ fixture: ColdFixture, suffix: String = "") async -> ColdRead {
        do { let value: RelayJSON = try await fixture.adapter.get("v1/sessions/" + session + suffix); return .init(value: value) }
        catch { return .init(error: (error as? BridgeFailure)?.code ?? (error as? RelayFailure)?.code ?? String(describing: error)) }
    }
    static func result(_ name: String, passed: Bool, facts: [String: RelayJSON]) -> RelayJSON {
        .object(facts.merging(["name": .string(name), "passed": .bool(passed)]) { _, new in new })
    }
    static func facts(_ fixture: ColdFixture) async -> [String: RelayJSON] {
        let calls = await fixture.socket.calls
        return ["subscribeCalls": .int(calls.filter { $0 == "subscribeConversationV4" }.count),
                "readAttempts": .array(await fixture.socket.sessionReadReadiness), "order": .array(await fixture.socket.coldOpenOrder.map(RelayJSON.string)),
                "commandCalls": .int(await fixture.socket.sentCommandCount), "setterCalls": .int(await fixture.socket.setterCalls),
                "projectionText": await fixture.client.currentProjection(sessionID: session)?.rows.first?["text"] ?? .null]
    }
    static func rawColdReadContract() async throws -> RelayJSON {
        let f = try await fixture()
        var coldError: String?
        do { _ = try await f.client.readSession(session) } catch { coldError = (error as? RelayFailure)?.code }
        _ = try await f.client.subscribe(sessionID: session)
        let warm = try await f.client.readSession(session)
        var evidence = await facts(f); evidence["coldReadError"] = coldError.map(RelayJSON.string) ?? .null
        let answer = result("read_requires_runtime_then_subscription_makes_it_ready", passed: coldError == "desktop_rpc_error" && warm.sessionID == session && evidence["subscribeCalls"]?.integer == 1, facts: evidence)
        await f.close(); return answer
    }
    static func single(_ settings: Bool) async throws -> RelayJSON {
        let f = try await fixture(), value = await read(f, suffix: settings ? "/settings" : "")
        var evidence = await facts(f); evidence["routeResult"] = value.json
        let complete = settings ? value.value["model"]["thoughtLevel"].string == "max" : value.value["messages"].array?.first?["text"].string == "Hello"
        let ready = evidence["readAttempts"]?.array?.allSatisfy { $0["runtimeReady"].bool == true } == true
        let answer = result(settings ? "cold_settings_alone_waits_for_subscription" : "cold_detail_waits_for_subscription", passed: value.error == nil && complete && ready && evidence["subscribeCalls"]?.integer == 1, facts: evidence)
        await f.close(); return answer
    }
    static func concurrent() async throws -> RelayJSON {
        let f = try await fixture()
        async let detail = read(f)
        async let settings = read(f, suffix: "/settings")
        let (d, s) = await (detail, settings)
        var evidence = await facts(f); evidence["detail"] = d.json; evidence["settings"] = s.json
        let attempts = evidence["readAttempts"]?.array ?? []
        let passed = d.error == nil && s.error == nil && d.value["messages"].array?.first?["text"].string == "Hello" && s.value["model"]["thoughtLevel"].string == "max" && attempts.count == 2 && attempts.allSatisfy { $0["runtimeReady"].bool == true } && evidence["subscribeCalls"]?.integer == 1 && evidence["commandCalls"]?.integer == 0 && evidence["setterCalls"]?.integer == 0
        let answer = result("concurrent_detail_and_settings_share_one_cold_subscription", passed: passed, facts: evidence)
        await f.close(); return answer
    }
    static func warmReads() async throws -> RelayJSON {
        let f = try await fixture(cold: false), first = await read(f)
        async let detail = read(f)
        async let settings = read(f, suffix: "/settings")
        let (d, s) = await (detail, settings)
        var evidence = await facts(f); evidence["errors"] = .array([first, d, s].map { $0.error.map(RelayJSON.string) ?? .null })
        let answer = result("warm_repeated_reads_keep_one_subscription", passed: [first, d, s].allSatisfy { $0.error == nil } && evidence["subscribeCalls"]?.integer == 1 && evidence["readAttempts"]?.array?.count == 3 && evidence["setterCalls"]?.integer == 0, facts: evidence)
        await f.close(); return answer
    }
    static func realReadFailureStillPropagates() async throws -> RelayJSON {
        let f = try await fixture(cold: false); await f.socket.failSessionRead(session)
        async let detail = read(f)
        async let settings = read(f, suffix: "/settings")
        let (d, s) = await (detail, settings)
        var evidence = await facts(f); evidence["errors"] = .array([d, s].map { $0.error.map(RelayJSON.string) ?? .null })
        let answer = result("ready_runtime_read_rejection_remains_visible_on_both_routes", passed: d.error == "desktop_rpc_error" && s.error == "desktop_rpc_error" && evidence["readAttempts"]?.array?.allSatisfy { $0["runtimeReady"].bool == true } == true && evidence["projectionText"]?.string == "Hello", facts: evidence)
        await f.close(); return answer
    }
    static func subagentReadRemainsExistingOnly() async throws -> RelayJSON {
        let f = try await fixture(cold: false), parent = await read(f), childID = "child-ended"
        let child: RelayJSON = .object(["session": .object(["sessionId": .string(childID), "sessionKind": .string("subagent_child"), "parentSessionId": .string(session), "workspace": .object(["workspacePath": .string("/workspace"), "workspaceKey": .string("/workspace")]), "status": .string("completed"), "title": .string("Child fixture")]), "settings": .object([:]), "runtime": .object([:]), "messages": .array([.object(["info": .object(["messageId": .string("child-message"), "role": .string("assistant")]), "parts": .array([.object(["type": .string("text"), "text": .string("Existing child history")])])])])])
        await f.socket.useSubagentSnapshot(child, sessionID: childID)
        let value: RelayJSON = try await f.adapter.get("v1/sessions/" + childID)
        await f.socket.setSubagentUnavailable(childID, value: true)
        var coldError: String?
        do { _ = try await f.client.readSubagentSession(childID, parentSessionID: session) } catch { coldError = (error as? RelayFailure)?.code }
        let childCalls = await f.socket.serviceCalls.filter { $0["params"]["sessionId"].string == childID }
        var evidence = await facts(f); evidence["childCalls"] = .array(childCalls); evidence["coldChildError"] = coldError.map(RelayJSON.string) ?? .null
        let onlyRead = childCalls.count == 2 && childCalls.allSatisfy { $0["method"].string == "readSession" && $0["channel"].string == "zcode-agent" && $0["params"]["runtimePolicy"].string == "existing-only" && $0["params"]["messageLimit"] == .null }
        let answer = result("warm_child_read_and_default_core_read_remain_existing_only", passed: parent.error == nil && value["messages"].array?.first?["text"].string == "Existing child history" && value["session"]["capabilities"]["send"].bool == false && coldError == "relay_subagent_history_unavailable" && onlyRead && evidence["subscribeCalls"]?.integer == 1 && evidence["commandCalls"]?.integer == 0, facts: evidence)
        await f.close(); return answer
    }
    static func main() async throws {
        let results = try await [rawColdReadContract(), single(false), single(true), concurrent(), warmReads(), realReadFailureStillPropagates(), subagentReadRemainsExistingOnly()]
        let passed = results.filter { $0["passed"].bool == true }.count
        let output: RelayJSON = .object(["verifiedAt": .string(ISO8601DateFormatter().string(from: Date())), "passed": .bool(passed == results.count), "passedCount": .int(passed), "totalCount": .int(results.count), "checks": .array(results), "boundary": .string("Production Swift client/facade over an in-memory IPC socket. No network, live controller, CLI process, model, or original task accessed.")])
        if let path = CommandLine.arguments.dropFirst().first { try output.data().write(to: URL(fileURLWithPath: path), options: .atomic) }
        print(String(data: try output.data(), encoding: .utf8)!)
        if passed != results.count { exit(1) }
    }
}
#endif
