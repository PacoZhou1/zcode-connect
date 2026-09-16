import Foundation
import OSLog
import CryptoKit

/// Bounded, credential-free transport evidence for physical-device diagnosis.
private final class RelayConnectionTrace: @unchecked Sendable {
    static let shared = RelayConnectionTrace()
    private let lock = NSLock()
    func record(_ stage: String) {
        lock.lock(); defer { lock.unlock() }
        guard let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        let file = directory.appendingPathComponent("relay-connection-trace.log")
        let line = "\(Date().timeIntervalSince1970) \(stage)\n"
        var data = (try? Data(contentsOf: file)) ?? Data()
        if data.count > 65_536 { data = Data() }
        data.append(contentsOf: line.utf8)
        try? data.write(to: file, options: .atomic)
    }
}

private enum RelayChildHistoryOperation {
    @TaskLocal static var sessionID: String?
}

/// Injectable so the complete client can be exercised without contacting a real account.
public protocol RelaySocketTransport: Sendable {
    func connect(to url: URL) async throws
    func connect(pairing: RelayPairing) async throws
    func send(text: String) async throws
    func receive() async throws -> String
    func close() async
}

public extension RelaySocketTransport {
    func connect(pairing: RelayPairing) async throws { try await connect(to: pairing.relayURL) }
}

/// A pairing authorizes one endpoint, never a redirect to a different server.
final class RelaySocketRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Official and explicitly paired custom services use normal platform TLS.
/// No custom trust root, certificate bypass, or insecure HTTP fallback is installed.
public actor RelayURLSessionSocket: RelaySocketTransport {
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var tracedSends = 0
    public init() {}
    public func connect(to url: URL) async throws {
        guard url.scheme == "wss", url.host == "zcode.z.ai", url.path == "/ws",
              url.port == nil || url.port == 443, url.user == nil, url.password == nil, url.fragment == nil else {
            throw RelayFailure("relay_invalid_endpoint", "A custom relay endpoint requires explicit pairing information.")
        }
        try open(to: url)
    }
    public func connect(pairing: RelayPairing) async throws {
        // RelayPairing is immutable and constructible only through the validated
        // official URL or explicit same-origin custom transport envelope.
        try open(to: pairing.relayURL)
    }
    private func open(to url: URL) throws {
        tracedSends = 0
        RelayConnectionTrace.shared.record("socket_open")
        guard task == nil else { throw RelayFailure("relay_already_connected", "Disconnect before opening another relay endpoint.") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration, delegate: RelaySocketRedirectDelegate(), delegateQueue: nil)
        let task = session.webSocketTask(with: url)
        task.maximumMessageSize = RelayWire.maxFrame
        self.session = session; self.task = task; task.resume()
    }
    public func send(text: String) async throws {
        guard text.utf8.count <= RelayWire.maxFrame, let task else { throw RelayFailure.closed() }
        let started = Date(); let trace = tracedSends < 2; tracedSends += 1
        try await task.send(.string(text))
        if trace { RelayConnectionTrace.shared.record("socket_sent_ms=\(Int(Date().timeIntervalSince(started) * 1000))") }
    }
    public func receive() async throws -> String {
        guard let task else { throw RelayFailure.closed() }
        guard case .string(let text) = try await task.receive(), text.utf8.count <= RelayWire.maxFrame else { throw RelayFailure.invalid("The relay sent a non-text or oversized envelope.") }; return text
    }
    public func close() async { task?.cancel(with: .goingAway, reason: nil); task = nil; session?.invalidateAndCancel(); session = nil }
}

