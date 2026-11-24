# Daily Report Home Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 iPhone 打开应用就能读到最新会议日报，查看图文并编辑，只有需要核对时才打开会议来源和录音。

**Architecture:** `DailyJournalReport` 仍是生成数据；日报界面从 AI 会议纪要中挑出要点，图表由真实录音时间计算。在 `JournalStore` 按归档日与时区单存用户编辑版，后台整理、健康更新及音频清理不会覆盖它。用户明确确认后，可以在手机处理模式用既有方舟模型合并多场会议纪要为可编辑文字。

**Tech Stack:** iOS 17+ SwiftUI、Swift Charts、PhotosUI、ImageIO、Foundation/JSON、Xcode/simctl。

---

### Task 1: 本地日报内容与独立编辑版

**Files:** `Shared/DailyInsights.swift`, `Shared/JournalStore.swift`, `Tests/CoreRegression.swift`

- [x] 给 `DailyJournalReport` 增加只读 `narrative`（报告标题、汇总要点）及 `preferred(in:)`（会议日报优先，健康日报作回退）。按录制开始小时汇总时长。`DailyReportEdition` 限制标题 120 字、正文 16,000 字、三张各不超过 1 MiB 的照片，保留保存时的会议 ID。
- [x] `store.dailyEdition(_:)` 和 `store.saveDailyEdition(_:for:)` 使用 `DailyEditions` 子目录与日报相同的编码键；分享和云备份都不读取私有编辑附件。为归档刷新、重启和同日不同时区隔离加断言，例如：

  ```swift
  try store.saveDailyEdition(edited, for: report.day)
  try store.saveDaily(report)
  try check(try JournalStore(root: root).dailyEdition(report.day) == edited, "manual edition survives report regeneration")
  ```

- [x] 运行 README 的 `CoreRegression.swift` 编译与执行命令，确认新断言通过。

### Task 2: 日报首页、阅读与图文编辑

**Files:** `Phone/DailyReportPresentation.swift`（新）, `Phone/JournalReviewView.swift`, `Phone/WristJournalPhone.swift`, `WristJournal.xcodeproj/project.pbxproj`

- [x] 首 tab 使用 `DailyReportHome(journal: journal, openRecordings: { tab = 2 })`，顺序为日报、健康、录音、设置。首页空态给同步录音入口；有报告时先显示当天的主要信息，其他日期从「历史日报」进入日、周、月；分析和来源继续复用已有流程。
- [x] `DailyReportSections` 渲染带小标题、加粗和列表的正文、照片及说明、录制时段柱状图；「会议与来源」单独打开原有证据列表。增加 `DailyReportEditor`，提供编辑/预览、保存/取消和恢复自动正文。照片用系统选取器，ImageIO 下采样，不保留原图元数据。
- [x] 在 `Shared/MeetingAnalysis.swift` 用 `ArkClient` 对最多 12 场的原有文字纪要按用户确认再生成日报草稿。在 `.watch` / `.none` 下只用本地汇编，不改变当前设备模式和自动分析的授权。
- [x] 编译新增的 `PhoneUITests` 界面用例。隔离的 Debug 夹具已实际渲染图文版，并验证新归档不会覆盖文本或照片；触摸用例未运行，见验证记录。

### Task 3: 交付

**Files:** `README.md`, `docs/validation/README.md`

- [x] 构建 `PhoneUITests` iOS Simulator 目标和含 Watch 的 unsigned device Release，运行核心、续录和涉及日报的模拟回归。记录系统照片选择、真实 AI 调用、真机 VoiceOver 尚需验收，保持 README 真机验收 OPEN。
- [x] 交付时运行 `git diff --check`，提交并推送 `origin/main`，确认远端 commit。
