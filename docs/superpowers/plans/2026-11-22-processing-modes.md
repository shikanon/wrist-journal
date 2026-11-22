# Processing Modes Implementation Plan

> **For agentic workers:** Execute this authorized implementation inline, task by task, with compile and simulator checkpoints. Development, testing, commit and remote push are authorized by the current session.

**Goal:** 提供 Watch 直接调用模型、Phone 调用模型、不处理／导出 Mac 三种处理方式，与三种存储位置独立。

**Architecture:** 复用现有音频分段、方舟调用与检查点为 Shared 层；Phone 维护用户选择，通过 WatchConnectivity 同步公开配置，按需交付钥匙串凭据。Watch 运行可取消的日处理队列，将完成结果可靠传回 Phone，Phone 继续本地健康关联和日报归档。原音只能在处理端不再需要且接收端已确认时释放。

**Tech Stack:** Swift / SwiftUI、AVFoundation、URLSession、HealthKit、Security、WatchConnectivity、现有 CloudKit 与临时 HTTPS 下载。

---

## 产品规则

- 默认 `.phone`，保持当前配置与已启用自动分析的兼容性。位置选择独立于 `automatic`：自动开关决定后台模型调用；手动处理仍由用户触发。
- 当前处理选择控制待处理任务；切换位置取消本机不再符合选择的工作。`.none` 暂停模型调用及日处理／最终清理，采集和已授权的存储／备份同步继续。已导出的文件不自动删除。
- Watch 只调用 Phone 配置的当前方舟模型和 Key，不使用模拟本地模型。URLSession 由系统选择网络路径；后台时间不足取消并保留检查点，不能保证长任务一次完成。
- 设置在配对连接同步后对 Watch 生效；离线手表不能即时知道 Phone 上的新选择。公开配置显示版本，缓存凭据只匹配该版本。
- Key 不进入 applicationContext、录音元数据、CloudKit、导出、日志或代码。Watch 按需通过配对消息获取最新配置，保存到本机钥匙串；公开版本不匹配时等待重新同步，不使用旧 Key。Phone／不处理模式不提供新的 Watch 调用凭据。
- Watch 处理可以使用仍在手表的原音；已经转交手机的待处理原音可由手机重新交给 Watch。结果完成并可靠保存前，手机 ACK／云 ACK 不得释放 Watch 仍需要的原音。
- Watch 结果持久化、发送、Phone 入库与结果 ACK 分开；重复结果不重复分析，晚到结果不能复活已清理数据。Phone 在 Watch 模式仅复用已完成模型结果，不回退发起模型请求。
- 不处理模式提供 Mac 原音及录音元数据导出，保留原始时间、时区、位置和已有运动窗口；已有健康报告可单独导出，不捏造缺失样本。

## Task 1：共享策略与模型接口

Files: `Shared/ProcessingPolicy.swift`（新增）、`Shared/Models.swift`、`Phone/DailyPipeline.swift`、`Phone/MeetingAnalysis.swift` → `Shared/MeetingAnalysis.swift`、`Phone/AudioPreparation.swift` → `Shared/AudioPreparation.swift`、工程文件。

- [x] 定义 `ProcessingMode` 与默认／旧配置迁移：

```swift
enum ProcessingMode: String, Codable, CaseIterable, Identifiable {
    case watch, phone, none
    var id: Self { self }
    static func preference(_ raw: String?) -> Self {
        raw.flatMap(Self.init(rawValue:)) ?? .phone
    }
}
```

- [x] 将 DailySettings 增加可选 processingMode；旧 JSON 缺字段继续读取。公开 Watch 配置包含 mode、model、credential 名称、revision、automatic、chargingOnly、wifiOnly、skipSilence、audioFormat，不包含 Key。
- [x] 复用 Shared 模型接口与分段逻辑；校验其 watchOS 可用性，错误文案不再只指 iPhone。分析任务记录处理端与完成结果 ID，检查点保留原始时间映射。

## Task 2：Phone 路由与“不处理”

Files: `Phone/PhoneJournal.swift`、`Phone/DailyPipeline.swift`、`Phone/AnalysisScheduling.swift`、`Phone/StorageSync.swift`、`Phone/WristJournalPhone.swift`、`Phone/JournalReviewView.swift`。

- [x] Phone 手动、自动、重启恢复和每次网络请求均检查处理位置；切换取消正在执行的任务。`.none` 在日处理入口直接保留原音，不因已有日报继续清理。
- [x] `.watch` 时向 Watch 请求处理／转送缺少的原音；Phone 不调用模型。日报允许使用 Watch 已完成结果，即使 Phone 只有元数据而无原音；备份所需原音不齐时继续保留来源端。
- [x] 设置增加三选一；根据模式显示操作文案、Key 同步状态与限制，Mac 导出入口保持可用。手动处理 Watch 的入口带上传说明；自动开关仍独立。

