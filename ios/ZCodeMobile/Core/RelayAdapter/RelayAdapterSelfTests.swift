#if RELAY_ADAPTER_SELF_TESTS
import Foundation

private struct AdapterTestFailure: Error { let message: String }
private func expect(_ value: Bool, _ message: String) throws { if !value { throw AdapterTestFailure(message: message) } }
@MainActor private func failure(_ code: String, _ operation: () async throws -> Void) async throws {
    do { try await operation(); throw AdapterTestFailure(message: "Expected " + code) }
    catch let error as BridgeFailure { try expect(error.code == code, "Expected \(code), got \(error.code)") }
    catch let error as RelayFailure { try expect(error.code == code, "Expected \(code), got \(error.code)") }
}
private actor AdapterEvents {
    var events: [BridgeEnvelope] = []
    func append(_ event: BridgeEnvelope) { events.append(event) }
}

@main private struct RelayAdapterSelfTests {
    @MainActor static func main() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "relay-adapter-tests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let mock = MockRelaySocket(), client = try RelayClient(clientID: "adapter-stable-client", transport: mock, requestTimeout: 2)
        let pairing = try RelayPairing(scannedURL: "https://zcode.z.ai/remote/v4?sid=mock-desktop&hash=mock-pairing-value-0123456789-abcdef")
        try await client.connect(pairing: pairing, confirmedControllerReplacement: true)
        let bootstrap = try await client.bootstrap(), bridge = try await client.openWorkspace(key: "/workspace")
        let adapter = try await RelayRemoteTransport(client: client, bootstrap: bootstrap, bridge: bridge, hostName: "Mock desktop", journalDirectory: folder)
        var checks: [String] = []
        checks += try runHookReviewDTOTests()
        checks += try await runHookReviewFacadeTests(directory: folder)
        checks += try await runSubagentFacadeTests(directory: folder)
        var pager = RelaySessionPages()
        let filters: RelayJSON = .object(["includeArchived": .bool(true)]), records: [RelayJSON] = (0..<205).map { .object(["id": .string(String($0))]) }
        let firstPage = try pager.page(records: records, filters: filters, limit: 100, cursor: nil, now: 0)
        let secondPage = try pager.page(filters: filters, limit: 100, cursor: firstPage["pagination"]["nextCursor"].string, now: 1)
        let thirdPage = try pager.page(filters: filters, limit: 100, cursor: secondPage["pagination"]["nextCursor"].string, now: 2)
        let repeatPage = try pager.page(filters: filters, limit: 100, cursor: firstPage["pagination"]["nextCursor"].string, now: 3)
        let ids = [firstPage, secondPage, thirdPage].flatMap { $0["sessions"].array! }.compactMap { $0["id"].string }
        try expect(Set(ids).count == 205 && thirdPage["pagination"]["hasMore"].bool == false && firstPage["pagination"]["total"].integer == 205 && repeatPage == secondPage, "Task pagination lost stable snapshot identity")
        do { _ = try pager.page(filters: .null, limit: 100, cursor: firstPage["pagination"]["nextCursor"].string, now: 4); throw AdapterTestFailure(message: "Changed task filter accepted") }
        catch let error as RelayFailure { try expect(error.code == "session_cursor_mismatch", "Wrong filter failure") }
        do { _ = try pager.page(filters: filters, limit: 100, cursor: firstPage["pagination"]["nextCursor"].string, now: 301); throw AdapterTestFailure(message: "Expired cursor accepted") }
        catch let error as RelayFailure { try expect(error.code == "session_cursor_expired", "Wrong expiry failure") }
        let capped = try pager.page(records: (0..<5001).map { .object(["id": .int($0)]) }, filters: filters, limit: 1000, cursor: nil, now: 302)
        try expect(capped["pagination"]["total"].integer == 5001 && capped["pagination"]["truncated"].bool == true, "Task cap pretended to be complete")
        checks.append("stable_task_list_pagination_cursor_replay_expiry_filters_and_explicit_caps")
        let events = AdapterEvents()
        let observer = Task { try await adapter.events(after: nil) { await events.append($0) } }
        let projects: RelayJSON = try await adapter.get("v1/projects"), projectID = projects["projects"].array!.first!["id"].string!
        let settings: RemoteProjectSettings = try await adapter.get("v1/projects/\(projectID)/settings")
        try expect(settings.model.providerId == "host-provider" && settings.model.thoughtLevel == "max" && settings.mode == "build", "Inherited project settings changed")
        let catalog: RelayJSON = try await adapter.get("v1/models")
        try expect(catalog["models"].array!.first!["thoughtLevels"].array!.contains(.string("max")), "Host catalog not mapped")
        let list: RelayJSON = try await adapter.get("v1/sessions?includeArchived=true")
        try expect(list["sessions"].array?.count == 1, "Pinned list duplicated the task")
        try expect(list["pagination"]["total"].integer == 1 && list["pagination"]["truncated"].bool == false, "Task list completeness missing")
        let detail: BridgeDetail = try await adapter.get("v1/sessions/session-test")
        try expect(detail.messages.first?.text == "Hello", "Transcript mapping failed")
        let activity = try RelayJSON(data: JSONEncoder().encode(detail.hostActivity))
        try expect(activity["goal"]["timeUsedSeconds"].integer == 40 && activity["subagents"]["endedTotal"].integer == 1, "Host activity was fabricated or lost")
        var historical = try await adapter.hostProjection(sessionID: "session-test").raw.requiringObject()
        historical["rows"] = .object(["window": .array([.object(["rowId": .int(2), "kind": .string("subagent"), "childSessionId": .string("child-ended"), "title": .string("Host child title"), "status": .string("success"), "summaryText": .string("Host child summary")])])])
        let mappedHistory = RelayBridgeMapping.activity(try RelayConversationProjection(raw: .object(historical)))
        try expect(mappedHistory["rows"]["window"].array?.first?["summaryText"].string == "Host child summary", "Ended subagent details were lost")
        try expect(await mock.setterCalls == 0, "Read-only routes changed model settings")
        checks.append("bridge_dto_host_models_goal_agents_and_read_only_routes")

