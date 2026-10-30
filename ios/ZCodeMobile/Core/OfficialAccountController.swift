import Foundation
import Observation
import Security

protocol RelayAccountStorage: Sendable {
    func read() throws -> RelayAccountSession?
    func save(_ session: RelayAccountSession) throws
    func clear() throws
}

struct RelayAccountKeychain: RelayAccountStorage {
    let account: String
    init(account: String = "active-v2") { self.account = account }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "dev.paco.zcode.mobile.official-account",
         kSecAttrAccount as String: account]
    }
    func read() throws -> RelayAccountSession? {
        var query = query; query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw OfficialRelay.failure("account_storage") }
        guard let session = try? JSONDecoder().decode(RelayAccountSession.self, from: data) else {
            throw OfficialRelay.failure("account_storage")
        }
        return session
    }
    func save(_ session: RelayAccountSession) throws {
        let data = try JSONEncoder().encode(session)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw OfficialRelay.failure("account_storage") }
        var item = query; item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw OfficialRelay.failure("account_storage") }
    }
    func clear() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw OfficialRelay.failure("account_storage") }
    }
}

@MainActor @Observable
final class OfficialAccountController {
    private(set) var identity: RelayAccountIdentity?
    private(set) var devices: [RelayAccountDevice] = []
    private(set) var loadingDevices = false
    private(set) var signingIn = false
    var authorizationURL: URL?
    var failure: String?
    @ObservationIgnored private let api: OfficialRelayAPI
    @ObservationIgnored private let storage: any RelayAccountStorage
    @ObservationIgnored private var loginTask: Task<Void, Never>?
    @ObservationIgnored private var revision = UUID()
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var deviceRequest: UUID?
    @ObservationIgnored var onIdentityChange: @MainActor () -> Void = {}

    init(api: OfficialRelayAPI = OfficialRelayAPI(), storage: any RelayAccountStorage = RelayAccountKeychain()) {
        self.api = api; self.storage = storage
    }

    func restore() {
        guard !loaded else { return }; loaded = true
        do {
            if let session = try storage.read() {
                if session.isExpired { try storage.clear() }
                else { identity = session.identity; onIdentityChange() }
            }
        } catch { loaded = false; failure = error.localizedDescription }
    }

    func signIn(_ provider: RelayAccountProvider) {
        guard identity == nil else { return }
        cancelLogin(); signingIn = true; failure = nil
        let attempt = UUID(); revision = attempt
        loginTask = Task { [weak self, api] in
            do {
                let flow = try await api.beginLogin(provider: provider)
                guard let self, self.revision == attempt else { return }
                self.authorizationURL = flow.authorizationURL
                while Date() < flow.expiresAt {
                    try Task.checkCancellation()
                    if let session = try await api.poll(flow) {
                        try Task.checkCancellation()
                        guard self.revision == attempt else { return }
                        guard !session.isExpired else { throw OfficialRelay.failure("account_expired") }
                        try self.storage.save(session)
                        self.identity = session.identity; self.onIdentityChange()
                        self.signingIn = false; self.authorizationURL = nil
                        self.loginTask = nil
                        return
                    }
                    try await Task.sleep(for: .seconds(flow.interval))
                }
                throw OfficialRelay.failure("account_login_expired")
            } catch is CancellationError {
            } catch {
                guard let self, self.revision == attempt else { return }
                self.failure = error.localizedDescription; self.signingIn = false; self.authorizationURL = nil
                self.loginTask = nil
            }
        }
    }

    func cancelLogin() {
        revision = UUID(); loginTask?.cancel(); loginTask = nil; signingIn = false; authorizationURL = nil
    }

    func signOut() throws {
        // Do not claim logout succeeded if Keychain deletion failed.
        try storage.clear(); cancelLogin(); identity = nil; devices = []; failure = nil; loaded = true
        deviceRequest = nil; loadingDevices = false; onIdentityChange()
    }

    private func session(expectedScope: String? = nil) throws -> RelayAccountSession {
        restore()
        guard let session = try storage.read() else { throw OfficialRelay.failure("account_login_required") }
        guard !session.isExpired else {
            try signOut(); failure = OfficialRelay.failure("account_expired").localizedDescription
            throw OfficialRelay.failure("account_expired")
        }
        guard expectedScope == nil || session.identity.scope == expectedScope else { throw OfficialRelay.failure("account_mismatch") }
        return session
    }

    private func checkCurrent(_ session: RelayAccountSession) throws {
        try Task.checkCancellation()
        guard try storage.read()?.jwt == session.jwt, identity?.scope == session.identity.scope else { throw CancellationError() }
    }

    private func invalidateIfCurrent(_ session: RelayAccountSession, error: Error) throws {
        if (error as? RelayFailure)?.code == "account_expired" {
            guard try storage.read()?.jwt == session.jwt else { throw CancellationError() }
            try signOut()
            failure = OfficialRelay.failure("account_expired").localizedDescription
        }
    }

    func refreshDevices() async {
        let requestID = UUID(); deviceRequest = requestID
        loadingDevices = true; failure = nil
        let currentRevision = revision
        defer { if deviceRequest == requestID { loadingDevices = false; deviceRequest = nil } }
        do {
            let session = try session()
            do {
                let devices = try await api.devices(session: session)
                try checkCurrent(session); guard revision == currentRevision, deviceRequest == requestID else { return }
                self.devices = devices
            } catch { try invalidateIfCurrent(session, error: error); throw error }
        } catch is CancellationError {
        } catch { if revision == currentRevision && deviceRequest == requestID { failure = error.localizedDescription } }
    }

    func terminalToken(expectedScope: String? = nil) async throws -> (token: String, scope: String) {
        let session = try session(expectedScope: expectedScope)
        do {
            let token = try await api.terminalToken(session: session)
            try checkCurrent(session)
            return (token, session.identity.scope)
        } catch { try invalidateIfCurrent(session, error: error); throw error }
    }

    /// A stored MID is only a preference. A fresh, authenticated list must prove ownership,
    /// and multiple online windows are deliberately left to the user's selection.
    func replacementDevice(machineID: String, excludingSID: String, expectedScope: String) async throws -> RelayAccountDevice? {
        let session = try session(expectedScope: expectedScope)
        do {
            let devices = try await api.devices(session: session)
            try checkCurrent(session)
            let candidates = devices.filter { $0.machineID == machineID && $0.online }
            return candidates.count == 1 && candidates[0].id != excludingSID ? candidates[0] : nil
        } catch { try invalidateIfCurrent(session, error: error); throw error }
    }
}
