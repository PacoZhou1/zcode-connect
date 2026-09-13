import SwiftUI

enum FloatingPanelPlacement { case above, sourceLeading }

private struct FloatingPanelRequest: Identifiable {
    let id: UUID
    let anchor: Anchor<CGRect>
    let isPresented: Bool
    let width: CGFloat
    let cornerRadius: CGFloat
    let placement: FloatingPanelPlacement
    let content: AnyView
    let setPresented: (Bool) -> Void
    let onDismiss: () -> Void
}

private struct FloatingPanelPreference: PreferenceKey {
    static var defaultValue: [FloatingPanelRequest] { [] }
    static func reduce(value: inout [FloatingPanelRequest], nextValue: () -> [FloatingPanelRequest]) {
        value.append(contentsOf: nextValue())
    }
}

private struct NativeFloatingPanel<Panel: View>: ViewModifier {
    @Binding var isPresented: Bool
    @State private var id = UUID()
    let preferredWidth: CGFloat
    let cornerRadius: CGFloat
    let placement: FloatingPanelPlacement
    let onDismiss: () -> Void
    @ViewBuilder let panel: () -> Panel

    func body(content: Content) -> some View {
        // Retain the closed request until its host finishes the exit animation.
        content.anchorPreference(key: FloatingPanelPreference.self, value: .bounds) { anchor in
            [FloatingPanelRequest(id: id, anchor: anchor, isPresented: isPresented,
                                  width: preferredWidth, cornerRadius: cornerRadius,
                                  placement: placement, content: AnyView(panel()),
                                  setPresented: { isPresented = $0 }, onDismiss: onDismiss)]
        }
    }
}

/// One native glass surface over live content, without a popover arrow.
struct FloatingPanelOverlay: ViewModifier {
    func body(content: Content) -> some View {
        content.overlayPreferenceValue(FloatingPanelPreference.self) { requests in
            GeometryReader { geometry in
                ForEach(requests) { request in
                    FloatingPanelPresentation(request: request, source: geometry[request.anchor],
                                              container: geometry.size)
                }
            }.ignoresSafeArea()
        }
    }
}

private struct FloatingPanelPresentation: View {
    let request: FloatingPanelRequest
    let source: CGRect
    let container: CGSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Namespace private var glassNamespace
    @State private var mounted = false
    @State private var progress = 0.0
    @State private var height: CGFloat = 0
    @State private var generation = UUID()
    @State private var revealTask: Task<Void, Never>?

    private var width: CGFloat { min(request.width, max(1, container.width - 24)) }
    private var target: CGRect {
        let panelHeight = min(max(1, height), max(1, container.height - 32))
        let left: CGFloat
        let bottom: CGFloat
        switch request.placement {
        case .sourceLeading:
            left = min(max(12, source.minX - 10), max(12, container.width - width - 12))
            bottom = min(container.height - 8, source.maxY + 5)
        case .above:
            left = (container.width - width) / 2
            bottom = source.minY - 12
        }
        return CGRect(x: left, y: max(16, bottom - panelHeight), width: width, height: panelHeight)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if mounted {
                Color.clear.contentShape(Rectangle())
                    .onTapGesture { request.setPresented(false) }
                    .accessibilityHidden(true)
                GlassEffectContainer(spacing: 0) {
                    request.content.frame(width: width).fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { value in
                            guard value > 0, height != value else { return }
                            height = value
                            if request.isPresented, progress == 0 { reveal() }
                        }
                        .modifier(FloatingPanelMorph(progress: reduceMotion ? 1 : progress,
                                                     source: source, target: target,
                                                     cornerRadius: request.cornerRadius,
                                                     glass: reduceTransparency ? .regular : ZTheme.controlGlass,
                                                     id: request.id, namespace: glassNamespace))
                        .opacity(height > 0 ? (reduceMotion ? progress : 1) : 0)
                        .allowsHitTesting(request.isPresented && progress >= 1)
                        .accessibilityAddTraits(.isModal)
                        .accessibilityAction(.escape) { request.setPresented(false) }
                }
            }
        }
        .onChange(of: request.isPresented, initial: true) { _, visible in
            generation = UUID()
            revealTask?.cancel()
            if visible {
                mounted = true
                if height > 0 { reveal() }
            } else if mounted {
                let closingGeneration = generation
                withAnimation(reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.3, dampingFraction: 0.9),
                              completionCriteria: .removed) {
                    progress = 0
                } completion: {
                    guard generation == closingGeneration else { return }
                    mounted = false
                    request.onDismiss()
                }
            }
        }
        .onDisappear { generation = UUID(); revealTask?.cancel() }
    }

    private func reveal() {
        revealTask?.cancel()
        let openingGeneration = generation
        revealTask = Task { @MainActor in
            // Commit the source-sized surface before changing its geometry.
            // This yields scheduling; it does not impose a fixed delay.
            await Task.yield()
            guard !Task.isCancelled, generation == openingGeneration, request.isPresented else { return }
            withAnimation(reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.36, dampingFraction: 0.86)) {
                progress = 1
            }
        }
    }
}

/// Animate the glass frame and corner radius, not only its opacity.
private struct FloatingPanelMorph: ViewModifier, @MainActor Animatable {
    var progress: Double
    let source: CGRect
    let target: CGRect
    let cornerRadius: CGFloat
    let glass: Glass
    let id: UUID
    let namespace: Namespace.ID
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let p = CGFloat(max(0, min(1.05, progress)))
        let currentWidth = max(1, source.width + (target.width - source.width) * p)
        let currentHeight = max(1, source.height + (target.height - source.height) * p)
        let sourceRadius = min(source.width, source.height) / 2
        let radius = min(min(currentWidth, currentHeight) / 2, sourceRadius + (cornerRadius - sourceRadius) * p)
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .scaleEffect(x: currentWidth / target.width, y: currentHeight / target.height, anchor: .topLeading)
            .frame(width: currentWidth, height: currentHeight, alignment: .topLeading)
            .opacity(max(0, min(1, progress * 1.6 - 0.15)))
            .clipShape(shape)
            .glassEffect(glass, in: shape)
            .glassEffectID(id, in: namespace)
            .glassEffectTransition(.identity)
            .position(x: source.midX + (target.midX - source.midX) * p,
                      y: source.midY + (target.midY - source.midY) * p)
    }
}

extension View {
    func nativeFloatingPanel<Panel: View>(isPresented: Binding<Bool>, preferredWidth: CGFloat,
                                         cornerRadius: CGFloat = 17,
                                         placement: FloatingPanelPlacement = .above,
                                         onDismiss: @escaping () -> Void = {},
                                         @ViewBuilder content: @escaping () -> Panel) -> some View {
        modifier(NativeFloatingPanel(isPresented: isPresented, preferredWidth: preferredWidth,
                                     cornerRadius: cornerRadius, placement: placement,
                                     onDismiss: onDismiss, panel: content))
    }
}
