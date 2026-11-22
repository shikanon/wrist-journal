# 模拟验证证据

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
