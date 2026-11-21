import XCTest

final class WatchUITests: XCTestCase {
    @MainActor
    func testLibraryNavigationAndCrownRecordingRequest() {
        let app = XCUIApplication()
        app.launch()
        let start = app.buttons["开始录音"]
        XCTAssertTrue(start.waitForExistence(timeout: 8))

        app.buttons["录音与健康"].tap()
        XCTAssertTrue(app.staticTexts["健康报告"].waitForExistence(timeout: 5))
        app.terminate()
        app.launch()
        XCTAssertTrue(start.waitForExistence(timeout: 8))

        // The simulator's microphone permission is revoked for this test.
        XCUIDevice.shared.rotateDigitalCrown(delta: 1)
        let denied = app.staticTexts["请在系统设置中允许访问麦克风。"]
        if !denied.waitForExistence(timeout: 8) {
            let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screenshot.lifetime = .keepAlways
            add(screenshot)
            XCTFail("Turning the Digital Crown did not present the microphone permission error.\n\(app.debugDescription)")
        }
    }
}
