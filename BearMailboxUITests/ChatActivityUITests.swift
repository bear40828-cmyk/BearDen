import XCTest

final class ChatActivityUITests: XCTestCase {
    func testVisibilityTimelineAndToolDetail() {
        let app = XCUIApplication()
        app.launchArguments = ["--bear-activity-ui-test", "-assistantRemark", "周四测试备注"]
        app.launch()
        let toggle = app.switches["activity.toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["我拍了拍「周四测试备注」的脑袋"].exists)
        XCTAssertFalse(app.buttons["查看过程记录"].exists)
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        XCTAssertEqual(toggle.value as? String, "1", app.debugDescription)
        let header = app.buttons["查看过程记录"]
        XCTAssertTrue(header.waitForExistence(timeout: 5))
        header.tap()
        XCTAssertTrue(app.navigationBars["过程记录"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["这是接口返回的测试摘要。"].exists, app.debugDescription)
        let tool = app.buttons["查询系统日期和时间"]
        XCTAssertTrue(tool.waitForExistence(timeout: 5), app.debugDescription)
        tool.tap()
        XCTAssertTrue(app.navigationBars["工具详情"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["输入"].exists)
        XCTAssertTrue(app.staticTexts["输出"].exists)
        app.navigationBars["工具详情"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["过程记录"].waitForExistence(timeout: 5))
        app.buttons["完成"].tap()
        app.buttons["测试未返回摘要"].tap()
        header.tap()
        XCTAssertTrue(app.staticTexts["这条回复没有回传可显示的思考摘要。"].waitForExistence(timeout: 5))
        app.buttons["完成"].tap()
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        XCTAssertEqual(toggle.value as? String, "0", app.debugDescription)
        XCTAssertFalse(app.buttons["查看过程记录"].exists)
    }
}
