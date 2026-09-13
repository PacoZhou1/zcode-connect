#if RELAY_TRANSCRIPT_SELF_TESTS
import Foundation

private struct TranscriptCheckError: Error { let message: String }

@main @MainActor private struct RelayTranscriptSelfTests {
    static var assertions = 0
    static func require(_ condition: Bool, _ message: String) throws { assertions += 1; if !condition { throw TranscriptCheckError(message: message) } }
    static func row(_ id: Int, _ kind: String, turn: String = "turn-one", _ fields: [String: RelayJSON] = [:]) -> RelayJSON {
        .object(fields.merging(["rowId": .int(id), "kind": .string(kind), "turnId": .string(turn), "productTurnId": .string(turn), "createdAt": .int(1_700_000_000_000 + id)]) { _, new in new })
    }
    static func basic(_ state: String = "completedSuccess") -> [RelayJSON] {
        [row(1, "turnHeader", ["state": .string(state)]),
         row(2, "userInput", ["origin": .string("realUser"), "text": .string("Original user request")]),
         row(3, "assistantText", ["assistantResponseId": .string("progress-one"), "state": .string("complete"), "text": .string("First progress report")]),
         row(4, "toolCall", ["assistantResponseId": .string("progress-one"), "toolCallId": .string("tool-one"), "toolName": .string("Read"), "status": .string("success"), "output": .object(["text": .string("Original tool output")])]),
         row(5, "assistantText", ["assistantResponseId": .string("progress-two"), "state": .string("complete"), "text": .string("Second progress report")]),
         row(6, "reasoning", ["assistantResponseId": .string("final-one"), "state": .string("complete"), "text": .string("Original reasoning")]),
         row(7, "assistantText", ["assistantResponseId": .string("final-one"), "state": .string("complete"), "text": .string("Original final answer")])]
    }
    static func projection(_ rows: [RelayJSON], phase: String = "completedSuccess") throws -> RelayConversationProjection {
        try .init(raw: .object(["protocolVersion": .int(1), "sessionId": .string("grouping-session"), "logEpoch": .string("epoch"), "seq": .int(100), "revision": .int(3), "control": .object(["phase": .string(phase), "canStop": .bool(phase == "running")]), "rows": .object(["window": .array(rows)])]))
    }
    static func messages(_ rows: [RelayJSON], phase: String = "completedSuccess") throws -> [ChatMessage] {
        try RelayBridgeMapping.messages(projection(rows, phase: phase)).map { try $0.decode(BridgeMessage.self).local }
    }
    static func completed() throws {
        let original = try messages(basic()), turns = TranscriptPresentation.group(original)
        try require(turns.count == 1, "One official product turn was fragmented")
        let t = turns[0]
        try require(t.userMessages.map(\.text) == ["Original user request"], "User intent changed")
        try require(t.processMessages.count == 3 && t.resultMessages.count == 1, "Progress or final reasoning was not separated")
        try require(t.resultMessages[0].text == "Original final answer" && t.resultMessages[0].reasoning == nil, "Final body contains folded reasoning")
        try require(t.processMessages.last?.reasoning == "Original reasoning", "Final reasoning was lost")
        try require(t.defaultCollapsed && t.canCollapseProcess && t.isComplete && t.hasConfirmedResult, "Successful turn did not collapse")
        try require(t.actionMessageID == original.last?.id && t.messages == original, "Actions or original messages changed")
    }
    static func running() throws {
        let live = TranscriptPresentation.group(try messages(basic("running"), phase: "running"))[0]
        try require(!live.isComplete && !live.canCollapseProcess && live.resultMessages.isEmpty && live.actionMessageID == nil, "A complete text segment was promoted while the turn is running")
        try require(live.processMessages.map(\.text).contains("Original final answer"), "Live text was hidden")
        let done = TranscriptPresentation.group(try messages(basic()))[0]
        try require(live.id == done.id && live.messages.map(\.id) == done.messages.map(\.id), "Completion changed stable message or turn identity")
    }
    static func trailingWork() throws {
        for kind in ["toolCall", "subagent", "reasoning"] {
            let rows = basic() + [row(8, kind, ["state": .string("complete"), "status": .string("success"), "assistantResponseId": .string("last-work"), "text": .string("Work after progress")])]
            let t = TranscriptPresentation.group(try messages(rows))[0]
            try require(t.resultMessages.isEmpty && t.actionMessageID == nil && !t.canCollapseProcess, "Last progress before \(kind) became final")
        }
    }
    static func interruptedOrFailed() throws {
        for state in ["completedInterrupted", "failed"] {
            let t = TranscriptPresentation.group(try messages(basic(state)))[0]
            try require(t.isComplete && !t.hasConfirmedResult && !t.canCollapseProcess && t.actionMessageID == nil, "Non-success turn promoted partial text")
            try require(t.processMessages.count == 3, "Interrupted content disappeared")
        }
    }
    static func pagedHeader() throws {
        var rows = basic(); var last = rows.removeLast().object!
        last["actions"] = .object(["canFork": .bool(true)]); rows.append(.object(last))
        let full = TranscriptPresentation.group(try messages(rows))[0], paged = TranscriptPresentation.group(try messages(Array(rows.suffix(4))))[0]
        try require(full.id == paged.id && full.actionMessageID == paged.actionMessageID && paged.hasConfirmedResult, "Stable host boundary was lost before the turn header page arrived")
        let uncertain = TranscriptPresentation.group(try messages(Array(basic().suffix(4))))[0]
        try require(!uncertain.hasConfirmedResult && !uncertain.defaultCollapsed, "Missing-header history guessed completion from global session state")
    }
    static func previousTurnWhileNextRuns() throws {
        let next = [row(10, "turnHeader", turn: "turn-two", ["state": .string("running")]), row(11, "userInput", turn: "turn-two", ["origin": .string("realUser"), "text": .string("Next question")]), row(12, "assistantText", turn: "turn-two", ["assistantResponseId": .string("next-progress"), "state": .string("complete"), "text": .string("Not final")])]
        let turns = TranscriptPresentation.group(try messages(basic() + next, phase: "running"))
        try require(turns.count == 2 && turns[0].hasConfirmedResult && turns[0].defaultCollapsed && !turns[1].hasConfirmedResult && !turns[1].isComplete, "Current session state overwrote previous turn truth")
    }
    static func fragmentIdentity() throws {
        var rows = basic(); var first = rows.removeLast().object!
        first["text"] = .string("First "); rows.append(.object(first))
        rows.append(row(8, "assistantText", ["assistantResponseId": .string("final-one"), "state": .string("complete"), "text": .string("second")]))
        let t = TranscriptPresentation.group(try messages(rows))[0]
        try require(t.resultMessages.count == 1 && t.resultMessages[0].text == "First second", "Original assistant fragments were split or duplicated")
        try require(t.actionMessageID == "relay:grouping-session:assistant:final-one", "Original response identity changed")
    }
    static func resultSplit() throws {
        let semantics = TranscriptMessageSemantics(turnID: "split", state: .completed, role: .finalAnswer)
        let message = ChatMessage(id: "original-result", role: .assistant, text: "Body", elapsed: "2 min", steps: [.init(id: "step", title: "Tool", detail: "Original detail")], changes: [.init(path: "file.swift", additions: 1, deletions: 0, diff: "+line")], reasoning: "Reasoning", attachments: [.init(id: "attachment", fileName: "report.txt", mimeType: "text/plain")], forkTarget: .init(rowId: 7, entityId: "original"), transcript: semantics)
        let t = TranscriptPresentation.group([message])[0], process = t.processMessages[0], answer = t.resultMessages[0]
        try require(process.id == "transcript-process:original-result" && process.text.isEmpty && process.steps == message.steps && process.reasoning == message.reasoning && process.attachments.isEmpty && process.changes.isEmpty && process.forkTarget == nil, "Derived process copy leaks response actions or loses work")
        try require(answer.id == message.id && answer.text == message.text && answer.attachments == message.attachments && answer.changes == message.changes && answer.forkTarget == message.forkTarget && answer.steps.isEmpty && answer.reasoning == nil && answer.elapsed == nil, "Result copy lost original assets or retained process")
        try require(t.messages == [message], "Presentation mutated the canonical transcript")
    }
    static func legacyAndSystem() throws {
        let messages = [ChatMessage(id: "system-head", role: .system, text: "System notice"), ChatMessage(id: "user", role: .user, text: "Question"), ChatMessage(id: "progress", role: .assistant, text: "Progress"), ChatMessage(id: "system-mid", role: .system, text: "Visible control notice"), ChatMessage(id: "last", role: .assistant, text: "Unknown last text")]
        let turns = TranscriptPresentation.group(messages)
        try require(turns.flatMap(\.messages) == messages, "Legacy/system messages were dropped or reordered")
        try require(turns.allSatisfy { !$0.canCollapseProcess && $0.actionMessageID == nil }, "Legacy last-message heuristic fabricated a final result")
    }
    static func emptyResult() throws {
        let message = ChatMessage(id: "tool-only", role: .assistant, text: "", steps: [.init(id: "tool", title: "Tool", detail: "Original output")], reasoning: "Thinking", transcript: .init(turnID: "tool-turn", state: .completed, role: .finalAnswer))
        let t = TranscriptPresentation.group([message])[0]
        try require(t.resultMessages.isEmpty && t.processMessages == [message] && !t.canCollapseProcess && t.actionMessageID == nil, "Tool-only or reasoning-only final metadata collapsed into a blank result")
    }
    static func codingCompatibility() throws {
        let raw: RelayJSON = .object(["id": .string("old"), "role": .string("assistant"), "text": .string("Old payload"), "createdAt": .string("2026-09-13T00:00:00Z"), "isStreaming": .bool(false)])
        try require(raw.decode(BridgeMessage.self).local.transcript == nil, "Old wire payload required new metadata")
        let future = try RelayJSON.object(["turnId": .string("future"), "state": .string("new-state"), "role": .string("new-role")]).decode(TranscriptMessageSemantics.self)
        try require(future.state == .unknown && future.role == .unknown, "Unknown metadata values were promoted")
        let original = ChatMessage(id: "saved", role: .assistant, text: "Saved", transcript: .init(turnID: "turn", state: .completed, role: .finalAnswer))
        try require(JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(original)) == original, "Local transcript metadata did not survive Codable persistence")
    }
    static func snapshotBoundary() throws {
        let user: RelayJSON = .object(["info": .object(["id": .string("u"), "role": .string("user")]), "parts": .array([.object(["type": .string("text"), "text": .string("Original snapshot question")])])])
        let progress: RelayJSON = .object(["info": .object(["id": .string("p"), "role": .string("assistant"), "finish": .string("stop"), "time": .object(["completed": .int(5)])]), "parts": .array([.object(["type": .string("text"), "text": .string("Intermediate")])])])
        let final: RelayJSON = .object(["info": .object(["id": .string("a"), "role": .string("assistant"), "time": .object(["completed": .int(10)]), "anchor": .object(["productTurnId": .string("original-product"), "boundaryMessageId": .string("a"), "orderedMessageIds": .array([.string("u"), .string("p"), .string("a")])])]), "parts": .array([.object(["type": .string("text"), "text": .string("Snapshot final")])])])
        let mapped = try RelayBridgeMapping.snapshotMessages([user, progress, final], sessionID: "child").map { try $0.decode(BridgeMessage.self).local }
        let t = TranscriptPresentation.group(mapped)
        try require(t.count == 1 && t[0].actionMessageID == "a" && t[0].processMessages.map(\.id) == ["p"], "Original persisted product boundary was not preserved")
        let unknown = try RelayBridgeMapping.snapshotMessages([user, progress], sessionID: "child").map { try $0.decode(BridgeMessage.self).local }
        try require(TranscriptPresentation.group(unknown).allSatisfy { !$0.hasConfirmedResult }, "A model finish stop was mistaken for a completed product turn")
    }
    static func main() throws {
        let checks: [(String, () throws -> Void)] = [("completed_product_turn_collapses_only_process", completed), ("running_complete_segment_not_final_and_ids_stable", running), ("trailing_tool_subagent_or_reasoning_prevents_false_final", trailingWork), ("interrupted_and_failed_partial_text_remain_visible", interruptedOrFailed), ("paged_host_boundary_survives_without_guessing_missing_header", pagedHeader), ("historical_completed_turn_independent_of_current_running_task", previousTurnWhileNextRuns), ("same_response_fragments_keep_original_id_and_body", fragmentIdentity), ("mixed_final_splits_process_preserving_assets_and_original", resultSplit), ("legacy_and_system_content_no_heuristic_final", legacyAndSystem), ("tool_only_final_metadata_does_not_hide_all_content", emptyResult), ("old_payload_and_future_enum_and_saved_metadata_compatibility", codingCompatibility), ("snapshot_requires_original_persisted_product_boundary", snapshotBoundary)]
        var results: [RelayJSON] = []
        for (name, run) in checks {
            do { try run(); results.append(.object(["name": .string(name), "passed": .bool(true)])) }
            catch { results.append(.object(["name": .string(name), "passed": .bool(false), "error": .string(String(describing: error))])) }
        }
        let passed = results.filter { $0["passed"].bool == true }.count
        let output: RelayJSON = .object(["verifiedAt": .string(ISO8601DateFormatter().string(from: Date())), "passed": .bool(passed == results.count), "passedCount": .int(passed), "totalCount": .int(results.count), "assertions": .int(assertions), "checks": .array(results), "boundary": .string("Pure production mapping, Codable and grouping tests over synthetic official-shaped rows. No UI, network, CLI, model or user history was accessed.")])
        try output.data().write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
        print(String(data: try output.data(), encoding: .utf8)!)
        if passed != results.count { exit(1) }
    }
}
#endif
