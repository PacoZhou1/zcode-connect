import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox
import ScreenCaptureKit
import AppKit
import ApplicationServices

/// Captures one Simulator window with ScreenCaptureKit and feeds H.264 frames
/// to a broadcaster. The crop removes the window title bar; scaling to the
/// encode resolution happens in the stream configuration.
///
/// Pipeline: SCStream(.screen samples, encoder queue)
///   -> VTCompressionSession -> compressed CMSampleBuffer
///   -> AVCC AU + pts -> MirrorServer.broadcast
final class CaptureEngine: NSObject, @unchecked Sendable {
    private let lock = NSLock()
    private var stream: SCStream?
    private var compression: VTCompressionSession?
    private var avcCData: Data?
    private var encodeSize: (width: Int, height: Int) = (0, 0)
    private var forceKeyOnNextFrame = true
    private var windowPoints: (width: Double, height: Double) = (0, 0)
    private var contentRect: CGRect = .zero   // device screen area, window-relative points
    private var contentBundle: String = "com.apple.iphonesimulator"
    func currentContentBundle() -> String { lock.withLock { contentBundle } }
    weak var server: MirrorServer?

    struct Snapshot: Sendable {
        let windowID: UInt32
        let title: String
        let widthPoints: Double
        let heightPoints: Double
        var bundleID: String = "com.apple.iphonesimulator"
    }

    /// Device windows: Xcode 27's DeviceHub pop-outs and the legacy Simulator app.
    static let deviceBundles = ["com.apple.dt.Devices", "com.apple.iphonesimulator"]
    static func chromeHeight(forBundle bundle: String) -> Double { bundle == "com.apple.dt.Devices" ? 56 : 62 }

