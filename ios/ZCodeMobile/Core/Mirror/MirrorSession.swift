import UIKit
import Foundation
import AVFoundation
import AVKit
import CoreMedia
import CoreVideo

/// Streams the Mac's simulator screen over a dedicated WebSocket.
///
/// Protocol (matches mirror/Sources/MirrorAgent):
/// - text JSON: {action, token, ...} out; {event, ...} in
/// - binary: 0x01 key,pts-low32-BE,u32 len,AVCC AU | 0x02 u32 len,JSON {codec,width,height,avcC}
/// Compressed AUs go straight into AVSampleBufferDisplayLayer, which owns decoding.
@MainActor
@Observable
final class MirrorSession {
    static let shared = MirrorSession()

    enum Phase: Equatable {
        case idle, connecting, streaming
        case failed(String)
    }

    struct Quality: Equatable, Codable {
        var width: Int = 886
        var height: Int = 1920
        var fps: Int = 30
        var bitrate: Int = 1_200_000

        static let tiers: [String: Quality] = [
            "流畅": Quality(width: 540, height: 1170, fps: 20, bitrate: 600_000),
            "标准": Quality(width: 720, height: 1560, fps: 30, bitrate: 1_200_000),
            "高清": Quality(width: 886, height: 1920, fps: 30, bitrate: 2_400_000),
        ]
        var label: String {
            Self.tiers.first { $0.value == self }?.key ?? "自定义"
        }
    }

    private(set) var phase: Phase = .idle
    private(set) var fps: Double = 0
    private(set) var kbps: Double = 0
    private(set) var windows: [MirrorWindow] = []
    private(set) var streamingTitle: String?
    var quality: Quality = Quality() {
        didSet { saveQuality() }
    }
    var selectedWindowID: UInt32?

    private func saveQuality() {
        if let data = try? JSONEncoder().encode(quality) {
            UserDefaults.standard.set(data, forKey: "mirrorQuality")
        }
    }

    struct MirrorWindow: Identifiable, Equatable {
        let id: UInt32
        let title: String
        let width: Double
        let height: Double
    }

    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    @ObservationIgnored private var session: URLSession?
    @ObservationIgnored let renderer = MirrorRenderer()
    @ObservationIgnored private var receiveContinuation = false
    @ObservationIgnored private var statsTask: Task<Void, Never>?
    @ObservationIgnored private var receivedCounter = 0
    @ObservationIgnored private var frameWindow: (count: Int, bytes: Int, startedAt: Date) = (0, 0, Date())
    @ObservationIgnored private var lastFrameDate = Date()
    @ObservationIgnored private var reconnectAttempts = 0
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var pendingReconnect = false
    @ObservationIgnored private var wantsStream = false
    @ObservationIgnored private var autoPiPTried = false
    @ObservationIgnored private var endpoint: String = UserDefaults.standard.string(forKey: "mirrorEndpoint") ?? ""
    @ObservationIgnored private var token: String = UserDefaults.standard.string(forKey: "mirrorToken") ?? ""

    private init() {
        if let data = UserDefaults.standard.data(forKey: "mirrorQuality"), let saved = try? JSONDecoder().decode(Quality.self, from: data) {
            quality = saved
        }
    }

    var isStreaming: Bool { phase == .streaming || phase == .connecting }

    func updateCredentials(endpoint: String, token: String) {
        self.endpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let defaults = UserDefaults.standard
        defaults.set(self.endpoint, forKey: "mirrorEndpoint")
        if !self.token.isEmpty { defaults.set(self.token, forKey: "mirrorToken") }
    }
    var savedEndpoint: String { endpoint }
    var savedTokenSet: Bool { !token.isEmpty }

