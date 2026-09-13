import Foundation

enum RelayBridgeMapping {
    static func date(_ milliseconds: Double?) -> RelayJSON {
        .string(ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: (milliseconds ?? 0) / 1000)))
    }
    static func status(_ projection: RelayConversationProjection?, snapshot: RelaySessionSnapshot?, meta: RelayTaskMetadata?) -> String {
        if let projection {
            if !projection.pendingInteractions.isEmpty { return "waiting" }
            switch projection.phase {
            case "running", "prewarming": return "running"
            case "completedSuccess": return "completed"
            case "completedInterrupted", "draft": return "idle"
            case "error": return "error"
            default: break
            }
        }
        let value = snapshot?.status ?? meta?.displayStatus ?? meta?.status ?? "idle"
        if value == "failed" { return "error" }; return value
    }
    static func session(id: String, meta: RelayTaskMetadata?, snapshot: RelaySessionSnapshot?, projection: RelayConversationProjection?, bridge: RelayBridge, projectID: String) -> RelayJSON {
        let state = status(projection, snapshot: snapshot, meta: meta)
        let controllable = meta?.provider == nil || meta?.provider == "glm"
        let archived = meta?.archived ?? false
        var value: [String: RelayJSON] = ["id": .string(id), "title": .string(meta?.title.nilIfEmpty ?? projection?.title.nilIfEmpty ?? snapshot?.title.nilIfEmpty ?? "新任务"), "projectId": .string(projectID), "projectName": .string(URL(fileURLWithPath: bridge.workspacePath).lastPathComponent), "source": .string("official-relay"), "status": .string(state), "updatedAt": date(meta?.updatedAt ?? snapshot?.raw["session"]["updatedAt"].number), "pinned": .bool(meta?.pinned ?? false), "archived": .bool(archived),
            "unread": .bool(meta?.unreadAt != nil), "unreadAt": meta?.unreadAt.map(RelayJSON.number) ?? .null, "unreadScope": .string("desktop"),
            "capabilities": .object(["read": .bool(controllable), "send": .bool(controllable && !archived), "stop": .bool(controllable && (projection?.canStop ?? ["running", "waiting"].contains(state))), "approve": .bool(controllable), "changes": .bool(true), "markUnread": .bool(controllable), "rename": .bool(controllable), "pin": .bool(controllable), "archive": .bool(controllable), "fork": .bool(controllable && !archived && !(projection?.forkTargets.isEmpty ?? true))])]
        var provider = snapshot?.model["providerId"].string ?? projection?.config["provider"].string
        var model = snapshot?.model["modelId"].string ?? projection?.config["model"].string
        if model == nil, let stored = meta?.model {
            let pieces = stored.split(separator: "/", maxSplits: 1).map(String.init)
            if pieces.count == 2 { provider = pieces[0]; model = pieces[1] } else { model = stored }
        }
        if let provider { value["providerId"] = .string(provider) }
        if let model { value["model"] = .string(model) }
        if let thought = snapshot?.thoughtLevel ?? projection?.config["thought"].string ?? meta?.thoughtLevel { value["thoughtLevel"] = .string(thought) }
        return .object(value)
    }
    static func modelSelection(settings: RelayJSON) throws -> RelayJSON {
        var model = try settings["model"]["current"].requiringObject()
        _ = try RelayJSON.object(model).requiringString("providerId"); _ = try RelayJSON.object(model).requiringString("modelId")
        if let thought = settings["thoughtLevel"]["current"].string { model["thoughtLevel"] = .string(thought) }
        return .object(model)
    }
    static func subagentSession(_ snapshot: RelaySessionSnapshot, parentID: String, bridge: RelayBridge, projectID: String) -> RelayJSON {
        var value = session(id: snapshot.sessionID, meta: nil, snapshot: snapshot, projection: nil, bridge: bridge, projectID: projectID).object!
        value["source"] = .string("official-relay-subagent"); value["parentSessionId"] = .string(parentID); value["rootSessionId"] = .string(parentID)
        value["statusSource"] = .string("host-existing-runtime")
        value["capabilities"] = .object(["read": .bool(true), "send": .bool(false), "stop": .bool(false), "approve": .bool(false), "changes": .bool(false), "settings": .bool(false), "attachments": .bool(false), "markUnread": .bool(false), "rename": .bool(false), "pin": .bool(false), "archive": .bool(false), "fork": .bool(false), "hookReview": .bool(false)])
        return .object(value)
    }
    /// Legacy session/read is the only verified existing-runtime-only child history service.
    /// Visibility metadata, original message IDs and every visible content part are preserved.
    static func snapshotMessages(_ rows: [RelayJSON], sessionID: String? = nil) -> [RelayJSON] {
        let semantics = RelayTranscriptSemantics.snapshot(rows, sessionID: sessionID)
        func visible(_ value: RelayJSON) -> Bool {
            let semantics = value["semantics"].object != nil ? value["semantics"] : value["metadata"]["semantics"]
            return semantics["uiVisibility"].string != "hidden" && semantics["transcriptVisibility"].string != "hidden" && value["visibility"].string != "model-only" && value["metadata"]["visibility"].string != "model-only"
        }
        return rows.compactMap { row in
            let info = row["info"], parts = (row["parts"].array ?? []).filter(visible)
            guard visible(row), visible(info), let id = info["messageId"].string ?? info["id"].string else { return nil }
            let text = parts.filter { $0["type"].string == "text" }.compactMap { $0["text"].string }.joined(separator: "\n")
            let reasoning = parts.filter { $0["type"].string == "reasoning" }.compactMap { $0["text"].string }.joined(separator: "\n")
            let tools: [RelayJSON] = parts.filter { $0["type"].string == "tool" }.compactMap { part in
                guard let toolID = part["callID"].string ?? part["callId"].string ?? part["partId"].string ?? part["id"].string else { return nil }
                let output = part["state"]["output"].string ?? part["state"]["error"].string ?? part["output"].string
                return .object(["id": .string(toolID), "name": .string(part["tool"].string ?? part["name"].string ?? "Tool"), "status": .string(part["state"]["status"].string ?? part["status"].string ?? "completed"), "input": part["state"]["input"] == .null ? part["input"] : part["state"]["input"], "output": output.map(RelayJSON.string) ?? .null])
            }
            let attachments: [RelayJSON] = parts.filter { $0["type"].string == "file" }.compactMap { part in
                guard let attachmentID = part["partId"].string ?? part["id"].string else { return nil }
                return .object(["id": .string(attachmentID), "fileName": .string(part["filename"].string ?? "Attachment"), "mimeType": part["mime"]])
            }
            guard !text.isEmpty || !reasoning.isEmpty || !tools.isEmpty || !attachments.isEmpty else { return nil }
            let role = info["role"].string ?? "system"
            var message: [String: RelayJSON] = ["id": .string(id), "role": .string(["user", "assistant", "system", "tool"].contains(role) ? role : "system"), "text": .string(text), "reasoning": .string(reasoning), "toolCalls": .array(tools), "attachments": .array(attachments), "createdAt": date(info["time"]["created"].number ?? info["time_created"].number), "isStreaming": .bool(false)]
            if let meaning = semantics[id] { message["transcript"] = meaning.wire }
            return .object(message)
        }
    }
    static func models(_ options: [RelayJSON]) -> RelayJSON {
        .object(["models": .array(options.compactMap { option in
            guard let provider = option["ref"]["providerId"].string, let model = option["ref"]["modelId"].string else { return nil }
            return .object(["providerId": .string(provider), "providerName": option["providerLabel"].string.map(RelayJSON.string) ?? .string(provider), "modelId": .string(model), "name": option["label"].string.map(RelayJSON.string) ?? .string(model), "available": .bool(option["disabledReason"].string == nil), "unavailableReason": option["disabledReason"], "supportsImages": .bool(option["supportsImages"].bool == true), "supportsPDF": .bool(option["supportsPdf"].bool == true), "thoughtLevels": .array((option["reasoning"]["levels"].array ?? []).compactMap { $0["value"].string.map(RelayJSON.string) }), "defaultThoughtLevel": option["reasoning"]["defaultLevel"]])
        }), "modes": .array(["build", "edit", "plan", "yolo"].map(RelayJSON.string))])
    }
    static func settings(_ snapshot: RelaySessionSnapshot, permissionMode: String?) throws -> RelayJSON {
        var value: [String: RelayJSON] = ["sessionId": .string(snapshot.sessionID), "model": try modelSelection(settings: snapshot.raw["settings"]), "mode": snapshot.mode.map(RelayJSON.string) ?? .null,
            "thoughtLevels": .array((snapshot.raw["settings"]["thoughtLevel"]["available"].array ?? []).compactMap { ($0["value"].string ?? $0.string).map(RelayJSON.string) }), "modes": .array(["build", "edit", "plan", "yolo"].map(RelayJSON.string)), "mutable": .bool(snapshot.activeTurnID == nil && !["running", "waiting"].contains(snapshot.status))]
        if let permissionMode { value["permissionMode"] = .string(permissionMode) }
        return .object(value)
    }
    static func activity(_ projection: RelayConversationProjection, directory: RelaySubagentDirectory? = nil, directoryError: String? = nil) -> RelayJSON {
        var agents = projection.raw["subagents"].object ?? ["revision": .int(0), "childSessionIds": .array([]), "running": .array([]), "endedTotal": .int(0)]
        if let directory {
            agents["ended"] = directory.raw["ended"]
            agents["childSessionIds"] = .array(Array(Set((agents["childSessionIds"]?.array ?? []).compactMap(\.string) + directory.childSessionIDs)).sorted().map(RelayJSON.string))
            agents["directoryRevision"] = .int(directory.revision)
        }
        if let directoryError { agents["directoryError"] = .string(directoryError) }
        // Directory records stay in their own official collection, not fabricated transcript rows.
        return .object(["goal": projection.raw["goal"], "subagents": .object(agents), "availability": projection.raw["availability"].object != nil ? projection.raw["availability"] : .object([:]), "rows": .object(["window": .array(projection.rows.filter { $0["kind"].string == "subagent" })]), "revision": .int(projection.revision), "logEpoch": .string(projection.logEpoch), "seq": .int(projection.sequence)])
    }
    static func interaction(_ pending: RelayPendingInteraction, sessionID: String) -> RelayJSON {
        let p = pending.payload
        if pending.kind == "workspaceHookReview", let review = try? pending.workspaceHookReview() {
            return .object(["id": .string(pending.id), "sessionId": .string(sessionID), "kind": .string(pending.kind), "title": .string("审查工作区钩子"), "reason": .string("所选钩子的信任会持久保存。"), "hookReview": review.wire])
        }
        return .object(["id": .string(pending.id), "sessionId": .string(sessionID), "kind": .string(pending.kind), "title": p["toolName"].string.map(RelayJSON.string) ?? .string("需要你的回答"), "reason": p["reason"].string.map(RelayJSON.string) ?? p["prompt"], "toolName": p["toolName"], "questions": p["questions"], "input": p["input"]])
    }
    static func history(_ projection: RelayConversationProjection) -> RelayJSON {
        let before = projection.rows.first?["rowId"].integer, first = projection.raw["rows"]["firstRowId"].integer
        return .object(["hasMore": .bool(before != nil && first != nil && before! > first!), "beforeRowId": before.map(RelayJSON.int) ?? .null,
            "firstRowId": first.map(RelayJSON.int) ?? .null, "logEpoch": .string(projection.logEpoch), "atSeq": .int(projection.sequence),
            "loadedRowCount": .int(projection.rows.count), "totalRowCount": projection.raw["rows"]["totalCount"].integer.map(RelayJSON.int) ?? .int(projection.rows.count)])
    }
    static func messages(_ projection: RelayConversationProjection, olderRows: [RelayJSON] = []) -> [RelayJSON] {
        var byRow: [Int: RelayJSON] = [:]
        for row in olderRows + projection.rows { if let id = row["rowId"].integer { byRow[id] = row } }
        let orderedRows = byRow.keys.sorted().compactMap { byRow[$0] }
        let semantics = RelayTranscriptSemantics.rows(orderedRows, sessionID: projection.sessionID)
        var messages: [[String: RelayJSON]] = [], groups: [String: Int] = [:]
        for row in orderedRows {
            guard let rowID = row["rowId"].integer, let kind = row["kind"].string else { continue }
            let turn = row["turnId"].string ?? "row-\(rowID)"
            if kind == "userInput" {
                let role = row["origin"].string == "realUser" ? "user" : "system"
                var message: [String: RelayJSON] = ["id": .string("relay:\(projection.sessionID):user:\(rowID)"), "role": .string(role), "text": row["text"], "createdAt": date(row["createdAt"].number), "isStreaming": .bool(false), "attachments": .array((row["attachments"].array ?? []).compactMap { attachment in
                    guard let ref = attachment["ref"].string else { return nil }
                    return .object(["id": .string(ref), "fileName": attachment["fileName"], "mimeType": attachment["mime"]])
                })]
                if let meaning = semantics[rowID] { message["transcript"] = meaning.wire }
                messages.append(message); continue
            }
            guard ["assistantText", "reasoning", "toolCall", "subagent"].contains(kind) else { continue }
            let identity = row["assistantResponseId"].string ?? "turn:\(turn)"
            let key = "relay:\(projection.sessionID):assistant:\(identity)"
            let index: Int
            if let existing = groups[key] { index = existing }
            else { index = messages.count; groups[key] = index; messages.append(["id": .string(key), "role": .string("assistant"), "text": .string(""), "reasoning": .string(""), "toolCalls": .array([]), "createdAt": date(row["createdAt"].number), "isStreaming": .bool(false)]) }
            if let meaning = semantics[rowID] {
                if let previous = messages[index]["transcript"], previous["turnId"].string != meaning.turnID {
                    // Preserve original response identity without inventing a turn for ambiguous legacy grouping.
                    messages[index]["transcript"] = .object(["turnId": .string(key), "state": .string("unknown"), "role": .string("unknown")])
                } else if messages[index]["transcript"]?["role"].string != "finalAnswer" || meaning.role == .finalAnswer { messages[index]["transcript"] = meaning.wire }
            }
            if kind == "assistantText" { messages[index]["text"] = .string((messages[index]["text"]?.string ?? "") + (row["text"].string ?? "")) }
            if let target = projection.forkTargets.first(where: { $0.rowId == rowID }) { messages[index]["forkTarget"] = target.wire }
            if kind == "reasoning" { messages[index]["reasoning"] = .string((messages[index]["reasoning"]?.string ?? "") + (row["text"].string ?? "")) }
            if kind == "toolCall" || kind == "subagent" {
                let toolStatus = row["status"].string ?? "unknown"
                let normalized = ["inputStreaming", "running", "pendingApproval"].contains(toolStatus) ? "running" : ["error", "failed", "cancelled"].contains(toolStatus) ? "failed" : toolStatus
                let tool: RelayJSON = .object(["id": row["toolCallId"].string.map(RelayJSON.string) ?? .string("row-\(rowID)"), "name": row["toolName"].string.map(RelayJSON.string) ?? row["subagentType"].string.map(RelayJSON.string) ?? .string("Agent"), "status": .string(normalized), "input": row["input"] == .null ? row["inputText"] : row["input"], "output": kind == "subagent" ? row["summaryText"] : row["output"]["text"]])
                messages[index]["toolCalls"] = .array((messages[index]["toolCalls"]?.array ?? []) + [tool])
            }
            let streaming = row["state"].string == "streaming" || ["inputStreaming", "running", "pendingApproval"].contains(row["status"].string ?? "")
            messages[index]["isStreaming"] = .bool(projection.canStop && (messages[index]["isStreaming"]?.bool == true || streaming))
        }
        return messages.map(RelayJSON.object)
    }
}

private extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }
