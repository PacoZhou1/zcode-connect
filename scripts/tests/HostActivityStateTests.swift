import Foundation

// Other Store suites reuse these default-throwing adapters. The dedicated activity
// runner instead links in-memory RelayWorkspaceRecoveryAdapters, never real I/O.
#if !HOST_ACTIVITY_STATE_TESTS
actor RelayClient {
    init(clientID: String) throws {}
    func connect(pairing: RelayPairing, confirmedControllerReplacement: Bool) async throws { throw prohibited() }
    func bootstrap() async throws -> RelayBootstrap { throw prohibited() }
    func workspaces() async throws -> RelayBootstrap { throw prohibited() }
    func openWorkspace(key: String) async throws -> RelayBridge { throw prohibited() }
    func disconnect() async {}
    private func prohibited() -> TestFailure { TestFailure(message: "Real relay I/O is prohibited in this state harness") }
}
actor RelayRemoteTransport: RemoteTransport {
    init(client: RelayClient, bootstrap: RelayBootstrap, bridge: RelayBridge, hostName: String) async throws { throw TestFailure(message: "Real relay I/O is prohibited") }
    func get<T: Decodable & Sendable>(_ path: String, as type: T.Type) async throws -> T { throw TestFailure(message: "Real relay I/O is prohibited") }
    func mutate<T: Decodable & Sendable>(_ path: String, method: String, body: [String: JSONValue], as type: T.Type) async throws -> T { throw TestFailure(message: "Real relay I/O is prohibited") }
    func events(after cursor: String?, onEvent: @Sendable (BridgeEnvelope) async -> Void) async throws { throw TestFailure(message: "Real relay I/O is prohibited") }
    func shutdown() async {}
}
#endif