        let marked: RelayJSON = try await adapter.mutate("v1/sessions/session-test", method: "PATCH", body: ["unread": .bool(true)])
        let stamp = marked["session"]["unreadAt"].number!
        try expect(stamp == 1_700_000_000_124 && marked["session"]["unread"].bool == true && marked["session"]["unreadScope"].string == "desktop" && marked["metadataScope"].string == "desktop", "Official unread state or millisecond precision was lost")
        let _: RelayJSON = try await adapter.get("v1/sessions/session-test")
        let _: RelayJSON = try await adapter.get("v1/sessions?includeArchived=true")
        try expect(await mock.unreadCalls.count == 1, "A read-only preview cleared unread")
        await mock.setHostUnread(stamp + 10, sessionID: "session-test")
        let staleRead: RelayJSON = try await adapter.mutate("v1/sessions/session-test", method: "PATCH", body: ["unread": .bool(false), "expectedUnreadAt": .number(stamp)])
        try expect(staleRead["unreadApplied"].bool == false && staleRead["session"]["unreadAt"].number == stamp + 10 && staleRead["session"]["unread"].bool == true, "Clearing an older marker erased a newer unread arrival")
        let cleared: RelayJSON = try await adapter.mutate("v1/sessions/session-test", method: "PATCH", body: ["unread": .bool(false), "expectedUnreadAt": .number(stamp + 10)])
        try expect(cleared["unreadApplied"].bool == true && cleared["session"]["unreadAt"] == .null && cleared["session"]["unread"].bool == false, "Matching unread clear was not reflected")
        let unreadCallCount = await mock.unreadCalls.count
        try await failure("relay_invalid_frame") { let _: RelayJSON = try await adapter.mutate("v1/sessions/session-test", method: "PATCH", body: ["unread": .bool(false)]) }
        try await failure("relay_invalid_frame") { let _: RelayJSON = try await adapter.mutate("v1/sessions/session-test", method: "PATCH", body: ["unread": .bool(true), "expectedUnreadAt": .number(stamp)]) }
        try expect(await mock.unreadCalls.count == unreadCallCount, "Invalid unread mutation reached the host")
        checks.append("official_unread_timestamp_scope_and_compare_clear_preserve_newer_arrivals")

