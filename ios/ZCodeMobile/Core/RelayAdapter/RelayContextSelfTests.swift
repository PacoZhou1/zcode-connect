#if RELAY_CONTEXT_SELF_TESTS
import Foundation
import Darwin

private actor ContextEvents {
    var values: [BridgeEnvelope] = []
    func add(_ value: BridgeEnvelope) { values.append(value) }
    var contexts: [ContextUsage] { values.filter { $0.type == "context.updated" }.compactMap { $0.data?.contextUsage } }
}
private struct ContextFixture {
    let socket: MockRelaySocket
    let client: RelayClient
    let adapter: RelayRemoteTransport
    let folder: URL
    let journalURL: URL
    func close() async { await adapter.shutdown(); await client.disconnect(); try? FileManager.default.removeItem(at: folder) }
    func savedCommands() throws -> RelayJSON { try RelayJSON(data: Data(contentsOf: journalURL))["commands"] }
}
@main private struct RelayContextSelfTests {
    static func wait(_ note: String = "event", _ predicate: @escaping @Sendable () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline { if await predicate() { return }; try await Task.sleep(for: .milliseconds(10)) }
        throw RelayFailure("test_timeout", "Synthetic event was not observed: " + note)
    }
    static func fixture(_ projection: RelayJSON) async throws -> ContextFixture {
        let socket = MockRelaySocket(), client = try RelayClient(clientID: "context-fixture", transport: socket, requestTimeout: 5)
        await socket.useProjection(projection)
        try await client.connect(pairing: RelayPairing(scannedURL: "https://zcode.z.ai/remote/v4?sid=mock-desktop&hash=mock-pairing-value-0123456789-abcdef"), confirmedControllerReplacement: true)
        let bootstrap = try await client.bootstrap(), bridge = try await client.openWorkspace(key: "/workspace")
        let folder = FileManager.default.temporaryDirectory.appending(path: "relay-context-synthetic-" + UUID().uuidString)
        // An intentionally unresolved synthetic record verifies that unrelated
        // metadata/settings operations never clear or reconcile message identity.
        let journal = try RelayAdapterJournal(scope: "mock-desktop\n/workspace\ncontext-fixture", directory: folder)
        let pending = RelayCommandEnvelope(commandId: "synthetic-pending", clientId: "context-fixture", sessionId: "session-test", type: "sendText", payload: .object(["text": .string("Never sent synthetic journal fixture")]))
        try journal.commit { $0.commands["synthetic-pending"] = .init(intentHash: "synthetic-intent", envelope: pending, attempted: true) }
        let adapter = try await RelayRemoteTransport(client: client, bootstrap: bootstrap, bridge: bridge, hostName: "Synthetic context fixture", journalDirectory: folder)
        let _: RelayJSON = try await adapter.get("v1/sessions")
        return .init(socket: socket, client: client, adapter: adapter, folder: folder, journalURL: journal.url)
    }
    static func check(_ name: String, _ passed: Bool, _ facts: [String: RelayJSON] = [:]) -> RelayJSON {
        .object(facts.merging(["name": .string(name), "passed": .bool(passed)]) { _, new in new })
    }
    static func errorCode(_ error: any Error) -> String { (error as? BridgeFailure)?.code ?? (error as? RelayFailure)?.code ?? String(describing: error) }
    static func settings(_ f: ContextFixture) async -> RelayJSON {
        do { let value: RelayJSON = try await f.adapter.mutate("v1/sessions/session-test/settings", method: "PATCH", body: ["mode": .string("plan")]); return .object(["mode": value["mode"]]) }
        catch { return .object(["error": .string(errorCode(error))]) }
    }
    static func pure(_ fixture: RelayJSON, expectedShares: [RelayJSON]) throws -> [RelayJSON] {
        let initial = try RelayConversationProjection(raw: fixture["initialProjection"])
        let usage = RelayContextUsage(projection: initial)
        var checks = [check("window_tokens_are_not_cumulative_usage", usage.usedTokens == 150000 && usage.maxTokens == 200000 && usage.usedPercent == 75 && usage.autoCompactThresholdTokens == 160000, ["contextUsage": usage.wire])]
        let shares = usage.breakdown
        checks.append(check("seven_category_character_percentages_match_original_desktop_function", shares.count == expectedShares.count && zip(shares, expectedShares).allSatisfy { $0.source == $1["source"].string && $0.chars == $1["chars"].integer && abs($0.percent - ($1["percent"].number ?? -1) * 100) < 0.000001 }))
        let snapshot = try RelaySessionSnapshot(raw: .object(["session": .object(["sessionId": .string("session-test")]), "settings": .object([:]), "runtime": .object(["contextUsage": .object(["used": .int(199000), "size": .int(200000)])]), "messages": .array([])]))
        var raw = try initial.raw.requiringObject(); raw["usage"] = .object(["contextWindow": .null])
        let cleared = RelayContextUsage(projection: try RelayConversationProjection(raw: .object(raw)), snapshot: snapshot)
        checks.append(check("explicit_null_does_not_restore_stale_snapshot_counts", !cleared.available && cleared.usedTokens == nil && cleared.breakdown.isEmpty))
        raw.removeValue(forKey: "usage")
        let fallback = RelayContextUsage(projection: try RelayConversationProjection(raw: .object(raw)), snapshot: snapshot)
        checks.append(check("legacy_missing_window_uses_host_runtime_counters", fallback.usedTokens == 199000 && fallback.maxTokens == 200000))
        for invalid: RelayJSON in [.null, .object(["usedTokens": .int(10), "maxTokens": .int(0)]), .object(["usedTokens": .int(-1), "maxTokens": .int(100)]), .object(["usedTokens": .number(1.5), "maxTokens": .int(100)])] {
            raw["usage"] = .object(["contextWindow": invalid])
            checks.append(check("invalid_or_missing_counts_stay_unavailable", !RelayContextUsage(projection: try RelayConversationProjection(raw: .object(raw))).available))
        }
        raw["usage"] = .object(["contextWindow": .object(["usedTokens": .int(250000), "maxTokens": .int(200000)])])
        let excess = RelayContextUsage(projection: try RelayConversationProjection(raw: .object(raw)))
        checks.append(check("over_capacity_preserves_count_and_bounds_ring", excess.usedTokens == 250000 && excess.usedPercent == 100))
        var reducer = RelayProjectionReducer(projection: initial)
        try reducer.apply(fixture["start"], expectedSessionID: "session-test")
        let started = RelayContextUsage(projection: reducer.projection)
        try reducer.apply(fixture["completed"], expectedSessionID: "session-test")
        let completed = RelayContextUsage(projection: reducer.projection)
        checks.append(check("original_auto_compact_deltas_update_state_and_true_post_count", started.compacting && started.latestCompaction?.status == "running" && completed.compacting == false && completed.latestCompaction?.status == "success" && completed.latestCompaction?.origin == "auto" && completed.latestCompaction?.tokensBefore == 150000 && completed.latestCompaction?.tokensAfter == 40000 && completed.usedTokens == 40000 && completed.usedPercent == 20 && completed.breakdown.isEmpty && started.latestCompaction?.id == completed.latestCompaction?.id, ["started": started.wire, "completed": completed.wire]))
        var stopped = try reducer.projection!.raw.requiringObject()
        var rows = try stopped["rows"]!.requiringObject(), window = rows["window"]!.array!
        var markerRow = try window.last!.requiringObject(), marker = try markerRow["marker"]!.requiringObject(); marker["status"] = .string("running"); markerRow["marker"] = .object(marker); window[window.count-1] = .object(markerRow); rows["window"] = .array(window); stopped["rows"] = .object(rows)
        checks.append(check("historical_running_marker_does_not_override_current_idle_work", !RelayContextUsage(projection: try RelayConversationProjection(raw: .object(stopped))).compacting))
        let decoded = try completed.wire.decode(ContextUsage.self)
        checks.append(check("actual_app_dto_decodes_current_context_and_optional_marker", decoded.usedTokens == 40000 && decoded.compaction.latest?.tokensAfter == 40000 && !decoded.compaction.active))
        return checks
    }
    static func streamed(_ source: RelayJSON) async throws -> RelayJSON {
        let f = try await fixture(source["initialProjection"]), events = ContextEvents()
        let observer = Task { try await f.adapter.events(after: nil) { await events.add($0) } }
        try await wait("listener") { await events.values.contains { $0.type == "ready" } }
        let detail: RelayJSON = try await f.adapter.get("v1/sessions/session-test")
        // Initial load may be delivered by detail before the facade's event pump;
        // establish an observed later row event before counting changed context.
        try await f.socket.sendOnlineText(from: 10, to: 11, ordinal: 2, text: " baseline")
        try await wait("baseline row") { await events.values.contains { $0.type == "message.updated" && $0.data?.message?.text.hasSuffix(" baseline") == true } }
        let baselineCount = await events.contexts.count
        let initialReads = await f.socket.calls.filter { $0 == "readSession" }.count
        let context: RelayJSON = try await f.adapter.get("v1/sessions/session-test/context")
        try await f.socket.publishContextDeltas(source["start"]["payload"]["deltas"].array!, from: 11, to: 12, ordinal: 3)
        try await wait("compact started") { await events.contexts.last?.compaction.active == true }
        try await f.socket.publishContextDeltas(source["completed"]["payload"]["deltas"].array!, from: 12, to: 13, ordinal: 4)
        try await wait("compact completed") { await events.contexts.last?.compaction.latest?.status == "success" }
        try await f.socket.sendOnlineText(from: 13, to: 14, ordinal: 5, text: " final tail")
        try await wait("final row") { await events.values.contains { $0.type == "message.updated" && $0.data?.message?.text.hasSuffix(" final tail") == true } }
        let delivered = await events.contexts, calls = await f.socket.calls
        let current: RelayJSON = try await f.adapter.get("v1/sessions/session-test/context")
        let commandCount = await f.socket.sentCommandCount, setterCount = await f.socket.setterCalls
        let passed = detail["contextUsage"] == context["contextUsage"] && current["contextUsage"]["usedTokens"].integer == 40000 && delivered.count == baselineCount + 2 && delivered.suffix(2).map(\.compaction.active) == [true, false] && calls.filter { $0 == "readSession" }.count == initialReads && calls.allSatisfy { !$0.lowercased().contains("compact") } && commandCount == 0 && setterCount == 0
        let result = check("facade_detail_get_sse_share_real_projection_without_polling_or_compact", passed, ["contextChangeEventCount": .int(delivered.count - baselineCount), "readSessionCalls": .int(initialReads), "final": current, "realTaskOrModelCalls": .int(0)])
        observer.cancel(); await f.close(); return result
    }
    static func contention(_ source: RelayJSON, disposition: String) async throws -> RelayJSON {
        let f = try await fixture(source["initialProjection"])
        let marked: RelayJSON = try await f.adapter.mutate("v1/sessions/session-test", method: "PATCH", body: ["unread": .bool(true)])
        let stamp = marked["session"]["unreadAt"].number!
        let before = try f.savedCommands(); try await f.socket.gateMetadata(true)
        let read = Task { () -> RelayJSON in
            do { return try await f.adapter.mutate("v1/sessions/session-test", method: "PATCH", body: ["unread": .bool(false), "expectedUnreadAt": .number(stamp)]) }
            catch { return .object(["error": .string(errorCode(error))]) }
        }
        try await wait("metadata gate") { await f.socket.unreadCalls.count == 2 }
        let start = ContinuousClock.now
        let change = Task { await settings(f) }
        var otherBusy: String?
        if disposition == "release" {
            do { let _: RelayJSON = try await f.adapter.mutate("v1/sessions/session-test", method: "PATCH", body: ["pinned": .bool(true)]) }
            catch { otherBusy = errorCode(error) }
            try await Task.sleep(for: .milliseconds(100)); try await f.socket.gateMetadata(false)
        } else if disposition == "cancel" { try await Task.sleep(for: .milliseconds(100)); change.cancel() }
        else if disposition == "shutdown" { try await Task.sleep(for: .milliseconds(100)); await f.adapter.shutdown() }
        else if disposition == "scope" {
            try await Task.sleep(for: .milliseconds(100))
            // The real Core correctly refuses an in-place workspace switch while
            // RPCs are pending. Reconnection is what advances this generation.
            await f.client.disconnect()
            try await f.client.connect(pairing: RelayPairing(scannedURL: "https://zcode.z.ai/remote/v4?sid=mock-desktop&hash=mock-pairing-value-0123456789-abcdef"), confirmedControllerReplacement: true)
            _ = try await f.client.bootstrap(); _ = try await f.client.openWorkspace(key: "/workspace")
        }
        let result = await change.value, elapsed = ContinuousClock.now - start
        try await f.socket.gateMetadata(false); _ = await read.value
        let count = await f.socket.setterCalls, commandsPreserved = try f.savedCommands() == before
        let commands = await f.socket.sentCommandCount, queried = await f.socket.calls.contains("queryConversationCommandsV4")
        var passed = commandsPreserved && commands == 0 && !queried
        if disposition == "release" { passed = passed && result["mode"].string == "plan" && count == 1 && otherBusy == "relay_operation_in_progress" }
        else if disposition == "timeout" {
            passed = passed && result["error"].string == "relay_operation_in_progress" && count == 0 && elapsed >= .seconds(3) && elapsed < .seconds(4)
            let retry = await settings(f), afterRetry = await f.socket.setterCalls; passed = passed && retry["mode"].string == "plan" && afterRetry == 1
        } else { passed = passed && result["error"].string != nil && result["mode"].string == nil && count == 0 }
        let answer = check("settings_wait_for_metadata_" + disposition, passed, ["result": result, "setterCountBeforeRetry": .int(count), "pendingCommandUnchanged": .bool(commandsPreserved), "otherBusyCode": otherBusy.map(RelayJSON.string) ?? .null, "elapsedMilliseconds": .number(Double(elapsed.components.seconds)*1000 + Double(elapsed.components.attoseconds)/1e15)])
        await f.close(); return answer
    }
    static func main() async throws {
        let contract = try RelayJSON(data: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
        var checks = try pure(contract["fixture"], expectedShares: contract["desktopShares"].array!)
        checks.append(try await streamed(contract["fixture"]))
        for disposition in ["release", "timeout", "cancel", "shutdown", "scope"] { checks.append(try await contention(contract["fixture"], disposition: disposition)) }
        let passed = checks.allSatisfy { $0["passed"].bool == true }
        let output: RelayJSON = .object(["verifiedAt": .string(ISO8601DateFormatter().string(from: Date())), "passed": .bool(passed), "checks": .array(checks), "boundary": .string("Original installed compact projection deltas and desktop share vectors replayed through actual Swift Core/Facade with memory IPC. All journals, metadata, settings and frames are isolated fixtures. Zero real model, compact, pairing, permission or host task operations.")])
        try output.data().write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
        print(String(data: try output.data(), encoding: .utf8)!); exit(passed ? 0 : 1)
    }
}
#endif
