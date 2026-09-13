import SwiftUI
import Observation

enum AccentTheme: String, CaseIterable, Identifiable {
    case violet, blue, teal, green, orange, rose
    var id: String { rawValue }
    var label: String {
        switch self {
        case .violet: "紫色"
        case .blue: "蓝色"
        case .teal: "青色"
        case .green: "绿色"
        case .orange: "橙色"
        case .rose: "玫瑰色"
        }
    }
    var rgb: (Double, Double, Double) {
        switch self {
        case .violet: (172, 120, 249)
        case .blue: (66, 139, 245)
        case .teal: (35, 155, 163)
        case .green: (65, 157, 95)
        case .orange: (223, 134, 48)
        case .rose: (219, 100, 151)
        }
    }
    var color: Color { Color(red: rgb.0 / 255, green: rgb.1 / 255, blue: rgb.2 / 255) }
}

@MainActor @Observable final class ThemePreferences {
    static let shared = ThemePreferences()
    var selection: AccentTheme {
        didSet { UserDefaults.standard.set(selection.rawValue, forKey: "accentTheme") }
    }
    private init() {
        selection = AccentTheme(rawValue: UserDefaults.standard.string(forKey: "accentTheme") ?? "") ?? .violet
    }
}

@MainActor enum ZTheme {
    static var controlGlass: Glass {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--clear-tinted-glass") { return .clear.tint(.white.opacity(0.6)) }
        if ProcessInfo.processInfo.arguments.contains("--clear-glass") { return .clear }
        #endif
        return .regular
    }
    static var accent: Color { ThemePreferences.shared.selection.color }
    static let agentColors = [(42.0, 132.0, 79.0), (140.0, 83.0, 209.0), (46.0, 106.0, 219.0), (219.0, 61.0, 79.0)]
        .map { Color(red: $0.0 / 255, green: $0.1 / 255, blue: $0.2 / 255) }
    static var userText: Color {
        if ThemePreferences.shared.selection == .violet { return Color(red: 0.50, green: 0.27, blue: 0.89) }
        let rgb = ThemePreferences.shared.selection.rgb
        return Color(light: UIColor(red: rgb.0 / 340, green: rgb.1 / 340, blue: rgb.2 / 340, alpha: 1),
                     dark: UIColor(red: 0.4 + rgb.0 / 425, green: 0.4 + rgb.1 / 425, blue: 0.4 + rgb.2 / 425, alpha: 1))
    }
    static var userBubble: Color {
        if ThemePreferences.shared.selection == .violet {
            return Color(light: UIColor(red: 0.936, green: 0.897, blue: 0.996, alpha: 1),
                         dark: UIColor(red: 0.22, green: 0.15, blue: 0.33, alpha: 1))
        }
        let rgb = ThemePreferences.shared.selection.rgb
        return Color(light: UIColor(red: 0.88 + rgb.0 / 2125, green: 0.88 + rgb.1 / 2125, blue: 0.88 + rgb.2 / 2125, alpha: 1),
                     dark: UIColor(red: 0.06 + rgb.0 / 850, green: 0.06 + rgb.1 / 850, blue: 0.06 + rgb.2 / 850, alpha: 1))
    }
    static let background = Color(uiColor: .systemBackground)
    static let secondary = Color(uiColor: .secondaryLabel)
    static let listSecondary = Color(light: UIColor(white: 0.42, alpha: 1), dark: UIColor(white: 0.66, alpha: 1))
    static let searchPlaceholder = Color(light: UIColor(white: 151.0 / 255, alpha: 1), dark: UIColor(white: 0.66, alpha: 1))
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
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 17))
            TextField(placeholder, text: $text, prompt: Text(placeholder).foregroundStyle(ZTheme.searchPlaceholder))
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
        .padding(.horizontal, 12).frame(height: 48)
        .glassEffect(ZTheme.controlGlass, in: Capsule())
        .measureLayout("search.\(placeholder)")
    }
}

struct StatusDot: View {
    var status: SessionStatus
    var body: some View {
        Group {
            if status == .running {
                ProgressView().controlSize(.mini).tint(ZTheme.accent)
                    .frame(width: 12, height: 12)
            } else {
                Circle().fill(color).frame(width: 7, height: 7)
            }
        }.accessibilityElement(children: .ignore).accessibilityLabel(status.label)
    }
    private var color: Color {
        switch status {
        case .running: ZTheme.accent
        case .waiting: .orange
        case .failed: .red
        case .completed: ZTheme.accent
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
