import XCTest

final class PhoneUITests: XCTestCase {
    @MainActor
    func testSyncAndAnalysisSettingsAreAvailable() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["同步手表录音"].waitForExistence(timeout: 8))

        app.tabBars.buttons["设置"].tap()
        XCTAssertTrue(app.staticTexts["录音存储"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["API Key 来源"].exists)
        XCTAssertTrue(app.secureTextFields["输入个人 API Key"].exists)

        let context = app.switches["分析时使用会议背景"]
        app.swipeUp()
        XCTAssertTrue(context.exists)
        let updated = (context.value as? String) == "1" ? "0" : "1"
        let switchControl = context.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5))
        switchControl.tap()
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", updated), object: context)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed)

        app.terminate()
        app.launch()
        app.tabBars.buttons["设置"].tap()
        app.swipeUp()
        XCTAssertEqual(context.value as? String, updated)
        switchControl.tap()
    }
}