## Task 3：配置与结果的可靠设备传输

Files: `Shared/CompanionTransfer.swift`、`Shared/JournalStore.swift`、`Shared/ProcessingPolicy.swift`。

- [x] applicationContext 合并公开配置。通过配对 sendMessage 请求凭据，并在回复时检查当前 revision；Watch 钥匙串缓存与公开 revision 不一致时禁止调用。
- [x] 增加 Phone → Watch 待处理音频、Watch → Phone 完成结果和结果 ACK。入库必须在 WC 临时文件失效前完成；只有持久化成功才回 ACK。
- [x] 结果 outbox 和 ACK 状态持久化，文件传输去重；完整性校验包含 UUID、有限时长、结果完成态、非空纪要、合法语音时间窗口。使用不可变传输副本。
- [x] Phone 接收结果不制造本地原音存在状态；修改待处理索引以包含只有远端结果的待归档条目，保留既有手机副本释放索引优化。

## Task 4：Watch 执行与存储协调

Files: `Watch/WatchProcessing.swift`（新增）、`Watch/WatchJournal.swift`、`Watch/WatchCloudStorage.swift`、`Watch/WristJournalWatch.swift`、`Shared/JournalStore.swift`。

- [x] 串行执行结束日期的录音，复用 MeetingAnalyzer。录音期间暂停；自动执行遵守充电、低电量／热状态及联网策略；手动处理仍不能打断录音。
- [x] 持久化重试冷却和手动请求。Key 失效等待配置变化；后台到期、开始录音或模式变化取消 URLSession 并保存检查点。
- [x] 手机／云端确认与原音释放分开：Watch 模式尚未完成的原音必须保留，完成后再按存储策略释放；失败不删除。结果 ACK 只移出 outbox，不冒充日报最终清理。
- [x] Watch 展示处理位置、进度／等待状态、已完成纪要和手动处理入口。结果传回后由 Phone 生成可回顾日报，不能让 Phone 再发相同模型请求。

## Task 5：Mac 自行处理的数据导出

Files: `Phone/LocalDownloadServer.swift`、`Phone/LocalDownloadView.swift`、`Phone/Export.swift`。

- [x] HTTPS 增加鉴权后的元数据导出，含格式版本、录音 UUID、UTC 起止／时区、时长、位置、已有运动窗口及已有健康报告；没有 Key／公开配置中的 Key 哈希。
- [x] 页面提供下载元数据的按钮，原音继续使用一次性票据。CSV 同步补充时区／位置，标明没有本地音频的条目。导出不触发删除。

## Task 6：验证、文档与交付

Files: `Tests/CoreRegression.swift`、`Phone/ProcessingSimulation.swift`（新增）、`Watch/WatchProcessingSimulation.swift`（新增，必要时合入现有 Debug 入口）、`Tests/SimulatorRegression.py`、`Tests/LocalDownloadRegression.py`、`README.md`、`docs/validation/`。

- [x] 策略回归：默认 Phone、三选一、None 禁止自动／手动网络和清理、Watch 阻止 Phone 网络、Watch 未完成前禁止原音释放、已完成结果去重与 ACK 重启恢复。
- [x] Debug 模型传输 fixture 走同一分段／检查点调用链，验证 Watch 编解码与模型请求构造、失败重试、结果同步导入、Phone 无二次请求、None 保留原音。不使用真实 API Key 或用户录音。
- [x] 运行全部既有核心／六组模拟回归，并新增处理模式、元数据下载断言。真实模型服务与配对设备通信单独列为另一台电脑验收。
- [x] 构建 PhoneUITests／WatchUITests 通用模拟器目标和两端 Release 目标，日志留 `/tmp/wrist-journal-validation/`。当前 CoreSimulator 不匹配，不重试已知失败的 XCTest 调度。

```sh
swiftc Shared/Models.swift Shared/DailyInsights.swift Shared/WorkPolicy.swift \
  Shared/StoragePolicy.swift Shared/ProcessingPolicy.swift Shared/JournalStore.swift \
  Tests/CoreRegression.swift -o /tmp/wrist-journal-validation/processing-core
/tmp/wrist-journal-validation/processing-core
```

- [x] 文档注明处理与存储的组合、默认 Phone、离线配置传播、Watch 后台限制、None 保留及 Mac 导出范围。测试通过后按用户授权提交推送；提交与远端状态由 Git 记录核验。

实现补充：手动请求按配置版本持久化，防止 WC 多通道乱序导致丢失或错误授权；返送手表的原音在对应结果完成前保留。结果首次入库使用原子目录迁移，重复投递还会修复已写结果但未写索引标记的中断。
