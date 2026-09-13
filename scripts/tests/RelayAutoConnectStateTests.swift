import Foundation

@MainActor private enum RetryClock {
    static var delays: [Duration] = []
    static var gate: Gate?
    static func wait(_ delay: Duration) async throws {
        delays.append(delay)
        if let gate { await gate.hold() }
        try Task.checkCancellation()
    }
}

@MainActor private final class AutoConnectFixture {
    let suite = "dev.paco.relay-autoconnect.\(UUID().uuidString)"
    let defaults: UserDefaults
    let store: AppStore
    let profile: ConnectionProfile
    init(profiles: [ConnectionProfile] = [RelayAutoConnectStateTests.profile()]) throws {
        profile = profiles[0]
        defaults = UserDefaults(suiteName: suite)!
        defaults.set(try JSONEncoder().encode(profiles), forKey: "connections")
        defaults.set(profile.id, forKey: "activeConnection")
        defaults.set(true, forKey: "hasConnectedBefore")
        for item in profiles { CredentialStore.values[item.id] = RelayAutoConnectStateTests.raw(item.relayDeviceID!) }
        store = AppStore(defaults: defaults, reconnectDelay: { try await RetryClock.wait($0) })
    }
    func reopen() -> AppStore { AppStore(defaults: defaults, reconnectDelay: { try await RetryClock.wait($0) }) }
    func close() { store.disconnect(); defaults.removePersistentDomain(forName: suite) }
}

