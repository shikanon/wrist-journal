import XCTest

final class WatchUITests: XCTestCase {
    @MainActor
    func testLibraryNavigationAndCrownDoesNotRecord() {
        let app = XCUIApplication()
        app.launchArguments = ["-journal-recording-ui", "-journal-recording-reset"]
        app.launch()
        let start = app.buttons["开始录音"]
        XCTAssertTrue(start.waitForExistence(timeout: 8))

        app.buttons["录音与健康"].tap()
        XCTAssertTrue(app.staticTexts["暂无录音"].waitForExistence(timeout: 5))
        for _ in 0..<4 where !app.staticTexts["健康报告"].exists { app.swipeUp() }
        XCTAssertTrue(app.staticTexts["健康报告"].waitForExistence(timeout: 5))
        let settings = app.staticTexts["录音设置"]
        for _ in 0..<3 where !settings.isHittable { app.swipeUp() }
        settings.tap()
        XCTAssertTrue(app.switches["开始后立即锁定"].waitForExistence(timeout: 5))
        app.terminate()
        app.launch()
        XCTAssertTrue(start.waitForExistence(timeout: 8))

        // Rotation remains available for scrolling and never requests the microphone.
        XCUIDevice.shared.rotateDigitalCrown(delta: 1)
        XCTAssertFalse(app.staticTexts["请在系统设置中允许访问麦克风。"].exists)
        XCTAssertFalse(app.otherElements["recording.locked"].exists)
        XCTAssertTrue(start.isEnabled)
    }

    @MainActor
    func testRecordingTouchGuardWithGrantedMicrophone() {
        let app = XCUIApplication()
        app.launchArguments = ["-journal-recording-ui", "-journal-recording-reset"]
        app.launch()
        let start = app.buttons["recording.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 8))
        start.tap()
        let hold = app.descendants(matching: .any)["recording.hold"].firstMatch
        XCTAssertTrue(hold.waitForExistence(timeout: 8))
        hold.tap()
        XCTAssertFalse(app.buttons["recording.stop"].exists)
        hold.press(forDuration: 0.5)
        XCTAssertFalse(app.buttons["recording.stop"].exists)
        hold.press(forDuration: 1.7)
        XCTAssertTrue(app.buttons["recording.stop"].waitForExistence(timeout: 2))
        XCTAssertTrue(hold.waitForExistence(timeout: 7))
        hold.press(forDuration: 1.7)
        app.buttons["recording.stop"].tap()
        XCTAssertTrue(app.staticTexts["已保存"].waitForExistence(timeout: 5))
    }
}
