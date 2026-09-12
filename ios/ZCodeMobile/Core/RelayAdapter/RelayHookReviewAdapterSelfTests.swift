#if RELAY_ADAPTER_SELF_TESTS
import Foundation

private struct HookAdapterTestFailure: Error { let message: String }
private func hookAdapterExpect(_ value: Bool, _ message: String) throws { if !value { throw HookAdapterTestFailure(message: message) } }
@MainActor private func hookAdapterReject(_ code: String, _ operation: () async throws -> Void) async throws {
    do { try await operation(); throw HookAdapterTestFailure(message: "Expected " + code) }
    catch let error as BridgeFailure { try hookAdapterExpect(error.code == code, "Expected \(code), got \(error.code)") }
    catch let error as RelayFailure { try hookAdapterExpect(error.code == code, "Expected \(code), got \(error.code)") }
}
private func hookAdapterBody(_ request: RelayHookReviewRequest, _ operation: RelayHookReviewOperation, id: String) throws -> [String: JSONValue] {
    let confirmation = try request.confirmation(for: operation, userConfirmed: true)
    var value: [String: RelayJSON] = ["clientCommandId": .string(id), "request": request.wire, "confirmation": try RelayJSON(data: JSONEncoder().encode(confirmation))]
    switch operation {
    case .trustSelected(let ids), .revokeSelected(let ids): value["reviewItemIds"] = .array(ids.map(RelayJSON.string))
    case .setEnabled(let id, let enabled): value["reviewItemId"] = .string(id); value["enabled"] = .bool(enabled)
    }
    return try JSONDecoder().decode([String: JSONValue].self, from: RelayJSON.object(value).data())
}
@MainActor private func hookAwaitCommand(_ mock: MockRelaySocket, key: String) async throws {
    for _ in 0..<100 { if await mock.commandEnvelopes[key] != nil { return }; try await Task.sleep(for: .milliseconds(10)) }
    throw HookAdapterTestFailure(message: "Hook command never reached the mock")
}

