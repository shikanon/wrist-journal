# Storage Modes and Local Download Implementation Plan

> **For agentic workers:** Execute the authorized implementation inline, task by task, with compile and simulation checkpoints. The user explicitly requested development, testing, commit and push.

**Goal:** 提供默认 Watch 优先、手机优先、云端优先三种存储模式，安全搬运原音，并提供可配置空闲超时的 Mac 浏览器下载。

**Architecture:** 原音始终先在 Watch 安全落盘，按目标批量搬运；接收端确认持久化后才释放 Watch 文件。云端采用现有私人 CloudKit 容器，手机读取待分析清单。普通 watchOS App 不支持局域网监听，下载服务由 iPhone 临时中转，采用临时 HTTPS 身份、会话令牌和空闲租约。

**Tech Stack:** Swift / SwiftUI、WatchConnectivity、CloudKit、BackgroundTasks、Network.framework（仅 iPhone 监听）、Security.framework。

**执行记录（2026-11-22）：** Task 1–5 已实现；Task 6 的 84 项核心回归、原五组应用内场景、新增存储与真实 HTTPS 场景、两端模拟器 XCTest 包编译和两端 Release 编译均通过。证据见 `docs/validation/`，部署及真机边界见 `docs/存储模式与本地下载.md`。下方保留原始验收清单以便另一台电脑补做硬件与真实账号验收；CloudKit 成功路径使用 Debug 本地传输 fixture，不视为真实云服务验证。提交和推送按用户授权在交付时执行。

---

## 已核实的约束与产品选择

- 用户原文“录音数据不每段立刻传输到手机上”按批量传输实现。安全暂存替代“不在 Watch 落盘”，避免断连丢音。
- 新安装／未配置默认 Watch；已有明确的手机或手表偏好保留，旧 `automatic` 偏好迁移为 Watch。历史录音自己的目的地保持，避免更换设置后擅自搬运旧数据。
- Watch 优先：结束日期在手机日调度时请求，不逐段主动发送；日报及可选备份成功后清理。
- 手机优先：按可配置批量间隔（默认 60 分钟）发送；录音中暂停，遵守可选充电条件；入库 ACK 才删除 Watch 副本。
- 云端优先：Watch 发起 CloudKit 请求，禁止蜂窝，不使用 Watch 上不可用的 NWPathMonitor 判断网络。网络路径由系统选择，可经配对手机代理；脱离手机时可使用已知 Wi-Fi，不能承诺强制 Watch 自身 Wi-Fi。
- CloudKit 上传确认后可释放 Watch 原音，保留云端记录、轻量本地元数据以及手机清理回执状态。健康／运动窗口不进入 CloudKit。
- Mac 下载由 iPhone 提供，必须明确显示中转要求。默认 10 分钟无有效操作关闭，设置范围 1–60 分钟；进入后台、Wi-Fi 不可用或用户停止也关闭。下载本身不触发删除。
- HTTPS 使用临时自签名证书，向用户显示证书 SHA-256 指纹；Mac 首次连接需核对并信任。每次启动更换身份和访问令牌；不提交私钥、真实会话令牌或凭据。
- 定时使用系统机会调度，不能保证准点。存储同步与自动语音分析授权分开，存储选择不会自行开启方舟上传。

官方依据（2026-11-22）：

1. https://developer.apple.com/documentation/technotes/tn3135-low-level-networking-on-watchos.md ：普通 Watch App 的监听／底层连接受限，NWPathMonitor 会 unsatisfied；模拟器不体现限制。
2. https://developer.apple.com/documentation/watchos-apps/keeping-your-watchos-app-s-content-up-to-date.md ：CloudKit 可直接从 Watch 使用，但系统选择手机代理、Wi-Fi、蜂窝路径，后台机会有限。
3. https://developer.apple.com/documentation/cloudkit/ckoperation/configuration-swift.class/allowscellularaccess.md ：请求配置禁止蜂窝。
4. 本机 iOS SDK `Security.framework/Headers/SecIdentity.h`：`SecIdentityCreate(allocator, certificate, privateKey)` 自 iOS 11.2 可用，可为每次临时 HTTPS 会话生成独立身份。

## 文件边界

