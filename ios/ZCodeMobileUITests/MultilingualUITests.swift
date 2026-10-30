import XCTest
import Vision

/// Uses isolated preferences and synthetic demo data; never connects to a real host.
final class MultilingualUITests: XCTestCase {
    private struct Copy {
        let code: String, locale: String, name: String, hero: String, settings: String
        let done: String, system: String, guide: String, workspace: String
    }
    private let languages: [Copy] = [
        Copy(code: "ja", locale: "ja_JP", name: "日本語", hero: "コンピュータのタスクをスマートフォンで続ける", settings: "設定", done: "完了", system: "システムに従う", guide: "ZCode 公式リレーを使う", workspace: "デモワークスペース"),
        Copy(code: "fr", locale: "fr_CA", name: "Français", hero: "Poursuivez vos tâches sur votre téléphone", settings: "Réglages", done: "Terminé", system: "Selon le système", guide: "Utiliser le relais officiel ZCode", workspace: "Espace de démonstration"),
        Copy(code: "ko", locale: "ko_KR", name: "한국어", hero: "휴대폰에서 컴퓨터 작업 이어가기", settings: "설정", done: "완료", system: "시스템 설정 따르기", guide: "ZCode 공식 릴레이 사용", workspace: "데모 작업 공간"),
        Copy(code: "de", locale: "de_CH", name: "Deutsch", hero: "Desktop-Aufgaben am Smartphone fortsetzen", settings: "Einstellungen", done: "Fertig", system: "Wie im System", guide: "Offiziellen ZCode-Relay nutzen", workspace: "Demo-Arbeitsbereich")
    ]
    @MainActor private func launch(_ language: Copy, screen: String? = nil, reset: Bool = true, englishSystem: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--onboarding-review", "--reset-onboarding-review", "--localization-review", "-AppleLanguages", "(\(englishSystem ? "en-US" : language.locale.replacingOccurrences(of: "_", with: "-")))", "-AppleLocale", englishSystem ? "en_US" : language.locale]
        if reset { app.launchArguments.append("--reset-localization-review") }
        if let screen { app.launchArguments += ["--reference", "--screen", screen] }
        app.launch()
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 15))
        return app
    }
    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
    @MainActor private func review(_ language: Copy) {
        var app = launch(language)
        XCTAssertTrue(app.staticTexts[language.hero].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["pairing.scan"].isHittable)
        capture(app, language.code + "-onboarding")
        app.buttons["pairing.settings"].tap()
        XCTAssertTrue(app.navigationBars[language.settings].waitForExistence(timeout: 5))
        capture(app, language.code + "-settings")
        app.buttons["settings.language"].tap()
        for choice in languages { XCTAssertTrue(app.buttons[choice.name].exists, choice.name) }
        capture(app, language.code + "-language-menu")
        app.buttons[language.system].tap()
        app.buttons[language.done].tap()
        app.buttons["pairing.guide"].tap()
        XCTAssertTrue(app.staticTexts[language.guide].waitForExistence(timeout: 5))
        capture(app, language.code + "-official-guide")
        app.swipeUp()
        capture(app, language.code + "-official-guide-details")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["pairing.selfHostedGuide"].tap()
        XCTAssertTrue(app.buttons["pairing.exportKit"].waitForExistence(timeout: 5))
        capture(app, language.code + "-self-hosted-guide")
        app.terminate()
        for screen in ["home", "chat", "permissions", "advanced", "files", "goal", "hooks"] {
            app = launch(language, screen: screen)
            if screen == "home" {
                XCTAssertTrue(app.buttons["home.menu"].waitForExistence(timeout: 5))
                XCTAssertTrue(app.staticTexts[language.workspace].exists)
                app.buttons["home.menu"].tap()
                XCTAssertTrue(app.buttons[language.settings].exists)
                app.buttons[language.settings].tap()
                XCTAssertTrue(app.buttons["settings.language"].waitForExistence(timeout: 5))
                app.buttons[language.done].tap()
            }
            if screen == "permissions" {
                XCTAssertTrue(app.buttons["permission.full"].waitForExistence(timeout: 5))
                if language.code == "de" {
                    let title = app.staticTexts["Benutzerdefiniert (config.toml)"].firstMatch
                    XCTAssertTrue(title.exists)
                    XCTAssertGreaterThan(title.frame.height, 30, "The German permission title must wrap instead of truncating")
                }
            }
            if screen == "chat", language.code == "ko" { assertCompleteKoreanResponse(app) }
            capture(app, language.code + "-" + screen)
            app.terminate()
        }
    }
    @MainActor func testJapaneseSystemAndScreens() { review(languages[0]) }
    @MainActor func testFrenchSystemAndScreens() { review(languages[1]) }
    @MainActor func testKoreanSystemAndScreens() { review(languages[2]) }
    @MainActor func testGermanSystemAndScreens() { review(languages[3]) }

    @MainActor private func assertCompleteKoreanResponse(_ app: XCUIApplication) {
        let response = app.staticTexts["준비가 완료되었습니다. 컴퓨터에 연결하면 작업을 읽고 대화를 이어가며 승인이 필요한 작업을 처리할 수 있습니다."].firstMatch
        XCTAssertTrue(response.waitForExistence(timeout: 5))
        // Accessibility contains the untruncated source even when pixels show an
        // ellipsis. Verify rendered glyphs rather than assuming a line count.
        let request = VNRecognizeTextRequest()
        request.recognitionLanguages = ["ko-KR", "en-US"]
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        do {
            try VNImageRequestHandler(data: app.screenshot().pngRepresentation).perform([request])
            let visible = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                .joined().filter { !$0.isWhitespace }
            XCTAssertTrue(visible.contains("승인이필요한작업을처리할수있습니다."), "The rendered Korean response must include its complete ending: \(visible)")
        } catch { XCTFail("Screenshot text recognition failed: \(error)") }
    }

    @MainActor func testContentLayoutAcrossLanguages() {
        for language in languages {
            for screen in ["chat", "permissions", "advanced", "goal", "hooks"] {
                let app = launch(language, screen: screen)
                if screen == "chat", language.code == "ko" { assertCompleteKoreanResponse(app) }
                if screen == "permissions" {
                    let heading = app.staticTexts["permission.heading"]
                    XCTAssertTrue(heading.waitForExistence(timeout: 5))
                    XCTAssertGreaterThan(heading.frame.height, 30, "The full permission question needs multiple lines")
                    XCTAssertTrue(app.buttons["permission.custom"].isHittable)
                    if language.code == "de" {
                        XCTAssertGreaterThan(app.staticTexts["Benutzerdefiniert (config.toml)"].firstMatch.frame.height, 30)
                    }
                }
                capture(app, language.code + "-" + screen)
                app.terminate()
            }
        }
    }

    @MainActor func testAllOverridesPersistAndCanReturnToSystem() {
        for language in languages {
            var app = launch(language, englishSystem: true)
            app.buttons["pairing.settings"].tap()
            app.buttons["settings.language"].tap()
            app.buttons[language.name].tap()
            XCTAssertTrue(app.navigationBars[language.settings].waitForExistence(timeout: 5))
            app.buttons[language.done].tap()
            XCTAssertTrue(app.staticTexts[language.hero].waitForExistence(timeout: 5))
            app.terminate()
            app = launch(language, reset: false, englishSystem: true)
            XCTAssertTrue(app.staticTexts[language.hero].waitForExistence(timeout: 5))
            app.buttons["pairing.settings"].tap()
            app.buttons["settings.language"].tap()
            app.buttons[language.system].tap()
            XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
            app.buttons["Done"].tap()
            XCTAssertTrue(app.staticTexts["Continue desktop tasks on your phone"].waitForExistence(timeout: 5))
            app.terminate()
        }
    }
}