@main struct HostActivityStateTests {
    @MainActor static var results: [TestResult] = []
    @MainActor static var assertions = 0
    @MainActor static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        assertions += 1
        if try !condition() { throw TestFailure(message: message) }
    }
    @MainActor static func run(_ name: String, _ body: () async throws -> Void) async {
        for _ in 0..<150 { await Task.yield() }
        TestTransport.reset()
        RelayWorkspaceProbe.reset()
        OutboxTestSandbox.directory = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(UUID().uuidString)
        do { try await body(); results.append(.init(name: name, passed: true, detail: "all assertions passed")); print("PASS \(name)") }
        catch { let detail = (error as? TestFailure)?.message ?? String(describing: error); results.append(.init(name: name, passed: false, detail: detail)); print("FAIL \(name): \(detail)") }
    }
    static func goal(_ status: String = "active", objective: String = "Host objective") -> RelayJSON {
        .object(["targetId": .string("target-1"), "objective": .string(objective), "status": .string(status), "timeUsedSeconds": .int(60), "activeRunStartedAtMs": .number(1_000_000), "iteration": .int(1), "verifications": .array([])])
    }
    static func agent(_ id: String, title: String = "Host agent", status: String = "running") -> RelayJSON {
        .object(["childSessionId": .string(id), "title": .string(title), "subagentType": .string("general"), "status": .string(status), "summary": .string("Host summary")])
    }
    static func row(_ id: String, rowID: Int = 1, title: String = "Ended host agent", status: String = "completed") -> RelayJSON {
        .object(["rowId": .int(rowID), "kind": .string("subagent"), "childSessionId": .string(id), "title": .string(title), "status": .string(status), "summaryText": .string("Host final summary")])
    }
    static func activity(goal: RelayJSON = .null, children: [String] = [], running: [RelayJSON] = [], ended: Int = 0, rows: [RelayJSON] = [], pause: Bool = false, resume: Bool = false, seq: Int = 10, revision: Int? = nil, epoch: String = "host-epoch") -> RelayJSON {
        .object(["goal": goal, "subagents": .object(["revision": .int(seq), "childSessionIds": .array(children.map(RelayJSON.string)), "running": .array(running), "endedTotal": .int(ended)]), "rows": .object(["window": .array(rows)]), "availability": .object(["pauseGoal": .object(["allowed": .bool(pause)]), "resumeGoal": .object(["allowed": .bool(resume)])]), "revision": .int(revision ?? seq), "seq": .int(seq), "logEpoch": .string(epoch)])
    }
    static func json(_ value: RelayJSON) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: value.data()) }
    static func projection(_ activity: RelayJSON) throws -> RelayConversationProjection {
        var raw = try activity.requiringObject()
        raw["protocolVersion"] = .int(1); raw["sessionId"] = .string("S")
        return try .init(raw: .object(raw))
    }
    @MainActor static func detail(_ activity: JSONValue?) -> JSONValue {
        var value: [String: JSONValue] = ["session": TestTransport.session(), "messages": .array([]), "pendingInteractions": .array([])]
        if let activity { value["hostActivity"] = activity }
        return .object(value)
    }
    @MainActor static func install(_ activity: RelayJSON?, store: AppStore) async throws {
        let value = try activity.map(json)
        TestTransport.handler = { request in request.path == "v1/sessions/S" ? detail(value) : nil }
        await store.loadTranscript("S")
    }
    @MainActor static func emit(_ value: RelayJSON) async throws {
        try await TestTransport.emit(["hostActivity": try json(value)], type: "host.activity")
    }
    @MainActor static func visible(_ store: AppStore) -> Bool { store.goals["S"] != nil || store.agentCount("S") > 0 }

    static func directory(_ items: [RelayJSON], nextCursor: String? = nil) throws -> RelaySubagentDirectory {
        try .init(raw: .object(["revision": .int(20), "childSessionIds": .array(items.compactMap { $0["childSessionId"].string }.map(RelayJSON.string)),
            "running": .array([]), "ended": .object(["total": .int(items.count), "items": .array(items), "nextCursor": nextCursor.map(RelayJSON.string) ?? .null])]))
    }
    static func endedRecord(_ id: String, title: String, status: String = "success") throws -> RelayJSON {
        var fields = try agent(id, title: title, status: status).requiringObject()
        fields["summary"] = .string("主机摘要：" + title)
        fields["startedAt"] = .number(1_000_000); fields["endedAt"] = .number(1_060_000)
        return .object(fields)
    }
    @MainActor static func childDetail(_ id: String, title: String = "Loaded child") -> JSONValue {
        var child = TestTransport.session(id, status: "completed", title: title).objectValue!
        child["source"] = .string("official-relay-subagent")
        child["capabilities"] = .object(["read": .bool(true), "send": .bool(false), "stop": .bool(false), "approve": .bool(false),
            "changes": .bool(false), "markUnread": .bool(false), "fork": .bool(false), "rename": .bool(false), "pin": .bool(false), "archive": .bool(false)])
        return .object(["session": .object(child), "messages": .array([TestTransport.message("Synthetic retained child history")]),
            "pendingInteractions": .array([]), "hostActivity": .object(["goal": .null, "subagents": .object(["childSessionIds": .array([]), "running": .array([]), "endedTotal": .number(0)])])])
    }
    @MainActor static func waitFor(_ value: () -> Bool) async throws {
        for _ in 0..<10_000 { if value() { return }; await Task.yield() }
        throw TestFailure(message: "Bounded wait for synthetic activity lifecycle expired")
    }
    @MainActor static func relayReady() async throws {
        let expected = RelayWorkspaceProbe.count("adapter", device: "activity-device")
        try await waitFor { (TestTransport.eventSubscriptions[ActivityRelayFixture.host] ?? 0) >= expected && TestTransport.subscribers[ActivityRelayFixture.host] != nil }
        try await TestTransport.emit(["connectionStatus": .string("connected")], host: ActivityRelayFixture.host, type: "ready")
    }

    @MainActor static func main() async throws {
        await run("fresh non-reference store has no activity entry points") {
            let f = Fixture(); defer { f.close() }
            try check(!visible(f.store) && f.store.agentTasks.isEmpty && f.store.hostGoals.isEmpty, "fresh store fabricated activity")
        }
        await run("detail without activity removes old goal and agents") {
            let f = Fixture(); defer { f.close() }; await f.connect()
            try await install(activity(goal: goal(), children: ["A"], running: [agent("A")]), store: f.store)
            try await install(nil, store: f.store)
            try check(!visible(f.store) && f.store.hostGoals["S"] == nil && f.store.hostAgents["S"] == nil && f.store.agentTasks["S"] == nil, "absent activity retained state")
        }
        await run("only host goal activates only the goal entry point") {
            let f = Fixture(); defer { f.close() }; await f.connect()
            try await install(activity(goal: goal()), store: f.store)
            try check(f.store.goals["S"]?.text == "Host objective" && f.store.agentCount("S") == 0 && f.store.agentTasks["S"] == nil, "goal-only projection created agents")
        }
        await run("only host agents activate only the agents entry point") {
            let f = Fixture(); defer { f.close() }; await f.connect()
            try await install(activity(children: ["A"], running: [agent("A")]), store: f.store)
            try check(f.store.goals["S"] == nil && f.store.agentCount("S") == 1 && f.store.agentTasks["S"]?.first?.status == .running, "agent-only projection created a goal or wrong count")
        }
        await run("empty host collections do not activate entry points") {
            let f = Fixture(); defer { f.close() }; await f.connect()
            try await install(activity(), store: f.store)
            try check(!visible(f.store) && f.store.agentTasks["S"] == nil, "empty collections were visible")
        }
        await run("host removal event clears both activity models") {
            let f = Fixture(); defer { f.close() }; await f.connect()
            try await install(activity(goal: goal(), children: ["A"], running: [agent("A")]), store: f.store)
            try await emit(activity(seq: 11))
            try check(!visible(f.store) && f.store.hostGoals["S"] == nil && f.store.agentTasks["S"] == nil, "host removal did not clear observable UI models")
        }
        await run("host removes goal while retaining agents") {
            let f = Fixture(); defer { f.close() }; await f.connect()
            try await install(activity(goal: goal(), children: ["A"], running: [agent("A")]), store: f.store)
            try await emit(activity(children: ["A"], running: [agent("A")], seq: 11))
            try check(f.store.goals["S"] == nil && f.store.agentCount("S") == 1, "independent goal removal removed or retained wrong collection")
        }
        await run("host removes agents while retaining goal") {
            let f = Fixture(); defer { f.close() }; await f.connect()
            try await install(activity(goal: goal(), children: ["A"], running: [agent("A")]), store: f.store)
            try await emit(activity(goal: goal(), seq: 11))
            try check(f.store.goals["S"] != nil && f.store.agentCount("S") == 0 && f.store.agentTasks["S"] == nil, "independent agent removal removed or retained wrong collection")
        }
        let statuses = [("active", "正在追求目标", true), ("paused", "已暂停的目标", false), ("verifying", "正在验证目标", true), ("verified", "已完成的目标", false), ("notSatisfied", "正在继续目标", true), ("failed", "目标遇到问题", false)]
        for (status, title, active) in statuses {
            await run("host goal status \(status) controls title, timer and allowed action") {
                let f = Fixture(); defer { f.close() }; await f.connect()
                try await install(activity(goal: goal(status), pause: active, resume: !active), store: f.store)
                try check(f.store.goalTitle("S") == title && f.store.goals["S"]?.isPaused == !active, "status title/play/pause mismatch")
                try check(f.store.goalElapsed("S", at: Date(timeIntervalSince1970: 1_010)) == (active ? "0小时1分钟10秒" : "0小时1分钟0秒"), "inactive timer advanced or active timer stopped")
                try check(f.store.canToggleGoal("S"), "host-allowed action was disabled")
            }
        }
        for status in ["active", "paused"] {
            await run("\(status) goal with unavailable action sends no command") {
                let f = Fixture(); defer { f.close() }; await f.connect()
                try await install(activity(goal: goal(status)), store: f.store)
                try check(!f.store.canToggleGoal("S"), "unavailable goal action appears enabled")
                await f.store.toggleGoal("S")
                try check(!TestTransport.requests.contains { $0.path.contains("/goal/") }, "unavailable action reached transport")
            }
        }
        for (status, command) in [("active", "pause"), ("paused", "resume")] {
            await run("\(status) goal sends only host-allowed \(command) command") {
                let f = Fixture(); defer { f.close() }; await f.connect()
                let initial = activity(goal: goal(status), pause: command == "pause", resume: command == "resume")
                try await install(initial, store: f.store)
                TestTransport.handler = { r in
                    if r.path.contains("/goal/") { return .object(["accepted": .bool(true)]) }
                    return r.path == "v1/sessions/S" ? detail(try json(initial)) : nil
                }
                await f.store.toggleGoal("S")
                try check(TestTransport.requests.filter { $0.path.contains("/goal/") }.map(\.path) == ["v1/sessions/S/goal/\(command)"], "wrong goal command emitted")
                try check(f.store.goals["S"]?.isPaused == (status == "paused"), "ACK alone changed host lifecycle")
            }
        }
        await run("in-flight goal command is disabled and cannot be submitted twice") {
            let f = Fixture(); defer { f.close() }; await f.connect()
            let initial = activity(goal: goal(), pause: true)
            try await install(initial, store: f.store)
            let gate = Gate()
            TestTransport.handler = { r in
                if r.path.contains("/goal/") { await gate.hold(); return .object(["accepted": .bool(false)]) }
                return r.path == "v1/sessions/S" ? detail(try json(initial)) : nil
            }
            let task = Task { await f.store.toggleGoal("S") }
            try await gate.waitUntilEntered()
            let enabled = f.store.canToggleGoal("S")
            await f.store.toggleGoal("S")
            gate.release(); await task.value
            try check(!enabled && TestTransport.requests.filter { $0.path.contains("/goal/") }.count == 1, "duplicate command escaped in-flight guard")
            try check(f.store.changingGoals.isEmpty && f.store.goals["S"]?.isPaused == false, "rejected command changed host state or stayed pending")
        }
        await run("ended agents retain host history and unique row identities") {
            let f = Fixture(); defer { f.close() }; await f.connect()
            try await install(activity(children: ["A", "A", "B"], running: [agent("A")], ended: 1, rows: [row("B", title: "Old title"), row("B", rowID: 2, title: "Final title")]), store: f.store)
            try check(f.store.agentCount("S") == 2 && f.store.agentTasks["S"]?.count == 2, "child list duplicates inflated count or rows")
            let ended = f.store.agentTasks["S"]?.first { $0.id == "B" }
            try check(ended?.title == "Final title" && ended?.status == .completed && ended?.detail == "Host final summary", "last host history row was not retained")
        }
        await run("ended total without child details is visible without fabricating rows") {
            let f = Fixture(); defer { f.close() }; await f.connect()
            try await install(activity(ended: 3), store: f.store)
            try check(f.store.agentCount("S") == 3 && f.store.agentTasks["S"]?.isEmpty == true, "history-only count or unknown child boundary changed")
        }
        await run("duplicate running child identities do not inflate the displayed agent count") {
            let f = Fixture(); defer { f.close() }; await f.connect()
            try await install(activity(children: ["A"], running: [agent("A"), agent("A")]), store: f.store)
            try check(f.store.agentCount("S") == 1 && f.store.agentTasks["S"]?.count == 1, "same child renders one row but count=\(f.store.agentCount("S"))")
        }
        await run("relay activity mapping preserves ended agent title status and summary") {
            let f = Fixture(); defer { f.close() }; await f.connect()
            let raw = activity(children: ["B"], ended: 1, rows: [row("B")])
            let mapped = RelayBridgeMapping.activity(try projection(raw))
            try await install(mapped, store: f.store)
            let ended = f.store.agentTasks["S"]?.first
            try check(ended?.title == "Ended host agent" && ended?.status == .completed && ended?.detail == "Host final summary", "relay mapping lost ended row; observed title=\(ended?.title ?? "nil"), status=\(ended?.status.rawValue ?? "nil")")
        }
        await run("older already-in-flight detail cannot resurrect removed activity") {
            let f = Fixture(); defer { f.close() }; await f.connect()
            let old = activity(goal: goal(), children: ["A"], running: [agent("A")], seq: 10)
            try await install(old, store: f.store)
            let gate = Gate()
            TestTransport.handler = { r in if r.path == "v1/sessions/S" { await gate.hold(); return detail(try json(old)) }; return nil }
            let task = Task { await f.store.loadTranscript("S") }
            try await gate.waitUntilEntered()
            try await emit(activity(seq: 11))
            gate.release(); await task.value
            try check(!visible(f.store), "request sent before removal overwrote its newer event")
        }
        await run("lower-sequence snapshot requested after removal cannot resurrect activity") {
            let f = Fixture(); defer { f.close() }; await f.connect()
            let old = activity(goal: goal(), children: ["A"], running: [agent("A")], seq: 10)
            try await install(old, store: f.store)
            try await emit(activity(seq: 11))
            try await install(old, store: f.store)
            try check(!visible(f.store), "seq 10 detail resurrected state after seq 11 removal")
        }
        await run("lower-sequence activity event cannot resurrect removed activity") {
            let f = Fixture(); defer { f.close() }; await f.connect()
            try await install(activity(seq: 11), store: f.store)
            try await emit(activity(goal: goal(), children: ["A"], running: [agent("A")], seq: 10))
            try check(!visible(f.store), "seq 10 event resurrected state after seq 11 detail")
        }
        await run("new host epoch may start a new goal at a lower sequence") {
            let f = Fixture(); defer { f.close() }; await f.connect()
            try await install(activity(seq: 100), store: f.store)
            try await emit(activity(goal: goal(objective: "New host epoch"), seq: 1, epoch: "replacement-epoch"))
            try check(f.store.goals["S"]?.text == "New host epoch", "valid new epoch rejected for lower sequence")
        }
        await run("retired host epoch cannot restore activity even with a higher sequence") {
            let f = Fixture(); defer { f.close() }; await f.connect()
            try await install(activity(goal: goal(), seq: 100, epoch: "retired-epoch"), store: f.store)
            try await emit(activity(seq: 1, epoch: "current-epoch"))
            try await emit(activity(goal: goal(objective: "Retired goal"), seq: 101, epoch: "retired-epoch"))
            try check(!visible(f.store), "retired epoch was treated as another new host epoch")
        }
        await run("same-sequence lower host revision cannot restore removed activity") {
            let f = Fixture(); defer { f.close() }; await f.connect()
            try await install(activity(seq: 10, revision: 3), store: f.store)
            try await emit(activity(goal: goal(), seq: 10, revision: 2))
            try check(!visible(f.store), "same-sequence older revision resurrected activity")
        }
        await run("same-sequence higher host revision may update activity") {
            let f = Fixture(); defer { f.close() }; await f.connect()
            try await install(activity(seq: 10, revision: 3), store: f.store)
            try await emit(activity(goal: goal(objective: "New revision"), seq: 10, revision: 4))
            try check(f.store.goals["S"]?.text == "New revision", "same-sequence newer revision was discarded")
        }
        await run("switching connected host clears prior host activity") {
            let f = Fixture(); defer { f.close() }; await f.connect()
            try await install(activity(goal: goal(), children: ["A"], running: [agent("A")]), store: f.store)
            TestTransport.handler = nil
            await f.store.connect(ConnectionProfile(id: "B", name: "Synthetic B", baseURL: "https://b.invalid"), token: "synthetic")
            try check(!visible(f.store) && f.store.hostGoals.isEmpty && f.store.hostAgents.isEmpty, "host A activity leaked into host B")
        }
        await run("removing active connection clears its goal and agent entry points") {
            let f = Fixture(); defer { f.close() }; await f.connect()
            try await install(activity(goal: goal(), children: ["A"], running: [agent("A")]), store: f.store)
            f.store.removeConnection(f.profile)
            try check(!visible(f.store) && f.store.hostGoals.isEmpty && f.store.hostAgents.isEmpty, "deleted host still has goal/agent state")
        }
        await run("late goal command response after host switch cannot restore old activity") {
            let f = Fixture(); defer { f.close() }; await f.connect()
            try await install(activity(goal: goal(), pause: true), store: f.store)
            let gate = Gate()
            TestTransport.handler = { r in if r.path.contains("/goal/") { await gate.hold(); return .object(["accepted": .bool(true)]) }; return nil }
            let task = Task { await f.store.toggleGoal("S") }
            try await gate.waitUntilEntered()
            await f.store.connect(ConnectionProfile(id: "B", name: "Synthetic B", baseURL: "https://b.invalid"), token: "synthetic")
            gate.release(); await task.value
            try check(!visible(f.store) && f.store.changingGoals.isEmpty, "old goal command wrote across connection epoch")
            try check(!TestTransport.requests.contains { $0.host == "b.invalid" && $0.path == "v1/sessions/S" }, "old command refreshed session on replacement host")
        }
        await run("official ended directory supplies all 13 distinct names states and summaries without transcript rows") {
            let f = Fixture(); defer { f.close() }; await f.connect()
            let names = ["核对需求", "审查连接协议", "检查文件路径", "梳理错误恢复", "验证历史分页", "检查附件事务", "复核会话权限", "验证命令回执", "检查目录状态", "复核取消边界", "核对重连顺序", "审查存储隔离", "整理验收证据"]
            let states = ["success", "failed", "cancelled", "lost"]
            let records = try names.enumerated().map { try endedRecord("ended-\($0.offset)", title: $0.element, status: states[$0.offset % states.count]) }
            let mapped = RelayBridgeMapping.activity(try projection(activity()), directory: try directory(records))
            try await install(mapped, store: f.store)
            let tasks = f.store.agentTasks["S"] ?? []
            try check(tasks.count == 13 && f.store.agentCount("S") == 13, "Ended directory was truncated or used a fixed count")
            for (index, name) in names.enumerated() {
                let expectedStatus: SessionStatus = index % 4 == 0 ? .completed : index % 4 == 1 ? .failed : .idle
                let label = ["已完成", "失败", "已取消", "已中断"][index % 4]
                let task = tasks.first { $0.id == "ended-\(index)" }
                try check(task?.title == name && task?.detail == "主机摘要：" + name && task?.status == expectedStatus && task?.statusText == label, "Ended record \(index) lost its exact title/status/summary")
            }
            try check(f.store.hostAgents["S"]?.ended.allSatisfy { $0.endedAt == 1_060_000 } == true, "Ended timestamps were discarded")
            try check(mapped["rows"]["window"].array?.isEmpty == true && f.store.messages("S").isEmpty, "Directory entries were fabricated as transcript rows/messages")
        }
        await run("unrecognized host agent state remains explicit and is never labeled ready or complete") {
            let f = Fixture(); defer { f.close() }; await f.connect()
            let record = try endedRecord("unknown-child", title: "新状态任务", status: "futureHostState")
            let mapped = RelayBridgeMapping.activity(try projection(activity()), directory: try directory([record]))
            try await install(mapped, store: f.store)
            let task = f.store.agentTasks["S"]?.first
            try check(task?.title == "新状态任务" && task?.status == .idle && task?.statusText == "状态待更新", "Unknown state was silently reclassified as ready or complete")
            try check(f.store.hostAgents["S"]?.ended.first?.status == "futureHostState", "Typed projection lost the original unknown state")
        }
        await run("official directory metadata wins over stale ended transcript metadata") {
            let f = Fixture(); defer { f.close() }; await f.connect()
            let record = try endedRecord("child-A", title: "目录最终标题", status: "cancelled")
            let mapped = RelayBridgeMapping.activity(try projection(activity(children: ["child-A"], rows: [row("child-A", title: "旧历史标题")])), directory: try directory([record]))
            try await install(mapped, store: f.store)
            let task = f.store.agentTasks["S"]?.first
            try check(task?.title == "目录最终标题" && task?.statusText == "已取消" && task?.detail == "主机摘要：目录最终标题", "Stale row replaced the official directory record")
        }
        await run("opening and reading a real-source child uses a separate read-only cache without adding a Home task") {
            let f = Fixture(); defer { f.close() }; await f.connect()
            let mapped = RelayBridgeMapping.activity(try projection(activity()), directory: try directory([try endedRecord("child-A", title: "主机子任务")]))
            try await install(mapped, store: f.store)
            let originalHomeIDs = f.store.sessions.map(\.id)
            let task = f.store.agentTasks["S"]!.first!
            f.store.openAgent(task, parentID: "S")
            try check(f.store.currentSessionID == task.id && f.store.sessions.map(\.id) == originalHomeIDs, "Opening an agent inserted it into Home")
            let opened = f.store.session(task.id)
            try check(opened?.title == task.title && opened?.canControl == false && opened?.source == "official-relay-subagent", "Opened child cache fabricated ordinary task permissions")
            TestTransport.handler = { request in request.path == "v1/sessions/child-A" ? childDetail("child-A", title: "读回子任务") : nil }
            await f.store.loadTranscript(task.id)
            try check(f.store.session(task.id)?.title == "读回子任务" && f.store.messages(task.id).first?.text == "Synthetic retained child history", "Child snapshot did not update its separate cache/history")
            try check(f.store.sessions.map(\.id) == originalHomeIDs && f.store.session(task.id)?.canControl == false, "Child detail polluted Home or became writable")
            await f.store.refresh()
            try check(f.store.sessions.map(\.id) == originalHomeIDs && f.store.session(task.id)?.title == "读回子任务", "Normal index refresh lost or promoted the child cache")
        }
        await run("unlisted agent IDs cannot open and a child cache cannot appear on a different computer") {
            let f = Fixture(); defer { f.close() }; await f.connect()
            let mapped = RelayBridgeMapping.activity(try projection(activity()), directory: try directory([try endedRecord("child-A", title: "主机 A 子任务")]))
            try await install(mapped, store: f.store)
            let unlisted = AgentTask(id: "guessed-child", title: "Guessed", status: .idle, detail: "", colorIndex: 0)
            f.store.openAgent(unlisted, parentID: "S")
            try check(f.store.path.isEmpty && f.store.session("guessed-child") == nil, "Unlisted child received a navigation/cache entry")
            f.store.openAgent(f.store.agentTasks["S"]!.first!, parentID: "S")
            TestTransport.handler = nil
            let other = ConnectionProfile(id: "B", name: "Synthetic B", baseURL: "https://b.invalid")
            f.store.profiles.append(other)
            await f.store.switchComputer(other)
            try check(f.store.activeProfileID == other.id && f.store.connection.isOnline, "Saved B fixture did not complete its connection")
            try check(f.store.session("child-A") == nil && f.store.path.isEmpty, "A child cache appeared under B's scope")
            try check(!TestTransport.requests.contains { $0.host == "b.invalid" && $0.path == "v1/sessions/child-A" }, "Switching hosts read the old child on B")
        }
        await run("automatic Relay restoration primes the parent before requesting the retained child") {
            let f = try ActivityRelayFixture(); defer { f.close() }
            await f.store.start(); try await relayReady()
            let mapped = RelayBridgeMapping.activity(try projection(activity()), directory: try directory([try endedRecord("child-A", title: "恢复中的主机子任务")]))
            var primedGeneration = 0
            TestTransport.handler = { request in
                if request.path == "v1/sessions/S" {
                    primedGeneration = RelayWorkspaceProbe.count("adapter", device: "activity-device")
                    return detail(try json(mapped))
                }
                if request.path == "v1/sessions/child-A" {
                    guard primedGeneration == RelayWorkspaceProbe.count("adapter", device: "activity-device") else { throw TestFailure(message: "Cold child was requested before its parent authorized the new adapter") }
                    return childDetail("child-A", title: "Generation \(primedGeneration)")
                }
                return nil
            }
            await f.store.loadTranscript("S")
            f.store.openAgent(f.store.agentTasks["S"]!.first!, parentID: "S")
            await f.store.loadTranscript("child-A")
            let recoveryStart = TestTransport.requests.count
            TestTransport.eventExitHandler = { _ in throw RelayFailure("relay_transport_failed", "Synthetic connection interrupted") }
            TestTransport.subscribers[ActivityRelayFixture.host]?.finish()
            try await waitFor { RelayWorkspaceProbe.count("adapter", device: "activity-device") == 2 && primedGeneration == 2 && f.store.connection.isOnline }
            try await relayReady()
            try await waitFor { f.store.session("child-A")?.title == "Generation 2" }
            let reads = TestTransport.requests.dropFirst(recoveryStart).filter { ["v1/sessions/S", "v1/sessions/child-A"].contains($0.path) }
            try check(reads.map(\.path) == ["v1/sessions/S", "v1/sessions/child-A"], "Retained child recovery did not read parent then child exactly once")
            try check(f.store.currentSessionID == "child-A" && f.store.session("child-A")?.canControl == false && f.store.messages("child-A").first?.text == "Synthetic retained child history", "Restoration lost the child page or its read-only snapshot")
            try check(f.store.sessions.map(\.id) == ["S"] && TestTransport.requests.dropFirst(recoveryStart).allSatisfy { $0.method == "GET" }, "Child restoration registered a Home task or sent a mutation")
            try check(RelayWorkspaceProbe.count("pair", device: "activity-device") == 2 && f.store.errorMessage == nil, "Restoration duplicated pairing or hid a parent-scope error")
        }
        let failed = results.filter { !$0.passed }.count
        let report = ActivityReport(cases: results.count, passed: results.count - failed, failed: failed, assertions: assertions, results: results)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        print("RESULT \(report.passed)/\(report.cases) passed; \(assertions) assertions")
        if failed > 0 { exit(1) }
    }
}
struct ActivityReport: Codable { let cases: Int; let passed: Int; let failed: Int; let assertions: Int; let results: [TestResult] }

