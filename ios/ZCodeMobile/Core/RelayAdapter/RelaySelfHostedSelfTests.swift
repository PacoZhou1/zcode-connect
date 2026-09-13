#if RELAY_SELF_HOSTED_SELF_TESTS
import Foundation

private struct SelfHostedFailure: Error { let message: String }

/// The existing protocol fixture retains its official-shaped synthetic host.
/// This wrapper records the production client's approved custom endpoint; it
/// forwards only to that in-memory fixture and never opens a URLSession.
private actor SelfHostedSocket: RelaySocketTransport {
    let backing = MockRelaySocket()
    var requestedURLs: [URL] = []
    var approvedServices: [String] = []
    func connect(pairing: RelayPairing) async throws {
        approvedServices.append(pairing.serviceID)
        try await connect(to: pairing.relayURL)
    }
    func connect(to url: URL) async throws {
        requestedURLs.append(url)
        try await backing.connect(to: URL(string: RelayPairing.officialServiceID)!)
    }
    func send(text: String) async throws { try await backing.send(text: text) }
    func receive() async throws -> String { try await backing.receive() }
    func close() async { await backing.close() }
}

private final class RedirectResult: @unchecked Sendable {
    private let lock = NSLock()
    private var called = false
    private var rejected = false
    func capture(_ request: URLRequest?) { lock.lock(); defer { lock.unlock() }; called = true; rejected = request == nil }
    var passed: Bool { lock.lock(); defer { lock.unlock() }; return called && rejected }
}