    func listSimulatorWindows() async throws -> [Snapshot] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        return content.windows.compactMap { window in
            // DeviceHub helper windows have no title and are not devices.
            guard let app = window.owningApplication, Self.deviceBundles.contains(app.bundleIdentifier),
                  window.frame.width > 200, window.frame.height > 300,
                  !(window.title ?? "").isEmpty else { return nil }
            return Snapshot(windowID: window.windowID, title: window.title ?? "",
                            widthPoints: window.frame.width, heightPoints: window.frame.height,
                            bundleID: app.bundleIdentifier)
        }
    }

    func start(windowID: UInt32, config: MirrorConfig) async throws {
        stop()
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let window = content.windows.first(where: { $0.windowID == windowID }),
              let app = window.owningApplication, Self.deviceBundles.contains(app.bundleIdentifier) else {
            throw MirrorError("找不到对应的模拟器窗口，请先在 Mac 上打开模拟器或 DeviceHub。")
        }
        let owningBundle = app.bundleIdentifier
        // Window capture only streams reliably when the window is on screen; raise
        // the target window so occluded or other-space simulators come forward.
        Self.raiseWindow(windowID: windowID, title: window.title ?? "")
        if let simulator = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.iphonesimulator").first {
            simulator.activate()
        }
        usleep(250_000)
        lock.withLock {
            forceKeyOnNextFrame = true
            windowPoints = (window.frame.width, window.frame.height)
        }
        // The window chrome (title bar + toolbar) and the device bezel must be cut
        // away. Detect the device screen's bounding box with a small probe stream.
        let fullRect = CGRect(x: 0, y: 0, width: window.frame.width, height: window.frame.height)
        let chrome = Self.chromeHeight(forBundle: owningBundle)
        let deviceRect: CGRect
        if owningBundle == "com.apple.dt.Devices" {
            // DeviceHub pop-outs sit the device on a light background; find the
            // dark bezel's bounding box so only the device is mirrored.
            let probed = try await detectDarkDeviceRect(windowID: windowID, windowRect: fullRect)
            deviceRect = probed ?? CGRect(x: 0, y: chrome, width: fullRect.width, height: max(1, fullRect.height - chrome))
            NSLog("mirror: devicehub rect \(deviceRect)")
        } else {
            deviceRect = try await detectDeviceRect(windowID: windowID, windowRect: fullRect)
            NSLog("mirror: detected device rect \(deviceRect) in window \(fullRect)")
        }
        lock.withLock { contentRect = deviceRect; contentBundle = owningBundle }
        // The encode resolution follows the device's current orientation: the
        // quality tier's width is the short edge and its height the long edge.
        let portrait = deviceRect.height >= deviceRect.width
        let encodeWidth = portrait ? config.width : config.height
        let encodeHeight = portrait ? config.height : config.width
        lock.withLock { encodeSize = (encodeWidth, encodeHeight) }

        var streamConfig = SCStreamConfiguration()
        streamConfig.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(5, config.fps)))
        streamConfig.queueDepth = 4
        streamConfig.showsCursor = true
        streamConfig.sourceRect = deviceRect
        streamConfig.width = encodeWidth
        streamConfig.height = encodeHeight
        streamConfig.scalesToFit = true
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let stream = SCStream(filter: filter, configuration: streamConfig, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: encoderQueue)
        try await stream.startCapture()
        lock.withLock { self.stream = stream }
        try await startEncoder(width: encodeWidth, height: encodeHeight, fps: config.fps, bitrate: config.bitrate)
    }

    /// One low-resolution frame over the whole window; the device screen is the
    /// largest non-black region inside it (the bezel and chrome are black).
    private func detectDeviceRect(windowID: UInt32, windowRect: CGRect) async throws -> CGRect {
        var streamConfig = SCStreamConfiguration()
        streamConfig.sourceRect = windowRect
        streamConfig.width = 160
        streamConfig.height = 340
        streamConfig.scalesToFit = true
        streamConfig.minimumFrameInterval = CMTime(value: 1, timescale: 5)
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw MirrorError("窗口不存在。")
        }
        let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: window), configuration: streamConfig, delegate: nil)
        let box = FrameBox()
        try stream.addStreamOutput(box, type: .screen, sampleHandlerQueue: detectionQueue)
        try await stream.startCapture()
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(80))
            if box.image != nil { break }
        }
        try await stream.stopCapture()
        guard let image = box.image else { throw MirrorError("检测设备屏幕区域失败：没有抓到帧。") }
        // The window chrome (title bar + toolbar) is light when focused and must be
        // excluded unconditionally; the device bezel around the screen is pure black.
        let chromeTopFraction = min(0.2, 62.0 / max(1, windowRect.height))
        var bounds = Self.brightBounds(image: image, threshold: 40)
        NSLog("mirror: bright bounds \(bounds)")
        let clampedMinY = max(bounds.minY, chromeTopFraction)
        bounds.height = max(0, bounds.height - (clampedMinY - bounds.minY))
        bounds.minY = clampedMinY
        guard bounds.width > 0.3, bounds.height > 0.3 else {
            // A dark screen defeats the scan; fall back to a chrome-only crop.
            return CGRect(x: 0, y: 62, width: windowRect.width, height: windowRect.height - 62)
        }
        return CGRect(x: windowRect.minX + bounds.minX * windowRect.width,
                      y: windowRect.minY + bounds.minY * windowRect.height,
                      width: bounds.width * windowRect.width,
                      height: bounds.height * windowRect.height)
    }

    /// Normalized bounding box of pixels brighter than the threshold.
    static func brightBounds(image: CGImage, threshold: UInt8) -> (minX: Double, minY: Double, width: Double, height: Double) {
        let width = image.width, height = image.height
        guard width > 0, height > 0, let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else {
            return (0, 0, 1, 1)
        }
        let bytesPerRow = image.bytesPerRow
        let components = image.bitsPerPixel / 8
        var minX = width, maxX = -1, minY = height, maxY = -1
        for y in stride(from: 0, to: height, by: 2) {
            let row = bytes + y * bytesPerRow
            for x in stride(from: 0, to: width, by: 2) {
                let offset = x * components
                let blue = row[offset], green = row[offset + 1], red = row[offset + 2]
                if max(red, max(green, blue)) > threshold {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
            }
        }
        guard maxX >= 0, maxY >= 0 else { return (0, 0, 1, 1) }
        return (Double(minX) / Double(width), Double(minY) / Double(height),
                Double(maxX - minX + 1) / Double(width), Double(maxY - minY + 1) / Double(height))
    }

    /// DeviceHub pop-outs place the (dark-bezeled) device on a light background.
    /// A dark-pixel bounding box isolates the device regardless of screen content.
    private func detectDarkDeviceRect(windowID: UInt32, windowRect: CGRect) async throws -> CGRect? {
        var streamConfig = SCStreamConfiguration()
        // Probe only the chrome-free band so title-bar indicators and the bottom
        // toolbar cannot contaminate the dark-pixel bounding box.
        let chrome = Self.chromeHeight(forBundle: "com.apple.dt.Devices")
        let bottomBar = min(40, windowRect.height * 0.06)
        let contentRect = CGRect(x: 0, y: chrome, width: windowRect.width,
                                 height: max(1, windowRect.height - chrome - bottomBar))
        streamConfig.sourceRect = contentRect
        streamConfig.width = 160
        streamConfig.height = 340
        streamConfig.scalesToFit = true
        streamConfig.showsCursor = false
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else { return nil }
        let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: window), configuration: streamConfig, delegate: nil)
        let box = FrameBox()
        try stream.addStreamOutput(box, type: .screen, sampleHandlerQueue: detectionQueue)
        try await stream.startCapture()
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(80))
            if box.image != nil { break }
        }
        try await stream.stopCapture()
        guard let image = box.image else { return nil }
        let bounds = Self.darkBounds(image: image, threshold: 70)
        guard bounds.width > 0.2, bounds.height > 0.35 else { return nil }
        return CGRect(x: contentRect.minX + bounds.minX * contentRect.width,
                      y: contentRect.minY + bounds.minY * contentRect.height,
                      width: bounds.width * contentRect.width,
                      height: bounds.height * contentRect.height)
    }

    static func darkBounds(image: CGImage, threshold: UInt8) -> (minX: Double, minY: Double, width: Double, height: Double) {
        let width = image.width, height = image.height
        guard width > 0, height > 0, let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else {
            return (0, 0, 1, 1)
        }
        let bytesPerRow = image.bytesPerRow
        let components = image.bitsPerPixel / 8
        var minX = width, maxX = -1, minY = height, maxY = -1
        for y in stride(from: 0, to: height, by: 2) {
            let row = bytes + y * bytesPerRow
            for x in stride(from: 0, to: width, by: 2) {
                let offset = x * components
                let blue = row[offset], green = row[offset + 1], red = row[offset + 2]
                if max(red, max(green, blue)) < threshold {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
            }
        }
        guard maxX >= 0, maxY >= 0 else { return (0, 0, 0, 0) }
        return (Double(minX) / Double(width), Double(minY) / Double(height),
                Double(maxX - minX + 1) / Double(width), Double(maxY - minY + 1) / Double(height))
    }

    /// Bring the simulator window to the front of its space via the Accessibility
    /// API. Needs the assistive permission the input bridge already requires.
    static func raiseWindow(windowID: UInt32, title: String) {
        let list = CGWindowListCopyWindowInfo([], kCGNullWindowID) as? [[String: Any]] ?? []
        guard let entry = list.first(where: { ($0[kCGWindowNumber as String] as? UInt32 ?? 0) == windowID }),
              let pid = entry[kCGWindowOwnerPID as String] as? Int32 else { return }
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return }
        for axWindow in windows {
            var titleValue: CFTypeRef?
            // SCWindow titles omit the simulator's runtime suffix; match by prefix.
            guard AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleValue) == .success,
                  (titleValue as? String)?.hasPrefix(title) == true else { continue }
            // A minimized window cannot be captured; restore it first.
            AXUIElementSetAttributeValue(axWindow, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
            return
        }
    }

    func stop() {
        lock.lock()
        let stream = self.stream; self.stream = nil
        let session = self.compression; self.compression = nil
        self.avcCData = nil
        lock.unlock()
        if let stream { try? stream.stopCapture() }
        if let session { VTCompressionSessionInvalidate(session) }
    }

    func requestKeyframe() { lock.withLock { forceKeyOnNextFrame = true } }

    func contentRectInWindowPoints() -> CGRect { lock.withLock { contentRect } }

    // MARK: - SCStreamOutput

    private let encoderQueue = DispatchQueue(label: "mirror.capture")
    private let detectionQueue = DispatchQueue(label: "mirror.detect")

    func currentConfigMessage() -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard let avcC = avcCData else { return nil }
        let payload: [String: Any] = ["codec": "avc1", "width": encodeSize.width, "height": encodeSize.height, "avcC": avcC.base64EncodedString()]
        guard let json = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        var message = Data([0x02]); var length = UInt32(json.count).bigEndian
        withUnsafeBytes(of: &length) { message.append(contentsOf: $0) }
        message.append(json)
        return message
    }

    // MARK: - Encoder

    private func startEncoder(width: Int, height: Int, fps: Int, bitrate: Int) async throws {
        lock.withLock { encodeSize = (width, height) }
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault, width: Int32(width), height: Int32(height),
            codecType: kCMVideoCodecType_H264, encoderSpecification: nil,
            imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: { refcon, _, status, _, sampleBuffer in
                guard let refcon else { return }
                let engine = Unmanaged<CaptureEngine>.fromOpaque(refcon).takeUnretainedValue()
                engine.encoderQueue.async { engine.publishEncoded(status: status, sampleBuffer: sampleBuffer) }
            },
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &session)
        guard status == noErr, let session else { throw MirrorError("视频编码器创建失败 (\(status))。") }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Main_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: bitrate))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: fps))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: max(fps, 30) * 2))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        guard VTCompressionSessionPrepareToEncodeFrames(session) == noErr else {
            VTCompressionSessionInvalidate(session)
            throw MirrorError("视频编码器初始化失败。")
        }
        lock.withLock { self.compression = session }
    }

    /// SCStream output: a scaled screen frame arrives; hand it to the compressor.
    var captureCount = 0, publishCount = 0
    fileprivate func captureSample(_ sampleBuffer: CMSampleBuffer) {
        captureCount += 1
        if captureCount % 60 == 1 { NSLog("mirror sc frames: \(captureCount) encoded: \(publishCount)") }
        guard CMSampleBufferDataIsReady(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lock.lock()
        let session = compression
        let forceKey = forceKeyOnNextFrame
        forceKeyOnNextFrame = false
        lock.unlock()
        guard let session else { return }
        var frameProperties: [CFString: Any] = [:]
        if forceKey { frameProperties[kVTEncodeFrameOptionKey_ForceKeyFrame] = true }
        let status = VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixelBuffer,
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
            duration: .invalid, frameProperties: frameProperties as CFDictionary,
            sourceFrameRefcon: nil, infoFlagsOut: nil)
        if status != noErr { NSLog("mirror encode error \(status)") }
    }

    /// VT output: a compressed AVCC access unit; wrap and broadcast.
    fileprivate func publishEncoded(status: OSStatus, sampleBuffer: CMSampleBuffer?) {
        publishCount += 1
        guard status == noErr, let sampleBuffer, CMSampleBufferDataIsReady(sampleBuffer),
              let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[String: Any]],
              let first = attachmentsArray.first else { return }
        let keyframe = !(first[kCMSampleAttachmentKey_NotSync as String] as? Bool ?? false)
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let total = CMBlockBufferGetDataLength(block)
        var au = Data(count: total)
        au.withUnsafeMutableBytes { pointer in
            _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: total, destination: pointer.baseAddress!)
        }
        guard !au.isEmpty else { return }
        // Config refresh is keyframe-only work; the frame itself always broadcasts.
        if keyframe, let format = CMSampleBufferGetFormatDescription(sampleBuffer),
           let extensions = CMFormatDescriptionGetExtensions(format) as? [String: Any],
           let atoms = extensions["SampleDescriptionExtensionAtoms"] as? [String: Any],
           let avcC = atoms["avcC"] as? Data {
            let changed = lock.withLock { () -> Bool in
                let previous = avcCData; avcCData = avcC; return previous != avcC
            }
            if changed, let message = currentConfigMessage() { server?.broadcast(message) }
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let ms = UInt32(clamping: Int(CMTimeGetSeconds(pts) * 1000))
        var message = Data([0x01, keyframe ? 1 : 0])
        var be = ms.bigEndian
        withUnsafeBytes(of: &be) { message.append(contentsOf: $0) }
        var length = UInt32(au.count).bigEndian
        withUnsafeBytes(of: &length) { message.append(contentsOf: $0) }
        message.append(au)
        server?.broadcast(message)
    }
}

extension CaptureEngine: SCStreamOutput, SCStreamDelegate {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        captureSample(sampleBuffer)
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("mirror capture stopped: \(error.localizedDescription)")
        stop()
    }
}
