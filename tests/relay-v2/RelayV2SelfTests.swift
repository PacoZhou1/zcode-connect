import Foundation

private struct CheckFailure: Error { let label: String }
private actor HTTPFixture: RelayHTTPTransport {
    enum Mode: Sendable { case normal, invalidToken, expired, businessError, malformedDevice, lateReady, forbiddenRedirect, multiWindow, pending }
    var mode: Mode
    var calls: [URLRequest] = []
    init(_ mode: Mode = .normal) { self.mode = mode }
    func send(_ request: URLRequest, limit: Int) async throws -> RelayHTTPReply {
        calls.append(request)
        guard request.url?.host == "zcode.z.ai", request.url?.scheme == "https" else { throw CheckFailure(label: "fixed origin") }
        let path = request.url!.path
        if mode == .forbiddenRedirect { return .init(status: 302, body: Data()) }
        if mode == .expired && path.hasSuffix("/token") { return .init(status: 401, body: Data()) }
        if mode == .businessError { return try reply(.object(["code": .int(3004), "msg": .string("fixture")])) }
        var data: RelayJSON
        if path.hasSuffix("/init") {
            data = .object(["flow_id": .string("synthetic-flow"), "authorize_url": .string("https://chat.z.ai/api/oauth/authorize?state=synthetic"),
                            "expires_at": .number(Date().timeIntervalSince1970 + 120), "poll_interval_sec": .int(1)])
        } else if path.contains("/poll/") {
            if mode == .lateReady { try? await Task.sleep(for: .milliseconds(200)) }
            if mode == .pending { return try reply(.object(["code": .int(0), "data": .object(["status": .string("pending")])])) }
            data = .object(["status": .string("ready"), "token": .string("synthetic-account-credential"),
                            "user": .object(["user_id": .string("test-user"), "name": .string("Demo")]),
                            "zai": .object(["access_token": .string("synthetic-provider-credential")])])
        } else if path.hasSuffix("/device") {
            data = .array([.object(["device_sid": .string("test-device"), "device_mid": .string("test-machine"),
                "online": mode == .malformedDevice ? .string("yes") : .bool(true), "created_at": .int(1),
                "meta": .object(["name": .string("Demo Mac"), "version": .string("3.17.1"), "future": .bool(true)]),
                "future": .int(1)])])
        } else if path.hasSuffix("/token") {
            data = .object(["token": .string(mode == .invalidToken ? "not-valid" : String(repeating: "x", count: 22)), "expires_in": .int(60), "future": .int(1)])
        } else { throw CheckFailure(label: "unexpected request") }
        if mode == .multiWindow, path.hasSuffix("/device"), let first = data.array?.first, var second = first.object {
            second["device_sid"] = .string("second-window"); data = .array([first, .object(second)])
        }
        return try reply(.object(["code": .int(0), "data": data, "logid": .object(["ignored": .bool(true)])]))
    }
    func reply(_ body: RelayJSON) throws -> RelayHTTPReply { .init(status: 200, body: try body.data()) }
    func requests() -> [URLRequest] { calls }
}

private final class MemoryAccountStorage: RelayAccountStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var value: RelayAccountSession?
    init(_ value: RelayAccountSession? = nil) { self.value = value }
    func read() throws -> RelayAccountSession? { lock.lock(); defer { lock.unlock() }; return value }
    func save(_ value: RelayAccountSession) throws { lock.lock(); defer { lock.unlock() }; self.value = value }
    func clear() throws { lock.lock(); defer { lock.unlock() }; value = nil }
}

