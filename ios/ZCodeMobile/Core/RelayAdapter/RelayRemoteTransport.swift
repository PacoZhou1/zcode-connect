import Foundation

/// One already-paired desktop workspace, projected into the app's existing transport contract.
/// The caller owns pairing and must shut this adapter down before changing the client's workspace.
actor RelayRemoteTransport: RemoteTransport {
    let client: RelayClient
    let bridge: RelayBridge
    let projectID: String
    let hostName: String
    private let deviceID: String
    private let version: String?
    private let journal: RelayAdapterJournal
    private var metadata: [String: RelayTaskMetadata] = [:]
    private var snapshots: [String: RelaySessionSnapshot] = [:]
    private struct SubagentHistory {
        let parentID: String
        let snapshot: RelaySessionSnapshot
        let epoch: String
        var loadedCount: Int
    }
    private var subagentParents: [String: String] = [:]
    private var subagentHistories: [String: SubagentHistory] = [:]
    private var sessionPages = RelaySessionPages()
    private var projections: [String: RelayConversationProjection] = [:]
    private var loads: [String: Task<RelayConversationProjection, any Error>] = [:]
    private var busy = Set<String>()
    private var pump: Task<Void, Never>?
    private var closed = false
    private let eventEpoch = UUID().uuidString
    private var eventSequence = 0
    private var replay: [BridgeEnvelope] = []
    private var sinks: [UUID: AsyncThrowingStream<BridgeEnvelope, any Error>.Continuation] = [:]

    init(client: RelayClient, bootstrap: RelayBootstrap, bridge: RelayBridge, hostName: String, journalDirectory: URL? = nil) async throws {
        guard await client.bridge == bridge, let deviceID = await client.pairedDeviceID,
              bootstrap.workspaces.contains(where: { $0.id == bridge.workspaceKey && $0.workspacePath == bridge.workspacePath }) else {
            throw RelayFailure("relay_workspace_mismatch", "The adapter needs the currently attached desktop workspace.")
        }
        self.client = client; self.bridge = bridge; self.deviceID = deviceID; self.hostName = hostName
        version = await client.connectedAppVersion
        projectID = "relay-" + String(relayDigest(Data((deviceID + "\n" + bridge.workspaceKey).utf8)).prefix(24))
        journal = try RelayAdapterJournal(scope: deviceID + "\n" + bridge.workspaceKey + "\n" + client.clientID, directory: journalDirectory)
        for task in bootstrap.tasks ?? [] where Self.belongs(task, to: bridge) { metadata[task.id] = task }
    }
    deinit { pump?.cancel(); for sink in sinks.values { sink.finish() } }

    /// Cancels this facade's event consumer. It does not disconnect or replace the caller's controller.
    func shutdown() async {
        closed = true; pump?.cancel(); pump = nil
        for task in loads.values { task.cancel() }; loads.removeAll()
        for sink in sinks.values { sink.finish() }; sinks.removeAll()
        if await client.bridge == bridge {
            for id in projections.keys { try? await client.unsubscribe(sessionID: id) }
        }
    }

    func get<T: Decodable & Sendable>(_ path: String, as: T.Type = T.self) async throws -> T {
        do {
            try await checkScope()
            return try await RelayWorkspaceOperation.$expectedBridge.withValue(bridge) { try await route(path, method: "GET", body: .object([:])).decode(T.self) }
        }
        catch { throw relayBridgeFailure(error) }
    }
    func mutate<T: Decodable & Sendable>(_ path: String, method: String = "POST", body: [String: JSONValue], as: T.Type = T.self) async throws -> T {
        do {
            try await checkScope()
            let request = try RelayJSON(data: JSONEncoder().encode(body))
            let parsed = try Self.parse(path)
            let lock = parsed.parts.count >= 3 && parsed.parts[1] == "sessions" ? "session:" + parsed.parts[2] : parsed.parts.joined(separator: "/")
            guard busy.insert(lock).inserted else { throw RelayFailure("input_pending", "A request for this task is still being reconciled.") }
            defer { busy.remove(lock) }
            return try await RelayWorkspaceOperation.$expectedBridge.withValue(bridge) { try await route(path, method: method.uppercased(), body: request).decode(T.self) }
        } catch { throw relayBridgeFailure(error) }
    }

    func events(after cursor: String?, onEvent: @Sendable (BridgeEnvelope) async -> Void) async throws {
        do {
            try await checkScope(); startPump()
            let id = UUID(), pair = AsyncThrowingStream<BridgeEnvelope, any Error>.makeStream(bufferingPolicy: .bufferingNewest(512))
            sinks[id] = pair.continuation
            defer { sinks.removeValue(forKey: id); pair.continuation.finish() }
            if let cursor, let index = replay.firstIndex(where: { $0.id == cursor }) {
                for item in replay.dropFirst(index + 1) { pair.continuation.yield(item) }
            } else if cursor != nil { pair.continuation.yield(try envelope(type: "resync.required")) }
            pair.continuation.yield(try envelope(type: "ready", data: ["connectionStatus": .string("connected")]))
            for try await event in pair.stream { try Task.checkCancellation(); await onEvent(event) }
        } catch { throw relayBridgeFailure(error) }
    }

    func hostProjection(sessionID: String) async throws -> RelayConversationProjection {
        try await checkScope()
        return try await RelayWorkspaceOperation.$expectedBridge.withValue(bridge) { try await loadProjection(sessionID) }
    }

    private func checkScope() async throws {
        guard !closed, await client.pairedDeviceID == deviceID, await client.bridge == bridge else {
            throw RelayFailure("relay_workspace_changed", "Reconnect this view to the selected desktop workspace.")
        }
    }
    private static func belongs(_ task: RelayTaskMetadata, to bridge: RelayBridge) -> Bool {
        if let identity = bridge.workspaceIdentity { return task.workspaceIdentity == identity }
        return task.workspacePath == bridge.workspacePath && task.workspaceIdentity == nil
    }
    private static func parse(_ path: String) throws -> (parts: [String], query: [String: String]) {
        guard !path.contains("://"), let url = URLComponents(string: "https://adapter.invalid/" + path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))), url.fragment == nil else { throw RelayFailure.invalid("Invalid adapter route.") }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.first == "v1", parts.allSatisfy({ $0 != "." && $0 != ".." && !$0.contains("\\") }) else { throw RelayFailure.invalid("Invalid adapter route.") }
        var query: [String: String] = [:]
        for item in url.queryItems ?? [] { guard query[item.name] == nil else { throw RelayFailure.invalid("Duplicate query parameter.") }; query[item.name] = item.value ?? "" }
        return (parts, query)
    }
    private func requireProject(_ id: String) throws { guard id == projectID else { throw RelayFailure("project_not_found", "This connection is attached to another project.") } }
    private func route(_ path: String, method: String, body: RelayJSON) async throws -> RelayJSON {
        let (p, q) = try Self.parse(path)
        if method != "GET" { try validateBody(body, path: p, method: method) }
        if method == "GET", p == ["v1", "status"] {
            return .object(["hostName": .string(hostName), "connectionStatus": .string("connected"), "zcodeVersion": version.map(RelayJSON.string) ?? .null,
                "limitations": .array([.string("Official relay codec and services were verified from source and mock transport; live account acceptance is pending."), .string("Goal removal is not offered by the verified desktop protocol.")])])
        }
        if method == "GET", p == ["v1", "projects"] {
            return .object(["projects": .array([.object(["id": .string(projectID), "name": .string(URL(fileURLWithPath: bridge.workspacePath).lastPathComponent), "path": .string(bridge.workspacePath)])])])
        }
        if method == "GET", p == ["v1", "models"] { return try await RelayBridgeMapping.models(client.listModels()) }
        if method == "GET", p == ["v1", "sessions"] {
            if let id = q["projectId"], !id.isEmpty { try requireProject(id) }
            guard let limit = Int(q["limit"] ?? "100"), (1...1000).contains(limit),
                  q["includeArchived"].map({ ["true", "false"].contains($0) }) ?? true,
                  (q["search"] ?? "").count <= 200 else { throw RelayFailure.invalid("Invalid task list filters or limit.") }
            let search = (q["search"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let filters: RelayJSON = .object(["projectId": q["projectId"].flatMap({ $0.isEmpty ? nil : $0 }).map(RelayJSON.string) ?? .null, "includeArchived": .bool(q["includeArchived"] == "true"), "search": .string(search)])
            if let cursor = q["cursor"] { return try sessionPages.page(filters: filters, limit: limit, cursor: cursor) }
            let tasks = try await taskList(includeArchived: q["includeArchived"] == "true")
            let records = tasks.map { sessionJSON($0.id) }.filter { search.isEmpty || (($0["title"].string ?? "") + "\n" + ($0["projectName"].string ?? "")).lowercased().contains(search) }
            return try sessionPages.page(records: records, filters: filters, limit: limit, cursor: nil)
        }
        if method == "POST", p == ["v1", "sessions"] { return try await create(body) }
        if p.count == 4, p[1] == "projects", method == "GET" {
            try requireProject(p[2])
            switch p[3] {
            case "settings":
                let state = try await client.readWorkspaceState()
                guard let mode = state.mode else { throw RelayFailure("settings_unavailable", "The desktop omitted its current collaboration mode.") }
                return .object(["projectId": .string(projectID), "model": try RelayBridgeMapping.modelSelection(settings: state.settings), "mode": .string(mode)])
            case "files":
                let result: RelayWorkspaceFiles
                if let query = q["search"], !query.isEmpty { result = try await client.searchFiles(query) }
                else { result = try await client.directory(relativePath: q["path"] ?? "") }
                return .object(["files": try RelayJSON(data: JSONEncoder().encode(result.files)), "truncated": .bool(result.truncated), "searchComplete": .bool(result.searchComplete)])
            case "file": return try await client.readFile(relativePath: q["path"] ?? "")
            default: break
            }
        }
        if p.count >= 3, p[1] == "sessions" {
            let id = p[2]; try await ensureTask(id)
            if subagentParents[id] != nil {
                guard method == "GET", p.count == 3 || (p.count == 4 && p[3] == "messages") else {
                    throw RelayFailure("session_read_only", "Subagent records are read-only; control remains with their parent task.")
                }
                return p.count == 3 ? try await subagentDetail(id) : try subagentMessages(id, query: q)
            }
            if p.count == 3 {
                if method == "GET" { return try await detail(id) }
                if method == "PATCH" { return try await metadataMutation(id, body) }
            }
            if p.count == 4 {
                switch (method, p[3]) {
                case ("GET", "settings"):
                    let snapshot = try await client.readSession(id); snapshots[id] = snapshot
                    return try RelayBridgeMapping.settings(snapshot, permissionMode: permissionMode(snapshot))
                case ("PATCH", "settings"): return try await settingsMutation(id, body)
                case ("GET", "messages"): return try await olderMessages(id, query: q)
                case ("POST", "messages"): return try await message(id, body)
                case ("POST", "attachments"): return try await attachment(id, body)
                case ("POST", "stop"): return try await stop(id)
                case ("POST", "fork"): return try await fork(id, body)
                case ("GET", "changes"): return try await changes(id)
                default: break
                }
            }
            if p.count == 6, p[3] == "hooks", p[4] == "review", method == "POST" {
                return try await hookReview(id, action: p[5], body: body)
            }
            if p.count == 5, p[3] == "goal", method == "POST" {
                guard ["pause", "resume"].contains(p[4]) else { throw RelayFailure("goal_remove_unsupported", "The desktop protocol has no goal removal command.") }
                _ = try await loadProjection(id)
                let type = p[4] == "pause" ? "pauseGoal" : "resumeGoal"
                _ = try await durableCommand(key: "goal-" + UUID().uuidString, intent: body, sessionID: id, type: type, payload: .object([:]))
                let projection = try await waitForProjection(id) { p[4] == "pause" ? $0.hostGoal?.status == "paused" : $0.hostGoal?.isActive == true }
                return .object(["accepted": .bool(true), "sessionId": .string(id), "hostActivity": RelayBridgeMapping.activity(projection)])
            }
        }
        if p.count == 4, p[1] == "interactions", p[3] == "respond", method == "POST" { return try await respond(p[2], body) }
        throw RelayFailure("relay_route_unsupported", "This operation is not supported by the verified official relay adapter.")
    }

    private func validateBody(_ body: RelayJSON, path: [String], method: String) throws {
        guard let fields = body.object else { throw RelayFailure.invalid("Use an object request body.") }
        let schemas: [String: [String: String]] = [
            "create": ["projectId": "string", "clientDraftId": "string", "title": "string", "mode": "string", "model": "object", "confirmFullAccess": "bool"],
            "messages": ["text": "string", "inputId": "string", "attachmentIds": "array"],
            "attachments": ["fileName": "string", "mimeType": "string", "base64": "string"],
            "settings": ["model": "object", "thoughtLevel": "string", "mode": "string", "permissionMode": "string", "confirmFullAccess": "bool"],
            "metadata": ["title": "string", "pinned": "bool", "archived": "bool", "unread": "bool", "expectedUnreadAt": "number"],
            "fork": ["clientForkId": "string", "target": "object"],
            "respond": ["decision": "string", "reason": "string", "action": "string", "content": "object"],
            "hook.respond": ["clientCommandId": "string", "request": "object", "reviewItemIds": "array", "confirmation": "object"],
            "hook.revoke": ["clientCommandId": "string", "request": "object", "reviewItemIds": "array", "confirmation": "object"],
            "hook.toggle": ["clientCommandId": "string", "request": "object", "reviewItemId": "string", "enabled": "bool", "confirmation": "object"],
            "hook.request": ["clientCommandId": "string", "workspaceIdentity": "string", "bundleDigest": "string", "remoteSessionId": "string"],
            "stop": [:], "pause": [:], "resume": [:]
        ]
        let hookRoute = path.count == 6 && path[3] == "hooks" && path[4] == "review"
        let route = hookRoute ? "hook." + (path.last ?? "") : path == ["v1", "sessions"] ? "create" : path.count == 3 && method == "PATCH" ? "metadata" : path.last ?? ""
        guard let schema = schemas[route] else { return }
        guard Set(fields.keys).isSubset(of: Set(schema.keys)) else { throw RelayFailure.invalid("An unsupported request field was provided.") }
        for (key, value) in fields {
            let valid: Bool
            switch schema[key] {
            case "string": valid = value.string != nil
            case "bool": valid = value.bool != nil
            case "array": valid = value.array != nil
            case "object": valid = value.object != nil
            case "number": valid = value.number != nil
            default: valid = false
            }
            guard valid else { throw RelayFailure.invalid("Invalid request field type: " + key) }
        }
        if let model = fields["model"]?.object, !Set(model.keys).isSubset(of: ["providerId", "modelId", "thoughtLevel"]) || model.values.contains(where: { $0.string == nil }) { throw RelayFailure.invalid("Use the model reference and reasoning level returned by the desktop.") }
    }

    private func taskList(includeArchived: Bool) async throws -> [RelayTaskMetadata] {
        async let normal = client.listTasks()
        async let pinned = client.listTasks(pinned: true)
        var tasks = try await normal + pinned
        if includeArchived {
            let archived = try await client.listTasks(archived: true)
            tasks += try archived.map { item in
                var json = try RelayJSON(data: JSONEncoder().encode(item)).requiringObject(); json["archived"] = .bool(true)
                return try RelayJSON.object(json).decode(RelayTaskMetadata.self)
            }
        }
        var unique: [String: RelayTaskMetadata] = [:]
        for task in tasks where Self.belongs(task, to: bridge) && subagentParents[task.id] == nil { unique[task.id] = task; metadata[task.id] = task }
        return unique.values.sorted { ($0.pinned == true) != ($1.pinned == true) ? $0.pinned == true : ($0.updatedAt ?? 0) > ($1.updatedAt ?? 0) }
    }
    private func ensureTask(_ id: String) async throws {
        guard RelayWire.validID(id) else { throw RelayFailure.invalid("Invalid session ID.") }
        // A parent projection, including ended rows, grants only child read access.
        // It must take precedence even if another desktop view indexed that child.
        let parents = projections.values.filter { projection in
            projection.sessionID != id && metadata[projection.sessionID].map { Self.belongs($0, to: bridge) && ($0.provider == nil || $0.provider == "glm") } == true && projection.referencedSubagentIDs.contains(id)
        }.map(\.sessionID)
        if parents.count == 1 {
            subagentParents[id] = parents[0]; metadata.removeValue(forKey: id); snapshots.removeValue(forKey: id); return
        }
        guard parents.isEmpty else { throw RelayFailure("relay_subagent_scope_mismatch", "Multiple parent activities claimed this subagent. Reload the original parent.") }
        if subagentParents[id] != nil { return }
        if metadata[id] == nil && snapshots[id] == nil { _ = try await taskList(includeArchived: true) }
        guard metadata[id] != nil || snapshots[id] != nil else { throw RelayFailure("session_not_found", "This task is not in the selected desktop workspace.") }
        if let provider = metadata[id]?.provider, provider != "glm" { throw RelayFailure("relay_provider_unsupported", "The verified native session service supports the ZCode engine only.") }
    }
    private func ensureWritable(_ id: String) throws {
        guard subagentParents[id] == nil else { throw RelayFailure("session_read_only", "Subagent records are read-only.") }
        guard metadata[id]?.archived != true else { throw RelayFailure("session_archived", "Restore the task before changing it.") }
    }
    private func sessionJSON(_ id: String) -> RelayJSON {
        if let child = subagentHistories[id] { return RelayBridgeMapping.subagentSession(child.snapshot, parentID: child.parentID, bridge: bridge, projectID: projectID) }
        return RelayBridgeMapping.session(id: id, meta: metadata[id], snapshot: snapshots[id], projection: projections[id], bridge: bridge, projectID: projectID)
    }
    private func loadProjection(_ id: String) async throws -> RelayConversationProjection {
        guard subagentParents[id] == nil else { throw RelayFailure("session_read_only", "Subagent history must not create or resume a conversation subscription.") }
        startPump()
        if let loading = loads[id] { return try await loading.value }
        guard projections.count + loads.count < 32 || projections[id] != nil else { throw RelayFailure("relay_subscription_limit", "Close and reopen this workspace to inspect more tasks.") }
        let client = client
        let task = Task<RelayConversationProjection, any Error> {
            _ = try await client.subscribe(sessionID: id)
            let deadline = ContinuousClock.now + .seconds(12)
            while ContinuousClock.now < deadline {
                try Task.checkCancellation()
                if let projection = await client.currentProjection(sessionID: id) { return projection }
                try await Task.sleep(for: .milliseconds(40))
            }
            throw RelayFailure("projection_timeout", "The desktop has not sent the task's current state.")
        }
        loads[id] = task; defer { loads.removeValue(forKey: id) }
        let projection = try await task.value; try await checkScope(); projections[id] = projection; return projection
    }
    private func detail(_ id: String) async throws -> RelayJSON {
        async let snapshotRead = client.readSession(id)
        let projection = try await loadProjection(id), snapshot = try await snapshotRead
        snapshots[id] = snapshot
        return .object(["session": sessionJSON(id), "messages": .array(RelayBridgeMapping.messages(projection)), "pendingInteractions": .array(projection.pendingInteractions.map { RelayBridgeMapping.interaction($0, sessionID: id) }), "hostActivity": RelayBridgeMapping.activity(projection), "history": RelayBridgeMapping.history(projection)])
    }
    private func subagentDetail(_ id: String) async throws -> RelayJSON {
        guard let parentID = subagentParents[id] else { throw RelayFailure("session_not_found", "Open the original parent's subagent activity first.") }
        guard subagentHistories[id] != nil || subagentHistories.count < 32 else { throw RelayFailure("relay_history_limit", "Reopen this workspace before reading more subagent histories.") }
        let snapshot = try await client.readSubagentSession(id, parentSessionID: parentID)
        try await checkScope()
        let epoch = "relay-subagent-" + relayDigest(try RelayJSON.object(["sessionId": .string(id), "messages": .array(snapshot.messages)]).data())
        let loaded = subagentHistories[id].flatMap { $0.epoch == epoch ? $0.loadedCount : nil } ?? min(500, snapshot.messages.count)
        let history = SubagentHistory(parentID: parentID, snapshot: snapshot, epoch: epoch, loadedCount: loaded)
        subagentHistories[id] = history
        return .object(["session": sessionJSON(id), "messages": .array(RelayBridgeMapping.snapshotMessages(Array(snapshot.messages.suffix(loaded)))),
                        "pendingInteractions": .array([]), "history": subagentHistoryJSON(history),
                        "hostActivity": .object(["supported": .bool(false), "reasonCode": .string("subagentReadOnly"), "goal": .null,
                                                 "subagents": .object(["revision": .int(0), "childSessionIds": .array([]), "running": .array([]), "endedTotal": .int(0)]), "availability": .object([:]), "rows": .object(["window": .array([])])])])
    }
    private func subagentHistoryJSON(_ value: SubagentHistory) -> RelayJSON {
        let total = value.snapshot.messages.count, before = total > 0 ? total - value.loadedCount : nil
        return .object(["hasMore": .bool(value.loadedCount < total), "beforeRowId": before.map(RelayJSON.int) ?? .null,
                        "firstRowId": total > 0 ? .int(0) : .null, "logEpoch": .string(value.epoch),
                        "atSeq": value.snapshot.raw["runtime"]["eventSeq"].integer.map(RelayJSON.int) ?? .int(0),
                        "loadedRowCount": .int(value.loadedCount), "totalRowCount": .int(total)])
    }
    private func subagentMessages(_ id: String, query: [String: String]) throws -> RelayJSON {
        guard query.keys.allSatisfy({ ["beforeRowId", "logEpoch", "limit"].contains($0) }),
              let before = query["beforeRowId"].flatMap(Int.init), let epoch = query["logEpoch"],
              let limit = Int(query["limit"] ?? "200"), (1...200).contains(limit) else { throw RelayFailure.invalid("Use the current subagent history cursor and a limit from 1 to 200.") }
        guard var value = subagentHistories[id], value.epoch == epoch, before == value.snapshot.messages.count - value.loadedCount else {
            throw RelayFailure("relay_history_changed", "Reload the subagent history before requesting an older page.")
        }
        value.loadedCount = min(value.snapshot.messages.count, value.loadedCount + limit); subagentHistories[id] = value
        return .object(["messages": .array(RelayBridgeMapping.snapshotMessages(Array(value.snapshot.messages.suffix(value.loadedCount)))), "history": subagentHistoryJSON(value)])
    }
    private func olderMessages(_ id: String, query: [String: String]) async throws -> RelayJSON {
        guard query.keys.allSatisfy({ ["beforeRowId", "logEpoch", "limit"].contains($0) }),
              let before = query["beforeRowId"].flatMap(Int.init), before >= 0,
              let epoch = query["logEpoch"], !epoch.isEmpty, epoch.utf8.count <= 1024,
              let limit = Int(query["limit"] ?? "200"), (1...200).contains(limit) else {
            throw RelayFailure.invalid("History needs beforeRowId, logEpoch and a limit from 1 to 200.")
        }
        _ = try await loadProjection(id)
        let projection = try await client.loadOlderRows(sessionID: id, beforeRowID: before, logEpoch: epoch, limit: limit)
        try await checkScope(); projections[id] = projection
        return .object(["messages": .array(RelayBridgeMapping.messages(projection)), "history": RelayBridgeMapping.history(projection)])
    }
    private func waitForProjection(_ id: String, predicate: @Sendable (RelayConversationProjection) -> Bool) async throws -> RelayConversationProjection {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            try Task.checkCancellation(); try await checkScope()
            if let value = await client.currentProjection(sessionID: id), predicate(value) { projections[id] = value; return value }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw RelayFailure("host_change_not_confirmed", "The command was acknowledged, but its resulting state is not yet confirmed.", outcomeUncertain: true)
    }

    private func durableCommand(key: String, intent: RelayJSON, sessionID: String?, type: String, payload: RelayJSON, context: RelayJSON? = nil, confirmFullAccess: Bool = false, hookReviewAuthorization: RelayHookReviewAuthorization? = nil) async throws -> RelayCommandAck {
        let hash = relayDigest(try intent.data())
        if let saved = journal.state.commands[key] {
            guard saved.intentHash == hash, saved.envelope.sessionId == sessionID, saved.envelope.type == type else { throw RelayFailure(type == "createSession" ? "draft_conflict" : type == "forkAssistant" ? "fork_conflict" : type.contains("WorkspaceHook") ? "hook_review_conflict" : "input_conflict", "This request ID was already used with different content.") }
        } else {
            let envelope: RelayCommandEnvelope
            if type == "createSession" { envelope = try await client.makeCreateSessionCommand(commandID: key) }
            else if type == "forkAssistant" { envelope = try await client.makeForkCommand(sessionID: sessionID!, target: payload["target"] == .null ? nil : RelayRowTarget(wire: payload["target"]), commandID: key) }
            else if let hookReviewAuthorization { envelope = try await client.makeHookReviewCommand(authorization: hookReviewAuthorization, commandID: key) }
            else if type == "requestWorkspaceHookReview" {
                envelope = try await client.makeRequestHookReviewCommand(sessionID: sessionID!, workspaceIdentity: payload.requiringString("workspaceIdentity"), bundleDigest: payload.requiringString("bundleDigest"), remoteSessionID: payload["remoteSessionId"].string, commandID: key)
            }
            else { envelope = await client.makeCommand(sessionID: sessionID!, type: type, payload: payload, commandID: key) }
            try journal.commit { $0.commands[key] = .init(intentHash: hash, envelope: envelope, context: context) }
        }
        var record = journal.state.commands[key]!
        if let ack = record.acknowledgement { return try admitted(ack, type: type) }
        if record.attempted {
            let query = try await client.queryCommands([.init(sessionId: record.envelope.sessionId, commandId: record.envelope.commandId)])
            guard let result = query["results"].array?.first(where: { $0["key"]["commandId"].string == record.envelope.commandId && $0["key"]["sessionId"].string == record.envelope.sessionId })?["result"] else { throw RelayFailure.invalid("The desktop omitted the command reconciliation result.") }
            if result.object != nil {
                let ack = try result.decode(RelayCommandAck.self)
                guard ack.commandId == key else { throw RelayFailure.invalid("The desktop reconciled another command.") }
                try journal.commit { $0.commands[key]?.acknowledgement = ack }; return try admitted(ack, type: type)
            }
            guard result == .string("unknown") else { throw RelayFailure.invalid("Unknown command reconciliation shape.") }
        }
        // Persist before submitting. Retries retain the original issuedAt, base revision, epoch and attachment refs.
        try journal.commit { $0.commands[key]?.attempted = true }; record = journal.state.commands[key]!
        let ack = try await client.submit(record.envelope, explicitUserAction: true, confirmFullAccess: confirmFullAccess, hookReviewAuthorization: hookReviewAuthorization)
        try journal.commit { $0.commands[key]?.acknowledgement = ack }; return try admitted(ack, type: type)
    }
    private func admitted(_ ack: RelayCommandAck, type: String) throws -> RelayCommandAck {
        guard ack.admitted else {
            if type == "forkAssistant" {
                let description = [ack.reasonCode, ack.message].compactMap { $0 }.joined(separator: ": ")
                throw RelayFailure("fork_rejected", description.isEmpty ? "The desktop declined this fork." : description)
            }
            throw RelayFailure(ack.reasonCode ?? "command_rejected", ack.message ?? "The desktop declined this command.")
        }; return ack
    }
    private func message(_ id: String, _ body: RelayJSON) async throws -> RelayJSON {
        try ensureWritable(id); _ = try await loadProjection(id)
        let inputID = body["inputId"].string ?? UUID().uuidString
        guard RelayWire.validID(inputID), let text = body["text"].string else { throw RelayFailure.invalid("Message text and a valid input ID are required.") }
        let ids = body["attachmentIds"].array ?? []
        guard ids.count <= 6, ids.allSatisfy({ $0.string != nil }) else { throw RelayFailure.invalid("Invalid attachment IDs.") }
        let attachments = try ids.map { value -> RelayAttachment in
            guard let item = journal.state.attachments[value.string!], item.sessionID == id else { throw RelayFailure("attachment_not_found", "The saved attachment is unavailable for this task.") }; return item
        }
        var payload: [String: RelayJSON] = ["text": .string(text), "requestedDelivery": .string("startNow")]
        if !attachments.isEmpty { payload["attachments"] = .array(attachments.map(\.wire)) }
        let intent: RelayJSON = .object(["sessionId": .string(id), "text": .string(text), "attachmentIds": .array(ids)])
        let duplicate = journal.state.commands[inputID]?.acknowledgement?.admitted == true
        _ = try await durableCommand(key: inputID, intent: intent, sessionID: id, type: "sendText", payload: .object(payload))
        return .object(["accepted": .bool(true), "sessionId": .string(id), "inputId": .string(inputID), "duplicate": .bool(duplicate)])
    }
    private func attachment(_ id: String, _ body: RelayJSON) async throws -> RelayJSON {
        try ensureWritable(id)
        let name = try body.requiringString("fileName"), mime = try body.requiringString("mimeType"), text = try body.requiringString("base64")
        guard text.utf8.count <= 12 * 1024 * 1024 else { throw RelayFailure("attachment_too_large", "This attachment exceeds the upload limit.") }
        let data = try RelayWire.base64(text)
        let hash = relayDigest(try RelayJSON.object(["sessionId": .string(id), "fileName": .string(name), "mime": .string(mime), "sha256": .string(relayDigest(data))]).data())
        let stableID = "relay-attachment-" + hash
        if journal.state.attachments[stableID] == nil {
            let uploaded = try await client.uploadAttachment(sessionID: id, fileName: name, mime: mime, data: data, uploadID: "upload-" + UUID().uuidString, explicitUserAction: true)
            try journal.commit { $0.attachments[stableID] = uploaded }
        }
        let value = journal.state.attachments[stableID]!
        return .object(["attachment": .object(["id": .string(stableID), "sessionId": .string(id), "fileName": .string(value.fileName), "mimeType": .string(value.mime), "bytes": .int(value.bytes)])])
    }
    private func stop(_ id: String) async throws -> RelayJSON {
        try ensureWritable(id); let projection = try await loadProjection(id)
        if projection.canStop {
            let active = projection.raw["control"]["activeWorks"].array?.first?["foregroundExecutionId"].string
            let payload: RelayJSON = .object(active.map { ["expectedForegroundExecutionId": .string($0)] } ?? [:])
            _ = try await durableCommand(key: "stop-" + UUID().uuidString, intent: payload, sessionID: id, type: "stop", payload: payload)
            _ = try await waitForProjection(id) { !$0.canStop && $0.pendingInteractions.isEmpty }
        }
        let snapshot = try await client.readSession(id); snapshots[id] = snapshot
        guard snapshot.activeTurnID == nil, !["running", "waiting"].contains(snapshot.status) else { throw RelayFailure("stop_not_confirmed", "The desktop has not confirmed that the active turn ended.", outcomeUncertain: true) }
        return .object(["stopped": .bool(true), "sessionId": .string(id), "verified": .bool(true)])
    }
    private func fork(_ id: String, _ body: RelayJSON) async throws -> RelayJSON {
        let clientID = try body.requiringString("clientForkId")
        guard clientID.utf8.count <= 128 else { throw RelayFailure.invalid("clientForkId must contain at most 128 bytes.") }
        let target = body["target"] == .null ? nil : try RelayRowTarget(wire: body["target"])
        let key = "fork-" + relayDigest(Data(clientID.utf8))
        if journal.state.commands[key] == nil { try ensureWritable(id); _ = try await loadProjection(id) }
        let ack = try await durableCommand(key: key, intent: body, sessionID: id, type: "forkAssistant", payload: .object(target.map { ["target": $0.wire] } ?? [:]))
        guard ack.result?["type"].string == "forkAssistant", let child = ack.result?["sessionId"].string, child != id, RelayWire.validID(child) else { throw RelayFailure("fork_uncertain", "The host acknowledged the command without confirming a forked task ID.", outcomeUncertain: true) }
        _ = try await taskList(includeArchived: true)
        if metadata[child] == nil {
            snapshots[child] = try await client.registerForkedTask(ack, parentSessionID: id, explicitUserAction: true)
            _ = try await taskList(includeArchived: true)
        }
        guard metadata[child] != nil else { throw RelayFailure("fork_uncertain", "The fork exists, but the host has not confirmed its task-list entry. Retry the original fork request.", outcomeUncertain: true) }
        snapshots[child] = try await client.readSession(child)
        let session = sessionJSON(child)
        try emit(type: "session.created", sessionID: child, data: ["session": session])
        return .object(["session": session, "parentSessionId": .string(id), "forkedSessionId": .string(child)])
    }
    private func hookReview(_ id: String, action: String, body: RelayJSON) async throws -> RelayJSON {
        guard ["request", "respond", "toggle", "revoke"].contains(action), let requestID = body["clientCommandId"].string, RelayWire.validID(requestID) else { throw RelayFailure("hook_review_invalid", "Use a stable command ID and a dedicated hook review action.") }
        let type: String, payload: RelayJSON, authorization: RelayHookReviewAuthorization?, intent: RelayJSON
        if action == "request" {
            type = "requestWorkspaceHookReview"; authorization = nil
            var fields: [String: RelayJSON] = ["sessionId": .string(id), "workspaceIdentity": .string(try body.requiringString("workspaceIdentity")), "bundleDigest": .string(try body.requiringString("bundleDigest"))]
            if let remote = body["remoteSessionId"].string { fields["remoteSessionId"] = .string(remote) }
            payload = .object(fields); intent = .object(["type": .string(type), "payload": payload])
        } else {
            let request = try RelayHookReviewRequest(wire: body["request"])
            guard request.sessionId == id else { throw RelayFailure("workspace_hooks_snapshot_mismatch", "The review belongs to another task.") }
            let operation: RelayHookReviewOperation
            if action == "toggle" {
                guard let enabled = body["enabled"].bool else { throw RelayFailure("hook_review_invalid", "A configuration toggle needs an explicit enabled value.") }
                operation = .setEnabled(itemID: try body.requiringString("reviewItemId"), enabled: enabled)
            } else {
                guard let values = body["reviewItemIds"].array, values.count <= 1000, values.allSatisfy({ $0.string != nil }) else { throw RelayFailure("hook_review_selection_invalid", "Use exact selected hook item IDs.") }
                let ids = values.compactMap(\.string)
                operation = action == "respond" ? .trustSelected(itemIDs: ids) : .revokeSelected(itemIDs: ids)
            }
            let confirmation = try body["confirmation"].decode(RelayHookReviewConfirmation.self)
            authorization = try .init(request: request, operation: operation, confirmation: confirmation)
            type = operation.commandType; payload = try operation.payload(target: request.target)
            intent = .object(["request": request.wire, "operation": operation.canonical])
        }
        let fingerprint = relayDigest(try intent.data())
        // A new explicit UI action after relaunch must recover an unresolved identical operation,
        // not allocate another command. Scope is already bound by this journal's desktop/workspace/client.
        let prior = journal.state.commands.filter { $0.value.envelope.sessionId == id && $0.value.envelope.type == type && $0.value.intentHash == fingerprint && ($0.value.acknowledgement == nil || (action != "request" && $0.value.acknowledgement?.admitted == true)) }.sorted {
            if ($0.value.acknowledgement == nil) != ($1.value.acknowledgement == nil) { return $0.value.acknowledgement == nil }
            return $0.value.envelope.issuedAt < $1.value.envelope.issuedAt
        }.first
        let key = prior?.key ?? "hook-" + requestID
        if journal.state.commands[key] == nil { try ensureWritable(id); _ = try await loadProjection(id) }
        let ack = try await durableCommand(key: key, intent: intent, sessionID: id, type: type, payload: payload,
                                          context: .object(["hookReviewRequest": body["request"]]), hookReviewAuthorization: authorization)
        return .object(["accepted": .bool(true), "sessionId": .string(id), "acknowledgement": try RelayJSON(data: JSONEncoder().encode(ack))])
    }
    private func respond(_ interactionID: String, _ body: RelayJSON) async throws -> RelayJSON {
        if let (key, saved) = journal.state.commands.first(where: { $0.value.envelope.type == "resolveInteraction" && $0.value.envelope.payload["interactionId"].string == interactionID }) {
            guard saved.context?["request"] == body else { throw RelayFailure("input_conflict", "This interaction was already answered differently.") }
            let intent: RelayJSON = .object(["sessionId": saved.envelope.sessionId.map(RelayJSON.string) ?? .null, "interactionId": .string(interactionID), "answer": saved.envelope.payload["answer"]])
            _ = try await durableCommand(key: key, intent: intent, sessionID: saved.envelope.sessionId, type: "resolveInteraction", payload: saved.envelope.payload)
            return .object(["accepted": .bool(true)])
        }
        let matches = projections.values.filter { $0.pendingInteractions.contains(where: { $0.id == interactionID }) }
        guard matches.count == 1, let previous = matches.first else { throw RelayFailure("interaction_not_pending", "Refresh the task before responding to this question.") }
        let id = previous.sessionID; try ensureWritable(id)
        let projection = try await loadProjection(id)
        guard let pending = projection.pendingInteractions.first(where: { $0.id == interactionID }) else { throw RelayFailure("interaction_not_pending", "This question is no longer pending.") }
        let answer: RelayJSON
        if pending.kind == "permission" {
            guard let decision = body["decision"].string, ["allow", "deny"].contains(decision),
                  let option = pending.oneTimeOptions.first(where: { $0["kind"].string == (decision == "allow" ? "allowOnce" : "deny") })?["optionId"].string else { throw RelayFailure("permission_option_unavailable", "The desktop does not offer this one-time permission choice.") }
            answer = .object(["optionId": .string(option)])
        } else {
            guard let action = body["action"].string, ["accept", "decline", "cancel"].contains(action) else { throw RelayFailure.invalid("Choose an explicit answer action.") }
            var fields: [String: RelayJSON] = ["action": .string(action)]
            if body["content"] != .null { fields["content"] = body["content"] }; answer = .object(fields)
        }
        let intent: RelayJSON = .object(["sessionId": .string(id), "interactionId": .string(interactionID), "answer": answer])
        let key = "reply-" + relayDigest(Data((id + "\n" + interactionID).utf8))
        _ = try await durableCommand(key: key, intent: intent, sessionID: id, type: "resolveInteraction", payload: .object(["interactionId": .string(interactionID), "answer": answer]), context: .object(["request": body]))
        return .object(["accepted": .bool(true)])
    }

    private func create(_ body: RelayJSON) async throws -> RelayJSON {
        try requireProject(try body.requiringString("projectId"))
        let draftID = body["clientDraftId"].string ?? UUID().uuidString
        guard RelayWire.validID(draftID) else { throw RelayFailure.invalid("Invalid draft ID.") }
        let key = "create-" + relayDigest(Data(draftID.utf8)), hash = relayDigest(try body.data())
        if let saved = journal.state.commands[key], saved.intentHash != hash { throw RelayFailure("draft_conflict", "This draft ID was already used with different settings.") }
        if let completed = journal.state.commands[key]?.context?["completedSession"], completed.object != nil { return .object(["session": completed]) }
        var config: RelayJSON
        if let saved = journal.state.commands[key]?.context { config = saved }
        else {
            let inherited = try await client.readWorkspaceState()
            let selection = body["model"].object != nil ? body["model"] : try RelayBridgeMapping.modelSelection(settings: inherited.settings)
            let mode = body["mode"].string ?? inherited.mode
            guard let mode, ["build", "edit", "plan", "yolo"].contains(mode) else { throw RelayFailure("mode_unsupported", "The desktop collaboration mode is unavailable.") }
            let model: RelayJSON = .object(["providerId": .string(try selection.requiringString("providerId")), "modelId": .string(try selection.requiringString("modelId"))])
            guard inherited.models.contains(where: { $0["ref"] == model && $0["disabledReason"].string == nil }) else { throw RelayFailure("model_unavailable", "The chosen desktop model is unavailable.") }
            config = .object(["model": model, "thoughtLevel": selection["thoughtLevel"], "mode": .string(mode), "title": body["title"]])
        }
        let full = body["confirmFullAccess"].bool == true
        if config["mode"].string == "yolo", !full { throw RelayFailure("full_access_confirmation_required", "Confirm full access before creating this task.") }
        if let title = config["title"].string, title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || title.count > 200 { throw RelayFailure.invalid("Use a title of 1–200 characters.") }
        let ack = try await durableCommand(key: key, intent: body, sessionID: nil, type: "createSession", payload: .object([:]), context: config, confirmFullAccess: full)
        guard ack.result?["type"].string == "createSession", let id = ack.result?["sessionId"].string, RelayWire.validID(id) else { throw RelayFailure("draft_uncertain", "The desktop has not returned the created task ID. Preserve this draft ID.", outcomeUncertain: true) }
        // The ACK/session ID is already on disk. A setter failure retries this same empty task.
        let snapshot = try await client.setSessionConfiguration(sessionID: id, model: config["model"], thoughtLevel: config["thoughtLevel"].string, mode: config["mode"].string, explicitUserAction: true, confirmFullAccess: full, registerCreatedTask: true)
        snapshots[id] = snapshot
        var registered: RelayTaskMetadata?
        for attempt in 0..<5 {
            registered = try await client.listTasks().first(where: { $0.id == id && Self.belongs($0, to: bridge) })
            if registered != nil { break }
            if attempt < 4 { try await Task.sleep(for: .milliseconds(150)) }
        }
        guard let registered else { throw RelayFailure("relay_task_registration_unconfirmed", "The session ID is saved, but the desktop has not confirmed it in its task index. Retry this same draft.", outcomeUncertain: true) }
        metadata[id] = registered
        if let title = config["title"].string, title != snapshot.title { metadata[id] = try await client.renameTask(sessionID: id, title: title, explicitUserAction: true) }
        if let mode = snapshot.mode, mode != "plan" { try journal.commit { $0.permissionModes[id] = mode } }
        _ = try await loadProjection(id)
        let completed = sessionJSON(id)
        try journal.commit { state in
            if var context = state.commands[key]?.context?.object { context["completedSession"] = completed; state.commands[key]?.context = .object(context) }
        }
        try emit(type: "session.created", sessionID: id, data: ["session": sessionJSON(id)])
        return .object(["session": sessionJSON(id)])
    }
    private func permissionMode(_ snapshot: RelaySessionSnapshot) -> String? {
        snapshot.mode == "plan" ? journal.state.permissionModes[snapshot.sessionID] : snapshot.mode
    }
    private func settingsMutation(_ id: String, _ body: RelayJSON) async throws -> RelayJSON {
        try ensureWritable(id)
        let current = try await client.readSession(id)
        let permission = body["permissionMode"].string, requestedMode = body["mode"].string, full = body["confirmFullAccess"].bool == true
        if let permission, !["build", "edit", "yolo"].contains(permission) { throw RelayFailure("mode_unsupported", "Choose an explicit permission mode.") }
        if permission == "yolo" || requestedMode == "yolo", !full { throw RelayFailure("full_access_confirmation_required", "Confirm full access for this change.") }
        if let requestedMode, let permission, requestedMode != "plan", requestedMode != permission { throw RelayFailure.invalid("The requested permission and collaboration modes conflict.") }
        let mode = requestedMode ?? (current.mode == "plan" ? nil : permission)
        let selection = body["model"]
        let model: RelayJSON? = selection.object == nil ? nil : .object(["providerId": .string(try selection.requiringString("providerId")), "modelId": .string(try selection.requiringString("modelId"))])
        let snapshot = try await client.setSessionConfiguration(sessionID: id, model: model, thoughtLevel: body["thoughtLevel"].string ?? selection["thoughtLevel"].string, mode: mode, explicitUserAction: true, confirmFullAccess: full)
        snapshots[id] = snapshot
        let storedPermission = permission ?? (snapshot.mode == "plan" ? (current.mode == "plan" ? journal.state.permissionModes[id] : current.mode) : snapshot.mode)
        if let storedPermission { try journal.commit { $0.permissionModes[id] = storedPermission } }
        var json = try RelayBridgeMapping.settings(snapshot, permissionMode: permissionMode(snapshot)).requiringObject(); json["session"] = sessionJSON(id)
        try emit(type: "session.updated", sessionID: id, data: ["session": sessionJSON(id)])
        return .object(json)
    }
    private func metadataMutation(_ id: String, _ body: RelayJSON) async throws -> RelayJSON {
        guard let fields = body.object, !fields.isEmpty, Set(fields.keys).isSubset(of: ["title", "pinned", "archived", "unread", "expectedUnreadAt"]) else { throw RelayFailure.invalid("Only title, pin, archive and unread fields are supported.") }
        if body["unread"].bool == false {
            guard let stamp = body["expectedUnreadAt"].number, stamp.isFinite, stamp >= 0, stamp <= 9_007_199_254_740_991, stamp.rounded() == stamp else { throw RelayFailure.invalid("Clearing unread requires its original timestamp in milliseconds.") }
        } else if fields["expectedUnreadAt"] != nil { throw RelayFailure.invalid("An expected unread timestamp is only used when clearing unread.") }
        if body["archived"].bool == true {
            let snapshot = try await client.readSession(id)
            guard snapshot.activeTurnID == nil, !["running", "waiting"].contains(snapshot.status) else { throw RelayFailure("session_busy", "Stop the running task before archiving it.") }
        }
        if let title = body["title"].string { metadata[id] = try await client.renameTask(sessionID: id, title: title, explicitUserAction: true) }
        if let pin = body["pinned"].bool { metadata[id] = try await client.pinTask(sessionID: id, pinned: pin, explicitUserAction: true) }
        if let archive = body["archived"].bool { metadata[id] = try await client.archiveTask(sessionID: id, archived: archive, explicitUserAction: true) }
        if let unread = body["unread"].bool { metadata[id] = try await client.setTaskUnread(sessionID: id, unread: unread, expectedUnreadAt: body["expectedUnreadAt"].number, explicitUserAction: true) }
        try emit(type: "session.updated", sessionID: id, data: ["session": sessionJSON(id)])
        var result: [String: RelayJSON] = ["session": sessionJSON(id), "metadataScope": .string("desktop")]
        if let unread = body["unread"].bool { result["unreadApplied"] = .bool(unread == (metadata[id]?.unreadAt != nil)) }
        return .object(result)
    }
    private func changes(_ id: String) async throws -> RelayJSON {
        _ = id // This route deliberately reports workspace Git changes, not guessed per-task ownership.
        let source = "unstaged", raw = try await client.workspaceChanges(source: source)
        guard let entries = raw.array else { throw RelayFailure.invalid("Unexpected desktop Git changes response.") }
        var files: [RelayJSON] = [], truncated = entries.count > 100, bytes = 0
        for item in entries.prefix(100) {
            guard let path = item["path"].string, (try? RelayWorkspacePath.validate(path)) != nil else { truncated = true; continue }
            let diff = try await client.workspaceDiff(path: path, source: source)
            guard diff["availability"].string == "patch", let patch = diff["patch"].string else { throw RelayFailure("diff_unavailable", "The desktop cannot provide this file's patch.") }
            if bytes + patch.utf8.count > 1024 * 1024 { truncated = true; break }; bytes += patch.utf8.count
            files.append(.object(["path": .string(path), "additions": item["added"].integer.map(RelayJSON.int) ?? .int(0), "deletions": item["removed"].integer.map(RelayJSON.int) ?? .int(0), "diff": .string(patch), "truncated": .bool(false)]))
        }
        return .object(["files": .array(files), "source": .string("workspace-git-unstaged"), "truncated": .bool(truncated)])
    }

    private func startPump() {
        guard pump == nil, !closed else { return }
        let client = client
        pump = Task { [weak self] in
            let stream = await client.observeEvents()
            for await event in stream {
                if Task.isCancelled { return }
                await self?.consume(event)
            }
        }
    }
    private func consume(_ event: RelayEvent) async {
        guard !closed else { return }
        do {
            switch event {
            case .projection(let projection):
                guard await client.bridge == bridge else { return }
                let previous = projections[projection.sessionID]; projections[projection.sessionID] = projection
                let oldMessages = previous.map { RelayBridgeMapping.messages($0) } ?? [], newMessages = RelayBridgeMapping.messages(projection)
                let oldIDs = Set(oldMessages.compactMap { $0["id"].string }), newIDs = Set(newMessages.compactMap { $0["id"].string })
                if previous?.logEpoch != nil && (previous?.logEpoch != projection.logEpoch || !oldIDs.isSubset(of: newIDs)) { try emit(type: "resync.required", sessionID: projection.sessionID) }
                let oldByID = Dictionary(uniqueKeysWithValues: oldMessages.compactMap { message in message["id"].string.map { ($0, message) } })
                for message in newMessages where oldByID[message["id"].string ?? ""] != message { try emit(type: "message.updated", sessionID: projection.sessionID, data: ["message": message]) }
                let activity = RelayBridgeMapping.activity(projection)
                // Sequence/revision change on every token; only substantive activity changes trigger a detail refresh.
                let oldActivity = previous.map(RelayBridgeMapping.activity)
                if oldActivity?["goal"] != activity["goal"] || oldActivity?["subagents"] != activity["subagents"] || oldActivity?["availability"] != activity["availability"] || oldActivity?["rows"] != activity["rows"] {
                    try emit(type: "host.activity", sessionID: projection.sessionID, data: ["hostActivity": activity])
                }
                let previousPending = previous?.pendingInteractions ?? [], pending = projection.pendingInteractions
                for item in pending where !previousPending.contains(item) { try emit(type: "interaction.requested", sessionID: projection.sessionID, data: ["interaction": RelayBridgeMapping.interaction(item, sessionID: projection.sessionID)]) }
                for item in previousPending where !pending.contains(where: { $0.id == item.id }) { try emit(type: "interaction.resolved", sessionID: projection.sessionID, data: ["interactionId": .string(item.id)]) }
                if previous?.phase != projection.phase || previous?.title != projection.title || previous?.config != projection.config { try emit(type: "session.updated", sessionID: projection.sessionID, data: ["session": sessionJSON(projection.sessionID)]) }
            case .resyncRequired(let id, _): try emit(type: "resync.required", sessionID: id)
            case .state(let state):
                if state == .disconnected || state == .replaced {
                    try emit(type: "connection.changed", data: ["connectionStatus": .string("disconnected")])
                    for sink in sinks.values { sink.finish(throwing: RelayFailure("relay_disconnected", "The desktop relay disconnected. Reconnect explicitly.")) }; sinks.removeAll()
                }
            case .failure(let failure):
                if failure.code == "relay_event_overflow" { try emit(type: "resync.required") }
            default: break
            }
        } catch {
            for sink in sinks.values { sink.finish(throwing: relayBridgeFailure(error)) }; sinks.removeAll()
        }
    }
    private func envelope(type: String, sessionID: String? = nil, data: [String: RelayJSON] = [:], id: String? = nil) throws -> BridgeEnvelope {
        var json: [String: RelayJSON] = ["type": .string(type), "data": .object(data)]
        if let id { json["id"] = .string(id) }; if let sessionID { json["sessionId"] = .string(sessionID) }
        return try RelayJSON.object(json).decode(BridgeEnvelope.self)
    }
    private func emit(type: String, sessionID: String? = nil, data: [String: RelayJSON] = [:]) throws {
        eventSequence += 1
        let item = try envelope(type: type, sessionID: sessionID, data: data, id: eventEpoch + ":" + String(eventSequence))
        replay.append(item); if replay.count > 384 { replay.removeFirst(replay.count - 384) }
        var overflow: [UUID] = []
        for (id, sink) in sinks { if case .dropped = sink.yield(item) { sink.finish(throwing: RelayFailure("relay_event_overflow", "Reload the current task to recover its event stream.")); overflow.append(id) } }
        for id in overflow { sinks.removeValue(forKey: id) }
    }
}
