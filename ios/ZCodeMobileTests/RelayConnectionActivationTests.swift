import XCTest
@testable import ZCodeMobile

private actor RelayActivationIndex: RemoteTransport {
    private var blocked: Bool
    private let failModels: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let requested: @Sendable () -> Void
    init(blocked: Bool = false, failModels: Bool = false, requested: @escaping @Sendable () -> Void = {}) {
        self.blocked = blocked; self.failModels = failModels; self.requested = requested
    }
    func release() { blocked = false; let pending = waiters; waiters = []; for waiter in pending { waiter.resume() } }
    func get<T: Decodable & Sendable>(_ path: String, as type: T.Type) async throws -> T {
        requested()
        if blocked { await withCheckedContinuation { waiters.append($0) } }
        if failModels && path == "v1/models" { throw BridgeFailure(message: "Synthetic index failure", code: "fixture_index_failure") }
        let body: String
        if path == "v1/projects" { body = #"{"projects":[{"id":"new-project","name":"New project","path":"/demo/new"}]}"# }
        else if path.hasPrefix("v1/sessions") {
            body = #"{"sessions":[{"id":"new-task","title":"New task","projectId":"new-project","projectName":"New project","status":"idle","updatedAt":"2026-10-31T00:00:00Z","source":"official-relay","capabilities":{"read":true,"send":true,"stop":true,"approve":true,"changes":true}}]}"#
        } else if path == "v1/models" { body = #"{"models":[]}"# }
        else { throw BridgeFailure(message: "Unexpected fixture read", code: "fixture_route") }
        return try JSONDecoder().decode(T.self, from: Data(body.utf8))
    }
    func mutate<T: Decodable & Sendable>(_ path: String, method: String, body: [String: JSONValue], as type: T.Type) async throws -> T {
        throw BridgeFailure(message: "No mutation allowed", code: "fixture_mutation")
    }
    func events(after cursor: String?, onEvent: @Sendable (BridgeEnvelope) async -> Void) async throws {}
}

@MainActor final class RelayConnectionActivationTests: XCTestCase {
    private struct EmptyAccount: RelayAccountStorage {
        var value: RelayAccountSession? = nil
        func read() throws -> RelayAccountSession? { value }
        func save(_ session: RelayAccountSession) throws {}
        func clear() throws {}
    }
    private func fixture(accountRelay: Bool = false) throws -> (AppStore, UserDefaults, String, ConnectionProfile, ConnectionProfile, String) {
        let domain = "relay-activation-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        let old = ConnectionProfile(id: UUID().uuidString, name: "Old computer", baseURL: "https://zcode.z.ai/remote/v4",
                                    relayDeviceID: "old-device", relayWorkspaceKey: "/old", relayServiceID: RelayPairing.officialServiceID)
        let session = RelayAccountSession(identity: .init(provider: .bigmodel, userID: "fixture-owner", name: "Demo"), jwt: "synthetic-not-a-real-account", expiresAt: nil)
        let new = ConnectionProfile(id: UUID().uuidString, name: "New computer", baseURL: "https://zcode.z.ai/remote/v4",
                                    relayDeviceID: "new-device", relayWorkspaceKey: "/new", relayServiceID: accountRelay ? OfficialRelay.serviceID : RelayPairing.officialServiceID,
                                    relayAccountScope: accountRelay ? session.identity.scope : nil, relayMachineID: accountRelay ? "new-machine" : nil)
        defaults.set(try JSONEncoder().encode([old]), forKey: "connections"); defaults.set(old.id, forKey: "activeConnection")
        defaults.set(true, forKey: "hasConnectedBefore")
        let store = AppStore(defaults: defaults, officialAccount: OfficialAccountController(storage: EmptyAccount(value: accountRelay ? session : nil)))
        store.hostName = old.name; store.projects = [.init(id: "old-project", name: "Old project", path: "/old")]
        let raw = accountRelay ? "https://zcode.z.ai/remote/v4?sid=new-device&mid=new-machine&name=New%20computer" : "https://zcode.z.ai/remote/v4?sid=new-device&hash=synthetic-fixture-only-0000000000000000&name=New%20computer"
        return (store, defaults, domain, old, new, raw)
    }
    func testNewComputerPublishesOnlyAfterIndexAndSurvivesRelaunch() async throws {
        let (store, defaults, domain, old, new, raw) = try fixture()
        defer { store.disconnect(); defaults.removePersistentDomain(forName: domain); CredentialStore.remove(new.id) }
        let started = expectation(description: "Initial index requested"); started.assertForOverFulfill = false
        let index = RelayActivationIndex(blocked: true, requested: { started.fulfill() })
        let task = Task { try await store.activateRelayConnection(new, using: index, pairingPayload: raw, appVersion: "3.17.1") }
        await fulfillment(of: [started], timeout: 3)
        XCTAssertEqual(store.activeProfileID, old.id); XCTAssertEqual(store.profiles, [old])
        XCTAssertFalse(store.connection.isOnline)
        await index.release(); try await task.value
        XCTAssertEqual(store.activeProfileID, new.id); XCTAssertEqual(store.hostName, "New computer")
        XCTAssertEqual(store.profiles.count, 2); XCTAssertTrue(store.profiles.contains(old)); XCTAssertTrue(store.profiles.contains(new))
        XCTAssertEqual(store.sessions.map(\.id), ["new-task"]); XCTAssertEqual(store.projects.map(\.id), ["new-project"])
        XCTAssertTrue(store.connection.isOnline)
        let reopened = AppStore(defaults: defaults, officialAccount: OfficialAccountController(storage: EmptyAccount()))
        XCTAssertEqual(reopened.activeProfileID, new.id); XCTAssertEqual(reopened.hostName, new.name)
        XCTAssertEqual(reopened.profiles.count, 2)
    }
    func testAccountComputerIsAddedBesideLegacyConnectionAndSelected() async throws {
        let (store, defaults, domain, old, new, raw) = try fixture(accountRelay: true)
        defer { store.disconnect(); defaults.removePersistentDomain(forName: domain); CredentialStore.remove(new.id) }
        try await store.activateRelayConnection(new, using: RelayActivationIndex(), pairingPayload: raw, appVersion: "3.17.1")
        XCTAssertEqual(store.activeProfileID, new.id); XCTAssertEqual(store.hostName, new.name)
        XCTAssertEqual(store.profiles.count, 2); XCTAssertTrue(store.profiles.contains(old))
        let reopened = AppStore(defaults: defaults, officialAccount: store.officialAccount)
        XCTAssertEqual(reopened.activeProfileID, new.id); XCTAssertEqual(reopened.hostName, new.name)
        XCTAssertEqual(reopened.profiles.count, 2)
    }
    func testForeignAccountCannotPublishAComputer() async throws {
        let (store, defaults, domain, old, profile, raw) = try fixture(accountRelay: true)
        var foreign = profile; foreign.relayAccountScope = "zai:another-owner"
        defer { store.disconnect(); defaults.removePersistentDomain(forName: domain); CredentialStore.remove(profile.id) }
        do { try await store.activateRelayConnection(foreign, using: RelayActivationIndex(), pairingPayload: raw, appVersion: nil); XCTFail("Wrong account must fail") }
        catch { XCTAssertEqual((error as? RelayFailure)?.code, "account_mismatch") }
        XCTAssertEqual(store.activeProfileID, old.id); XCTAssertEqual(store.profiles, [old])
        XCTAssertNil(CredentialStore.read(profile.id))
    }
    func testFailedNewIndexPreservesSavedComputer() async throws {
        let (store, defaults, domain, old, new, raw) = try fixture()
        defer { store.disconnect(); defaults.removePersistentDomain(forName: domain); CredentialStore.remove(new.id) }
        do { try await store.activateRelayConnection(new, using: RelayActivationIndex(failModels: true), pairingPayload: raw, appVersion: nil); XCTFail("Expected failed index") }
        catch { XCTAssertEqual((error as? BridgeFailure)?.code, "fixture_index_failure") }
        XCTAssertEqual(store.activeProfileID, old.id); XCTAssertEqual(store.hostName, old.name)
        XCTAssertEqual(store.profiles, [old]); XCTAssertFalse(store.connection.isOnline)
        XCTAssertNil(CredentialStore.read(new.id))
    }
    func testCancelledIndexCannotPublishNewComputer() async throws {
        let (store, defaults, domain, old, new, raw) = try fixture()
        defer { store.disconnect(); defaults.removePersistentDomain(forName: domain); CredentialStore.remove(new.id) }
        let started = expectation(description: "Index started"); started.assertForOverFulfill = false
        let index = RelayActivationIndex(blocked: true, requested: { started.fulfill() })
        let task = Task { try await store.activateRelayConnection(new, using: index, pairingPayload: raw, appVersion: nil) }
        await fulfillment(of: [started], timeout: 3); store.disconnect(); await index.release()
        do { try await task.value; XCTFail("Old generation must not apply") } catch is CancellationError {}
        XCTAssertEqual(store.activeProfileID, old.id); XCTAssertEqual(store.profiles, [old])
    }
    func testFreshIndexDoesNotRestoreOldComputerReadingCache() async throws {
        let (store, defaults, domain, _, new, raw) = try fixture()
        defer { store.disconnect(); defaults.removePersistentDomain(forName: domain); CredentialStore.remove(new.id) }
        let cached: [String: Any] = ["savedAt": Date().timeIntervalSinceReferenceDate, "sessions": [], "projects": [], "hostName": "Stale cached computer"]
        defaults.set(try JSONSerialization.data(withJSONObject: cached), forKey: AppStore.connectionCacheScope(new) + "|readingState.v1")
        try await store.activateRelayConnection(new, using: RelayActivationIndex(), pairingPayload: raw, appVersion: nil)
        XCTAssertEqual(store.hostName, new.name); XCTAssertEqual(store.projects.map(\.id), ["new-project"])
        XCTAssertEqual(store.sessions.map(\.id), ["new-task"])
    }
    func testAutomaticProjectUsesHostPreferenceOrSingleAvailableProject() throws {
        func workspace(_ path: String) throws -> RelayWorkspace {
            try JSONDecoder().decode(RelayWorkspace.self, from: Data("{\"kind\":\"local\",\"workspacePath\":\"\(path)\"}".utf8))
        }
        let a = try workspace("/a"), b = try workspace("/b")
        func bootstrap(_ rows: [RelayWorkspace], active: String? = nil) -> RelayBootstrap {
            .init(windowControlSessionId: nil, workspaces: rows, tasks: nil, initialViewState: nil, mobileViewState: nil, activeWorkspaceKey: active, activeTaskId: nil)
        }
        XCTAssertEqual(AppStore.automaticWorkspace(bootstrap([a]))?.id, "/a")
        XCTAssertEqual(AppStore.automaticWorkspace(bootstrap([a, b], active: "/b"))?.id, "/b")
        XCTAssertNil(AppStore.automaticWorkspace(bootstrap([a, b])))
        XCTAssertNil(AppStore.automaticWorkspace(bootstrap([])))
    }
}
