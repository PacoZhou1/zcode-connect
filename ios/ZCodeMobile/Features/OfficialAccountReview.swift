#if DEBUG
import Foundation

/// Offline display fixtures use a separate defaults domain and memory-only credentials.
/// They never read, replace, or sign out the user's real Keychain accounts.
@MainActor enum OfficialAccountReview {
    static func makeStore(_ scenario: String) -> AppStore {
        let domain = "dev.paco.zcode.mobile.account-review"
        let defaults = UserDefaults(suiteName: domain)!
        defaults.removePersistentDomain(forName: domain)
        if scenario == "existing" { defaults.set(true, forKey: "hasConnectedBefore") }
        let providers: [RelayAccountProvider] = scenario == "both" ? [.zai, .bigmodel]
            : RelayAccountProvider(rawValue: scenario).map { [$0] } ?? []
        let sessions = providers.map { provider in
            RelayAccountSession(identity: .init(provider: provider, userID: "review-" + provider.rawValue, name: "Demo"),
                                jwt: "synthetic-review-only", expiresAt: nil)
        }
        let storage = ReviewStorage(sessions)
        let api = providers.isEmpty ? OfficialRelayAPI() : OfficialRelayAPI(http: ReviewHTTP())
        return AppStore(defaults: defaults, officialAccount: OfficialAccountController(api: api, storage: storage))
    }
    private final class ReviewStorage: RelayAccountStorage, @unchecked Sendable {
        private let lock = NSLock()
        private var sessions: [RelayAccountSession]
        private var selected: RelayAccountProvider?
        init(_ sessions: [RelayAccountSession]) { self.sessions = sessions; selected = sessions.last?.identity.provider }
        func read() throws -> RelayAccountSession? { lock.withLock { sessions.first { $0.identity.provider == selected } } }
        func readAccounts() throws -> [RelayAccountSession] { lock.withLock { sessions } }
        func save(_ session: RelayAccountSession) throws {
            lock.withLock { sessions.removeAll { $0.identity.provider == session.identity.provider }; sessions.append(session); selected = session.identity.provider }
        }
        func select(_ provider: RelayAccountProvider) throws -> RelayAccountSession? {
            lock.withLock { selected = provider; return sessions.first { $0.identity.provider == provider } }
        }
        func remove(_ provider: RelayAccountProvider) throws {
            lock.withLock { sessions.removeAll { $0.identity.provider == provider }; if selected == provider { selected = nil } }
        }
        func clear() throws { if let provider = try read()?.identity.provider { try remove(provider) } }
    }
    private struct ReviewHTTP: RelayHTTPTransport {
        func send(_ request: URLRequest, limit: Int) async throws -> RelayHTTPReply {
            if request.url?.path == "/api/v1/remote/token" { throw RelayFailure("review_attempt_started", "Demo connection attempt started") }
            guard request.url?.path == "/api/v1/remote/device" else { throw OfficialRelay.failure("account_login_required") }
            return .init(status: 200, body: try RelayJSON.object(["code": .int(0), "data": .array([])]).data())
        }
    }
}
#endif
