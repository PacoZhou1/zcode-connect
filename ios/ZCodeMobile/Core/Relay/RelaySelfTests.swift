#if RELAY_SELF_TESTS || RELAY_ADAPTER_SELF_TESTS || RELAY_RECOVERY_SELF_TESTS || RELAY_AUTH_SELF_TESTS || RELAY_COLD_OPEN_SELF_TESTS || RELAY_AGENT_GOAL_SELF_TESTS || RELAY_SELF_HOSTED_SELF_TESTS
import Foundation

private struct TestFailure: Error { let message: String }
private func require(_ condition: Bool, _ message: String) throws { if !condition { throw TestFailure(message: message) } }
private func rejects(_ body: () throws -> Void) throws { do { try body(); throw TestFailure(message: "Expected rejection") } catch is TestFailure { throw TestFailure(message: "Expected protocol rejection") } catch {} }
@MainActor private func rejectsAsync(_ body: () async throws -> Void) async throws { do { try await body(); throw TestFailure(message: "Expected rejection") } catch is TestFailure { throw TestFailure(message: "Expected protocol rejection") } catch {} }
@MainActor private func waitFor(_ predicate: () async -> Bool) async throws {
    for _ in 0..<100 { if await predicate() { return }; try await Task.sleep(for: .milliseconds(10)) }
    throw TestFailure(message: "Mock condition did not complete")
}
private func hex(_ value: String) throws -> Data {
    guard value.count % 2 == 0 else { throw TestFailure(message: "Bad hex") }
    var bytes = Data(); var index = value.startIndex
    while index < value.endIndex { let end = value.index(index, offsetBy: 2); guard let byte = UInt8(value[index..<end], radix: 16) else { throw TestFailure(message: "Bad hex") }; bytes.append(byte); index = end }; return bytes
}
private func baseProjection() -> RelayJSON {
    .object(["protocolVersion": .int(1), "sessionId": .string("session-test"), "logEpoch": .string("epoch-one"), "seq": .int(10), "revision": .int(1),
             "meta": .object(["title": .string("Original desktop task")]), "config": .object(["provider": .string("configured-provider"), "model": .string("configured-model"), "thought": .string("max"), "mode": .string("build")]),
             "control": .object(["canStop": .bool(true), "phase": .string("running")]),
             "availability": .object(["pauseGoal": .object(["allowed": .bool(true)]), "resumeGoal": .object(["allowed": .bool(false)])]),
             "goal": .object(["targetId": .string("host-target"), "objective": .string("Host-created objective"), "status": .string("active"), "timeUsedSeconds": .int(40), "activeRunStartedAtMs": .int(1000), "iteration": .int(2)]),
             "subagents": .object(["revision": .int(3), "childSessionIds": .array([.string("child-one"), .string("child-ended")]), "running": .array([.object(["childSessionId": .string("child-one"), "subagentType": .string("general"), "title": .string("Host agent"), "status": .string("waiting")])]), "endedTotal": .int(1)]),
             "pendingInteractions": .array([.object(["interactionId": .string("permission-one"), "kind": .string("permission"), "anchorRowId": .null, "createdAt": .int(1000), "payload": .object(["kind": .string("permission"), "toolName": .string("Bash"), "options": .array([
                .object(["optionId": .string("allow-one"), "label": .string("Allow once"), "kind": .string("allowOnce")]),
                .object(["optionId": .string("deny-one"), "label": .string("Deny"), "kind": .string("deny")]),
                .object(["optionId": .string("custom-persistent-id"), "label": .string("Always"), "kind": .string("allowAlways")])])])])]),
             "rows": .object(["window": .array([.object(["rowId": .int(1), "kind": .string("assistantText"), "text": .string("Hello")])]), "totalCount": .int(1), "firstRowId": .int(1)])])
}
private func logical(_ payload: RelayJSON, from: Int = 0, to: Int = 10) -> RelayJSON { .object(["topic": .string("conversation/session-test"), "subscriptionId": .string("subscription-one"), "fromSeq": .int(from), "toSeq": .int(to), "sentAt": .int(2000), "payload": payload]) }
private func wire(_ frame: RelayJSON, ordinal: Int = 1) -> RelayJSON { .object(["wireVersion": .int(3), "kind": .string("complete"), "deliveryKind": .string("initial"), "logicalFrameId": .string("logical-\(ordinal)"), "logicalFrameOrdinal": .int(ordinal), "topic": frame["topic"], "subscriptionId": frame["subscriptionId"], "frame": frame]) }