        let historyMock = MockRelaySocket(); await historyMock.useHistoricalRows()
        let historyClient = try RelayClient(clientID: "history-client", transport: historyMock, requestTimeout: 2)
        try await historyClient.connect(pairing: pairing, confirmedControllerReplacement: true)
        let historyBootstrap = try await historyClient.bootstrap(), historyBridge = try await historyClient.openWorkspace(key: "/workspace")
        let historyAdapter = try await RelayRemoteTransport(client: historyClient, bootstrap: historyBootstrap, bridge: historyBridge, hostName: "History mock", journalDirectory: folder)
        let initial: RelayJSON = try await historyAdapter.get("v1/sessions/session-test")
        let messageID = initial["messages"].array?.first?["id"]
        try expect(initial["history"]["hasMore"].bool == true && initial["history"]["beforeRowId"].integer == 3, "History cursor did not describe the host window")
        let older: RelayJSON = try await historyAdapter.get("v1/sessions/session-test/messages?beforeRowId=3&logEpoch=epoch-one&limit=200")
        try expect(older["messages"].array?.count == 2 && older["messages"].array?.last?["id"] == messageID && older["messages"].array?.last?["text"].string == "Head tail", "Cross-page assistant response was split or repeated")
        try expect(older["history"]["hasMore"].bool == false && older["history"]["loadedRowCount"].integer == 3, "History completion differs")
        let reloaded: RelayJSON = try await historyAdapter.get("v1/sessions/session-test")
        try expect(reloaded["messages"] == older["messages"], "Detail discarded already loaded history")
        try await failure("relay_history_changed") { let _: RelayJSON = try await historyAdapter.get("v1/sessions/session-test/messages?beforeRowId=3&logEpoch=epoch-one") }
        try await failure("relay_history_changed") { let _: RelayJSON = try await historyAdapter.get("v1/sessions/session-test/messages?beforeRowId=1&logEpoch=old-epoch") }
        try await failure("relay_invalid_frame") { let _: RelayJSON = try await historyAdapter.get("v1/sessions/session-test/messages?beforeRowId=1&logEpoch=epoch-one&limit=201") }
        await historyAdapter.shutdown(); await historyClient.disconnect()
        checks.append("paginated_history_retains_assistant_identity_and_fences_stale_cursors")