@MainActor private final class ActivityRelayFixture {
    static let host = "relay:activity-device:/synthetic"
    let suite = "dev.paco.activity-relay.\(UUID().uuidString)"
    let defaults: UserDefaults
    let store: AppStore
    init() throws {
        defaults = UserDefaults(suiteName: suite)!
        let profile = ConnectionProfile(id: "activity-A", name: "Synthetic activity host", baseURL: "https://zcode.z.ai/remote/v4", relayDeviceID: "activity-device", relayWorkspaceKey: "/synthetic")
        defaults.set(try JSONEncoder().encode([profile]), forKey: "connections")
        defaults.set(profile.id, forKey: "activeConnection"); defaults.set(true, forKey: "hasConnectedBefore")
        CredentialStore.values[profile.id] = "https://zcode.z.ai/remote/v4?sid=activity-device&hash=synthetic-fixture-only-0000000000000000&name=Synthetic&app_version=fixture"
        RelayWorkspaceProbe.listings["activity-device"] = .init(windowControlSessionId: "activity-fixture-control", workspaces: [
            .init(kind: "local", workspacePath: "/synthetic", workspaceIdentity: nil, remoteSessionId: nil, connectionState: "connected", lastConnectionError: nil)
        ], tasks: [], initialViewState: nil, mobileViewState: nil, activeWorkspaceKey: nil, activeTaskId: nil)
        store = AppStore(defaults: defaults, reconnectDelay: { _ in try Task.checkCancellation() })
    }
    func close() { store.disconnect(); defaults.removePersistentDomain(forName: suite) }
}
