import Foundation

@main struct ComputerSwitchStateTests {
    @MainActor static var results: [TestResult] = []
    @MainActor static var assertions = 0
    static let profileB = ConnectionProfile(id: "B", name: "Synthetic B", baseURL: "https://b.invalid")
    static let profileC = ConnectionProfile(id: "C", name: "Synthetic C", baseURL: "https://c.invalid")

    @MainActor static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        assertions += 1
        if !condition() { throw TestFailure(message: message) }
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
    @MainActor static func fixture() async -> Fixture {
        let f = Fixture()
        await f.connect()
        f.store.profiles.append(contentsOf: [profileB, profileC])
        return f
    }
    @MainActor static func seedPrivateA(_ store: AppStore) {
        store.transcripts["S"] = [ChatMessage(id: "A-message", role: .assistant, text: "A transcript")]
        store.goals["S"] = TaskGoal(text: "A goal", isPaused: false, elapsed: "1m")
        store.agentTasks["S"] = [AgentTask(id: "A-child", title: "A agent", status: .running, detail: "A detail", colorIndex: 0)]
        let projection: RelayJSON = .object([
            "goal": .object(["objective": .string("A host goal"), "status": .string("active")]),
            "subagents": .object(["childSessionIds": .array([.string("A-child")]), "endedTotal": .int(1)])
        ])
        store.hostGoals["S"] = RelayHostGoal(projection: projection)
        store.hostAgents["S"] = RelayHostAgents(projection: projection)
        store.setDraft("A draft", for: "S")
        store.draftAttachments["S"] = [Attachment(name: "A.txt", data: Data("A bytes".utf8), mimeType: "text/plain")]
        store.pendingSubmissions["S"] = PendingSubmission(draftKey: "S", text: "A pending", attachments: [])
        store.path = [.session("S")]
    }
    @MainActor static func checkOldStateCleared(_ store: AppStore) throws {
        try check(store.sessions.isEmpty && store.transcripts.isEmpty, "Old sessions or transcript still visible")
        try check(store.goals.isEmpty && store.agentTasks.isEmpty && store.hostGoals.isEmpty && store.hostAgents.isEmpty, "Old goal or agent state still visible")
        try check(store.drafts.isEmpty && store.draftAttachments.isEmpty && store.pendingSubmissions.isEmpty, "Old draft, attachment or pending request leaked")
        try check(store.path.isEmpty && store.projects.isEmpty && store.selectedProjectID == nil, "Old navigation or project remains selected")
    }
    @MainActor static func listing(_ host: String) -> JSONValue {
        .object(["sessions": .array([TestTransport.session(title: "\(host) task")])])
    }
    @MainActor static func drainActor() async { for _ in 0..<100 { await Task.yield() } }

