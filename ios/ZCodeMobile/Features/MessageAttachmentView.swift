import SwiftUI
import ImageIO
import CryptoKit

struct MessageAttachmentView: View {
    let attachment: MessageAttachment
    @State private var preview: UIImage?
    @State private var showPreview = false
    @State private var loadedRequest: AttachmentPreviewRequest?
    @State private var previewGeneration = UUID()

    private var previewRequest: AttachmentPreviewRequest {
        AttachmentPreviewRequest(id: attachment.id, mimeType: attachment.mimeType, url: attachment.previewURL)
    }

    var body: some View {
        let request = previewRequest
        Group {
            if let preview, loadedRequest == request {
                Button { showPreview = true } label: {
                    Image(uiImage: preview).resizable().scaledToFit()
                        .frame(maxWidth: 250, maxHeight: 200)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }.buttonStyle(.plain).accessibilityLabel("查看图片附件，\(displayName)")
            } else {
                Label(displayName, systemImage: attachment.mimeType.hasPrefix("image/") ? "photo" : "doc")
                    .font(.subheadline).lineLimit(2)
                    .padding(10).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel("附件，\(displayName)")
            }
        }
        .task(id: request) {
            guard loadedRequest != request else { return }
            let generation = UUID()
            previewGeneration = generation
            preview = nil
            loadedRequest = nil
            showPreview = false
            let image = await AttachmentPreviewCache.shared.image(for: request)
            guard !Task.isCancelled, previewGeneration == generation else { return }
            preview = image.map { UIImage(cgImage: $0) }
            loadedRequest = request
        }
        .onDisappear { previewGeneration = UUID() }
        .sheet(isPresented: $showPreview) {
            if let preview, loadedRequest == request { AttachmentImagePreview(image: preview, title: displayName) }
        }
    }

    private var displayName: String {
        attachment.fileName == "Attachment" ? (attachment.mimeType.hasPrefix("image/") ? "图片" : "附件") : attachment.fileName
    }

}

private struct AttachmentPreviewRequest: Equatable, Sendable {
    let id: String
    let mimeType: String
    let url: String?
}

/// ImageIO and Base64 work run on this actor, never on the SwiftUI main actor.
/// Cache keys are digests so cached thumbnails do not retain the large data URLs.
private actor AttachmentPreviewCache {
    static let shared = AttachmentPreviewCache()
    private struct Entry {
        let image: CGImage
        let cost: Int
    }
    private let entryLimit: Int
    private let byteLimit: Int
    private var entries: [SHA256.Digest: Entry] = [:]
    private var recency: [SHA256.Digest] = []
    private var retainedBytes = 0

    init(entryLimit: Int = 24, byteLimit: Int = 48 * 1024 * 1024) {
        self.entryLimit = max(0, entryLimit)
        self.byteLimit = max(0, byteLimit)
    }

    func image(for request: AttachmentPreviewRequest) -> CGImage? {
        guard !Task.isCancelled, request.mimeType.hasPrefix("image/"), let raw = request.url,
              raw.utf8.count <= 12 * 1024 * 1024,
              raw.hasPrefix("data:image/"), let comma = raw.firstIndex(of: ","),
              raw[..<comma].hasSuffix(";base64") else { return nil }
        let key = SHA256.hash(data: Data(raw.utf8))
        if let entry = entries[key] {
            recency.removeAll { $0 == key }
            recency.append(key)
            return entry.image
        }
        guard !Task.isCancelled,
              let image = Self.decode(raw, comma: comma), !Task.isCancelled else { return nil }
        let cost = image.bytesPerRow * image.height
        guard entryLimit > 0, cost <= byteLimit else { return image }
        while entries.count >= entryLimit || retainedBytes + cost > byteLimit {
            guard let oldest = recency.first else { break }
            recency.removeFirst()
            if let removed = entries.removeValue(forKey: oldest) { retainedBytes -= removed.cost }
        }
        entries[key] = Entry(image: image, cost: cost)
        recency.append(key)
        retainedBytes += cost
        return image
    }

    private static func decode(_ raw: String, comma: String.Index) -> CGImage? {
        autoreleasepool {
            guard let data = Data(base64Encoded: String(raw[raw.index(after: comma)...])),
              data.count <= 8 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 1600,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
            return image
        }
    }
}

private struct AttachmentImagePreview: View {
    let image: UIImage
    let title: String
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ZoomableAttachmentImage(image: image)
                .background(Color(uiColor: .systemBackground))
                .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}

private struct ZoomableAttachmentImage: UIViewRepresentable {
    let image: UIImage
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 5
        scroll.delegate = context.coordinator
        let view = context.coordinator.imageView
        view.image = image
        view.contentMode = .scaleAspectFit
        view.isAccessibilityElement = true
        view.accessibilityLabel = "图片预览，可双指缩放"
        scroll.addSubview(view)
        return scroll
    }
    func updateUIView(_ scroll: UIScrollView, context: Context) {
        context.coordinator.imageView.image = image
        context.coordinator.imageView.frame = scroll.bounds
        context.coordinator.imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scroll.contentSize = scroll.bounds.size
    }
    final class Coordinator: NSObject, UIScrollViewDelegate {
        let imageView = UIImageView()
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
    }
}
