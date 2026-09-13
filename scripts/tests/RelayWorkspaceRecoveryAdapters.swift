import Foundation

// This suite enters the production Store's Relay branch, using production DTOs.
// Both RelayClient and RelayRemoteTransport are replaced in full by Store-level
// API stubs. It does not test the production socket, handshake or Relay protocol,
// and does not use an HTTP connection/profile reclassification as a substitute.
@MainActor enum RelayWorkspaceProbe {
    struct Call: Equatable { let operation: String; let device: String; let workspace: String? }
    static var calls: [Call] = []
    static var handler: (@MainActor (Call) async throws -> RelayBootstrap?)?
    static var listings: [String: RelayBootstrap] = [:]
    static func reset() { calls = []; handler = nil; listings = [:] }
    static func invoke(_ operation: String, device: String, workspace: String? = nil) async throws -> RelayBootstrap? {
        let call = Call(operation: operation, device: device, workspace: workspace)
        calls.append(call)
        if let value = try await handler?(call) { return value }
        return listings[device]
    }
    static func record(_ operation: String, device: String, workspace: String? = nil) {
        calls.append(.init(operation: operation, device: device, workspace: workspace))
    }
    static func count(_ operation: String, device: String? = nil) -> Int {
        calls.filter { $0.operation == operation && (device == nil || $0.device == device) }.count
    }
}

actor RelayClient {
    private var device = "unpaired"
    init(clientID: String) throws {}
    func deviceID() -> String { device }
    func connect(pairing: RelayPairing, confirmedControllerReplacement: Bool) async throws {
        guard confirmedControllerReplacement else { throw TestFailure(message: "Store omitted explicit controller confirmation") }
        device = pairing.deviceID
        _ = try await RelayWorkspaceProbe.invoke("pair", device: device)
    }
    func bootstrap() async throws -> RelayBootstrap {
        guard let result = try await RelayWorkspaceProbe.invoke("bootstrap", device: device) else { throw TestFailure(message: "Missing synthetic Relay bootstrap") }
        return result
    }
    func workspaces() async throws -> RelayBootstrap {
        guard let result = try await RelayWorkspaceProbe.invoke("workspaces", device: device) else { throw TestFailure(message: "Missing synthetic Relay workspace list") }
        return result
    }
    func openWorkspace(key: String) async throws -> RelayBridge {
        _ = try await RelayWorkspaceProbe.invoke("open", device: device, workspace: key)
        return RelayBridge(bridgeSessionId: "fixture-bridge-\(device)-\(key)", bridgeGeneration: 1,
            recoveryId: nil, kind: "local", workspaceKey: key, workspacePath: key,
            workspaceIdentity: nil, remoteSessionId: nil, initialTaskId: nil)
    }
    func disconnect() async { await RelayWorkspaceProbe.record("disconnect", device: device) }
}

actor RelayRemoteTransport: RemoteTransport {
    let fixtureHost: String
    private var eventContinuation: AsyncStream<TestEvent>.Continuation?
    init(client: RelayClient, bootstrap: RelayBootstrap, bridge: RelayBridge, hostName: String) async throws {
        let device = await client.deviceID()
        fixtureHost = "relay:\(device):\(bridge.workspaceKey)"
        _ = try await RelayWorkspaceProbe.invoke("adapter", device: device, workspace: bridge.workspaceKey)
    }
    func get<T: Decodable & Sendable>(_ path: String, as type: T.Type) async throws -> T {
        try await request(path, method: "GET", body: [:], as: type)
    }
    func mutate<T: Decodable & Sendable>(_ path: String, method: String, body: [String: JSONValue], as type: T.Type) async throws -> T {
        try await request(path, method: method, body: body, as: type)
    }
    private func request<T: Decodable & Sendable>(_ path: String, method: String, body: [String: JSONValue], as type: T.Type) async throws -> T {
        let value = try await TestTransport.request(.init(host: fixtureHost, method: method, path: path, body: body))
        return try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }
    func events(after cursor: String?, onEvent: @Sendable (BridgeEnvelope) async -> Void) async throws {
        let host = fixtureHost
        let pair = AsyncStream<TestEvent>.makeStream()
        eventContinuation = pair.continuation
        await MainActor.run {
            TestTransport.eventSubscriptions[host, default: 0] += 1
            TestTransport.subscribers[host] = pair.continuation
        }
        for await event in pair.stream { await onEvent(event.envelope); event.delivered.resume() }
        try await Self.exiting(host)
    }
    @MainActor private static func exiting(_ host: String) async throws { try await TestTransport.eventExitHandler?(host) }
    func shutdown() async { eventContinuation?.finish() }
}
