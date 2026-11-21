# 每日手记、性能与省电 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 iPhone 按录音发生地的日期汇总语音、位置、运动和健康数据，生成日/周/月回顾，安全清理原始数据，完成模拟验证并推送远程仓库。

**Architecture:** 手表只录制 AAC 和获取有截止时间的单次粗略定位；iPhone 串行执行分段语音分析与本地 HealthKit 关联。每日结果原子落盘后，按设置先备份原音与位置到 CloudKit 私有数据库再删除两端原始录音；健康原始样本仅在内存中关联，不进入 iCloud；摘要和清理标记保留用于回顾及防止重复导入。

**Tech Stack:** Swift、SwiftUI、AVFoundation、HealthKit、CoreLocation、WatchConnectivity、BackgroundTasks、CloudKit、Xcode 模拟器。

---

用户已授权实施、模拟测试和推送。本计划直接在当前干净仓库执行，不另设审批步骤。测试及构建产物存放在工作区外。

### Task 1: 数据与纯本地关联

**Files:** `Shared/Models.swift`、新建 `Shared/DailyInsights.swift`、`Shared/JournalStore.swift`。

- [x] 增加可选的录音时区、定位精度/时间和原音清理时间，旧 JSON 缺字段仍能读取。
- [x] 定义 `JournalDayKey`、`SpeechWindow`、`HeartSample`、`ActivityWindow`、`HeartRateEvent`、`MeetingDigest`、`DailyJournalReport`、`JournalReview`。同一会议按开始时的时区和日期归档；跨午夜会议的健康关联读取完整录制时段。
- [x] 实现本地关联：有效基线样本来自说话窗口之前五分钟，至少三个样本；升高需同时达到用户设置的绝对值和相对值；运动窗口或运动中的心率升高单独标记；没有基线/语音证据时不生成关联结论。

```swift
let elevated = sample.bpm >= settings.highBPM
    && sample.bpm - baseline >= settings.riseBPM
let overlapsSpeech = sample.date >= speech.start && sample.date < speech.end
let overlapsActivity = activity.contains { $0.start <= sample.date && sample.date < $0.end }
```

- [x] 每日文件原子写入；清理只删除原音并保留录音元数据与摘要；收到已有清理标记的同 ID 文件时不复活原音。
- [x] 增加可重复执行的纯 Swift 回归程序，验证缺数据、运动排除、时区/夏令时、回顾统计、失败清理和重复传输。

### Task 2: 语音与 HealthKit

**Files:** `Phone/MeetingAnalysis.swift`、新建 `Phone/DailyHealthReader.swift`、`Watch/HealthReader.swift`。

- [x] 每个语音分段请求中文纪要及有相对时间范围的激动说话线索；严格验证 JSON，普通文本兼容为纪要且不生成说话线索。记录重试检查点，已完成的分段不重传。
- [x] 心率原始样本和活动窗口仅用于本地关联；禁止把高心率写成疾病或证明情绪导致高心率。
- [x] 用 HealthKit 日统计读取五项指标，以有界查询读取会议及其前五分钟的心率、步数和运动时段。实际读取错误保留原音；空结果注明权限／同步／采样可能缺失，不产生关联判断。
- [x] 手表的非累计日统计采用统计集合查询，避免一次读取整周所有心率原始样本。

### Task 3: 每日任务与备份

**Files:** 新建 `Phone/DailyPipeline.swift`、`Phone/CloudBackup.swift`、`Phone/AnalysisScheduling.swift`、`Phone/Info.plist`；修改 `Phone/PhoneJournal.swift`、手机 entitlements 和 Xcode 配置。

- [x] 自动分析为用户显式开启的设置，设置文案说明方舟上传；每天处理已经结束的日期，手动按钮可立即处理。今天和未完成语音任务不清理。
- [x] 串行分析，开启云备份时用固定记录 ID 重试 CloudKit 私有备份；原音和位置备份确认后才清理。健康样本不进入 iCloud。关闭备份不上传 CloudKit，并保留待备份原音。
- [x] 先写日报，再写清理标记并移除音频，最后向手表发送清理通知；重启后可继续清理。分段临时笔记在日报完成后收缩，纪要保留。
- [x] 注册 BGProcessingTask，下一日最早运行、默认需充电和网络；到期取消。前台按相同策略补跑，低电量和 serious/critical 热状态暂停自动语音任务，每个分段检查点重新核对策略。

```swift
request.requiresExternalPower = chargingOnly
request.requiresNetworkConnectivity = true
request.earliestBeginDate = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: .now))
```

### Task 4: 手表采集与跨设备清理

**Files:** `Watch/WatchJournal.swift`、`Shared/CompanionTransfer.swift`、`Watch/WristJournalWatch.swift`。

- [x] 每段会议单独记录位置和当时时区；定位超过 15 秒、录音结束或设置关闭即取消，下一会议可重新定位。
- [x] 自动存储优先交给手机；保留可靠入库回执和离线暂存。
- [x] 清理通知采用可排队的 userInfo；同步请求携带清理 ID 以补偿离线、重装或丢失通知；手表处理清理时取消相同文件的待发送任务。通知分批并去重。
- [x] 录音过程中禁止整周报告读取，避免传感器与 CPU 竞争。

### Task 5: 日/周/月回顾与设置

**Files:** `Phone/WristJournalPhone.swift`、`Phone/Export.swift`、新建 `Phone/JournalReviewView.swift`。

- [x] 增加回顾入口，展示每日纪要、每段位置、心率关联事件和缺数据说明；周/月仅从日报聚合，无重复音频分析或上传。健康按固定时区去重。
- [x] 增加自动日分析、健康读取、仅充电分析、云备份、心率阈值设置和手动分析入口。
- [x] 已清理录音隐藏播放/原音导出，继续显示纪要与地点。播放进度更新仅在播放时运行。

### Task 6: 验证、交付和远程推送

**Files:** `Tests/PhoneUITests.swift`、`Tests/WatchUITests.swift`、新建 `Tests/CoreRegression.swift`、`README.md`、`docs/性能省电与真机验收.md`。

- [x] 运行纯 Swift 回归，35 项通过，退出码 0；覆盖原音清理、云备份失败保护和时间关联边界。
- [x] 编译 iOS/watchOS 模拟器及不签名真机目标（含 Release），完整日志写到 `/tmp/wrist-journal-validation`。

```sh
xcodebuild -project WristJournal.xcodeproj -scheme WristJournal -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project WristJournal.xcodeproj -scheme PhoneUITests -destination 'platform=iOS Simulator,name=iPhone 17 Pro' CODE_SIGNING_ALLOWED=NO test
xcodebuild -project WristJournal.xcodeproj -scheme WatchUITests -destination 'platform=watchOS Simulator,name=Apple Watch Series 11 (46mm)' CODE_SIGNING_ALLOWED=NO test
```

以上模拟器名称以本机实际设备列表为准。运行时缺失则安装可用的 Xcode 官方运行时，再继续原定模拟器路径。

- [x] 实际运行四组应用内模拟器回归，验证偏好／回顾重启持久化、合成关联、清理、损坏日期和备份失败保护，保存截图及 JSON。XCTest 界面包编译通过，但设备调度被本机 CoreSimulator 版本不匹配阻塞；导航用例留给完整环境执行，详见验收文档。
- [x] 更新性能方案、CloudKit 配置与另一台电脑的真机验收步骤；未以模拟器结果宣称实际续航改善百分比。
- [x] 检查 diff，提交并常规推送 `origin/main`；远程 main 在提交前没有新增变更，不强推。
