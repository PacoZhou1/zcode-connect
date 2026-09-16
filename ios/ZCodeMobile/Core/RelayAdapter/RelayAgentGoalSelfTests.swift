#if RELAY_AGENT_GOAL_SELF_TESTS
import Foundation

private struct AGResult: Sendable {
    let value: RelayJSON
    let code: String?
    var json: RelayJSON { .object(["code": code.map(RelayJSON.string) ?? .null, "value": value]) }
}
private struct AGFixture {
    let socket: MockRelaySocket
    let client: RelayClient
    let adapter: RelayRemoteTransport
    let bootstrap: RelayBootstrap
    let bridge: RelayBridge
    let directory: URL
    func close() async { await adapter.shutdown(); await client.disconnect(); try? FileManager.default.removeItem(at: directory) }
}
private struct AGFailure: Error { let text: String }

@main private struct RelayAgentGoalSelfTests {
    static let parent = "session-test", child = "child-ended"
    static func fixture(mode: String = "build", active: Bool = false) async throws -> AGFixture {
        let socket = MockRelaySocket(), client = try RelayClient(clientID: "agent-goal-fixture", transport: socket, requestTimeout: 2)
        await socket.useGoalFixture(mode: mode, active: active)
        let pairing = try RelayPairing(scannedURL: "https://zcode.z.ai/remote/v4?sid=mock-desktop&hash=mock-pairing-value-0123456789-abcdef")
        try await client.connect(pairing: pairing, confirmedControllerReplacement: true)
        let bootstrap = try await client.bootstrap(), bridge = try await client.openWorkspace(key: "/workspace")
        let directory = FileManager.default.temporaryDirectory.appending(path: "relay-agent-goal-" + UUID().uuidString)
        let adapter = try await RelayRemoteTransport(client: client, bootstrap: bootstrap, bridge: bridge, hostName: "Synthetic agent-goal fixture", journalDirectory: directory)
        let _: RelayJSON = try await adapter.get("v1/sessions")
        return .init(socket: socket, client: client, adapter: adapter, bootstrap: bootstrap, bridge: bridge, directory: directory)
    }
    static func capture(_ operation: () async throws -> RelayJSON) async -> AGResult {
        do { return .init(value: try await operation(), code: nil) }
        catch { return .init(value: .null, code: (error as? BridgeFailure)?.code ?? (error as? RelayFailure)?.code ?? String(describing: error)) }
    }
    static func get(_ f: AGFixture, _ path: String) async -> AGResult { await capture { try await f.adapter.get(path) } }
    static func goal(_ f: AGFixture, text: String = "Inspect the dedicated fixture", id: String = "goal-one") async -> AGResult {
        await capture { try await f.adapter.mutate("v1/sessions/" + parent + "/goal/start", body: ["text": .string(text), "clientGoalId": .string(id)]) }
    }
    static func check(_ name: String, _ passed: Bool, _ facts: [String: RelayJSON]) -> RelayJSON {
        .object(facts.merging(["name": .string(name), "passed": .bool(passed)]) { _, new in new })
    }
    static func wait(_ condition: () async -> Bool) async throws {
        for _ in 0..<150 { if await condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        throw AGFailure(text: "Synthetic event deadline exceeded")
    }
    static func childSnapshot(count: Int = 705, mismatch: String? = nil) -> RelayJSON {
        var workspace: [String: RelayJSON] = ["workspacePath": .string("/workspace"), "workspaceKey": .string("/workspace")]
        if mismatch == "workspace" { workspace["workspacePath"] = .string("/other") }
        let session: RelayJSON = .object(["sessionId": .string(child), "sessionKind": .string(mismatch == "kind" ? "interactive" : "subagent_child"), "parentSessionId": .string(mismatch == "parent" ? "another-parent" : parent), "workspace": .object(workspace), "status": .string("completed"), "title": .string("Original persisted child")])
        return .object(["session": session, "settings": .object(["model": .object(["current": .object(["providerId": .string("child-provider"), "modelId": .string("child-model")])]), "thoughtLevel": .object(["current": .string("max")]), "mode": .object(["current": .string("plan")])]), "runtime": .object(["eventSeq": .int(5)]), "messages": .array((0..<count).map { .object(["info": .object(["messageId": .string("original-child-message-\($0)"), "role": .string($0 % 2 == 0 ? "user" : "assistant")]), "parts": .array([.object(["type": .string("text"), "text": .string("Original child history \($0)")])])]) })])
    }
    static func names() async throws -> RelayJSON {
        let f = try await fixture()
        let _: RelayJSON = try await f.adapter.get("v1/sessions/" + parent)
        var projection = try await f.client.currentProjection(sessionID: parent)!.raw.requiringObject()
        let ids = (0..<13).map { "named-child-\($0)" }
        projection["subagents"] = .object(["revision": .int(4), "childSessionIds": .array(ids.map(RelayJSON.string)), "running": .array([]), "endedTotal": .int(13)])
        let items = ids.enumerated().map { index, id in RelayJSON.object(["childSessionId": .string(id), "title": .string("Original specialized task \(index)"), "status": .string(index == 0 ? "failed" : "success"), "subagentType": .string("Explore"), "summary": .string("Original summary \(index)"), "endedAt": .int(1000 + index)]) }
        await f.socket.useProjection(.object(projection))
        await f.socket.useSubagentDirectory(.object(["revision": .int(4), "childSessionIds": .array(ids.map(RelayJSON.string)), "running": .array([]), "ended": .object(["total": .int(13), "items": .array(items)])]))
        // Re-open only the synthetic subscription so its new directory revision is authoritative.
        try await f.client.unsubscribe(sessionID: parent)
        let result = await get(f, "v1/sessions/" + parent)
        let actual = result.value["hostActivity"]["subagents"]["ended"]["items"].array ?? []
        let passed = result.code == nil && actual == items && result.value["hostActivity"]["rows"]["window"].array?.isEmpty == true
        let evidence = check("thirteen_ended_names_summaries_and_statuses_without_transcript_agent_rows", passed, ["directoryItems": .array(actual), "routeError": result.code.map(RelayJSON.string) ?? .null, "commandCount": .int(await f.socket.sentCommandCount)])
        await f.close(); return evidence
    }
    static func directoryFailure() async throws -> RelayJSON {
        let f = try await fixture(); await f.socket.failSubagentDirectory()
        let result = await get(f, "v1/sessions/" + parent)
        let evidence = check("directory_failure_keeps_parent_text_and_reports_auxiliary_error", result.code == nil && result.value["messages"].array?.first?["text"].string == "Hello" && result.value["hostActivity"]["subagents"]["directoryError"].string == "desktop_rpc_error", ["result": result.json])
        await f.close(); return evidence
    }
    static func directoryPagination() async throws -> RelayJSON {
        let f = try await fixture()
        let ids = (0..<205).map { "page-child-\($0)" }
        let items = ids.enumerated().map { index, id in RelayJSON.object(["childSessionId": .string(id), "title": .string("Directory title \(index)"), "status": .string("success"), "endedAt": .int(10_000 - index)]) }
        var projection = try await f.socket.alternateProjection!.requiringObject()
        projection["subagents"] = .object(["revision": .int(3), "childSessionIds": .array(ids.map(RelayJSON.string)), "running": .array([]), "endedTotal": .int(205)])
        await f.socket.useProjection(.object(projection))
        func page(_ range: Range<Int>, next: String?) -> RelayJSON {
            .object(["revision": .int(3), "childSessionIds": .array(ids.map(RelayJSON.string)), "running": .array([]), "ended": .object(["total": .int(205), "items": .array(Array(items[range])), "nextCursor": next.map(RelayJSON.string) ?? .null])])
        }
        await f.socket.useSubagentDirectory(page(0..<100, next: "page-two"))
        let first = await get(f, "v1/sessions/" + parent), initial = await get(f, "v1/sessions/" + parent + "/agents")
        await f.socket.useSubagentDirectory(page(100..<200, next: "page-three"))
        let second = await get(f, "v1/sessions/" + parent + "/agents?endedCursor=page-two")
        await f.socket.useSubagentDirectory(page(200..<205, next: nil))
        let final = await get(f, "v1/sessions/" + parent + "/agents?endedCursor=page-three")
        let detail = await get(f, "v1/sessions/" + parent), repeatCursor = await get(f, "v1/sessions/" + parent + "/agents?endedCursor=page-two")
        let count = await f.socket.calls.filter { $0 == "listSessionSubagents" }.count
        let passed = first.value["hostActivity"]["subagents"]["ended"]["items"].array?.count == 100 && initial.value["directory"]["ended"]["items"].array?.count == 100 && second.value["directory"]["ended"]["items"].array?.count == 200 && final.value["directory"]["ended"]["items"] == .array(items) && detail.value["hostActivity"]["subagents"]["ended"]["items"] == .array(items) && repeatCursor.code == "subagent_directory_changed" && count == 3
        let evidence = check("directory_100_200_205_pages_accumulate_and_detail_preserves_loaded_names", passed, ["firstCount": .int(first.value["hostActivity"]["subagents"]["ended"]["items"].array?.count ?? 0), "secondCount": .int(second.value["directory"]["ended"]["items"].array?.count ?? 0), "finalCount": .int(final.value["directory"]["ended"]["items"].array?.count ?? 0), "detailCount": .int(detail.value["hostActivity"]["subagents"]["ended"]["items"].array?.count ?? 0), "repeatedCursor": repeatCursor.json, "directoryRPCCalls": .int(count)])
        await f.close(); return evidence
    }
    static func coldChild() async throws -> RelayJSON {
        let f = try await fixture(); _ = await get(f, "v1/sessions/" + parent)
        await f.socket.useSubagentSnapshot(childSnapshot(), sessionID: child); await f.socket.makeSessionCold(child)
        async let first = get(f, "v1/sessions/" + child)
        async let simultaneous = get(f, "v1/sessions/" + child)
        let (result, second) = await (first, simultaneous)
        var page = result.value
        if result.code == nil {
            for _ in 0..<2 {
                let cursor = page["history"]["beforeRowId"].integer!, epoch = page["history"]["logEpoch"].string!
                page = try await f.adapter.get("v1/sessions/\(child)/messages?beforeRowId=\(cursor)&logEpoch=\(epoch)&limit=200")
            }
        }
        let calls = await f.socket.serviceCalls, childCalls = calls.filter { $0["params"]["sessionId"].string == child }
        let subscriptions = childCalls.filter { $0["method"].string == "subscribeConversationV4" }
        let forbidden = calls.filter { ["resumeSession", "setModel", "setThoughtLevel", "setMode", "sendConversationCommandV4"].contains($0["method"].string ?? "") }
        var denied: [String: RelayJSON] = [:]
        for path in ["/messages", "/stop", "/goal/start", "/hooks/review/request"] {
            let attempt = await capture { try await f.adapter.mutate("v1/sessions/" + child + path, body: [:]) }; denied[path] = attempt.code.map(RelayJSON.string) ?? .null
        }
        let childSettings = await get(f, "v1/sessions/" + child + "/settings"), childChanges = await get(f, "v1/sessions/" + child + "/changes")
        let directSubscribe = await capture { _ = try await f.client.subscribe(sessionID: child); return .null }
        let text = page["messages"].array ?? [], list = await get(f, "v1/sessions")
        let safeSubscribe = subscriptions.count == 1 && Set(subscriptions[0]["params"].object!.keys) == ["sessionId", "workspacePath", "visibility"]
        let readOnly = result.value["session"]["source"].string == "official-relay-subagent" && result.value["session"]["capabilities"]["send"].bool == false
        let guards = denied.values.allSatisfy { $0.string == "session_read_only" } && childSettings.code == "session_read_only" && childChanges.code == "session_read_only" && directSubscribe.code == "session_read_only"
        let passed = result.code == nil && second.code == nil && result.value["history"]["loadedRowCount"].integer == 500 && page["history"]["loadedRowCount"].integer == 705 && page["history"]["hasMore"].bool == false && text.count == 705 && text.first?["text"].string == "Original child history 0" && text.last?["text"].string == "Original child history 704" && safeSubscribe && forbidden.isEmpty && readOnly && guards && list.value["sessions"].array?.contains(where: { $0["id"].string == child }) == false
        let evidence = check("parent_verified_cold_child_shares_one_restore_and_pages_all_705_original_messages", passed, ["firstError": result.code.map(RelayJSON.string) ?? .null, "secondError": second.code.map(RelayJSON.string) ?? .null, "childCalls": .array(childCalls), "unsubscribeCount": .int(calls.filter { $0["method"].string == "unsubscribeConversationV4" }.count), "history": page["history"], "firstText": text.first?["text"] ?? .null, "lastText": text.last?["text"] ?? .null, "forbiddenCalls": .array(forbidden), "mutationGuards": .object(denied), "session": result.value["session"]])
        await f.close(); return evidence
    }
    static func taskMembership() async throws -> RelayJSON {
        let f = try await fixture()
        let normal = try await f.client.listTasks()
        let pinned = try await f.client.listTasks(pinned: true)
        let archived = try await f.client.listTasks(archived: true)
        let result = check("task_list_membership_survives_missing_dto_flags", !normal.isEmpty && !pinned.isEmpty && normal.allSatisfy { $0.pinned == false && $0.archived == false } && pinned.allSatisfy { $0.pinned == true && $0.archived == false } && archived.allSatisfy { $0.pinned == false && $0.archived == true }, [:])
        await f.close(); return result
    }
    static func persistedV4Child() async throws -> RelayJSON {
        let f = try await fixture(); _ = await get(f, "v1/sessions/" + parent)
        await f.socket.useHistoricalRows()
        await f.socket.setSubagentUnavailable(child, value: true)
        let first = await get(f, "v1/sessions/" + child)
        let page = await get(f, "v1/sessions/\(child)/messages?beforeRowId=3&logEpoch=epoch-one&limit=200")
        let denied = await capture { try await f.adapter.mutate("v1/sessions/\(child)/messages", body: ["text": .string("must not send")]) }
        let calls = await f.socket.serviceCalls
        let passed = first.code == nil && page.code == nil
            && first.value["session"]["capabilities"]["send"].bool == false
            && first.value["session"]["source"].string == "official-relay-subagent"
            && first.value["history"]["hasMore"].bool == true
            && page.value["history"]["loadedRowCount"].integer == 3
            && page.value["messages"].array?.contains(where: { $0["text"].string == "Head tail" }) == true
            && denied.code == "session_read_only"
            && !calls.contains(where: { ["resumeSession", "setModel", "sendConversationCommandV4"].contains($0["method"].string ?? "") })
        let result = check("persisted_v4_child_without_legacy_runtime_reads_and_pages_original_rows", passed, ["first": first.json, "page": page.json, "write": denied.json])
        await f.close(); return result
    }
    static func coldScope(_ mismatch: String) async throws -> RelayJSON {
        let f = try await fixture(); _ = await get(f, "v1/sessions/" + parent)
        await f.socket.useSubagentSnapshot(childSnapshot(count: 1, mismatch: mismatch), sessionID: child); await f.socket.makeSessionCold(child)
        let result = await get(f, "v1/sessions/" + child)
        let commands = await f.socket.sentCommandCount
        let evidence = check("cold_restored_original_" + mismatch + "_mismatch_rejected", result.code == "relay_subagent_scope_mismatch" && result.value == .null && commands == 0, ["result": result.json])
        await f.close(); return evidence
    }
    static func coldParentRevalidation() async throws -> RelayJSON {
        let f = try await fixture(); _ = await get(f, "v1/sessions/" + parent)
        await f.socket.makeSessionCold(child)
        await f.socket.useSubagentDirectory(.object(["revision": .int(9), "childSessionIds": .array([]), "running": .array([]), "ended": .object(["total": .int(0), "items": .array([])])]))
        let result = await get(f, "v1/sessions/" + child)
        let calls = await f.socket.serviceCalls.filter { $0["params"]["sessionId"].string == child }
        let evidence = check("stale_parent_reference_cannot_restore_or_read_arbitrary_child", result.code == "relay_subagent_scope_mismatch" && calls.count == 1 && calls.first?["method"].string == "readSession", ["result": result.json, "childCalls": .array(calls)])
        await f.close(); return evidence
    }
    static func offline() async throws -> RelayJSON {
        let f = try await fixture(); _ = await get(f, "v1/sessions/" + parent)
        await f.socket.failReceive(); try await wait { await f.client.state == .disconnected }
        let result = await get(f, "v1/sessions/" + child)
        let evidence = check("disconnected_child_view_reports_connection_failure_not_workspace_mismatch", result.code != nil && result.code != "relay_workspace_changed", ["result": result.json])
        await f.close(); return evidence
    }
    static func goalPrecondition(_ mode: String, active: Bool, text: String, expected: String) async throws -> RelayJSON {
        let f = try await fixture(mode: mode, active: active), result = await goal(f, text: text)
        let count = await f.socket.sentCommandCount
        let files = (try? FileManager.default.contentsOfDirectory(at: f.directory, includingPropertiesForKeys: nil)) ?? []
        let setters = await f.socket.setterCalls
        let evidence = check("goal_precondition_" + expected, result.code == expected && count == 0 && files.isEmpty && setters == 0, ["result": result.json, "commandCount": .int(count), "journalFileCount": .int(files.count)])
        await f.close(); return evidence
    }
    static func goalSuccess() async throws -> RelayJSON {
        let f = try await fixture(), first = await goal(f, text: "  Inspect the dedicated fixture  ")
        let duplicate = await goal(f), changed = await goal(f, text: "Changed objective")
        let envelopes = await f.socket.commandEnvelopes
        let command = envelopes["goal-start-goal-one"] ?? .null
        let setters = await f.socket.setterCalls
        let passed = first.value["accepted"].bool == true && duplicate.value["accepted"].bool == true && changed.code == "input_conflict" && envelopes.count == 1 && command["type"].string == "sendGoalCommand" && command["payload"] == .object(["text": .string("Inspect the dedicated fixture"), "displayText": .string("/goal Inspect the dedicated fixture")]) && setters == 0
        let evidence = check("goal_start_exact_official_envelope_trimmed_intent_and_durable_duplicate", passed, ["first": first.json, "duplicate": duplicate.json, "changed": changed.json, "envelope": command])
        await f.close(); return evidence
    }
    static func lostGoalAck() async throws -> RelayJSON {
        let f = try await fixture(); await f.socket.dropAcknowledgement()
        let firstTask = Task { await goal(f) }
        try? await wait { await f.socket.sentCommandCount == 1 }; firstTask.cancel()
        let uncertain = await firstTask.value
        guard await f.socket.sentCommandCount == 1 else { let evidence = check("lost_goal_ack_reconciles_original_id_after_restart_despite_now_active_goal", false, ["initial": uncertain.json]); await f.close(); return evidence }
        try await f.socket.publishGoalActive(); try await wait { await f.client.currentProjection(sessionID: parent)?.hostGoal?.isActive == true }
        // Reconstruct the facade from the durable journal while keeping the same synthetic host.
        await f.adapter.shutdown()
        let restored = try await RelayRemoteTransport(client: f.client, bootstrap: f.bootstrap, bridge: f.bridge, hostName: "Restored synthetic goal", journalDirectory: f.directory)
        let second = await capture { try await restored.mutate("v1/sessions/" + parent + "/goal/start", body: ["text": .string("Inspect the dedicated fixture"), "clientGoalId": .string("goal-one")]) }
        let count = await f.socket.sentCommandCount, calls = await f.socket.serviceCalls
        let query = calls.filter { $0["method"].string == "queryConversationCommandsV4" }
        let evidence = check("lost_goal_ack_reconciles_original_id_after_restart_despite_now_active_goal", uncertain.code != nil && second.value["accepted"].bool == true && count == 1 && query.count == 1 && query.first?["params"]["commands"].array?.first?["commandId"].string == "goal-start-goal-one", ["uncertain": uncertain.json, "recovered": second.json, "commandCount": .int(count), "query": .array(query)])
        await restored.shutdown(); await f.close(); return evidence
    }
    static func goalAck(_ status: String) async throws -> RelayJSON {
        let f = try await fixture(); await f.socket.setNextCommandStatus(status)
        let first = await goal(f), second = await goal(f)
        let expected = ["rejected", "stale"].contains(status) ? "goal_start_rejected" : "goal_start_uncertain"
        let count = await f.socket.sentCommandCount
        let evidence = check("goal_ack_" + status + "_keeps_identity_and_explicit_outcome", first.code == expected && second.code == expected && count == 1, ["first": first.json, "repeat": second.json, "commandCount": .int(count)])
        await f.close(); return evidence
    }
    static func main() async throws {
        let results = try await [names(), directoryFailure(), directoryPagination(), coldChild(), taskMembership(), persistedV4Child(), coldScope("parent"), coldScope("kind"), coldScope("workspace"), coldParentRevalidation(), offline(), goalPrecondition("plan", active: false, text: "Objective", expected: "goal_plan_mode"), goalPrecondition("build", active: true, text: "Objective", expected: "goal_start_unavailable"), goalPrecondition("build", active: false, text: "  ", expected: "goal_start_invalid"), goalSuccess(), lostGoalAck(), goalAck("rejected"), goalAck("stale"), goalAck("failed")]
        let passed = results.filter { $0["passed"].bool == true }.count
        let output: RelayJSON = .object(["verifiedAt": .string(ISO8601DateFormatter().string(from: Date())), "passed": .bool(passed == results.count), "passedCount": .int(passed), "totalCount": .int(results.count), "checks": .array(results), "boundary": .string("Production Swift client/facade over synthetic IPC only. No actual pairing, host runtime restore, hook, model input, or user task accessed. Cold restoration side effects are verified from installed source, not performed by this suite.")])
        try output.data().write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
        print(String(data: try output.data(), encoding: .utf8)!)
        if passed != results.count { exit(1) }
    }
}
#endif
