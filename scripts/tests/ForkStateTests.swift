import Foundation

@main struct ForkStateTests {
    @MainActor static var results: [TestResult] = []
    @MainActor static var assertions = 0
    static let profileB = ConnectionProfile(id: "B", name: "Synthetic B", baseURL: "https://b.invalid")
    @MainActor static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        assertions += 1; if try !condition() { throw TestFailure(message: message) }
    }
    @MainActor static func run(_ name: String, _ body: () async throws -> Void) async {
        TestTransport.reset()
        OutboxTestSandbox.directory = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(UUID().uuidString)
        do { try await body(); results.append(TestResult(name: name, passed: true, detail: "all assertions passed")); print("PASS \(name)") }
        catch { let detail = (error as? TestFailure)?.message ?? String(describing: error); results.append(TestResult(name: name, passed: false, detail: detail)); print("FAIL \(name): \(detail)") }
    }
    @MainActor static func session(_ id: String = "S") -> JSONValue {
        var fields = TestTransport.session(id).objectValue!
        fields["source"] = .string("official-relay")
        var capabilities = fields["capabilities"]!.objectValue!
        capabilities["fork"] = .bool(true); fields["capabilities"] = .object(capabilities)
        return .object(fields)
    }
    @MainActor static func listing() -> JSONValue { .object(["sessions": .array([session()])]) }
    @MainActor static func result(_ id: String) -> JSONValue { .object(["session": session(id), "forkedSessionId": .string(id)]) }
    @MainActor static func fixture() async -> Fixture {
        let f = Fixture()
        TestTransport.handler = { request in request.path.hasPrefix("v1/sessions?") ? listing() : nil }
        await f.connect(); f.store.profiles.append(profileB); TestTransport.requests.removeAll()
        return f
    }
    @MainActor static func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<10_000 { if condition() { return }; await Task.yield() }
        throw TestFailure(message: "Synthetic fork operation did not finish")
    }
    @MainActor static func journal() -> ForkJournal { ForkJournal(directory: OutboxTestSandbox.directory.appendingPathComponent("Forks")) }

    @MainActor static func main() async throws {
        await run("lost fork ACK survives reopen with identical UUID and message boundary") {
            let f = await fixture(); defer { f.close() }
            let target = MessageForkTarget(rowId: 17, entityId: "message-M")
            TestTransport.handler = { request in
                if request.path.hasSuffix("/fork") { throw BridgeFailure(message: "Synthetic lost ACK", code: "offline") }
                return request.path.hasPrefix("v1/sessions?") ? listing() : nil
            }
            f.store.forkSession("S", target: target)
            try await waitFor { !f.store.isForking("S") }
            let first = TestTransport.requests.first { $0.path.hasSuffix("/fork") }
            try check(first?.body["clientForkId"]?.stringValue.flatMap(UUID.init(uuidString:)) != nil, "Initial fork had no stable UUID")
            try check(first?.body["target"] == .object(["rowId": .number(17), "entityId": .string("message-M")]), "Initial boundary was changed")
            try check(f.store.path.isEmpty && f.store.errorMessage?.contains("Synthetic lost ACK") == true, "Uncertain fork reported success")
            try check(try journal().read(scope: "A|https://a.invalid")["S|17|message-M"]?.clientForkId == first?.body["clientForkId"]?.stringValue, "Fork command was not durable before retry")

            f.store.disconnect()
            let reopened = AppStore(defaults: f.defaults); defer { reopened.disconnect() }
            await reopened.connect(f.profile)
            TestTransport.handler = { request in
                if request.path.hasSuffix("/fork") { throw BridgeFailure(message: "Synthetic uncertain result", code: "fork_uncertain") }
                return nil
            }
            reopened.forkSession("S", target: target)
            try await waitFor { !reopened.isForking("S") }
            try check(try journal().read(scope: "A|https://a.invalid")["S|17|message-M"]?.clientForkId == first?.body["clientForkId"]?.stringValue, "Uncertain host result discarded the retry UUID")
            try check(reopened.path.isEmpty && reopened.errorMessage?.contains("Synthetic uncertain result") == true, "Uncertain host result reported success")
            TestTransport.handler = { request in request.path.hasSuffix("/fork") ? result("child-A") : nil }
            reopened.forkSession("S", target: target)
            try await waitFor { !reopened.isForking("S") }
            let requests = TestTransport.requests.filter { $0.path.hasSuffix("/fork") }
            try check(requests.count == 3 && requests.allSatisfy { $0.body == first?.body }, "Reopen or uncertain host result changed the fork UUID or boundary")
            try check(reopened.session("child-A") != nil && reopened.path == [.session("child-A")], "Confirmed fork did not navigate to its actual child")
            try check(try journal().read(scope: "A|https://a.invalid").isEmpty, "Successful fork command stayed pending")
        }
        await run("explicit fork rejection clears its journal and the next click uses a new UUID") {
            let f = await fixture(); defer { f.close() }
            TestTransport.handler = { request in
                if request.path.hasSuffix("/fork") { throw BridgeFailure(message: "Synthetic explicit refusal", code: "fork_rejected") }
                return nil
            }
            f.store.forkSession("S")
            try await waitFor { !f.store.isForking("S") }
            let first = TestTransport.requests.first { $0.path.hasSuffix("/fork") }
            try check(first?.body["clientForkId"]?.stringValue.flatMap(UUID.init(uuidString:)) != nil, "Rejected fork had no command UUID")
            try check(try journal().read(scope: "A|https://a.invalid").isEmpty, "Explicitly rejected fork remained pending")
            try check(f.store.path.isEmpty && f.store.errorMessage?.contains("电脑未创建分支") == true, "Explicit refusal was presented as success or an uncertain outcome")
            TestTransport.handler = { request in request.path.hasSuffix("/fork") ? result("child-new") : nil }
            f.store.forkSession("S")
            try await waitFor { !f.store.isForking("S") }
            let requests = TestTransport.requests.filter { $0.path.hasSuffix("/fork") }
            try check(requests.count == 2 && requests[0].body["clientForkId"] != requests[1].body["clientForkId"], "A new click replayed the explicitly rejected command UUID")
            try check(f.store.session("child-new") != nil && f.store.path == [.session("child-new")], "New confirmed fork did not open its actual child")
            try check(try journal().read(scope: "A|https://a.invalid").isEmpty, "Successful replacement fork remained pending")
        }
        await run("late A fork ACK cannot mutate B and B receives a distinct command ID") {
            let f = await fixture(); defer { f.close() }
            let gate = Gate(); defer { gate.release() }
            TestTransport.handler = { request in
                if request.path.hasPrefix("v1/sessions?") { return listing() }
                if request.path.hasSuffix("/fork") {
                    if request.host == "a.invalid" { await gate.hold(); return result("child-A") }
                    return result("child-B")
                }
                return nil
            }
            f.store.forkSession("S"); try await gate.waitUntilEntered()
            let first = TestTransport.requests.first { $0.path.hasSuffix("/fork") }!
            await f.store.switchComputer(profileB)
            try check(!f.store.isForking("S"), "A in-flight guard leaked into B")
            f.store.forkSession("S"); try await waitFor { !f.store.isForking("S") }
            let second = TestTransport.requests.last { $0.path.hasSuffix("/fork") }!
            try check(first.host == "a.invalid" && second.host == "b.invalid" && first.body["clientForkId"] != second.body["clientForkId"], "B inherited A's command UUID or destination")
            gate.release(); try await waitFor { !f.store.forksInFlight.contains("A|https://a.invalid|S") }
            try check(f.store.activeProfileID == "B" && f.store.session("child-A") == nil && f.store.session("child-B") != nil && f.store.path == [.session("child-B")], "Late A fork ACK contaminated B state or navigation")
            try check(try journal().read(scope: "A|https://a.invalid")["S|latest"]?.clientForkId == first.body["clientForkId"]?.stringValue, "Ignored A ACK lost A's retry identity")
            try check(try journal().read(scope: "B|https://b.invalid").isEmpty, "A pending command was written into B journal")
        }
        await run("fork queued before host switch makes no request and preserves only A journal") {
            let f = await fixture(); defer { f.close() }
            f.store.forkSession("S")
            await f.store.switchComputer(profileB)
            try await waitFor { f.store.forksInFlight.isEmpty }
            try check(!TestTransport.requests.contains { $0.path.hasSuffix("/fork") }, "Stale queued fork was transmitted")
            try check(f.store.activeProfileID == "B" && f.store.path.isEmpty, "Stale queued fork navigated in B")
            try check(try journal().read(scope: "A|https://a.invalid")["S|latest"] != nil && journal().read(scope: "B|https://b.invalid").isEmpty, "Unstarted A command was lost or crossed scopes")
        }
        let report: [String: JSONValue] = ["cases": .number(Double(results.count)), "passed": .number(Double(results.filter(\.passed).count)), "failed": .number(Double(results.filter { !$0.passed }.count)), "assertions": .number(Double(assertions))]
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(JSONValue.object(report))) as! [String: Any]
        object["results"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(results))
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        print("\(results.filter(\.passed).count)/\(results.count) passed; \(assertions) assertions; no real relay, network, Simulator or Keychain")
        if results.contains(where: { !$0.passed }) { exit(1) }
    }
}
