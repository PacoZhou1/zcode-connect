import SwiftUI
import ImageIO

struct MessageAttachmentView: View {
    let attachment: MessageAttachment
    @State private var preview: UIImage?
    @State private var showPreview = false

    var body: some View {
        Group {
            if let preview {
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
        .task(id: attachment.previewURL) { preview = decodePreview() }
        .sheet(isPresented: $showPreview) {
            if let preview { AttachmentImagePreview(image: preview, title: displayName) }
        }
    }

    private var displayName: String {
        attachment.fileName == "Attachment" ? (attachment.mimeType.hasPrefix("image/") ? "图片" : "附件") : attachment.fileName
    }

    private func decodePreview() -> UIImage? {
        guard attachment.mimeType.hasPrefix("image/"), let raw = attachment.previewURL,
              raw.utf8.count <= 12 * 1024 * 1024,
              raw.hasPrefix("data:image/"), let comma = raw.firstIndex(of: ","),
              raw[..<comma].hasSuffix(";base64"),
              let data = Data(base64Encoded: String(raw[raw.index(after: comma)...])),
              data.count <= 8 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 1600,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
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
