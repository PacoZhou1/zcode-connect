#if RELAY_ADAPTER_SELF_TESTS
import Foundation

private struct SubagentTestFailure: Error { let message: String }
private func childExpect(_ condition: Bool, _ message: String) throws { if !condition { throw SubagentTestFailure(message: message) } }
@MainActor private func childReject(_ code: String, _ operation: () async throws -> Void) async throws {
    do { try await operation(); throw SubagentTestFailure(message: "Expected " + code) }
    catch let error as BridgeFailure { try childExpect(error.code == code, "Expected \(code), got \(error.code)") }
    catch let error as RelayFailure { try childExpect(error.code == code, "Expected \(code), got \(error.code)") }
}
private func childSnapshot(id: String = "child-ended", count: Int = 705) -> RelayJSON {
    let messages: [RelayJSON] = (0..<count).map { index in
        var info: [String: RelayJSON] = ["messageId": .string("\(id)-message-\(index)"), "role": .string(index % 2 == 0 ? "user" : "assistant"), "time": .object(["created": .int(1_700_000_000_000 + index), "completed": .int(1_700_000_000_001 + index)])]
        if index == 650 { info["semantics"] = .object(["transcriptVisibility": .string("hidden")]) }
        return .object(["info": .object(info), "parts": .array([
            .object(["type": .string("text"), "text": .string("Host child record \(index)")]),
            .object(["type": .string("text"), "text": .string("MODEL_ONLY_NEVER_DISPLAYED"), "visibility": .string("model-only")])])])
    }
    return .object(["session": .object(["sessionId": .string(id), "sessionKind": .string("subagent_child"), "parentSessionId": .string("session-test"), "workspace": .object(["workspacePath": .string("/workspace"), "workspaceKey": .string("/workspace")]), "title": .string("Original child title"), "status": .string("completed"), "updatedAt": .int(1_700_000_000_900)]),
                    "settings": .object(["model": .object(["current": .object(["providerId": .string("child-provider"), "modelId": .string("child-model")])]), "thoughtLevel": .object(["current": .string("child-host-thought")]), "mode": .object(["current": .string("build")])]),
                    "runtime": .object(["eventSeq": .int(9), "stateRevision": .int(2)]), "messages": .array(messages)])
}

