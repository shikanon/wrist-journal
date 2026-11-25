# Report Period Calendar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 iPhone 报告首页一眼看到当前与前五期，直接点选日报、周报或月报，无需逐期翻页。

**Architecture:** `ReportPeriod` 以归档的公历日期作为锚点，按日、周一至周日、自然月取范围。首页从归档索引获得日期状态，仅读取所选范围的日报并复用原有数据，不触发模型；日报图文、编辑和来源保持可达。更早的日期从同一页面的「选日期」打开。

**Tech Stack:** Swift、SwiftUI、Foundation 日历、原生 Xcode/simctl。

---

- [x] **日期和读取。** 在 `Shared/DailyInsights.swift` 实现 `ReportPeriod` 和六个 `ReportPeriod.Range`（含当前），以 ISO 本地日期字符串查 `Shared/JournalStore.swift` 的有界区间。覆盖跨年周、闰月和同日多时区的核心断言；区间查询不受历史列表上限影响。
- [x] **首页日历行。** 在 `Phone/DailyReportPresentation.swift` 和新的 `Phone/ReportPeriodPresentation.swift` 放首页分段与横排日期。常规字号六格都在首屏；大字号可横移。高亮当前选中期，标有报告的期，空期不自动跳过；「选日期」可直达更早，且能回到最近六期。真实日期和 VoiceOver 标签要说明范围，不只靠颜色。
- [x] **内容与下钻。** 保留 `DailyReportSections` 和同日其他时区入口。周／月以现有存档展示概要、代表性要点、健康概况及子周期链接；月点周、周点日。同一张日历内切换仅换锚点和读取范围。当前日报未生成时默认仍优先看到近期已归档会议日报。
- [x] **验证与交付。** 补核心日期与区间回归，使用 `Tests/PhoneUITests.swift` 实际点击首页日历；编译 iPhone 测试包和双端 Release，保留日报、周报、月报和空档的原生模拟器截图。更新 README 的使用与真机 TODO，保持 OPEN；提交并推送既有远端 `main`。
