import Foundation
import CoreGraphics
import ImageIO
import CryptoKit

private extension AttachmentPreviewCache {
    func evidence(for request: AttachmentPreviewRequest) -> (CGImage?, Bool) {
        let result = image(for: request)
        return (result, Thread.isMainThread)
    }
    func metrics() -> [Int] { [entries.count, retainedBytes] }
}

@main private struct AttachmentPreviewCacheTests {
    struct Failure: Error { let message: String }
    @MainActor static var results: [[String: String]] = []
    @MainActor static var assertions = 0
    @MainActor static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        assertions += 1
        if !condition() { throw Failure(message: message) }
    }
    @MainActor static func run(_ name: String, _ body: () async throws -> Void) async {
        do { try await body(); results.append(["name": name, "status": "PASS"]); print("PASS \(name)") }
        catch { let detail = (error as? Failure)?.message ?? String(describing: error); results.append(["name": name, "status": "FAIL", "detail": detail]); print("FAIL \(name): \(detail)") }
    }
    static func request(_ color: CGFloat, width: Int = 64, height: Int = 64) throws -> AttachmentPreviewRequest {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: color, green: 0.3, blue: 1 - color, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure(message: "Cannot encode synthetic PNG") }
        return AttachmentPreviewRequest(id: UUID().uuidString, mimeType: "image/png", url: "data:image/png;base64," + (output as Data).base64EncodedString())
    }
    @MainActor static func main() async throws {
        await run("real ImageIO decode runs off main thread and preserves 1600px aspect ratio") {
            let cache = AttachmentPreviewCache()
            let (image, onMain) = await cache.evidence(for: try request(0.1, width: 2000, height: 1000))
            try check(!onMain, "ImageIO worker ran on main thread")
            try check(image?.width == 1600 && image?.height == 800, "Existing thumbnail size or aspect ratio changed")
        }
        await run("same data URL reuses decoded image across attachment identities") {
            let cache = AttachmentPreviewCache(); let a = try request(0.2)
            let b = AttachmentPreviewRequest(id: "different-ID", mimeType: a.mimeType, url: a.url)
            let first = await cache.image(for: a); let second = await cache.image(for: b)
            try check(first != nil && first === second, "Cache decoded the same payload again")
            let metrics = await cache.metrics()
            try check(metrics[0] == 1, "Same payload created duplicate entries")
        }
        await run("entry limit evicts the least recently used image") {
            let cache = AttachmentPreviewCache(entryLimit: 2)
            let a = try request(0.1), b = try request(0.5), c = try request(0.9)
            let firstA = await cache.image(for: a); let firstB = await cache.image(for: b)
            _ = await cache.image(for: a); _ = await cache.image(for: c)
            let recentA = await cache.image(for: a); let secondB = await cache.image(for: b)
            try check(firstA === recentA, "Recently used image was evicted")
            try check(firstB !== secondB, "Least-recent image was not evicted")
            let metrics = await cache.metrics()
            try check(metrics[0] == 2, "Entry cap was exceeded")
        }
        await run("decoded byte budget is enforced and oversized entries are returned uncached") {
            let small = AttachmentPreviewCache(byteLimit: 1)
            let image = await small.image(for: try request(0.4))
            let empty = await small.metrics()
            try check(image != nil && empty == [0, 0], "Oversized entry was retained or lost")
            let cache = AttachmentPreviewCache(byteLimit: 20_000)
            _ = await cache.image(for: try request(0.2)); _ = await cache.image(for: try request(0.8))
            let metrics = await cache.metrics()
            try check(metrics[0] == 1 && metrics[1] <= 20_000, "Decoded byte cap was exceeded")
        }
        await run("invalid non-image remote and oversized input remain rejected") {
            let cache = AttachmentPreviewCache()
            let inputs = [
                AttachmentPreviewRequest(id: "1", mimeType: "text/plain", url: try request(0.2).url),
                AttachmentPreviewRequest(id: "2", mimeType: "image/png", url: "https://example.invalid/image.png"),
                AttachmentPreviewRequest(id: "3", mimeType: "image/png", url: "data:image/png;base64,not-base64"),
                AttachmentPreviewRequest(id: "4", mimeType: "image/png", url: "data:image/png;base64," + String(repeating: "A", count: 12 * 1024 * 1024))
            ]
            for input in inputs { let image = await cache.image(for: input); try check(image == nil, "Unsupported input was accepted") }
            let metrics = await cache.metrics(); try check(metrics == [0, 0], "Rejected payload was retained")
        }
        await run("cancelled view task does not decode or populate the cache") {
            let cache = AttachmentPreviewCache(); let input = try request(0.6)
            let task = Task { await cache.image(for: input) }
            task.cancel()
            let image = await task.value; let metrics = await cache.metrics()
            try check(image == nil && metrics == [0, 0], "Cancelled work returned or retained an image")
        }
        let passed = results.filter { $0["status"] == "PASS" }.count
        let report: [String: Any] = ["cases": results.count, "passed": passed, "failed": results.count - passed, "assertions": assertions, "results": results]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        print("\(passed)/\(results.count) passed; \(assertions) assertions; synthetic local images only")
        if passed != results.count { exit(1) }
    }
}
