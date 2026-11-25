# 模拟验证证据

2026-11-25 日报正文优先：[日报截图](daily-journal-content.png)使用一条 90 分钟的合成录音档案，首屏显示三个不同话题，录音明细从「录音与来源」打开。三项 iPhone XCTest 验证了日期切换、来源及周月摘录、编辑保存与重启恢复。127 项核心／存储／处理检查和 37 项续录／来源检查通过，iPhone／Watch Release 编译通过。合成回归覆盖单条语音日志的纯文字草稿、Watch 分析流程、手机归档与清理后的引用保留。真实长录音和方舟结果仍待真机验收。

2026-11-25 报告日期栏：iOS 27.0 模拟器实际运行日期栏、日报分析与清理、编辑保存与取消三项 XCTest，均通过。日报、周报、月报均同时显示六格，可直接点更早的一期，空档不会跳走，并可从月报进入周报、在「选日期」打开历史归档及返回最近。123 项核心／存储／处理检查、37 项续录／来源检查通过；iPhone／Watch Release 均编译通过。模拟编辑回归还验证了生成草稿、照片下采样和追加会议后保留编辑版。配对真机验收仍保持开放。

截图使用合成数据：[日报](report-calendar-day.png)、[周报](report-calendar-week.png)、[月报](report-calendar-month.png)、[空档](report-calendar-empty.png)。

2026-11-25 日报首页与编辑：115 项核心／存储／处理检查与 37 项续录／来源检查通过，双端 Release 及 iPhone XCTest 包编译通过。iPhone 模拟回归验证原音清理、备份失败保留，以及两场纪要生成仅含文字的 AI 草稿请求、照片下采样、同日追加会议后保留编辑版和重启后恢复。模型响应为夹具，没有向真实服务发送内容。[日报首页](daily-report-home.png)与[编辑界面](daily-report-editor.png)由原生模拟器渲染。XCTest 触摸用例未运行；系统相册选取、真实方舟请求及配对真机操作列在 README 验收中。