@MainActor func runHookReviewFacadeTests(directory: URL) async throws -> [String] {
    let request = try hookReviewFixture(), trust = RelayHookReviewOperation.trustSelected(itemIDs: ["fixture-item"])
    let mock = MockRelaySocket(); try await mock.useHookReview(request)
    let client = try RelayClient(clientID: "hook-facade-stable", transport: mock, requestTimeout: 2)
    let pairing = try RelayPairing(scannedURL: "https://zcode.z.ai/remote/v4?sid=mock-desktop&hash=mock-pairing-value-0123456789-abcdef")
    try await client.connect(pairing: pairing, confirmedControllerReplacement: true)
    let bootstrap = try await client.bootstrap(), bridge = try await client.openWorkspace(key: "/workspace")
    let adapter = try await RelayRemoteTransport(client: client, bootstrap: bootstrap, bridge: bridge, hostName: "Hook mock", journalDirectory: directory)
    let detail: BridgeDetail = try await adapter.get("v1/sessions/session-test")
    try hookAdapterExpect(detail.pendingInteractions.first?.hookReview == request, "Facade lost the complete typed hook request")
    let requestBody: [String: JSONValue] = ["clientCommandId": .string("review-request"), "workspaceIdentity": .string(request.workspaceIdentity), "bundleDigest": .string(request.bundleDigest)]
    let opened: RelayJSON = try await adapter.mutate("v1/sessions/session-test/hooks/review/request", body: requestBody)
    try hookAdapterExpect(opened["accepted"].bool == true, "Request-only review route failed")
    let countAfterRequest = await mock.sentCommandCount
    let _: RelayJSON = try await adapter.mutate("v1/sessions/session-test/hooks/review/request", body: requestBody)
    try hookAdapterExpect(await mock.sentCommandCount == countAfterRequest, "Same request identity was submitted twice")
    var freshRequest = requestBody; freshRequest["clientCommandId"] = .string("review-reopened-explicitly")
    let reopened: RelayJSON = try await adapter.mutate("v1/sessions/session-test/hooks/review/request", body: freshRequest)
    let countAfterReopen = await mock.sentCommandCount
    try hookAdapterExpect(reopened["acknowledgement"]["commandId"].string == "hook-review-reopened-explicitly" && countAfterReopen == countAfterRequest + 1, "A completed review request prevented reopening the same bundle")
    var missingConsent = try hookAdapterBody(request, trust, id: "missing-consent"); missingConsent["confirmation"] = .object(["action": .string("allow_once")])
    try await hookAdapterReject("hook_review_invalid") { let _: RelayJSON = try await adapter.mutate("v1/sessions/session-test/hooks/review/respond", body: missingConsent) }
    await mock.dropAcknowledgement()
    let originalBody = try hookAdapterBody(request, trust, id: "original-trust")
    let pending = Task { let result: RelayJSON = try await adapter.mutate("v1/sessions/session-test/hooks/review/respond", body: originalBody); return result }
    try await hookAwaitCommand(mock, key: "hook-original-trust")
    pending.cancel(); _ = try? await pending.value
    let originalEnvelope = await mock.commandEnvelopes["hook-original-trust"]!
    await adapter.shutdown(); try await mock.useHookReview(nil)
    _ = try await client.subscribe(sessionID: "session-test", resume: false)
    let restored = try await RelayRemoteTransport(client: client, bootstrap: bootstrap, bridge: bridge, hostName: "Hook mock", journalDirectory: directory)
    let before = await mock.sentCommandCount
    let recovered: RelayJSON = try await restored.mutate("v1/sessions/session-test/hooks/review/respond", body: hookAdapterBody(request, trust, id: "new-ui-id-after-restart"))
    try hookAdapterExpect(recovered["accepted"].bool == true && recovered["acknowledgement"]["commandId"].string == "hook-original-trust", "Relaunch did not reconcile the old command identity")
    try hookAdapterExpect(await mock.sentCommandCount == before, "Known accepted hook was submitted again")
    try await client.unsubscribe(sessionID: "session-test"); try await mock.useHookReview(request); _ = try await client.subscribe(sessionID: "session-test", resume: false)
    let toggle = RelayHookReviewOperation.setEnabled(itemID: "fixture-item", enabled: false)
    await mock.dropAcknowledgement(); await mock.reportUnknownCommands(true)
    let unknown = Task { let result: RelayJSON = try await restored.mutate("v1/sessions/session-test/hooks/review/toggle", body: hookAdapterBody(request, toggle, id: "original-toggle")); return result }
    try await hookAwaitCommand(mock, key: "hook-original-toggle"); unknown.cancel(); _ = try? await unknown.value
    let frozenToggle = await mock.commandEnvelopes["hook-original-toggle"]!
    let _: RelayJSON = try await restored.mutate("v1/sessions/session-test/hooks/review/toggle", body: hookAdapterBody(request, toggle, id: "different-ui-toggle-id"))
    let envelopes = await mock.commandEnvelopes
    try hookAdapterExpect(envelopes["hook-original-toggle"] == frozenToggle && envelopes["hook-different-ui-toggle-id"] == nil && envelopes["hook-original-trust"] == originalEnvelope, "Unknown hook retry changed its wire identity")
    await mock.reportUnknownCommands(false)
    let revoke = RelayHookReviewOperation.revokeSelected(itemIDs: ["fixture-item"])
    await mock.rejectNextCommand(reason: "workspace_hooks_blocked_by_policy")
    let rejectedBody = try hookAdapterBody(request, revoke, id: "rejected-revoke")
    try await hookAdapterReject("workspace_hooks_blocked_by_policy") { let _: RelayJSON = try await restored.mutate("v1/sessions/session-test/hooks/review/revoke", body: rejectedBody) }
    let rejectedCount = await mock.sentCommandCount
    try await hookAdapterReject("workspace_hooks_blocked_by_policy") { let _: RelayJSON = try await restored.mutate("v1/sessions/session-test/hooks/review/revoke", body: rejectedBody) }
    try hookAdapterExpect(await mock.sentCommandCount == rejectedCount, "Known rejection was retried under its terminal ID")
    let fresh: RelayJSON = try await restored.mutate("v1/sessions/session-test/hooks/review/revoke", body: hookAdapterBody(request, revoke, id: "fresh-explicit-revoke"))
    try hookAdapterExpect(fresh["accepted"].bool == true && fresh["acknowledgement"]["commandId"].string == "hook-fresh-explicit-revoke", "A fresh explicit action could not proceed after terminal rejection")
    let second = try hookReviewFixture(generation: 2)
    try await client.unsubscribe(sessionID: "session-test"); try await mock.useHookReview(second); _ = try await client.subscribe(sessionID: "session-test", resume: false)
    await mock.dropAcknowledgement(); await mock.reportUnknownCommands(true)
    let stale = Task { let result: RelayJSON = try await restored.mutate("v1/sessions/session-test/hooks/review/respond", body: hookAdapterBody(second, trust, id: "stale-unknown")); return result }
    try await hookAwaitCommand(mock, key: "hook-stale-unknown"); stale.cancel(); _ = try? await stale.value
    let staleCount = await mock.sentCommandCount
    try await client.unsubscribe(sessionID: "session-test"); try await mock.useHookReview(hookReviewFixture(generation: 3)); _ = try await client.subscribe(sessionID: "session-test", resume: false)
    try await hookAdapterReject("workspace_hooks_review_superseded") { let _: RelayJSON = try await restored.mutate("v1/sessions/session-test/hooks/review/respond", body: hookAdapterBody(second, trust, id: "new-ui-stale-id")) }
    try hookAdapterExpect(await mock.sentCommandCount == staleCount, "A stale unknown review produced a fresh host mutation")
    let journal = try RelayAdapterJournal(scope: "mock-desktop\n/workspace\nhook-facade-stable", directory: directory)
    try hookAdapterExpect(journal.state.commands["hook-stale-unknown"]?.attempted == true && journal.state.commands["hook-stale-unknown"]?.acknowledgement == nil, "Uncertain stale operation was silently discarded")
    let setterCalls = await mock.setterCalls, unexpected = await mock.sawCredentialEndpoint
    try hookAdapterExpect(setterCalls == 0 && !unexpected, "Hook facade changed model settings or used an unrelated host service")
    await restored.shutdown(); await client.disconnect()
    return ["hook_review_original_typed_mapping_and_dedicated_routes", "hook_review_new_ui_uuid_recovers_journal_ack_loss_without_mutating_again", "hook_review_unknown_replay_frozen_wire_terminal_rejection_and_generation_invalidation"]
}
#endif
