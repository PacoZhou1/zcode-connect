import Foundation

@main struct StreamLifecycleStateTests {
    @MainActor static var results: [TestResult] = []
    @MainActor static var assertions = 0
    static let profileB = ConnectionProfile(id: "B", name: "Synthetic B", baseURL: "https://b.invalid")

    @MainActor static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        assertions += 1
        if !condition() { throw TestFailure(message: message) }
    }
    @MainActor static func until(_ predicate: () -> Bool, timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() {
            guard Date() < deadline else { throw TestFailure(message: "Timed out waiting for synthetic stream state") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    @MainActor static func run(_ name: String, _ operation: () async throws -> Void) async {
        TestTransport.reset()
        OutboxTestSandbox.directory = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(UUID().uuidString)
        do {
            try await operation()
            results.append(.init(name: name, passed: true, detail: "all assertions passed"))
            print("PASS \(name)")
        } catch {
            let detail = (error as? TestFailure)?.message ?? String(describing: error)
            results.append(.init(name: name, passed: false, detail: detail))
            print("FAIL \(name): \(detail)")
        }
    }
    @MainActor static func ready(_ host: String) async throws {
        try await until { TestTransport.subscribers[host] != nil }
        try await TestTransport.emit(["connectionStatus": .string("connected")], host: host, type: "ready")
    }
    @MainActor static func classifyAsRelay(_ store: AppStore) throws {
        guard let index = store.profiles.firstIndex(where: { $0.id == store.activeProfileID }) else {
            throw TestFailure(message: "Synthetic connection has no active profile")
        }
        // beginStreaming selects its end/error policy from this metadata. Its
        // transport stays inert; these tests do not claim a Relay handshake.
        store.profiles[index].relayDeviceID = "synthetic-relay-device"
        store.profiles[index].relayWorkspaceKey = "synthetic-workspace"
    }

    @MainActor static func main() async throws {
        for relay in [false, true] {
            for fails in [false, true] {
                await run("late old HTTP \(fails ? "error" : "normal end") cannot overwrite new \(relay ? "Relay-classified" : "HTTP") connection") {
                    let f = Fixture(); defer { f.close() }
                    await f.connect(); try await ready("a.invalid")
                    let exitGate = Gate()
                    var exitDelivered = false
                    TestTransport.eventExitHandler = { host in
                        guard host == "a.invalid" else { return }
                        await exitGate.hold()
                        exitDelivered = true
                        if fails { throw BridgeFailure(message: "synthetic late old stream failure", code: "offline") }
                    }
                    defer { exitGate.release() }
                    await f.store.connect(profileB, token: "synthetic-test-token")
                    try await exitGate.waitUntilEntered()
                    if relay { try classifyAsRelay(f.store) }
                    try await ready("b.invalid")
                    f.store.setDraft("B unsent draft", for: "S")
                    try check(f.store.streamConnected && f.store.connection == .connected, "New connection was not ready before releasing old completion")
                    exitGate.release(); try await until { exitDelivered }
                    for _ in 0..<100 { await Task.yield() }
                    try check(f.store.activeProfileID == "B" && f.store.streamConnected && f.store.connection == .connected,
                              "Old stream completion contaminated the new connection: \(f.store.connection), streamConnected=\(f.store.streamConnected)")
                    try check(f.store.drafts["S"] == "B unsent draft", "Late old stream changed the new host draft")
                    try check(TestTransport.eventSubscriptions["a.invalid"] == 1 && TestTransport.eventSubscriptions["b.invalid"] == 1,
                              "Old completion started a replacement subscription")
                }
            }
        }
        for code in [String?.none, "offline", "controller_replaced"] {
            await run("current Relay-classified stream \(code ?? "normal end") still reports its real disconnect") {
                let f = Fixture(); defer { f.close() }
                await f.connect(); try classifyAsRelay(f.store); try await ready("a.invalid")
                f.store.setDraft("Preserve disconnected draft", for: "S")
                TestTransport.eventExitHandler = { _ in
                    if let code { throw BridgeFailure(message: "synthetic current stream failure", code: code) }
                }
                TestTransport.subscribers["a.invalid"]?.finish()
                try await until { !f.store.streamConnected }
                let expected = code == nil ? "远程连接已结束，请在连接页面重新连接电脑。"
                    : code == "controller_replaced" ? "另一台手机已接管连接。你可以在连接页面手动重新连接。"
                    : "远程连接已断开，草稿已保留。请手动重新连接电脑。"
                try check(f.store.connection == .failed(expected), "Current stream disconnect was ignored or misclassified")
                try check(f.store.drafts["S"] == "Preserve disconnected draft", "Current disconnect discarded draft")
                try check(TestTransport.eventSubscriptions["a.invalid"] == 1, "Relay policy unexpectedly retried automatically")
            }
        }
        for fails in [false, true] {
            await run("current HTTP \(fails ? "error" : "normal end") still clears stream state and retries") {
                let f = Fixture(); defer { f.close() }
                await f.connect(); try await ready("a.invalid")
                TestTransport.eventExitHandler = { _ in
                    if fails { throw BridgeFailure(message: "synthetic current HTTP failure", code: "offline") }
                }
                TestTransport.subscribers["a.invalid"]?.finish()
                try await until { !f.store.streamConnected }
                try check(f.store.connection == .connected, "Existing HTTP retry policy changed to a terminal connection failure")
                try await until { TestTransport.eventSubscriptions["a.invalid"] == 2 }
                try await ready("a.invalid")
                try check(f.store.streamConnected && f.store.connection == .connected, "Current HTTP stream did not recover through its next subscription")
            }
        }
        await run("explicit disconnect is not replaced by a late normal stream failure") {
            let f = Fixture(); defer { f.close() }
            await f.connect(); try classifyAsRelay(f.store); try await ready("a.invalid")
            let exitGate = Gate(); var exitDelivered = false
            TestTransport.eventExitHandler = { _ in await exitGate.hold(); exitDelivered = true }
            defer { exitGate.release() }
            f.store.disconnect(); try await exitGate.waitUntilEntered()
            exitGate.release(); try await until { exitDelivered }
            for _ in 0..<100 { await Task.yield() }
            try check(f.store.connection == .disconnected && !f.store.streamConnected, "Cancelled stream turned explicit disconnect into a failure")
            try check(TestTransport.eventSubscriptions["a.invalid"] == 1, "Cancelled stream restarted after explicit disconnect")
        }

        let object: [String: Any] = ["cases": results.count, "passed": results.filter(\.passed).count,
            "failed": results.filter { !$0.passed }.count, "assertions": assertions,
            "results": try JSONSerialization.jsonObject(with: JSONEncoder().encode(results))]
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        print("\(results.filter(\.passed).count)/\(results.count) passed; \(assertions) assertions; production AppStore with inert transport, no services or Relay handshake")
        if results.contains(where: { !$0.passed }) { exit(1) }
    }
}