/// Independent original-host adapter. It never launches a CLI, reads desktop credentials, or reconnects automatically.
public actor RelayClient {
    public nonisolated let clientID: String
    /// One consumer; events carry full current projections rather than requiring the UI to apply deltas.
    public nonisolated let events: AsyncStream<RelayEvent>
    public private(set) var state: RelayClientState = .idle
    public private(set) var bridge: RelayBridge?
    public var pairedDeviceID: String? { paired ? lastDeviceID : nil }
    public var pairedServiceID: String? { paired ? lastServiceID : nil }
    public var connectedAppVersion: String? { pairing?.appVersion }
    public private(set) var workspaceHookReviewSupported = false
    public nonisolated let liveVerified = false
    private let eventSink: AsyncStream<RelayEvent>.Continuation
    private var observers: [UUID: AsyncStream<RelayEvent>.Continuation] = [:]
    private let transport: any RelaySocketTransport
    private let requestTimeout: TimeInterval
    private var receiveTask: Task<Void, Never>?, heartbeatTask: Task<Void, Never>?, outboundTail: Task<Void, Error>?
    private var pairing: RelayPairing?, connectionID: UUID?
    private var lastDeviceID: String?, lastServiceID: String?, workspaceScopeID: String?
    private var paired = false, rpcReady = false, closing = false, workspaceOpening = false, eventOverflowReported = false
    private var lastHeartbeat = 0.0, bridgeGeneration = 0
    private var rpcSequence: Int32 = 0
    private var frames: RelayFrameTransport?
    private var conversationAssembler = RelayConversationAssembler()
    private var knownWorkspaces: [RelayWorkspace] = []
    private struct AppPending {
        let expectedTypes: Set<String>
        let continuation: CheckedContinuation<RelayJSON, any Error>
        let timeout: Task<Void, Never>
        let workspace: RelayWorkspace?
        let bridgeID: String?
        let generation: Int?
    }
    private struct RPCPending {
        let continuation: CheckedContinuation<RelayJSON, any Error>
        let timeout: Task<Void, Never>
    }
    private var appRequests: [String: AppPending] = [:]
    private var rpcRequests: [Int32: RPCPending] = [:]
    private var pairWaiter: CheckedContinuation<Void, any Error>?, pairTimeout: Task<Void, Never>?
    private var initializeWaiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private var initializeTimeouts: [UUID: Task<Void, Never>] = [:]
    private var conversationListener: Int32?
    private var conversationInitialization: (id: UUID, task: Task<Bool, any Error>)?
    private var conversationReady = false
    private var subscriptions: [String: (sessionID: String, ack: RelaySubscription)] = [:]
    private var reducers: [String: RelayProjectionReducer] = [:]
    private var snapshots: [String: RelaySessionSnapshot] = [:]
    private var earlyFrames: [String: [RelayJSON]] = [:]
    private var earlyFrameFailures: [String: String] = [:]
    private var subscriptionRequests = Set<String>()
    private var earlyFrameBytes = 0, pendingSubscriptions = 0
    private var recovering: [String: UUID] = [:]
    private var stoppedSessions = Set<String>()
    private var commandHashes: [String: Data] = [:]
    private var readOnlySubagents = Set<String>()

    public init(clientID: String, transport: any RelaySocketTransport = RelayURLSessionSocket(), requestTimeout: TimeInterval = 15) throws {
        guard RelayWire.validID(clientID), requestTimeout.isFinite, (0.05...120).contains(requestTimeout) else { throw RelayFailure.invalid("Invalid relay client configuration.") }
        self.clientID = clientID; self.transport = transport; self.requestTimeout = requestTimeout
        let pair = AsyncStream<RelayEvent>.makeStream(bufferingPolicy: .bufferingNewest(128)); events = pair.stream; eventSink = pair.continuation
    }
    deinit { receiveTask?.cancel(); heartbeatTask?.cancel(); pairTimeout?.cancel(); eventSink.finish() }
    private func emit(_ event: RelayEvent) {
        if case .dropped = eventSink.yield(event), !eventOverflowReported {
            eventOverflowReported = true
            eventSink.yield(.failure(.init("relay_event_overflow", "The UI event consumer fell behind. Reload the client's current projection.")))
        }
        for sink in observers.values {
            if case .dropped = sink.yield(event) { sink.yield(.failure(.init("relay_event_overflow", "Reload the current task projection to recover missed events."))) }
        }
    }
    /// Independent observer lifetime; cancelling one view must not terminate another view's stream.
    public func observeEvents() -> AsyncStream<RelayEvent> {
        let id = UUID(), pair = AsyncStream<RelayEvent>.makeStream(bufferingPolicy: .bufferingNewest(128))
        observers[id] = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        return pair.stream
    }
    private func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }
    private func setState(_ next: RelayClientState) { state = next; emit(.state(next)) }
    private func timeoutTask(_ seconds: TimeInterval, action: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        Task { do { try await Task.sleep(for: .seconds(seconds)); guard !Task.isCancelled else { return }; await action() } catch {} }
    }

    public func connect(pairing: RelayPairing, confirmedControllerReplacement: Bool) async throws {
        guard confirmedControllerReplacement else { throw RelayFailure("controller_confirmation_required", "Connecting can replace another mobile controller. Confirm the selected desktop first.") }
        guard connectionID == nil, !closing else { throw RelayFailure("relay_already_connected", "Disconnect before pairing another desktop.") }
        if lastDeviceID != pairing.deviceID || lastServiceID != pairing.serviceID { reducers.removeAll(); snapshots.removeAll(); commandHashes.removeAll(); stoppedSessions.removeAll(); workspaceScopeID = nil }
        lastDeviceID = pairing.deviceID; lastServiceID = pairing.serviceID
        let id = UUID(); connectionID = id; self.pairing = pairing; setState(.connecting)
        RelayConnectionTrace.shared.record("connect_start selfHosted=\(pairing.isSelfHosted) timeout=\(requestTimeout)")
        do {
            try await transport.connect(pairing: pairing)
            receiveTask = Task { [weak self, transport] in
                do {
                    while !Task.isCancelled {
                        let text = try await transport.receive()
                        guard let self else { return }; try await self.receive(text, connectionID: id)
                    }
                } catch { await self?.transportFailed(error, connectionID: id) }
            }
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    pairWaiter = continuation
                    pairTimeout = timeoutTask(requestTimeout) { [weak self] in await self?.transportFailed(RelayFailure("relay_pairing_timeout", "The desktop did not pair before the deadline."), connectionID: id) }
                    Task {
                        do {
                            self.setState(.authenticating)
                            try await self.sendEnvelope(.object(["type": .string("auth_init"), "role": .string("terminal"), "device_sid": .string(pairing.deviceID), "meta": .object(["platform": .string("web"), "version": .string(pairing.appVersion), "name": .string("zcode-native-ios")]), "client_ts": .int(Int(Date().timeIntervalSince1970 * 1000))]))
                        } catch { await self.transportFailed(error, connectionID: id) }
                    }
                }
            } onCancel: { Task { await self.transportFailed(CancellationError(), connectionID: id) } }
        } catch { if connectionID == id { await terminate(error: error, next: .disconnected) }; throw error }
    }
    public func disconnect() async { await terminate(error: RelayFailure.closed(), next: .idle) }
    private func transportFailed(_ error: any Error, connectionID id: UUID) async {
        guard connectionID == id else { return }
        let native = error as NSError
        RelayConnectionTrace.shared.record("transport_failed domain=\(native.domain) code=\(native.code) relay=\((error as? RelayFailure)?.code ?? "none")")
        let failure = (error as? RelayFailure) ?? RelayFailure("relay_transport_failed", "The encrypted relay connection closed. Reconcile pending commands before reconnecting.", outcomeUncertain: true)
        emit(.failure(failure)); await terminate(error: failure, next: failure.code == "controller_replaced" ? .replaced : .disconnected)
    }
    private func terminate(error: any Error, next: RelayClientState) async {
        guard !closing else { return }; closing = true; connectionID = nil
        receiveTask?.cancel(); receiveTask = nil; heartbeatTask?.cancel(); heartbeatTask = nil; outboundTail?.cancel(); outboundTail = nil
        pairTimeout?.cancel(); pairTimeout = nil; pairWaiter?.resume(throwing: error); pairWaiter = nil
        for request in appRequests.values { request.timeout.cancel(); request.continuation.resume(throwing: error) }; appRequests.removeAll()
        for request in rpcRequests.values { request.timeout.cancel(); request.continuation.resume(throwing: error) }; rpcRequests.removeAll()
        for waiter in initializeWaiters.values { waiter.resume(throwing: error) }; initializeWaiters.removeAll()
        for timeout in initializeTimeouts.values { timeout.cancel() }; initializeTimeouts.removeAll()
        conversationInitialization?.task.cancel(); conversationInitialization = nil
        conversationReady = false; workspaceHookReviewSupported = false
        readOnlySubagents.removeAll()
        paired = false; rpcReady = false; pairing = nil; bridge = nil; frames = nil; conversationListener = nil
        subscriptions.removeAll(); earlyFrames.removeAll(); earlyFrameFailures.removeAll(); subscriptionRequests.removeAll(); earlyFrameBytes = 0; pendingSubscriptions = 0; recovering.removeAll(); conversationAssembler = .init()
        await transport.close(); closing = false; setState(next)
    }
    private func sendEnvelope(_ value: RelayJSON) async throws {
        try await sendEnvelopes([value])
    }
    private func sendEnvelopes(_ values: [RelayJSON]) async throws {
        guard let id = connectionID, !closing else { throw RelayFailure.closed() }
        let texts = try values.map { value in
            let data = try value.data(); guard data.count <= RelayWire.maxFrame, let text = String(data: data, encoding: .utf8) else { throw RelayFailure.invalid("Relay envelope exceeds 1 MiB.") }; return text
        }
        let previous = outboundTail, transport = transport
        // Queue an entire fragment batch before awaiting, preventing concurrent RPC calls from interleaving it.
        let task = Task { try await previous?.value; for text in texts { try Task.checkCancellation(); guard self.connectionID == id, !self.closing else { throw RelayFailure.closed() }; try await transport.send(text: text) } }
        outboundTail = task; try await task.value
    }
    private func sendPayload(_ value: RelayJSON) async throws {
        guard paired else { throw RelayFailure.closed() }
        try await sendEnvelope(.object(["type": .string("data"), "payload": value, "client_ts": .int(Int(Date().timeIntervalSince1970 * 1000))]))
    }
    private func receive(_ text: String, connectionID id: UUID) async throws {
        guard connectionID == id else { return }
        guard text.utf8.count <= RelayWire.maxFrame else { throw RelayFailure.invalid("Oversized relay envelope.") }
        let value = try RelayJSON(data: Data(text.utf8)), type = try value.requiringString("type")
        if type == "auth_challenge" {
            RelayConnectionTrace.shared.record("auth_challenge")
            guard !paired, let pairing else { throw RelayFailure.invalid("Unexpected authentication challenge.") }
            let proof = try pairing.challengeProof(nonce: value.requiringString("nonce"))
            try await sendEnvelope(.object(["type": .string("auth_response"), "device_sid": .string(pairing.deviceID), "proof": .string(proof), "client_ts": .int(Int(Date().timeIntervalSince1970 * 1000))])); return
        }
        if ["auth_ack", "pair_status_ack"].contains(type) {
            RelayConnectionTrace.shared.record(type + " status=" + (["matched", "waiting"].contains(value["pair_status"].string ?? "") ? value["pair_status"].string! : "invalid"))
            lastHeartbeat = ProcessInfo.processInfo.systemUptime
            switch value["pair_status"].string {
            case "matched":
                if !paired { paired = true; setState(.paired); pairTimeout?.cancel(); pairTimeout = nil; pairWaiter?.resume(); pairWaiter = nil; startHeartbeat(id) }
            case "waiting":
                if paired { throw RelayFailure("relay_desktop_unpaired", "The desktop is no longer paired.", outcomeUncertain: true) }; setState(.waiting)
            default: throw RelayFailure.invalid("Invalid pairing acknowledgement.")
            }; return
        }
        if type == "error" {
            throw RelayFailure.rejected(code: value["code"].string, paired: paired)
        }
        guard type == "data", paired else { return }
        let payload = value["payload"], subtype = try payload.requiringString("zcode_type")
        // Valid incoming application traffic also proves transport liveness when
        // a heartbeat acknowledgement waits behind a large ordered message.
        lastHeartbeat = ProcessInfo.processInfo.systemUptime
        if ["rpc-frame", "rpc-frame-ack"].contains(subtype) {
            // The official v4 receiver ignores residual RPC traffic until a bridge is attached.
            // Never acknowledge or decode a previous bridge's traffic in the new connection.
            guard var current = frames else { return }
            let result = try current.accept(payload); frames = current
            if let ack = result.acknowledgement { try await sendPayload(ack) }
            guard frames?.identity == current.identity else { return }
            if let bytes = result.message { try await receiveIPC(bytes) }; return
        }
        if let requestID = payload["requestId"].string, let pending = appRequests[requestID], pending.expectedTypes.contains(subtype) {
            if payload["success"].bool == false || subtype == "workspace-bridge-error" {
                completeApp(requestID, result: .failure(RelayFailure("desktop_bridge_rejected", "The desktop could not complete the workspace request."))); return
            }
            if subtype == "workspace-bridge-ready" {
                let attached = try payload["bridge"].decode(RelayBridge.self)
                guard let workspace = pending.workspace, attached.bridgeSessionId == pending.bridgeID, attached.bridgeGeneration == pending.generation,
                      attached.workspacePath == workspace.workspacePath, attached.workspaceKey == workspace.id, attached.workspaceIdentity == workspace.workspaceIdentity else { throw RelayFailure.invalid("The attached workspace differs from the selected workspace.") }
                if workspaceScopeID != attached.workspaceKey { reducers.removeAll(); snapshots.removeAll(); stoppedSessions.removeAll(); workspaceScopeID = attached.workspaceKey }
                frames = try RelayFrameTransport(identity: attached.identity); bridge = attached; rpcReady = false; conversationListener = nil
                conversationInitialization?.task.cancel(); conversationInitialization = nil
                conversationReady = false; workspaceHookReviewSupported = false
                readOnlySubagents.removeAll()
                subscriptions.removeAll(); earlyFrames.removeAll(); earlyFrameFailures.removeAll(); earlyFrameBytes = 0; recovering.removeAll(); conversationAssembler = .init(); setState(.attached(attached))
            }
            completeApp(requestID, result: .success(payload)); return
        }
        if subtype == "workspace-list-updated" {
            let list = try payload["result"].decode(RelayBootstrap.self); knownWorkspaces = list.workspaces; emit(.workspaces(list)); return
        }
        if subtype == "bridge-degraded" {
            // A new controller can receive the previous bridge's queued fault.
            // Only a fault scoped to our attached bridge may end this connection.
            guard let bridge, bridge.identity.matches(payload) else { return }
            throw RelayFailure("desktop_bridge_degraded", "电脑连接暂时中断，正在尝试恢复。", outcomeUncertain: true)
        }
        if ["workspace-bridge-error", "app-error"].contains(subtype) { throw RelayFailure("desktop_bridge_degraded", "The original desktop service is unavailable.", outcomeUncertain: true) }
    }
    private func startHeartbeat(_ id: UUID) {
        heartbeatTask = Task { [weak self] in
            do { while !Task.isCancelled { try await Task.sleep(for: .seconds(10)); guard let self else { return }; try await self.heartbeat() } }
            catch { await self?.transportFailed(error, connectionID: id) }
        }
    }
    private func heartbeat() async throws {
        guard paired, let pairing else { throw RelayFailure.closed() }
        guard ProcessInfo.processInfo.systemUptime - lastHeartbeat <= 30 else { throw RelayFailure("relay_heartbeat_timeout", "The relay stopped acknowledging heartbeats.", outcomeUncertain: true) }
        try frames?.checkDeadline()
        for subscription in conversationAssembler.expire() { requestRecovery(subscription, reason: "conversation_fragment_timeout") }
        try await sendEnvelope(.object(["type": .string("pair_status_query"), "device_sid": .string(pairing.deviceID), "client_ts": .int(Int(Date().timeIntervalSince1970 * 1000))]))
    }

    private func appRequest(type: String, expected: Set<String>, fields: [String: RelayJSON] = [:], workspace: RelayWorkspace? = nil, bridgeID: String? = nil, generation: Int? = nil) async throws -> RelayJSON {
        guard paired else { throw RelayFailure.closed() }; try Task.checkCancellation()
        let requestID = UUID().uuidString
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timeout = timeoutTask(requestTimeout) { [weak self] in await self?.completeApp(requestID, result: .failure(RelayFailure("relay_request_timeout", "The desktop request timed out."))) }
                appRequests[requestID] = .init(expectedTypes: expected, continuation: continuation, timeout: timeout, workspace: workspace, bridgeID: bridgeID, generation: generation)
                var value = fields; value["zcode_type"] = .string(type); value["requestId"] = .string(requestID)
                Task { do { if self.appRequests[requestID] != nil { try await self.sendPayload(.object(value)) } } catch { self.completeApp(requestID, result: .failure(error)) } }
            }
        } onCancel: { Task { await self.completeApp(requestID, result: .failure(CancellationError())) } }
    }
    private func completeApp(_ id: String, result: Result<RelayJSON, any Error>) { guard let pending = appRequests.removeValue(forKey: id) else { return }; pending.timeout.cancel(); pending.continuation.resume(with: result) }
    public func bootstrap() async throws -> RelayBootstrap {
        let response = try await appRequest(type: "bootstrap-request", expected: ["bootstrap-response"])
        let result = try response["result"].decode(RelayBootstrap.self); knownWorkspaces = result.workspaces; return result
    }
    public func workspaces() async throws -> RelayBootstrap {
        let response = try await appRequest(type: "workspace-list-request", expected: ["workspace-list-response"])
        let result = try response["result"].decode(RelayBootstrap.self); knownWorkspaces = result.workspaces; return result
    }
    public func openWorkspace(key: String, taskID: String? = nil) async throws -> RelayBridge {
        guard !workspaceOpening, rpcRequests.isEmpty, pendingSubscriptions == 0, conversationInitialization == nil || conversationReady else { throw RelayFailure("relay_busy", "Wait for pending desktop requests before switching workspaces.") }
        guard let workspace = knownWorkspaces.first(where: { $0.id == key }), workspace.canAttach else { throw RelayFailure("workspace_unavailable", "Choose an opened and connected desktop workspace.") }
        workspaceOpening = true; defer { workspaceOpening = false }
        let bridgeID = UUID().uuidString; bridgeGeneration += 1
        var fields: [String: RelayJSON] = ["bridgeSessionId": .string(bridgeID), "bridgeGeneration": .int(bridgeGeneration), "workspaceKey": .string(key)]
        if let taskID { fields["taskId"] = .string(taskID) }
        _ = try await appRequest(type: "workspace-bridge-open", expected: ["workspace-bridge-ready", "workspace-bridge-error"], fields: fields, workspace: workspace, bridgeID: bridgeID, generation: bridgeGeneration)
        try await waitForIPC(); guard let bridge else { throw RelayFailure.closed() }; return bridge
    }
    private func waitForIPC() async throws {
        if rpcReady { return }; guard bridge != nil else { throw RelayFailure("relay_no_workspace", "Attach a desktop workspace first.") }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                initializeWaiters[id] = continuation
                initializeTimeouts[id] = timeoutTask(requestTimeout) { [weak self] in await self?.finishInitialization(id, error: RelayFailure("relay_rpc_not_ready", "The original desktop service did not initialize.")) }
            }
        } onCancel: { Task { await self.finishInitialization(id, error: CancellationError()) } }
    }
    private func finishInitialization(_ id: UUID, error: (any Error)? = nil) {
        initializeTimeouts.removeValue(forKey: id)?.cancel()
        guard let waiter = initializeWaiters.removeValue(forKey: id) else { return }
        if let error { waiter.resume(throwing: error) } else { waiter.resume() }
    }
    private func nextRPCID() throws -> Int32 { guard rpcSequence < Int32.max else { throw RelayFailure.invalid("RPC request ID exhausted; reconnect explicitly.") }; defer { rpcSequence += 1 }; return rpcSequence }
    private func initializeConversation() async throws {
        if conversationReady { return }
        guard let selected = bridge, let connection = connectionID else { throw RelayFailure.closed() }
        let initialization: (id: UUID, task: Task<Bool, any Error>)
        if let existing = conversationInitialization { initialization = existing }
        else {
            initialization = (UUID(), Task {
                try await RelayWorkspaceOperation.$expectedBridge.withValue(selected) {
                    let hello = try await self.rpc("zcode-agent", "helloConversationV4")
                    let mode = hello["clientMode"].string
                    guard hello["kind"].string == "hello", hello["protocolVersion"].integer == 3,
                          hello["connectionId"].string?.isEmpty == false,
                          ["desktop-continuous", "web-remote-replayable"].contains(mode ?? ""),
                          hello["deliveryProfile"].string == (mode == "desktop-continuous" ? "continuous" : "replayable"),
                          hello["serverTime"].number?.isFinite == true,
                          hello["capabilities"]["nativeDialogs"].bool != nil,
                          hello["capabilities"]["localTerminal"].bool != nil,
                          hello["capabilities"]["binaryFrames"].bool != nil,
                          ["none", "permessage-deflate"].contains(hello["capabilities"]["compression"].string ?? "") else {
                        throw RelayFailure("relay_protocol_unsupported", "The desktop conversation protocol is incompatible with this client.")
                    }
                    _ = try await self.rpc("zcode-agent", "initializeConversationV4", [
                        "kind": .string("clientHello"), "protocolVersion": .int(3), "clientId": .string(self.clientID),
                        "clientKind": .string("mobileApp"),
                        "appVersion": .string(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"),
                        "capabilities": .object(["workspaceHookReviewUi": .bool(true)])
                    ])
                    return hello["capabilities"]["workspaceHookReview"].bool == true
                }
            })
            conversationInitialization = initialization
        }
        let supported: Bool
        do { supported = try await initialization.task.value }
        catch {
            if conversationInitialization?.id == initialization.id { conversationInitialization = nil }
            throw error
        }
        guard connectionID == connection, bridge == selected, conversationInitialization?.id == initialization.id else { throw RelayFailure.closed() }
        conversationReady = true; workspaceHookReviewSupported = supported
        try Task.checkCancellation()
    }
    func rpc(_ channel: String, _ method: String, _ params: [String: RelayJSON] = [:], timeout: TimeInterval? = nil) async throws -> RelayJSON {
        guard !workspaceOpening else { throw RelayFailure("relay_busy", "Wait for the selected desktop workspace to finish opening.") }
        let target = params["sessionId"]?.string ?? params["taskId"]?.string ?? params["envelope"]?["sessionId"].string
        let childHistorySubscribe = method == "subscribeConversationV4" && target != nil && RelayChildHistoryOperation.sessionID == target
        if let target, readOnlySubagents.contains(target), !(channel == "zcode-agent" && (method == "readSession" && params["runtimePolicy"]?.string == "existing-only" || childHistorySubscribe || method == "conversationRowsRangeV4" && reducers[target]?.projection != nil)) {
            throw RelayFailure("session_read_only", "Subagent records permit only verified history reads.")
        }
        try await waitForIPC(); try Task.checkCancellation(); guard let bridge else { throw RelayFailure.closed() }
        if let expected = RelayWorkspaceOperation.expectedBridge, expected != bridge { throw RelayFailure("relay_workspace_changed", "The workspace changed before this operation completed.") }
        let handshake = channel == "zcode-agent" && ["helloConversationV4", "initializeConversationV4"].contains(method)
        if channel == "zcode-agent", !handshake { try await initializeConversation() }
        guard self.bridge == bridge else { throw RelayFailure("relay_workspace_changed", "The workspace changed before this operation completed.") }
        // ClientHello has a strict schema. Workspace routing is already bound by the relay frame identity.
        let id = try nextRPCID(), scope = handshake ? params : params.merging(bridge.scope) { _, host in host }
        let bytes = try RelayIPCCodec.encode(.init(header: [.int32(100), .int32(id), .string(channel), .string(method)], body: .array([try .object(.object(scope))])))
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let readOnly = ["zcode-task/listTasks", "zcode-task/listPinnedTasks", "zcode-task/listArchivedTasks",
                                "zcode-session/readSession", "zcode-agent/readSession", "zcode-agent/listSessionSubagents",
                                "zcode-agent/helloConversationV4", "zcode-agent/conversationRowsRangeV4",
                                "zcode-agent/queryConversationCommandsV4"].contains(channel + "/" + method)
                let timer = timeoutTask(timeout ?? (readOnly ? requestTimeout * 2 : requestTimeout)) { [weak self] in
                    // Operation names only: never log task IDs, messages, credentials or RPC parameters.
                    Logger(subsystem: "dev.paco.zcode.mobile", category: "Relay").error("Desktop RPC timeout: \(channel, privacy: .public)/\(method, privacy: .public)")
                    let failure = readOnly
                        ? RelayFailure("relay_read_timeout", "读取电脑上的内容超时，请稍后重试。")
                        : RelayFailure("relay_rpc_timeout", "电脑尚未确认操作结果。请先恢复连接并核对原操作，避免重复提交。", outcomeUncertain: true)
                    await self?.completeRPC(id, result: .failure(failure))
                }
                rpcRequests[id] = .init(continuation: continuation, timeout: timer)
                Task { do { if self.rpcRequests[id] != nil { try await self.sendIPC(bytes) } } catch { self.completeRPC(id, result: .failure(error)) } }
            }
        } onCancel: { Task { await self.completeRPC(id, result: .failure(CancellationError())) } }
    }
    private func completeRPC(_ id: Int32, result: Result<RelayJSON, any Error>) { guard let pending = rpcRequests.removeValue(forKey: id) else { return }; pending.timeout.cancel(); pending.continuation.resume(with: result) }
    private func sendIPC(_ bytes: Data) async throws {
        guard var current = frames else { throw RelayFailure.closed() }
        let payloads = try current.enqueue(bytes); frames = current
        try await sendEnvelopes(payloads.map { .object(["type": .string("data"), "payload": $0, "client_ts": .int(Int(Date().timeIntervalSince1970 * 1000))]) })
    }
    private func receiveIPC(_ bytes: Data) async throws {
        let message = try RelayIPCCodec.decode(bytes)
        if message.type == 200 { rpcReady = true; for id in Array(initializeWaiters.keys) { finishInitialization(id) }; return }
        guard let id = message.requestID else { throw RelayFailure.invalid("Missing service request ID.") }
        let body = try message.body.jsonValue()
        switch message.type {
        case 201: completeRPC(id, result: .success(body))
        case 202, 203:
            completeRPC(id, result: .failure(RelayFailure("desktop_rpc_error", "The desktop rejected the service request.")))
        case 204: if id == conversationListener { receiveConversation(body) }
        default: throw RelayFailure.invalid("Unsupported service response type.")
        }
    }

    public func listTasks(archived: Bool = false, pinned: Bool = false) async throws -> [RelayTaskMetadata] {
        let result = try await rpc("zcode-task", archived ? "listArchivedTasks" : pinned ? "listPinnedTasks" : "listTasks")
        return try result.decode([RelayTaskMetadata].self).map { item in
            var fields = try RelayJSON(data: JSONEncoder().encode(item)).requiringObject()
            // List membership is authoritative; the task DTO may omit these flags.
            fields["pinned"] = .bool(pinned && !archived)
            fields["archived"] = .bool(archived)
            return try RelayJSON.object(fields).decode(RelayTaskMetadata.self)
        }
    }
    public func readSession(_ sessionID: String, messageLimit: Int = 500) async throws -> RelaySessionSnapshot {
        guard !sessionID.isEmpty, (1...1000).contains(messageLimit) else { throw RelayFailure.invalid("Invalid session read parameters.") }
        let result = try RelaySessionSnapshot(raw: await rpc("zcode-session", "readSession", ["sessionId": .string(sessionID), "messageLimit": .int(messageLimit)]))
        guard result.sessionID == sessionID else { throw RelayFailure.invalid("The desktop returned another session.") }
        snapshots[sessionID] = result
        if result.activeTurnID == nil, !["running", "waiting"].contains(result.status) { stoppedSessions.remove(sessionID) }
        return result
    }
    public func listSubagentDirectory(parentSessionID: String, cursor: String? = nil, limit: Int = 100) async throws -> RelaySubagentDirectory {
        guard RelayWire.validID(parentSessionID), !readOnlySubagents.contains(parentSessionID), reducers[parentSessionID]?.projection != nil,
              (1...100).contains(limit), cursor == nil || (!cursor!.isEmpty && cursor!.utf8.count <= 8192) else { throw RelayFailure.invalid("Open the original parent before reading its subagent directory.") }
        var params: [String: RelayJSON] = ["sessionId": .string(parentSessionID), "endedLimit": .int(limit)]
        if let cursor { params["endedCursor"] = .string(cursor) }
        let directory = try RelaySubagentDirectory(raw: await rpc("zcode-agent", "listSessionSubagents", params))
        guard directory.ended.count <= limit else { throw RelayFailure.invalid("The desktop exceeded the requested subagent page size.") }
        return directory
    }
    /// The optional cold path follows the official child pane: revalidate the host's parent
    /// directory, materialize its runtime through V4, then read and remove our subscription.
    /// Host resume hooks may run; no input, model override, registration or child command is sent.
    public func readSubagentSession(_ sessionID: String, parentSessionID: String, allowColdRestore: Bool = false) async throws -> RelaySessionSnapshot {
        guard RelayWire.validID(sessionID), sessionID != parentSessionID, let selected = bridge,
              let parent = reducers[parentSessionID]?.projection, parent.referencedSubagentIDs.contains(sessionID) else {
            throw RelayFailure("session_not_found", "The selected parent's activity does not reference this subagent.")
        }
        readOnlySubagents.insert(sessionID)
        var raw: RelayJSON
        let readParams: [String: RelayJSON] = ["sessionId": .string(sessionID), "runtimePolicy": .string("existing-only")]
        do { raw = try await rpc("zcode-agent", "readSession", readParams) }
        catch let failure as RelayFailure where failure.code == "desktop_rpc_error" {
            guard allowColdRestore else { throw RelayFailure("relay_subagent_history_unavailable", "The host has no readable active runtime for this subagent.") }
            // The ordinary session list contains roots only. The parent's dedicated directory
            // reads its persisted relationships and admits only actual subagent_child records.
            let directory = try await listSubagentDirectory(parentSessionID: parentSessionID)
            guard bridge == selected, directory.childSessionIDs.contains(sessionID) else { throw RelayFailure("relay_subagent_scope_mismatch", "The desktop no longer lists this child under the selected parent.") }
            raw = try await RelayChildHistoryOperation.$sessionID.withValue(sessionID) {
                _ = try await subscribe(sessionID: sessionID, resume: false)
                do {
                    let snapshot: RelayJSON
                    do { snapshot = try await rpc("zcode-agent", "readSession", readParams) }
                    catch let failure as RelayFailure where failure.code == "desktop_rpc_error" {
                        // V4 can serve persisted child rows without creating a legacy runtime.
                        // Its scoped directory and validated conversation topic establish identity.
                        let deadline = ContinuousClock.now + .seconds(12)
                        while reducers[sessionID]?.projection == nil, ContinuousClock.now < deadline {
                            try Task.checkCancellation()
                            guard bridge == selected else { throw RelayFailure.closed() }
                            try await Task.sleep(for: .milliseconds(40))
                        }
                        guard bridge == selected, let projection = reducers[sessionID]?.projection else {
                            throw RelayFailure("relay_subagent_history_unavailable", "The desktop has not returned this subagent's saved conversation.")
                        }
                        snapshot = .object([
                            "session": .object(["sessionId": .string(sessionID), "title": .string(projection.title), "status": .string(projection.phase)]),
                            "conversationProjection": projection.raw
                        ])
                    }
                    try await unsubscribe(sessionID: sessionID)
                    return snapshot
                } catch {
                    try? await unsubscribe(sessionID: sessionID)
                    throw error
                }
            }
        }
        let result = try RelaySessionSnapshot(raw: raw)
        if raw["conversationProjection"] != .null {
            let projection = try RelayConversationProjection(raw: raw["conversationProjection"])
            guard bridge == selected, projection.sessionID == sessionID,
                  try raw.data().count <= 16 * 1024 * 1024 else { throw RelayFailure.invalid("Invalid child conversation scope or size.") }
            return result
        }
        try validateSubagentIdentity(raw["session"], sessionID: sessionID, parentSessionID: parentSessionID, selected: selected)
        guard raw["messages"].array != nil, result.messages.allSatisfy({ ($0["info"]["messageId"].string ?? $0["info"]["id"].string)?.isEmpty == false }) else {
            throw RelayFailure.invalid("The host omitted subagent history or original message identities.")
        }
        let messageIDs = result.messages.compactMap { $0["info"]["messageId"].string ?? $0["info"]["id"].string }
        guard Set(messageIDs).count == messageIDs.count else { throw RelayFailure.invalid("The host returned duplicate subagent message identities.") }
        guard result.messages.count <= 10_000, try raw.data().count <= 16 * 1024 * 1024 else {
            throw RelayFailure("relay_history_limit", "This subagent history exceeds the native read limit. No truncated history was returned.")
        }
        return result
    }
    private func validateSubagentIdentity(_ session: RelayJSON, sessionID: String, parentSessionID: String, selected: RelayBridge) throws {
        let workspace = session["workspace"]
        guard bridge == selected, session["sessionId"].string == sessionID, session["sessionKind"].string == "subagent_child",
              session["parentSessionId"].string == parentSessionID,
              workspace["workspacePath"].string == selected.workspacePath,
              workspace["workspaceIdentity"].string == selected.workspaceIdentity,
              workspace["remoteSessionId"].string == selected.remoteSessionId else { throw RelayFailure("relay_subagent_scope_mismatch", "The host's subagent ancestry or workspace differs from the parent's activity.") }
    }
    public func currentProjection(sessionID: String) -> RelayConversationProjection? { reducers[sessionID]?.projection }
    public func subscribe(sessionID: String, resume: Bool = true) async throws -> RelaySubscription {
        guard !workspaceOpening else { throw RelayFailure("relay_busy", "Wait for the selected desktop workspace to finish opening.") }
        guard !readOnlySubagents.contains(sessionID) || RelayChildHistoryOperation.sessionID == sessionID else { throw RelayFailure("session_read_only", "A child can only be opened through its verified parent history.") }
        guard !sessionID.isEmpty, subscriptionRequests.insert(sessionID).inserted else { throw RelayFailure("relay_subscription_in_progress", "This task subscription is already opening.") }
        defer { subscriptionRequests.remove(sessionID) }
        try await waitForIPC(); guard let bridge else { throw RelayFailure.closed() }
        if let existing = subscriptions.values.first(where: { $0.sessionID == sessionID }) { return existing.ack }
        pendingSubscriptions += 1; defer { pendingSubscriptions = max(0, pendingSubscriptions - 1) }
        try await initializeConversation()
        if conversationListener == nil {
            let id = try nextRPCID(); conversationListener = id
            try await sendIPC(RelayIPCCodec.encode(.init(header: [.int32(102), .int32(id), .string("zcode-agent"), .string("onDynamicConversationFrame")], body: try .object(.object(bridge.scope)))))
        }
        var params: [String: RelayJSON] = ["sessionId": .string(sessionID), "visibility": .string("foreground")]
        if resume, let projection = reducers[sessionID]?.projection { params["base"] = .object(["logEpoch": .string(projection.logEpoch), "seq": .int(projection.sequence)]) }
        let response = try await rpc("zcode-agent", "subscribeConversationV4", params), ack = try response["ack"].decode(RelaySubscription.self)
        subscriptions[ack.subscriptionId] = (sessionID, ack)
        if !resume || reducers[sessionID]?.projection?.logEpoch != ack.logEpoch { reducers[sessionID] = .init() }
        if let reason = earlyFrameFailures.removeValue(forKey: ack.subscriptionId) {
            if let buffered = earlyFrames.removeValue(forKey: ack.subscriptionId) { earlyFrameBytes -= buffered.reduce(0) { $0 + ((try? $1.data().count) ?? 0) } }
            requestRecovery(ack.subscriptionId, reason: reason); return ack
        }
        if let buffered = earlyFrames.removeValue(forKey: ack.subscriptionId) {
            for frame in buffered { earlyFrameBytes -= (try? frame.data().count) ?? 0; applyConversation(frame, subscriptionID: ack.subscriptionId) }
        }
        return ack
    }
    public func unsubscribe(sessionID: String) async throws {
        let ids = subscriptions.filter { $0.value.sessionID == sessionID }.map(\.key)
        for id in ids { _ = try await rpc("zcode-agent", "unsubscribeConversationV4", ["subscriptionId": .string(id)]); subscriptions.removeValue(forKey: id); recovering.removeValue(forKey: id); conversationAssembler.discard(subscriptionID: id) }
    }
    private func receiveConversation(_ wire: RelayJSON) {
        let id = wire["subscriptionId"].string ?? ""
        do {
            guard subscriptions[id] != nil || pendingSubscriptions > 0 else { return }
            if recovering[id] != nil, wire["deliveryKind"].string != "recovery", wire["deliveryKind"].string != "initial" { return }
            guard let frame = try conversationAssembler.accept(wire) else { return }
            if subscriptions[id] == nil {
                let bytes = try frame.data().count
                guard earlyFrameBytes + bytes <= 32 * 1024 * 1024 else { throw RelayFailure.invalid("Early subscription frames exceed the memory limit.") }
                earlyFrames[id, default: []].append(frame); earlyFrameBytes += bytes; return
            }
            applyConversation(frame, subscriptionID: id)
        } catch { requestRecovery(id, reason: (error as? RelayFailure)?.code ?? "conversation_invalid_frame") }
    }
    private func applyConversation(_ frame: RelayJSON, subscriptionID: String) {
        guard let sessionID = subscriptions[subscriptionID]?.sessionID else { return }
        do {
            var reducer = reducers[sessionID] ?? .init()
            if try reducer.apply(frame, expectedSessionID: sessionID), let projection = reducer.projection {
                reducers[sessionID] = reducer; recovering.removeValue(forKey: subscriptionID)
                if !projection.canStop && projection.pendingInteractions.isEmpty { stoppedSessions.remove(sessionID) }
                emit(.projection(projection))
            }
        } catch { requestRecovery(subscriptionID, reason: (error as? RelayFailure)?.code ?? "conversation_gap") }
    }
    private func requestRecovery(_ subscriptionID: String, reason: String) {
        guard let sessionID = subscriptions[subscriptionID]?.sessionID else {
            if !subscriptionID.isEmpty, pendingSubscriptions > 0, earlyFrameFailures.count < 32 { earlyFrameFailures[subscriptionID] = reason }
            return
        }
        guard recovering[subscriptionID] == nil, let selected = bridge, let connection = connectionID else { return }
        let attempt = UUID(); recovering[subscriptionID] = attempt
        conversationAssembler.discard(subscriptionID: subscriptionID); emit(.resyncRequired(sessionID: sessionID, reason: reason))
        Task {
            do {
                _ = try await self.rpc("zcode-agent", "resyncConversationV4", ["subscriptionId": .string(subscriptionID), "base": .null, "forceSnapshot": .bool(true)])
                // An RPC acknowledgement is not proof that its recovery snapshot arrived.
                // Bound that second wait as well; a frozen projection must not remain online.
                if self.recoveryIsCurrent(subscriptionID, attempt: attempt, connection: connection, bridge: selected) {
                    try await Task.sleep(for: .seconds(self.requestTimeout))
                    if self.recoveryIsCurrent(subscriptionID, attempt: attempt, connection: connection, bridge: selected) {
                        throw RelayFailure("relay_recovery_snapshot_timeout", "The desktop acknowledged recovery but did not send its current task state.")
                    }
                }
            } catch {
                // A snapshot may precede a lost ACK, or a new workspace/connection may
                // replace this recovery. Neither case may disconnect the current view.
                guard self.recoveryIsCurrent(subscriptionID, attempt: attempt, connection: connection, bridge: selected) else { return }
                await self.transportFailed(RelayFailure("relay_resync_failed", "The desktop task state could not be recovered. Reconnect explicitly; pending command IDs are retained.", outcomeUncertain: true), connectionID: connection)
            }
        }
    }
    private func recoveryIsCurrent(_ subscriptionID: String, attempt: UUID, connection: UUID, bridge selected: RelayBridge) -> Bool {
        !closing && connectionID == connection && bridge == selected && recovering[subscriptionID] == attempt && subscriptions[subscriptionID] != nil
    }
    public func rows(sessionID: String, beforeRowID: Int? = nil, limit: Int = 200) async throws -> RelayJSON {
        guard (1...200).contains(limit), beforeRowID.map({ $0 >= 0 }) ?? true else { throw RelayFailure.invalid("Invalid row range.") }
        var fields: [String: RelayJSON] = ["sessionId": .string(sessionID), "limit": .int(limit)]; if let beforeRowID { fields["beforeRowId"] = .int(beforeRowID) }
        return try await rpc("zcode-agent", "conversationRowsRangeV4", fields)
    }

    /// Reads one official history page and atomically extends the subscribed projection.
    /// The caller supplies the cursor from its most recent detail response.
    public func loadOlderRows(sessionID: String, beforeRowID: Int, logEpoch: String, limit: Int = 200) async throws -> RelayConversationProjection {
        guard let requestedBridge = bridge, let current = reducers[sessionID]?.projection, current.logEpoch == logEpoch,
              current.rows.first?["rowId"].integer == beforeRowID else {
            throw RelayFailure("relay_history_changed", "Read the current task before requesting older messages.")
        }
        let page = try await rows(sessionID: sessionID, beforeRowID: beforeRowID, limit: limit)
        guard page["rows"].array.map({ $0.count <= limit }) == true else { throw RelayFailure.invalid("The history page exceeded its requested limit.") }
        // Normally stream frames precede the RPC response. If it overtook its
        // corresponding stream frame, briefly wait for that exact sequence.
        let deadline = ContinuousClock.now + .seconds(2)
        while let state = reducers[sessionID]?.projection, state.logEpoch == logEpoch,
              let sequence = page["atSeq"].integer, state.sequence < sequence, ContinuousClock.now < deadline {
            try Task.checkCancellation(); try await Task.sleep(for: .milliseconds(20))
        }
        guard bridge == requestedBridge, var reducer = reducers[sessionID] else { throw RelayFailure("relay_history_changed", "The task subscription ended while loading history.") }
        try reducer.prependRows(page, beforeRowID: beforeRowID, expectedLogEpoch: logEpoch)
        guard let projection = reducer.projection else { throw RelayFailure.invalid("The task projection is unavailable.") }
        reducers[sessionID] = reducer; emit(.projection(projection)); return projection
    }
    public func queryCommands(_ keys: [RelayCommandKey]) async throws -> RelayJSON {
        guard (1...64).contains(keys.count), keys.allSatisfy({ !$0.commandId.isEmpty }) else { throw RelayFailure.invalid("Query 1 to 64 command IDs.") }
        // Preserve an explicit null sessionId; Codable's default optional encoding omits it.
        return try await rpc("zcode-agent", "queryConversationCommandsV4", ["commands": .array(keys.map { .object(["sessionId": $0.sessionId.map(RelayJSON.string) ?? .null, "commandId": .string($0.commandId)]) })])
    }

    /// Persist this exact envelope in the caller's outbox before submitting it.
    public func makeCommand(sessionID: String, type: String, payload: RelayJSON, commandID: String) -> RelayCommandEnvelope {
        let projection = reducers[sessionID]?.projection
        return .init(commandId: commandID, clientId: clientID, sessionId: sessionID, type: type, payload: payload, baseRevision: projection?.revision, baseLogEpoch: projection?.logEpoch)
    }
    public func submit(_ command: RelayCommandEnvelope, explicitUserAction: Bool, confirmFullAccess: Bool = false, hookReviewAuthorization: RelayHookReviewAuthorization? = nil) async throws -> RelayCommandAck {
        try RelayWire.requireAction(explicitUserAction)
        try validate(command, confirmFullAccess: confirmFullAccess, hookReviewAuthorization: hookReviewAuthorization)
        let key = command.commandId, digest = Data(SHA256.hash(data: try command.json().data()))
        if let previous = commandHashes[key], previous != digest { throw RelayFailure("command_conflict", "The command ID was reused with different content.") }
        commandHashes[key] = digest
        if command.type == "stop", let sessionID = command.sessionId { stoppedSessions.insert(sessionID) }
        do {
            let result = try await rpc("zcode-agent", "sendConversationCommandV4", ["envelope": command.json()], timeout: 60)
            let ack = try result.decode(RelayCommandAck.self)
            guard ack.commandId == command.commandId else { throw RelayFailure.invalid("The desktop acknowledged another command.") }
            if command.type == "stop", !ack.admitted, let sessionID = command.sessionId { stoppedSessions.remove(sessionID) }
            if ack.status == "stale", ack.reasonCode == "proto.staleRevision",
               ["deleteQueueItem", "editQueueItem", "switchModelConfig"].contains(command.type) {
                commandHashes.removeValue(forKey: key)
            }
            emit(.command(ack)); return ack
        } catch { emit(.commandUncertain(.init(sessionId: command.sessionId, commandId: command.commandId))); throw error }
    }
    private func validate(_ command: RelayCommandEnvelope, confirmFullAccess: Bool, hookReviewAuthorization: RelayHookReviewAuthorization?) throws {
        guard command.clientId == clientID, RelayWire.validID(command.commandId), command.issuedAt.isFinite else { throw RelayFailure.invalid("Invalid command identity.") }
        let payload = try command.payload.requiringObject()
        if command.type == "createSession" {
            guard command.sessionId == nil, Set(payload.keys) == ["workspaceId"], let bridge, payload["workspaceId"]?.string == bridge.workspaceKey else { throw RelayFailure.invalid("Creation must target the attached workspace and contain no first input.") }
            return
        }
        guard let sessionID = command.sessionId, !sessionID.isEmpty else { throw RelayFailure.invalid("Missing command session.") }
        if ["requestWorkspaceHookReview", "respondWorkspaceHookReview", "toggleWorkspaceHookReviewItem", "revokeWorkspaceHookTrust"].contains(command.type) {
            try validateHookReviewCommand(command, authorization: hookReviewAuthorization); return
        }
        let keys: [String: Set<String>] = ["editQueueItem": ["queueItemId", "newText"], "deleteQueueItem": ["queueItemId"], "sendQueuedNow": ["queueItemId"], "sendText": ["text", "attachments", "requestedDelivery"], "sendGoalCommand": ["text", "displayText"], "stop": ["expectedForegroundExecutionId"], "forkAssistant": ["target"], "renameSession": ["title"], "resolveInteraction": ["interactionId", "answer"], "switchModelConfig": ["provider", "model", "thought"], "switchCollaborationMode": ["mode"], "pauseGoal": [], "resumeGoal": []]
        guard let allowed = keys[command.type], Set(payload.keys).isSubset(of: allowed) else { throw RelayFailure("relay_command_unsupported", "This command or payload field is not exposed by the native adapter.") }
        switch command.type {
        case "sendGoalCommand":
            guard let text = payload["text"]?.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 128_000,
                  payload["displayText"]?.string == "/goal " + text else { throw RelayFailure.invalid("A goal requires objective text and its matching command display.") }
        case "sendText":
            guard let text = payload["text"]?.string, text.utf8.count <= 128_000, payload["attachments"]?.array.map({ $0.count <= 6 }) ?? (payload["attachments"] == nil) else { throw RelayFailure.invalid("Invalid message or attachments.") }
            if let delivery = payload["requestedDelivery"], !["startNow", "queue", "guide"].contains(delivery.string ?? "") { throw RelayFailure.invalid("Unsupported message delivery mode.") }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !(payload["attachments"]?.array ?? []).isEmpty else { throw RelayFailure.invalid("A message needs text or an attachment.") }
        case "stop": if let target = payload["expectedForegroundExecutionId"], target.string?.isEmpty != false { throw RelayFailure.invalid("Invalid stop target.") }
        case "forkAssistant":
            _ = try RelayRowTarget(wire: payload["target"] ?? .null)
            guard command.baseRevision != nil, command.baseLogEpoch?.isEmpty == false else { throw RelayFailure.invalid("Fork requires the source projection revision and epoch.") }
        case "editQueueItem", "deleteQueueItem", "sendQueuedNow":
            guard let id = payload["queueItemId"]?.string, !id.isEmpty,
                  reducers[sessionID]?.projection?.raw["queue"]["items"].array?.contains(where: { $0["queueItemId"].string == id }) == true else { throw RelayFailure("queue_item_missing", "这条消息已被处理，请刷新会话。") }
            if command.type == "editQueueItem" {
                guard let text = payload["newText"]?.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 128_000 else { throw RelayFailure.invalid("Invalid queued message text.") }
            }
        case "renameSession": guard let title = payload["title"]?.string, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 200 else { throw RelayFailure.invalid("Invalid task title.") }
        case "switchCollaborationMode":
            guard let mode = payload["mode"]?.string, ["build", "edit", "plan", "yolo"].contains(mode) else { throw RelayFailure.invalid("Unsupported collaboration mode.") }
            if mode == "yolo", !confirmFullAccess { throw RelayFailure("full_access_confirmation_required", "Full access requires an explicit confirmation for this request.") }
        case "switchModelConfig": guard payload["provider"]?.string?.isEmpty == false, payload["model"]?.string?.isEmpty == false, payload["thought"]?.string != nil else { throw RelayFailure.invalid("Use provider, model, and thought for a model change.") }
        case "pauseGoal", "resumeGoal":
            guard let goal = reducers[sessionID]?.projection?.hostGoal,
                  command.type == "pauseGoal" ? goal.pauseAvailable : goal.resumeAvailable else { throw RelayFailure("goal_action_unavailable", "The desktop has not enabled this goal action.") }
        case "resolveInteraction":
            guard !stoppedSessions.contains(sessionID), let id = payload["interactionId"]?.string, let interaction = reducers[sessionID]?.projection?.pendingInteractions.first(where: { $0.id == id }) else { throw RelayFailure("interaction_not_pending", "This interaction is no longer pending or must be refreshed first.") }
            try validateAnswer(payload["answer"] ?? .null, interaction: interaction)
        default: break
        }
    }
    public func currentHookReview(sessionID: String) throws -> RelayHookReviewRequest? {
        guard let projection = reducers[sessionID]?.projection else { return nil }
        let pending = projection.pendingInteractions.filter { $0.kind == "workspaceHookReview" }
        guard pending.count <= 1 else { throw RelayFailure("hook_review_invalid", "The desktop supplied conflicting hook reviews.") }
        return try pending.first?.workspaceHookReview()
    }
    private func validateHookReviewCommand(_ command: RelayCommandEnvelope, authorization: RelayHookReviewAuthorization?) throws {
        guard workspaceHookReviewSupported else { throw RelayFailure("workspace_hooks_require_trust_capable_host", "The attached desktop has not advertised workspace hook review support.") }
        guard let sessionID = command.sessionId, let bridge, let projection = reducers[sessionID]?.projection else { throw RelayFailure("hook_review_not_pending", "Read the attached task before reviewing workspace hooks.") }
        let payload = try command.payload.requiringObject(), workspace = bridge.workspaceIdentity ?? bridge.workspacePath
        guard payload["sessionId"]?.string == sessionID, payload["workspaceIdentity"]?.string == workspace, payload["remoteSessionId"]?.string == bridge.remoteSessionId else { throw RelayFailure("workspace_hooks_snapshot_mismatch", "The hook review targets another workspace, remote host or task.") }
        if command.type == "requestWorkspaceHookReview" {
            let allowed: Set<String> = ["sessionId", "workspaceIdentity", "bundleDigest", "remoteSessionId"]
            guard Set(payload.keys).isSubset(of: allowed), let digest = payload["bundleDigest"]?.string,
                  digest == (try currentHookReview(sessionID: sessionID))?.bundleDigest || digest == projection.raw["workspaceHookAdmission"]["bundleDigest"].string else { throw RelayFailure("workspace_hooks_snapshot_mismatch", "The requested hook bundle is no longer current.") }
            return
        }
        guard let authorization else { throw RelayFailure("hook_review_confirmation_required", "Use the dedicated workspace hook review confirmation.") }
        let request = authorization.request
        try request.validateConfirmation(authorization.confirmation, operation: authorization.operation)
        guard command.type == authorization.operation.commandType, command.payload == (try authorization.operation.payload(target: request.target)) else { throw RelayFailure("hook_review_confirmation_required", "The command differs from the confirmed hook operation.") }
        guard let current = try currentHookReview(sessionID: sessionID), current.target == request.target else { throw RelayFailure("workspace_hooks_review_superseded", "The workspace hook review has been replaced or settled.") }
        guard current == request else { throw RelayFailure("workspace_hooks_snapshot_mismatch", "The displayed hook review content changed. Review the new commands before confirming.") }
        guard Date().timeIntervalSince1970 * 1000 < current.deadlineAt else { throw RelayFailure("hook_review_expired", "The workspace hook review has expired.") }
    }
    /// The caller must journal this complete envelope before submitting it.
    public func makeHookReviewCommand(authorization: RelayHookReviewAuthorization, commandID: String) throws -> RelayCommandEnvelope {
        let command = makeCommand(sessionID: authorization.request.sessionId, type: authorization.operation.commandType, payload: try authorization.operation.payload(target: authorization.request.target), commandID: commandID)
        try validateHookReviewCommand(command, authorization: authorization); return command
    }
    public func makeRequestHookReviewCommand(sessionID: String, workspaceIdentity: String, bundleDigest: String, remoteSessionID: String? = nil, commandID: String) throws -> RelayCommandEnvelope {
        var fields: [String: RelayJSON] = ["sessionId": .string(sessionID), "workspaceIdentity": .string(workspaceIdentity), "bundleDigest": .string(bundleDigest)]
        if let remoteSessionID { fields["remoteSessionId"] = .string(remoteSessionID) }
        let command = makeCommand(sessionID: sessionID, type: "requestWorkspaceHookReview", payload: .object(fields), commandID: commandID)
        try validateHookReviewCommand(command, authorization: nil); return command
    }
    public func requestHookReview(sessionID: String, workspaceIdentity: String, bundleDigest: String, remoteSessionID: String? = nil, commandID: String, explicitUserAction: Bool) async throws -> RelayCommandAck {
        try await submit(makeRequestHookReviewCommand(sessionID: sessionID, workspaceIdentity: workspaceIdentity, bundleDigest: bundleDigest, remoteSessionID: remoteSessionID, commandID: commandID), explicitUserAction: explicitUserAction)
    }
    public func trustHookReview(request: RelayHookReviewRequest, selectedItemIDs: [String], confirmation: RelayHookReviewConfirmation, commandID: String, explicitUserAction: Bool) async throws -> RelayCommandAck {
        let authorization = try RelayHookReviewAuthorization(request: request, operation: .trustSelected(itemIDs: selectedItemIDs), confirmation: confirmation)
        return try await submit(makeHookReviewCommand(authorization: authorization, commandID: commandID), explicitUserAction: explicitUserAction, hookReviewAuthorization: authorization)
    }
    public func revokeHookTrust(request: RelayHookReviewRequest, selectedItemIDs: [String], confirmation: RelayHookReviewConfirmation, commandID: String, explicitUserAction: Bool) async throws -> RelayCommandAck {
        let authorization = try RelayHookReviewAuthorization(request: request, operation: .revokeSelected(itemIDs: selectedItemIDs), confirmation: confirmation)
        return try await submit(makeHookReviewCommand(authorization: authorization, commandID: commandID), explicitUserAction: explicitUserAction, hookReviewAuthorization: authorization)
    }
    public func toggleHookReviewItem(request: RelayHookReviewRequest, itemID: String, enabled: Bool, confirmation: RelayHookReviewConfirmation, commandID: String, explicitUserAction: Bool) async throws -> RelayCommandAck {
        let authorization = try RelayHookReviewAuthorization(request: request, operation: .setEnabled(itemID: itemID, enabled: enabled), confirmation: confirmation)
        return try await submit(makeHookReviewCommand(authorization: authorization, commandID: commandID), explicitUserAction: explicitUserAction, hookReviewAuthorization: authorization)
    }
    private func validateAnswer(_ answer: RelayJSON, interaction: RelayPendingInteraction) throws {
        let fields = try answer.requiringObject()
        guard Set(fields.keys).isSubset(of: ["optionId", "action", "content", "freeText"]) else { throw RelayFailure.invalid("Unsupported interaction answer field.") }
        if interaction.kind == "permission" {
            guard fields.count == 1, let id = answer["optionId"].string, interaction.oneTimeOptions.contains(where: { $0["optionId"].string == id }) else { throw RelayFailure("persistent_permissions_unsupported", "Choose an exact pending one-time permission option.") }; return
        }
        guard interaction.kind == "userInput" else { throw RelayFailure("interaction_unsupported", "Use the dedicated workspace hook review and persistent-change confirmation.") }
        if let id = answer["optionId"].string {
            guard fields.count == 1, interaction.oneTimeOptions.contains(where: { $0["optionId"].string == id }) else { throw RelayFailure.invalid("Choose a pending user-input option.") }; return
        }
        guard let action = answer["action"].string, ["accept", "decline", "cancel"].contains(action), fields["freeText"] == nil else { throw RelayFailure.invalid("Invalid user-input action.") }
        if action != "accept" { guard fields.count == 1 else { throw RelayFailure.invalid("Decline/cancel cannot carry an answer.") }; return }
        let content = try answer["content"].requiringObject()
        guard Set(content.keys).isSubset(of: ["answer", "answers"]), content.count == 1 else { throw RelayFailure.invalid("Use answer or answers for the question form.") }
        func valid(_ value: RelayJSON) -> Bool {
            if let text = value.string { return text.count <= 16_000 }
            return value.array.map { $0.count <= 30 && $0.allSatisfy { $0.string.map { $0.count <= 4000 } ?? false } } ?? false
        }
        if let single = content["answer"] { guard valid(single) else { throw RelayFailure.invalid("Invalid question answer.") } }
        if let answers = content["answers"]?.object {
            let known = Set(interaction.questions.compactMap { $0["question"].string })
            guard answers.count <= 30, !answers.isEmpty, Set(answers.keys).isSubset(of: known), answers.values.allSatisfy(valid) else { throw RelayFailure.invalid("Answer keys must match the pending question text.") }
        } else if content["answers"] != nil { throw RelayFailure.invalid("Invalid question answers object.") }
    }
    public func sendText(sessionID: String, text: String, attachments: [RelayAttachment] = [], commandID: String, explicitUserAction: Bool) async throws -> RelayCommandAck {
        guard attachments.allSatisfy({ $0.sessionID == sessionID }) else { throw RelayFailure("attachment_wrong_session", "An attachment belongs to another task.") }
        var payload: [String: RelayJSON] = ["text": .string(text), "requestedDelivery": .string("startNow")]
        if !attachments.isEmpty { payload["attachments"] = .array(attachments.map(\.wire)) }
        return try await submit(makeCommand(sessionID: sessionID, type: "sendText", payload: .object(payload), commandID: commandID), explicitUserAction: explicitUserAction)
    }
    public func stop(sessionID: String, commandID: String, explicitUserAction: Bool) async throws -> RelayCommandAck {
        let active = reducers[sessionID]?.projection?.raw["control"]["activeWorks"].array?.first?["foregroundExecutionId"].string
        let payload: RelayJSON = .object(active.map { ["expectedForegroundExecutionId": .string($0)] } ?? [:])
        return try await submit(makeCommand(sessionID: sessionID, type: "stop", payload: payload, commandID: commandID), explicitUserAction: explicitUserAction)
    }
    public func makeForkCommand(sessionID: String, target: RelayRowTarget? = nil, commandID: String) throws -> RelayCommandEnvelope {
        guard let projection = reducers[sessionID]?.projection else { throw RelayFailure("fork_unavailable", "Read the host conversation before branching it.") }
        let allowed = projection.forkTargets
        guard let selected = target ?? allowed.last else { throw RelayFailure("fork_unavailable", "The host has no completed assistant boundary available to branch.") }
        guard allowed.contains(selected) else { throw RelayFailure("fork_target_stale", "This assistant boundary changed or is no longer available. Refresh before branching.") }
        return makeCommand(sessionID: sessionID, type: "forkAssistant", payload: .object(["target": selected.wire]), commandID: commandID)
    }
    public func fork(sessionID: String, target: RelayRowTarget? = nil, commandID: String, explicitUserAction: Bool) async throws -> RelayCommandAck {
        try await submit(makeForkCommand(sessionID: sessionID, target: target, commandID: commandID), explicitUserAction: explicitUserAction)
    }
    /// Registers an acknowledged native fork with the original host's task index, preserving its host-chosen configuration.
    public func registerForkedTask(_ acknowledgement: RelayCommandAck, parentSessionID: String, explicitUserAction: Bool) async throws -> RelaySessionSnapshot {
        try RelayWire.requireAction(explicitUserAction)
        guard acknowledgement.admitted, acknowledgement.result?["type"].string == "forkAssistant",
              let child = acknowledgement.result?["sessionId"].string, RelayWire.validID(child), child != parentSessionID else { throw RelayFailure("fork_uncertain", "The host has not confirmed a distinct forked task.", outcomeUncertain: true) }
        let snapshot = try RelaySessionSnapshot(raw: await rpc("zcode-session", "resumeSession", ["sessionId": .string(child)]))
        guard snapshot.sessionID == child else { throw RelayFailure.invalid("The host resumed another task.") }
        return snapshot
    }
    public func reply(sessionID: String, interactionID: String, answer: RelayInteractionAnswer, commandID: String, explicitUserAction: Bool) async throws -> RelayCommandAck {
        var wire = answer.wire
        if answer == .decline, let pending = reducers[sessionID]?.projection?.pendingInteractions.first(where: { $0.id == interactionID }), pending.kind == "permission", let option = pending.oneTimeOptions.first(where: { $0["kind"].string == "deny" })?["optionId"].string { wire = .object(["optionId": .string(option)]) }
        return try await submit(makeCommand(sessionID: sessionID, type: "resolveInteraction", payload: .object(["interactionId": .string(interactionID), "answer": wire]), commandID: commandID), explicitUserAction: explicitUserAction)
    }
    public func pauseGoal(sessionID: String, commandID: String, explicitUserAction: Bool) async throws -> RelayCommandAck {
        try await submit(makeCommand(sessionID: sessionID, type: "pauseGoal", payload: .object([:]), commandID: commandID), explicitUserAction: explicitUserAction)
    }
    public func resumeGoal(sessionID: String, commandID: String, explicitUserAction: Bool) async throws -> RelayCommandAck {
        try await submit(makeCommand(sessionID: sessionID, type: "resumeGoal", payload: .object([:]), commandID: commandID), explicitUserAction: explicitUserAction)
    }
    public func makeGoalCommand(sessionID: String, text: String, commandID: String) throws -> RelayCommandEnvelope {
        let objective = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !readOnlySubagents.contains(sessionID), let projection = reducers[sessionID]?.projection else { throw RelayFailure("goal_start_unavailable", "Open an ordinary task before starting a goal.") }
        guard !objective.isEmpty, objective.utf8.count <= 128_000 else { throw RelayFailure("goal_start_invalid", "A goal needs a nonempty objective of at most 128 KB.") }
        guard projection.config["mode"].string != "plan" else { throw RelayFailure("goal_plan_mode", "请先关闭计划模式，再开始追求目标。") }
        guard !projection.canStop, projection.pendingInteractions.isEmpty, projection.hostGoal?.isActive != true,
              !["running", "prewarming"].contains(projection.phase) else { throw RelayFailure("goal_start_unavailable", "请先停止或暂停当前任务，再设置新的目标。") }
        return makeCommand(sessionID: sessionID, type: "sendGoalCommand", payload: .object(["text": .string(objective), "displayText": .string("/goal " + objective)]), commandID: commandID)
    }
    public func startGoal(sessionID: String, text: String, commandID: String, explicitUserAction: Bool) async throws -> RelayCommandAck {
        try await submit(makeGoalCommand(sessionID: sessionID, text: text, commandID: commandID), explicitUserAction: explicitUserAction)
    }
    public func removeGoal(sessionID: String) throws {
        throw RelayFailure("goal_remove_unsupported", "The verified desktop protocol has no goal removal command.")
    }
    public func renameTask(sessionID: String, title: String, explicitUserAction: Bool) async throws -> RelayTaskMetadata {
        try RelayWire.requireAction(explicitUserAction); guard !title.isEmpty, title.count <= 200 else { throw RelayFailure.invalid("Invalid title.") }
        return try await rpc("zcode-task", "renameTask", ["taskId": .string(sessionID), "title": .string(title)]).decode(RelayTaskMetadata.self)
    }
    public func archiveTask(sessionID: String, archived: Bool, explicitUserAction: Bool) async throws -> RelayTaskMetadata {
        try RelayWire.requireAction(explicitUserAction)
        let result = try await rpc("zcode-task", archived ? "archiveTask" : "unarchiveTask", ["taskId": .string(sessionID)]).decode(RelayTaskMetadata.self)
        guard result.id == sessionID, let confirmed = try await listTasks(archived: archived).first(where: { $0.id == sessionID }) else { throw RelayFailure("metadata_not_confirmed", "The host has not confirmed the task's archive state.", outcomeUncertain: true) }
        var value = try RelayJSON(data: JSONEncoder().encode(confirmed)).requiringObject()
        value["archived"] = .bool(archived)
        return try RelayJSON.object(value).decode(RelayTaskMetadata.self)
    }
    public func pinTask(sessionID: String, pinned: Bool, explicitUserAction: Bool) async throws -> RelayTaskMetadata {
        try RelayWire.requireAction(explicitUserAction)
        return try await rpc("zcode-task", "setTaskPinned", ["taskId": .string(sessionID), "pinned": .bool(pinned)]).decode(RelayTaskMetadata.self)
    }
    public func setTaskUnread(sessionID: String, unread: Bool, expectedUnreadAt: Double? = nil, explicitUserAction: Bool) async throws -> RelayTaskMetadata {
        try RelayWire.requireAction(explicitUserAction)
        guard RelayWire.validID(sessionID) else { throw RelayFailure.invalid("Invalid task ID.") }
        if unread {
            guard expectedUnreadAt == nil else { throw RelayFailure.invalid("An unread marker does not take a clear timestamp.") }
        } else {
            guard let expectedUnreadAt, expectedUnreadAt.isFinite, expectedUnreadAt >= 0, expectedUnreadAt <= 9_007_199_254_740_991, expectedUnreadAt.rounded() == expectedUnreadAt else { throw RelayFailure.invalid("Clearing unread requires its exact expectedUnreadAt timestamp in milliseconds.") }
        }
        var params: [String: RelayJSON] = ["taskId": .string(sessionID), "unread": .bool(unread)]
        if let expectedUnreadAt { params["expectedUnreadAt"] = .number(expectedUnreadAt) }
        let result = try await rpc("zcode-task", "setTaskUnread", params).decode(RelayTaskMetadata.self)
        guard result.taskId == sessionID else { throw RelayFailure.invalid("The desktop returned another task's unread state.") }
        if unread, result.unreadAt == nil { throw RelayFailure("unread_change_not_confirmed", "The desktop did not confirm the unread marker.", outcomeUncertain: true) }
        return result
    }

    public func uploadAttachment(sessionID: String, fileName: String, mime: String, data: Data, uploadID: String, explicitUserAction: Bool) async throws -> RelayAttachment {
        try RelayWire.requireAction(explicitUserAction)
        guard RelayWire.validID(uploadID), !fileName.isEmpty, fileName.count <= 180, !fileName.hasPrefix("."), !fileName.contains(where: { "/\\\0\r\n".contains($0) }), !data.isEmpty, data.count <= 8 * 1024 * 1024 else { throw RelayFailure.invalid("Invalid attachment name, ID, or size.") }
        let textTypes = ["text/plain", "text/markdown", "text/csv", "application/json"], imageTypes = ["image/png", "image/jpeg", "image/webp", "image/gif"]
        guard textTypes.contains(mime) || imageTypes.contains(mime) || mime == "application/pdf" else { throw RelayFailure("attachment_unsupported", "This attachment type is unsupported.") }
        if textTypes.contains(mime) { guard data.count <= 64 * 1024, !data.contains(0), String(data: data, encoding: .utf8) != nil else { throw RelayFailure.invalid("Text attachments must be UTF-8 and at most 64 KiB.") } }
        // A model may have changed on the desktop since the last UI read.
        let snapshot = try await readSession(sessionID)
        if imageTypes.contains(mime), !snapshot.supports("supportsImages") { throw RelayFailure("model_does_not_support_images", "The selected desktop model does not advertise image input.") }
        if mime == "application/pdf", !snapshot.supports("supportsPdf") { throw RelayFailure("model_does_not_support_pdf", "The selected desktop model does not advertise PDF input.") }
        let signatureOK: Bool
        switch mime {
        case "image/png": signatureOK = data.prefix(8) == Data([137, 80, 78, 71, 13, 10, 26, 10])
        case "image/jpeg": signatureOK = data.prefix(3) == Data([255, 216, 255])
        case "image/gif": signatureOK = ["GIF87a", "GIF89a"].contains(String(data: data.prefix(6), encoding: .ascii) ?? "")
        case "image/webp": signatureOK = data.count >= 12 && data.prefix(4) == Data("RIFF".utf8) && data.subdata(in: 8..<12) == Data("WEBP".utf8)
        case "application/pdf": signatureOK = data.prefix(5) == Data("%PDF-".utf8)
        default: signatureOK = true
        }
        guard signatureOK else { throw RelayFailure("attachment_type_mismatch", "The file signature differs from its declared MIME type.") }
        let chunkSize = 384 * 1024, count = (data.count + chunkSize - 1) / chunkSize
        let scope: [String: RelayJSON] = ["sessionId": .string(sessionID), "uploadId": .string(uploadID)]
        var begin = scope; begin.merge(["fileName": .string(fileName), "mime": .string(mime), "totalBytes": .int(data.count), "totalChunks": .int(count), "checksum": .string("sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())]) { _, new in new }
        var begun = false
        do {
            var result = try await rpc("zcode-agent", "attachmentBeginV4", begin); begun = true
            if result["state"].string != "committed" {
                let first = try result.requiringInt("nextChunkIndex", maximum: count)
                for index in first..<count {
                    try Task.checkCancellation()
                    let end = min((index + 1) * chunkSize, data.count)
                    var chunk = scope; chunk["chunkIndex"] = .int(index); chunk["dataBase64"] = .string(data.subdata(in: (index * chunkSize)..<end).base64EncodedString())
                    result = try await rpc("zcode-agent", "attachmentChunkV4", chunk)
                    guard result["nextChunkIndex"].integer == index + 1 else { throw RelayFailure.invalid("Attachment progress did not match the uploaded chunk.") }
                    emit(.attachmentProgress(uploadID: uploadID, sent: end, total: data.count))
                }
                result = try await rpc("zcode-agent", "attachmentCommitV4", scope)
            }
            let ref = try result.requiringString("ref")
            return .init(sessionID: sessionID, ref: ref, fileName: fileName, mime: mime, bytes: data.count, previewRef: result["previewRef"].string)
        } catch {
            if begun, paired {
                // This unstructured cleanup is not cancelled with the caller's upload task.
                let cleanup = Task { _ = try? await self.rpc("zcode-agent", "attachmentAbortV4", scope, timeout: 3) }
                await cleanup.value
            }
            throw error
        }
    }
}
