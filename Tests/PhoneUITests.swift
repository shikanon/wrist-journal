import XCTest

final class PhoneUITests: XCTestCase {
    @MainActor
    func testSyncAndAnalysisSettingsAreAvailable() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.navigationBars["日报"].waitForExistence(timeout: 8))
        app.tabBars.buttons["录音"].tap()
        XCTAssertTrue(app.buttons["同步手表录音"].waitForExistence(timeout: 8))

        app.tabBars.buttons["设置"].tap()
        XCTAssertTrue(app.staticTexts["录音存储"].waitForExistence(timeout: 5))
        let advanced = app.staticTexts["进阶设置"]
        for _ in 0..<3 where !advanced.isHittable { app.swipeUp() }
        advanced.tap()
        XCTAssertTrue(app.staticTexts["API Key 来源"].exists)
        XCTAssertTrue(app.secureTextFields["输入个人 API Key"].exists)

        let context = app.switches["分析时附加心率汇总"]
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
        for _ in 0..<3 where !advanced.isHittable { app.swipeUp() }
        advanced.tap()
        app.swipeUp()
        XCTAssertEqual(context.value as? String, updated)
        switchControl.tap()
    }

    @MainActor
    func testDailyAnalysisReviewAndCleanup() {
        let app = XCUIApplication()
        app.launchArguments = ["-journal-fixture", "-journal-fixture-reset"]
        app.launch()
        let analyze = app.buttons["分析已结束日期"]
        XCTAssertTrue(analyze.waitForExistence(timeout: 8))
        analyze.tap()
        XCTAssertTrue(app.navigationBars["确认分析范围"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["1 个归档日 · 1 段"].exists)
        app.buttons["开始每日分析"].tap()
        XCTAssertTrue(app.staticTexts["daily-report.title"].waitForExistence(timeout: 10))
        openMeetingSources(in: app)
        XCTAssertTrue(app.staticTexts["模拟纪要：确认差旅会议的行动项，下周跟进。"].waitForExistence(timeout: 5))
        assertMeetingMap(in: app)
        let event = app.staticTexts["心率与语音重合 · 未发现运动"]
        for _ in 0..<4 {
            if event.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(event.isHittable)
        app.tabBars.buttons["录音"].tap()
        XCTAssertTrue(app.staticTexts["原音已清理 · 纪要在回顾中保留"].exists)
        app.cells.containing(.staticText, identifier: "差旅模拟会议").firstMatch.tap()
        XCTAssertFalse(app.buttons["播放"].exists)
        XCTAssertFalse(app.buttons["导出 M4A"].exists)
        assertMeetingMap(in: app)
        app.terminate()
        app.launchArguments = ["-journal-fixture"]
        app.launch()
        app.navigationBars.buttons["历史日报"].tap()
        app.segmentedControls.buttons["每周"].tap()
        XCTAssertTrue(app.staticTexts["1 段 · 02:00"].exists)
        app.segmentedControls.buttons["每月"].tap()
        XCTAssertTrue(app.staticTexts["1 段 · 02:00"].exists)
    }

    @MainActor
    private func openMeetingSources(in app: XCUIApplication) {
        let sources = app.descendants(matching: .any)["daily-report.sources"].firstMatch
        for _ in 0..<5 where !sources.isHittable { app.swipeUp() }
        XCTAssertTrue(sources.isHittable)
        sources.tap()
    }

    @MainActor
    func testDailyReportEditorSavesAndDiscards() {
        let app = XCUIApplication()
        app.launchArguments = ["-journal-fixture", "-journal-fixture-reset", "-journal-report-edition-simulation"]
        app.launch()
        let reportTitle = app.staticTexts["daily-report.title"]
        XCTAssertTrue(app.staticTexts["编辑版：差旅与项目交接"].waitForExistence(timeout: 12))
        let edit = app.buttons["编辑日报"]
        XCTAssertTrue(edit.isHittable)
        edit.tap()
        let title = app.textFields["daily-report.editor.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap()
        title.typeText("1")
        app.buttons["保存"].tap()
        let expected = "编辑版：差旅与项目交接1"
        XCTAssertTrue(app.staticTexts[expected].waitForExistence(timeout: 5))

        edit.tap()
        title.tap()
        title.typeText("2")
        app.buttons["取消"].tap()
        app.alerts.buttons["放弃更改"].tap()
        XCTAssertEqual(reportTitle.label, expected)

        app.terminate()
        app.launchArguments = ["-journal-fixture"]
        app.launch()
        XCTAssertTrue(app.staticTexts[expected].waitForExistence(timeout: 6))
    }

    @MainActor
    private func assertMeetingMap(in app: XCUIApplication) {
        let preview = app.descendants(matching: .any).matching(identifier: "meeting-location.preview").firstMatch
        for _ in 0..<4 {
            if preview.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(preview.isHittable)
        XCTAssertFalse(app.buttons["在 Apple 地图中打开"].exists)
        XCTAssertFalse(app.links["在 Apple 地图中打开"].exists)
        XCTAssertTrue(app.staticTexts["录音开始附近 · 约 150 米范围"].exists)
        XCTAssertFalse(app.staticTexts["会议地点（粗略）：31.230, 121.474"].exists)
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
        app.tabBars.buttons["日报"].tap()
        app.buttons["分析已结束日期"].tap()
        app.buttons["开始每日分析"].tap()
        let failed = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "云备份未完成")).firstMatch
        XCTAssertTrue(app.staticTexts["daily-report.title"].waitForExistence(timeout: 10))
        for _ in 0..<5 where !failed.isHittable { app.swipeUp() }
        XCTAssertTrue(failed.waitForExistence(timeout: 10))
        app.tabBars.buttons["录音"].tap()
        XCTAssertFalse(app.staticTexts["原音已清理 · 纪要在回顾中保留"].exists)
        app.cells.containing(.staticText, identifier: "差旅模拟会议").firstMatch.tap()
        XCTAssertTrue(app.buttons["播放"].exists)
        XCTAssertTrue(app.buttons["导出 M4A"].exists)
    }
}
