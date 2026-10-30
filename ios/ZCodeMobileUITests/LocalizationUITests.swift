import XCTest

final class LocalizationUITests: XCTestCase {
    @MainActor private func launch(system: String = "en", resetLanguage: Bool = true, screen: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--onboarding-review", "--reset-onboarding-review", "--localization-review", "-AppleLanguages", "(\(system))", "-AppleLocale", ["en": "en_US", "zh-Hans": "zh_CN", "ja": "ja_JP", "fr": "fr_FR", "ko": "ko_KR", "de": "de_DE"][system] ?? system]
        if resetLanguage { app.launchArguments.append("--reset-localization-review") }
        if let screen { app.launchArguments += ["--reference", "--screen", screen] }
        app.launch()
        return app
    }
    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
    @MainActor private func assertNoChinese(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let labels = app.descendants(matching: .any).allElementsBoundByAccessibilityElement
            .filter { $0.isHittable }.map(\.label)
        for label in labels where label != "简体中文" {
            // iOS-owned scroll indicator announcements follow the system language,
            // independently of the app interface override. Do not mask app-owned copy.
            if label.range(of: #"^(垂直|水平)滚动条, \d+页$"#, options: .regularExpression) != nil { continue }
            XCTAssertNil(label.range(of: #"\p{Han}"#, options: .regularExpression), "Untranslated visible label: \(label)", file: file, line: line)
        }
    }
    @MainActor func testEnglishOnboardingGuidesAndError() {
        let app = launch()
        XCTAssertTrue(app.buttons["pairing.scan"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Continue desktop tasks on your phone"].exists)
        assertNoChinese(app); capture(app, "en-onboarding")
        app.buttons["pairing.guide"].tap()
        XCTAssertTrue(app.staticTexts["Use the Official ZCode Relay"].waitForExistence(timeout: 5))
        assertNoChinese(app); capture(app, "en-official-guide")
        app.swipeUp(); assertNoChinese(app); capture(app, "en-official-guide-details")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["pairing.showPaste"].tap()
        let field = app.textFields["pairing.address"].exists ? app.textFields["pairing.address"] : app.textViews["pairing.address"]
        field.tap(); field.typeText("https://example.invalid")
        app.buttons["pairing.recognize"].tap()
        XCTAssertTrue(app.staticTexts["pairing.failure"].waitForExistence(timeout: 5))
        assertNoChinese(app); capture(app, "en-invalid-link")
    }
    @MainActor func testOverrideOnChineseSystemPersistsAndReturnsToSystem() {
        var app = launch(system: "zh-Hans")
        XCTAssertTrue(app.buttons["pairing.settings"].waitForExistence(timeout: 15))
        app.buttons["pairing.settings"].tap()
        app.buttons["settings.language"].tap()
        app.buttons["English"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Appearance"].exists)
        assertNoChinese(app); capture(app, "en-settings-on-chinese-system")
        app.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts["Continue desktop tasks on your phone"].waitForExistence(timeout: 5))
        app.terminate()
        app = launch(system: "zh-Hans", resetLanguage: false)
        XCTAssertTrue(app.staticTexts["Continue desktop tasks on your phone"].waitForExistence(timeout: 15))
        app.buttons["pairing.settings"].tap()
        app.buttons["settings.language"].tap()
        app.buttons["Follow System"].tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5))
        app.buttons["完成"].tap()
        XCTAssertTrue(app.staticTexts["在手机上继续电脑任务"].waitForExistence(timeout: 5))
        capture(app, "zh-restored-system-language")
    }
    @MainActor func testHomeMenuAndEnglishScreens() {
        let app = launch(screen: "home")
        XCTAssertTrue(app.buttons["home.menu"].waitForExistence(timeout: 15))
        assertNoChinese(app); capture(app, "en-home")
        app.buttons["home.menu"].tap()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 5))
        assertNoChinese(app); capture(app, "en-home-menu")
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.buttons["settings.language"].waitForExistence(timeout: 5))
        assertNoChinese(app); capture(app, "en-settings")
        app.buttons["settings.theme"].tap()
        XCTAssertTrue(app.navigationBars["Accent Color"].waitForExistence(timeout: 5))
        assertNoChinese(app); capture(app, "en-theme")
    }
    @MainActor func testEnglishFeatureScreensHaveNoChineseChrome() {
        for screen in ["chat", "advanced", "files", "permissions", "goal", "agents", "new", "hooks", "activity-review"] {
            let app = launch(screen: screen)
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
            // Wait for the synthetic task/navigation to finish presenting.
            let ready = app.navigationBars.firstMatch
            XCTAssertTrue(ready.waitForExistence(timeout: 10))
            assertNoChinese(app); capture(app, "en-" + screen)
            app.terminate()
        }
    }
}