        let forkMock = MockRelaySocket(); try await forkMock.useForkRows()
        let forkClient = try RelayClient(clientID: "fork-journal-client", transport: forkMock, requestTimeout: 2)
        try await forkClient.connect(pairing: pairing, confirmedControllerReplacement: true)
        let forkBootstrap = try await forkClient.bootstrap(), forkBridge = try await forkClient.openWorkspace(key: "/workspace")
        let forkAdapter = try await RelayRemoteTransport(client: forkClient, bootstrap: forkBootstrap, bridge: forkBridge, hostName: "Fork mock", journalDirectory: folder)
        let forkDetail: RelayJSON = try await forkAdapter.get("v1/sessions/session-test")
        try expect(forkDetail["session"]["capabilities"]["fork"].bool == true && forkDetail["messages"].array?.first?["forkTarget"]["entityId"].string == "stable-boundary", "Host fork target was not preserved")
        let forkBody: [String: JSONValue] = ["clientForkId": .string("retained-fork")]
        await forkMock.dropAcknowledgement()
        let uncertainFork = Task { let value: RelayJSON = try await forkAdapter.mutate("v1/sessions/session-test/fork", body: forkBody); return value }
        let forkKey = "fork-" + relayDigest(Data("retained-fork".utf8))
        for _ in 0..<100 { if await forkMock.commands[forkKey] != nil { break }; try await Task.sleep(for: .milliseconds(10)) }
        try expect(await forkMock.commands[forkKey] != nil, "Fork did not reach the host")
        uncertainFork.cancel(); _ = try? await uncertainFork.value; await forkAdapter.shutdown()
        let originalFork = await forkMock.commandEnvelopes[forkKey]!
        let forkRestored = try await RelayRemoteTransport(client: forkClient, bootstrap: forkBootstrap, bridge: forkBridge, hostName: "Fork mock", journalDirectory: folder)
        let beforeForkQueries = await forkMock.sentCommandCount
        let recoveredFork: RelayJSON = try await forkRestored.mutate("v1/sessions/session-test/fork", body: forkBody)
        let childID = recoveredFork["forkedSessionId"].string!
        try expect(childID != "session-test" && recoveredFork["session"]["id"].string == childID, "Fork did not return its real child")
        try expect(await forkMock.sentCommandCount == beforeForkQueries, "Known fork result was sent again")
        try expect(await forkMock.setterCalls == 0, "Fork changed model, thinking or mode")
        try await failure("fork_conflict") { let _: RelayJSON = try await forkRestored.mutate("v1/sessions/session-test/fork", body: ["clientForkId": .string("retained-fork"), "target": .object(["rowId": .number(9), "entityId": .string("stable-boundary")])]) }
        await forkMock.dropAcknowledgement(); await forkMock.reportUnknownCommands(true)
        let unknownBody: [String: JSONValue] = ["clientForkId": .string("unknown-fork")]
        let unknownKey = "fork-" + relayDigest(Data("unknown-fork".utf8))
        let unknownFork = Task { let value: RelayJSON = try await forkRestored.mutate("v1/sessions/session-test/fork", body: unknownBody); return value }
        for _ in 0..<100 { if await forkMock.commands[unknownKey] != nil { break }; try await Task.sleep(for: .milliseconds(10)) }
        unknownFork.cancel(); _ = try? await unknownFork.value
        let originalUnknown = await forkMock.commandEnvelopes[unknownKey]!
        let _: RelayJSON = try await forkRestored.mutate("v1/sessions/session-test/fork", body: unknownBody)
        let replayedForkEnvelopes = await forkMock.commandEnvelopes
        try expect(replayedForkEnvelopes[unknownKey] == originalUnknown && replayedForkEnvelopes[forkKey] == originalFork, "Unknown fork replay changed its envelope")
        await forkMock.rejectNextCommand(reason: "proto.staleRevision")
        let rejectedBody: [String: JSONValue] = ["clientForkId": .string("rejected-fork")]
        try await failure("fork_rejected") { let _: RelayJSON = try await forkRestored.mutate("v1/sessions/session-test/fork", body: rejectedBody) }
        let rejectedCount = await forkMock.sentCommandCount
        try await failure("fork_rejected") { let _: RelayJSON = try await forkRestored.mutate("v1/sessions/session-test/fork", body: rejectedBody) }
        try expect(await forkMock.sentCommandCount == rejectedCount, "A terminal rejected fork was sent again")
        checks.append("native_fork_target_durable_journal_ack_loss_restart_and_unknown_query_replay")
        let archived: RelayJSON = try await forkRestored.mutate("v1/sessions/\(childID)", method: "PATCH", body: ["archived": .bool(true)])
        try expect(archived["session"]["archived"].bool == true, "Archive was not confirmed from host list")
        try await failure("session_archived") { let _: RelayJSON = try await forkRestored.mutate("v1/sessions/\(childID)/messages", body: ["text": .string("Blocked"), "inputId": .string("archive-blocked")]) }
        let unarchived: RelayJSON = try await forkRestored.mutate("v1/sessions/\(childID)", method: "PATCH", body: ["archived": .bool(false)])
        try expect(unarchived["session"]["archived"].bool == false && unarchived["metadataScope"].string == "desktop", "Restore was not confirmed from host list")
        await forkRestored.shutdown(); await forkClient.disconnect()
        checks.append("official_archive_restore_readback_with_metadata_omitting_archive_flags")

