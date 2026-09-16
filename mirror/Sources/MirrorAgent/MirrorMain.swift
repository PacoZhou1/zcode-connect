import AppKit
import Foundation
import CoreGraphics
import CoreMedia
import CoreVideo
import ImageIO
import UniformTypeIdentifiers
import ScreenCaptureKit
import VideoToolbox

struct MirrorError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

let usage = """
MirrorAgent — 把 Mac 上的 iOS 模拟器画面镜像给 ZCodeMobile。
用法:
  MirrorAgent                    启动镜像服务 (默认)
  MirrorAgent --info             打印配置与连接信息 (JSON)
  MirrorAgent --list             列出模拟器窗口 (JSON)
  MirrorAgent --probe-shot <窗口ID> [输出.png]   抓一帧原始画面用于裁剪校准
  MirrorAgent --set-crop <pt>    调整标题栏裁剪高度并保存
"""

@main
struct MirrorMain {
    static func main() async {
        let arguments = CommandLine.arguments
        let config: MirrorConfig
        do { config = try MirrorConfig.load() } catch {
            NSLog("mirror config error: \(error.localizedDescription)")
            exit(1)
        }
        // Window-server clients need a CGS/NSApp context or CoreGraphics asserts.
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        if arguments.contains("--info") {
            let payload: [String: Any] = [
                "port": Int(config.port), "token": config.token,
                "crop": config.captureTopCrop, "width": config.width, "height": config.height,
                "fps": config.fps, "bitrate": config.bitrate,
            ]
            printJSON(payload)
            return
        }
        if arguments.contains("--set-crop"), let index = arguments.firstIndex(of: "--set-crop"), arguments.indices.contains(index + 1),
           let crop = Double(arguments[index + 1]), crop >= 0, crop < 200 {
            var updated = config
            updated.captureTopCrop = crop
            try? updated.save()
            printJSON(["ok": true, "crop": updated.captureTopCrop])
            return
        }

        let engine = CaptureEngine()
        if arguments.contains("--list") {
            do { printJSON(["windows": try await engine.listSimulatorWindows().map { ["windowID": $0.windowID, "title": $0.title, "width": $0.widthPoints, "height": $0.heightPoints] }]) }
            catch { printJSON(["error": error.localizedDescription]) }
            return
        }
        if let index = arguments.firstIndex(of: "--probe-shot"), arguments.indices.contains(index + 1),
           let windowID = UInt32(arguments[index + 1]) {
            let output = arguments.indices.contains(index + 2) ? arguments[index + 2] : "/tmp/mirror-probe.png"
            do { try await probeShot(windowID: windowID, output: output, config: config) ; printJSON(["ok": true, "output": output]) }
            catch { printJSON(["error": error.localizedDescription]) }
            return
        }

        let server = MirrorServer(config: config)
        engine.server = server
        do { try server.start() } catch {
            NSLog("mirror listener failed: \(error.localizedDescription)")
            exit(1)
        }
        printJSON(["event": "listening", "port": Int(config.port)])
        dispatchMain()
    }

    /// One raw frame, un-cropped and unscaled, written as PNG for calibration.
    static func probeShot(windowID: UInt32, output: String, config: MirrorConfig) async throws {
        NSLog("probe: content start")
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        NSLog("probe: content ok \(content.windows.count)")
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw MirrorError("窗口不存在。")
        }
        CaptureEngine.raiseWindow(windowID: windowID, title: window.title ?? "")
        if let simulator = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.iphonesimulator").first {
            simulator.activate()
        }
        try await Task.sleep(for: .milliseconds(300))
        var streamConfig = SCStreamConfiguration()
        streamConfig.sourceRect = CGRect(x: 0, y: 0, width: window.frame.width, height: window.frame.height)
        streamConfig.width = Int(window.frame.width) * 2
        streamConfig.height = Int(window.frame.height) * 2
        streamConfig.scalesToFit = true
        streamConfig.showsCursor = true
        let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: window), configuration: streamConfig, delegate: nil)
        let box = FrameBox()
        NSLog("probe: stream created")
        try stream.addStreamOutput(box, type: .screen, sampleHandlerQueue: DispatchQueue(label: "mirror.probe"))
        NSLog("probe: output added")
        try await stream.startCapture()
        NSLog("probe: capture started")
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(50))
            if let image = box.image { break }
        }
        try await stream.stopCapture()
        NSLog("probe: stopped, image \(box.image == nil ? "nil" : "ok")")
        guard let image = box.image else { throw MirrorError("没有抓到帧。") }
        NSLog("probe: writing png")
        let destination = try? CGImageDestinationCreateWithURL(URL(fileURLWithPath: output) as CFURL, UTType.png.identifier as CFString, 1, nil)
        guard let destination else { throw MirrorError("PNG 目标创建失败。") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw MirrorError("PNG 写入失败。") }
    }
}

final class FrameBox: NSObject, SCStreamOutput, @unchecked Sendable {
    var image: CGImage?
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        image = makeImage(pixelBuffer)
    }
    private func makeImage(_ pixelBuffer: CVPixelBuffer) -> CGImage? {
        var image: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &image)
        return image
    }
}

func printJSON(_ payload: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
       let text = String(data: data, encoding: .utf8) { print(text) }
}