@main struct RelayAutoConnectStateTests {
    @MainActor static var results: [TestResult] = []
    @MainActor static var assertions = 0
    static func raw(_ device: String = "device-A") -> String {
        "https://zcode.z.ai/remote/v4?sid=\(device)&hash=synthetic-fixture-only-0000000000000000&name=Synthetic&app_version=fixture"
    }
    static func profile(_ id: String = "saved-A", device: String = "device-A", workspace: String = "/A") -> ConnectionProfile {
        .init(id: id, name: "Saved \(id)", baseURL: "https://zcode.z.ai/remote/v4", relayDeviceID: device, relayWorkspaceKey: workspace)
    }
    static func listing(_ paths: [String]) -> RelayBootstrap {
        .init(windowControlSessionId: "fixture-control", workspaces: paths.map {
            RelayWorkspace(kind: "local", workspacePath: $0, workspaceIdentity: nil, remoteSessionId: nil, connectionState: "connected", lastConnectionError: nil)
        }, tasks: [], initialViewState: nil, mobileViewState: nil, activeWorkspaceKey: nil, activeTaskId: nil)
    }
    @MainActor static func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
        assertions += 1
        if !value() { throw TestFailure(message: message) }
    }
    @MainActor static func until(_ predicate: () -> Bool) async throws {
        for _ in 0..<10000 { if predicate() { return }; await Task.yield() }
        throw TestFailure(message: "Bounded wait for inert connection state expired")
    }
    @MainActor static func drain() async { for _ in 0..<150 { await Task.yield() } }
    @MainActor static func ready(_ device: String = "device-A", workspace: String = "/A") async throws {
        let host = "relay:\(device):\(workspace)"
        let expected = RelayWorkspaceProbe.calls.filter { $0.operation == "adapter" && $0.device == device && $0.workspace == workspace }.count
        try await until { TestTransport.subscribers[host] != nil && (TestTransport.eventSubscriptions[host] ?? 0) >= expected }
        try await TestTransport.emit(["connectionStatus": .string("connected")], host: host, type: "ready")
    }
    @MainActor static func run(_ name: String, _ body: () async throws -> Void) async {
        try? ("START " + name).write(to: URL(fileURLWithPath: CommandLine.arguments[2] + ".progress"), atomically: true, encoding: .utf8)
        await drain(); TestTransport.reset(); RelayWorkspaceProbe.reset(); RetryClock.delays = []; RetryClock.gate = nil
        OutboxTestSandbox.directory = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(UUID().uuidString)
        RelayWorkspaceProbe.listings["device-A"] = listing(["/A"])
        RelayWorkspaceProbe.listings["device-B"] = listing(["/B"])
        do { try await body(); results.append(.init(name: name, passed: true, detail: "all assertions passed")); print("PASS \(name)") }
        catch { let detail = (error as? TestFailure)?.message ?? String(describing: error); results.append(.init(name: name, passed: false, detail: detail)); print("FAIL \(name): \(detail)") }
    }

    @MainActor static func main() async throws {
        await run("cold launch restores the saved Relay once without another confirmation or workspace prompt") {
            let f = try AutoConnectFixture(); defer { f.close() }
            await f.store.start(); try await ready()
            await f.store.start(); await f.store.applicationDidBecomeActive()
            try check(f.store.connection.isOnline && f.store.activeProfileID == f.profile.id, "Saved profile was not restored")
            try check(RelayWorkspaceProbe.count("pair") == 1 && RelayWorkspaceProbe.count("open") == 1, "Repeated startup/foreground created another controller")
            try check(f.store.relayWorkspaceSelection == nil && f.store.sheet == nil && RetryClock.delays.isEmpty, "Known workspace unexpectedly required user selection or backoff")
        }
        await run("overlapping startup and foreground wait for the same pairing") {
            let f = try AutoConnectFixture(); defer { f.close() }
            let gate = Gate(); defer { gate.release() }
            RelayWorkspaceProbe.handler = { call in if call.operation == "pair" { await gate.hold() }; return nil }
            let start = Task { await f.store.start() }; try await gate.waitUntilEntered()
            let foreground = Task { await f.store.applicationDidBecomeActive() }; await drain()
            try check(RelayWorkspaceProbe.count("pair") == 1, "Foreground duplicated an in-flight handshake")
            gate.release(); await start.value; await foreground.value; try await ready()
            try check(TestTransport.eventSubscriptions["relay:device-A:/A"] == 1 && f.store.connection.isOnline, "Overlapping triggers duplicated stream attachment")
        }
        await run("manual disconnect survives foreground and process recreation") {
            let f = try AutoConnectFixture(); defer { f.close() }
            await f.store.start(); try await ready(); f.store.disconnect()
            f.store.applicationDidEnterBackground(); await f.store.applicationDidBecomeActive()
            let reopened = f.reopen(); defer { reopened.disconnect() }; await reopened.start()
            try check(RelayWorkspaceProbe.count("pair") == 1, "Manual disconnect was silently undone")
            try check(f.store.connection == .disconnected && reopened.connection == .disconnected, "Manual offline preference was not retained")
            await reopened.connect(f.profile, confirmedControllerReplacement: true); try await ready()
            try check(reopened.connection.isOnline && RelayWorkspaceProbe.count("pair") == 2, "Explicit reconnect could not clear the saved manual block")
        }
        await run("transient pair failures use 2 and 5 second backoff then recover") {
            let f = try AutoConnectFixture(); defer { f.close() }
            RelayWorkspaceProbe.handler = { call in
                if call.operation == "pair", RelayWorkspaceProbe.count("pair") < 3 { throw URLError(.notConnectedToInternet) }
                return nil
            }
            await f.store.start(); try await ready()
            try check(RelayWorkspaceProbe.count("pair") == 3 && RetryClock.delays == [.seconds(2), .seconds(5)], "Transient retries did not use the bounded schedule")
            try check(f.store.connection.isOnline && f.store.errorMessage == nil, "Recovered transient error produced a blocking alert")
        }
        await run("continuous network failure exhausts a finite foreground budget") {
            let f = try AutoConnectFixture(); defer { f.close() }
            RelayWorkspaceProbe.handler = { call in if call.operation == "pair" { throw URLError(.timedOut) }; return nil }
            await f.store.start(); await f.store.applicationDidBecomeActive(); await f.store.start()
            try check(RelayWorkspaceProbe.count("pair") == 4 && RetryClock.delays == [.seconds(2), .seconds(5), .seconds(10)], "Retry budget reset while still in the same foreground visit")
            f.store.applicationDidEnterBackground(); await f.store.applicationDidBecomeActive()
            try check(RelayWorkspaceProbe.count("pair") == 8, "A later foreground visit cannot start a new bounded recovery cycle")
        }
        for code in ["relay_rejected", "controller_replaced", "relay_invalid_frame"] {
            await run("\(code) blocks background takeover and remains blocked after recreation") {
                let f = try AutoConnectFixture(); defer { f.close() }
                RelayWorkspaceProbe.handler = { call in if call.operation == "pair" { throw RelayFailure(code, "Synthetic definitive rejection") }; return nil }
                await f.store.start(); f.store.applicationDidEnterBackground(); await f.store.applicationDidBecomeActive()
                let reopened = f.reopen(); defer { reopened.disconnect() }; await reopened.start()
                try check(RelayWorkspaceProbe.count("pair") == 1 && RetryClock.delays.isEmpty, "Definitive rejection retried or stole the controller")
                try check(!reopened.connection.isOnline && f.store.errorMessage != nil, "Authentication/controller failure was hidden")
            }
        }
        await run("KICKED stream keeps the original draft and never automatically reconnects") {
            let f = try AutoConnectFixture(); defer { f.close() }
            await f.store.start(); try await ready(); f.store.setDraft("unsent original", for: "S")
            TestTransport.eventExitHandler = { _ in throw RelayFailure("controller_replaced", "Synthetic kicked") }
            TestTransport.subscribers["relay:device-A:/A"]?.finish()
            try await until { !f.store.streamConnected }; await drain()
            f.store.applicationDidEnterBackground(); await f.store.applicationDidBecomeActive()
            try check(RelayWorkspaceProbe.count("pair") == 1 && RetryClock.delays.isEmpty, "KICKED started an automatic controller replacement")
            try check(f.store.drafts["S"] == "unsent original" && !f.store.connection.isOnline, "KICKED lost the draft or claimed an online connection")
        }
        await run("temporary stream loss restores the same workspace and reading location") {
            let f = try AutoConnectFixture(); defer { f.close() }
            await f.store.start(); try await ready(); f.store.path = [.session("S")]; f.store.setDraft("unsent", for: "S")
            TestTransport.eventExitHandler = { _ in throw RelayFailure("relay_transport_failed", "Synthetic network loss") }
            TestTransport.subscribers["relay:device-A:/A"]?.finish()
            try await until { RelayWorkspaceProbe.count("pair") == 2 && f.store.connection.isOnline }; await drain(); try await ready()
            try check(f.store.currentSessionID == "S" && f.store.drafts["S"] == "unsent", "Automatic recovery discarded navigation or draft")
            try check(RetryClock.delays == [.seconds(2)] && RelayWorkspaceProbe.count("open") == 2, "Stream recovery duplicated or changed workspace attachment")
        }
        await run("first foreground read failure replaces the stale online transport in the same visit") {
            let f = try AutoConnectFixture(); defer { f.close() }
            await f.store.start(); try await ready(); f.store.path = [.session("S")]
            f.store.applicationDidEnterBackground()
            var failed = false
            TestTransport.handler = { request in
                if request.path == "v1/projects", !failed { failed = true; throw URLError(.networkConnectionLost) }
                return nil
            }
            await f.store.applicationDidBecomeActive()
            try await until { RelayWorkspaceProbe.count("pair") == 2 && f.store.connection.isOnline }; try await ready()
            try check(failed && f.store.currentSessionID == "S" && f.store.connection.isOnline, "Stale online transport needed a second foreground event")
            try check(RelayWorkspaceProbe.count("pair") == 2, "Foreground recovery duplicated pairing")
        }
        await run("foreground authentication failure does not retry the stale online transport") {
            let f = try AutoConnectFixture(); defer { f.close() }
            await f.store.start(); try await ready(); f.store.applicationDidEnterBackground()
            TestTransport.handler = { request in
                if request.path == "v1/projects" { throw RelayFailure("relay_rejected", "Synthetic authentication expired") }
                return nil
            }
            await f.store.applicationDidBecomeActive(); await drain()
            f.store.applicationDidEnterBackground(); await f.store.applicationDidBecomeActive()
            try check(RelayWorkspaceProbe.count("pair") == 1 && !f.store.connection.isOnline, "Expired authentication caused background takeover")
        }
        await run("brief successful handshakes do not replenish a flapping network budget") {
            let f = try AutoConnectFixture(); defer { f.close() }
            await f.store.start(); try await ready()
            TestTransport.eventExitHandler = { _ in throw RelayFailure("relay_transport_failed", "Synthetic flapping network") }
            for targetCount in 2...4 {
                TestTransport.subscribers["relay:device-A:/A"]?.finish()
                try await until { RelayWorkspaceProbe.count("pair") == targetCount && f.store.connection.isOnline }
                await drain(); try await ready()
            }
            TestTransport.subscribers["relay:device-A:/A"]?.finish()
            try await until { !f.store.streamConnected }; await drain()
            try check(RelayWorkspaceProbe.count("pair") == 4 && !f.store.connection.isOnline, "Repeated short successes created an unbounded loop")
            try check(RetryClock.delays == [.seconds(2), .seconds(5), .seconds(10)], "Flapping stream lost its cumulative budget")
        }
        await run("background cancels delayed retries without permanently disabling restoration") {
            let f = try AutoConnectFixture(); defer { f.close() }
            let gate = Gate(); RetryClock.gate = gate; defer { gate.release() }
            RelayWorkspaceProbe.handler = { call in if call.operation == "pair" { throw URLError(.timedOut) }; return nil }
            let start = Task { await f.store.start() }; try await gate.waitUntilEntered()
            f.store.applicationDidEnterBackground(); gate.release(); await start.value
            try check(RelayWorkspaceProbe.count("pair") == 1, "A cancelled background delay still connected")
            RelayWorkspaceProbe.handler = nil; RetryClock.gate = nil
            await f.store.applicationDidBecomeActive(); try await ready()
            try check(RelayWorkspaceProbe.count("pair") == 2 && f.store.connection.isOnline, "Background cancellation was mistaken for a manual disconnect")
        }
        await run("manual disconnect during backoff prevents even a late delay completion") {
            let f = try AutoConnectFixture(); defer { f.close() }
            let gate = Gate(); RetryClock.gate = gate; defer { gate.release() }
            RelayWorkspaceProbe.handler = { call in if call.operation == "pair" { throw URLError(.timedOut) }; return nil }
            let start = Task { await f.store.start() }; try await gate.waitUntilEntered()
            f.store.disconnect(); gate.release(); await start.value
            f.store.applicationDidEnterBackground(); await f.store.applicationDidBecomeActive()
            try check(RelayWorkspaceProbe.count("pair") == 1 && f.store.connection == .disconnected, "Late retry ignored a manual disconnect")
        }
        await run("late automatic pair result cannot replace a manually selected computer") {
            let b = profile("saved-B", device: "device-B", workspace: "/B")
            let f = try AutoConnectFixture(profiles: [profile(), b]); defer { f.close() }
            let gate = Gate(); defer { gate.release() }
            RelayWorkspaceProbe.handler = { call in if call.operation == "pair", call.device == "device-A" { await gate.hold() }; return nil }
            let start = Task { await f.store.start() }; try await gate.waitUntilEntered()
            await f.store.switchComputer(b, confirmedControllerReplacement: true); try await ready("device-B", workspace: "/B")
            f.store.setDraft("B draft", for: "S"); gate.release(); await start.value; await drain()
            try check(f.store.activeProfileID == b.id && f.store.connection.isOnline && f.store.drafts["S"] == "B draft", "Old automatic result crossed computer scope")
            try check(RelayWorkspaceProbe.count("open", device: "device-A") == 0 && RelayWorkspaceProbe.count("pair", device: "device-B") == 1, "Stale automatic pairing opened a workspace or duplicated B")
        }
        await run("late KICKED from the detached computer cannot suppress the new computer") {
            let b = profile("saved-B", device: "device-B", workspace: "/B")
            let f = try AutoConnectFixture(profiles: [profile(), b]); defer { f.close() }
            await f.store.start(); try await ready()
            let gate = Gate(); defer { gate.release() }
            TestTransport.eventExitHandler = { host in if host == "relay:device-A:/A" { await gate.hold(); throw RelayFailure("controller_replaced", "Old kicked") } }
            await f.store.switchComputer(b, confirmedControllerReplacement: true)
            try await gate.waitUntilEntered(); try await ready("device-B", workspace: "/B")
            gate.release(); await drain(); f.store.applicationDidEnterBackground(); await f.store.applicationDidBecomeActive()
            try check(f.store.activeProfileID == b.id && f.store.connection.isOnline && f.store.streamConnected, "Old KICKED changed B's live connection")
            let blocks = f.defaults.dictionary(forKey: "automaticConnectionBlocks") as? [String: String] ?? [:]
            try check(blocks[b.id] == nil && RelayWorkspaceProbe.count("pair", device: "device-B") == 1, "Old event blocked or re-paired B")
        }
        await run("missing saved workspace offers a live selection without repeated pairing") {
            let f = try AutoConnectFixture(); defer { f.close() }
            RelayWorkspaceProbe.listings["device-A"] = listing(["/alternative"])
            await f.store.start(); await f.store.applicationDidBecomeActive()
            try check(RelayWorkspaceProbe.count("pair") == 1 && RelayWorkspaceProbe.count("open") == 0, "Unavailable workspace triggered repeated handshake or an automatic substitute")
            try check(f.store.relayWorkspaceSelection != nil && f.store.sheet?.id == "pairing", "Workspace choice was lost")
        }
        await run("first QR still requires confirmation and does not auto-open a workspace") {
            let f = try AutoConnectFixture(); defer { f.close() }
            do {
                _ = try await f.store.beginRelayPairing(raw(), confirmedControllerReplacement: false)
                throw TestFailure(message: "Unconfirmed first QR connected")
            } catch let error as BridgeFailure { try check(error.code == "controller_confirmation_required", "Wrong first-pairing gate") }
            let context = try await f.store.beginRelayPairing(raw(), confirmedControllerReplacement: true)
            try check(f.store.isCurrentRelaySelection(context) && RelayWorkspaceProbe.count("open") == 0, "Fresh pairing silently selected a workspace")
        }
        await run("automatic connection never replays pending text or uploads") {
            let f = try AutoConnectFixture(); defer { f.close() }
            let pending = PendingSubmission(id: "frozen-pending", draftKey: "S", sessionID: "S", text: "Uncertain prior input", attachments: [])
            try SubmissionJournal(directory: OutboxTestSandbox.directory).write(["S": pending], scope: "\(f.profile.id)|\(f.profile.baseURL)")
            await f.store.start(); try await ready()
            try check(f.store.pendingSubmissions["S"]?.id == pending.id, "Restoration erased the pending original ID")
            try check(TestTransport.requests.allSatisfy { $0.method == "GET" } && TestTransport.created == 0 && TestTransport.uploaded == 0, "Connecting replayed a command or uploaded an attachment")
        }
        let passed = results.filter(\.passed).count
        let report = Report(passed: passed, failed: results.count - passed, assertions: assertions, results: results)
        try JSONEncoder().encode(report).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        print("\(passed)/\(results.count) passed; \(assertions) assertions; production Store with inert Relay, credentials and virtual retry clock")
        if passed != results.count { exit(1) }
    }
    struct Report: Codable { let passed: Int; let failed: Int; let assertions: Int; let results: [TestResult] }
}
