# Watch Recording Experience Implementation Plan

**Goal:** 点击开始后进入黑底防误触界面；可靠反馈真实录音和保存状态；中断可恢复且提示持续可见。

**Architecture:** Watch 录音生命周期继续由 `WatchJournal` 管理。独立的纯 Swift `RecordingGuard` 管理确认、锁定和控制面板时限，SwiftUI 只负责显示及手势。录音结果单独持久化，恢复录音也产生中断结果；录音文件仍沿用现有校验和存储流程。

**Tech Stack:** SwiftUI / watchOS 10+ / AVFoundation / WatchKit / simctl。

## 执行与验收

- [x] 新建 `Watch/RecordingExperience.swift`：状态 `locked / confirming / controls`，默认立即锁定，非立即模式确认 1 秒，长按 1.5 秒解锁后控制面板 5 秒无操作自动锁定。失活和低亮度立即锁定。VoiceOver 使用可访问按钮解锁，阅读时不按 5 秒关闭。
- [x] 新建 `Watch/RecordingScreen.swift`，移除 `Watch/WristJournalWatch.swift` 中表冠录音绑定。锁定页黑底，只显示静态小状态与长按提示；控制面板显示计时器、停止保存、立即锁定。停止按钮只存在于解锁面板。
- [x] 修改 `Watch/WatchJournal.swift`：`record()` 成功后立即发开始触觉；健康授权异步采集不延迟反馈；结束后先校验文件并写元数据，再发成功触觉。失败和中断发不同反馈，持久化结果卡直到明确关闭。
- [x] 开始前检查空间并提示低电量／低剩余空间；停止后明确手表落盘与等待手机／云端确认。保留系统后台音频模式，不声称程序可强制物理熄屏。
- [x] 新建 `Tests/RecordingExperienceRegression.swift`，24 项策略回归通过；短按与长按手势的 Watch XCTest 用例已编译，运行待补。
- [x] 添加 Debug 独立沙盒应用内验收。真实编码文件校验、中断、损坏和冷启动恢复通过；真实麦克风 AVAudioRecorder 启动被模拟器 AudioQueue 锁阻塞，不能算通过。
- [x] 编译 Watch 和 Phone XCTest 包以及两端 Release；已检查原生渲染布局和程序解锁后的自动回锁。真实触摸、VoiceOver 与熄屏验收受环境限制，待补。
- [x] 查询 Auday 官方网站、FAQ、App Store 与用户视频；区分可见演示、官方自述与未验证指标，提供按收益排序的借鉴建议。
- [x] 更新 README、验收文档与证据；按用户已有授权交付代码。

## 命令

```sh
swiftc Watch/RecordingExperience.swift Tests/RecordingExperienceRegression.swift -o /tmp/wrist-journal-validation/recording-experience
/tmp/wrist-journal-validation/recording-experience
swiftc Shared/Models.swift Shared/DailyInsights.swift Shared/WorkPolicy.swift Shared/StoragePolicy.swift Shared/ProcessingPolicy.swift Shared/JournalStore.swift Tests/CoreRegression.swift -o /tmp/wrist-journal-validation/core-regression
/tmp/wrist-journal-validation/core-regression
xcodebuild -project WristJournal.xcodeproj -scheme WatchUITests -destination 'generic/platform=watchOS Simulator' -derivedDataPath /tmp/wrist-journal-validation/watch-simulator CODE_SIGNING_ALLOWED=NO build-for-testing
xcodebuild -project WristJournal.xcodeproj -scheme PhoneUITests -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/wrist-journal-validation/phone-simulator CODE_SIGNING_ALLOWED=NO build-for-testing
xcodebuild -project WristJournal.xcodeproj -scheme WristJournal -configuration Release -destination 'generic/platform=iOS' -derivedDataPath /tmp/wrist-journal-validation/release-device CODE_SIGNING_ALLOWED=NO build
```

纯逻辑验收必须输出 PASS；模拟器真实音频录制必须生成可解码、正时长文件。硬件熄屏续录、触觉手感、耗电及真实系统来电中断列为配对真机补验，不能用合成结果替代。

执行结果及未完成的体验验收见 `docs/Watch录音体验与验收.md`；本计划中的完成标记表示对应实现和可执行验证已交付，不表示未通过的硬件项目完成。
