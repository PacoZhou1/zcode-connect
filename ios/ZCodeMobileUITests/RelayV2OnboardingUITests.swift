import XCTest

@MainActor final class RelayV2OnboardingUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    private func launch(_ language: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(\(language))", "-AppleLocale", language == "en" ? "en_US" : "zh_CN"]
        app.launch()
        return app
    }
    func testEnglishAccountOnboarding() throws {
        let app = launch("en")
        XCTAssertTrue(app.buttons["account.signIn.zai"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["account.signIn.bigmodel"].exists)
        XCTAssertTrue(app.staticTexts["ZCode account"].exists)
        XCTAssertFalse(app.staticTexts["account.failure"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Relay V2 English account entry"; shot.lifetime = .keepAlways; add(shot)
    }
    func testChineseAccountOnboarding() throws {
        let app = launch("zh-Hans")
        XCTAssertTrue(app.buttons["account.signIn.zai"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["account.signIn.bigmodel"].exists)
        XCTAssertTrue(app.staticTexts["ZCode 账号"].exists)
        XCTAssertFalse(app.staticTexts["account.failure"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Relay V2 Chinese account entry"; shot.lifetime = .keepAlways; add(shot)
    }
    func testNewQRNeedsAccountBeforeConnecting() throws {
        let app = launch("en")
        let paste = app.buttons["pairing.showPaste"]
        for _ in 0..<4 where !paste.isHittable { app.swipeUp() }
        XCTAssertTrue(paste.waitForExistence(timeout: 10)); paste.tap()
        let text = app.textFields["pairing.address"].exists ? app.textFields["pairing.address"] : app.textViews["pairing.address"]
        text.tap()
        text.typeText("https://zcode.z.ai/remote/v4?sid=synthetic-device&mid=synthetic-machine&name=Demo&app_version=3.17.1")
        app.buttons["pairing.recognize"].tap()
        XCTAssertTrue(app.buttons["pairing.connect"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["pairing.connect"].isEnabled)
        XCTAssertTrue(app.buttons["account.signIn.zai"].exists)
    }
    func testOfficialBrowserAuthorizationCanBeCancelled() throws {
        try verifyOfficialBrowser(provider: "zai")
    }
    func testBigModelOfficialAuthorizationCanBeCancelled() throws {
        try verifyOfficialBrowser(provider: "bigmodel")
    }
    private func verifyOfficialBrowser(provider: String) throws {
        let app = launch("en")
        XCTAssertTrue(app.buttons["account.signIn.\(provider)"].waitForExistence(timeout: 15))
        app.buttons["account.signIn.\(provider)"].tap()
        let done = app.buttons.matching(NSPredicate(format: "label IN %@", ["Done", "Close", "完成", "关闭"])).firstMatch
        let presented = done.waitForExistence(timeout: 25)
        let content = app.webViews.staticTexts.matching(NSPredicate(format: "label != %@", "")).firstMatch
        let contentLoaded = content.waitForExistence(timeout: 30)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Official authorization in Safari service " + provider; shot.lifetime = .keepAlways; add(shot)
        XCTAssertTrue(contentLoaded, "Official provider page should render content, beyond just Safari chrome")
        XCTAssertTrue(presented, "Official authorization must open in the system browser surface")
        done.tap()
        XCTAssertTrue(app.buttons["account.signIn.zai"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.otherElements["account.identity"].exists)
    }
}
