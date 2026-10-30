import XCTest
@testable import ZCodeMobile

final class RelayAccountKeychainTests: XCTestCase {
    func testDeviceOnlyAccountRoundTripAndRemoval() throws {
        let vault = RelayAccountKeychain(account: "test-" + UUID().uuidString)
        defer { try? vault.clear() }
        XCTAssertNil(try vault.read())
        let identity = RelayAccountIdentity(provider: .zai, userID: "synthetic-user", name: "Demo")
        let session = RelayAccountSession(identity: identity, jwt: "synthetic-not-a-login-token", expiresAt: nil)
        try vault.save(session)
        XCTAssertEqual(try vault.read()?.identity.scope, "zai:synthetic-user")
        XCTAssertEqual(try vault.read()?.jwt, session.jwt)
        let other = RelayAccountSession(identity: .init(provider: .bigmodel, userID: "synthetic-other", name: "Demo"), jwt: "synthetic-replacement", expiresAt: nil)
        try vault.save(other)
        XCTAssertEqual(try vault.read()?.identity.scope, "bigmodel:synthetic-other")
        try vault.clear()
        XCTAssertNil(try vault.read())
    }
    @MainActor
    func testAccountCacheIsGuardedBeforeTheFirstUIFrame() throws {
        struct EmptyStorage: RelayAccountStorage {
            func read() throws -> RelayAccountSession? { nil }
            func save(_ session: RelayAccountSession) throws {}
            func clear() throws {}
        }
        let domain = "relay-v2-init-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let profile = ConnectionProfile(id: "synthetic-cold-profile", name: "Demo", baseURL: "https://zcode.z.ai/remote/v4",
            relayDeviceID: "synthetic-device", relayWorkspaceKey: "synthetic-workspace", relayServiceID: OfficialRelay.serviceID,
            relayAccountScope: "zai:synthetic-user")
        defaults.set(try JSONEncoder().encode([profile]), forKey: "connections")
        defaults.set(profile.id, forKey: "activeConnection")
        let store = AppStore(defaults: defaults, officialAccount: OfficialAccountController(storage: EmptyStorage()))
        XCTAssertNil(store.activeProfileID)
        XCTAssertNil(defaults.string(forKey: "activeConnection"))
        XCTAssertTrue(store.sessions.isEmpty)
    }
    @MainActor
    func testColdAccountConnectionHidesCachedContentUntilSignIn() async throws {
        struct EmptyStorage: RelayAccountStorage {
            func read() throws -> RelayAccountSession? { nil }
            func save(_ session: RelayAccountSession) throws { throw RelayFailure("test", "No credential writes expected") }
            func clear() throws {}
        }
        let domain = "relay-v2-cold-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let account = OfficialAccountController(storage: EmptyStorage())
        let store = AppStore(defaults: defaults, officialAccount: account)
        let profile = ConnectionProfile(id: "synthetic-profile", name: "Demo", baseURL: "https://zcode.z.ai/remote/v4",
            relayDeviceID: "synthetic-device", relayWorkspaceKey: "synthetic-workspace", relayServiceID: OfficialRelay.serviceID,
            relayAccountScope: "zai:synthetic-user")
        store.profiles = [profile]; store.activeProfileID = profile.id
        store.sessions = ReferenceData.sessions
        store.drafts = ["synthetic-session": "private synthetic draft"]
        await store.start()
        XCTAssertNil(store.activeProfileID)
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertTrue(store.transcripts.isEmpty)
        XCTAssertTrue(store.drafts.isEmpty)
        XCTAssertEqual(store.profiles.count, 1, "Keep the saved computer; hide account content until reauthorized")
    }
    @MainActor
    func testAccountAndDeviceCacheNamespacesRemainSeparate() {
        var profile = ConnectionProfile(id: "fixture-profile", name: "Demo", baseURL: "https://zcode.z.ai/remote/v4",
            relayDeviceID: "device-a", relayWorkspaceKey: "workspace", relayServiceID: OfficialRelay.serviceID,
            relayAccountScope: "zai:synthetic-user")
        let original = AppStore.connectionCacheScope(profile)
        profile.relayDeviceID = "device-b"
        XCTAssertNotEqual(original, AppStore.connectionCacheScope(profile))
        profile.relayDeviceID = "device-a"; profile.relayAccountScope = "bigmodel:synthetic-user"
        XCTAssertNotEqual(original, AppStore.connectionCacheScope(profile))
        XCTAssertFalse(original.contains("synthetic-user"))
        profile.relayServiceID = RelayPairing.officialServiceID
        XCTAssertEqual(AppStore.connectionCacheScope(profile), "fixture-profile|https://zcode.z.ai/remote/v4")
    }
    func testLiveOfficialAuthorizationInitAndPendingPoll() async throws {
        for provider in RelayAccountProvider.allCases {
            let api = OfficialRelayAPI()
            let flow = try await api.beginLogin(provider: provider)
            XCTAssertEqual(flow.provider, provider)
            XCTAssertTrue(flow.expiresAt > Date())
            let session = try await api.poll(flow)
            XCTAssertNil(session)
        }
    }
}