| 文件 | 责任 |
| --- | --- |
| `Shared/Models.swift` | 三种存储选择、旧配置迁移、云端上传和本地释放状态 |
| `Shared/StoragePolicy.swift` | 批量传输决策、间隔归一化、空闲租约、HTTP 请求验证等可测试纯逻辑 |
| `Shared/JournalStore.swift` | 云确认后释放原音，与日报最终删除分别记录；恢复中断释放 |
| `Shared/CompanionTransfer.swift` | 同步间隔／超时设置、自动结束日期拉取、云端清单通知，持久化队列与去重 |
| `Shared/CloudBackup.swift` | 从 Phone 移到 Shared；两端上传、查询待分析记录、下载及完成确认；继续排除健康字段 |
| `Watch/WatchCloudStorage.swift` | 持久化上传重试和批量队列，录音期间取消／暂停，确认云端保存才释放原音 |
| `Watch/WatchJournal.swift` | 三种目的地的调度、接收回执、云端状态与后台生命周期 |
| `Watch/WristJournalWatch.swift` | 当前存储状态、批量同步入口、云端等待／完成状态 |
| `Phone/StorageSync.swift` | 定时请求 Watch、导入 CloudKit、持久化云端完成通知；不阻塞本地健康 |
| `Phone/LocalDownloadServer.swift` | 仅 Wi-Fi 临时 HTTPS 服务、鉴权、流式下载、连接上限、超时和停止 |
| `Phone/LocalTLSIdentity.swift` | Security 原生密钥与签名、自签名 X.509 编码、证书指纹 |
| `Phone/LocalDownloadView.swift` | 开启／关闭、连接网址、指纹、剩余时间和明确的 iPhone 中转说明 |
| `Phone/DailyPipeline.swift` | 云源自动视为需备份；成功日报后确认云待办已处理 |
| `Phone/PhoneJournal.swift` / `AnalysisScheduling.swift` | 来源同步和分析调度协作、前后台状态、安全停止下载服务 |
| `Phone/WristJournalPhone.swift` | 三种存储选择、批量间隔、空闲超时和局域网下载入口 |
| `Phone/StorageSimulation.swift` | 独立 Debug 场景和本地服务测试入口，Release 不包含合成数据 |
| `Tests/CoreRegression.swift` / `Tests/SimulatorRegression.py` | 既有回归继续通过，增加新存储逻辑证据 |
| `Tests/LocalDownloadRegression.py` | 实际 HTTPS 请求、鉴权、下载、租约延长／过期测试 |
| 两端 plist／entitlements／工程 | Watch iCloud 能力、Phone 本地网络说明和新源文件编译 |

## Task 1: 存储状态与策略

- [x] `RecordingStorage` 保留旧 raw value 解码，UI 只展示三个选项：

```swift
static var allCases: [Self] { [.watch, .phone, .cloud] }
static func preference(_ raw: String?) -> Self {
    guard let raw, let value = Self(rawValue: raw), value != .automatic else { return .watch }
    return value
}
```

- [x] 录音新增 `cloudUploadedAt: Date?` 和 `localEvictedAt: Date?`。本地可播放要求二者中的 `localEvictedAt == nil`；云端释放不复用 `rawDeletedAt`，后者只用于最终清理防复活。
- [x] `JournalStore` 先原子保存云确认与释放意图，再删除文件；重启完成未完成 unlink。手机从云端导入时清除本地释放标记，保留云确认信息。
- [x] 策略测试覆盖默认／迁移、Watch 不逐段发送、Phone 未到批量期限不发送、录音中不发送、云失败不删原音、云释放不伪造最终清理、重启完成释放。
- [x] 空闲租约使用单调时间，不因系统时钟变化延长；只接受过期前的有效活动：

```swift
struct LocalAccessLease {
    let timeout: TimeInterval
    private(set) var deadline: TimeInterval
    mutating func touch(at now: TimeInterval) -> Bool {
        guard now < deadline else { return false }
        deadline = now + timeout
        return true
    }
    func expired(at now: TimeInterval) -> Bool { now >= deadline }
}
```

## Task 2: 批量设备通信

- [x] 设置通过 applicationContext 合并同步；默认 Watch、批量间隔 60 分钟、局域网空闲 10 分钟。
- [x] 同步请求区分手动全部与自动仅结束日期。接收到自动请求不会开启方舟分析。
- [x] Watch 持久化上次批量时间和待同步请求；录音／充电阻挡后等待后续机会，成功入队才推进期限。
- [x] Phone 入库 ACK 才删除手机优先原音；Watch 优先直到日处理完成才释放；云端源仅因确认上传或最终清理释放。
- [x] 传输请求和云端通知去重；前台、连接事件与系统后台刷新触发，避免常驻轮询。

## Task 3: Watch 云端与 Phone 云导入