private actor StrictV2Socket: RelaySocketTransport {
    let errorCode: String?
    var outgoing: [RelayJSON] = []
    var incoming: [String] = []
    var waiter: CheckedContinuation<String, any Error>?
    var closed = false
    var route: URL?
    init(errorCode: String? = nil) { self.errorCode = errorCode }
    func connect(to url: URL) async throws {
        guard url.host == "zcode.z.ai", url.path == "/api/v1/remote/ws2",
              URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "token" })?.value?.count == 22 else {
            throw CheckFailure(label: "V2 socket endpoint")
        }
        route = url
    }
    func send(text: String) async throws {
        let body = try RelayJSON(data: Data(text.utf8)); outgoing.append(body)
        guard let timestamp = body["client_ts"].integer, abs(Double(timestamp) - Date().timeIntervalSince1970) < 30 else {
            throw CheckFailure(label: "V2 Unix seconds")
        }
        if body["type"].string == "auth_init" {
            guard body["role"] == .null, body["device_sid"].string == "test-device" else { throw CheckFailure(label: "V2 auth fields") }
            if errorCode == "waiting" || errorCode == "wrong-device" || errorCode == "millis" {
                try push(.object(["type": .string("auth_ack"), "device_sid": .string(errorCode == "wrong-device" ? "other-device" : "test-device"),
                                  "terminal_sid": .string("test-terminal"), "pair_status": .string(errorCode == "waiting" ? "waiting" : "matched"),
                                  "server_ts": .int(errorCode == "millis" ? timestamp * 1000 : timestamp)]))
            } else if let errorCode {
                if errorCode == "challenge" { try push(.object(["type": .string("auth_challenge"), "nonce": .string("synthetic")])) }
                else { try push(.object(["type": .string("error"), "code": .string(errorCode)])) }
            } else {
                try push(.object(["type": .string("auth_ack"), "device_sid": .string("test-device"),
                                  "terminal_sid": .string("test-terminal"), "pair_status": .string("matched"), "server_ts": .int(timestamp)]))
            }
        } else if body["type"].string == "data", body["payload"]["zcode_type"].string == "bootstrap-request" {
            let workspace: RelayJSON = .object(["kind": .string("local"), "workspacePath": .string("/example"), "workspaceIdentity": .string("workspace-a")])
            let result: RelayJSON = .object(["workspaces": .array([workspace])])
            let payload: RelayJSON = .object(["zcode_type": .string("bootstrap-response"), "requestId": body["payload"]["requestId"], "result": result])
            try push(.object(["type": .string("data"), "payload": payload]))
        } else if body["type"].string == "pair_status_query" {
            guard body["device_sid"] == .null else { throw CheckFailure(label: "V2 heartbeat routing") }
            try push(.object(["type": .string("pair_status_ack"), "pair_status": .string("matched"), "server_ts": .int(timestamp)]))
        }
    }
    func push(_ body: RelayJSON) throws {
        let value = String(decoding: try body.data(), as: UTF8.self)
        if let waiter { self.waiter = nil; waiter.resume(returning: value) }
        else { incoming.append(value) }
    }
    func receive() async throws -> String {
        if !incoming.isEmpty { return incoming.removeFirst() }
        if closed { throw CancellationError() }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }
    func close() async { closed = true; waiter?.resume(throwing: CancellationError()); waiter = nil }
    func sent() -> [RelayJSON] { outgoing }
}

