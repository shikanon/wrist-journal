# 手记 · WristJournal

用 Apple Watch 随手录音，在 iPhone 同步、回听和生成会议纪要。录音与健康统计可以离线完成，会议分析使用火山方舟。

## 使用

1. 在 Apple Watch 的「手记」首页转动数码表冠，或点「开始录音」。首次录音需允许使用麦克风。开始后可放下手腕或切回表盘，结束时回到手记点「停止并保存」。表冠按压和侧键仍由 watchOS 处理。
2. 在 iPhone 的「录音」页点「同步手表录音」。手表暂时不可达时，系统会排队。同一条录音只导入一次。录音详情支持回听和导出 M4A，录音列表支持导出 CSV 索引。
3. 在录音详情点「分析录音」，确认后异步生成会议纪要。iPhone 会逐段上传，保存进度与结果。可以离开录音详情，重新打开 App 后会继续等待中的分析。
4. 如需记录大致地点，在手表「录音与健康」打开「记录会议地点」并授权。在 iPhone 设置开启「分析时使用会议背景」后，分析可使用地点及健康 App 已同步的会议时段心率汇总。
5. 在手表「录音与健康 → 健康报告」仍可生成近 7 天报告并选择发送。iPhone 的健康页支持查看每日趋势、导出 HTML 和 CSV。

## 数据如何处理

- 手表使用 AVFoundation 录制 16 kHz、32 kbps 单声道 AAC，持续写入文件。后台音频模式允许已开始的会话在熄屏或切回表盘时继续。系统中断时应用尝试保留可播放部分，强制退出或掉电可能令当前文件无法播放。
- iPhone 的「设置 → 录音存储」支持自动、保留在手表、优先存到 iPhone。自动模式在开始录音时检查手表容量，可用空间低于一半时选择 iPhone。手表先写入本地暂存，iPhone 确认入库后才移除手表副本。两台设备不在附近时，暂存会保留。
- 报告读取手表上已有的 HealthKit 样本。步数与活动能量使用 HealthKit 的累积统计，其他指标用可用样本计算均值、最小值、最大值和样本数。跨日均值按样本数加权。当天结果截至生成时间。缺失数据在界面标为「无数据」，在 CSV 中为空。心率采样频率由系统决定。
- 录音及报告通过 Watch Connectivity 在配对设备间传输。两端的本地目录均排除系统备份。选择保留在手表时，两端分别保留各自的副本。手表备注修改后，可在录音详情再次发送以刷新手机上的备注。删除健康报告只移除手记保存的报告文件。
- 会议分析需在 iPhone 确认上传，录音分段转换为 WAV 后调用方舟 Chat Completions，再将各段摘要汇总成会议纪要。开启会议背景时，只附带粗略地点和已有的心率汇总。手表在录音期间只获取一次位置，心率使用健康 App 中已有的样本。
- 个人方舟 Key 在 iPhone 设置中填写，保存在设备钥匙串。官方 Key 可由管理配置项 `ArkAPIKey` 提供，或在 Debug 启动时通过环境变量 `WRIST_JOURNAL_ARK_DEFAULT` 写入钥匙串。默认模型为 `doubao-seed-2-1-lite-260915`，可在设置中更换模型或接入点 ID。

## 从源码运行

- 手表最低需要 watchOS 10，配对应用最低需要 iOS 17。使用 Xcode 16 或更新版本打开 `WristJournal.xcodeproj`，无需安装包依赖。
- 在 `WristJournal` 和 `WristJournalWatch` 的 **Signing & Capabilities** 中选择同一个开发团队，并为两个 target 配置 HealthKit。若需更换 Bundle ID，手表 ID 应使用 iPhone ID 加 `.watchkitapp`，并同步修改手表的 `INFOPLIST_KEY_WKCompanionAppBundleIdentifier`。
- 运行 `WristJournal` scheme 安装 iPhone 应用及其嵌入的手表应用。也可以从 `WristJournalWatch` scheme 直接运行手表应用。

在 Mac 上编译两个真机目标：

```sh
xcodebuild -project WristJournal.xcodeproj -scheme WristJournal \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

## 模拟器回归

先在 Xcode 的 Components 安装 iOS 和 watchOS 模拟器运行时。使用 `PhoneUITests` scheme 检查同步入口、分析设置和偏好持久化。使用 `WatchUITests` scheme 检查手表资料页及转动表冠后的录音权限提示。手表用例要求先在测试模拟器安装 App，并拒绝麦克风权限，可使用 `xcrun simctl privacy <watch-simulator-id> revoke microphone io.github.shikanon.wristjournal.watchkitapp` 设置该前置条件。

Watch Connectivity 的文件传输和熄屏录音在下一步用配对真机验收。方舟分析可使用合成音频及本机钥匙串里的开发凭据单独测试。[Apple Watch Connectivity 说明](https://developer.apple.com/documentation/watchconnectivity/wcsession/transferfile(_:metadata:))

## 真机验收

1. 关闭 iPhone 和手表的 Wi-Fi 与蜂窝数据，保留配对蓝牙。使用手表录制，放下手腕并按表冠返回表盘，等待后再进入应用停止，回放确认后台时段有音频。
2. 检查较长录音的时长及回放，在录制期间触发系统音频中断，确认可播放部分显示为中断录音。
3. 在离线状态下生成报告，核对 HealthKit 授权、没有样本的日期和当前日汇总。重新打开应用查看已保存的录音和报告。
4. 在 iPhone 发起同步两次，确认每段录音只出现一次。将存储设为「优先存到 iPhone」后录制，确认 iPhone 收到文件以后手表才清理副本。再检查手机回听、M4A 导出和离线打开健康报告。
5. 录制长于两分钟的测试样本，在 iPhone 启动分析，检查分段进度、失败重试和最终纪要。另验收地点授权和已有心率样本对会议背景的影响。

相关 Apple 文档包括 [watchOS 后台会话](https://developer.apple.com/documentation/watchkit/enabling-background-sessions) · [HealthKit 授权](https://developer.apple.com/documentation/healthkit/authorizing-access-to-health-data) · [Watch Connectivity 文件传输](https://developer.apple.com/documentation/watchconnectivity/wcsession/transferfile(_:metadata:))
