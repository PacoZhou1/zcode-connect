import Foundation

@MainActor private final class SelfHostedStoreFixture {
    let suite = "dev.paco.self-hosted-relay.\(UUID().uuidString)"
    let defaults: UserDefaults
    let store: AppStore
    init(profiles: [ConnectionProfile] = [], credentials: [String: String] = [:]) throws {
        defaults = UserDefaults(suiteName: suite)!
        defaults.set(try JSONEncoder().encode(profiles), forKey: "connections")
        if let profile = profiles.first { defaults.set(profile.id, forKey: "activeConnection") }
        defaults.set(!profiles.isEmpty, forKey: "hasConnectedBefore")
        CredentialStore.values = credentials
        store = AppStore(defaults: defaults, reconnectDelay: { _ in await MainActor.run { SelfHostedRelayStateTests.delays += 1 }; await Task.yield() })
    }
    func close() { store.disconnect(); defaults.removePersistentDomain(forName: suite) }
}

@main @MainActor struct SelfHostedRelayStateTests {
    static let secret = "synthetic-fixture-only-0000000000000000"
    static let official = "https://zcode.z.ai/remote/v4?sid=device-A&hash=" + secret
    static var delays = 0
    static var assertions = 0
    static var results: [TestResult] = []
    static func raw(_ host: String = "relay-a.example.invalid", device: String = "device-A") throws -> String {
        String(data: try RelayJSON.object(["transport": .string("zcode-relay"), "url": .string("https://\(host)/zcode/remote/v4?sid=\(device)&hash=\(secret)&name=Synthetic"), "relayURL": .string("wss://\(host)/zcode/ws")]).data(), encoding: .utf8)!
    }
    static func profile(_ id: String = "saved-custom", host: String = "relay-a.example.invalid") throws -> ConnectionProfile {
        let pairing = try RelayPairing(payload: raw(host))
        return .init(id: id, name: "Synthetic", baseURL: pairing.profileURL.absoluteString, relayDeviceID: pairing.deviceID, relayWorkspaceKey: "/workspace", relayServiceID: pairing.serviceID)
    }
    static func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        assertions += 1; if try !value() { throw TestFailure(message: message) }
    }
    static func drain() async { for _ in 0..<150 { await Task.yield() } }
    private static func connect(_ f: SelfHostedStoreFixture, payload: String) async throws -> ConnectionProfile {
        let context = try await f.store.beginRelayPairing(payload, confirmedControllerReplacement: true)
        try await f.store.completeRelayPairing(workspaceKey: "/workspace", name: "Synthetic", context: context)
        await drain()
        guard let profile = f.store.activeProfile else { throw TestFailure(message: "No active profile after pairing") }
        return profile
    }
    static func run(_ name: String, _ body: () async throws -> Void) async {
        await drain(); TestTransport.reset(); RelayWorkspaceProbe.reset(); delays = 0
        OutboxTestSandbox.directory = URL(fileURLWithPath: CommandLine.arguments[1]).appending(path: UUID().uuidString)
        RelayWorkspaceProbe.listings["device-A"] = .init(windowControlSessionId: "fixture-control", workspaces: [
            .init(kind: "local", workspacePath: "/workspace", workspaceIdentity: nil, remoteSessionId: nil, connectionState: "connected", lastConnectionError: nil)
        ], tasks: [], initialViewState: nil, mobileViewState: nil, activeWorkspaceKey: nil, activeTaskId: nil)
        do { try await body(); results.append(.init(name: name, passed: true, detail: "all assertions passed")); print("PASS \(name)") }
        catch { let detail = (error as? TestFailure)?.message ?? String(describing: error); results.append(.init(name: name, passed: false, detail: detail)); print("FAIL \(name): \(detail)") }
    }
    static func main() async throws {
        await run("custom typed payload is kept in credential storage while profile contains only public identity") {
            let f = try SelfHostedStoreFixture(); defer { f.close() }
            let payload = try raw(), saved = try await connect(f, payload: payload)
            try check(f.store.connection.isOnline && saved.relayServiceID == "wss://relay-a.example.invalid/zcode/ws", "Custom service was not saved")
            try check(CredentialStore.values[saved.id] == payload, "Full typed payload was not preserved for reconnect")
            let data = f.defaults.data(forKey: "connections")!
            try check(!String(decoding: data, as: UTF8.self).contains(secret) && saved.baseURL == "https://relay-a.example.invalid/zcode/remote/v4", "Public profile leaked credential query")
        }
        await run("two services sharing sid and workspace retain independent profile and draft scopes") {
            let f = try SelfHostedStoreFixture(); defer { f.close() }
            let a = try await connect(f, payload: raw())
            f.defaults.set(try JSONEncoder().encode(["S": "Draft A"]), forKey: "\(a.id)|\(a.baseURL)|drafts")
            let b = try await connect(f, payload: raw("relay-b.example.invalid"))
            try check(a.id != b.id && f.store.profiles.count == 2, "Services sharing a SID overwrote a profile")
            try check(f.store.drafts["S"] == nil, "New service inherited another service's draft")
            await f.store.switchComputer(a, confirmedControllerReplacement: true); await drain()
            try check(f.store.activeProfileID == a.id && f.store.drafts["S"] == "Draft A", "Switch-back did not restore the correct draft scope")
            let credentialA = try raw(), credentialB = try raw("relay-b.example.invalid")
            try check(CredentialStore.values[a.id] == credentialA && CredentialStore.values[b.id] == credentialB, "A service overwrote another credential")
        }
        await run("existing official profile upgrades in place without losing old identifier or draft key") {
            let old = ConnectionProfile(id: "saved-official", name: "Official", baseURL: RelayPairing.officialProfileURL, relayDeviceID: "device-A", relayWorkspaceKey: "/workspace")
            let f = try SelfHostedStoreFixture(profiles: [old], credentials: [old.id: official]); defer { f.close() }
            f.defaults.set(try JSONEncoder().encode(["S": "Old official draft"]), forKey: "\(old.id)|\(old.baseURL)|drafts")
            await f.store.start(); await drain()
            try check(f.store.connection.isOnline && f.store.profiles.count == 1 && f.store.activeProfileID == old.id, "Legacy official profile lost its identity")
            try check(f.store.activeProfile?.relayServiceID == RelayPairing.officialServiceID && f.store.drafts["S"] == "Old official draft", "Legacy official scope was not retained")
            try check(CredentialStore.values[old.id] == official, "Official credential was rewritten to custom transport")
        }
        await run("saved custom service cannot use another service's keychain payload") {
            let p = try profile(), wrong = try raw("relay-b.example.invalid")
            let f = try SelfHostedStoreFixture(profiles: [p], credentials: [p.id: wrong]); defer { f.close() }
            await f.store.start(); await drain()
            try check(!f.store.connection.isOnline && RelayWorkspaceProbe.count("pair") == 0, "Cross-service credential reached a socket")
            let blocks = f.defaults.dictionary(forKey: "automaticConnectionBlocks") as? [String: String]
            try check(blocks?[p.id] == "relay_profile_mismatch" && delays == 0 && CredentialStore.values[p.id] == wrong, "Mismatch was retried or erased")
        }
        await run("saved same-service payload with different sid is rejected before networking") {
            let p = try profile(), f = try SelfHostedStoreFixture(profiles: [p], credentials: [p.id: raw(device: "device-B")]); defer { f.close() }
            await f.store.start(); await drain()
            try check(!f.store.connection.isOnline && RelayWorkspaceProbe.count("pair") == 0 && delays == 0, "SID mismatch acquired a different controller")
        }
        await run("official legacy identity cannot silently adopt a custom payload") {
            let old = ConnectionProfile(id: "saved-official", name: "Official", baseURL: RelayPairing.officialProfileURL, relayDeviceID: "device-A", relayWorkspaceKey: "/workspace")
            let f = try SelfHostedStoreFixture(profiles: [old], credentials: [old.id: raw()]); defer { f.close() }
            await f.store.start(); await drain()
            try check(!f.store.connection.isOnline && RelayWorkspaceProbe.count("pair") == 0 && f.store.profiles == [old], "Official profile migrated across service trust boundary")
        }
        await run("old HTTP bridge profile remains on the original transport") {
            let old = ConnectionProfile(id: "http-old", name: "HTTP fixture", baseURL: "https://http-bridge.example.invalid")
            let f = try SelfHostedStoreFixture(profiles: [old], credentials: [old.id: "synthetic-http-token"]); defer { f.close() }
            await f.store.start(); await drain()
            try check(f.store.connection.isOnline && f.store.profiles == [old] && RelayWorkspaceProbe.count("pair") == 0, "HTTP bridge was reclassified as Relay")
            try check(TestTransport.requests.contains { $0.path == "v1/status" }, "HTTP connection bypassed original status handshake")
        }
        await run("new custom pairing still requires explicit controller confirmation") {
            let f = try SelfHostedStoreFixture(); defer { f.close() }
            do { _ = try await f.store.beginRelayPairing(raw(), confirmedControllerReplacement: false); throw TestFailure(message: "Unconfirmed custom controller accepted") }
            catch let error as BridgeFailure { try check(error.code == "controller_confirmation_required", "Wrong confirmation error") }
            try check(RelayWorkspaceProbe.count("pair") == 0 && f.store.profiles.isEmpty, "Unconfirmed pairing had side effects")
        }
        await run("invalid replacement payload does not disconnect a valid selected service") {
            let f = try SelfHostedStoreFixture(); defer { f.close() }
            let saved = try await connect(f, payload: raw()), count = RelayWorkspaceProbe.count("pair")
            let invalid = String(data: try RelayJSON.object(["transport": .string("zcode-relay"), "url": .string(official), "relayURL": .string("wss://relay-a.example.invalid/zcode/ws")]).data(), encoding: .utf8)!
            do { _ = try await f.store.beginRelayPairing(invalid, confirmedControllerReplacement: true); throw TestFailure(message: "Invalid replacement accepted") }
            catch let error as RelayFailure { try check(error.code == "relay_invalid_pairing", "Wrong invalid-payload error") }
            try check(f.store.connection.isOnline && f.store.activeProfileID == saved.id && RelayWorkspaceProbe.count("pair") == count, "Invalid parser input tore down an unrelated connection")
        }
        await run("scope mismatch and kicked suspend automatic reconnect without claiming another controller") {
            for code in ["AUTH_SCOPE_MISMATCH", "KICKED"] {
                let p = try profile("saved-\(code)"), f = try SelfHostedStoreFixture(profiles: [p], credentials: [p.id: raw()])
                RelayWorkspaceProbe.handler = { call in if call.operation == "pair" { throw RelayFailure.rejected(code: code, paired: code == "KICKED") }; return nil }
                let count = RelayWorkspaceProbe.count("pair")
                await f.store.start(); await drain(); await f.store.applicationDidBecomeActive(); await drain()
                try check(!f.store.connection.isOnline && RelayWorkspaceProbe.count("pair") == count + 1 && delays == 0, "Terminal rejection retried control acquisition")
                let blocks = f.defaults.dictionary(forKey: "automaticConnectionBlocks") as? [String: String]
                try check(blocks?[p.id] == (code == "KICKED" ? "controller_replaced" : "relay_rejected"), "Terminal block lost its reason")
                f.close()
            }
        }
        let passed = results.allSatisfy(\.passed)
        let output = SelfHostedStoreReport(cases: results.count, passed: results.filter(\.passed).count, failed: results.filter { !$0.passed }.count, assertions: assertions, results: results)
        try JSONEncoder().encode(output).write(to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .atomic)
        if !passed { exit(1) }
    }
}

struct SelfHostedStoreReport: Codable { let cases: Int; let passed: Int; let failed: Int; let assertions: Int; let results: [TestResult] }