    func start(windowID: UInt32? = nil, isRetry: Bool = false) {
        guard !endpoint.isEmpty, !token.isEmpty else {
            if endpoint.isEmpty || token.isEmpty { phase = .failed("请先在下方填写镜像连接与令牌。") }
            return
        }
        if isStreaming, !isRetry { return }
        reconnectTask?.cancel(); reconnectTask = nil; pendingReconnect = false
        if !isRetry { reconnectAttempts = 0 }
        stop(keepCredentials: true)
        phase = .connecting
        wantsStream = true
        lastFrameDate = Date()
        autoPiPTried = false
        renderer.reset()
        let configured = URLSessionConfiguration.default
        configured.timeoutIntervalForRequest = 12
        let session = URLSession(configuration: configured)
        self.session = session
        var address = endpoint
        if !address.hasPrefix("ws://") && !address.hasPrefix("wss://") { address = "wss://" + address }
        guard let url = URL(string: address) else {
            phase = .failed("镜像地址格式不正确。")
            return
        }
        let socket = session.webSocketTask(with: url)
        self.socket = socket
        socket.resume()
        receiveLoop(socket)
        send(["action": "auth", "token": token])
        let payload: [String: Any] = ["action": "start", "token": token,
                                      "width": quality.width, "height": quality.height,
                                      "fps": quality.fps, "bitrate": quality.bitrate]
        if let windowID { var full = payload; full["windowID"] = Int(windowID); send(full) } else { send(payload) }
        statsTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.isStreaming else { return }
                let window = self.frameWindow
                let elapsed = Date().timeIntervalSince(window.startedAt)
                if elapsed >= 0.9 {
                    self.fps = Double(window.count) / elapsed
                    self.kbps = Double(window.bytes) * 8 / elapsed / 1000
                    self.frameWindow = (0, 0, Date())
                }
                if self.phase == .streaming, Date().timeIntervalSince(self.lastFrameDate) > 12 {
                    NSLog("mirror: no frames for 12s; scheduling reconnect")
                    self.scheduleReconnect(reason: "画面停止更新")
                }
                self.maybeAutoPiP()
            }
        }
    }

    func stop(keepCredentials: Bool = false) {
        statsTask?.cancel(); statsTask = nil
        reconnectTask?.cancel(); reconnectTask = nil
        pendingReconnect = false
        wantsStream = false
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        if !keepCredentials { /* credentials persist for the next start */ }
        session?.invalidateAndCancel(); session = nil
        renderer.reset()
        fps = 0; kbps = 0
        streamingTitle = nil
        if case .streaming = phase { phase = .idle }
        if case .connecting = phase { phase = .idle }
    }

    func refreshWindows() {
        guard isStreaming || !endpoint.isEmpty else { return }
        if socket == nil, !endpoint.isEmpty, !token.isEmpty {
            // A lightweight control-only connection lists windows without streaming.
            startControlProbe()
        }
        send(["action": "windows", "token": token])
    }

    /// Connects only to enumerate simulators; closes after the reply.
    private func startControlProbe() {
        stop(keepCredentials: true)
        phase = .connecting
        wantsStream = false
        let configured = URLSessionConfiguration.default
        configured.timeoutIntervalForRequest = 8
        let session = URLSession(configuration: configured)
        self.session = session
        var address = endpoint
        if !address.hasPrefix("ws://") && !address.hasPrefix("wss://") { address = "wss://" + address }
        guard let url = URL(string: address) else { phase = .failed("镜像地址格式不正确。"); return }
        let socket = session.webSocketTask(with: url)
        self.socket = socket
        socket.resume()
        receiveLoop(socket)
        send(["action": "auth", "token": token])
    }

    /// Auto-floats the stream into picture-in-picture shortly after the first
    /// frames land — from a calm main-queue turn, never from inside the media
    /// pipeline (starting PiP mid-enqueue wedged AVFoundation on device).
    private func maybeAutoPiP() {
        guard phase == .streaming, !autoPiPTried, renderer.configured,
              renderer.autoPiPEnabled, !renderer.isPiPActive,
              AVPictureInPictureController.isPictureInPictureSupported() else { return }
        autoPiPTried = true
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.8))
            guard let self, self.isStreaming, !self.renderer.isPiPActive else { return }
            NSLog("mirror: auto PiP start")
            self.renderer.startPiP()
        }
    }

    // MARK: - Commands

    func tap(normalizedX x: Double, y: Double) { send(["action": "tap", "token": token, "x": x, "y": y]) }
    func swipe(fromX: Double, fromY: Double, toX: Double, toY: Double) {
        send(["action": "swipe", "token": token, "x": fromX, "y": fromY, "x2": toX, "y2": toY])
    }
    func longPress(normalizedX x: Double, y: Double) {
        send(["action": "longpress", "token": token, "x": x, "y": y, "duration": 0.6])
    }

    private func send(_ payload: [String: Any]) {
        guard let socket, let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        socket.send(.data(data)) { error in
            if let error { NSLog("mirror send failed: \(error.localizedDescription)") }
        }
    }

    // MARK: - Receive loop

    private func receiveLoop(_ socket: URLSessionWebSocketTask) {
        socket.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch result {
                case .success(let message):
                    self.handle(message)
                    if self.socket === socket { self.receiveLoop(socket) }
                case .failure(let error):
                    if self.socket === socket {
                        if self.wantsStream {
                            self.scheduleReconnect(reason: "镜像连接中断：\(error.localizedDescription)")
                        } else {
                            self.phase = .failed("镜像连接中断：\(error.localizedDescription)")
                            self.stop(keepCredentials: true)
                        }
                    }
                }
            }
        }
    }

    /// Transport resilience: WebSocket drops and frame stalls self-heal with a
    /// short backoff; manual starts reset the attempt budget.
    private func scheduleReconnect(reason: String) {
        guard reconnectTask == nil, !pendingReconnect else { return }
        guard reconnectAttempts < 5 else {
            NSLog("mirror: reconnect exhausted: \(reason)")
            phase = .failed("镜像连接多次失败：\(reason)")
            stop(keepCredentials: true)
            return
        }
        reconnectAttempts += 1
        pendingReconnect = true
        phase = .connecting
        NSLog("mirror: reconnect attempt \(reconnectAttempts): \(reason)")
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled else { return }
            self.reconnectTask = nil
            guard self.pendingReconnect else { return }
            self.pendingReconnect = false
            self.start(windowID: self.selectedWindowID, isRetry: true)
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let text):
            guard let data = text.data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let event = payload["event"] as? String else { return }
            switch event {
            case "ready":
                if case .failed = phase { phase = .connecting }
                send(["action": "windows", "token": token])
            case "windows":
                let list = (payload["windows"] as? [[String: Any]] ?? []).compactMap { item -> MirrorWindow? in
                    guard let id = item["windowID"] as? Int, id > 0 else { return nil }
                    return MirrorWindow(id: UInt32(id), title: item["title"] as? String ?? "模拟器",
                                        width: item["width"] as? Double ?? 0, height: item["height"] as? Double ?? 0)
                }
                windows = list
                if selectedWindowID == nil { selectedWindowID = list.first?.id }
                if case .connecting = phase, renderer.configured == false {
                    // Control-only probe keeps the connection for a moment, then stops.
                }
            case "streaming":
                phase = .streaming
                streamingTitle = windows.first { $0.id == UInt32(payload["windowID"] as? Int ?? 0) }?.title ?? "模拟器"
            case "stopped":
                if phase == .streaming { phase = .idle }
            case "error":
                phase = .failed(payload["message"] as? String ?? "镜像启动失败。")
                stop(keepCredentials: true)
            default:
                break
            }
        case .data(let data):
            handleFrame(data)
        @unknown default:
            break
        }
    }

    private func handleFrame(_ data: Data) {
        receivedCounter += 1
        lastFrameDate = Date()
        reconnectAttempts = 0
        if receivedCounter % 60 == 1 { NSLog("mirror: frame #\(receivedCounter) type=\(data[0]) len=\(data.count) configured=\(renderer.configured)") }
        guard data.count > 6 else { return }
        switch data[0] {
        case 0x02:
            let length = Int(data.subdata(in: 1..<5).map { UInt32($0) }.enumerated().reduce(0) { $0 + UInt64($1.element) << UInt64(8 * (3 - $1.offset)) })
            guard data.count >= 5 + length, let json = try? JSONSerialization.jsonObject(with: data.subdata(in: 5..<5 + length)) as? [String: Any],
                  let avcCBase64 = json["avcC"] as? String, let avcC = Data(base64Encoded: avcCBase64) else { return }
            let width = json["width"] as? Int ?? quality.width
            let height = json["height"] as? Int ?? quality.height
            renderer.configure(width: width, height: height, avcC: avcC)
        case 0x01:
            let keyframe = data[1] == 1
            let pts = data.subdata(in: 2..<6).map { UInt32($0) }.enumerated().reduce(UInt64(0)) { $0 + UInt64($1.element) << UInt64(8 * (3 - $1.offset)) }
            let length = Int(data.subdata(in: 6..<10).map { UInt32($0) }.enumerated().reduce(0) { $0 + UInt64($1.element) << UInt64(8 * (3 - $1.offset)) })
            guard data.count >= 10 + length else { return }
            let au = data.subdata(in: 10..<10 + length)
            renderer.enqueue(accessUnit: au, keyframe: keyframe, ptsMilliseconds: Int64(pts))
            frameWindow.count += 1
            frameWindow.bytes += data.count
            if case .connecting = phase { phase = .streaming }
        default:
            break
        }
    }
}