@main @MainActor
struct RelayV2SelfTests {
    static var passed: [String] = []
    static func check(_ label: String, _ condition: Bool) throws {
        guard condition else { throw CheckFailure(label: label) }; passed.append(label)
    }
    static func expect(_ label: String, code: String, operation: () async throws -> Void) async throws {
        do { try await operation(); throw CheckFailure(label: label) }
        catch let error as RelayFailure { try check(label, error.code == code) }
    }
    static func main() async throws {
        let url = "https://zcode.z.ai/remote/v4?sid=test-device&mid=test-machine&name=Demo&app_version=3.17.1"
        let pairing = try RelayPairing(payload: url)
        try check("V2 QR without legacy credential", pairing.usesAccount && pairing.serviceID == OfficialRelay.serviceID)
        try check("V2 no-SID entry opens account list", RelayPairing.isAccountDeviceList("https://zcode.z.ai/remote/v4?app_version=3.17.1"))
        try check("Duplicate routing fields rejected", !RelayPairing.isAccountDeviceList("https://zcode.z.ai/remote/v4?mid=a&mid=b"))
        try check("Foreign device-list origin rejected", !RelayPairing.isAccountDeviceList("https://other.example/remote/v4"))
        let old = try RelayPairing(payload: "https://zcode.z.ai/remote/v4?sid=test-device&hash=" + String(repeating: "a", count: 64))
        try check("Legacy official V1 preserved", !old.usesAccount)
        let custom = try RelayPairing(payload: "https://relay.example/zcode/remote/v4?sid=test-device&hash=" + String(repeating: "a", count: 64))
        try check("Legacy self-hosted V1 preserved", !custom.usesAccount && custom.isSelfHosted)
        do { _ = try custom.authenticatedSocketURL(oneTimeToken: String(repeating: "x", count: 22)); throw CheckFailure(label: "credential isolation") }
        catch let error as RelayFailure { try check("Account token cannot route to a custom relay", error.code == "account_login_required") }
        try check("Pairing descriptions redact credentials", !String(describing: pairing).contains("test-device"))

        let fixture = HTTPFixture(); let api = OfficialRelayAPI(http: fixture)
        let flow = try await api.beginLogin(provider: .zai)
        try check("Random polling proof is 32 bytes", flow.pollToken.count == 64)
        let session = try await api.poll(flow)!
        try check("Official grant supplies scoped account identity", session.identity.scope == "zai:test-user")
        try check("Session description redacts JWT", !String(describing: session).contains(session.jwt))
        let devices = try await api.devices(session: session)
        try check("Additive response fields accepted", devices.count == 1 && devices[0].name == "Demo Mac")
        try check("Device selection creates credential-free V2 QR", try RelayPairing(payload: devices[0].pairingURL()).usesAccount)
        let token = try await api.terminalToken(session: session)
        try check("One-time token parsed", token.count == 22)
        _ = try await api.terminalToken(session: session)
        let calls = await fixture.requests()
        try check("Each connection requests a new terminal token", calls.filter { $0.url?.path.hasSuffix("/token") == true }.count == 2)
        let tokenRequest = calls.first { $0.url?.path.hasSuffix("/token") == true }!
        try check("JWT only goes in Authorization header", tokenRequest.url?.query == nil && tokenRequest.value(forHTTPHeaderField: "Authorization") == "Bearer " + session.jwt)
        try check("Terminal role supplied to HTTP endpoint", try RelayJSON(data: tokenRequest.httpBody!)["role"].string == "terminal")
        try await expect("Reject malformed one-time token", code: "account_invalid_response") { _ = try await OfficialRelayAPI(http: HTTPFixture(.invalidToken)).terminalToken(session: session) }
        try await expect("Reject malformed device response", code: "account_invalid_response") { _ = try await OfficialRelayAPI(http: HTTPFixture(.malformedDevice)).devices(session: session) }
        try await expect("HTTP 200 business failure stays a failure", code: "account_login_expired") { _ = try await OfficialRelayAPI(http: HTTPFixture(.businessError)).terminalToken(session: session) }
        try await expect("Redirect is not a successful response", code: "account_network") { _ = try await OfficialRelayAPI(http: HTTPFixture(.forbiddenRedirect)).terminalToken(session: session) }

        let replacementAccount = OfficialAccountController(api: api, storage: MemoryAccountStorage(session))
        replacementAccount.restore()
        let replacement = try await replacementAccount.replacementDevice(machineID: "test-machine", excludingSID: "old-device", expectedScope: session.identity.scope)
        try check("SID recovery uses a fresh owned machine match", replacement?.id == "test-device")
        let same = try await replacementAccount.replacementDevice(machineID: "test-machine", excludingSID: "test-device", expectedScope: session.identity.scope)
        try check("SID recovery cannot loop on the rejected SID", same == nil)
        let multiAPI = OfficialRelayAPI(http: HTTPFixture(.multiWindow))
        let multiple = try await multiAPI.devices(session: session)
        let groups = RelayAccountComputer.group(multiple)
        try check("Multiple windows are grouped under one computer", groups.count == 1 && groups[0].onlineConnections.count == 2)
        let multiAccount = OfficialAccountController(api: multiAPI, storage: MemoryAccountStorage(session)); multiAccount.restore()
        let ambiguous = try await multiAccount.replacementDevice(machineID: "test-machine", excludingSID: "old-device", expectedScope: session.identity.scope)
        try check("Multiple owned windows never get an arbitrary automatic selection", ambiguous == nil)

        let vault = MemoryAccountStorage(session)
        let account = OfficialAccountController(api: OfficialRelayAPI(http: HTTPFixture(.expired)), storage: vault)
        account.restore()
        try await expect("Prevent account-scope substitution", code: "account_mismatch") { _ = try await account.terminalToken(expectedScope: "bigmodel:other") }
        try await expect("401 returns to sign-in", code: "account_expired") { _ = try await account.terminalToken() }
        try check("401 removes current persisted session", try vault.read() == nil && account.identity == nil)
        let cancelledVault = MemoryAccountStorage()
        let cancelled = OfficialAccountController(api: OfficialRelayAPI(http: HTTPFixture(.lateReady)), storage: cancelledVault)
        cancelled.signIn(.zai)
        try await Task.sleep(for: .milliseconds(50)); cancelled.cancelLogin()
        try await Task.sleep(for: .milliseconds(250))
        try check("Cancelled authorization cannot persist a late ready response", try cancelledVault.read() == nil && cancelled.identity == nil)

        let lateVault = MemoryAccountStorage()
        let late = OfficialAccountController(api: OfficialRelayAPI(http: HTTPFixture(.lateReady)), storage: lateVault)
        late.signIn(.zai)
        try await Task.sleep(for: .milliseconds(50)); late.browserDidDismiss()
        try check("Browser dismissal confirms instead of cancelling the authorization in flight", late.confirmingLogin && late.signingIn)
        try await Task.sleep(for: .milliseconds(300))
        try check("A late verified grant is saved and publishes the signed-in platform", late.identity?.provider == .zai && late.identities[.zai] != nil && late.loginCompletion != nil && !late.signingIn)
        try check("Successful grant closes the browser and clears transient progress", late.authorizationURL == nil && !late.confirmingLogin && late.loginProvider == nil)
        let closed = OfficialAccountController(api: OfficialRelayAPI(http: HTTPFixture(.pending)), storage: MemoryAccountStorage())
        closed.signIn(.bigmodel)
        try await Task.sleep(for: .milliseconds(50)); closed.browserDidDismiss()
        try await Task.sleep(for: .seconds(7))
        try check("Closing an unapproved browser never produces signed-in status", closed.identity == nil && closed.loginCompletion == nil && !closed.signingIn && closed.failure != nil)

        let socket = StrictV2Socket(); let client = try RelayClient(clientID: "test-client", transport: socket)
        try await client.connect(pairing: pairing, confirmedControllerReplacement: true, oneTimeToken: token)
        try check("Native client completes strict V2 handshake", await client.state == .paired)
        let bootstrap = try await client.bootstrap()
        try check("V2 carries native workspace bootstrap after authentication", bootstrap.workspaces.first?.id == "workspace-a")
        try await Task.sleep(for: .seconds(7))
        let frames = await socket.sent()
        try check("Native client sends V2 heartbeat without SID", frames.contains { $0["type"].string == "pair_status_query" && $0["device_sid"] == .null })
        try check("Native client sends Unix seconds", frames.allSatisfy { ($0["client_ts"].integer ?? Int.max) < 10_000_000_000 })
        await client.disconnect()
        for (wire, code) in [("AUTH_FAILED", "account_mismatch"), ("DEVICE_OFFLINE", "account_offline"), ("KICKED", "controller_replaced"), ("challenge", "relay_invalid_frame"), ("wrong-device", "relay_invalid_frame"), ("millis", "relay_invalid_frame")] {
            let badSocket = StrictV2Socket(errorCode: wire); let badClient = try RelayClient(clientID: "test-client", transport: badSocket)
            try await expect("V2 error handling: " + wire, code: code) { try await badClient.connect(pairing: pairing, confirmedControllerReplacement: true, oneTimeToken: token) }
            let sent = await badSocket.sent()
            try check("No legacy proof leaks after " + wire, !sent.contains { $0["type"].string == "auth_response" })
            await badClient.disconnect()
        }
        let waitingSocket = StrictV2Socket(errorCode: "waiting")
        let waitingClient = try RelayClient(clientID: "waiting-client", transport: waitingSocket)
        try await waitingClient.connect(pairing: pairing, confirmedControllerReplacement: true, oneTimeToken: token)
        try await Task.sleep(for: .milliseconds(100))
        try check("Waiting-to-matched heartbeat does not cancel a healthy connection", await waitingClient.state == .paired)
        await waitingClient.disconnect()
        if CommandLine.arguments.contains("--live-auth-preflight") {
            for provider in RelayAccountProvider.allCases {
                let live = OfficialRelayAPI(); let flow = try await live.beginLogin(provider: provider)
                let ready = try await live.poll(flow)
                try check("Live unauthenticated preflight: " + provider.rawValue, ready == nil)
            }
        }
        let report: [String: Any] = ["passed": passed.count, "checks": passed, "realAccountAuthorized": false]
        print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
    }
}
