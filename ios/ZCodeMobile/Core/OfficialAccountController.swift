import Foundation
import Observation
import Security

protocol RelayAccountStorage: Sendable {
    func read() throws -> RelayAccountSession?
    func save(_ session: RelayAccountSession) throws
    func clear() throws
    func readAccounts() throws -> [RelayAccountSession]
    func select(_ provider: RelayAccountProvider) throws -> RelayAccountSession?
    func remove(_ provider: RelayAccountProvider) throws
}

extension RelayAccountStorage {
    func readAccounts() throws -> [RelayAccountSession] { try read().map { [$0] } ?? [] }
    func select(_ provider: RelayAccountProvider) throws -> RelayAccountSession? {
        try readAccounts().first { $0.identity.provider == provider }
    }
    func remove(_ provider: RelayAccountProvider) throws {
        if try read()?.identity.provider == provider { try clear() }
    }
}

struct RelayAccountKeychain: RelayAccountStorage {
    let account: String
    init(account: String = "active-v2") { self.account = account }
    private struct Vault: Codable {
        var sessions: [String: RelayAccountSession] = [:]
        var selected: RelayAccountProvider?
    }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "dev.paco.zcode.mobile.official-account",
         kSecAttrAccount as String: account]
    }
    private func vault() throws -> Vault {
        var query = query; query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return Vault() }
        guard status == errSecSuccess, let data = result as? Data else { throw OfficialRelay.failure("account_storage") }
        if let vault = try? JSONDecoder().decode(Vault.self, from: data),
           vault.sessions.allSatisfy({ $0.key == $0.value.identity.provider.rawValue }) { return vault }
        // Migrate the original single-account value without dropping its valid login.
        if let session = try? JSONDecoder().decode(RelayAccountSession.self, from: data) {
            return Vault(sessions: [session.identity.provider.rawValue: session], selected: session.identity.provider)
        }
        throw OfficialRelay.failure("account_storage")
    }
    func read() throws -> RelayAccountSession? {
        let value = try vault(); return value.selected.flatMap { value.sessions[$0.rawValue] }
    }
    func readAccounts() throws -> [RelayAccountSession] { Array(try vault().sessions.values) }
    func save(_ session: RelayAccountSession) throws {
        var value = try vault(); value.sessions[session.identity.provider.rawValue] = session
        value.selected = session.identity.provider
        try write(value)
    }
    func select(_ provider: RelayAccountProvider) throws -> RelayAccountSession? {
        var value = try vault()
        guard let session = value.sessions[provider.rawValue], !session.isExpired else { return nil }
        value.selected = provider; try write(value); return session
    }
    func remove(_ provider: RelayAccountProvider) throws {
        var value = try vault(); value.sessions[provider.rawValue] = nil
        if value.selected == provider { value.selected = nil }
        try write(value)
    }
    func clear() throws {
        if let provider = try vault().selected { try remove(provider) }
    }
    private func write(_ vault: Vault) throws {
        if vault.sessions.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw OfficialRelay.failure("account_storage") }
            return
        }
        let data = try JSONEncoder().encode(vault)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw OfficialRelay.failure("account_storage") }
        var item = query; item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw OfficialRelay.failure("account_storage") }
    }
}

