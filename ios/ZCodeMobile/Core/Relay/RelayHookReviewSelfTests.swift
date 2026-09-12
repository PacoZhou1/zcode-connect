#if RELAY_SELF_TESTS || RELAY_ADAPTER_SELF_TESTS
import Foundation

private struct HookTestFailure: Error { let message: String }
private func hookExpect(_ condition: Bool, _ message: String) throws { if !condition { throw HookTestFailure(message: message) } }
private func hookReject(_ body: () throws -> Void) throws {
    do { try body(); throw HookTestFailure(message: "Expected hook review rejection") }
    catch is HookTestFailure { throw HookTestFailure(message: "Expected hook review rejection") } catch {}
}
@MainActor private func hookRejectAsync(_ code: String, _ body: () async throws -> Void) async throws {
    do { try await body(); throw HookTestFailure(message: "Expected " + code) }
    catch let error as RelayFailure { try hookExpect(error.code == code, "Expected \(code), got \(error.code)") }
}

func hookReviewFixture(generation: Int = 1) throws -> RelayHookReviewRequest {
    let directory = CommandLine.arguments.dropFirst().first ?? "/Users/developer/claude code/zcode-mobile/docs/backend/evidence"
    let evidence = try RelayJSON(data: Data(contentsOf: URL(fileURLWithPath: directory).appending(path: "hook-review-contract.json")))
    var value = try evidence["vectors"]["request"].requiringObject()
    value["sessionId"] = .string("session-test"); value["taskId"] = .string("session-test"); value["workspaceIdentity"] = .string("/workspace")
    value["generation"] = .int(generation); value["interactionId"] = .string("fixture-review-\(generation)")
    let now = Date().timeIntervalSince1970 * 1000
    value["createdAt"] = .number(now - 1000); value["deadlineAt"] = .number(now + 600_000)
    return try .init(wire: .object(value))
}

func runHookReviewDTOTests() throws -> [String] {
    let request = try hookReviewFixture(), operation = RelayHookReviewOperation.trustSelected(itemIDs: ["fixture-item"])
    let encoded = try JSONEncoder().encode(request), decoded = try JSONDecoder().decode(RelayHookReviewRequest.self, from: encoded)
    try hookExpect(decoded == request, "Typed review roundtrip changed the immutable request")
    let confirmation = try request.confirmation(for: operation, userConfirmed: true)
    try request.validateConfirmation(confirmation, operation: operation)
    try hookReject { _ = try request.confirmation(for: operation, userConfirmed: false) }
    try hookReject { _ = try request.confirmation(for: operation, userConfirmed: true, now: request.deadlineAt) }
    try hookReject { try request.validate(.trustSelected(itemIDs: [])) }
    try hookReject { try request.validate(.trustSelected(itemIDs: ["fixture-item", "fixture-item"])) }
    try hookReject { try request.validate(.trustSelected(itemIDs: ["unknown"])) }
    try hookReject { try request.validateConfirmation(confirmation, operation: .revokeSelected(itemIDs: ["fixture-item"])) }
    for (key, bad): (String, RelayJSON) in [("bundleDigest", .string("bad")), ("generation", .int(0)), ("deadlineAt", .number(request.createdAt - 1)), ("allowOnce", .bool(true))] {
        var changed = try request.wire.requiringObject(); changed[key] = bad
        try hookReject { _ = try RelayHookReviewRequest(wire: .object(changed)) }
    }
    var changed = try request.wire.requiringObject(), item = try request.items[0].wire.requiringObject()
    item["displayCommand"] = .string("OTHER_COMMAND_NOT_EXECUTED"); changed["items"] = .array([.object(item)])
    let modified = try RelayHookReviewRequest(wire: .object(changed))
    try hookReject { try modified.validateConfirmation(confirmation, operation: operation) }
    item["editable"] = .bool(false); changed["items"] = .array([.object(item)])
    try hookReject { try RelayHookReviewRequest(wire: .object(changed)).validate(.setEnabled(itemID: "fixture-item", enabled: false)) }
    var pending: [String: RelayJSON] = ["interactionId": .string(request.interactionId), "kind": .string(request.kind), "payload": request.wire]
    pending["autoResolution"] = .object([:])
    try hookReject { _ = try RelayPendingInteraction(raw: .object(pending)).workspaceHookReview() }
    return ["official_hook_review_dto_exact_fields_confirmation_fingerprint_expiry_and_selection_guards"]
}