actor MockRelaySocket: RelaySocketTransport {
    var inbox: [String] = []
    var receiver: CheckedContinuation<String, any Error>?
    var server: RelayFrameTransport?
    var listenerID: Int32?
    var calls: [String] = []
    var commands: [String: RelayCommandAck] = [:]
    var sentCommandCount = 0
    var dropNextCommandAck = false
    var dropNextChunkAck = false
    var imagesSupported = true
    var corruptNextSubscription = false
    var connected = false
    var uploadChunks = 0
    var sawCredentialEndpoint = false
    var configurationMode = "build"
    var configurationThought = "max"
    var setterCalls = 0
    var commandEnvelopes: [String: RelayJSON] = [:]
    var alternateProjection: RelayJSON?
    var historicalRows: [RelayJSON] = []
    var titles: [String: String] = [:]
    var registeredSessions: Set<String> = ["session-test"]
    var unreadAt: [String: Double] = [:]
    var unreadClock: Double = 1_700_000_000_123
    var unreadCalls: [RelayJSON] = []
    var archivedSessions: Set<String> = []
    var queryUnknown = false
    var nextRejectedCommand: String?
    var conversationHello: RelayJSON?
    var clientHellos: [RelayJSON] = []
    var conversationInitialized = false
    var serviceCalls: [RelayJSON] = []
    var subagentSnapshots: [String: RelayJSON] = [:]
    var subagentDirectoryOverride: RelayJSON?
    var directoryFailure = false
    var nextCommandStatus: String?
    var unavailableSubagents = Set<String>()
    var recoveryBehavior = "normal"
    var recoveryRequests = 0
    var socketConnectCount = 0
    var serializedOutgoingEnvelopes: [String] = []
    var dropHeartbeats = false
    var coldSessions = Set<String>()
    var sessionReadFailures = Set<String>()
    var coldOpenDelay: Duration = .milliseconds(120)
    var sessionReadReadiness: [RelayJSON] = []
    var coldOpenOrder: [String] = []
    func makeSessionCold(_ sessionID: String, delay: Duration = .milliseconds(120)) { coldSessions.insert(sessionID); coldOpenDelay = delay }
    func useSubagentDirectory(_ value: RelayJSON) { subagentDirectoryOverride = value }
    func failSubagentDirectory() { directoryFailure = true }
    func useProjection(_ value: RelayJSON) { alternateProjection = value }
    func setNextCommandStatus(_ value: String) { nextCommandStatus = value }
    func useGoalFixture(mode: String = "build", active: Bool = false) {
        var value = try! baseProjection().requiringObject()
        var config = try! value["config"]!.requiringObject(); config["mode"] = .string(mode); value["config"] = .object(config)
        configurationMode = mode
        value["goal"] = active ? value["goal"] : .null
        value["control"] = .object(["canStop": .bool(active), "phase": .string(active ? "running" : "draft")])
        value["pendingInteractions"] = .array([]); alternateProjection = .object(value)
    }
    func publishGoalActive() throws {
        var value = try (alternateProjection ?? baseProjection()).requiringObject()
        value["goal"] = baseProjection()["goal"]
        value["control"] = .object(["canStop": .bool(true), "phase": .string("running")])
        value["seq"] = .int(11); value["revision"] = .int(2); alternateProjection = .object(value)
        let frame = logical(.object(["kind": .string("snapshot"), "snapshot": .object(value)]), to: 11)
        var envelope = try wire(frame, ordinal: 2).requiringObject(); envelope["deliveryKind"] = .string("online")
        try sendRPC(.init(header: [.int32(204), .int32(listenerID!)], body: try .object(.object(envelope))))
    }
    func failSessionRead(_ sessionID: String) { sessionReadFailures.insert(sessionID) }
    func setRecoveryBehavior(_ value: String) { recoveryBehavior = value }
    func setDropHeartbeats(_ value: Bool) { dropHeartbeats = value }
    func failReceive() { connected = false; receiver?.resume(throwing: URLError(.networkConnectionLost)); receiver = nil }
    func sendRecoveryGap(ordinal: Int = 2) throws {
        let frame = logical(.object(["kind": .string("deltas"), "deltas": .array([])]), from: 99, to: 100)
        var value = try wire(frame, ordinal: ordinal).requiringObject(); value["deliveryKind"] = .string("online")
        try sendRPC(.init(header: [.int32(204), .int32(listenerID!)], body: try .object(.object(value))))
    }
    func sendOnlineText(from: Int, to: Int, ordinal: Int, text: String) throws {
        let delta: RelayJSON = .object(["op": .string("row.delta"), "rowId": .int(1), "path": .string("text"), "append": .string(text)])
        let frame = logical(.object(["kind": .string("deltas"), "deltas": .array([delta])]), from: from, to: to)
        var value = try wire(frame, ordinal: ordinal).requiringObject(); value["deliveryKind"] = .string("online")
        try sendRPC(.init(header: [.int32(204), .int32(listenerID!)], body: try .object(.object(value))))
    }
    func sendRecoverySnapshot(sequence: Int = 20, ordinal: Int = 3) throws {
        var projection = try baseProjection().requiringObject()
        projection["rows"] = .object(["window": .array([.object(["rowId": .int(1), "kind": .string("assistantText"), "text": .string("Recovered complete text")])]), "totalCount": .int(1), "firstRowId": .int(1)])
        let frame = logical(.object(["kind": .string("snapshot"), "snapshot": .object(projection)]), to: sequence)
        var value = try wire(frame, ordinal: ordinal).requiringObject(); value["deliveryKind"] = .string("recovery")
        try sendRPC(.init(header: [.int32(204), .int32(listenerID!)], body: try .object(.object(value))))
    }
    func useSubagentSnapshot(_ value: RelayJSON, sessionID: String) { subagentSnapshots[sessionID] = value }
    func setSubagentUnavailable(_ sessionID: String, value: Bool) { if value { unavailableSubagents.insert(sessionID) } else { unavailableSubagents.remove(sessionID) } }
    func listSubagentAsTask(_ sessionID: String) { registeredSessions.insert(sessionID) }
    func useConversationHello(_ value: RelayJSON) { conversationHello = value }
    func rejectNextCommand(reason: String) { nextRejectedCommand = reason }
    func reportUnknownCommands(_ value: Bool) { queryUnknown = value }
    func useForkRows() throws {
        var value = try baseProjection().requiringObject()
        value["control"] = .object(["canStop": .bool(false), "phase": .string("completedSuccess")])
        value["pendingInteractions"] = .array([]); value["goal"] = .null
        value["availability"] = .object(["fork": .object(["allowed": .bool(true)])])
        value["rows"] = .object(["window": .array([.object(["rowId": .int(9), "turnId": .string("turn-one"), "entityId": .string("stable-boundary"), "assistantResponseId": .string("message-one"), "kind": .string("assistantText"), "state": .string("complete"), "text": .string("Host finished answer"), "actions": .object(["canFork": .bool(true)])])]), "totalCount": .int(1), "firstRowId": .int(9)])
        alternateProjection = .object(value)
    }
    func useHookReview(_ request: RelayHookReviewRequest?) throws {
        var value = try baseProjection().requiringObject()
        value["control"] = .object(["canStop": .bool(false), "phase": .string("completedSuccess")]); value["goal"] = .null
        value["pendingInteractions"] = .array(request.map { [.object(["interactionId": .string($0.interactionId), "kind": .string("workspaceHookReview"), "anchorRowId": .null, "createdAt": .number($0.createdAt), "payload": $0.wire])] } ?? [])
        value["workspaceHookAdmission"] = request.map { .object(["pendingCount": .int($0.summary.pendingCount), "bundleDigest": .string($0.bundleDigest), "workspaceIdentity": .string($0.workspaceIdentity)]) } ?? .null
        alternateProjection = .object(value)
    }
    func setHostUnread(_ stamp: Double, sessionID: String) { unreadAt[sessionID] = stamp }
    func snapshot(_ sessionID: String) -> RelayJSON {
        let model: RelayJSON = .object(["providerId": .string("host-provider"), "modelId": .string("host-model")])
        return .object(["session": .object(["sessionId": .string(sessionID), "title": .string(titles[sessionID] ?? "Original desktop task"), "status": .string("completed")]), "settings": .object(["model": .object(["current": model, "available": .array([.object(["ref": model, "label": .string("Host model"), "reasoning": .object(["levels": .array([.object(["value": .string("max")]), .object(["value": .string("high")])])]), "supportsImages": .bool(imagesSupported), "supportsPdf": .bool(false)])])]), "thoughtLevel": .object(["current": .string(configurationThought), "available": .array([.object(["value": .string("max")]), .object(["value": .string("high")])])]), "mode": .object(["current": .string(configurationMode)])]), "messages": .array([]), "runtime": .object([:])])
    }
    private func completeConversationSubscription(_ id: Int32, params: RelayJSON) throws {
        var projection = try (alternateProjection ?? baseProjection()).requiringObject()
        let sessionID = params["sessionId"].string!; projection["sessionId"] = .string(sessionID)
        coldSessions.remove(sessionID); coldOpenOrder.append("runtime-ready:" + sessionID)
        var frame = try logical(.object(["kind": .string("snapshot"), "snapshot": .object(projection)])).requiringObject()
        frame["topic"] = .string("conversation/" + sessionID); frame["subscriptionId"] = .string("subscription-" + sessionID)
        if sessionID == "session-test" { frame["subscriptionId"] = .string("subscription-one") }
        var initial = try wire(.object(frame)).requiringObject()
        if corruptNextSubscription { initial["wireVersion"] = .int(99); corruptNextSubscription = false }
        try sendRPC(.init(header: [.int32(204), .int32(listenerID!)], body: try .object(.object(initial))))
        try success(id, .object(["ack": .object(["subscriptionId": frame["subscriptionId"]!, "mode": .string("snapshot"), "logEpoch": .string("epoch-one")])]))
    }
    func connect(to url: URL) async throws { try require(url.host == "zcode.z.ai", "Wrong host"); connected = true; socketConnectCount += 1 }
    func close() async { connected = false; receiver?.resume(throwing: RelayFailure.closed()); receiver = nil; inbox.removeAll() }
    func receive() async throws -> String {
        if !inbox.isEmpty { return inbox.removeFirst() }; guard connected else { throw RelayFailure.closed() }
        return try await withCheckedThrowingContinuation { receiver = $0 }
    }
    func push(_ json: RelayJSON) throws {
        let text = String(data: try json.data(), encoding: .utf8)!
        if let receiver { self.receiver = nil; receiver.resume(returning: text) } else { inbox.append(text) }
    }
    func payload(_ json: RelayJSON) throws { try push(.object(["type": .string("data"), "payload": json])) }
    func sendRPC(_ message: RelayIPCMessage) throws {
        let frames = try server!.enqueue(RelayIPCCodec.encode(message))
        for frame in frames { try payload(frame) }
    }
    func success(_ id: Int32, _ value: RelayJSON) throws { try sendRPC(.init(header: [.int32(201), .int32(id)], body: try .object(value))) }
    func send(text: String) async throws {
        serializedOutgoingEnvelopes.append(text)
        // An actual suspension makes concurrent-client frame interleaving observable to the server assembler.
        try await Task.sleep(for: .milliseconds(1))
        let message = try RelayJSON(data: Data(text.utf8))
        switch message["type"].string {
        case "auth_init": try push(.object(["type": .string("auth_challenge"), "nonce": .string("nonce-test")]))
        case "auth_response":
            let pairing = try RelayPairing(scannedURL: "https://zcode.z.ai/remote/v4?sid=mock-desktop&hash=mock-pairing-value-0123456789-abcdef")
            try require(message["proof"].string == pairing.challengeProof(nonce: "nonce-test"), "HMAC proof differs")
            try push(.object(["type": .string("auth_ack"), "pair_status": .string("matched")]))
        case "pair_status_query": if !dropHeartbeats { try push(.object(["type": .string("pair_status_ack"), "pair_status": .string("matched")])) }
        case "data":
            let value = message["payload"]
            if value["zcode_type"].string == "bootstrap-request" || value["zcode_type"].string == "workspace-list-request" {
                let type = value["zcode_type"].string == "bootstrap-request" ? "bootstrap-response" : "workspace-list-response"
                try payload(.object(["zcode_type": .string(type), "requestId": value["requestId"], "success": .bool(true), "result": .object(["workspaces": .array([.object(["kind": .string("local"), "workspacePath": .string("/workspace")])]), "tasks": .array([])])])); return
            }
            if value["zcode_type"].string == "workspace-bridge-open" {
                conversationInitialized = false
                let id = RelayFrameIdentity(bridgeSessionId: value["bridgeSessionId"].string!, bridgeGeneration: value["bridgeGeneration"].integer)
                server = try .init(identity: id)
                var bridge = id.fields; bridge.merge(["kind": .string("local"), "workspaceKey": .string("/workspace"), "workspacePath": .string("/workspace")]) { _, new in new }
                try payload(.object(["zcode_type": .string("workspace-bridge-ready"), "requestId": value["requestId"], "bridgeSessionId": value["bridgeSessionId"], "bridge": .object(bridge)]))
                try sendRPC(.init(header: [.int32(200)], body: .undefined)); return
            }
            let accepted = try server!.accept(value)
            if let ack = accepted.acknowledgement { try payload(ack) }
            guard let bytes = accepted.message else { return }
            let request = try RelayIPCCodec.decode(bytes)
            if request.type == 102 { try require(conversationInitialized, "Conversation listener preceded ClientHello"); listenerID = request.requestID; return }
            if request.type == 103 { return }
            let id = request.requestID!, method = try request.header[3].jsonValue().string!, params = try request.body.jsonValue().array!.first!
            if ["helloConversationV4", "initializeConversationV4"].contains(method) { try require(params["workspacePath"] == .null, "ClientHello contains strict-schema workspace fields") }
            else { try require(params["workspacePath"].string == "/workspace", "Scope missing") }
            calls.append(method)
            serviceCalls.append(.object(["channel": try request.header[2].jsonValue(), "method": .string(method), "params": params]))
            switch method {
            case "helloConversationV4":
                try success(id, conversationHello ?? .object(["kind": .string("hello"), "protocolVersion": .int(3), "connectionId": .string("mock-conversation"), "clientMode": .string("web-remote-replayable"), "deliveryProfile": .string("replayable"), "serverTime": .int(1_700_000_000_000), "capabilities": .object(["nativeDialogs": .bool(false), "localTerminal": .bool(false), "binaryFrames": .bool(false), "compression": .string("none"), "workspaceHookReview": .bool(true)]), "auth": .object([:])]))
            case "initializeConversationV4":
                try require(Set(try params.requiringObject().keys) == ["kind", "protocolVersion", "clientId", "clientKind", "appVersion", "capabilities"], "ClientHello fields differ from the strict official schema")
                try require(params["kind"].string == "clientHello" && params["protocolVersion"].integer == 3 && params["clientKind"].string == "mobileApp" && params["capabilities"] == .object(["workspaceHookReviewUi": .bool(true)]), "The complete native hook UI was not advertised")
                clientHellos.append(params); conversationInitialized = true; try success(id, .null)
            case "listTasks", "listPinnedTasks", "listArchivedTasks":
                let tasks = registeredSessions.filter { archivedSessions.contains($0) == (method == "listArchivedTasks") }
                try success(id, .array(tasks.sorted().map { .object(["taskId": .string($0), "title": .string(titles[$0] ?? "Original desktop task"), "workspacePath": .string("/workspace"), "provider": .string("glm"), "unreadAt": unreadAt[$0].map(RelayJSON.number) ?? .null]) }))
            case "listSessionSubagents":
                if directoryFailure { try sendRPC(.init(header: [.int32(202), .int32(id)], body: try .object(.object(["message": .string("Directory unavailable")])))); break }
                let source = (alternateProjection ?? baseProjection())["subagents"]
                let ended: RelayJSON = .object(["childSessionId": .string("child-ended"), "title": .string("Original ended agent"), "status": .string("success"), "subagentType": .string("Explore"), "summary": .string("Original child summary"), "endedAt": .int(2_000)])
                let directory = subagentDirectoryOverride ?? .object(["revision": source["revision"], "childSessionIds": source["childSessionIds"], "running": source["running"], "ended": .object(["total": source["endedTotal"], "items": source["endedTotal"].integer == 0 ? .array([]) : .array([ended])])])
                try success(id, directory)
            case "readSession", "resumeSession":
                if method == "resumeSession" { registeredSessions.insert(params["sessionId"].string!) }
                let sessionID = params["sessionId"].string!
                let ready = !coldSessions.contains(sessionID)
                sessionReadReadiness.append(.object(["sessionId": .string(sessionID), "method": .string(method), "runtimeReady": .bool(ready)]))
                coldOpenOrder.append("read:" + sessionID + (ready ? ":ready" : ":cold"))
                if unavailableSubagents.contains(sessionID) || sessionReadFailures.contains(sessionID) || (method == "readSession" && !ready) {
                    try sendRPC(.init(header: [.int32(202), .int32(id)], body: try .object(.object(["message": .string("Session is not active"), "code": .string("sessionUnavailable")]))))
                } else { try success(id, subagentSnapshots[sessionID] ?? snapshot(sessionID)) }
            case "readWorkspaceState": try success(id, .object(["settings": snapshot("session-test")["settings"]]))
            case "conversationRowsRangeV4":
                let before = params["beforeRowId"].integer ?? Int.max, limit = params["limit"].integer!
                let rows = historicalRows.filter { $0["rowId"].integer! < before }, page = Array(rows.suffix(limit))
                try success(id, .object(["rows": .array(page), "atSeq": .int(10), "atLogEpoch": .string("epoch-one"), "hasMore": .bool(rows.count > page.count)]))
            case "setModel", "setThoughtLevel", "setMode":
                setterCalls += 1
                if method == "setModel" { registeredSessions.insert(params["sessionId"].string!) }
                if method != "setMode" { try require(params["persistAsWorkspaceLastUsed"].bool == false, "Workspace defaults were changed") }
                if let mode = params["mode"].string { configurationMode = mode }
                if let thought = params["thoughtLevel"].string { configurationThought = thought }
                try success(id, snapshot(params["sessionId"].string!))
            case "subscribeConversationV4":
                let sessionID = params["sessionId"].string!
                coldOpenOrder.append("subscribe:" + sessionID)
                if coldSessions.contains(sessionID) {
                    // Host restoration completes independently of accepting later RPC frames.
                    // Sleeping inside send() would serialize reads behind this ACK and hide the race.
                    let delay = coldOpenDelay
                    Task {
                        try await Task.sleep(for: delay)
                        if connected { try completeConversationSubscription(id, params: params) }
                    }
                } else { try completeConversationSubscription(id, params: params) }
            case "sendConversationCommandV4":
                let envelope = params["envelope"], commandID = envelope["commandId"].string!, prior = commands[commandID]
                if prior == nil { sentCommandCount += 1 }
                if let original = commandEnvelopes[commandID] { try require(original == envelope, "Retry changed the original command envelope") }
                commandEnvelopes[commandID] = envelope
                let kind = envelope["type"].string
                let result: RelayJSON? = kind == "createSession" ? .object(["type": .string("createSession"), "sessionId": .string("session-created")]) : kind == "forkAssistant" ? .object(["type": .string("forkAssistant"), "sessionId": .string("fork-child-" + commandID)]) : nil
                let rejection = nextRejectedCommand, status = nextCommandStatus; nextRejectedCommand = nil; nextCommandStatus = nil
                let ack = prior.map { old in old.admitted ? RelayCommandAck(commandId: old.commandId, status: "duplicate", revisionAtDecision: old.revisionAtDecision, reasonCode: old.reasonCode, message: old.message, result: old.result) : old } ?? RelayCommandAck(commandId: commandID, status: status ?? (rejection == nil ? "accepted" : "stale"), revisionAtDecision: 2, reasonCode: rejection, message: rejection == nil ? nil : "Host target changed", result: rejection == nil ? result : nil)
                commands[commandID] = ack
                if dropNextCommandAck { dropNextCommandAck = false; return }
                try success(id, RelayJSON(data: JSONEncoder().encode(ack)))
            case "queryConversationCommandsV4":
                let results = try params["commands"].array!.map { key -> RelayJSON in
                    let result = queryUnknown ? .string("unknown") : try commands[key["commandId"].string!].map { try RelayJSON(data: JSONEncoder().encode($0)) } ?? .string("unknown")
                    return .object(["key": key, "result": result])
                }
                try success(id, .object(["results": .array(results)]))
            case "attachmentBeginV4": try success(id, .object(["state": .string("uploading"), "nextChunkIndex": .int(0)]))
            case "attachmentChunkV4":
                uploadChunks += 1; _ = try RelayWire.base64(params["dataBase64"].string!)
                if dropNextChunkAck { dropNextChunkAck = false; return }
                try success(id, .object(["nextChunkIndex": .int(params["chunkIndex"].integer! + 1)]))
            case "attachmentCommitV4": try success(id, .object(["ref": .string("attachment-ref")]))
            case "resyncConversationV4":
                recoveryRequests += 1
                if recoveryBehavior == "timeout" { return }
                if recoveryBehavior == "ackOnly" { try success(id, .object([:])); return }
                if recoveryBehavior == "reject" { try sendRPC(.init(header: [.int32(202), .int32(id)], body: try .object(.object(["message": .string("Recovery unavailable")])))); return }
                if recoveryBehavior == "snapshotThenDropAck" { try sendRecoverySnapshot(); return }
                var recovery = try wire(logical(.object(["kind": .string("snapshot"), "snapshot": baseProjection()])), ordinal: 2).requiringObject(); recovery["deliveryKind"] = .string("recovery")
                try sendRPC(.init(header: [.int32(204), .int32(listenerID!)], body: try .object(.object(recovery))))
                try success(id, .object([:]))
            case "unsubscribeConversationV4", "attachmentAbortV4": try success(id, .object([:]))
            case "renameTask", "setTaskPinned", "archiveTask", "unarchiveTask":
                let taskID = params["taskId"].string!
                if let title = params["title"].string { titles[taskID] = title }
                if method == "archiveTask" { archivedSessions.insert(taskID) }
                if method == "unarchiveTask" { archivedSessions.remove(taskID) }
                try success(id, .object(["taskId": .string(taskID), "title": .string(titles[taskID] ?? "Original desktop task"), "workspacePath": .string("/workspace"), "provider": .string("glm"), "pinned": params["pinned"], "unreadAt": unreadAt[taskID].map(RelayJSON.number) ?? .null]))
            case "setTaskUnread":
                let taskID = params["taskId"].string!; unreadCalls.append(params)
                if params["unread"].bool == true { unreadClock += 1; unreadAt[taskID] = unreadClock }
                else if params["expectedUnreadAt"].number == unreadAt[taskID] { unreadAt[taskID] = nil }
                try success(id, .object(["taskId": .string(taskID), "title": .string(titles[taskID] ?? "Original desktop task"), "workspacePath": .string("/workspace"), "provider": .string("glm"), "unreadAt": unreadAt[taskID].map(RelayJSON.number) ?? .null]))
            case "readdir":
                let path = params["path"].string!, entries: [RelayJSON]
                if path == "/workspace" {
                    entries = [("src", "directory", false), ("README.md", "file", false), ("secrets.json", "file", false), ("link.txt", "file", true)].map { .object(["name": .string($0.0), "path": .string(path + "/" + $0.0), "type": .string($0.1), "isSymbolicLink": .bool($0.2)]) }
                }
                else if path == "/workspace/src" { entries = [.object(["name": .string("main.swift"), "path": .string(path + "/main.swift"), "type": .string("file"), "isSymbolicLink": .bool(false)])] }
                else { throw TestFailure(message: "Unexpected file root") }
                try success(id, .array(entries))
            case "stat": try success(id, .object(["path": params["path"], "type": .string("file"), "size": .int(5)]))
            case "readTextFile": try success(id, .object(["path": params["path"], "content": .string("hello"), "isBinary": .bool(false), "truncated": .bool(false), "offset": .int(0), "bytesRead": .int(5), "totalBytes": .int(5)]))
            case "getChanges": try success(id, .array([.object(["path": .string("README.md"), "added": .int(1), "removed": .int(0)])]))
            case "getDiff": try success(id, .object(["path": params["path"], "availability": .string("patch"), "patch": .string("+hello")]))
            default: sawCredentialEndpoint = true; throw TestFailure(message: "Unexpected method \(method)")
            }
        default: throw TestFailure(message: "Unexpected relay envelope")
        }
    }
    func dropAcknowledgement() { dropNextCommandAck = true }
    func setImagesSupported(_ supported: Bool) { imagesSupported = supported }
    func dropChunkAcknowledgement() { dropNextChunkAck = true }
    func corruptSubscription() { corruptNextSubscription = true }
    func useHistoricalRows() {
        var value = try! baseProjection().requiringObject()
        historicalRows = [.object(["rowId": .int(1), "kind": .string("userInput"), "origin": .string("realUser"), "text": .string("Original question")]),
            .object(["rowId": .int(2), "kind": .string("assistantText"), "assistantResponseId": .string("cross-page"), "text": .string("Head ")])]
        value["rows"] = .object(["window": .array([.object(["rowId": .int(3), "kind": .string("assistantText"), "assistantResponseId": .string("cross-page"), "text": .string("tail")])]), "firstRowId": .int(1), "totalCount": .int(3)])
        alternateProjection = .object(value)
    }
    func useEmptyActivity() {
        var value = try! baseProjection().requiringObject(); value["goal"] = .null; value["subagents"] = .object(["revision": .int(0), "childSessionIds": .array([]), "running": .array([]), "endedTotal": .int(0)])
        value["control"] = .object(["canStop": .bool(false), "phase": .string("draft")]); value["pendingInteractions"] = .array([]); alternateProjection = .object(value)
    }
    func kick() throws { try push(.object(["type": .string("error"), "code": .string("KICKED")])) }
}

