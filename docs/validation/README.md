# 模拟验证证据

2026-11-22，Xcode 27.2。60 项纯 Swift 回归通过，五组应用内回归均在独立 iOS 27.0／watchOS 27.2 模拟器中运行并通过。

- [`phone-daily-cleanup.json`](phone-daily-cleanup.json)：日报、位置和心率事件保留，原音已清理；额外损坏录音仍保留。
- [`phone-restart-review.json`](phone-restart-review.json)：应用重启后偏好、日报、事件和清理结果仍可读。
- [`phone-backup-failure.json`](phone-backup-failure.json)：备份失败时原音保留；冷却期不重复请求；旧版日报缺备份清单字段时仍尝试备份。`damagedDayRetained: false` 表示这个场景未执行损坏录音检查，该检查在第一个场景执行；清理场景的备份专用字段为 `false` 同理。
- [`watch-permission-and-purge.json`](watch-permission-and-purge.json)：麦克风拒绝、录音期间报告限制及手表清理路径。
- [`phone-incremental-power.json`](phone-incremental-power.json)：AVFoundation 实际编码和回读；25 秒音频跳过 19 秒静音，后一段保留源时间偏移 21.5 秒；3.5 秒 M4A 27,245 字节，对照 WAV 116,096 字节。还验证全静音零请求、完成日期复用、健康迟到／删除修正、无有效 Key 的本地健康处理，以及旧队列策略。
- [`core-regression.txt`](core-regression.txt)：核心回归的实际输出。

截图为合成数据的应用界面：[日回顾](phone-daily-cleanup.png)、[重启后的回顾](phone-restart-review.png)、[增量回归](phone-incremental-power.png)、[手表回归](watch-permission-and-purge.png)。语音结果和健康样本使用 Debug 合成输入，云失败由代码注入；没有使用用户真实录音、健康信息或云端账号。短片段编码节省约 76.5%，不代表真机续航或语音识别质量。

两端模拟器 App／XCTest 包及 Release 真机目标已编译通过。XCTest 界面用例未实际调度运行，原因和另一台电脑的补验步骤见[性能与真机验收](../性能省电与真机验收.md)。