        let listing: BridgeFileListing = try await adapter.get("v1/projects/\(projectID)/files?search=main")
        try expect(listing.files.map(\.path) == ["src/main.swift"] && listing.searchComplete == true, "Safe recursive search failed")
        let text: RelayJSON = try await adapter.get("v1/projects/\(projectID)/file?path=README.md")
        try expect(text["content"].string == "hello", "Host file preview failed")
        for path in ["../secrets", "secrets.json", "link.txt"] {
            try await failure("file_restricted") { let _: RelayJSON = try await adapter.get("v1/projects/\(projectID)/file?path=\(path)") }
        }
        let changes: BridgeChanges = try await adapter.get("v1/sessions/session-test/changes")
        try expect(changes.files.first?.diff == "+hello" && changes.source == "workspace-git-unstaged", "Workspace changes mapping failed")
        checks.append("recursive_file_search_preview_symlink_secret_guards_and_git_mapping")

        let body: [String: JSONValue] = ["projectId": .string(projectID), "clientDraftId": .string("stable-draft"), "mode": .string("plan"), "title": .string("Native isolated mock draft")]
        let created: RelayJSON = try await adapter.mutate("v1/sessions", body: body)
        let createdID = created["session"]["id"].string!
        let count = await mock.sentCommandCount, setters = await mock.setterCalls
        let again: RelayJSON = try await adapter.mutate("v1/sessions", body: body)
        let repeatedCount = await mock.sentCommandCount, repeatedSetters = await mock.setterCalls
        try expect(again["session"]["id"].string == createdID && repeatedCount == count && repeatedSetters == setters, "Creation retry created or configured another task")
        var changed = body; changed["mode"] = .string("build")
        try await failure("draft_conflict") { let _: RelayJSON = try await adapter.mutate("v1/sessions", body: changed) }
        let plan: RemoteSettings = try await adapter.mutate("v1/sessions/\(createdID)/settings", method: "PATCH", body: ["permissionMode": .string("edit")])
        try expect(plan.mode == "plan" && plan.permissionMode == "edit", "Permission preference exited the host plan mode")
        try await failure("full_access_confirmation_required") { let _: RelayJSON = try await adapter.mutate("v1/sessions/\(createdID)/settings", method: "PATCH", body: ["permissionMode": .string("yolo")]) }
        try expect(await mock.configurationThought == "max", "Thinking level changed")
        checks.append("durable_empty_create_idempotency_and_permission_preference_preserves_plan")

        let upload: [String: JSONValue] = ["fileName": .string("note.txt"), "mimeType": .string("text/plain"), "base64": .string(Data("hello".utf8).base64EncodedString())]
        let first: RelayJSON = try await adapter.mutate("v1/sessions/session-test/attachments", body: upload)
        let attachmentID = first["attachment"]["id"].string!
        let uploadCount = await mock.uploadChunks
        let second: RelayJSON = try await adapter.mutate("v1/sessions/session-test/attachments", body: upload)
        let repeatedUploadCount = await mock.uploadChunks
        try expect(second == first && repeatedUploadCount == uploadCount, "Upload mapping was not stable")
        let message: [String: JSONValue] = ["text": .string("One original message"), "inputId": .string("durable-send"), "attachmentIds": .array([.string(attachmentID)])]
        await mock.dropAcknowledgement()
        let uncertain = Task { let result: RelayJSON = try await adapter.mutate("v1/sessions/session-test/messages", body: message); return result }
        for _ in 0..<100 { if await mock.commands["durable-send"] != nil { break }; try await Task.sleep(for: .milliseconds(10)) }
        try expect(await mock.commands["durable-send"] != nil, "Mock send never reached the host")
        uncertain.cancel(); _ = try? await uncertain.value
        let originalEnvelope = await mock.commandEnvelopes["durable-send"]!
        observer.cancel(); _ = try? await observer.value
        await adapter.shutdown()