@MainActor func runConversationCapabilityTests() async throws -> [String] {
    let request = try hookReviewFixture(), mock = MockRelaySocket()
    try await mock.useHookReview(request)
    let client = try RelayClient(clientID: "capability-client", transport: mock, requestTimeout: 2)
    let pairing = try RelayPairing(scannedURL: "https://zcode.z.ai/remote/v4?sid=mock-desktop&hash=mock-pairing-value-0123456789-abcdef")
    try await client.connect(pairing: pairing, confirmedControllerReplacement: true)
    _ = try await client.bootstrap(); _ = try await client.openWorkspace(key: "/workspace")
    async let subscription = client.subscribe(sessionID: "session-test")
    async let query = client.queryCommands([.init(sessionId: "session-test", commandId: "never-submitted")])
    _ = try await (subscription, query)
    try hookExpect(await mock.clientHellos.count == 1, "Concurrent subscription and query initialized the same bridge twice")
    _ = try await client.openWorkspace(key: "/workspace")
    try hookExpect(await !client.workspaceHookReviewSupported, "A new bridge inherited the previous capability state")
    var hello: [String: RelayJSON] = ["kind": .string("hello"), "protocolVersion": .int(3), "connectionId": .string("mock-second-connection"), "clientMode": .string("web-remote-replayable"), "deliveryProfile": .string("replayable"), "serverTime": .int(1_700_000_000_000), "capabilities": .object(["nativeDialogs": .bool(false), "localTerminal": .bool(false), "binaryFrames": .bool(false), "compression": .string("none"), "workspaceHookReview": .bool(false)]), "auth": .object([:])]
    await mock.useConversationHello(.object(hello)); _ = try await client.subscribe(sessionID: "session-test", resume: false)
    try hookExpect(await mock.clientHellos.count == 2, "A newly attached bridge was not initialized independently")
    try await hookRejectAsync("workspace_hooks_require_trust_capable_host") { _ = try await client.requestHookReview(sessionID: request.sessionId, workspaceIdentity: request.workspaceIdentity, bundleDigest: request.bundleDigest, commandID: "unsupported-capability", explicitUserAction: true) }
    try hookExpect(await mock.sentCommandCount == 0, "Unsupported host capability produced a mutation")
    _ = try await client.openWorkspace(key: "/workspace")
    hello["deliveryProfile"] = .string("continuous"); await mock.useConversationHello(.object(hello))
    try await hookRejectAsync("relay_protocol_unsupported") { _ = try await client.subscribe(sessionID: "session-test", resume: false) }
    try hookExpect(await mock.clientHellos.count == 2, "An incompatible server hello reached ClientHello")
    await client.disconnect()
    return ["conversation_capability_strict_hello_once_per_bridge_concurrency_scope_and_unsupported_host_guards"]
}

