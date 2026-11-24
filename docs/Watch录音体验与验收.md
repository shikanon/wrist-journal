# Watch 录音体验与验收

2026-11-23：功能已实现；纯逻辑、编码音频生命周期和原生界面渲染验收通过。**触摸端到端与配对真机体验尚未完成**，本机模拟器环境存在下述限制。

## 使用方式

1. 点首页的大按钮开始，旋转数码表冠不再启动录音。
2. 麦克风获准且 `AVAudioRecorder.record()` 成功后才发开始触觉。默认立即显示黑底静态状态并防误触，不显示持续跳动的计时器或波形。健康权限和精准采集不再延迟开始反馈。
3. 长按 1.5 秒，有进度提示，进入控制面板；再点「停止并保存」。松手过早不应解锁。控制面板显示计时、精准模式状态（启用时）和「锁定屏幕」，5 秒无操作自动锁定。滚动／触摸控制面板会延长时限。
4. 应用失活或进入低亮度状态立即锁定，再抬腕仍锁定。VoiceOver 提供「解锁录音控制」按钮；阅读控制面板期间不按 5 秒自动关闭，放下手腕／离开应用仍会锁定。
5. 「录音与健康 → 录音设置 → 开始后立即锁定」默认开启。关闭后先显示 1 秒开始确认，再自动锁定。
6. 电量不超过 20%（未充电）或可用空间 16–64 MB 时，允许用户查看提示后继续；不足 16 MB 阻止开始。未知电量或空间不伪造提示。
7. 结束先校验音频和写元数据，再发成功触觉。中断、无有效文件分别使用通知、失败触觉。结果卡明确显示「已存手表／等待 iPhone 确认／等待云端确认」，只有收到确认才显示相应完成状态。中断或失败结果持久化到用户关闭或更新结果。