2026-11-24 体验优化：核心、存储和处理共 110 项 Swift 检查、37 项续录与来源检查通过。五项应用内模拟回归及两端处理夹具通过；确认分析后才出现的同日录音不被当次处理，云备份失败仍保留原音。iPhone 模拟器中，录音详情和日报均显示合成会议地点的实际底图与 150 米范围圈，无外跳入口。两端 Release 与 XCTest 测试包均编译通过；XCTest 未运行，配对同步、真机地图、触摸及真实健康读取仍在 [README 真机验收 TODO](../../README.md#真机验收-todoopen)。

2026-11-23 连续录音与来源回顾更新：

- [37 项新特性回归](continuity/continuity-regression.txt)，加上 [103 项核心回归](continuity/core-regression.txt)与 [24 项交互状态回归](continuity/recording-experience.txt)，累计 164 项。
- [Watch 生命周期](continuity/watch-recording-lifecycle.json)：标记持久化与重复点击合并；默认不续录；开启后关联新文件；用户取消、开关关闭、系统拒绝及删除片段均取消恢复；重复结束通知和主动停止不重启。
- [冷启动](continuity/watch-recording-cold-start.json)：恢复持久提示，清除过期的等待文案，不启动麦克风。
- [Watch 分析](continuity/watch-processing.json)与 [Phone 归档](continuity/phone-processing.json)：转写原文与标记随结果保存，支持“保留原音”及关闭后清理，清理后引用继续可读。
- [健康更新](continuity/phone-incremental-power.json)：迟到健康数据重新关联时保留原文、标记、空档，已完成日期不重写。
- [Watch 渲染](continuity/watch-recording-render.json)及[控制面板截图](continuity/watch-recording-controls.png)：标记、停止、锁定按钮及 5 秒回锁；[Phone 来源渲染](continuity/phone-source-render.json)及[截图](continuity/phone-source-review.png)：原文摘录、时间范围与原音已清理状态。

两端模拟器测试包与 Release 真机目标通过编译。Watch 生命周期使用合成编码音频，引用来自模型 fixture，结果由脚本交付；渲染为程序打开的原生 SwiftUI 页面。以上不代表真实录音、转写准确性、电话/Siri 中断、触摸或配对传输已通过真机测试。完整功能与边界见[连续录音、标记与来源回顾](../连续录音标记与来源回顾.md)。

2026-11-23 录音体验更新：新增 [24 项状态回归](recording-experience.txt)、[保存／中断／损坏恢复](watch-recording-lifecycle.json)、[冷启动结果恢复](watch-recording-cold-start.json)、[原生 SwiftUI 渲染及回锁](watch-recording-render.json)。原有 103 项核心回归再次通过，两端测试包及 Release 编译通过。生命周期使用真实编码的合成音频，渲染使用 Debug 前台状态和程序解锁；**不代表麦克风录制或触摸手势实测**。完整边界与待补验项见 [Watch 录音体验与验收](../Watch录音体验与验收.md)。

新增截图：[首页](watch-recording-home.png)、[锁定](watch-recording-locked.png)、[控制面板](watch-recording-controls.png)、[中断恢复](watch-recording-recovery.png)、[拒绝麦克风](watch-recording-permission-denied.png)。

2026-11-22，Xcode 27.2。103 项纯 Swift 回归通过，八组应用内场景在独立 iOS 27.0／watchOS 27.2 模拟器中运行并通过。

- [`phone-daily-cleanup.json`](phone-daily-cleanup.json)：日报、位置和心率事件保留，原音已清理；额外损坏录音仍保留。
- [`phone-restart-review.json`](phone-restart-review.json)：应用重启后偏好、日报、事件和清理结果仍可读。
- [`phone-backup-failure.json`](phone-backup-failure.json)：备份失败时原音保留；冷却期不重复请求；旧版日报缺备份清单字段时仍尝试备份。`damagedDayRetained: false` 表示这个场景未执行损坏录音检查，该检查在第一个场景执行；清理场景的备份专用字段为 `false` 同理。
- [`watch-permission-and-purge.json`](watch-permission-and-purge.json)：麦克风拒绝、录音期间报告限制及手表清理路径。
- [`phone-incremental-power.json`](phone-incremental-power.json)：AVFoundation 实际编码和回读；25 秒音频跳过 19 秒静音，后一段保留源时间偏移 21.5 秒；3.5 秒 M4A 27,245 字节，对照 WAV 116,096 字节。还验证全静音零请求、完成日期复用、健康迟到／删除修正、无有效 Key 的本地健康处理，以及旧队列策略。
- [`core-regression.txt`](core-regression.txt)：核心回归的实际输出。
- [`watch-processing.json`](watch-processing.json)：Watch 真正执行 AVFoundation 编码、分段与 Ark 请求构造；Debug 返回一次 401 后从持久化检查点继续，合计 3 次 fixture 请求，实际 M4A 音频 27,619 字节；验证原始时间映射及结果 outbox／ACK 重启恢复。
- [`phone-processing.json`](phone-processing.json)：导入上述 Watch 序列化结果，在只有元数据的情况下归档；重复结果去重，手机模型请求为 0。不处理模式拦截手动／自动及每次请求入口，并暂停已提交日报的清理；JSON 元数据可导出。
- [`storage-and-https.json`](storage-and-https.json)：存储迁移使用 Debug 本地云 fixture；验证失败保留、确认释放、导入幂等、健康排除、迟到云会议合并已清理日期。HTTPS 使用实际 Network.framework TLS 连接，验证指定证书／IP、无授权 401、Host 拒绝、票据重放 403、196,731 字节下载哈希一致、有效操作延长及无效请求不续期、到期服务关闭。正式服务限 Wi-Fi；测试限 loopback、8 秒超时。

截图为合成数据的应用界面：[日回顾](phone-daily-cleanup.png)、[重启后的回顾](phone-restart-review.png)、[增量回归](phone-incremental-power.png)、[手表回归](watch-permission-and-purge.png)。语音结果和健康样本使用 Debug 合成输入，云失败由代码注入；没有使用用户真实录音、健康信息或云端账号。短片段编码节省约 76.5%，不代表真机续航或语音识别质量。模型 HTTP 响应由 fixture 提供，Watch→Phone 测试结果由脚本交付，不等于 WatchConnectivity 已通过配对真机验收。

两端模拟器 App／XCTest 包及 Release 真机目标已编译通过。XCTest 界面用例未实际调度运行，原因和另一台电脑的补验步骤见[性能与真机验收](../性能省电与真机验收.md)。

新增设置截图见 [`storage-and-https.png`](storage-and-https.png)。HTTPS 回归也覆盖元数据未鉴权 401、鉴权后下载和敏感配置排除。没有提交会话凭证、私钥或真实用户录音。真实 CloudKit 账号／索引、Watch 网络路径、首次 Key 同步与离线配置传播、Mac 浏览器信任操作、手机本地网络权限与续航仍需真机验证。处理模式的补验步骤见[数据处理模式](../数据处理模式.md)。
