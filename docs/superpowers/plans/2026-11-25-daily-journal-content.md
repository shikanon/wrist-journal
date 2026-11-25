# Daily Journal Content Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 日报打开即读当天内容；一段长录音、个人随记和真正的会议都能形成有用的记录。

**Architecture:** 复用按日期归档的 `MeetingDigest.minutes` 和本机编辑版，不改变归档格式、录音和原音清理流程。报告以自动整理的正文为主，保留照片和编辑入口，另设录音来源；共享分析提示词允许日常事件和个人想法，也保留录音中确实出现的决定与待办。

**Tech Stack:** SwiftUI、Foundation、现有 ArkClient 和 Xcode XCTest。

---

- [x] **正文与来源。** 在 `Shared/DailyInsights.swift` 从整理文本渲染去重的有界段落，引用仍在来源页，处理旧纪要、空白和全静音；在 `Phone/DailyReportPresentation.swift` 将标题与正文合在第一张内容卡，移除会议统计和时长图，保留图文编辑。`Phone/ReportPeriodPresentation.swift` 复用正文摘录，周／月显示有日报的天数与子报告链接。`Tests/CoreRegression.swift` 使用个人日志与多条录音的样例验证顺序、去重和静音状态。
- [x] **生成与确认。** 在 `Shared/MeetingAnalysis.swift` 调整系统、分段、长录音合并、单条整理、日报草稿的提示词，让它们保留日常、观察、想法及有依据的实际待办。仍按原协议返回 `minutes` 和引用；`Phone/DailyReportPresentation.swift`、`Phone/PhoneJournal.swift` 使用同一草稿条数限制，继续要求确认。`Shared/AnalysisFixture.swift` 检查个人日志的纯文字草稿请求和合成响应。
- [x] **验证与交付。** 用 `Tests/PhoneUITests.swift` 验证日志先于来源、选日期、可编辑、原音清理及重启恢复；纯 Swift 回归与双端 Release 编译。README 记录阅读和草稿行为，保持真机验收开放，将实际结果提交并推送到既有 `main`。
