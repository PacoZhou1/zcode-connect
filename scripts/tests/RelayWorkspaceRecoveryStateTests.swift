import Foundation

@MainActor private final class RelayFixture {
    let suite = "dev.paco.relay-workspace-tests.\(UUID().uuidString)"
    let defaults: UserDefaults
    let store: AppStore
    init(profiles: [ConnectionProfile] = []) throws {
        defaults = UserDefaults(suiteName: suite)!
        defaults.set(false, forKey: "hasConnectedBefore")
        defaults.set(try JSONEncoder().encode(profiles), forKey: "connections")
        defaults.set(profiles.first?.id, forKey: "activeConnection")
        for profile in profiles {
            defaults.set(try JSONEncoder().encode(["S": "draft-\(profile.id)"]),
                         forKey: "\(profile.id)|\(profile.baseURL)|drafts")
        }
        store = AppStore(defaults: defaults)
    }
    func close() { store.disconnect(); defaults.removePersistentDomain(forName: suite) }
}

@main struct RelayWorkspaceRecoveryStateTests {
    @MainActor static var results: [TestResult] = []
    @MainActor static var assertions = 0
    @MainActor static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        assertions += 1
        if try !condition() { throw TestFailure(message: message) }
    }
    @MainActor static func drain() async { for _ in 0..<100 { await Task.yield() } }
    @MainActor static func run(_ name: String, _ body: () async throws -> Void) async {
        await drain(); TestTransport.reset(); RelayWorkspaceProbe.reset()
        OutboxTestSandbox.directory = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(UUID().uuidString)
        do { try await body(); results.append(.init(name: name, passed: true, detail: "all assertions passed")); print("PASS \(name)") }
        catch { let detail = (error as? TestFailure)?.message ?? String(describing: error); results.append(.init(name: name, passed: false, detail: detail)); print("FAIL \(name): \(detail)") }
    }
    static func raw(_ device: String = "device-A") -> String {
        "https://zcode.z.ai/remote/v4?sid=\(device)&hash=synthetic-fixture-only-0000000000000000&name=Synthetic&app_version=fixture"
    }
    static func profile(_ id: String = "saved-A", device: String = "device-A", workspace: String = "/closed") -> ConnectionProfile {
        .init(id: id, name: "Saved \(id)", baseURL: "https://zcode.z.ai/remote/v4", relayDeviceID: device, relayWorkspaceKey: workspace)
    }
    static func workspace(_ path: String, attachable: Bool = true) -> RelayWorkspace {
        .init(kind: attachable ? "local" : "remote", workspacePath: path, workspaceIdentity: nil,
              remoteSessionId: nil, connectionState: attachable ? "connected" : "disconnected", lastConnectionError: nil)
    }
    static func listing(_ workspaces: [RelayWorkspace]) -> RelayBootstrap {
        .init(windowControlSessionId: "fixture-control", workspaces: workspaces, tasks: [], initialViewState: nil,
              mobileViewState: nil, activeWorkspaceKey: nil, activeTaskId: nil)
    }
    @MainActor private static func savedRecovery(_ f: RelayFixture, profile: ConnectionProfile) async throws -> RelayWorkspaceSelectionContext {
        await f.store.connect(profile, token: raw(profile.relayDeviceID!), confirmedControllerReplacement: true)
        guard let context = f.store.relayWorkspaceSelection else { throw TestFailure(message: "Successful pairing lost its unavailable-workspace recovery context") }
        return context
    }
    @MainActor static func cancelled(_ operation: () async throws -> Void) async throws {
        do { try await operation(); throw TestFailure(message: "Stale operation unexpectedly succeeded") }
        catch is CancellationError { }
    }

    @MainActor static func main() async throws {
        for attachable in [false, true] {
            await run(attachable ? "missing saved workspace keeps its one confirmed pairing" : "unattachable saved workspace keeps its one confirmed pairing") {
                let saved = profile()
                let f = try RelayFixture(profiles: [saved]); defer { f.close() }
                let rows = attachable ? [workspace("/B")] : [workspace("/closed", attachable: false), workspace("/B")]
                RelayWorkspaceProbe.listings["device-A"] = listing(rows)
                let context = try await savedRecovery(f, profile: saved)
                try check(RelayWorkspaceProbe.count("pair") == 1 && RelayWorkspaceProbe.count("bootstrap") == 1 && RelayWorkspaceProbe.count("open") == 0, "Fallback repeated pairing or opened an invalid workspace")
                try check(RelayWorkspaceProbe.count("disconnect") == 0 && f.store.relayWorkspaces == rows, "Fallback discarded the already-confirmed pairing/list")
                try check(f.store.sheet?.id == "pairing" && context.name == saved.name && !context.reason.isEmpty, "Fallback is not surfaced through the shared pairing destination")
                try check(f.store.isCurrentRelaySelection(context) && !f.store.connection.isOnline && !f.store.hasConnectedBefore && f.store.errorMessage == nil, "Workspace selection was reported as a completed or failed connection")
                try check(f.store.drafts["S"] == "draft-saved-A" && f.store.profiles == [saved], "Fallback changed the old profile or its draft scope")
            }
        }

        await run("choosing an alternative workspace reuses pairing and restores that profile's drafts") {
            let old = profile(), target = profile("saved-B", workspace: "/B")
            let f = try RelayFixture(profiles: [old, target]); defer { f.close() }
            RelayWorkspaceProbe.listings["device-A"] = listing([workspace("/B")])
            let context = try await savedRecovery(f, profile: old)
            try await f.store.completeRelayPairing(workspaceKey: "/B", name: target.name, context: context)
            await drain()
            try check(RelayWorkspaceProbe.count("pair") == 1 && RelayWorkspaceProbe.count("bootstrap") == 1 && RelayWorkspaceProbe.count("open") == 1, "Choosing B performed a second pairing or duplicate open")
            try check(RelayWorkspaceProbe.calls.first { $0.operation == "open" }?.workspace == "/B", "Wrong workspace opened")
            try check(f.store.connection.isOnline && f.store.hasConnectedBefore && f.store.relayWorkspaceSelection == nil, "Successful index did not complete the recovered connection")
            try check(f.store.isCurrentRelaySelection(context) && f.store.activeProfileID == target.id && f.store.drafts["S"] == "draft-saved-B", "Success lost UI generation ownership or loaded the wrong draft scope")
            let oldDrafts = try JSONDecoder().decode([String: String].self, from: f.defaults.data(forKey: "\(old.id)|\(old.baseURL)|drafts")!)
            try check(oldDrafts["S"] == "draft-saved-A" && f.store.profiles.contains(old), "Alternative workspace overwrote the old saved connection/draft")
            try check(TestTransport.eventSubscriptions["relay:device-A:/B"] == 1 && !TestTransport.requests.contains { $0.path == "v1/status" }, "Recovery used HTTP connection setup or missed Relay streaming")
        }

        await run("empty workspace list can refresh and a local unavailable guard preserves selection") {
            let saved = profile(); let f = try RelayFixture(profiles: [saved]); defer { f.close() }
            RelayWorkspaceProbe.listings["device-A"] = listing([])
            let context = try await savedRecovery(f, profile: saved)
            RelayWorkspaceProbe.listings["device-A"] = listing([workspace("/B")])
            try await f.store.refreshRelayWorkspaces(context: context)
            try check(f.store.relayWorkspaces.map(\.id) == ["/B"] && RelayWorkspaceProbe.count("workspaces") == 1 && RelayWorkspaceProbe.count("pair") == 1, "Refresh requires re-pairing or does not replace the live list")
            RelayWorkspaceProbe.handler = { call in
                if call.operation == "open" { throw RelayFailure("workspace_unavailable", "synthetic workspace unavailable") }
                return nil
            }
            do {
                try await f.store.completeRelayPairing(workspaceKey: "/B", name: "B", context: context)
                throw TestFailure(message: "Unavailable workspace was reported as attached")
            } catch let error as BridgeFailure { try check(error.code == "relay_workspace_unavailable", "Client guard was not normalized to the UI contract") }
            try check(f.store.isCurrentRelaySelection(context) && f.store.relayWorkspaceSelection?.id == context.id && RelayWorkspaceProbe.count("disconnect") == 0, "Recoverable workspace guard discarded the pairing")
            try check(!f.store.connection.isOnline && !f.store.hasConnectedBefore && f.store.errorMessage == nil, "Workspace guard produced fake success/global failure")
        }

        await run("stale selection refresh and cancel cannot act on a reused-attempt newer pairing") {
            let saved = profile(); let f = try RelayFixture(profiles: [saved]); defer { f.close() }
            RelayWorkspaceProbe.listings["device-A"] = listing([workspace("/B")])
            RelayWorkspaceProbe.listings["device-C"] = listing([workspace("/C")])
            let old = try await savedRecovery(f, profile: saved)
            let current = try await f.store.beginRelayPairing(raw("device-C"), confirmedControllerReplacement: true, attempt: old.attempt)
            let before = RelayWorkspaceProbe.calls
            try await cancelled { try await f.store.completeRelayPairing(workspaceKey: "/C", name: "C", context: old) }
            try await cancelled { try await f.store.refreshRelayWorkspaces(context: old) }
            f.store.cancelRelayPairing(context: old)
            try check(!f.store.isCurrentRelaySelection(old) && f.store.isCurrentRelaySelection(current) && old.epoch != current.epoch, "Attempt reuse bypassed epoch isolation")
            try check(RelayWorkspaceProbe.calls.filter { ["open", "workspaces"].contains($0.operation) }.count == before.filter { ["open", "workspaces"].contains($0.operation) }.count, "An old UI operation reached the new Relay client")
            try check(f.store.relayWorkspaces.map(\.id) == ["/C"], "Old cancellation changed the new workspace selection")
            f.store.cancelRelayPairing(context: current)
            try check(f.store.connection == .disconnected && f.store.relayWorkspaces.isEmpty && !f.store.isCurrentRelaySelection(current), "Current cancellation did not terminate its own pairing")
        }

        for throwsLate in [false, true] {
            await run("late workspace refresh \(throwsLate ? "error" : "result") cannot overwrite another computer") {
                let saved = profile(); let f = try RelayFixture(profiles: [saved]); defer { f.close() }
                RelayWorkspaceProbe.listings["device-A"] = listing([workspace("/B")])
                RelayWorkspaceProbe.listings["device-C"] = listing([workspace("/C")])
                let context = try await savedRecovery(f, profile: saved)
                let gate = Gate(); defer { gate.release() }
                RelayWorkspaceProbe.handler = { call in
                    if call.operation == "workspaces", call.device == "device-A" {
                        await gate.hold()
                        if throwsLate { throw RelayFailure("controller_replaced", "synthetic late replacement") }
                        return listing([workspace("/late-A")])
                    }
                    return nil
                }
                let refresh = Task { try await f.store.refreshRelayWorkspaces(context: context) }
                try await gate.waitUntilEntered()
                let target = profile("saved-C", device: "device-C", workspace: "/C")
                f.store.profiles.append(target)
                await f.store.connect(target, token: raw("device-C"), confirmedControllerReplacement: true)
                gate.release(); try await cancelled { try await refresh.value }
                try check(f.store.connection.isOnline && f.store.activeProfileID == target.id && f.store.relayWorkspaces.map(\.id) == ["/C"], "Old refresh contaminated the current computer")
                try check(f.store.relayWorkspaceSelection == nil && f.store.errorMessage == nil, "Old refresh displayed a stale recovery/error")
                try check(RelayWorkspaceProbe.count("disconnect", device: "device-C") == 0, "Old refresh disconnected the new computer")
            }
        }

        await run("late workspace open cannot construct an adapter or persist into the next computer") {
            let saved = profile(); let f = try RelayFixture(profiles: [saved]); defer { f.close() }
            RelayWorkspaceProbe.listings["device-A"] = listing([workspace("/B")])
            RelayWorkspaceProbe.listings["device-C"] = listing([workspace("/C")])
            let context = try await savedRecovery(f, profile: saved)
            let gate = Gate(); defer { gate.release() }
            RelayWorkspaceProbe.handler = { call in if call.operation == "open", call.device == "device-A" { await gate.hold() }; return nil }
            let opening = Task { try await f.store.completeRelayPairing(workspaceKey: "/B", name: "B", context: context) }
            try await gate.waitUntilEntered()
            let target = profile("saved-C", device: "device-C", workspace: "/C")
            f.store.profiles.append(target)
            await f.store.connect(target, token: raw("device-C"), confirmedControllerReplacement: true)
            gate.release(); try await cancelled { try await opening.value }
            try check(RelayWorkspaceProbe.count("adapter", device: "device-A") == 0 && RelayWorkspaceProbe.count("adapter", device: "device-C") == 1, "A late open continued adapter initialization")
            try check(f.store.connection.isOnline && f.store.activeProfileID == target.id && !f.store.profiles.contains { $0.relayWorkspaceKey == "/B" }, "Old workspace was persisted or selected after switching computers")
            try check(f.store.errorMessage == nil && f.store.relayWorkspaceSelection == nil, "Old open replaced the new connection UI state")
        }

        for stage in ["pair", "bootstrap", "workspaces", "open", "index"] {
            await run("current \(stage) failure drops pairing and never marks initial setup complete") {
                let saved = profile(); let f = try RelayFixture(profiles: [saved]); defer { f.close() }
                RelayWorkspaceProbe.listings["device-A"] = listing([workspace("/B")])
                var context: RelayWorkspaceSelectionContext?
                if !["pair", "bootstrap"].contains(stage) { context = try await savedRecovery(f, profile: saved) }
                RelayWorkspaceProbe.handler = { call in
                    if call.operation == stage { throw RelayFailure(stage == "pair" ? "controller_replaced" : "relay_disconnected", "synthetic current failure") }
                    return nil
                }
                if stage == "index" {
                    TestTransport.handler = { request in if request.path.hasPrefix("v1/sessions?") { throw URLError(.networkConnectionLost) }; return nil }
                }
                if let context {
                    do {
                        if stage == "workspaces" { try await f.store.refreshRelayWorkspaces(context: context) }
                        else { try await f.store.completeRelayPairing(workspaceKey: "/B", name: "B", context: context) }
                        throw TestFailure(message: "Current transport failure was reported as successful")
                    } catch is RelayFailure { } catch is URLError { }
                    try check(!f.store.isCurrentRelaySelection(context) && f.store.errorMessage == nil, "Failed picker retained a valid context or emitted a global alert")
                } else {
                    await f.store.connect(saved, token: raw(), confirmedControllerReplacement: true)
                    try check(f.store.errorMessage != nil, "Saved reconnect failure lost its visible error")
                }
                await drain()
                if case .failed = f.store.connection { } else { throw TestFailure(message: "Current failure has no failed connection state") }
                try check(f.store.relayWorkspaceSelection == nil && f.store.relayWorkspaces.isEmpty && !f.store.hasConnectedBefore, "Fatal error retained a selectable pairing or marked first setup complete")
                try check(RelayWorkspaceProbe.count("disconnect", device: "device-A") == 1, "Fatal error did not close exactly its current Relay connection")
            }
        }

        await run("saved available workspace connects directly without presenting recovery") {
            let saved = profile(workspace: "/B"); let f = try RelayFixture(profiles: [saved]); defer { f.close() }
            RelayWorkspaceProbe.listings["device-A"] = listing([workspace("/B")])
            await f.store.connect(saved, token: raw(), confirmedControllerReplacement: true)
            try check(RelayWorkspaceProbe.count("pair") == 1 && RelayWorkspaceProbe.count("bootstrap") == 1 && RelayWorkspaceProbe.count("open") == 1, "Normal saved reconnect changed its operation count")
            try check(f.store.connection.isOnline && f.store.activeProfileID == saved.id && f.store.hasConnectedBefore, "Normal reconnect did not complete its index/profile lifecycle")
            try check(f.store.relayWorkspaceSelection == nil && f.store.sheet == nil && f.store.drafts["S"] == "draft-saved-A", "Normal reconnect presented recovery or lost its drafts")
        }

        await run("dismiss during initial pairing blocks late bootstrap and preserves disconnected state") {
            let f = try RelayFixture(); defer { f.close() }
            RelayWorkspaceProbe.listings["device-A"] = listing([workspace("/B")])
            let gate = Gate(); defer { gate.release() }
            RelayWorkspaceProbe.handler = { call in if call.operation == "pair" { await gate.hold() }; return nil }
            let attempt = UUID()
            let pairing = Task { try await f.store.beginRelayPairing(raw(), confirmedControllerReplacement: true, attempt: attempt) }
            try await gate.waitUntilEntered()
            f.store.cancelRelayPairing(attempt: attempt)
            gate.release(); try await cancelled { _ = try await pairing.value }
            try check(RelayWorkspaceProbe.count("bootstrap") == 0 && RelayWorkspaceProbe.count("open") == 0, "Dismissed pairing continued into bootstrap or workspace open")
            try check(f.store.connection == .disconnected && f.store.relayWorkspaces.isEmpty && f.store.relayWorkspaceSelection == nil && !f.store.hasConnectedBefore, "Late pairing revived dismissed setup")
        }

        let object: [String: Any] = ["cases": results.count, "passed": results.filter(\.passed).count,
            "failed": results.filter { !$0.passed }.count, "assertions": assertions,
            "results": try JSONSerialization.jsonObject(with: JSONEncoder().encode(results))]
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        print("\(results.filter(\.passed).count)/\(results.count) passed; \(assertions) assertions; actual AppStore Relay branch, in-memory pairing/RPC adapters, no sockets or real control transfer")
        if results.contains(where: { !$0.passed }) { exit(1) }
    }
}
