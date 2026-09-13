import SwiftUI

/// The system owns positioning, the glass surface and presentation/dismissal.
/// Keep panel content free of a second glassEffect or custom backdrop.
private struct NativeFloatingPanel<Panel: View>: ViewModifier {
    @Binding var isPresented: Bool
    let preferredWidth: CGFloat
    @ViewBuilder let panel: () -> Panel

    func body(content: Content) -> some View {
        content.popover(isPresented: $isPresented, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
            panel()
                .frame(minWidth: 240, idealWidth: preferredWidth, maxWidth: preferredWidth)
                .presentationCompactAdaptation(.popover)
        }
    }
}

extension View {
    func nativeFloatingPanel<Panel: View>(isPresented: Binding<Bool>, preferredWidth: CGFloat,
                                         @ViewBuilder content: @escaping () -> Panel) -> some View {
        modifier(NativeFloatingPanel(isPresented: isPresented, preferredWidth: preferredWidth, panel: content))
    }
}