#if RELAY_SELF_TESTS
@main private struct RelaySelfTests {
    static func main() async throws {
        var checks: [String] = []
        checks += try runHookReviewDTOTests()
        checks += try await runConversationCapabilityTests()
        checks += try await runHookReviewClientTests()
        let evidenceDirectory = CommandLine.arguments.dropFirst().first ?? "/Users/developer/claude code/zcode-mobile/docs/backend/evidence"
        let vectors = try RelayJSON(data: Data(contentsOf: URL(fileURLWithPath: evidenceDirectory + "/relay-ipc-vectors.json")))
        for vector in vectors["vectors"].array! {
            let bytes = try hex(vector["hex"].string!), decoded = try RelayIPCCodec.decode(bytes)
            try require(RelayIPCCodec.encode(decoded) == bytes, "Official IPC bytes changed")
            try require(RelayIPCValue.array(decoded.header).jsonValue() == vector["header"], "Header decode differs")
            try require(decoded.body.jsonValue() == vector["body"], "Body decode differs")
        }
        checks.append("four_official_ipc_vectors")
        try require(RelayChecksum.crc32(Data("123456789".utf8)) == "cbf43926", "CRC vector failed")
        for bytes in [Data([4, 1]), Data([4, 1, 6, 255, 255, 255, 255, 31]), Data([4, 1, 1, 1, 255, 0]), Data([4, 0, 0, 0])] { try rejects { _ = try RelayIPCCodec.decode(bytes) } }
        checks.append("crc_varint_utf8_truncation_bounds")
        let frameEvidence = try RelayJSON(data: Data(contentsOf: URL(fileURLWithPath: evidenceDirectory + "/relay-frame-vectors.json")))
        let identity = RelayFrameIdentity(bridgeSessionId: "bridge-golden", bridgeGeneration: 1, recoveryId: "recovery-golden")
        try require(RelayFrameTransport.fragment(hex(frameEvidence["rawIPCHex"].string!), identity: identity) == frameEvidence["frames"].array!, "Official RPC frame differs")
        var receiver = try RelayFrameTransport(identity: identity); let big = Data(repeating: 73, count: 700_000), fragments = try RelayFrameTransport.fragment(big, identity: identity)
        _ = try receiver.accept(fragments[0]); _ = try receiver.accept(fragments[0]); let completed = try receiver.accept(fragments[1]); try require(completed.message == big, "Fragment reassembly failed"); try require(receiver.accept(fragments[1]).message == nil, "Replay delivered twice")
        var wrongOrder = try RelayFrameTransport(identity: identity); try rejects { _ = try wrongOrder.accept(fragments[1]) }
        var sender = try RelayFrameTransport(identity: identity); _ = try sender.enqueue(Data([1]), now: 0); try rejects { _ = try sender.replayFrames(now: 46) }
        checks.append("official_rpc_frame_fragment_replay_and_deadlines")

        var reducer = RelayProjectionReducer(); let snapshot = logical(.object(["kind": .string("snapshot"), "snapshot": baseProjection()]))
        try require(reducer.apply(snapshot, expectedSessionID: "session-test"), "Snapshot failed")
        let change = logical(.object(["kind": .string("deltas"), "deltas": .array([.object(["op": .string("row.delta"), "rowId": .int(1), "path": .string("text"), "append": .string(" 世界")])])]), from: 10, to: 11)
        try require(reducer.apply(change, expectedSessionID: "session-test"), "Delta failed")
        try require(reducer.projection!.rows[0]["text"].string == "Hello 世界", "Delta content differs")
        try require(!reducer.apply(change, expectedSessionID: "session-test"), "Delta replay duplicated")
        let beforeGap = reducer.projection; try rejects { _ = try reducer.apply(logical(.object(["kind": .string("deltas"), "deltas": .array([])]), from: 12, to: 13), expectedSessionID: "session-test") }; try require(reducer.projection == beforeGap, "Failed delta partially mutated projection")
        let goal = reducer.projection!.hostGoal!; try require(goal.elapsedSeconds(atUnixMilliseconds: 6000) == 45 && goal.pauseAvailable && !goal.resumeAvailable && !goal.removeAvailable, "Host goal incorrect")
        try require(goal.elapsedSeconds(atUnixMilliseconds: Double.greatestFiniteMagnitude) == 9_007_199_254_740_991, "Corrupt clock overflowed the goal timer")
        try require(reducer.projection!.hostAgents!.runningCount == 1 && reducer.projection!.hostAgents!.endedTotal == 1 && reducer.projection!.hostAgents!.childSessionIDs.count == 2, "Host agents incorrect")
        checks.append("atomic_projection_seq_replay_goal_and_real_agent_counts")

        var historyRaw = try baseProjection().requiringObject()
        historyRaw["rows"] = .object(["window": .array([.object(["rowId": .int(3), "kind": .string("assistantText"), "text": .string("Tail")])]), "firstRowId": .int(1), "totalCount": .int(2)])
        var history = RelayProjectionReducer(projection: try .init(raw: .object(historyRaw)))
        let page: RelayJSON = .object(["rows": .array([.object(["rowId": .int(1), "kind": .string("assistantText"), "text": .string("Head")])]), "atSeq": .int(10), "atLogEpoch": .string("epoch-one"), "hasMore": .bool(false)])
        try history.prependRows(page, beforeRowID: 3, expectedLogEpoch: "epoch-one")
        try require(history.projection?.rows.count == 2, "History did not join the live projection")
        try rejects { try history.prependRows(page, beforeRowID: 3, expectedLogEpoch: "epoch-one") }
        try rejects { try history.prependRows(page, beforeRowID: 1, expectedLogEpoch: "stale-epoch") }
        let historyDelta = logical(.object(["kind": .string("deltas"), "deltas": .array([.object(["op": .string("row.delta"), "rowId": .int(1), "path": .string("text"), "append": .string(" updated")])])]), from: 10, to: 11)
        _ = try history.apply(historyDelta, expectedSessionID: "session-test")
        try require(history.projection?.rows.first?["text"].string == "Head updated", "Loaded history stopped receiving deltas")
        var stale = RelayProjectionReducer(projection: try .init(raw: .object(historyRaw))); historyRaw["seq"] = .int(11)
        stale = RelayProjectionReducer(projection: try .init(raw: .object(historyRaw)))
        try rejects { try stale.prependRows(page, beforeRowID: 3, expectedLogEpoch: "epoch-one") }
        try require(stale.projection?.rows.count == 1, "Stale page partially changed history")
        checks.append("history_pagination_epoch_sequence_anchor_fences_and_live_deltas")
        var assembler = RelayConversationAssembler(); let logicalBytes = try snapshot.data(), split = logicalBytes.count / 2
        func inner(_ index: Int) -> RelayJSON {
            .object(["wireVersion": .int(3), "kind": .string("fragment"), "deliveryKind": .string("initial"), "logicalFrameId": .string("inner-test"), "logicalFrameOrdinal": .int(1), "topic": .string("conversation/session-test"), "subscriptionId": .string("subscription-one"), "fragmentCount": .int(2), "fragmentIndex": .int(index), "logicalBytes": .int(logicalBytes.count), "checksum": .object(["algorithm": .string("crc32"), "value": .string(RelayChecksum.crc32(logicalBytes))]), "dataBase64": .string(logicalBytes.subdata(in: index == 0 ? 0..<split : split..<logicalBytes.count).base64EncodedString())])
        }
        try require(assembler.accept(inner(1)) == nil, "Partial frame delivered"); try require(assembler.accept(inner(0)) == snapshot, "Inner frame mismatch"); try require(assembler.accept(inner(0)) == nil, "Inner replay duplicated")
        var expired = RelayConversationAssembler(); _ = try expired.accept(inner(0), now: 0); try require(expired.expire(now: 31) == ["subscription-one"], "Inner timeout missing")
        checks.append("conversation_v3_fragment_order_replay_and_expiry")

        let pairingURL = "https://zcode.z.ai/remote/v4?sid=mock-desktop&hash=mock-pairing-value-0123456789-abcdef", pairing = try RelayPairing(scannedURL: pairingURL)
        try require(!String(reflecting: pairing).contains("mock-pairing-value"), "Pairing debug leaked")
        try rejects { _ = try RelayPairing(scannedURL: pairingURL + "&sid=duplicate") }; try rejects { _ = try RelayPairing(scannedURL: pairingURL.replacingOccurrences(of: "https:", with: "http:")) }
        let mock = MockRelaySocket(), client = try RelayClient(clientID: "stable-native-client", transport: mock, requestTimeout: 2)
        try await rejectsAsync { try await client.connect(pairing: pairing, confirmedControllerReplacement: false) }
        try await client.connect(pairing: pairing, confirmedControllerReplacement: true)
        _ = try await client.bootstrap(); _ = try await client.openWorkspace(key: "/workspace")
        try require(try await client.listTasks().first?.taskId == "session-test", "Task list failed")
        let read = try await client.readSession("session-test"); try require(read.thoughtLevel == "max", "Read changed model thought")
        _ = try await client.subscribe(sessionID: "session-test")
        try require(await client.currentProjection(sessionID: "session-test")?.showsHostGoal == true, "Early projection was lost")
        _ = try await client.reply(sessionID: "session-test", interactionID: "permission-one", answer: .option("allow-one"), commandID: "one-time-approval", explicitUserAction: true)
        try await rejectsAsync { _ = try await client.reply(sessionID: "session-test", interactionID: "permission-one", answer: .option("custom-persistent-id"), commandID: "persistent-denied", explicitUserAction: true) }
        _ = try await client.pauseGoal(sessionID: "session-test", commandID: "pause-host-goal", explicitUserAction: true)
        try await rejectsAsync { _ = try await client.resumeGoal(sessionID: "session-test", commandID: "resume-disabled-goal", explicitUserAction: true) }
        try await rejectsAsync { try await client.removeGoal(sessionID: "session-test") }
        let yolo = await client.makeCommand(sessionID: "session-test", type: "switchCollaborationMode", payload: .object(["mode": .string("yolo")]), commandID: "unconfirmed-yolo")
        try await rejectsAsync { _ = try await client.submit(yolo, explicitUserAction: true) }
        let command = await client.makeCommand(sessionID: "session-test", type: "sendText", payload: .object(["text": .string("Native test")]), commandID: "durable-message")
        _ = try await client.submit(command, explicitUserAction: true); let duplicate = try await client.submit(command, explicitUserAction: true); try require(duplicate.status == "duplicate", "Command replay changed identity")
        checks.append("mock_challenge_bootstrap_original_host_read_early_stream_commands_and_guards")
        let png = Data([137, 80, 78, 71, 13, 10, 26, 10]) + Data(repeating: 73, count: 500_000)
        let pngCount = png.count
        async let attachment = client.uploadAttachment(sessionID: "session-test", fileName: "test.png", mime: "image/png", data: png, uploadID: "stable-upload", explicitUserAction: true)
        async let parallelTasks = client.listTasks()
        let uploaded = try await attachment; _ = try await parallelTasks
        try require(uploaded.ref == "attachment-ref" && uploaded.bytes == pngCount, "Attachment transaction failed")
        try require(await mock.uploadChunks == 2, "Attachment chunks differ")
        checks.append("concurrent_rpc_batch_order_and_attachment_transaction")
        await mock.setImagesSupported(false)
        try await rejectsAsync { _ = try await client.uploadAttachment(sessionID: "session-test", fileName: "test.png", mime: "image/png", data: png, uploadID: "changed-model-upload", explicitUserAction: true) }
        try require(await mock.uploadChunks == 2, "A stale cached model allowed an unsupported image")
        await mock.setImagesSupported(true); await mock.dropChunkAcknowledgement()
        let cancelledUpload = Task { try await client.uploadAttachment(sessionID: "session-test", fileName: "test.txt", mime: "text/plain", data: Data("cancel test".utf8), uploadID: "cancelled-upload", explicitUserAction: true) }
        try await waitFor { await mock.uploadChunks == 3 }; cancelledUpload.cancel()
        try await rejectsAsync { _ = try await cancelledUpload.value }
        try require(await mock.calls.contains("attachmentAbortV4"), "Cancelled attachment transaction was not aborted")
        checks.append("fresh_host_modality_guard_and_cancelled_attachment_abort")
        try await client.unsubscribe(sessionID: "session-test"); await mock.corruptSubscription()
        _ = try await client.subscribe(sessionID: "session-test", resume: false)
        try await waitFor { await client.currentProjection(sessionID: "session-test") != nil }
        try require(await mock.calls.contains("resyncConversationV4"), "Invalid initial frame was not recovered after subscribe acknowledgement")
        checks.append("invalid_early_frame_recovers_after_subscription_ack")
        await mock.dropAcknowledgement()
        let uncertainEnvelope = await client.makeCommand(sessionID: "session-test", type: "sendText", payload: .object(["text": .string("Uncertain test")]), commandID: "uncertain-message")
        let pending = Task { try await client.submit(uncertainEnvelope, explicitUserAction: true) }
        try await waitFor { await mock.commands["uncertain-message"] != nil }; pending.cancel(); try await rejectsAsync { _ = try await pending.value }
        let reconciled = try await client.queryCommands([.init(sessionId: "session-test", commandId: "uncertain-message")])
        try require(reconciled["results"].array!.first!["result"]["status"].string == "accepted", "Uncertain command was not reconciled")
        try require(await mock.sentCommandCount == 4, "A command was silently repeated")
        checks.append("cancellation_preserves_command_identity_and_query_reconciliation")
        _ = try await client.stop(sessionID: "session-test", commandID: "stop-current", explicitUserAction: true)
        try await rejectsAsync { _ = try await client.reply(sessionID: "session-test", interactionID: "permission-one", answer: .option("allow-one"), commandID: "late-approval", explicitUserAction: true) }
        try await mock.kick(); try await Task.sleep(for: .milliseconds(40)); try require(await client.state == .replaced, "KICKED did not stop the connection")
        try require(await mock.sawCredentialEndpoint == false, "A credential endpoint was used")
        await client.disconnect(); checks.append("stop_blocks_late_approval_and_kicked_requires_explicit_reconnect")
        let output: RelayJSON = .object(["passed": .bool(true), "verifiedAt": .string(ISO8601DateFormatter().string(from: Date())), "checks": .array(checks.map(RelayJSON.string)), "realAccountConnected": .bool(false), "liveVerified": .bool(false)])
        try output.data().write(to: URL(fileURLWithPath: evidenceDirectory).appending(path: "swift-relay-validation.json"), options: .atomic)
        print(String(data: try output.data(), encoding: .utf8)!)
    }
}
#endif
#endif