    @MainActor static func main() async throws {
        await run("fresh installation requires a connection and durably records the initial gate") {
            let f = Fixture(); defer { f.close() }
            try check(f.store.profiles.isEmpty && !f.store.hasConnectedBefore && f.store.requiresInitialConnection, "Fresh install reached Home without a connection")
            try check(f.defaults.object(forKey: "hasConnectedBefore") as? Bool == false, "Fresh-install false was not persisted before any profile can be saved")
            await f.store.start()
            try check(TestTransport.requests.isEmpty && f.store.requiresInitialConnection, "Empty startup attempted I/O or bypassed onboarding")
            let reopened = AppStore(defaults: f.defaults); defer { reopened.disconnect() }
            try check(reopened.requiresInitialConnection && !reopened.hasConnectedBefore, "Empty relaunch bypassed onboarding")
        }
        await run("a failed initial handshake remains gated after relaunch") {
            let f = Fixture(); defer { f.close() }
            TestTransport.handler = { request in
                if request.path == "v1/status" { throw BridgeFailure(message: "Synthetic first connection failure", code: "offline") }
                return nil
            }
            await f.connect()
            try check(f.store.requiresInitialConnection && !f.store.hasConnectedBefore, "Failed handshake unlocked Home")
            try check(f.store.connection == .failed("Synthetic first connection failure"), "Initial failure was hidden")
            let reopened = AppStore(defaults: f.defaults); defer { reopened.disconnect() }
            try check(reopened.requiresInitialConnection && !reopened.hasConnectedBefore, "Failed handshake became a successful prior connection on relaunch")
        }
        await run("saving a profile before failed initial index does not bypass the gate on relaunch") {
            let f = Fixture(); defer { f.close() }
            TestTransport.handler = { request in
                if request.path.hasPrefix("v1/sessions?") { throw BridgeFailure(message: "Synthetic initial index failure", code: "offline") }
                return nil
            }
            await f.connect()
            try check(f.store.profiles == [f.profile] && f.defaults.data(forKey: "connections") != nil, "Fixture did not reach persisted-profile-before-index boundary")
            try check(f.store.requiresInitialConnection && !f.store.hasConnectedBefore, "Saved profile was mistaken for initial connection success")
            try check(f.defaults.object(forKey: "hasConnectedBefore") as? Bool == false, "Index failure changed the persistent gate")
            let reopened = AppStore(defaults: f.defaults); defer { reopened.disconnect() }
            try check(reopened.profiles == [f.profile] && reopened.requiresInitialConnection, "Existing failed profile bypassed onboarding during migration")
            await reopened.start()
            try check(reopened.requiresInitialConnection, "Automatic failed reconnect unlocked Home")
        }
        await run("only a completed initial index unlocks Home and the result survives disconnect and relaunch") {
            let f = Fixture(); defer { f.close() }
            let gate = Gate()
            TestTransport.handler = { request in
                if request.path.hasPrefix("v1/sessions?") { await gate.hold() }
                return nil
            }
            let connecting = Task { await f.connect() }
            defer { gate.release(); connecting.cancel() }
            try await gate.waitUntilEntered()
            try check(f.store.connection.isOnline && f.store.requiresInitialConnection, "Status handshake alone unlocked Home before index completion")
            try check(!f.defaults.bool(forKey: "hasConnectedBefore"), "Success persisted while the initial index was pending")
            gate.release(); await connecting.value
            try check(f.store.session("S") != nil && f.store.hasConnectedBefore && !f.store.requiresInitialConnection, "Successful initial index did not unlock Home")
            try check(f.defaults.bool(forKey: "hasConnectedBefore"), "Connection success was not persisted")
            f.store.disconnect()
            try check(!f.store.requiresInitialConnection, "An ordinary disconnect reset completed onboarding")
            let reopened = AppStore(defaults: f.defaults); defer { reopened.disconnect() }
            try check(reopened.connection == .disconnected && reopened.hasConnectedBefore && !reopened.requiresInitialConnection, "Offline relaunch lost successful connection history")
        }
        await run("reference mode skips onboarding without persisting a real connection") {
            let f = Fixture(); defer { f.close() }
            f.store.enterReferenceMode()
            try check(f.store.isReferenceMode && !f.store.requiresInitialConnection && !f.store.hasConnectedBefore, "Reference preview did not bypass only the visible gate")
            try check(!f.defaults.bool(forKey: "hasConnectedBefore") && TestTransport.requests.isEmpty, "Reference preview claimed or attempted a real connection")
            f.store.leaveReferenceMode(); await drainActor()
            try check(!f.store.isReferenceMode && f.store.requiresInitialConnection, "Leaving reference preview bypassed first connection")
            let reopened = AppStore(defaults: f.defaults); defer { reopened.disconnect() }
            try check(reopened.requiresInitialConnection && !reopened.isReferenceMode && !reopened.hasConnectedBefore, "Reference-only relaunch entered Home")
        }
        await run("legacy saved configuration migrates once without replacing explicit false") {
            let f = Fixture(); defer { f.close() }
            f.defaults.set(try JSONEncoder().encode([f.profile]), forKey: "connections")
            f.defaults.set(f.profile.id, forKey: "activeConnection")
            f.defaults.removeObject(forKey: "hasConnectedBefore")
            let migrated = AppStore(defaults: f.defaults); defer { migrated.disconnect() }
            try check(migrated.profiles == [f.profile] && migrated.activeProfileID == f.profile.id, "Migration changed the saved computer")
            try check(migrated.hasConnectedBefore && !migrated.requiresInitialConnection && f.defaults.bool(forKey: "hasConnectedBefore"), "Legacy profiles were not migrated to prior connection history")
            try check(TestTransport.requests.isEmpty, "Legacy migration performed remote I/O")
            f.defaults.set(false, forKey: "hasConnectedBefore")
            let explicitlyUnconnected = AppStore(defaults: f.defaults); defer { explicitlyUnconnected.disconnect() }
            try check(!explicitlyUnconnected.hasConnectedBefore && explicitlyUnconnected.requiresInitialConnection, "Migration overrode an explicitly persisted false")
        }
        await run("a cancelled connection cannot unlock onboarding through its late index") {
            let f = Fixture(); defer { f.close() }
            let gate = Gate()
            TestTransport.handler = { request in
                if request.path.hasPrefix("v1/sessions?") { await gate.hold() }
                return nil
            }
            let connecting = Task { await f.connect() }
            defer { gate.release(); connecting.cancel() }
            try await gate.waitUntilEntered()
            f.store.disconnect(); gate.release(); await connecting.value
            try check(f.store.connection == .disconnected && f.store.requiresInitialConnection && !f.store.hasConnectedBefore, "Late cancelled index unlocked Home")
            try check(!f.defaults.bool(forKey: "hasConnectedBefore"), "Cancelled epoch persisted onboarding success")
            let reopened = AppStore(defaults: f.defaults); defer { reopened.disconnect() }
            try check(reopened.requiresInitialConnection, "Cancelled connection unlocked Home on relaunch")
        }
        await run("superseded initial index cannot unlock onboarding when its replacement fails") {
            let f = Fixture(); defer { f.close() }
            let first = Gate(), replacement = Gate()
            var sessionReads = 0
            TestTransport.handler = { request in
                if request.path.hasPrefix("v1/sessions?") {
                    sessionReads += 1
                    if sessionReads == 1 { await first.hold() }
                    else { await replacement.hold(); throw BridgeFailure(message: "Synthetic replacement index failure", code: "offline") }
                }
                return nil
            }
            let connecting = Task { await f.connect() }
            defer { first.release(); replacement.release(); connecting.cancel() }
            try await first.waitUntilEntered()
            let refreshing = Task { await f.store.refresh() }
            defer { refreshing.cancel() }
            try await replacement.waitUntilEntered()
            first.release(); await connecting.value
            replacement.release(); await refreshing.value
            try check(f.store.sessions.isEmpty && f.store.connection == .failed("Synthetic replacement index failure"), "Fixture did not supersede the initial index before replacement failure")
            try check(f.store.requiresInitialConnection && !f.store.hasConnectedBefore, "An index discarded by indexRequest guard was treated as successful onboarding")
            let reopened = AppStore(defaults: f.defaults); defer { reopened.disconnect() }
            try check(reopened.requiresInitialConnection, "Discarded initial index permanently unlocked Home")
        }
        await run("a successful replacement index completes initial onboarding") {
            let f = Fixture(); defer { f.close() }
            let first = Gate(), replacement = Gate()
            var sessionReads = 0
            TestTransport.handler = { request in
                if request.path.hasPrefix("v1/sessions?") {
                    sessionReads += 1
                    if sessionReads == 1 { await first.hold() }
                    else { await replacement.hold(); return listing("successful replacement") }
                }
                return nil
            }
            let connecting = Task { await f.connect() }
            defer { first.release(); replacement.release(); connecting.cancel() }
            try await first.waitUntilEntered()
            let refreshing = Task { await f.store.refresh() }
            defer { refreshing.cancel() }
            try await replacement.waitUntilEntered()
            first.release(); await connecting.value
            let gatedWhileReplacementPending = f.store.requiresInitialConnection
            replacement.release(); await refreshing.value
            try check(gatedWhileReplacementPending, "Discarded first index unlocked onboarding before its successful replacement")
            try check(f.store.session("S")?.title == "successful replacement task" && f.store.hasConnectedBefore && !f.store.requiresInitialConnection, "Applied replacement index failed to complete onboarding")
            try check(f.defaults.bool(forKey: "hasConnectedBefore"), "Replacement success was not durable")
        }
        await run("A to B clears old content and drafts before the first response") {
            let f = await fixture(); defer { f.close() }; seedPrivateA(f.store)
            let gate = Gate()
            TestTransport.handler = { request in
                if request.host == "b.invalid", request.path == "v1/status" { await gate.hold() }
                if request.path.hasPrefix("v1/sessions?") { return listing(request.host) }
                return nil
            }
            let switching = Task { await f.store.switchComputer(profileB) }
            defer { gate.release(); switching.cancel() }
            try await gate.waitUntilEntered()
            try check(f.store.activeProfileID == "B" && f.store.hostName == "Synthetic B" && f.store.connection == .connecting, "Target identity was not selected before its response")
            try checkOldStateCleared(f.store)
            gate.release(); await switching.value
            try check(f.store.connection.isOnline && f.store.session("S")?.title == "b.invalid task", "B sessions were not refreshed after switching")
        }
        await run("failed B keeps B selected and never redisplays A state") {
            let f = await fixture(); defer { f.close() }; seedPrivateA(f.store)
            let gate = Gate()
            TestTransport.handler = { request in
                if request.host == "b.invalid", request.path == "v1/status" {
                    await gate.hold()
                    throw BridgeFailure(message: "Synthetic B offline", code: "offline")
                }
                return nil
            }
            let switching = Task { await f.store.switchComputer(profileB) }
            defer { gate.release(); switching.cancel() }
            try await gate.waitUntilEntered(); gate.release(); await switching.value
            try check(f.store.activeProfileID == "B" && f.store.hostName == "Synthetic B", "Failure restored the wrong computer heading")
            try check(f.store.connection == .failed("Synthetic B offline") && f.store.errorMessage == "Synthetic B offline", "B failure was hidden or reported as success")
            try checkOldStateCleared(f.store)
            try check(!TestTransport.requests.contains { $0.host == "b.invalid" && $0.method != "GET" }, "Failure caused a remote write")
        }
        await run("fast B to C ignores B late index and does not restart C event stream") {
            let f = await fixture(); defer { f.close() }
            let gate = Gate()
            TestTransport.handler = { request in
                if request.host == "b.invalid", request.path.hasPrefix("v1/sessions?") { await gate.hold() }
                if request.path.hasPrefix("v1/sessions?") { return listing(request.host) }
                return nil
            }
            let toB = Task { await f.store.switchComputer(profileB) }
            defer { gate.release(); toB.cancel() }
            try await gate.waitUntilEntered()
            await f.store.switchComputer(profileC)
            f.store.setDraft("C draft", for: "S")
            f.store.transcripts["S"] = [ChatMessage(id: "C-message", role: .assistant, text: "C transcript")]
            await drainActor()
            try check(TestTransport.eventSubscriptions["c.invalid"] == 1, "C stream did not start exactly once")
            gate.release(); await toB.value; await drainActor()
            try check(f.store.activeProfileID == "C" && f.store.hostName == "c.invalid" && f.store.connection.isOnline, "Late B response overwrote C identity/status")
            try check(f.store.session("S")?.title == "c.invalid task" && f.store.messages("S").map(\.text) == ["C transcript"] && f.store.drafts["S"] == "C draft", "Late B index overwrote C content or draft")
            try check(TestTransport.eventSubscriptions["c.invalid"] == 1 && TestTransport.eventSubscriptions["b.invalid"] == nil, "Old connect continuation restarted the current stream")
        }
        await run("choosing the connected computer refreshes without clearing or reconnecting") {
            let f = await fixture(); defer { f.close() }; seedPrivateA(f.store)
            await drainActor()
            let subscriptions = TestTransport.eventSubscriptions["a.invalid"]
            TestTransport.requests.removeAll()
            let gate = Gate()
            TestTransport.handler = { request in
                if request.path.hasPrefix("v1/sessions?") { await gate.hold(); return listing("refreshed A") }
                return nil
            }
            let refresh = Task { await f.store.switchComputer(f.profile) }
            defer { gate.release(); refresh.cancel() }
            try await gate.waitUntilEntered()
            try check(f.store.session("S") != nil && f.store.messages("S").map(\.text) == ["A transcript"] && f.store.drafts["S"] == "A draft", "Same-host selection cleared current content")
            try check(f.store.goals["S"] != nil && f.store.hostAgents["S"] != nil, "Same-host refresh discarded active host information")
            try check(!TestTransport.requests.contains { $0.path == "v1/status" }, "Same-host selection reconnected")
            gate.release(); await refresh.value; await drainActor()
            try check(f.store.session("S")?.title == "refreshed A task", "Same-host selection did not refresh sessions")
            try check(TestTransport.eventSubscriptions["a.invalid"] == subscriptions, "Same-host refresh restarted its event stream")
        }
        await run("each computer restores its text and attachment drafts including failed reconnect") {
            let f = await fixture(); defer { f.close() }
            let attachmentA = Attachment(name: "A.txt", data: Data("A attachment".utf8), mimeType: "text/plain")
            let attachmentB = Attachment(name: "B.txt", data: Data("B attachment".utf8), mimeType: "text/plain")
            f.store.setDraft("A saved draft", for: "S")
            f.store.setDraftAttachments([attachmentA], for: "S")
            await f.store.switchComputer(profileB)
            try check(f.store.drafts["S"] == nil && f.store.draftAttachments["S"] == nil, "A draft appeared on B")
            f.store.setDraft("B saved draft", for: "S")
            f.store.setDraftAttachments([attachmentB], for: "S")
            await f.store.switchComputer(f.profile)
            await f.store.loadDraftAttachments(for: "S")
            try check(f.store.drafts["S"] == "A saved draft" && f.store.draftAttachments["S"] == [attachmentA], "Returning to A lost or mixed its draft")
            TestTransport.handler = { request in
                if request.host == "b.invalid", request.path == "v1/status" { throw BridgeFailure(message: "Synthetic B offline", code: "offline") }
                return nil
            }
            await f.store.switchComputer(profileB)
            await f.store.loadDraftAttachments(for: "S")
            try check(f.store.activeProfileID == "B" && f.store.drafts["S"] == "B saved draft" && f.store.draftAttachments["S"] == [attachmentB], "Failed reconnect did not restore only B's local draft")
            try check(f.store.sessions.isEmpty && f.store.transcripts.isEmpty, "B's restored draft caused A content to return")
            let reopened = AppStore(defaults: f.defaults); defer { reopened.disconnect() }
            await reopened.loadDraftAttachments(for: "S")
            try check(reopened.activeProfileID == "B" && reopened.drafts["S"] == "B saved draft" && reopened.draftAttachments["S"] == [attachmentB], "Reopen after failed switch lost the selected scope's draft")
        }

        let report: [String: JSONValue] = ["cases": .number(Double(results.count)), "passed": .number(Double(results.filter(\.passed).count)), "failed": .number(Double(results.filter { !$0.passed }.count)), "assertions": .number(Double(assertions))]
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(JSONValue.object(report))) as! [String: Any]
        object["results"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(results))
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        print("\(results.filter(\.passed).count)/\(results.count) passed; \(assertions) assertions; no network, Simulator, Keychain or service access")
        if results.contains(where: { !$0.passed }) { exit(1) }
    }
}
