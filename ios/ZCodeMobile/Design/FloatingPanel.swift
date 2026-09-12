import SwiftUI

struct FloatingPanelPresentation {
    let anchor: Anchor<CGRect>
    let content: AnyView
    let dismiss: () -> Void
}

struct FloatingPanelPreference: PreferenceKey {
    static var defaultValue: FloatingPanelPresentation? { nil }
    static func reduce(value: inout FloatingPanelPresentation?, nextValue: () -> FloatingPanelPresentation?) {
        if let next = nextValue() { value = next }
    }
}

struct FloatingPanelOverlay: ViewModifier {
    func body(content: Content) -> some View {
        content.overlayPreferenceValue(FloatingPanelPreference.self) { presentation in
            if let presentation {
                GeometryReader { geometry in
                    let rect = geometry[presentation.anchor]
                    ZStack(alignment: .topLeading) {
                        Color.black.opacity(0.001).ignoresSafeArea()
                            .onTapGesture { presentation.dismiss() }
                            .accessibilityLabel("关闭附件面板")
                            .accessibilityAddTraits(.isButton)
                        presentation.content
                            .frame(width: 320, height: 420)
                            .clipShape(RoundedRectangle(cornerRadius: 48))
                            .glassEffect(ZTheme.controlGlass, in: RoundedRectangle(cornerRadius: 48))
                            .offset(x: min(max(rect.minX + 3, 12), geometry.size.width - 332),
                                    y: max(12, rect.maxY - 420))
                            .accessibilityAction(.escape) { presentation.dismiss() }
                    }
                }
            }
        }
    }
}
