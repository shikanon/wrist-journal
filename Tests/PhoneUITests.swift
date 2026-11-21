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

    @MainActor
    func testDailyAnalysisReviewAndCleanup() {
        let app = XCUIApplication()
        app.launchArguments = ["-journal-fixture", "-journal-fixture-reset"]
        app.launch()
        app.tabBars.buttons["回顾"].tap()
        let analyze = app.buttons["分析已结束日期"]
        XCTAssertTrue(analyze.waitForExistence(timeout: 8))
        analyze.tap()
        app.buttons["开始每日分析"].tap()
        let done = app.staticTexts["已完成结束日期的分析；日报、纪要和地点已保留。"]
        XCTAssertTrue(done.waitForExistence(timeout: 10))
        // One saved day in the isolated fixture store.
        let dayLink = app.cells.containing(.staticText, identifier: "1 段会议 · Asia/Shanghai").firstMatch
        XCTAssertTrue(dayLink.exists)
        dayLink.tap()
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["会议地点（粗略）：31.230, 121.474"].exists)
        XCTAssertTrue(app.staticTexts["模拟纪要：确认差旅会议的行动项，下周跟进。"].exists)
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["心率与语音重合 · 未发现运动"].exists)
        app.tabBars.buttons["录音"].tap()
        XCTAssertTrue(app.staticTexts["原音已清理 · 纪要在回顾中保留"].exists)
        app.cells.containing(.staticText, identifier: "差旅模拟会议").firstMatch.tap()
        XCTAssertFalse(app.buttons["播放"].exists)
        XCTAssertFalse(app.buttons["导出 M4A"].exists)
        app.terminate()
        app.launchArguments = ["-journal-fixture"]
        app.launch()
        app.tabBars.buttons["回顾"].tap()
        app.segmentedControls.buttons["每周"].tap()
        XCTAssertTrue(app.staticTexts["1 段 · 02:00"].exists)
        app.segmentedControls.buttons["每月"].tap()
        XCTAssertTrue(app.staticTexts["1 段 · 02:00"].exists)
    }

    @MainActor
    func testBackupFailureRetainsOriginal() {
        let app = XCUIApplication()
        app.launchArguments = ["-journal-fixture", "-journal-fixture-reset", "-journal-fixture-cloud-failure"]
        app.launch()
        app.tabBars.buttons["设置"].tap()
        for _ in 0..<5 {
            if app.switches["云端备份原始录音"].isHittable { break }
            app.swipeUp()
        }
        let backup = app.switches["云端备份原始录音"]
        XCTAssertTrue(backup.exists)
        backup.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        app.tabBars.buttons["回顾"].tap()
        app.buttons["分析已结束日期"].tap()
        app.buttons["开始每日分析"].tap()
        let failed = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "分析或备份未完成，原音已保留。")).firstMatch
        XCTAssertTrue(failed.waitForExistence(timeout: 10))
        app.tabBars.buttons["录音"].tap()
        XCTAssertFalse(app.staticTexts["原音已清理 · 纪要在回顾中保留"].exists)
        app.cells.containing(.staticText, identifier: "差旅模拟会议").firstMatch.tap()
        XCTAssertTrue(app.buttons["播放"].exists)
        XCTAssertTrue(app.buttons["导出 M4A"].exists)
    }
}