@main @MainActor private struct RelaySelfHostedSelfTests {
    static let secret = "mock-pairing-value-0123456789-abcdef"
    static let official = "https://zcode.z.ai/remote/v4?sid=mock-desktop&hash=" + secret
    static var assertions = 0
    static var checks: [RelayJSON] = []
    static func check(_ passed: Bool, _ message: String) throws {
        assertions += 1
        if !passed { throw SelfHostedFailure(message: message) }
    }
    static func payload(host: String = "relay-a.example.invalid", page: String? = nil, endpoint: String? = nil, extra: [String: RelayJSON] = [:]) throws -> String {
        let value = RelayJSON.object([
            "transport": .string("zcode-relay"),
            "url": .string(page ?? "https://\(host)/zcode/remote/v4?sid=mock-desktop&hash=\(secret)&mid=fixture-mid&name=Fixture&app_version=fixture"),
            "relayURL": .string(endpoint ?? "wss://\(host)/zcode/ws"),
        ].merging(extra) { _, new in new })
        return String(data: try value.data(), encoding: .utf8)!
    }
    static func rejected(_ body: () throws -> Void) throws {
        do { try body(); throw SelfHostedFailure(message: "Invalid pairing was accepted") }
        catch let error as RelayFailure { try check(error.code == "relay_invalid_pairing" || error.code == "relay_invalid_frame", "Unexpected rejection code") }
    }
    static func run(_ name: String, _ body: () async throws -> Void) async {
        do { try await body(); checks.append(.object(["name": .string(name), "passed": .bool(true)])); print("PASS \(name)") }
        catch { let message = (error as? SelfHostedFailure)?.message ?? String(describing: error); checks.append(.object(["name": .string(name), "passed": .bool(false), "failure": .string(message)])); print("FAIL \(name): \(message)") }
    }
    static func attach(_ client: RelayClient, pairing: RelayPairing, directory: URL) async throws -> RelayRemoteTransport {
        try await client.connect(pairing: pairing, confirmedControllerReplacement: true)
        let bootstrap = try await client.bootstrap(), bridge = try await client.openWorkspace(key: "/workspace")
        return try await RelayRemoteTransport(client: client, bootstrap: bootstrap, bridge: bridge, hostName: "Synthetic custom service", journalDirectory: directory)
    }
    static func send(_ adapter: RelayRemoteTransport, text: String, id: String) async throws -> RelayJSON {
        try await adapter.mutate("v1/sessions/session-test/messages", body: ["text": .string(text), "inputId": .string(id)])
    }
    static func main() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "relay-self-hosted-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        await run("ordinary_official_pairing_and_hmac_remain_compatible") {
            let first = try RelayPairing(scannedURL: official), second = try RelayPairing(payload: official)
            try check(first.serviceID == RelayPairing.officialServiceID && !first.isSelfHosted, "Official identity changed")
            try check(first.profileURL.absoluteString == RelayPairing.officialProfileURL, "Official profile leaked a query")
            try check(first.challengeProof(nonce: "fixture-nonce") == second.challengeProof(nonce: "fixture-nonce"), "Payload parser changed the official proof")
        }
        await run("typed_custom_pairing_preserves_hmac_and_scopes_public_identity") {
            let pairing = try RelayPairing(payload: payload())
            try check(pairing.isSelfHosted && pairing.serviceID == "wss://relay-a.example.invalid/zcode/ws", "Custom service missing")
            try check(pairing.relayURL.query == "mid=fixture-mid" && pairing.profileURL.query == nil, "Routing or public profile incorrect")
            let officialPairing = try RelayPairing(scannedURL: official)
            try check(pairing.challengeProof(nonce: "fixture-nonce") == officialPairing.challengeProof(nonce: "fixture-nonce"), "Custom mode changed the official cryptographic contract")
            try check(!pairing.description.contains(secret) && !pairing.debugDescription.contains(secret) && !pairing.serviceID.contains(secret), "Sensitive pairing description")
        }
        await run("plain_custom_url_cannot_relax_official_scanner") {
            try rejected { _ = try RelayPairing(scannedURL: "https://relay-a.example.invalid/zcode/remote/v4?sid=mock-desktop&hash=\(secret)") }
            try rejected { _ = try RelayPairing(payload: "https://relay-a.example.invalid/zcode/remote/v4?sid=mock-desktop&hash=\(secret)") }
        }
        await run("typed_transport_missing_wrong_or_additional_fields_rejected") {
            for value: RelayJSON in [.string("bridge"), .null, .int(1)] { try rejected { _ = try RelayPairing(payload: payload(extra: ["transport": value])) } }
            try rejected { _ = try RelayPairing(payload: payload(extra: ["token": .string("not-a-relay-key")])) }
            try rejected { _ = try RelayPairing(payload: "{\"transport\":\"zcode-relay\",\"url\":\"https://relay-a.example.invalid\"}") }
        }
        await run("official_credentials_cannot_be_directed_to_custom_relay") {
            try rejected { _ = try RelayPairing(payload: payload(page: official)) }
            try rejected { _ = try RelayPairing(payload: payload(endpoint: "wss://zcode.z.ai/ws")) }
            try rejected { _ = try RelayPairing(payload: payload(host: "ZCODE.Z.AI.")) }
            try rejected { _ = try RelayPairing(payload: payload(page: official, endpoint: RelayPairing.officialServiceID)) }
        }
        await run("same_origin_enforces_host_and_effective_port") {
            try rejected { _ = try RelayPairing(payload: payload(endpoint: "wss://relay-b.example.invalid/zcode/ws")) }
            try rejected { _ = try RelayPairing(payload: payload(endpoint: "wss://relay-a.example.invalid:8443/zcode/ws")) }
            let pairing = try RelayPairing(payload: payload(host: "RELAY-A.example.invalid:443", endpoint: "wss://relay-a.example.invalid/zcode/ws"))
            try check(pairing.serviceID == "wss://relay-a.example.invalid/zcode/ws" && pairing.profileURL.port == nil, "Default port identity is unstable")
            let customPort = try RelayPairing(payload: payload(host: "relay-a.example.invalid:8443"))
            try check(customPort.serviceID == "wss://relay-a.example.invalid:8443/zcode/ws", "Custom TLS port lost")
        }
        await run("custom_endpoint_credentials_fragments_queries_and_paths_rejected") {
            for endpoint in ["ws://relay-a.example.invalid/zcode/ws", "wss://user:password@relay-a.example.invalid/zcode/ws", "wss://relay-a.example.invalid/zcode/ws#other", "wss://relay-a.example.invalid/zcode/ws?enroll=secret", "wss://relay-a.example.invalid/ws", "wss://relay-a.example.invalid/zcode/%77s"] {
                try rejected { _ = try RelayPairing(payload: payload(endpoint: endpoint)) }
            }
            try rejected { _ = try RelayPairing(payload: payload(page: "http://relay-a.example.invalid/zcode/remote/v4?sid=mock-desktop&hash=\(secret)")) }
            try rejected { _ = try RelayPairing(payload: payload(page: "https://relay-a.example.invalid/remote/v4?sid=mock-desktop&hash=\(secret)")) }
        }
        await run("custom_pairing_duplicate_unknown_fields_and_invalid_hash_rejected") {
            for suffix in ["&sid=another", "&hash=another", "&t=1&t=2", "&enroll=not-for-phone"] {
                try rejected { _ = try RelayPairing(payload: payload(page: "https://relay-a.example.invalid/zcode/remote/v4?sid=mock-desktop&hash=\(secret)" + suffix)) }
            }
            try rejected { _ = try RelayPairing(payload: payload(page: "https://relay-a.example.invalid/zcode/remote/v4?sid=mock-desktop&hash=short")) }
        }
        await run("saved_profile_identity_is_public_and_legacy_official_is_supported") {
            let pairing = try RelayPairing(payload: payload())
            let profile = ConnectionProfile(id: "fixture-profile", name: "Fixture", baseURL: pairing.profileURL.absoluteString, relayDeviceID: pairing.deviceID, relayWorkspaceKey: "/workspace", relayServiceID: pairing.serviceID)
            let data = try JSONEncoder().encode(profile), decoded = try JSONDecoder().decode(ConnectionProfile.self, from: data)
            try check(decoded == profile && !String(decoding: data, as: UTF8.self).contains(secret), "Profile did not preserve public identity")
            let old = try JSONDecoder().decode(ConnectionProfile.self, from: Data("{\"id\":\"old\",\"name\":\"Old\",\"baseURL\":\"https://zcode.z.ai/remote/v4\",\"relayDeviceID\":\"mock-desktop\",\"relayWorkspaceKey\":\"/workspace\"}".utf8))
            try check(old.relayServiceID == nil && RelayPairing.legacyServiceID(profileURL: old.baseURL) == RelayPairing.officialServiceID, "Old official profile cannot upgrade")
            try check(RelayPairing.legacyServiceID(profileURL: "https://relay-a.example.invalid/zcode/remote/v4") == nil, "Custom profile borrowed legacy official identity")
        }
        await run("unapproved_socket_url_rejected_without_creating_a_connection") {
            let socket = RelayURLSessionSocket()
            for text in ["wss://relay-a.example.invalid/zcode/ws", "ws://zcode.z.ai/ws", "wss://zcode.z.ai:8443/ws", "wss://user@zcode.z.ai/ws"] {
                do { try await socket.connect(to: URL(string: text)!); throw SelfHostedFailure(message: "Unapproved socket endpoint accepted") }
                catch let error as RelayFailure { try check(error.code == "relay_invalid_endpoint", "Wrong endpoint error") }
            }
            await socket.close()
        }
        await run("websocket_redirect_is_refused_before_any_target_request") {
            let session = URLSession(configuration: .ephemeral), url = URL(string: "https://relay-a.example.invalid/zcode/ws")!
            let task = session.dataTask(with: url), result = RedirectResult()
            RelaySocketRedirectDelegate().urlSession(session, task: task, willPerformHTTPRedirection: HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: [:])!, newRequest: URLRequest(url: URL(string: "https://relay-b.example.invalid/zcode/ws")!)) { result.capture($0) }
            try check(result.passed && task.state == .suspended, "Redirect followed or test task resumed")
            task.cancel(); session.invalidateAndCancel()
        }
        await run("production_client_uses_explicit_pairing_endpoint_and_original_frames") {
            let socket = SelfHostedSocket(), client = try RelayClient(clientID: "self-hosted-fixture", transport: socket, requestTimeout: 2), pairing = try RelayPairing(payload: payload())
            let adapter = try await attach(client, pairing: pairing, directory: folder.appending(path: "protocol"))
            let detail: BridgeDetail = try await adapter.get("v1/sessions/session-test")
            try check(await socket.approvedServices == [pairing.serviceID], "Client skipped explicit transport approval")
            try check(await socket.requestedURLs == [pairing.relayURL], "Client sent pairing to a different endpoint")
            let pairedService = await client.pairedServiceID
            try check(detail.messages.first?.text == "Hello" && pairedService == pairing.serviceID, "Original host protocol failed behind custom transport")
            await adapter.shutdown(); await client.disconnect()
        }
        await run("same_sid_on_new_service_clears_core_cache_and_invalidates_old_facade") {
            let socket = SelfHostedSocket(), client = try RelayClient(clientID: "self-hosted-fixture", transport: socket, requestTimeout: 2)
            let first = try await attach(client, pairing: RelayPairing(payload: payload()), directory: folder.appending(path: "switch"))
            let _: BridgeDetail = try await first.get("v1/sessions/session-test")
            try check(await client.currentProjection(sessionID: "session-test") != nil, "Missing baseline projection")
            await client.disconnect()
            let second = try await attach(client, pairing: RelayPairing(payload: payload(host: "relay-b.example.invalid")), directory: folder.appending(path: "switch"))
            try check(await client.currentProjection(sessionID: "session-test") == nil, "Another service inherited the old projection")
            do { let _: RelayJSON = try await first.get("v1/status"); throw SelfHostedFailure(message: "Old service facade remained usable") }
            catch let error as BridgeFailure { try check(error.code == "relay_workspace_changed", "Wrong service scope error") }
            let _: BridgeDetail = try await second.get("v1/sessions/session-test")
            await first.shutdown()
            try check(await client.currentProjection(sessionID: "session-test") != nil, "Old facade shutdown removed the new service subscription")
            await second.shutdown(); await client.disconnect()
        }
        await run("different_services_same_sid_workspace_input_id_have_separate_projects_and_journals") {
            let directory = folder.appending(path: "journals")
            var projects: [String] = []
            for (index, host) in ["relay-a.example.invalid", "relay-b.example.invalid"].enumerated() {
                let socket = SelfHostedSocket(), client = try RelayClient(clientID: "self-hosted-fixture", transport: socket, requestTimeout: 2)
                let adapter = try await attach(client, pairing: RelayPairing(payload: payload(host: host)), directory: directory)
                let value: RelayJSON = try await adapter.get("v1/projects"); projects.append(value["projects"].array!.first!["id"].string!)
                let sent = try await send(adapter, text: "Synthetic service \(index)", id: "same-input-id")
                try check(sent["accepted"].bool == true && sent["duplicate"].bool != true, "Cross-service command journal reused an acknowledgement")
                await adapter.shutdown(); await client.disconnect()
            }
            try check(Set(projects).count == 2, "Cross-service project ID collision")
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
            try check(files.count == 2, "Cross-service journal filename collision")
        }
        await run("official_old_journal_scope_remains_recoverable_without_command_resend") {
            let directory = folder.appending(path: "legacy"), expectedScope = "mock-desktop\n/workspace\nself-hosted-fixture"
            let oldURL = directory.appending(path: relayDigest(Data(expectedScope.utf8)) + ".json")
            for attempt in 0..<2 {
                let socket = SelfHostedSocket(), client = try RelayClient(clientID: "self-hosted-fixture", transport: socket, requestTimeout: 2)
                let adapter = try await attach(client, pairing: RelayPairing(scannedURL: official), directory: directory)
                let result = try await send(adapter, text: "Synthetic original official intent", id: "legacy-input")
                try check(result["accepted"].bool == true && result["duplicate"].bool == (attempt == 1), "Official replay changed after service scoping")
                let commands = await socket.backing.commands.count
                try check(commands == (attempt == 0 ? 1 : 0), "Official admitted command resent")
                await adapter.shutdown(); await client.disconnect()
            }
            try check(FileManager.default.fileExists(atPath: oldURL.path), "Official journal path migrated unexpectedly")
        }
        await run("scope_mismatch_and_controller_replacement_remain_terminal_errors") {
            let mismatch = RelayFailure.rejected(code: "AUTH_SCOPE_MISMATCH", paired: false)
            try check(mismatch.code == "relay_rejected" && mismatch.message.contains("AUTH_SCOPE_MISMATCH"), "Custom registration boundary was hidden")
            let replaced = RelayFailure.rejected(code: "KICKED", paired: true)
            try check(replaced.code == "controller_replaced" && replaced.outcomeUncertain, "Controller replacement lost pending-command uncertainty")
        }
        let passed = checks.allSatisfy { $0["passed"].bool == true }
        let report: RelayJSON = .object(["verifiedAt": .string(ISO8601DateFormatter().string(from: Date())), "passed": .bool(passed), "totalCount": .int(checks.count), "passedCount": .int(checks.filter { $0["passed"].bool == true }.count), "assertions": .int(assertions), "checks": .array(checks), "boundary": .string("Production pairing, client and facade over synthetic in-memory sockets and temporary journals. No live account, pairing credential, host CLI, model request or real relay connection. URLSession redirect test never resumes its synthetic task.")])
        try report.data().write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
        print(String(data: try report.data(), encoding: .utf8)!)
        if !passed { exit(1) }
    }
}
#endif
