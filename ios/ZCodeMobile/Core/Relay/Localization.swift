import Foundation
import Observation

/// Stored identifiers remain stable as more languages are added.
enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system, english = "en", simplifiedChinese = "zh-Hans"
    case japanese = "ja", french = "fr", korean = "ko", german = "de"
    static let supportedCodes = allCases.filter { $0 != .system }.map(\.rawValue)
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: L10n.tr("跟随系统")
        case .english: "English"
        case .simplifiedChinese: "简体中文"
        case .japanese: "日本語"
        case .french: "Français"
        case .korean: "한국어"
        case .german: "Deutsch"
        }
    }

    func resolved(preferredLanguages: [String] = Locale.preferredLanguages) -> String {
        guard self == .system else { return rawValue }
        for language in preferredLanguages {
            let code = language.lowercased().replacingOccurrences(of: "_", with: "-")
            if code == "zh" || code.hasPrefix("zh-") { return "zh-Hans" }
            if let supported = Self.supportedCodes.first(where: { code == $0 || code.hasPrefix($0 + "-") }) {
                return supported
            }
        }
        return "en"
    }
}

/// UI reads are observable; transport errors can also resolve copy off the main actor.
/// The lock protects all preference storage shared with those background callers.
@Observable
final class LanguageSettings: @unchecked Sendable {
    static let shared: LanguageSettings = {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--localization-review"),
           let defaults = UserDefaults(suiteName: "dev.paco.zcode.mobile.localization-review") {
            if ProcessInfo.processInfo.arguments.contains("--reset-localization-review") {
                defaults.removePersistentDomain(forName: "dev.paco.zcode.mobile.localization-review")
            }
            return LanguageSettings(defaults: defaults)
        }
        #endif
        return LanguageSettings()
    }()
    @ObservationIgnored private let lock = NSLock()
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var storedSelection: AppLanguage
    @ObservationIgnored private var systemLanguages: [String]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        storedSelection = AppLanguage(rawValue: defaults.string(forKey: "appLanguage") ?? "") ?? .system
        systemLanguages = Locale.preferredLanguages
    }

    var selection: AppLanguage {
        get {
            access(keyPath: \.selection)
            return lock.withLock { storedSelection }
        }
        set {
            withMutation(keyPath: \.selection) {
                lock.withLock {
                    storedSelection = newValue
                    defaults.set(newValue.rawValue, forKey: "appLanguage")
                }
            }
        }
    }

    var resolvedLanguage: String {
        selection.resolved(preferredLanguages: lock.withLock { systemLanguages })
    }
    var locale: Locale { Locale(identifier: resolvedLanguage) }

    func refreshSystemLanguages() {
        withMutation(keyPath: \.selection) {
            lock.withLock { systemLanguages = Locale.preferredLanguages }
        }
    }
}

enum L10n {
    private static let bundles: [String: Bundle] = Dictionary(uniqueKeysWithValues: AppLanguage.supportedCodes.compactMap { language in
        Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)).map { (language, $0) }
    })
    private static let placeholder = try! NSRegularExpression(pattern: #"\{(\d+)\}"#)
    static var locale: Locale { LanguageSettings.shared.locale }

    /// Positional placeholders allow translators to reorder arguments. Values are
    /// inserted in one pass so a user's literal "{0}" is never interpreted again.
    static func tr(_ key: String, _ arguments: String...) -> String {
        render(key, arguments: arguments, language: LanguageSettings.shared.resolvedLanguage)
    }

    static func render(_ key: String, arguments: [String] = [], language: String,
                       bundle: Bundle = .main) -> String {
        let localizedBundle = bundle == .main ? bundles[language] : bundle.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:))
        let format = localizedBundle?.localizedString(forKey: key, value: key, table: "Localizable") ?? key
        guard !arguments.isEmpty else { return format }
        let source = format as NSString
        var output = "", cursor = 0
        for match in placeholder.matches(in: format, range: NSRange(location: 0, length: source.length)) {
            output += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let index = Int(source.substring(with: match.range(at: 1)))!
            output += arguments.indices.contains(index) ? arguments[index] : source.substring(with: match.range)
            cursor = NSMaxRange(match.range)
        }
        return output + source.substring(from: cursor)
    }
}
