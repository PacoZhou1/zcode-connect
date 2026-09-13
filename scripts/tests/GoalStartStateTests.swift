import Foundation

@MainActor private final class GoalStartFixture {
    let suite = "dev.paco.goal-start.\(UUID().uuidString)"
    let defaults: UserDefaults
    let profile = ConnectionProfile(id: "goal-A", name: "Synthetic goal host", baseURL: "https://zcode.z.ai/remote/v4",
                                    relayDeviceID: "goal-device", relayWorkspaceKey: "/synthetic")
    let store: AppStore
    var scope: String { "\(profile.id)|\(profile.baseURL)" }
    init() throws {
        defaults = UserDefaults(suiteName: suite)!
        defaults.set(try JSONEncoder().encode([profile]), forKey: "connections")
        defaults.set(profile.id, forKey: "activeConnection")
        defaults.set(true, forKey: "hasConnectedBefore")
        CredentialStore.values[profile.id] = "https://zcode.z.ai/remote/v4?sid=goal-device&hash=synthetic-fixture-only-0000000000000000&name=Synthetic&app_version=fixture"
        store = AppStore(defaults: defaults)
    }
    func close() { store.disconnect(); defaults.removePersistentDomain(forName: suite) }
}

@main struct GoalStartStateTests {
    @MainActor static var results: [TestResult] = []
    @MainActor static var assertions = 0
    @MainActor static func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        assertions += 1
        if try !value() { throw TestFailure(message: message) }
    }
    @MainActor static func journal() -> GoalSubmissionJournal {
        .init(directory: OutboxTestSandbox.directory.appendingPathComponent("pending-goals"))
    }
    @MainActor static func failure(_ code: String, _ work: () async throws -> Void) async throws {
        do { try await work() }
        catch {
            let actual = (error as? BridgeFailure)?.code ?? (error as? RelayFailure)?.code
            try check(actual == code, "Expected \(code), received \(actual ?? String(describing: error))")
            return
        }
        throw TestFailure(message: "Expected \(code), but goal operation succeeded")
    }
    @MainActor static func base(_ request: TestRequest) -> JSONValue? {
        if request.path.hasPrefix("v1/sessions?") {
            return .object(["sessions": .array([TestTransport.session("S"), TestTransport.session("T")])])
        }
        let components = request.path.split(separator: "/")
        if request.method == "GET", components.count == 3, components[0] == "v1", components[1] == "sessions" {
            return .object(["session": TestTransport.session(String(components[2])), "messages": .array([]), "pendingInteractions": .array([])])
        }
        return nil
    }
    @MainActor private static func fixture() async throws -> GoalStartFixture {
        let f = try GoalStartFixture()
        RelayWorkspaceProbe.listings["goal-device"] = .init(windowControlSessionId: "synthetic-goal-control", workspaces: [
            .init(kind: "local", workspacePath: "/synthetic", workspaceIdentity: nil, remoteSessionId: nil,
                  connectionState: "connected", lastConnectionError: nil)
        ], tasks: [], initialViewState: nil, mobileViewState: nil, activeWorkspaceKey: nil, activeTaskId: nil)
        TestTransport.handler = { base($0) }
        await f.store.start()
        try check(f.store.connection.isOnline && f.store.selectedProjectID == "P", "Synthetic Relay fixture did not connect")
        TestTransport.requests = []
        return f
    }
    @MainActor static func goalRequests() -> [TestRequest] { TestTransport.requests.filter { $0.path.hasSuffix("/goal/start") } }
    @MainActor static func creationRequests() -> [TestRequest] { TestTransport.requests.filter { $0.method == "POST" && $0.path == "v1/sessions" } }
    @MainActor static func run(_ name: String, _ body: () async throws -> Void) async {
        for _ in 0..<150 { await Task.yield() }
        TestTransport.reset(); RelayWorkspaceProbe.reset()
        OutboxTestSandbox.directory = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(UUID().uuidString)
        do { try await body(); results.append(.init(name: name, passed: true, detail: "all assertions passed")); print("PASS \(name)") }
        catch { let detail = (error as? TestFailure)?.message ?? String(describing: error); results.append(.init(name: name, passed: false, detail: detail)); print("FAIL \(name): \(detail)") }
    }

    @MainActor static func main() async throws {
        await run("existing session sends the exact goal route only after its command ID is durable") {
            let f = try await fixture(); defer { f.close() }
            TestTransport.handler = { request in
                if request.path == "v1/sessions/S/goal/start" {
                    let pending = try journal().read(scope: f.scope)["S"]
                    try check(pending?.sessionID == "S" && pending?.text == "Existing goal", "Goal payload was not durable before network")
                    try check(request.body == ["text": .string("Existing goal"), "clientGoalId": .string(pending!.id)], "Goal route changed its durable body")
                    return .object(["accepted": .bool(true)])
                }
                return base(request)
            }
            try await f.store.startGoal("  Existing goal\n", sessionID: "S")
            try check(goalRequests().count == 1 && creationRequests().isEmpty, "Existing goal created another session or sent multiple commands")
            try check(try journal().read(scope: f.scope).isEmpty && f.store.currentSessionID == "S", "Accepted goal did not settle its journal and open the session")
            try check(f.store.goals["S"] == nil, "Accepted ACK fabricated a local host goal")
        }
        await run("new goal persists creation identity and actual created session before sending the goal") {
            let f = try await fixture(); defer { f.close() }
            TestTransport.handler = { request in
                if request.path == "v1/sessions", request.method == "POST" {
                    let pending = try journal().read(scope: f.scope)["new:P"]!
                    try check(pending.sessionID == nil && request.body == pending.creation, "Creation payload was not persisted before create")
                    try check(request.body["clientDraftId"] == .string("goal-session-" + pending.id), "Creation did not derive a stable idempotency key")
                }
                if request.path.hasSuffix("/goal/start") {
                    let pending = try journal().read(scope: f.scope)["new:P"]!
                    try check(pending.sessionID == "created-1" && request.path == "v1/sessions/created-1/goal/start", "Created ID was not durable before goal command")
                    try check(request.body["clientGoalId"] == .string(pending.id), "Goal ID changed after creating the session")
                    return .object(["accepted": .bool(true)])
                }
                return base(request)
            }
            try await f.store.startGoal("New goal", sessionID: nil)
            try check(TestTransport.created == 1 && goalRequests().count == 1 && f.store.currentSessionID == "created-1", "New goal did not open its one actual session")
            try check(try journal().read(scope: f.scope).isEmpty, "Accepted new goal remained pending")
        }
        await run("lost creation ACK retries the frozen body and clientDraftId without creating a second session") {
            let f = try await fixture(); defer { f.close() }
            var first = true
            TestTransport.handler = { request in
                if request.path == "v1/sessions", request.method == "POST", first {
                    first = false
                    let draftID = request.body["clientDraftId"]!.stringValue!
                    TestTransport.created += 1; TestTransport.drafts[draftID] = "created-1"
                    throw BridgeFailure(message: "Synthetic creation ACK lost after admission", code: "draft_uncertain")
                }
                if request.path.hasSuffix("/goal/start") { return .object(["accepted": .bool(true)]) }
                return base(request)
            }
            try await failure("draft_uncertain") { try await f.store.startGoal("Frozen create", sessionID: nil) }
            let pending = try journal().read(scope: f.scope)["new:P"]!
            try check(pending.sessionID == nil && goalRequests().isEmpty, "Lost creation ACK claimed an ID or sent a goal prematurely")
            f.store.options.permission = .automatic
            try await f.store.startGoal("Frozen create", sessionID: nil)
            let requests = creationRequests()
            try check(requests.count == 2 && requests[0].body == requests[1].body && requests[0].body == pending.creation, "Creation retry changed settings, title, or clientDraftId")
            try check(TestTransport.created == 1 && goalRequests().first?.body["clientGoalId"] == .string(pending.id), "Creation retry forked a second session or goal identity")
        }
        await run("unknown goal ACK survives recreation and rejects text edits while preserving the original ID") {
            let f = try await fixture(); defer { f.close() }
            TestTransport.handler = { request in
                if request.path.hasSuffix("/goal/start") { throw BridgeFailure(message: "Synthetic unknown goal ACK", code: "goal_start_uncertain") }
                return base(request)
            }
            try await failure("goal_start_uncertain") { try await f.store.startGoal("Original goal", sessionID: "S") }
            let original = try journal().read(scope: f.scope)["S"]!
            try await failure("goal_pending") { try await f.store.startGoal("Edited goal", sessionID: "S") }
            try check(goalRequests().count == 1 && !original.rejected, "Uncertain command became an editable/rejected submission")
            f.store.disconnect()
            let reopened = AppStore(defaults: f.defaults); defer { reopened.disconnect() }
            try check(reopened.pendingGoalText("S") == "Original goal", "Relaunch lost the frozen pending goal text")
            await reopened.connect(f.profile, confirmedControllerReplacement: true)
            TestTransport.handler = { request in request.path.hasSuffix("/goal/start") ? .object(["accepted": .bool(true)]) : base(request) }
            try await reopened.startGoal("Original goal", sessionID: "S")
            try check(goalRequests().count == 2 && goalRequests().allSatisfy { $0.body["clientGoalId"] == .string(original.id) && $0.body["text"] == .string(original.text) }, "Relaunch changed the uncertain goal ID or payload")
            try check(try journal().read(scope: f.scope).isEmpty, "Confirmed retry did not settle the original journal")
        }
        await run("definitive host rejection permits corrected text with a new clientGoalId") {
            let f = try await fixture(); defer { f.close() }
            TestTransport.handler = { request in
                if request.path.hasSuffix("/goal/start") { throw RelayFailure("goal_start_rejected", "Synthetic definitive admission rejection") }
                return base(request)
            }
            try await failure("goal_start_rejected") { try await f.store.startGoal("Rejected goal", sessionID: "S") }
            let rejected = try journal().read(scope: f.scope)["S"]!
            try check(rejected.rejected, "Definitive host refusal was not marked terminal")
            TestTransport.handler = { request in request.path.hasSuffix("/goal/start") ? .object(["accepted": .bool(true)]) : base(request) }
            try await f.store.startGoal("Corrected goal", sessionID: "S")
            let next = goalRequests().last!
            try check(next.body["clientGoalId"] != .string(rejected.id) && next.body["text"] == .string("Corrected goal"), "Explicit next submission reused a rejected ID or old text")
            try check(creationRequests().isEmpty && journal().read(scope: f.scope).isEmpty, "Corrected existing goal created a task or remained pending")
        }
        await run("created session can find and retry its original new-goal pending record after unknown ACK") {
            let f = try await fixture(); defer { f.close() }
            TestTransport.handler = { request in
                if request.path.hasSuffix("/goal/start") { throw BridgeFailure(message: "Synthetic uncertain goal result", code: "goal_start_uncertain") }
                return base(request)
            }
            try await failure("goal_start_uncertain") { try await f.store.startGoal("New uncertain goal", sessionID: nil) }
            let pending = try journal().read(scope: f.scope)["new:P"]!
            let id = pending.sessionID!
            await f.store.loadTranscript(id)
            try check(f.store.pendingGoalText(id) == pending.text && f.store.session(id) != nil, "Created session could not recover its new-project pending record")
            try await failure("goal_pending") { try await f.store.startGoal("Unexpected edit", sessionID: id) }
            TestTransport.handler = { request in request.path.hasSuffix("/goal/start") ? .object(["accepted": .bool(true)]) : base(request) }
            try await f.store.startGoal(pending.text, sessionID: id)
            try check(TestTransport.created == 1 && creationRequests().count == 1, "Opening the created session created another task")
            try check(goalRequests().count == 2 && goalRequests().allSatisfy { $0.body["clientGoalId"] == .string(pending.id) }, "Created-session retry used a second goal identity")
            try check(try journal().read(scope: f.scope).isEmpty, "Retry failed to settle the original new-project key")
        }
        await run("different sessions preserve both journal entries across concurrent accepted and unknown results") {
            let f = try await fixture(); defer { f.close() }
            let s = Gate(), t = Gate(); defer { s.release(); t.release() }
            TestTransport.handler = { request in
                if request.path == "v1/sessions/S/goal/start" { await s.hold(); return .object(["accepted": .bool(true)]) }
                if request.path == "v1/sessions/T/goal/start" { await t.hold(); throw BridgeFailure(message: "Synthetic T uncertainty", code: "goal_start_uncertain") }
                return base(request)
            }
            let first = Task { try await f.store.startGoal("Goal S", sessionID: "S") }; try await s.waitUntilEntered()
            let second = Task { try await f.store.startGoal("Goal T", sessionID: "T") }; try await t.waitUntilEntered()
            let both = try journal().read(scope: f.scope)
            try check(Set(both.keys) == ["S", "T"] && both["S"]?.id != both["T"]?.id, "Concurrent starts overwrote another pending record")
            s.release(); try await first.value
            try check(try journal().read(scope: f.scope) == ["T": both["T"]!], "Settling S discarded in-flight T")
            t.release(); try await failure("goal_start_uncertain") { try await second.value }
            try check(try journal().read(scope: f.scope) == ["T": both["T"]!], "Unknown T result changed its durable record")
        }
        await run("overlapping attempts for one session make only one goal request") {
            let f = try await fixture(); defer { f.close() }
            let gate = Gate(); defer { gate.release() }
            TestTransport.handler = { request in
                if request.path.hasSuffix("/goal/start") { await gate.hold(); return .object(["accepted": .bool(true)]) }
                return base(request)
            }
            let first = Task { try await f.store.startGoal("One goal", sessionID: "S") }; try await gate.waitUntilEntered()
            try await failure("goal_busy") { try await f.store.startGoal("One goal", sessionID: "S") }
            try check(goalRequests().count == 1, "Duplicate in-flight submit reached the host")
            gate.release(); try await first.value
        }
        for originalID: String? in ["S", nil] {
            await run("journal preflight write failure prevents network for \(originalID == nil ? "new" : "existing") goal") {
                let f = try await fixture(); defer { f.close() }
                try FileManager.default.createDirectory(at: OutboxTestSandbox.directory, withIntermediateDirectories: true)
                try Data("not a directory".utf8).write(to: journal().directory)
                var rejected = false
                do { try await f.store.startGoal("Cannot persist", sessionID: originalID) }
                catch { rejected = true }
                try check(rejected && TestTransport.requests.isEmpty, "Goal network mutation preceded a successful durable preflight")
            }
        }
        let passed = results.filter(\.passed).count
        let report = Report(passed: passed, failed: results.count - passed, assertions: assertions, results: results)
        try JSONEncoder().encode(report).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        print("\(passed)/\(results.count) passed; \(assertions) assertions; actual production Store with isolated goal journal and inert Relay")
        if passed != results.count { exit(1) }
    }
    struct Report: Codable { let passed: Int; let failed: Int; let assertions: Int; let results: [TestResult] }
}
