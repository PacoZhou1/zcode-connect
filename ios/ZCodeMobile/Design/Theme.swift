import SwiftUI

enum ZTheme {
    static var controlGlass: Glass {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--clear-glass") { return .clear }
        #endif
        return .regular
    }
    static let accent = Color(red: 172.0 / 255, green: 120.0 / 255, blue: 249.0 / 255)
    static let userText = Color(red: 0.50, green: 0.27, blue: 0.89)
    static let userBubble = Color(light: UIColor(red: 0.936, green: 0.897, blue: 0.996, alpha: 1),
                                  dark: UIColor(red: 0.22, green: 0.15, blue: 0.33, alpha: 1))
    static let background = Color(uiColor: .systemBackground)
    static let secondary = Color(uiColor: .secondaryLabel)
    static let listSecondary = Color(light: UIColor(white: 0.42, alpha: 1), dark: UIColor(white: 0.66, alpha: 1))
    static let grouped = Color(uiColor: .secondarySystemGroupedBackground)
    static let separator = Color(uiColor: .separator).opacity(0.5)
    static let pageInset: CGFloat = 16
}

struct NativeGlassButtonStyle: PrimitiveButtonStyle {
    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        Button(configuration).buttonStyle(.glass)
    }
}

extension Color {
    init(light: UIColor, dark: UIColor) {
        self.init(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }
}

struct SymbolButton: View {
    let symbol: String
    let label: String
    var size: CGFloat = 22
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size, weight: .medium))
                .frame(width: 44, height: 44).contentShape(Circle())
        }
        .accessibilityLabel(label)
    }
}

struct GlassSearchField: View {
    @Binding var text: String
    var placeholder: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").font(.system(size: 20))
            TextField(placeholder, text: $text)
                .font(.system(size: 17))
                .submitLabel(.search)
                .autocorrectionDisabled()
                .accessibilityIdentifier("searchField")
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }.accessibilityLabel("清除搜索")
            }
        }
        .padding(.horizontal, 14).frame(height: 48)
        .glassEffect(ZTheme.controlGlass, in: Capsule())
        .measureLayout("search.\(placeholder)")
    }
}

struct StatusDot: View {
    var status: SessionStatus
    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8)
            .accessibilityLabel(status.label)
    }
    private var color: Color {
        switch status {
        case .running: ZTheme.accent
        case .waiting: .orange
        case .failed: .red
        case .completed: .green
        case .idle: .gray
        }
    }
}

struct ChangeCount: View {
    let additions: Int
    let deletions: Int
    var body: some View {
        HStack(spacing: 4) {
            Text("+\(additions)").foregroundStyle(.green)
            Text("−\(deletions)").foregroundStyle(.red)
        }.font(.system(size: 13, design: .monospaced))
    }
}

struct InlineNotice: View {
    var symbol = "info.circle"
    let text: String
    var body: some View {
        Label(text, systemImage: symbol)
            .font(.footnote).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
    }
}
