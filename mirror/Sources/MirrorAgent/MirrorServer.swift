import Foundation
import Network
import CoreGraphics

/// WebSocket server on the MacBook. One video capture broadcast to every
/// authenticated viewer; text frames carry JSON commands from viewers.
///
/// Frames (binary): 0x01 key,pts-low32-be,u32 len, AVCC AU | 0x02 u32 len, JSON config
/// Text frames: {"action": ...} in; {"event": ...} out.
final class MirrorServer: @unchecked Sendable {
    private let lock = NSLock()
    private var listener: NWListener?
    private var viewers: [UUID: NWConnection] = [:]
    private var captureWindowID: UInt32?
    private var monitorTask: Task<Void, Never>?
    private var restarting = false
    let engine = CaptureEngine()
    let input = InputBridge()
    private let config: MirrorConfig

    init(config: MirrorConfig) {
        self.config = config
        engine.server = self
    }

    func start() throws {
        let parameters = NWParameters.tcp
        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: config.port) ?? 28800)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state { NSLog("mirror listener failed: \(error)") }
        }
        listener.start(queue: .main)
    }

    func stop() {
        monitorTask?.cancel(); monitorTask = nil
        lock.lock()
        let viewers = self.viewers; self.viewers = [:]
        let listener = self.listener; self.listener = nil
        lock.unlock()
        viewers.values.forEach { $0.cancel() }
        listener?.cancel()
        engine.stop()
    }

    /// Rotation and window resizes change the device rect; re-detect and restart
    /// the pipeline so the mirrored aspect keeps matching the device.
    private func startGeometryMonitor(windowID: UInt32) {
        monitorTask?.cancel()
        let previous = monitorTask
        monitorTask = Task { [weak self] in
            var last = CGRect.zero
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                if self.restarting { continue }
                guard let bounds = Self.windowFrame(windowID), bounds.width > 50, bounds.height > 50 else { continue }
                if last != .zero, abs(bounds.width - last.width) > 2 || abs(bounds.height - last.height) > 2 {
                    NSLog("mirror: window changed \(last) -> \(bounds); restarting capture")
                    self.restarting = true
                    self.engine.stop()
                    try? await self.engine.start(windowID: windowID, config: self.config)
                    self.restarting = false
                }
                last = bounds
            }
        }
        _ = previous
    }

    static func windowFrame(_ windowID: UInt32) -> CGRect? {
        let list = CGWindowListCopyWindowInfo([], kCGNullWindowID) as? [[String: Any]] ?? []
        guard let entry = list.first(where: { ($0[kCGWindowNumber as String] as? UInt32 ?? 0) == windowID }),
              let frame = entry[kCGWindowBounds as String] as? [String: Double],
              let width = frame["Width"], let height = frame["Height"], width > 0, height > 0 else { return nil }
        return CGRect(x: frame["X"] ?? 0, y: frame["Y"] ?? 0, width: width, height: height)
    }

    private func accept(_ connection: NWConnection) {
        NSLog("mirror: connection accepted")
        connection.start(queue: .main)
        receiveLoop(connection)
    }

    private func receiveLoop(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data { self.handle(data: data, connection: connection) }
            if error == nil { self.receiveLoop(connection) }
            else { self.drop(connection) }
        }
    }

    private func handle(data: Data, connection: NWConnection) {
        guard data.count >= 1 else { return }
        if data.first == UInt8(ascii: "{") {
            guard let command = try? JSONDecoder().decode(MirrorCommand.self, from: data) else { return }
            handle(command: command, connection: connection)
            return
        }
        // Binary from a viewer is ignored; video only flows outbound.
    }

    private func handle(command: MirrorCommand, connection: NWConnection) {
        NSLog("mirror: command \(command.action)")
        switch command.action {
        case "auth":
            guard command.token == config.token else {
                send(text: ["event": "error", "message": "token 不正确"], to: connection)
                connection.cancel()
                return
            }
            send(text: ["event": "ready"], to: connection)
            lock.lock(); viewers[UUID()] = connection; lock.unlock()
            if let configMessage = engine.currentConfigMessage() { send(binary: configMessage, to: connection) }
            engine.requestKeyframe()
        case "start":
            guard command.token == config.token else { return }
            startCapture(command: command, connection: connection)
        case "stop":
            guard command.token == config.token else { return }
            engine.stop()
            broadcast(text: ["event": "stopped"])
        case "windows":
            guard command.token == config.token else { return }
            Task {
                let windows = (try? await engine.listSimulatorWindows()) ?? []
                let payload: [[String: Any]] = windows.map { ["windowID": $0.windowID, "title": $0.title, "width": $0.widthPoints, "height": $0.heightPoints] }
                broadcast(text: ["event": "windows", "windows": payload])
            }
        case "tap":
            guard command.token == config.token, let x = command.x, let y = command.y else { return }
            input.tap(nx: x, ny: y, windowID: captureWindow(), engine: engine)
        case "swipe":
            guard command.token == config.token,
                  let x = command.x, let y = command.y, let x2 = command.x2, let y2 = command.y2 else { return }
            input.swipe(fromX: x, fromY: y, toX: x2, toY: y2, windowID: captureWindow(), engine: engine)
        case "longpress":
            guard command.token == config.token, let x = command.x, let y = command.y else { return }
            input.longPress(nx: x, ny: y, seconds: command.duration ?? 0.6, windowID: captureWindow(), engine: engine)
        case "key":
            guard command.token == config.token, let text = command.text else { return }
            input.type(text: text, windowID: captureWindow(), engine: engine)
        case "return":
            guard command.token == config.token else { return }
            input.pressReturn(windowID: captureWindow(), engine: engine)
        default:
            break
        }
    }

    private func startCapture(command: MirrorCommand, connection: NWConnection) {
        guard command.token == config.token else { return }
        Task { [weak self] in
            guard let self else { return }
            let fallback = await self.latestWindowID()
            let windowID = command.windowID ?? fallback ?? self.lock.withLock { self.captureWindowID }
            guard let windowID else {
                self.send(text: ["event": "error", "message": "Mac 上没有发现模拟器窗口"], to: connection)
                return
            }
            self.lock.withLock { self.captureWindowID = windowID }
            self.startGeometryMonitor(windowID: windowID)
            var effective = self.config
            if let width = command.width, width > 100 { effective.width = width }
            if let height = command.height, height > 100 { effective.height = height }
            if let fps = command.fps, (5...60).contains(fps) { effective.fps = fps }
            if let bitrate = command.bitrate, bitrate > 50_000 { effective.bitrate = bitrate }
            do {
                try await self.engine.start(windowID: windowID, config: effective)
                self.broadcast(text: ["event": "streaming", "windowID": Int(windowID),
                                      "width": effective.width, "height": effective.height,
                                      "fps": effective.fps, "bitrate": effective.bitrate])
            } catch {
                self.send(text: ["event": "error", "message": error.localizedDescription], to: connection)
            }
        }
    }

    private func latestWindowID() async -> UInt32? {
        let windows = (try? await engine.listSimulatorWindows()) ?? []
        // Helper/overlay windows carry empty titles; prefer a named device window.
        return (windows.first { !$0.title.isEmpty } ?? windows.first)?.windowID
    }

    private func captureWindow() -> UInt32? { lock.withLock { captureWindowID } }

    func broadcast(text payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        lock.lock(); let viewers = Array(self.viewers.values); lock.unlock()
        viewers.forEach { send(binary: data, to: $0) }
    }
    func broadcast(_ data: Data) {
        lock.lock(); let viewers = Array(self.viewers.values); lock.unlock()
        viewers.forEach { send(binary: data, to: $0) }
    }
    private func send(text payload: [String: Any], to connection: NWConnection) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        send(binary: data, to: connection)
    }
    private func send(binary data: Data, to connection: NWConnection) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: data.first == UInt8(ascii: "{") ? .text : .binary)
        let context = NWConnection.ContentContext(identifier: "mirror", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { error in
            if error != nil { self.drop(connection) }
        })
    }
    private func drop(_ connection: NWConnection) {
        lock.lock()
        viewers = viewers.filter { $0.value !== connection }
        lock.unlock()
        connection.cancel()
    }
}

struct MirrorCommand: Decodable {
    let action: String
    var token: String?
    var windowID: UInt32?
    var x: Double?
    var y: Double?
    var x2: Double?
    var y2: Double?
    var duration: Double?
    var text: String?
    var width: Int?
    var height: Int?
    var fps: Int?
    var bitrate: Int?
}
