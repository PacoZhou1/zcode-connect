import Foundation

/// Uses the production AppStore plus the exact inert transports from OutboxStateTests.
/// Gates deliver SSE between page responses deterministically; there is no network.
@main struct SessionPaginationStateTests {
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
            try await body()
            results.append(TestResult(name: name, passed: true, detail: "all assertions passed"))
            print("PASS \(name)")
        } catch {
            let detail = (error as? TestFailure)?.message ?? String(describing: error)
            results.append(TestResult(name: name, passed: false, detail: detail))
            print("FAIL \(name): \(detail)")
        }
    }
    static func cursor(_ request: TestRequest) -> String? {
        URLComponents(string: "https://fixture.invalid/\(request.path)")?.queryItems?.first { $0.name == "cursor" }?.value
    }
    static func isList(_ request: TestRequest) -> Bool { request.method == "GET" && request.path.hasPrefix("v1/sessions?") }
    @MainActor static func page(_ sessions: [JSONValue], snapshot: String = "stable", next: String? = nil,
                               total: Int = 0, truncated: Bool = false) -> JSONValue {
        .object(["sessions": .array(sessions), "pagination": .object([
            "snapshotId": .string(snapshot), "hasMore": .bool(next != nil),
            "nextCursor": next.map(JSONValue.string) ?? .null, "total": .number(Double(total)),
            "truncated": .bool(truncated)
        ])])
    }
    @MainActor static func rows(_ range: Range<Int>, prefix: String = "T") -> [JSONValue] {
        range.map { TestTransport.session("\(prefix)\($0)") }
    }
    @MainActor static func prepared() async -> Fixture {
        let fixture = Fixture()
        await fixture.connect()
        TestTransport.requests.removeAll()
        return fixture
    }
    @MainActor static func main() async throws {
        await run("235 sessions load completely through three opaque-cursor pages") {
            let f = await prepared(); defer { f.close() }
            let opaque = "page two:+/=?& space"
            var calls = 0
            TestTransport.handler = { r in
                guard isList(r) else { return nil }; calls += 1
                switch cursor(r) {
                case nil: return page(rows(0..<100), next: opaque, total: 235)
                case opaque: return page(rows(100..<200), next: "last", total: 235)
                case "last": return page(rows(200..<235), total: 235)
                default: throw TestFailure(message: "Opaque cursor was changed")
                }
            }
            await f.store.refresh()
            try check(f.store.sessions.count == 235, "Only \(f.store.sessions.count) sessions loaded")
            try check(Set(f.store.sessions.map(\.id)) == Set((0..<235).map { "T\($0)" }), "Missing or duplicated IDs")
            try check(calls == 3 && !f.store.sessionListTruncated, "Wrong page count or false truncation")
            try check(f.store.connection.isOnline && f.store.errorMessage == nil, "Complete index reported failure")
        }
        await run("SSE during page two preserves newer state and a newly created task") {
            let f = await prepared(); defer { f.close() }
            let gate = Gate()
            TestTransport.handler = { r in
                guard isList(r) else { return nil }
                if cursor(r) == nil { return page([TestTransport.session()], next: "two", total: 2) }
                await gate.hold()
                return page([TestTransport.session("T1")], total: 2)
            }
            let task = Task { await f.store.refresh() }; defer { gate.release(); task.cancel() }
            try await gate.waitUntilEntered()
            try await TestTransport.emit(["session": TestTransport.session(status: "running", title: "new live title")], type: "session.updated")
            try await TestTransport.emit(["session": TestTransport.session("live-created", status: "waiting")], type: "session.created")
            gate.release(); await task.value
            try check(f.store.session("S")?.status == .running && f.store.session("S")?.title == "new live title", "Stale page overwrote SSE state")
            try check(f.store.session("live-created")?.status == .waiting, "Snapshot removed SSE-created task")
            try check(f.store.sessions.count == 3 && f.store.session("T1") != nil, "Page or live task missing")
        }
        await run("repeated cursor stops after two requests and marks partial results") {
            let f = await prepared(); defer { f.close() }
            var calls = 0
            TestTransport.handler = { r in
                guard isList(r) else { return nil }; calls += 1
                if calls > 4 { throw TestFailure(message: "Pagination exceeded repeated-cursor guard") }
                return page(rows(calls == 1 ? 0..<100 : 100..<200), next: "same", total: 300)
            }
            await f.store.refresh()
            try check(calls == 2, "Repeated cursor was requested \(calls) times")
            try check(f.store.sessionListTruncated && f.store.sessions.count == 200, "Partial index was hidden or discarded")
        }
        await run("snapshot mismatch restarts once and rejects a second mismatching snapshot") {
            let f = await prepared(); defer { f.close() }
            var firsts = 0, calls = 0
            TestTransport.handler = { r in
                guard isList(r) else { return nil }; calls += 1
                if calls > 6 { throw TestFailure(message: "Mismatch retry was unbounded") }
                if cursor(r) == nil { firsts += 1; return page(rows(0..<100), snapshot: "base-\(firsts)", next: "two", total: 101) }
                return page(rows(100..<101), snapshot: "wrong-snapshot", total: 101)
            }
            await f.store.refresh()
            try check(firsts == 2 && calls == 4, "Mismatch retry count was \(firsts)/\(calls)")
            try check(f.store.sessions.map(\.id) == ["S"], "Mixed or partial snapshot replaced prior index")
            try check(!f.store.connection.isOnline && f.store.errorMessage != nil, "Second mismatch silently reported success")
        }
        for relayError in [false, true] {
            await run("one \(relayError ? "RelayFailure" : "BridgeFailure") cursor expiry recovers with a fresh snapshot") {
                let f = await prepared(); defer { f.close() }
                var firsts = 0, calls = 0
                TestTransport.handler = { r in
                    guard isList(r) else { return nil }; calls += 1
                    if cursor(r) == nil {
                        firsts += 1
                        return page(rows(0..<100, prefix: firsts == 1 ? "old" : "fresh"), snapshot: "snapshot-\(firsts)", next: "two", total: 105)
                    }
                    if firsts == 1 {
                        if relayError { throw RelayFailure("session_cursor_expired", "Synthetic expired cursor") }
                        throw BridgeFailure(message: "Synthetic expired cursor", code: "session_cursor_expired")
                    }
                    return page(rows(100..<105, prefix: "fresh"), snapshot: "snapshot-2", total: 105)
                }
                await f.store.refresh()
                try check(firsts == 2 && calls == 4, "Expiry did not restart exactly once")
                try check(Set(f.store.sessions.map(\.id)) == Set((0..<105).map { "fresh\($0)" }), "Old snapshot survived restart or new page was missing")
                try check(f.store.connection.isOnline && f.store.errorMessage == nil && !f.store.sessionListTruncated, "Recovered index reported failure")
            }
        }
        await run("a second cursor expiry fails within four list requests without partial commit") {
            let f = await prepared(); defer { f.close() }
            var firsts = 0, calls = 0
            TestTransport.handler = { r in
                guard isList(r) else { return nil }; calls += 1
                if calls > 6 { throw TestFailure(message: "Expiry retry was unbounded") }
                if cursor(r) == nil { firsts += 1; return page(rows(0..<100), snapshot: "attempt-\(firsts)", next: "expired", total: 101) }
                throw BridgeFailure(message: "Synthetic second expiry", code: "session_cursor_expired")
            }
            await f.store.refresh()
            try check(firsts == 2 && calls == 4, "Repeated expiry was retried too often")
            try check(f.store.sessions.map(\.id) == ["S"], "Incomplete retry replaced prior index")
            try check(f.store.errorMessage == "Synthetic second expiry" && !f.store.connection.isOnline, "Final expiry was hidden")
        }
        await run("SSE before expiry remains newer than the restarted snapshot") {
            let f = await prepared(); defer { f.close() }
            let gate = Gate(); var firsts = 0
            TestTransport.handler = { r in
                guard isList(r) else { return nil }
                if cursor(r) == nil { firsts += 1; return page([TestTransport.session()], snapshot: "attempt-\(firsts)", next: "two", total: 2) }
                if firsts == 1 { await gate.hold(); throw BridgeFailure(message: "Synthetic expiry", code: "session_cursor_expired") }
                return page([TestTransport.session("T1")], snapshot: "attempt-2", total: 2)
            }
            let task = Task { await f.store.refresh() }; defer { gate.release(); task.cancel() }
            try await gate.waitUntilEntered()
            try await TestTransport.emit(["session": TestTransport.session(status: "running", title: "live before restart")], type: "session.updated")
            gate.release(); await task.value
            try check(firsts == 2, "Fixture did not exercise retry")
            try check(f.store.session("S")?.status == .running && f.store.session("S")?.title == "live before restart", "Retry reset the event revision boundary")
        }
        await run("host switch during expired page prevents old retry and old list commit") {
            let f = await prepared(); defer { f.close() }
            let gate = Gate(); var aLists = 0
            TestTransport.handler = { r in
                guard isList(r) else { return nil }
                if r.host == "b.invalid" { return page([TestTransport.session("B-only")], total: 1) }
                aLists += 1
                if cursor(r) == nil { return page(rows(0..<100, prefix: "A"), next: "two", total: 101) }
                await gate.hold(); throw BridgeFailure(message: "Old host expiry", code: "session_cursor_expired")
            }
            let task = Task { await f.store.refresh() }; defer { gate.release(); task.cancel() }
            try await gate.waitUntilEntered()
            await f.store.connect(ConnectionProfile(id: "B", name: "Synthetic B", baseURL: "https://b.invalid"), token: "synthetic")
            gate.release(); await task.value
            try check(aLists == 2, "Old connection started another cursor attempt")
            try check(f.store.activeProfileID == "B" && f.store.sessions.map(\.id) == ["B-only"], "Old host replaced the new index")
            try check(f.store.connection.isOnline && f.store.errorMessage == nil, "Old host failure changed new connection state")
        }
        await run("superseded paging does not replace a newer same-host index") {
            let f = await prepared(); defer { f.close() }
            let gate = Gate(); var firsts = 0
            TestTransport.handler = { r in
                guard isList(r) else { return nil }
                if cursor(r) == nil {
                    firsts += 1
                    return firsts == 1 ? page(rows(0..<100, prefix: "old"), next: "two", total: 101) : page([TestTransport.session("newest")], total: 1)
                }
                await gate.hold(); throw BridgeFailure(message: "Superseded expiry", code: "session_cursor_expired")
            }
            let older = Task { await f.store.refresh() }; defer { gate.release(); older.cancel() }
            try await gate.waitUntilEntered(); await f.store.refresh()
            gate.release(); await older.value
            try check(firsts == 2, "Superseded request restarted pagination")
            try check(f.store.sessions.map(\.id) == ["newest"], "Superseded list replaced current index")
        }
        await run("superseded paging cannot erase the failure state of a newer refresh") {
            let f = await prepared(); defer { f.close() }
            let gate = Gate(); var firsts = 0
            TestTransport.handler = { r in
                guard isList(r) else { return nil }
                if cursor(r) == nil {
                    firsts += 1
                    if firsts > 1 { throw BridgeFailure(message: "Newest refresh failed", code: "offline") }
                    return page(rows(0..<100, prefix: "old"), next: "two", total: 101)
                }
                await gate.hold(); throw BridgeFailure(message: "Superseded expiry", code: "session_cursor_expired")
            }
            let older = Task { await f.store.refresh() }; defer { gate.release(); older.cancel() }
            try await gate.waitUntilEntered(); await f.store.refresh()
            try check(!f.store.connection.isOnline, "Fixture did not reach newer refresh failure")
            gate.release(); await older.value
            try check(!f.store.connection.isOnline && f.store.errorMessage == "Newest refresh failed", "Superseded success return changed failed connection to online")
        }

        let report: [String: JSONValue] = ["cases": .number(Double(results.count)), "passed": .number(Double(results.filter(\.passed).count)), "failed": .number(Double(results.filter { !$0.passed }.count)), "assertions": .number(Double(assertions))]
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(JSONValue.object(report))) as! [String: Any]
        object["results"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(results))
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        print("\(results.filter(\.passed).count)/\(results.count) passed; \(assertions) assertions; no network, Simulator, Keychain or service access")
        if results.contains(where: { !$0.passed }) { exit(1) }
    }
}