@MainActor func runHookReviewClientTests() async throws -> [String] {
    let request = try hookReviewFixture(), operation = RelayHookReviewOperation.trustSelected(itemIDs: ["fixture-item"])
    let mock = MockRelaySocket(); try await mock.useHookReview(request)
    let client = try RelayClient(clientID: "hook-client-only", transport: mock, requestTimeout: 2)
    let pairing = try RelayPairing(scannedURL: "https://zcode.z.ai/remote/v4?sid=mock-desktop&hash=mock-pairing-value-0123456789-abcdef")
    try await client.connect(pairing: pairing, confirmedControllerReplacement: true)
    _ = try await client.bootstrap(); _ = try await client.openWorkspace(key: "/workspace"); _ = try await client.subscribe(sessionID: "session-test")
    try hookExpect(await client.workspaceHookReviewSupported, "Host hook capability was not negotiated")
    let helloCalls = await mock.calls
    try hookExpect(helloCalls.firstIndex(of: "helloConversationV4")! < helloCalls.firstIndex(of: "initializeConversationV4")! && helloCalls.firstIndex(of: "initializeConversationV4")! < helloCalls.firstIndex(of: "subscribeConversationV4")!, "Conversation capabilities were initialized after subscribing")
    let confirmation = try request.confirmation(for: operation, userConfirmed: true)
    let authorization = try RelayHookReviewAuthorization(request: request, operation: operation, confirmation: confirmation)
    let command = try await client.makeHookReviewCommand(authorization: authorization, commandID: "hook-exact-command")
    try hookExpect(command.type == "respondWorkspaceHookReview" && command.payload == (try operation.payload(target: request.target)), "Hook review used a generic interaction or lost the exact target")
    try await hookRejectAsync("hook_review_confirmation_required") { _ = try await client.submit(command, explicitUserAction: true) }
    try await hookRejectAsync("interaction_unsupported") { _ = try await client.reply(sessionID: "session-test", interactionID: request.interactionId, answer: .decline, commandID: "hook-generic-deny", explicitUserAction: true) }
    let beforeRejected = await mock.sentCommandCount
    do { _ = try await client.submit(command, explicitUserAction: false, hookReviewAuthorization: authorization); throw HookTestFailure(message: "Missing user action was accepted") }
    catch is RelayFailure {}
    try hookExpect(await mock.sentCommandCount == beforeRejected, "Invalid consent reached the mock host")
    let ack = try await client.submit(command, explicitUserAction: true, hookReviewAuthorization: authorization); try hookExpect(ack.admitted, "Dedicated confirmed hook command was not admitted")
    _ = try await client.requestHookReview(sessionID: request.sessionId, workspaceIdentity: request.workspaceIdentity, bundleDigest: request.bundleDigest, commandID: "hook-request-only", explicitUserAction: true)
    let toggle = RelayHookReviewOperation.setEnabled(itemID: "fixture-item", enabled: false)
    _ = try await client.toggleHookReviewItem(request: request, itemID: "fixture-item", enabled: false, confirmation: request.confirmation(for: toggle, userConfirmed: true), commandID: "hook-toggle-mock", explicitUserAction: true)
    let revoke = RelayHookReviewOperation.revokeSelected(itemIDs: ["fixture-item"])
    _ = try await client.revokeHookTrust(request: request, selectedItemIDs: ["fixture-item"], confirmation: request.confirmation(for: revoke, userConfirmed: true), commandID: "hook-revoke-mock", explicitUserAction: true)
    var changed = try request.wire.requiringObject(); changed["workspaceIdentity"] = .string("another-workspace")
    let cross = try RelayHookReviewRequest(wire: .object(changed)), crossConsent = try cross.confirmation(for: operation, userConfirmed: true)
    try await hookRejectAsync("workspace_hooks_snapshot_mismatch") { _ = try await client.trustHookReview(request: cross, selectedItemIDs: ["fixture-item"], confirmation: crossConsent, commandID: "hook-wrong-workspace", explicitUserAction: true) }
    try await client.unsubscribe(sessionID: "session-test"); try await mock.useHookReview(hookReviewFixture(generation: 2)); _ = try await client.subscribe(sessionID: "session-test", resume: false)
    try await hookRejectAsync("workspace_hooks_review_superseded") { _ = try await client.submit(command, explicitUserAction: true, hookReviewAuthorization: authorization) }
    let setterCalls = await mock.setterCalls, unexpectedService = await mock.sawCredentialEndpoint
    try hookExpect(setterCalls == 0 && !unexpectedService, "Hook tests changed model settings or called an unexpected service")
    try hookExpect(await mock.clientHellos.count == 1, "The client changed conversation identity during a workspace attachment")
    await client.disconnect()
    try hookExpect(await !client.workspaceHookReviewSupported, "Disconnected desktop retained hook capabilities")
    return ["dedicated_hook_commands_require_specific_consent_and_reject_generic_cross_workspace_and_superseded_review"]
}
#endif
