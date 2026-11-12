import XCTest

@MainActor
final class ChatUITests: XCTestCase {
    func openChat() -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launch()
        let preview = app.buttons["先预览聊天界面"]
        for _ in 0..<4 {
            if preview.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        preview.tap()
        let chat = app.staticTexts["完善手机聊天体验"]
        XCTAssertTrue(chat.waitForExistence(timeout: 5))
        chat.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "消息输入框").firstMatch.waitForExistence(timeout: 5))
        return app
    }
    func testTypingAndRotation() {
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = openChat()
        let input = app.descendants(matching: .any).matching(identifier: "消息输入框").firstMatch
        input.tap()
        input.typeText("hello from ui test")
        app.buttons["发送消息"].tap()
        XCTAssertTrue(app.staticTexts["hello from ui test"].waitForExistence(timeout: 5))
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Chat landscape"; attachment.lifetime = .keepAlways
        add(attachment)
    }
    func testImagePreview() {
        let app = openChat()
        let picture = app.buttons["查看图片，支持缩放"].firstMatch
        if !picture.isHittable { app.swipeUp() }
        XCTAssertTrue(picture.waitForExistence(timeout: 5))
        picture.tap()
        XCTAssertTrue(app.navigationBars["图片"].waitForExistence(timeout: 5))
        app.buttons["完成"].tap()
    }
}
