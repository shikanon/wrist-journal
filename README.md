# 手记 · WristJournal

用 Apple Watch 随手录音，在同一台手表上生成健康报告。打开配对 iPhone 的手记即可接收选定内容、回听和导出。录音与健康统计均可离线完成。

## 使用

1. 在 Apple Watch 打开「手记」，点「开始录音」并允许使用麦克风。录音会话持续到你停止、系统中断或设备无法继续录制。点「停止并保存」，可以回听、添备注或删除。
2. 在手表打开「健康报告」，点「生成近 7 天报告」并授权健康数据读取。报告按手表时区汇总今天和之前六个日历日的心率、静息心率、SDNN 心率变异性、步数与活动能量。
3. 首次传输前在配对 iPhone 打开「手记」。在手表的录音详情或报告页点「发送到 iPhone」。系统会排队传输。
4. 在 iPhone 打开录音详情可定位播放位置并导出标准 M4A。录音列表可导出 CSV 索引。健康页可以查看每日趋势，并将 HTML 报告或数据 CSV 存到「文件」。

## 数据如何处理

- 手表使用 AVFoundation 录制单声道 AAC 音频，文件和备注保存在应用本地目录。后台音频模式允许已开始的会话在切到表盘时继续。系统中断时应用尝试保留可播放的部分，强制退出或掉电可能令当前文件无法播放。
- 报告读取手表上已有的 HealthKit 样本。步数与活动能量使用 HealthKit 的累积统计，其他指标用可用样本计算均值、最小值、最大值和样本数。跨日均值按样本数加权。当天结果截至生成时间。缺失数据在界面标为「无数据」，在 CSV 中为空。心率采样频率由系统决定。
- 应用使用系统框架在设备上运行，启动无需登录。录音和报告保存在本机，用户在手表点发送时才通过 Watch Connectivity 传给配对 iPhone。两端的本地目录均排除系统备份。导出目的地由用户在系统面板中选择。
- 手表和手机分别保留各自的副本。手表备注修改后，再次发送同一段录音即可刷新手机中的备注。删除报告只移除手记保存的报告文件。

## 从源码运行

- 手表最低需要 watchOS 10，配对应用最低需要 iOS 17。使用 Xcode 16 或更新版本打开 `WristJournal.xcodeproj`，无需安装包依赖。
- 在 `WristJournal` 和 `WristJournalWatch` 的 **Signing & Capabilities** 中选择同一个开发团队。真机签名需要能为手表 target 配置 HealthKit 的开发团队。若需更换 Bundle ID，手表 ID 应使用 iPhone ID 加 `.watchkitapp`，并同步修改手表的 `INFOPLIST_KEY_WKCompanionAppBundleIdentifier`。
- 运行 `WristJournal` scheme 安装 iPhone 应用及其嵌入的手表应用。也可以从 `WristJournalWatch` scheme 直接运行手表应用。

在 Mac 上编译两个真机目标：

```sh
xcodebuild -project WristJournal.xcodeproj -scheme WristJournal \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

## 真机验收

1. 关闭 iPhone 和手表的 Wi-Fi 与蜂窝数据，保留配对蓝牙。使用手表录制，放下手腕并按表冠返回表盘，等待后再进入应用停止，回放确认后台时段有音频。
2. 检查较长录音的时长及回放，在录制期间触发系统音频中断，确认可播放部分显示为中断录音。
3. 在离线状态下生成报告，核对 HealthKit 授权、没有样本的日期和当前日汇总。重新打开应用查看已保存的录音和报告。
4. 给同一录音重复发送并更新备注。确认 iPhone 只保留一条记录，能回听导出原音，并能在离线状态用文件应用打开 HTML 和 CSV。

相关 Apple 文档包括 [watchOS 后台会话](https://developer.apple.com/documentation/watchkit/enabling-background-sessions) · [HealthKit 授权](https://developer.apple.com/documentation/healthkit/authorizing-access-to-health-data) · [Watch Connectivity 文件传输](https://developer.apple.com/documentation/watchconnectivity/wcsession/transferfile(_:metadata:))