/// Which inline surface currently wants the video layer.
enum MirrorSurface: Equatable {
    case none, inline, fullscreen
}

/// Owns the persistent AVSampleBufferDisplayLayer and the media pipeline.
/// Sample construction and enqueue run on a dedicated serial queue; layer-tree
/// mutations (mount / PiP) stay on the main actor and are refused while the
/// PiP window owns the layer — fighting the PiP system for the layer freezes
/// the whole app.
@MainActor
final class MirrorRenderer {
    private(set) var configured = false
    private var format: CMVideoFormatDescription?
    private var size: (width: Int, height: Int) = (0, 0)
    var videoSize: CGSize { CGSize(width: size.width, height: size.height) }
    /// One persistent layer for the renderer's lifetime, re-parented into
    /// whichever host view is on screen; PiP binds to it once. Its built-in
    /// control timebase sits at rate 0 — frames would be scheduled forever and
    /// never shown — hence the running timebase created up front.
    @ObservationIgnored private let videoLayer = AVSampleBufferDisplayLayer()
    @ObservationIgnored nonisolated(unsafe) private var timebase: CMTimebase?
    @ObservationIgnored nonisolated(unsafe) private var mediaLayerRef: AVSampleBufferDisplayLayer?
    @ObservationIgnored private let mediaQueue = DispatchQueue(label: "dev.paco.zcode.mirror.media")
    @ObservationIgnored private let stateLock = NSLock()
    @ObservationIgnored nonisolated(unsafe) private var mediaFormat: CMVideoFormatDescription?
    @ObservationIgnored nonisolated(unsafe) private var loggedFirstSample = false
    @ObservationIgnored private let pipDelegate = MirrorPiPDelegate()
    @ObservationIgnored private var pipController: AVPictureInPictureController?
    @ObservationIgnored private var pipActiveObservation: NSKeyValueObservation?
    private(set) var isPiPActive = false
    var autoPiPEnabled: Bool {
        didSet { UserDefaults.standard.set(autoPiPEnabled, forKey: "mirrorAutoPiP") }
    }

