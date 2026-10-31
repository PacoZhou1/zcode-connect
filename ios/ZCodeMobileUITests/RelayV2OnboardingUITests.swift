import XCTest

@MainActor final class RelayV2OnboardingUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    private func launch(_ language: String, scenario: String = "signedout") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--official-account-review", scenario, "-AppleLanguages", "(\(language))", "-AppleLocale", language == "en" ? "en_US" : "zh_CN"]
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
    func testBigModelSuccessShowsSeparatePlatformAndNextStep() throws {
        let app = launch("zh-Hans", scenario: "bigmodel")
        XCTAssertTrue(app.buttons["account.options.bigmodel"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["account.signIn.zai"].exists)
        XCTAssertFalse(app.buttons["account.signIn.bigmodel"].exists)
        XCTAssertTrue(app.staticTexts["pairing.loginSuccess"].exists)
        XCTAssertTrue(app.buttons["pairing.scan"].isHittable)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Offline BigModel signed-in QR next step"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["pairing.scan"].tap()
        XCTAssertTrue(app.buttons["pairing.showPaste"].waitForExistence(timeout: 5))
    }
    func testBothPlatformStatesAndExplicitAccountSelection() throws {
        let app = launch("en", scenario: "both")
        XCTAssertTrue(app.buttons["account.options.bigmodel"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["account.options.zai"].exists)
        app.buttons["account.options.zai"].tap()
        app.buttons["Use this account"].tap()
        XCTAssertTrue(app.staticTexts["Signed in to Z.ai"].waitForExistence(timeout: 5))
        app.buttons["account.options.zai"].tap()
        app.buttons["Sign out"].tap()
        XCTAssertTrue(app.buttons["account.signIn.zai"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["account.options.bigmodel"].exists)
    }
    func testSettingsOffersConnectionAfterSignIn() throws {
        let app = launch("en", scenario: "bigmodel")
        XCTAssertTrue(app.buttons["pairing.settings"].waitForExistence(timeout: 10))
        app.buttons["pairing.settings"].tap()
        XCTAssertTrue(app.buttons["settings.connectComputer"].waitForExistence(timeout: 5))
        app.buttons["settings.connectComputer"].tap()
        XCTAssertTrue(app.buttons["pairing.scan"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Signed in to BigModel"].exists)
    }
    func testSettingsOwnsItsAuthorizationPresentation() throws {
        let app = launch("en")
        XCTAssertTrue(app.buttons["pairing.settings"].waitForExistence(timeout: 10))
        app.buttons["pairing.settings"].tap()
        try verifyOfficialBrowser(provider: "bigmodel", app: app)
    }
    func testExistingUserCanAuthorizeFromAddConnectionSheet() throws {
        let app = launch("en", scenario: "existing")
        XCTAssertTrue(app.buttons["home.sidebar"].waitForExistence(timeout: 10))
        app.buttons["home.sidebar"].tap()
        XCTAssertTrue(app.buttons["connections.add"].waitForExistence(timeout: 5))
        app.buttons["connections.add"].tap()
        try verifyOfficialBrowser(provider: "bigmodel", app: app)
    }
    func testSettingsAddConnectionOwnsAuthorization() throws {
        let app = launch("en")
        XCTAssertTrue(app.buttons["pairing.settings"].waitForExistence(timeout: 10))
        app.buttons["pairing.settings"].tap()
        let add = app.buttons["settings.addConnection"]
        for _ in 0..<4 where !add.isHittable { app.swipeUp() }
        XCTAssertTrue(add.waitForExistence(timeout: 5)); add.tap()
        try verifyOfficialBrowser(provider: "bigmodel", app: app)
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
    private func verifyOfficialBrowser(provider: String, app existingApp: XCUIApplication? = nil) throws {
        let app = existingApp ?? launch("en")
        XCTAssertTrue(app.buttons["account.signIn.\(provider)"].waitForExistence(timeout: 15))
        // Settings overlays onboarding, whose offscreen row can share the same identifier.
        let signIn = try XCTUnwrap(app.buttons.matching(identifier: "account.signIn.\(provider)").allElementsBoundByIndex.first { $0.isHittable })
        signIn.tap()
        let closeButtons = app.buttons.matching(NSPredicate(format: "label IN %@", ["Done", "Close", "完成", "关闭"]))
        let presented = closeButtons.firstMatch.waitForExistence(timeout: 25)
        let content = app.webViews.staticTexts.matching(NSPredicate(format: "label != %@", "")).firstMatch
        let contentLoaded = content.waitForExistence(timeout: 30)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Official authorization in Safari service " + provider; shot.lifetime = .keepAlways; add(shot)
        XCTAssertTrue(contentLoaded, "Official provider page should render content, beyond just Safari chrome")
        XCTAssertTrue(presented, "Official authorization must open in the system browser surface")
        if let done = closeButtons.allElementsBoundByIndex.first(where: { $0.isHittable }) {
            done.tap()
        } else {
            // The nested Safari service exposes its visible close control as non-hittable
            // on this iOS 26.5 Simulator. The reviewed, fresh app screenshot places that
            // control here; this tap remains inside this app, never the Mac desktop.
            let closeShot = XCTAttachment(screenshot: app.screenshot()); closeShot.name = "Safari close fallback before tap"; closeShot.lifetime = .keepAlways; add(closeShot)
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.085, dy: 0.115)).tap()
        }
        XCTAssertTrue(app.buttons["account.signIn.\(provider)"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["account.options.\(provider)"].exists)
    }
}
