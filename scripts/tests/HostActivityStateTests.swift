import Foundation

// These adapters prohibit the real relay path. Activity DTOs, mapping and reducers
// are production code; pairing, sockets, RPC and credentials are never exercised.
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

@main struct HostActivityStateTests {
    @MainActor static var results: [TestResult] = []
    @MainActor static var assertions = 0
    @MainActor static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        assertions += 1
        if try !condition() { throw TestFailure(message: message) }
    }
    @MainActor static func run(_ name: String, _ body: () async throws -> Void) async {
        TestTransport.reset()
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
        let failed = results.filter { !$0.passed }.count
        let report = ActivityReport(cases: results.count, passed: results.count - failed, failed: failed, assertions: assertions, results: results)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        print("RESULT \(report.passed)/\(report.cases) passed; \(assertions) assertions")
        if failed > 0 { exit(1) }
    }
}
struct ActivityReport: Codable { let cases: Int; let passed: Int; let failed: Int; let assertions: Int; let results: [TestResult] }