        let restored = try await RelayRemoteTransport(client: client, bootstrap: bootstrap, bridge: bridge, hostName: "Mock desktop", journalDirectory: folder)
        let sentBefore = await mock.sentCommandCount
        let result: RelayJSON = try await restored.mutate("v1/sessions/session-test/messages", body: message)
        let resumedCommandCount = await mock.sentCommandCount
        try expect(result["accepted"].bool == true && resumedCommandCount == sentBefore, "Uncertain send was duplicated instead of queried")
        let afterRestart: RelayJSON = try await restored.mutate("v1/sessions/session-test/attachments", body: upload)
        let resumedUploadCount = await mock.uploadChunks
        try expect(afterRestart == first && resumedUploadCount == uploadCount, "Attachment mapping was lost on restart")
        let journalFiles = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        let saved = try journalFiles.map { try JSONDecoder().decode(RelayAdapterJournal.State.self, from: Data(contentsOf: $0)) }.first { $0.commands["durable-send"] != nil }!
        try expect(saved.commands["durable-send"]?.envelope.json() == originalEnvelope, "Saved envelope changed on retry")
        try expect((try FileManager.default.attributesOfItem(atPath: journalFiles.first!.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600, "Journal was not private")
        var differentMessage = message; differentMessage["text"] = .string("changed")
        try await failure("input_conflict") { let _: RelayJSON = try await restored.mutate("v1/sessions/session-test/messages", body: differentMessage) }
        checks.append("process_restart_preserves_attachment_refs_and_queries_original_uncertain_command")

        let restoredEvents = AdapterEvents(), nextObserver = Task { try await restored.events(after: "expired") { await restoredEvents.append($0) } }
        let restoredDetail: BridgeDetail = try await restored.get("v1/sessions/session-test")
        try expect(restoredDetail.hostActivity != nil, "Activity disappeared after observer replacement")
        for _ in 0..<100 { if await restoredEvents.events.contains(where: { $0.type == "ready" }) { break }; try await Task.sleep(for: .milliseconds(10)) }
        try expect(await restoredEvents.events.contains(where: { $0.type == "resync.required" }), "Expired event cursor was accepted")
        try await failure("goal_remove_unsupported") { let _: RelayJSON = try await restored.mutate("v1/sessions/session-test/goal/remove", body: [:]) }
        try await failure("relay_route_unsupported") { let _: RelayJSON = try await restored.get("v1/arbitrary-secret-service") }
        nextObserver.cancel(); _ = try? await nextObserver.value; await restored.shutdown(); await client.disconnect()
        try expect(await mock.sawCredentialEndpoint == false, "Unexpected credential endpoint")
        checks.append("replaceable_event_observers_cursor_recovery_and_explicit_unsupported_operations")

        let output: RelayJSON = .object(["passed": .bool(true), "verifiedAt": .string(ISO8601DateFormatter().string(from: Date())), "checks": .array(checks.map(RelayJSON.string)), "realAccountConnected": .bool(false), "liveVerified": .bool(false)])
        if let directory = CommandLine.arguments.dropFirst().first { try output.data().write(to: URL(fileURLWithPath: directory).appending(path: "swift-relay-adapter-validation.json"), options: .atomic) }
        print(String(data: try output.data(), encoding: .utf8)!)
    }
}
#endif