录音会话设置允许系统录音期间触觉，并请求减少铃声／系统提示造成的中断；这是系统偏好，不保证所有声音、中断和触觉行为。应用不能通过公开接口强制关闭硬件屏幕。黑底、防误触和物理熄屏是三个不同状态，后者及实际续航需要真机确认。参考 [Apple 常亮状态指南](https://developer.apple.com/cn/documentation/watchos-apps/designing-your-app-for-the-always-on-state)。

## 本次证据

| 检查 | 结果 | 证据与实际范围 |
| --- | --- | --- |
| 核心数据／处理回归 | 103 项通过 | 保留原有数据处理、存储、健康和清理行为 |
| 新增录音交互状态 | 24 项通过 | 默认锁定、确认时限、普通触摸不能解锁、非活跃／低亮度拒绝解锁、控制超时、交互续期、VoiceOver 策略、旧期限隔离、预检和结果序列化 |
| 录音生命周期 | 通过（合成输入） | 真实 AVFoundation 编码的 4 秒／64,000 frame 文件，正常保存、重复停止、中断通知、孤立录音恢复、缺失文件不报成功、明确关闭结果；未用实际麦克风录制 |
| 冷启动恢复 | 通过 | 杀进程后重新启动，重新加载中断结果与可播放录音 |
| 麦克风拒绝／录音中报告限制／清理 | 通过 | 实际系统拒绝权限路径，独立测试目录 |
| 原生 SwiftUI 渲染与自动回锁 | 通过（注入前台状态） | 编程调用解锁，真实 View 的 5 秒任务回锁；检查首页、控制面板、锁定页、中断卡截图 |
| PhoneUITests／WatchUITests | 编译通过，未执行 XCTest 调度 | 界面用例覆盖表冠不启动、短按和短长按不停止、长按解锁、超时回锁和停止保存 |
| 两端 Release | 不签名编译通过 | Debug fixture 和渲染探针不进入 Release |
| 实际录音／触摸／触觉／熄屏续录 | 未通过本次完整验收 | 等待可交互模拟器或配对真机 |

JSON：[录音生命周期](validation/watch-recording-lifecycle.json)、[冷启动](validation/watch-recording-cold-start.json)、[原生渲染](validation/watch-recording-render.json)。纯逻辑输出：[24 项](validation/recording-experience.txt)。

截图：[首页](validation/watch-recording-home.png)、[黑底锁定](validation/watch-recording-locked.png)、[解锁面板](validation/watch-recording-controls.png)、[中断恢复](validation/watch-recording-recovery.png)、[麦克风拒绝](validation/watch-recording-permission-denied.png)。截图来自实际 watchOS SwiftUI 渲染，**不是点击／长按已经通过的证明**。

## 环境限制

- 现有 CoreSimulator 1171.7 与 Xcode 所需 1174.21 不匹配，XCTest 调度问题沿用此前验证记录。本次没有重试替换系统框架。
- 未找到可运行的 Simulator 图形应用；原生 UI 工具也未能进入 DeviceHub。headless Watch 的 scene 为 inactive。渲染检查仅在 Debug 指定参数下注入 `.active`，再调用解锁路径并等待真实 SwiftUI 回锁任务。生产代码没有绕过前台／低亮度保护。
- 真实 `AVAudioRecorder.record()` 尝试阻塞于模拟器的 `AudioQueueObject::DoIONodeConnect → AQIONodeManager::_FindAQIONode → _os_unfair_lock_lock_slow`；没有生成完成结果。之后的通过证据明确记录 `actualRecorderSaved: false` 和 `syntheticEncodedAudio: true`。没有将合成音频称为麦克风实测。
- 本次状态和生命周期回归不代表真机续航、实际音质、HealthKit、后台硬件触觉或系统来电行为已验证。完整日志及采样位于本机 `/tmp/wrist-journal-validation/recording-*`。

## 复现

先按 README 构建 WatchUITests。`WATCH_UDID` 为已启动的 Watch，`SIMCTL` 为兼容的 simctl，`WATCH_APP` 为 Debug watchsimulator 产品路径。

```sh
swiftc Watch/RecordingExperience.swift Tests/RecordingExperienceRegression.swift -o /tmp/wrist-recording
/tmp/wrist-recording
python3 Tests/RecordingExperienceRegression.py \
  --simctl "$SIMCTL" --watch "$WATCH_UDID" --app "$WATCH_APP" \
  --output /tmp/wrist-recording-results --fixture
python3 Tests/RecordingRenderRegression.py \
  --simctl "$SIMCTL" --watch "$WATCH_UDID" --output /tmp/wrist-recording-results
```

录音生命周期脚本不传 `--fixture` 时使用实际 AVAudioRecorder，应在音频环境正常的模拟器运行。两种模式的证据字段不同。XCTest 界面测试请预先 grant microphone；麦克风拒绝由生命周期脚本末尾单独验证。渲染探针始终是程序解锁，不能替代手势测试。

## 完整体验的剩余验收

| 操作 | 合格条件 |
| --- | --- |
| 首页转动／按下表冠 | 旋转只滚动，按下走系统 Home；均不意外开始录音 |
| 开始录音 | 有权限和空间才成功；震动与实际录音启动一致；立即黑底，开启确认选项时约 1 秒后黑底 |
| 单击、连点、0.5 秒长按、按住后移出 | 不解锁、不结束；进度取消 |
| 持续长按 1.5 秒 | 仅解锁，继续录音；停止保存仍需另一次明确点击 |
| 控制面板停留／滚动 | 无操作约 5 秒回锁；操作延长时限；长按放开的触摸不能落到新出现的停止按钮上 |
| 抬腕、常亮、返回表盘、切应用 | 录音继续（系统允许范围内），回到应用仍锁定；常亮不可直接停止 |
| VoiceOver、大字号、减弱动态效果 | 能找到并操作解锁／停止，正确朗读时长，滚动可达；无需依赖长按或进度动画 |
| Siri、闹钟、接听电话、强退 | 明确停止或继续状态；中断片段可播放，重启仍提示；主动停止后不自启 |
| 低电量、空间临界、断网 | 提醒与阻止逻辑正确，离线保存手表，不虚报传输成功 |
| 5／30／60 分钟、熄屏与续航对照 | 比对回放时长、缺口、震动手感、电量和热状态；记录实测，不推算宣传续航 |

自动续录、Mark、Shortcuts 和 Ultra 操作按钮本次只作为后续借鉴方向，详见 [Auday 功能借鉴](Auday功能借鉴.md)。
