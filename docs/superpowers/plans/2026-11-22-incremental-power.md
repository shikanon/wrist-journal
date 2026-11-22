# Incremental Power Optimization Implementation Plan

> **For agentic workers:** Execute the authorized work inline, in the order below, with build and simulator checkpoints.

**Goal:** 实现待处理索引、重试冷却、增量设备同步、压缩音频与静音跳过、健康增量更新及可选精准采集。

**Architecture:** 本地文件仍是事实来源，以可重建目录索引分页读取历史，以持久化待办恢复未完成工作。健康本地统计先于联网任务；语音保留原始时间坐标，清理通知直到手表确认后才出队。默认读取系统健康数据，精准模式仅在用户录音期间主动采集运动并监听新增心率。

**Tech Stack:** Swift / SwiftUI、AVFoundation、HealthKit anchored queries、CoreMotion、Network、WatchConnectivity。

---

### 1. 索引、清理与历史

- [x] 修改 `Shared/JournalStore.swift`：目录索引缓存录音、日报的轻量描述，读写锁串行化；写入前设置脏标记，异常后重建；旧数据只迁移一次。
- [x] 修改 `Shared/DailyInsights.swift`：日报加入 `cleanupCompletedAt: Date?`；纪要保留 `speechWindows: [SpeechWindow]?`，迟到健康数据可重算。
- [x] 修改 `Phone/PhoneJournal.swift` 和列表：`store.list(offset:limit:)`、`store.dailyReports(offset:limit:)` 按页加载；从索引恢复未完成分析。
- [x] 完成清理时遵循 `saveDaily → backup → purgeDaily → compactAnalysis → completeCleanup`，重复执行不再改写墓碑。

### 2. 重试与网络

- [x] 新建共享纯 Swift 策略：持久化失败次数、下次尝试时间、配置指纹；间隔为 1、5、15、60 分钟，之后最多 6 小时；鉴权失败等待配置变化。
- [x] `DailyPipeline` 按待办逐日处理，失败不阻塞其它日期；健康本地阶段独立于上传和云备份。
- [x] `AnalysisScheduling` 使用 NWPathMonitor 与 URLSession 蜂窝限制执行仅 Wi-Fi 自动上传；每次请求前重新检查。

### 3. 手表通信与采集

- [x] `CompanionTransfer` 加入清理 ACK；手机只发送未确认 ID，手表真正删完后确认，包括重复通知。
- [x] 配置同步合并 applicationContext，包含采集模式和充电集中传输；录音中暂停自动文件队列，停止后恢复；手动发送明确绕过充电策略。
- [x] 精准模式使用 CoreMotion 主动运动采集并监听 HealthKit 新样本，录音结束或中断时立即停止。UI 明示心率频率由 watchOS 控制，不伪造训练。

### 4. 音频

- [x] `MeetingAnalysis` 按官方 Chat API 的压缩音频契约上传；已核实模型优先 M4A，未知自定义模型保留兼容选项。
- [x] 新建音频分段组件：扫描保守能量阈值，仅剔除长且明确安静的区段，前后留缓冲；持久化原始 frame 范围，恢复时不重新改变段索引。
- [x] 使用原始起点解析语音线索；全静音在本地完成，不调用模型；旧分段进度沿用旧时间划分。

### 5. 健康增量

- [x] `DailyHealthReader` 分页锚定查询新增/删除样本，保存锚点、样本时间索引与待失效区间；只有失效提交后清除区间。
- [x] 以固定健康时区和会议真实区间定位受影响日报；复用已完成日期，合并相邻会议的查询范围。
- [x] 原音删除后仍用纪要的语音时间窗口更新关联，健康数据不进入 CloudKit。

### 6. 验证与交付

- [x] 扩展本地回归覆盖：旧数据迁移、重启、清理幂等、ACK、分页、冷却、静音时间映射、健康迟到与删除、传输策略。
- [x] 执行 `swiftc Shared/Models.swift Shared/DailyInsights.swift Shared/WorkPolicy.swift Shared/JournalStore.swift Tests/CoreRegression.swift`：60 项通过。
- [x] 编译 iOS/watchOS 模拟器与 Release 设备目标；执行 `Tests/SimulatorRegression.py`：五个场景通过，证据保存在 `docs/validation/`。XCTest 包编译通过，界面调度仍受本机 CoreSimulator 版本限制。
- [x] 更新 `docs/性能省电与真机验收.md`，区分已验证接口契约、模拟验证及待真机测试。

交付：按此前授权提交并推送；远程提交以交付回复中的哈希为准。

官方接口依据（2026-11-22 核实）：

- https://ark.volcengine.com/region:cn-beijing/docs/audio-understanding
- https://developer.apple.com/documentation/healthkit/running-workout-sessions