@MainActor func runSubagentFacadeTests(directory: URL) async throws -> [String] {
    let mock = MockRelaySocket(), client = try RelayClient(clientID: "subagent-readonly-fixture", transport: mock, requestTimeout: 15)
    await mock.useSubagentSnapshot(childSnapshot(), sessionID: "child-ended")
    let pairing = try RelayPairing(scannedURL: "https://zcode.z.ai/remote/v4?sid=mock-desktop&hash=mock-pairing-value-0123456789-abcdef")
    try await client.connect(pairing: pairing, confirmedControllerReplacement: true)
    let bootstrap = try await client.bootstrap(), bridge = try await client.openWorkspace(key: "/workspace")
    let facade = try await RelayRemoteTransport(client: client, bootstrap: bootstrap, bridge: bridge, hostName: "Read-only child fixture", journalDirectory: directory)
    let _: BridgeDetail = try await facade.get("v1/sessions/session-test")
    let first: BridgeDetail = try await facade.get("v1/sessions/child-ended")
    try childExpect(first.session.source == "official-relay-subagent" && first.session.capabilities.read && !first.session.capabilities.send && !first.session.capabilities.stop && !first.session.capabilities.approve && !first.session.capabilities.changes, "A parent-authorized child gained ordinary task capability")
    try childExpect(first.session.model == "child-model" && first.session.providerId == "child-provider" && first.session.thoughtLevel == "child-host-thought", "Parent model was substituted for child settings")
    try childExpect(first.pendingInteractions.isEmpty && first.history?.hasMore == true && first.history?.loadedRowCount == 500 && first.history?.totalRowCount == 705, "Initial complete-read history window was lost or silently truncated")
    let firstJSON: RelayJSON = try await facade.get("v1/sessions/child-ended")
    try childExpect(firstJSON["session"]["parentSessionId"].string == "session-test" && firstJSON["hostActivity"]["goal"] == .null && firstJSON["hostActivity"]["reasonCode"].string == "subagentReadOnly", "Child provenance or read-only activity is missing")
    let countBeforePaging = await mock.serviceCalls.count
    let cursor = firstJSON["history"]["beforeRowId"].integer!, epoch = firstJSON["history"]["logEpoch"].string!
    let page: RelayJSON = try await facade.get("v1/sessions/child-ended/messages?beforeRowId=\(cursor)&logEpoch=\(epoch)&limit=200")
    let last: RelayJSON = try await facade.get("v1/sessions/child-ended/messages?beforeRowId=\(page["history"]["beforeRowId"].integer!)&logEpoch=\(epoch)&limit=200")
    let loaded = last["messages"].array!, ids = loaded.compactMap { $0["id"].string }
    try childExpect(last["history"]["loadedRowCount"].integer == 705 && last["history"]["hasMore"].bool == false && ids.count == 704 && Set(ids).count == 704, "Older child history lost or duplicated visible messages")
    try childExpect(ids.first == "child-ended-message-0" && ids.last == "child-ended-message-704" && !ids.contains("child-ended-message-650"), "Metadata-hidden row or oldest history boundary is wrong")
    try childExpect(!loaded.contains { ($0["text"].string ?? "").contains("MODEL_ONLY") || $0["isStreaming"].bool == true || $0["forkTarget"].object != nil }, "Read-only snapshot fabricated streaming, fork action, or hidden content")
    try childExpect(await mock.serviceCalls.count == countBeforePaging, "Local older history page started an unnecessary host read or subscription")
    try await childReject("relay_history_changed") { let _: RelayJSON = try await facade.get("v1/sessions/child-ended/messages?beforeRowId=\(cursor)&logEpoch=\(epoch)&limit=200") }

    for (suffix, method) in [("", "PATCH"), ("/settings", "PATCH"), ("/settings", "GET"), ("/changes", "GET"), ("/messages", "POST"), ("/stop", "POST"), ("/fork", "POST"), ("/attachments", "POST"), ("/goal/pause", "POST"), ("/goal/resume", "POST"), ("/hooks/review/request", "POST"), ("/hooks/review/respond", "POST"), ("/hooks/review/toggle", "POST"), ("/hooks/review/revoke", "POST")] {
        try await childReject("session_read_only") {
            if method == "GET" { let _: RelayJSON = try await facade.get("v1/sessions/child-ended" + suffix) }
            else { let _: RelayJSON = try await facade.mutate("v1/sessions/child-ended" + suffix, method: method, body: [:]) }
        }
    }
    try await childReject("session_read_only") { _ = try await client.subscribe(sessionID: "child-ended") }
    try await childReject("session_read_only") { _ = try await client.readSession("child-ended") }
    try await childReject("session_read_only") { _ = try await client.renameTask(sessionID: "child-ended", title: "Never submitted", explicitUserAction: true) }
    try await childReject("session_read_only") { _ = try await client.sendText(sessionID: "child-ended", text: "Never submitted", commandID: "forbidden-child-send", explicitUserAction: true) }
    await mock.listSubagentAsTask("child-ended")
    let list: RelayJSON = try await facade.get("v1/sessions?includeArchived=true")
    try childExpect(list["sessions"].array?.contains { $0["id"].string == "child-ended" } == false, "Child history was promoted to a registered task")
    let countBeforeGuess = await mock.serviceCalls.count
    try await childReject("session_not_found") { let _: RelayJSON = try await facade.get("v1/sessions/unreferenced-child") }
    let callsAfterGuess = await mock.serviceCalls
    try childExpect(!callsAfterGuess.dropFirst(countBeforeGuess).contains { $0["params"]["sessionId"].string == "unreferenced-child" }, "A guessed child ID reached a host session read")

    for patch in ["workspace", "identity", "remote", "parent", "kind"] {
        var invalid = childSnapshot(id: "child-one", count: 1).object!, session = invalid["session"]!.object!, workspace = session["workspace"]!.object!
        if patch == "workspace" { workspace["workspacePath"] = .string("/another-workspace") }
        if patch == "identity" { workspace["workspaceIdentity"] = .string("another-identity") }
        if patch == "remote" { workspace["remoteSessionId"] = .string("another-machine") }
        if patch == "parent" { session["parentSessionId"] = .string("another-parent") }
        if patch == "kind" { session["sessionKind"] = .string("interactive") }
        session["workspace"] = .object(workspace); invalid["session"] = .object(session)
        await mock.useSubagentSnapshot(.object(invalid), sessionID: "child-one")
        try await childReject("relay_subagent_scope_mismatch") { let _: RelayJSON = try await facade.get("v1/sessions/child-one") }
    }
    var overLimit = childSnapshot(id: "child-one", count: 0).object!
    overLimit["messages"] = .array((0..<10_001).map { .object(["info": .object(["messageId": .string("over-limit-\($0)")])]) })
    await mock.useSubagentSnapshot(.object(overLimit), sessionID: "child-one")
    try await childReject("relay_history_limit") { let _: RelayJSON = try await facade.get("v1/sessions/child-one") }
    await mock.setSubagentUnavailable("child-ended", value: true)
    try await childReject("relay_subagent_history_unavailable") { let _: RelayJSON = try await facade.get("v1/sessions/child-ended") }
    let serviceCalls = await mock.serviceCalls, setterCalls = await mock.setterCalls, commandCount = await mock.sentCommandCount
    let childCalls = serviceCalls.filter { ["child-ended", "child-one"].contains($0["params"]["sessionId"].string ?? $0["params"]["taskId"].string ?? "") }
    try childExpect(childCalls.allSatisfy { $0["channel"].string == "zcode-agent" && $0["method"].string == "readSession" && $0["params"]["runtimePolicy"].string == "existing-only" && $0["params"]["messageLimit"] == .null && $0["params"]["model"] == .null && $0["params"]["thoughtLevel"] == .null }, "Child read used subscribe, cold resume, registration, truncation or a configuration override")
    try childExpect(setterCalls == 0 && commandCount == 0, "Read-only child regression sent a host mutation")
    await facade.shutdown(); await client.disconnect()
    return ["parent_projection_grants_subagent_read_without_task_registration", "subagent_full_existing_runtime_snapshot_pages_705_rows_without_silent_truncation", "subagent_read_only_all_mutations_scope_type_and_cold_runtime_guards"]
}
#endif
