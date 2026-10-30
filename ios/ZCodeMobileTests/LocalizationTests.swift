import XCTest
@testable import ZCodeMobile

final class LocalizationTests: XCTestCase {
    func testSystemLanguageMatchingAndFallback() {
        XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: ["en-US"]), "en")
        XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: ["en-GB"]), "en")
        XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: ["zh-Hans-CN", "en-US"]), "zh-Hans")
        XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: ["ja-JP", "en-US"]), "ja")
        XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: ["fr-FR", "zh-Hans"]), "fr")
        XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: ["ko-KR", "de-DE"]), "ko")
        XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: ["de-CH", "en"]), "de")
        XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: ["fr_CA"]), "fr")
        XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: ["es-MX", "ja"]), "ja")
        XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: ["it", "es"]), "en")
        XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: []), "en")
        XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: ["french", "en"]), "en")
        for language in AppLanguage.allCases where language != .system {
            XCTAssertEqual(language.resolved(preferredLanguages: ["es"]), language.rawValue)
        }
        XCTAssertEqual(AppLanguage.english.resolved(preferredLanguages: ["zh-CN"]), "en")
        XCTAssertEqual(AppLanguage.simplifiedChinese.resolved(preferredLanguages: ["en"]), "zh-Hans")
    }

    func testExplicitChoiceSurvivesRelaunchAndSystemCanBeRestored() throws {
        let name = "localization-tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = LanguageSettings(defaults: defaults)
        XCTAssertEqual(settings.selection, .system)
        for language in AppLanguage.allCases where language != .system {
            settings.selection = language
            XCTAssertEqual(LanguageSettings(defaults: defaults).selection, language)
            XCTAssertEqual(settings.locale.language.languageCode?.identifier, language == .simplifiedChinese ? "zh" : language.rawValue)
        }
        settings.selection = .system
        XCTAssertEqual(LanguageSettings(defaults: defaults).selection, .system)
    }

    func testEveryCatalogIsBundledAndPreservesArguments() throws {
        let en = try table("en", "Localizable")
        XCTAssertGreaterThan(en.count, 750)
        XCTAssertEqual(Set(Bundle.main.localizations), Set(AppLanguage.supportedCodes))
        let placeholder = try NSRegularExpression(pattern: #"\{\d+\}"#)
        func tokens(_ value: String) -> [String] {
            placeholder.matches(in: value, range: NSRange(value.startIndex..., in: value)).map { (value as NSString).substring(with: $0.range) }.sorted()
        }
        for lang in AppLanguage.supportedCodes {
            let catalog = try table(lang, "Localizable")
            XCTAssertEqual(Set(en.keys), Set(catalog.keys), lang)
            for (key, value) in catalog {
                XCTAssertFalse(value.isEmpty, "\(lang): \(key)")
                if !["ja", "zh-Hans"].contains(lang) {
                    XCTAssertNil(value.range(of: #"\p{Han}"#, options: .regularExpression), "\(lang): \(key)")
                }
                XCTAssertEqual(tokens(key), tokens(value), "\(lang): \(key)")
                XCTAssertEqual(L10n.render(key, language: lang), value, "\(lang): \(key)")
            }
            let info = try table(lang, "InfoPlist")
            XCTAssertEqual(Set(info.keys), Set(try table("en", "InfoPlist").keys))
        }
    }

    func testInterpolationsNeverTranslateOrReinterpretUserContent() {
        XCTAssertEqual(L10n.render("在 {0} 上工作", arguments: ["我的电脑 {1} %@"], language: "en"), "Work on 我的电脑 {1} %@")
        XCTAssertEqual(L10n.render("{0}小时{1}分钟{2}秒", arguments: ["1", "2", "3"], language: "en"), "1h 2m 3s")
    }

    func testMarkdownTableCellsNeverLookUpAppTranslations() {
        let original = LanguageSettings.shared.selection
        defer { LanguageSettings.shared.selection = original }
        for language in AppLanguage.allCases where language != .system {
            LanguageSettings.shared.selection = language
            // These cells deliberately coincide with translated application keys.
            XCTAssertEqual(String(MessageTextCache.tableCell("设置").characters), "设置")
            XCTAssertEqual(String(MessageTextCache.tableCell("**任务** {0} %@").characters), "任务 {0} %@")
            XCTAssertEqual(String(MessageTextCache.tableCell("[我的文件](https://example.com)").characters), "我的文件")
        }
    }

    func testLiveObservableSwitchAndToolGrammar() {
        let original = LanguageSettings.shared.selection
        defer { LanguageSettings.shared.selection = original }
        LanguageSettings.shared.selection = .english
        XCTAssertEqual(ConnectionState.connected.label, "Connected")
        XCTAssertEqual(ToolStep(id: "test", title: "WebFetch", detail: "", status: .running).displayTitle, "Fetching")
        XCTAssertEqual(ReasoningLevel.medium.label, "Medium")
        XCTAssertEqual(ReferenceData.project.name, "Demo Workspace")
        LanguageSettings.shared.selection = .simplifiedChinese
        XCTAssertEqual(ConnectionState.connected.label, "已连接")
        XCTAssertEqual(ReferenceData.project.name, "示例工作区")
    }

    @MainActor func testLanguageChangePreservesEditedDemoContentAndDrafts() throws {
        let original = LanguageSettings.shared.selection
        let name = "localization-store-tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer {
            LanguageSettings.shared.selection = original
            defaults.removePersistentDomain(forName: name)
        }
        LanguageSettings.shared.selection = .simplifiedChinese
        let store = AppStore(defaults: defaults)
        store.enterReferenceMode()
        store.sessions[0].title = "用户自己的任务名称"
        store.goals[ReferenceData.conversationID]?.text = "用户自己的目标"
        store.drafts[ReferenceData.conversationID] = "未发送的草稿 {0}"
        store.path = [.session(ReferenceData.conversationID)]
        // Cycle through all languages twice, including switching from a newly added
        // locale. App-owned demo labels update, while user edits and navigation survive.
        for language in Array(AppLanguage.allCases.dropFirst()) + [.japanese, .german, .english] {
            LanguageSettings.shared.selection = language
            store.refreshLocalizedDemo()
            XCTAssertEqual(store.sessions[0].title, "用户自己的任务名称")
            XCTAssertEqual(store.sessions[1].title, L10n.tr("检查任务进度"))
            XCTAssertEqual(store.goals[ReferenceData.conversationID]?.text, "用户自己的目标")
            XCTAssertEqual(store.drafts[ReferenceData.conversationID], "未发送的草稿 {0}")
            XCTAssertEqual(store.path, [.session(ReferenceData.conversationID)])
            XCTAssertEqual(store.hostName, L10n.tr("示例电脑"))
        }
    }

    private func table(_ language: String, _ name: String) throws -> [String: String] {
        let url = try XCTUnwrap(Bundle.main.url(forResource: name, withExtension: "strings", subdirectory: nil, localization: language))
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: String])
    }
}
