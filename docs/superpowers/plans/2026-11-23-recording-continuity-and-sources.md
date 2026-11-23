# Recording continuity and sources implementation plan

**Goal:** 加入可选中断续录、录音时间点标记，以及可以查看转写原文和定位原音的回顾。

**Architecture:** 中断前后各保存独立音频，通过会话 ID、前段 ID 和实际空档连接，避免拼接后时间漂移。续录仅在本次进程内、系统明确允许恢复时进行有限重试。标记及引用均以原文件时间为准；旧记录保持可读，日报保留引用，清理原音后继续显示原文。

**Tech Stack:** Swift、SwiftUI、AVFoundation、WatchConnectivity、现有 JSON 持久化和独立 Swift 回归程序。

## 1. 连续录音与标记

- [x] `Shared/Models.swift` 增加可选 `markers`、`continuation`；`RecordingMarker` 保存 UUID、文件秒数和标签；`RecordingContinuation` 保存会话、前段和中断起止时间。可选字段保证历史 JSON 可解码。
- [x] `Watch/RecordingExperience.swift` 增加仅驻内存的 `RecordingRecovery` 状态机，系统许可后按 0/2/5 秒至多尝试三次；等待总时限 120 秒；重复结束通知不并发恢复；停止、关闭开关及超时取消。
- [x] `Watch/WatchJournal.swift` 接入中断 began/ended、取消令牌、保存结果和文件连续性；应用冷启动不恢复麦克风；失败保留已有音频。标记取 `AVAudioRecorder.currentTime`，原子保存成功才反馈，同一秒内去重。
- [x] `Watch/RecordingScreen.swift` 加入“标记此刻”和保存反馈；`Watch/WristJournalWatch.swift` 加入默认关闭的开关、等待续录提示与取消按钮、标记回听和录音空档。

状态机验收例：

```swift
var recovery = RecordingRecovery()
recovery.begin(recordingID: UUID(), enabled: false)
assert(recovery.pending == nil)
recovery.begin(recordingID: UUID(), enabled: true)
recovery.cancel()
assert(recovery.nextAttempt(shouldResume: true) == nil)
```

## 2. 原文与音频引用

- [x] `Shared/DailyInsights.swift` 扩展分段响应：`transcript` 包含相对分段的原文和起止秒数；`highlights` 通过索引指向转写。只有合法索引、有效时段和非空原文形成引用；旧纯纪要响应不补造引用。
- [x] `Shared/ProcessingPolicy.swift` 保存 `SourceCitation`，传输校验其录音 ID 和时段；`Shared/MeetingAnalysis.swift` 将分段帧起点加回偏移，确保静音跳过不改变引用时轴，断点续跑不重复。
- [x] `Shared/DailyInsights.swift` 的 `MeetingDigest`、`Phone/DailyPipeline.swift` 和 `Phone/LocalHealthPipeline.swift` 保留标记、连续性和来源字段；日报清理后不丢失引用。
- [x] `Phone/JournalReviewView.swift`、`Phone/WristJournalPhone.swift` 展示“来源要点”、可选择的转写原文、录音范围和回听按钮；日报及周/月下钻复用同一界面；源文件未在手机或已清理时说明状态。分享文本附原文和录音 ID。
- [x] `Phone/Export.swift` 导出标记和连续性；现有 JSON 元数据自动携带新增字段。

引用验收：源段起点 300 秒、模型返回 4–8 秒时，保存 304–308 秒；越界/倒序/不存在索引的引用全部拒绝；无来源历史纪要显示明确空态。

## 3. 回归与交付

- [x] 添加独立特性回归程序，覆盖旧 JSON、状态机、标记持久化、静音偏移、无效引用、处理结果跨设备编码及清理后日报保留。
- [x] 运行现有核心回归和录音体验回归。新特性测试同样使用 `swiftc` 直接编译 Foundation 层，完整输出保存到 `/tmp/wrist-journal-validation`。
- [x] 使用 `xcodebuild -project WristJournal.xcodeproj -scheme WristJournal -configuration Release -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build` 验证双端；构建 PhoneUITests/WatchUITests。
- [x] 扩展模拟器编码音频夹具验证标记、续录取消与引用生成。真实电话中断、后台恢复调度、触觉和实际触控列为硬件验收，不将夹具视为麦克风真机测试。
- [x] 更新 README、Auday 功能借鉴及验证记录；交付时沿用已获授权提交并推送远端。

三项均纳入实现，不引入假运动保活，不在重启后自动打开麦克风，不把纪要改写冒充转写原文。

验收结果：164 项独立 Swift 检查通过；原生编码音频、来源归档、健康更新和渲染探针通过；双端测试包及 Release 构建通过。细节与真机待验项见 `docs/连续录音标记与来源回顾.md` 和 `docs/validation/README.md`。
