import SwiftUI
import UIKit

struct SessionContextAction {
    var title: String
    var symbol: String
    var destructive = false
    var perform: @MainActor () -> Void
}

/// UIKit owns the lift, dimming, menu glass, dismissal and preview commit animation.
struct SessionContextInteraction: UIViewRepresentable {
    var title: String
    var identity: String
    var preview: AnyView
    var actions: [SessionContextAction]
    var open: @MainActor () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let interaction = UIContextMenuInteraction(delegate: context.coordinator)
        context.coordinator.interaction = interaction
        view.addInteraction(interaction)
        view.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped)))
        view.isAccessibilityElement = false
        return view
    }
    func updateUIView(_ view: UIView, context: Context) {
        if context.coordinator.parent.identity != identity { context.coordinator.invalidate() }
        context.coordinator.parent = self
    }
    static func dismantleUIView(_ view: UIView, coordinator: Coordinator) { coordinator.invalidate() }

    final class Coordinator: NSObject, UIContextMenuInteractionDelegate {
        var menuOpen: (@MainActor () -> Void)?
        var liftedRow: UIView?
        weak var interaction: UIContextMenuInteraction?
        var generation = UUID()
        var parent: SessionContextInteraction
        init(parent: SessionContextInteraction) { self.parent = parent }
        func invalidate() {
            generation = UUID()
            menuOpen = nil
            liftedRow = nil
            interaction?.dismissMenu()
        }
        @objc func tapped() { parent.open() }
        func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                    configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
            let current = parent
            let generation = self.generation
            menuOpen = { [weak self] in
                guard self?.generation == generation, self?.parent.identity == current.identity else { return }
                current.open()
            }
            return UIContextMenuConfiguration(identifier: current.identity as NSString, previewProvider: {
                let controller = UIHostingController(rootView: current.preview)
                let width = min(360, (interaction.view?.window?.bounds.width ?? 440) - 48)
                controller.preferredContentSize = CGSize(width: width, height: 520)
                controller.view.backgroundColor = .systemBackground
                return controller
            }, actionProvider: { _ in
                UIMenu(title: current.title, children: current.actions.map { action in
                    UIAction(title: action.title, image: UIImage(systemName: action.symbol),
                             attributes: action.destructive ? .destructive : []) { [weak self] _ in
                        guard self?.generation == generation, self?.parent.identity == current.identity else { return }
                        action.perform()
                    }
                })
            })
        }
        func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                    configuration: UIContextMenuConfiguration,
                                    highlightPreviewForItemWithIdentifier identifier: any NSCopying) -> UITargetedPreview? {
            guard configuration.identifier as? String == parent.identity,
                  let source = interaction.view, let window = source.window else { return nil }
            let rect = source.convert(source.bounds, to: window)
            guard let snapshot = window.resizableSnapshotView(from: rect, afterScreenUpdates: false, withCapInsets: .zero) else { return nil }
            liftedRow = snapshot
            let parameters = UIPreviewParameters()
            parameters.backgroundColor = .clear
            parameters.visiblePath = UIBezierPath(roundedRect: snapshot.bounds, cornerRadius: 12)
            return UITargetedPreview(view: snapshot, parameters: parameters,
                target: UIPreviewTarget(container: window, center: CGPoint(x: rect.midX, y: rect.midY)))
        }
        func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                    configuration: UIContextMenuConfiguration,
                                    dismissalPreviewForItemWithIdentifier identifier: any NSCopying) -> UITargetedPreview? {
            guard configuration.identifier as? String == parent.identity,
                  let source = interaction.view, let window = source.window, let snapshot = liftedRow else { return nil }
            let rect = source.convert(source.bounds, to: window)
            let parameters = UIPreviewParameters()
            parameters.backgroundColor = .clear
            return UITargetedPreview(view: snapshot, parameters: parameters,
                target: UIPreviewTarget(container: window, center: CGPoint(x: rect.midX, y: rect.midY)))
        }
        func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                    willPerformPreviewActionForMenuWith configuration: UIContextMenuConfiguration,
                                    animator: any UIContextMenuInteractionCommitAnimating) {
            let open = menuOpen
            animator.addCompletion { open?() }
        }
    }
}

struct ConversationPreview: View {
    @Environment(AppStore.self) private var store
    var sessionID: String
    @State private var loading = true
    @State private var messages: [ChatMessage] = []
    @State private var failure: String?

    var body: some View {
        Group {
            if loading && messages.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if messages.isEmpty {
                Text(failure ?? "暂无消息").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        ForEach(messages.suffix(12)) { message in
                            MessageView(message: message, sessionID: sessionID)
                        }
                    }.padding(16)
                }
                .defaultScrollAnchor(.bottom)
                .defaultScrollAnchor(.top, for: .alignment)
                .allowsHitTesting(false)
            }
        }
        .background(Color(uiColor: .systemBackground))
        .task(id: sessionID) {
            messages = store.messages(sessionID)
            loading = true
            defer { loading = false }
            do { messages = try await store.previewMessages(sessionID) }
            catch is CancellationError { }
            catch { failure = error.localizedDescription }
        }
    }
}