    init() {
        autoPiPEnabled = UserDefaults.standard.object(forKey: "mirrorAutoPiP") as? Bool ?? true
        let timebase = try? CMTimebase(sourceClock: CMClock.hostTimeClock)
        try? timebase?.setRate(1.0)
        self.timebase = timebase
        videoLayer.videoGravity = .resizeAspect
        videoLayer.controlTimebase = timebase
        mediaLayerRef = videoLayer
    }

    /// Floating system picture-in-picture window; survives leaving the app page.
    func startPiP() {
        guard pipController == nil, !isPiPActive else { return }
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        // A playback audio session is the standard companion of sample-buffer
        // PiP; without it the floating window may not be granted runtime.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: videoLayer, playbackDelegate: pipDelegate)
        let controller = AVPictureInPictureController(contentSource: source)
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        pipDelegate.renderer = self
        pipController = controller
        pipActiveObservation = controller.observe(\.isPictureInPictureActive, options: [.new]) { [weak self] _, change in
            let active = change.newValue ?? false
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isPiPActive = active
                if !active {
                    // The PiP window was closed (by us or by the system); drop
                    // the spent controller so the next start can create a fresh one.
                    self.pipController = nil
                    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                }
            }
        }
        controller.startPictureInPicture()
    }

    func stopPiP() {
        pipActiveObservation = nil
        pipController?.stopPictureInPicture()
        pipController = nil
        isPiPActive = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    nonisolated func currentTimebaseTime() -> CMTime { timebase?.time ?? .zero }

    /// Which inline surface currently wants the video layer. Exactly one owns
    /// it at a time; SwiftUI calls updateUIView on every visible representable
    /// on every render pass, so mounts must be idempotent — letting two hosts
    /// fight for the layer ping-pongs reparents (observed: 10+/2ms) and wedges
    /// the whole app.
    var surface: MirrorSurface = .none
    @ObservationIgnored private weak var ownerView: UIView?

    /// Re-parents the persistent video layer into the host view, filling bounds.
    /// Refused while the PiP window owns the layer — stealing it back would
    /// freeze both surfaces.
    func mount(in view: UIView, surface requested: MirrorSurface) {
        guard !isPiPActive else {
            if ownerView === view { detach() }
            return
        }
        guard self.surface == requested else {
            if ownerView === view { detach() }
            return
        }
        if videoLayer.superlayer !== view.layer {
            NSLog("mirror: mount reparent surface=\(requested == .fullscreen ? "fullscreen" : "inline")")
            view.layer.addSublayer(videoLayer)
        }
        ownerView = view
        let target = CGRect(origin: .zero, size: view.bounds.size)
        if videoLayer.frame != target {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            videoLayer.frame = target
            CATransaction.commit()
        }
    }

    func detach() {
        videoLayer.removeFromSuperlayer()
        ownerView = nil
    }

    func configure(width: Int, height: Int, avcC: Data) {
        if configured, size.width == width, size.height == height, format != nil {
            // Same format; keep rendering. The layer resyncs on its own after errors.
            return
        }
        var formatOut: CMVideoFormatDescription?
        let extensions = ["SampleDescriptionExtensionAtoms": ["avcC": avcC]] as CFDictionary
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, codecType: kCMVideoCodecType_H264,
            width: Int32(width), height: Int32(height), extensions: extensions,
            formatDescriptionOut: &formatOut)
        guard status == noErr, let formatOut else {
            NSLog("mirror format description failed \(status)")
            return
        }
        format = formatOut
        size = (width, height)
        configured = true
        stateLock.lock()
        mediaFormat = formatOut
        stateLock.unlock()
        videoLayer.sampleBufferRenderer.flush()
    }

    func reset() {
        stopPiP()
        configured = false
        format = nil
        stateLock.lock()
        mediaFormat = nil
        stateLock.unlock()
        mediaQueue.async { self.loggedFirstSample = false }
        videoLayer.sampleBufferRenderer.flush()
    }

    /// Media work happens off the main actor on a serial queue; the display
    /// layer's enqueue is thread-safe and the main thread stays free for UI.
    nonisolated func enqueue(accessUnit: Data, keyframe: Bool, ptsMilliseconds: Int64) {
        mediaQueue.async { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let format = self.mediaFormat
            self.stateLock.unlock()
            guard let format, let layer = self.mediaLayerRef else { return }
            var blockBuffer: CMBlockBuffer?
            let capacity = accessUnit.count
            let createStatus = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: capacity, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: capacity, flags: 0, blockBufferOut: &blockBuffer)
            guard createStatus == kCMBlockBufferNoErr, let blockBuffer else { return }
            let replaceStatus = accessUnit.withUnsafeBytes { pointer -> OSStatus in
                CMBlockBufferReplaceDataBytes(with: pointer.baseAddress!, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: capacity)
            }
            guard replaceStatus == kCMBlockBufferNoErr else { return }
            var sampleBuffer: CMSampleBuffer?
            let sampleStatus = CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: blockBuffer, dataReady: true, makeDataReadyCallback: nil, refcon: nil, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sampleBuffer)
            guard sampleStatus == noErr, let sampleBuffer else { return }
            let timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(value: CMTimeValue(ptsMilliseconds), timescale: 1000), decodeTimeStamp: .invalid)
            let setPtsStatus = CMSampleBufferSetOutputPresentationTimeStamp(sampleBuffer, newValue: timing.presentationTimeStamp)
            guard setPtsStatus == noErr else { return }
            if let timebase = self.timebase { try? timebase.setTime(timing.presentationTimeStamp) }
            layer.sampleBufferRenderer.enqueue(sampleBuffer)
            if !self.loggedFirstSample {
                self.loggedFirstSample = true
                NSLog("mirror: media queue first sample au=\(capacity) pts=\(ptsMilliseconds)")
            }
            if layer.status == .failed {
                NSLog("mirror layer failed: \(layer.sampleBufferRenderer.error?.localizedDescription ?? "?")")
                layer.sampleBufferRenderer.flush()
            }
        }
    }
}


/// Live-stream semantics for the sample-buffer PiP: always playing, always at
/// the live edge; the visible frames come from the shared display layer.
/// The PiP system calls these off the main actor; CMTimebase reads are
/// thread-safe and the mutable flags are advisory only.
final class MirrorPiPDelegate: NSObject, AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated(unsafe) weak var renderer: MirrorRenderer?
    nonisolated(unsafe) private(set) var playing = true

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
        self.playing = playing
    }

    func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .zero, duration: renderer?.currentTimebaseTime() ?? .zero)
    }

    func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool { false }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) {
        completionHandler()
    }

    func pictureInPictureControllerShouldProhibitBackgroundAudioPlayback(_ pictureInPictureController: AVPictureInPictureController) -> Bool { true }
}
