import XCTest

final class ConnectionOnboardingTests: XCTestCase {
    @MainActor func testLiveReviewBridgeConnection() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let address = environment["ZCODE_REVIEW_URL"],
              let token = environment["ZCODE_REVIEW_TOKEN"],
              let sessionID = environment["ZCODE_REVIEW_SESSION_ID"] else {
            throw XCTSkip("Live review credentials must be supplied privately to the test runner.")
        }
        let app = launch()
        let guide = app.buttons["pairing.selfHostedGuide"]
        if !guide.isHittable { app.swipeUp() }
        guide.tap()
        let advanced = app.buttons["pairing.advancedHTTP"]
        if !advanced.isHittable { app.swipeUp() }
        XCTAssertTrue(advanced.waitForExistence(timeout: 5))
        advanced.tap()
        let urlField = app.textFields["pairing.address"]
        XCTAssertTrue(urlField.waitForExistence(timeout: 5))
        urlField.tap(); urlField.typeText(address)
        let tokenField = app.secureTextFields["pairing.token"]
        tokenField.tap(); tokenField.typeText(token)
        app.buttons["pairing.connect"].tap()
        // Decline iOS password storage for the disposable reviewer credential.
        let later = app.buttons["以后"]
        if later.waitForExistence(timeout: 8) { later.tap() }
        let task = app.buttons["session.\(sessionID)"]
        guard task.waitForExistence(timeout: 30) else {
            capture(app, "live-review-connection-failure")
            XCTFail("The connected review task did not become visible.")
            return
        }
        task.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "ZCODE_REVIEW_CONNECTED")).firstMatch.waitForExistence(timeout: 20))
        capture(app, "live-review-bridge-real-response")
    }
    @MainActor func testFirstReleaseHasNoMirrorEntry() {
        let app = XCUIApplication()
        app.launchArguments = ["--onboarding-review", "--reset-onboarding-review", "--reference", "--screen", "chat", "--mirror-auto"]
        app.launchArguments += ["--localization-review", "--reset-localization-review", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.buttons["chat.menu"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.switches["mirror.toggle"].exists)
        app.buttons["chat.menu"].tap()
        XCTAssertTrue(app.buttons["复制对话串 ID"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["chat.mirror"].exists)
        XCTAssertFalse(app.buttons["模拟器镜像"].exists)
        capture(app, "connect-first-release-menu-without-mirror")
    }
    @MainActor private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--onboarding-review", "--reset-onboarding-review"]
        app.launchArguments += ["--localization-review", "--reset-localization-review", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.buttons["pairing.scan"].waitForExistence(timeout: 15))
        return app
    }
    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
    @MainActor private func importLink(_ value: String, into app: XCUIApplication) {
        app.buttons["pairing.showPaste"].tap()
        let field = app.textFields["pairing.address"].exists ? app.textFields["pairing.address"] : app.textViews["pairing.address"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap(); field.typeText(value)
        app.buttons["pairing.recognize"].tap()
    }
    @MainActor func testOfficialGuideAndPairingPreview() {
        let app = launch()
        XCTAssertFalse(app.secureTextFields["pairing.token"].exists)
        capture(app, "onboarding-official-start")
        app.buttons["pairing.guide"].tap()
        XCTAssertTrue(app.staticTexts["使用 ZCode 官方中转"].waitForExistence(timeout: 5))
        capture(app, "official-computer-guide")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        importLink("https://zcode.z.ai/remote/v4?sid=qa-device&hash=synthetic-pairing-value-0123456789&name=QAComputer", into: app)
        XCTAssertTrue(app.buttons["pairing.connect"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["ZCode 官方中转"].exists)
        capture(app, "official-confirm-computer")
        app.buttons["pairing.connect"].tap()
        XCTAssertTrue(app.buttons["连接并使用此手机控制"].waitForExistence(timeout: 5))
        app.buttons["取消"].tap() // No real network or credential used.
        XCTAssertTrue(app.buttons["pairing.connect"].exists)
    }
    @MainActor func testCustomDirectURLAndInvalidReplacement() {
        let app = launch()
        importLink("https://relay.example.invalid:8443/zcode/remote/v4?sid=qa-device&hash=synthetic-pairing-value-0123456789&name=QAComputer", into: app)
        XCTAssertTrue(app.buttons["pairing.connect"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["你的中转 · relay.example.invalid"].exists)
        XCTAssertFalse(app.staticTexts["使用 ZCode 官方中转，无需准备服务器。电脑需保持开机、联网并运行 ZCode。"].exists)
        XCTAssertFalse(app.secureTextFields["pairing.token"].exists)
        capture(app, "custom-direct-qr-preview")
        app.buttons["pairing.replace"].tap()
        // Existing paste disclosure remains open after replacement.
        let field = app.textFields["pairing.address"].exists ? app.textFields["pairing.address"] : app.textViews["pairing.address"]
        field.tap(); field.typeText("https://relay.example.invalid")
        app.buttons["pairing.recognize"].tap()
        XCTAssertTrue(app.staticTexts["pairing.failure"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["pairing.connect"].exists)
        XCTAssertFalse(app.secureTextFields["pairing.token"].exists)
        capture(app, "invalid-link-does-not-become-http")
    }
    @MainActor func testSelfHostedKitAndAdvancedIsolation() {
        let app = launch()
        let guide = app.buttons["pairing.selfHostedGuide"]
        if !guide.isHittable { app.swipeUp() }
        guide.tap()
        XCTAssertTrue(app.buttons["pairing.exportKit"].waitForExistence(timeout: 5))
        capture(app, "self-hosted-guide-and-export")
        app.buttons["pairing.exportKit"].tap()
        XCTAssertTrue(app.otherElements["ActivityListView"].waitForExistence(timeout: 5) || app.buttons["关闭"].exists || app.buttons["Close"].exists)
        capture(app, "self-hosted-kit-share")
    }
}