@MainActor @Observable
final class OfficialAccountController {
    private(set) var identity: RelayAccountIdentity?
    private(set) var identities: [RelayAccountProvider: RelayAccountIdentity] = [:]
    private(set) var loginProvider: RelayAccountProvider?
    private(set) var confirmingLogin = false
    private(set) var loginCompletion: UUID?
    @ObservationIgnored private var confirmationDeadline: Date?
    private(set) var devices: [RelayAccountDevice] = []
    private(set) var loadingDevices = false
    private(set) var signingIn = false
    var authorizationURL: URL?
    var failure: String?
    @ObservationIgnored private let api: OfficialRelayAPI
    @ObservationIgnored private let storage: any RelayAccountStorage
    @ObservationIgnored private var loginTask: Task<Void, Never>?
    @ObservationIgnored private var confirmationTask: Task<Void, Never>?
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
            identities = Dictionary(uniqueKeysWithValues: try storage.readAccounts().filter { !$0.isExpired }.map { ($0.identity.provider, $0.identity) })
            if let session = try storage.read() {
                if session.isExpired { try storage.clear() }
                else { identity = session.identity; onIdentityChange() }
            }
        } catch { loaded = false; failure = error.localizedDescription }
    }

    func useAccount(_ provider: RelayAccountProvider) {
        do {
            cancelLogin()
            guard let session = try storage.select(provider), !session.isExpired else {
                identities[provider] = nil; signIn(provider); return
            }
            identity = session.identity; devices = []; failure = nil
            deviceRequest = nil; loadingDevices = false
            onIdentityChange()
        } catch { failure = error.localizedDescription }
    }

    func signIn(_ provider: RelayAccountProvider) {
        guard identity?.provider != provider else { return }
        cancelLogin(); signingIn = true; loginProvider = provider; failure = nil
        let attempt = UUID(); revision = attempt
        loginTask = Task { [weak self, api] in
            do {
                let flow = try await api.beginLogin(provider: provider)
                guard let self, self.revision == attempt else { return }
                self.authorizationURL = flow.authorizationURL
                while Date() < min(flow.expiresAt, self.confirmationDeadline ?? flow.expiresAt) {
                    try Task.checkCancellation()
                    if let session = try await api.poll(flow) {
                        try Task.checkCancellation()
                        guard self.revision == attempt else { return }
                        guard !session.isExpired else { throw OfficialRelay.failure("account_expired") }
                        try self.storage.save(session)
                        self.identity = session.identity; self.identities[provider] = session.identity
                        self.devices = []; self.deviceRequest = nil; self.loadingDevices = false
                        self.onIdentityChange()
                        self.confirmationTask?.cancel(); self.confirmationTask = nil; self.confirmationDeadline = nil
                        self.signingIn = false; self.confirmingLogin = false; self.loginProvider = nil
                        self.authorizationURL = nil; self.loginCompletion = UUID()
                        self.loginTask = nil
                        return
                    }
                    let remaining = min(flow.expiresAt, self.confirmationDeadline ?? flow.expiresAt).timeIntervalSinceNow
                    try await Task.sleep(for: .seconds(min(flow.interval, max(0.05, remaining))))
                }
                throw OfficialRelay.failure(self.confirmingLogin ? "account_login_failed" : "account_login_expired")
            } catch is CancellationError {
            } catch {
                guard let self, self.revision == attempt else { return }
                self.confirmationTask?.cancel(); self.confirmationTask = nil; self.confirmationDeadline = nil
                self.failure = error.localizedDescription; self.signingIn = false; self.confirmingLogin = false; self.loginProvider = nil; self.authorizationURL = nil
                self.loginTask = nil
            }
        }
    }

    /// Safari can close just before the final poll arrives. Keep the flow alive briefly,
    /// but never treat closing a page as authorization or as a successful login.
    func browserDidDismiss() {
        guard signingIn else { return }
        authorizationURL = nil; confirmingLogin = true
        guard confirmationDeadline == nil else { return }
        confirmationDeadline = Date().addingTimeInterval(6)
        let attempt = revision
        confirmationTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(6)) } catch { return }
            guard let self, self.revision == attempt, self.signingIn else { return }
            // Also bound an HTTP poll that is still waiting on the network.
            self.cancelLogin()
            self.failure = OfficialRelay.failure("account_login_failed").localizedDescription
        }
    }

    func cancelLogin() {
        confirmationTask?.cancel(); confirmationTask = nil
        revision = UUID(); loginTask?.cancel(); loginTask = nil; signingIn = false; confirmingLogin = false; loginProvider = nil; confirmationDeadline = nil; authorizationURL = nil
    }

    func signOut() throws {
        guard let provider = try identity?.provider ?? storage.read()?.identity.provider else { return }
        try signOut(provider)
    }

    func signOut(_ provider: RelayAccountProvider) throws {
        // Remove only this platform, and never claim success if Keychain deletion failed.
        try storage.remove(provider)
        identities[provider] = nil
        if loginProvider == provider { cancelLogin() }
        if identity?.provider == provider {
            cancelLogin(); identity = nil; devices = []; deviceRequest = nil; loadingDevices = false
            onIdentityChange()
        }
        failure = nil; loaded = true
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
