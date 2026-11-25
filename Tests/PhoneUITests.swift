import XCTest

final class PhoneUITests: XCTestCase {
    @MainActor
    func testSyncAndAnalysisSettingsAreAvailable() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.navigationBars["报告"].waitForExistence(timeout: 8))
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
        XCTAssertTrue(app.staticTexts["daily-report.title"].waitForExistence(timeout: 5))
        app.segmentedControls.buttons["周报"].tap()
        XCTAssertTrue(app.staticTexts["1 段 · 02:00"].waitForExistence(timeout: 5))
        app.segmentedControls.buttons["月报"].tap()
        XCTAssertTrue(app.staticTexts["1 段 · 02:00"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testCalendarOpensReportsInOneTap() {
        let app = XCUIApplication()
        app.launchArguments = ["-journal-fixture", "-journal-fixture-reset", "-journal-report-calendar-fixture"]
        app.launch()
        let newest = app.buttons["report-calendar.slot.5"]
        let oldest = app.buttons["report-calendar.slot.0"]
        let selection = app.staticTexts["report-calendar.range"]
        XCTAssertTrue(newest.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["daily-report.title"].waitForExistence(timeout: 5))
        let archiveDate = selection.label
        assertSixVisibleSlots(in: app)
        newest.tap()
        XCTAssertTrue(app.staticTexts["这一天暂无日报"].waitForExistence(timeout: 5))
        oldest.tap()
        XCTAssertTrue(app.staticTexts["daily-report.title"].waitForExistence(timeout: 5))
        XCTAssertEqual(selection.label, archiveDate)

        app.segmentedControls.buttons["周报"].tap()
        assertSixVisibleSlots(in: app)
        XCTAssertTrue(app.staticTexts["report-calendar.summary"].waitForExistence(timeout: 5))
        let archiveWeek = selection.label
        let selectedWeek = (0..<6).map { app.buttons["report-calendar.slot.\($0)"] }
            .first { $0.isSelected }
        let expected = oldest.value as? String == "已有报告" ? "report-calendar.summary" : "这一周暂无周报"
        oldest.tap()
        XCTAssertNotEqual(selection.label, archiveWeek)
        XCTAssertTrue(app.staticTexts[expected].waitForExistence(timeout: 5))
        XCTAssertNotNil(selectedWeek)
        selectedWeek?.tap()

        app.segmentedControls.buttons["月报"].tap()
        assertSixVisibleSlots(in: app)
        XCTAssertTrue(app.staticTexts["report-calendar.summary"].waitForExistence(timeout: 5))
        let archiveMonth = selection.label
        let expectedMonth = oldest.value as? String == "已有报告" ? "report-calendar.summary" : "这个月暂无月报"
        let selectedMonth = (0..<6).map { app.buttons["report-calendar.slot.\($0)"] }
            .first { $0.isSelected }
        oldest.tap()
        XCTAssertNotEqual(selection.label, archiveMonth)
        XCTAssertTrue(app.staticTexts[expectedMonth].waitForExistence(timeout: 5))
        XCTAssertNotNil(selectedMonth)
        selectedMonth?.tap()

        let week = app.buttons.matching(identifier: "report-calendar.drill.week").firstMatch
        for _ in 0..<4 where !week.isHittable { app.swipeUp() }
        XCTAssertTrue(week.isHittable)
        week.tap()
        XCTAssertTrue(app.segmentedControls.buttons["周报"].isSelected)

        app.navigationBars.buttons["选日期"].tap()
        XCTAssertTrue(app.navigationBars["选日期"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars.buttons["查看周报"].exists)
        app.navigationBars.buttons["取消"].tap()

        app.segmentedControls.buttons["日报"].tap()
        let recent = app.buttons["回到最近"]
        if recent.exists { recent.tap() }
        app.navigationBars.buttons["选日期"].tap()
        let older = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "report-calendar.archive.")).allElementsBoundByIndex
        XCTAssertGreaterThanOrEqual(older.count, 2)
        if let oldDay = older.last {
            for _ in 0..<4 where !oldDay.isHittable { app.swipeUp() }
            oldDay.tap()
            XCTAssertTrue(recent.waitForExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts["daily-report.title"].waitForExistence(timeout: 5))
            recent.tap()
            XCTAssertTrue(app.staticTexts["这一天暂无日报"].waitForExistence(timeout: 5))
        }
    }

    @MainActor
    private func assertSixVisibleSlots(in app: XCUIApplication) {
        for index in 0..<6 {
            XCTAssertTrue(app.buttons["report-calendar.slot.\(index)"].isHittable, "Calendar slot \(index)")
        }
    }

    @MainActor
    private func openMeetingSources(in app: XCUIApplication) {
        let sources = app.descendants(matching: .any)["daily-report.sources"].firstMatch
        for _ in 0..<5 where !sources.isHittable { app.swipeUp() }
        XCTAssertTrue(sources.isHittable)
        sources.tap()
    }

    @MainActor
    func testDailyReportEditorSavesAndDiscards() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-journal-fixture", "-journal-fixture-reset", "-journal-report-edition-simulation"]
        app.launch()
        let reportTitle = app.staticTexts["daily-report.title"]
        XCTAssertTrue(app.staticTexts["编辑版：差旅与项目交接"].waitForExistence(timeout: 12))
        let edit = app.buttons["编辑日报"]
        for _ in 0..<3 where !edit.isHittable { app.swipeUp() }
        XCTAssertTrue(edit.isHittable)
        edit.tap()
        let title = app.textFields["daily-report.editor.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        let original = try XCTUnwrap(title.value as? String)
        title.tap()
        title.typeText("1")
        let expected = try XCTUnwrap(title.value as? String)
        XCTAssertEqual(expected.replacingOccurrences(of: "1", with: ""), original)
        XCTAssertEqual(expected.count, original.count + 1)
        app.buttons["保存"].tap()
        XCTAssertTrue(app.staticTexts[expected].waitForExistence(timeout: 5))

        edit.tap()
        title.tap()
        title.typeText("2")
        XCTAssertNotEqual(title.value as? String, expected)
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
        app.tabBars.buttons["报告"].tap()
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
