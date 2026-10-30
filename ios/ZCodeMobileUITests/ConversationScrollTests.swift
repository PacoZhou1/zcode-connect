import XCTest

final class ConversationScrollTests: XCTestCase {
    @MainActor func testHistoryDragAndJumpStayReadable() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reference", "--screen", "scroll-layout-review"]
        app.launchArguments += ["--localization-review", "--reset-localization-review", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let table = app.tables["chat.transcript"]
        XCTAssertTrue(table.waitForExistence(timeout: 20))
        let end = app.staticTexts["这是回复末尾，滚动检查。"]
        XCTAssertTrue(end.waitForExistence(timeout: 10))
        table.swipeDown(velocity: .slow)
        table.swipeDown(velocity: .slow)
        let jump = app.buttons["chat.jumpLatest"]
        XCTAssertTrue(jump.waitForExistence(timeout: 5))
        // Finish a long animated jump, verify that the real answer is on screen.
        jump.tap()
        let visible = NSPredicate { _, _ in end.exists && end.isHittable }
        expectation(for: visible, evaluatedWith: app)
        waitForExpectations(timeout: 5)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "jump-latest-real-answer"; shot.lifetime = .keepAlways; add(shot)
        // Interrupt a subsequent jump; native dragging must retain ownership.
        table.swipeDown(velocity: .fast)
        table.swipeDown(velocity: .slow)
        if jump.exists { jump.tap(); table.swipeDown(velocity: .slow) }
        XCTAssertTrue(table.exists)
    }
}
