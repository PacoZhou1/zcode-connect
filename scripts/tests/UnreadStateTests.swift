import Foundation

@main struct UnreadStateTests {
    @MainActor static var results: [TestResult] = []
    @MainActor static var assertions = 0
    @MainActor static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        assertions += 1
        if try !condition() { throw TestFailure(message: message) }
    }
    @MainActor static func run(_ name: String, _ body: () async throws -> Void) async {
        TestTransport.reset()
        OutboxTestSandbox.directory = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(UUID().uuidString)
        do {
            try await body(); results.append(TestResult(name: name, passed: true, detail: "all assertions passed")); print("PASS \(name)")
        } catch {
            let detail = (error as? TestFailure)?.message ?? String(describing: error)
            results.append(TestResult(name: name, passed: false, detail: detail)); print("FAIL \(name): \(detail)")
        }
    }
    @MainActor static func session(unread: Bool, stamp: Double? = nil, markable: Bool = true) -> JSONValue {
        var fields = TestTransport.session().objectValue!
        fields["unread"] = .bool(unread)
        fields["unreadAt"] = stamp.map(JSONValue.number) ?? .null
        fields["unreadScope"] = .string(markable ? "bridge" : "desktop")
        fields["source"] = .string(markable ? "bridge" : "desktop")
        var capabilities = fields["capabilities"]!.objectValue!
        capabilities["markUnread"] = .bool(markable)
        capabilities["send"] = .bool(markable)
        fields["capabilities"] = .object(capabilities)
        return .object(fields)
    }
    @MainActor static func listing(_ value: JSONValue) -> JSONValue { .object(["sessions": .array([value])]) }
    @MainActor static func prepared(unread: Bool = true, stamp: Double? = 10, markable: Bool = true) async -> Fixture {
        let f = Fixture()
        TestTransport.handler = { r in r.path.hasPrefix("v1/sessions?") ? listing(session(unread: unread, stamp: stamp, markable: markable)) : nil }
        await f.connect(); TestTransport.requests.removeAll(); TestTransport.handler = nil
        return f
    }
    @MainActor static func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<10_000 { if condition() { return }; await Task.yield() }
        throw TestFailure(message: "Expected synthetic state did not settle")
    }
    // The production action intentionally returns Void. After the gated in-memory
    // response, drain the main actor so its unstructured action can finish.
    @MainActor static func drainActor() async { for _ in 0..<100 { await Task.yield() } }

    @MainActor static func main() async throws {
        await run("preview returns messages without clearing unread or changing stored transcript") {
            let f = await prepared(); defer { f.close() }
            let previous = f.store.messages("S")
            TestTransport.handler = { r in
                guard r.path == "v1/sessions/S" else { return nil }
                return .object(["session": session(unread: false, stamp: 10), "messages": .array([TestTransport.message("preview only")]), "pendingInteractions": .array([])])
            }
            let preview = try await f.store.previewMessages("S")
            try check(preview.map(\.text) == ["preview only"], "Preview content missing")
            try check(f.store.isUnread("S") && f.store.session("S")?.unreadAt == 10, "Preview applied read status from detail")
            try check(f.store.messages("S") == previous && f.store.path.isEmpty, "Preview changed transcript or navigation")
            try check(TestTransport.requests.count == 1 && TestTransport.requests[0].method == "GET", "Preview mutated remote state")
        }
        await run("mark read sends original expectedUnreadAt and waits for successful ACK") {
            let f = await prepared(stamp: 101.25); defer { f.close() }
            let gate = Gate(); defer { gate.release() }
            TestTransport.handler = { r in
                guard r.method == "PATCH" else { return nil }
                await gate.hold()
                return .object(["session": session(unread: false, stamp: 101.25)])
            }
            f.store.setUnread(false, sessionID: "S")
            try await gate.waitUntilEntered()
            let request = TestTransport.requests.first { $0.method == "PATCH" }
            try check(request?.body == ["unread": .bool(false), "expectedUnreadAt": .number(101.25)], "Read did not preserve original CAS timestamp")
            try check(f.store.isUnread("S"), "Unread was cleared optimistically before ACK")
            gate.release(); try await waitFor { !f.store.isUnread("S") }
            try check(f.store.session("S")?.unread == false, "Successful ACK did not update state")
        }
        await run("CAS response with newer unread remains unread without optimistic clearing") {
            let f = await prepared(stamp: 10); defer { f.close() }
            let gate = Gate(); var responded = false; defer { gate.release() }
            TestTransport.handler = { r in
                guard r.method == "PATCH" else { return nil }
                await gate.hold(); responded = true
                return .object(["session": session(unread: true, stamp: 20)])
            }
            f.store.setUnread(false, sessionID: "S")
            try await gate.waitUntilEntered()
            try check(f.store.isUnread("S"), "CAS request cleared state before response")
            try check(TestTransport.requests.first { $0.method == "PATCH" }?.body["expectedUnreadAt"] == .number(10), "CAS compared against a changed timestamp")
            gate.release(); try await waitFor { responded && f.store.session("S")?.unreadAt == 20 }
            try check(f.store.isUnread("S") && f.store.errorMessage == nil, "CAS-preserved unread became read or a fake error")
        }
        await run("SSE newer unread wins over a delayed older mark-read ACK") {
            let f = await prepared(stamp: 10); defer { f.close() }
            let gate = Gate(); var responded = false; defer { gate.release() }
            TestTransport.handler = { r in
                guard r.method == "PATCH" else { return nil }
                await gate.hold(); responded = true
                return .object(["session": session(unread: false, stamp: 10)])
            }
            f.store.setUnread(false, sessionID: "S")
            try await gate.waitUntilEntered()
            try await TestTransport.emit(["session": session(unread: true, stamp: 30)], type: "session.updated")
            gate.release(); try await waitFor { responded }; await drainActor()
            try check(f.store.isUnread("S") && f.store.session("S")?.unreadAt == 30, "Older ACK overwrote a newer SSE unread")
            try check(TestTransport.requests.first { $0.method == "PATCH" }?.body["expectedUnreadAt"] == .number(10), "SSE rewrote in-flight CAS payload")
        }
        await run("late mark-read ACK after host switch cannot clear another host") {
            let f = await prepared(stamp: 10); defer { f.close() }
            let gate = Gate(); var responded = false; defer { gate.release() }
            TestTransport.handler = { r in
                if r.host == "b.invalid", r.path.hasPrefix("v1/sessions?") { return listing(session(unread: true, stamp: 200)) }
                guard r.host == "a.invalid", r.method == "PATCH" else { return nil }
                await gate.hold(); responded = true
                return .object(["session": session(unread: false, stamp: 10)])
            }
            f.store.setUnread(false, sessionID: "S"); try await gate.waitUntilEntered()
            await f.store.connect(ConnectionProfile(id: "B", name: "Synthetic B", baseURL: "https://b.invalid"), token: "synthetic")
            gate.release(); try await waitFor { responded }; await drainActor()
            try check(f.store.activeProfileID == "B" && f.store.isUnread("S") && f.store.session("S")?.unreadAt == 200, "A ACK leaked into B")
            try check(!TestTransport.requests.contains { $0.host == "b.invalid" && $0.method == "PATCH" }, "Read mutation crossed hosts")
        }
        await run("read-only read timestamp survives reopening and a newer unread reappears") {
            let f = await prepared(stamp: 10, markable: false); defer { f.close() }
            f.store.setUnread(false, sessionID: "S")
            try check(!f.store.isUnread("S") && TestTransport.requests.isEmpty, "Read-only fallback sent a request or failed locally")
            f.store.disconnect()
            let reopened = AppStore(defaults: f.defaults); defer { reopened.disconnect() }
            TestTransport.handler = { r in r.path.hasPrefix("v1/sessions?") ? listing(session(unread: true, stamp: 10, markable: false)) : nil }
            await reopened.connect(f.profile)
            try check(!reopened.isUnread("S"), "Read timestamp was lost on reopen")
            try await TestTransport.emit(["session": session(unread: true, stamp: 11, markable: false)], type: "session.updated")
            try check(reopened.isUnread("S"), "Local read hid a later unread notification")
            try check(!TestTransport.requests.contains { $0.method == "PATCH" }, "Read-only fallback mutated the desktop")
        }
        await run("read-only manual unread is isolated by profile URL and restored on return") {
            let f = await prepared(unread: false, stamp: nil, markable: false); defer { f.close() }
            f.store.setUnread(true, sessionID: "S")
            try check(f.store.isUnread("S"), "Manual unread was not stored")
            TestTransport.handler = { r in r.path.hasPrefix("v1/sessions?") ? listing(session(unread: false, markable: false)) : nil }
            await f.store.connect(ConnectionProfile(id: "A", name: "Same profile other URL", baseURL: "https://b.invalid"), token: "synthetic")
            try check(!f.store.isUnread("S"), "A URL marker leaked into B URL with same ID")
            await f.store.connect(f.profile, token: "synthetic")
            try check(f.store.isUnread("S"), "Original host unread was lost")
            try check(!TestTransport.requests.contains { $0.method == "PATCH" }, "Local fallback used remote metadata writes")
        }
        await run("preview response after host switch is cancelled without leaking messages") {
            let f = await prepared(); defer { f.close() }
            let gate = Gate()
            TestTransport.handler = { r in
                guard r.host == "a.invalid", r.path == "v1/sessions/S" else { return nil }
                await gate.hold()
                return .object(["session": session(unread: true, stamp: 10), "messages": .array([TestTransport.message("private A preview")]), "pendingInteractions": .array([])])
            }
            let preview = Task { try await f.store.previewMessages("S") }; defer { gate.release(); preview.cancel() }
            try await gate.waitUntilEntered()
            await f.store.connect(ConnectionProfile(id: "B", name: "Synthetic B", baseURL: "https://b.invalid"), token: "synthetic")
            gate.release()
            var cancelled = false
            do { _ = try await preview.value } catch is CancellationError { cancelled = true }
            try check(cancelled, "Old preview returned messages in a new host epoch")
            try check(!f.store.messages("S").contains { $0.text == "private A preview" }, "Preview leaked into transcript")
        }

        let report: [String: JSONValue] = ["cases": .number(Double(results.count)), "passed": .number(Double(results.filter(\.passed).count)), "failed": .number(Double(results.filter { !$0.passed }.count)), "assertions": .number(Double(assertions))]
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(JSONValue.object(report))) as! [String: Any]
        object["results"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(results))
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        print("\(results.filter(\.passed).count)/\(results.count) passed; \(assertions) assertions; no network, Simulator, Keychain or service access")
        if results.contains(where: { !$0.passed }) { exit(1) }
    }
}