- [x] 共享 `CloudBackup` 保持现有 `audio-<UUID>` 私有记录，加入 `pendingAnalysis` 字段。云端元数据移除 `motionWindows`。
- [x] 上传重试持久化，使用现有 1／5／15／60／180／360 分钟退避。CloudKit 操作设置 `allowsCellularAccess = false`；任务取消时取消操作。
- [x] Watch 上传返回成功后保存确认并释放本地原音；失败、取消或配置不可用时原音仍在。
- [x] Phone 只查询 `pendingAnalysis == 1` 的元数据，游标分页；已入库不重复下载，已清理只回写完成确认。新记录先下载完整资产并原子入库。
- [x] 在部署文档中记录 `pendingAnalysis` 的查询索引要求。尚未配置／无账号时呈现错误并保留数据。
- [x] 日报要求云端源备份确认；完成后持久化待回写队列，云端标记完成成功后出队。云端保留原音供用户备份。
- [x] 注入上传失败和本地云成功路径，验证无数据丢失、导入幂等、最终清理不复活；真实云账号与下载中断验收单独注明。

## Task 4: 定时来源同步与设置

- [x] 扩展每日后台入口，先请求手表来源、执行本地健康／已有录音，再导入云源并继续已授权分析；健康本地阶段不依赖网络成功。
- [x] 新录音到达时在前台按现有分析条件继续；不得以一次批次尚未到达为“全部已完成”。
- [x] 设置提供三种选择、手机批量间隔、仅充电传输、局域网空闲分钟数。说明更改对后续录音生效。
- [x] 云端优先明确选择即授权原音与位置云备份；普通备份开关与此要求一致，避免 UI 显示关闭却上传。

## Task 5: Mac 临时 HTTPS 下载

- [x] 原生 Security 生成每会话 RSA 私钥，构造带实际 IPv4 SAN 的短期 X.509 证书，用 `SecKeyCreateSignature` 签名，通过 `SecIdentityCreate` 提供 NWProtocolTLS 身份。私钥仅内存。
- [x] iPhone 只绑定 Wi-Fi IPv4，启用 TLS 1.2 或更新，拒绝 Host 不匹配。局域网 IP 从 en0 枚举；模拟测试可显式绑定 loopback，不能影响 Release。
- [x] 32 字节随机会话令牌通过 URL fragment 交给页面，API 使用 Authorization Bearer；正式流程不把令牌保存在日志、Cookie 或磁盘。
- [x] 无鉴权仅返回静态页面；音频列表／元数据需鉴权。页面通过 textContent 渲染名称，使用 CSP、no-store、no-referrer、nosniff。
- [x] 原生浏览器下载使用经鉴权签发、绑定录音、限时且仅可消费一次的下载 ticket；每次流式发送至多 64 KiB，限制并发连接和请求头长度，不提供任意路径文件访问。
- [x] 只有成功鉴权操作及已完成传输字节刷新租约；非法请求不续期。一个可取消的睡眠任务负责到期判断；停止时关闭所有连接、清空 ticket 与令牌。
- [x] App 后台、用户停止和网络变化关闭服务；不会因网页下载自动删除原音。显示 HTTPS 地址、证书指纹和首次信任步骤。

## Task 6: 验证与交付

- [x] 纯 Swift 回归覆盖策略／释放／鉴权解析／超时边界及现有全部核心断言：

```bash
swiftc Shared/Models.swift Shared/DailyInsights.swift Shared/WorkPolicy.swift \
  Shared/StoragePolicy.swift Shared/JournalStore.swift Tests/CoreRegression.swift \
  -o /tmp/wrist-journal-validation/storage-core
/tmp/wrist-journal-validation/storage-core
```

- [x] 编译 PhoneUITests、WatchUITests 的通用模拟器目标，以及 WristJournal 的 Release 真机目标；所有日志保存在 `/tmp/wrist-journal-validation/`。
- [x] 运行既有五个真实模拟器场景，新增存储／云失败保留／本地 HTTPS 场景。HTTPS 使用导出的测试证书验证，不把跳过 TLS 校验当成通过。
- [x] 外部 Python 对模拟器服务执行：无鉴权 401、错误 Host 拒绝、已鉴权列表、ticket 下载内容一致、ticket 重放失败、有效操作延长、无效请求不延长、到期连接关闭。测试会话令牌只在独立 Debug 目录，验证结束删除。
- [x] 将不含凭据的 JSON 结果与必要截图写入 `docs/validation/`，更新 README 与真机验收。明确 Watch 不能直接监听、不能强制 Wi-Fi 路由，以及后台调度的不确定性。
- 交付动作：测试通过后按用户授权 commit 并 push `origin/main`，确认远端哈希与工作区干净。
