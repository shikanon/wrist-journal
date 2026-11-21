# 手记 · WristJournal

Apple Watch 录音并记录每次会议的大致地点，iPhone 生成语音与健康日报，以及周／月回顾。录音与健康读取可离线完成，语音分析使用火山方舟，原音可选择备份到私人 iCloud。

## 使用

1. 在手表首页转动数码表冠，或点「开始录音」。允许麦克风权限后，开始录音可放下手腕或切回表盘，结束时回到手记停止并保存。系统中断会尽量保存可播放部分。
2. 在手表「录音与健康」开启「记录会议地点」。每段录音记录当时时区，并在开始时获取一次粗略位置；15 秒无结果、停止录音或关闭设置都会取消定位。
3. 自动存储优先交给 iPhone。手表离线时先暂存，手机确认入库后才清理手表副本；也可选「保留在手表」。手机「录音」页可主动同步、回听和导出。
4. 在 iPhone 设置配置方舟 Key。进入「回顾」点「分析已结束日期」，确认上传后分析；也可显式开启「自动每日分析」。默认只在充电、非低电量模式且设备未过热时自动处理。
5. 开启「读取健康与运动数据」并完成 HealthKit 授权。应用读取系统已有的心率、静息心率、SDNN、步数、活动能量及运动时段。请先同步手表和健康数据，再分析。
6. 日报保留会议纪要、每段地点、健康统计与心率／语音时间重合事件。「每周」「每月」复用日报，不再上传录音；「健康」页可导出日统计。

## 原始数据与备份

- 手表录制 16 kHz、32 kbps、单声道 AAC，约 14.4 MB/小时，不开启实时音量计。定位不是连续追踪。
- 日报原子保存后，删除两端应用内的原音，保留摘要、地点及清理标记。今日、不完整录音、语音失败或健康查询出错时不清理；清理中断后可重试，迟到的同 ID 录音不会复活。
- 「云端备份原始录音」默认关闭。开启后，先把原音与位置元数据备份到 CloudKit 私有数据库；备份确认成功后再清理本地副本。失败时保留原音。关闭备份后，不再上传等待中的备份；可以重新开启重试，或明确手动删除原音。
- 应用读取的健康原始样本只在内存中用于本地关联，不写入 iCloud，也不删除系统健康库中的数据。本地目录排除系统备份。
- 激动说话前 5 分钟至少 3 个非运动心率样本才建立基线。默认同时达到 110 bpm、较基线上升 25 bpm 才记录重合，阈值可调；伴随运动单独标记。录音里的发言者不一定是佩戴者，结果用于回顾，不能证明因果或诊断疾病。系统采样可能遗漏变化。
- 会议按开始时的当地日期归档，跨午夜仍读取完整会议时段的心率。健康日统计使用首次设置时保存的固定时区；同一健康日的周／月累计只计算一次，避免差旅中更换时区造成重复统计。
- 语音按最多两分钟／4 MiB PCM 负载分段转换为 WAV 并串行请求。分段结果保存检查点，失败重试复用已完成分段；日报完成后收缩分段笔记。个人 Key 存在 iPhone 钥匙串。

## 从源码运行

最低 iOS 17／watchOS 10，使用 Xcode 16 或更新版本打开 `WristJournal.xcodeproj`，无需包依赖。

为手机和手表选择同一个开发团队并配置 HealthKit。云备份还需在手机 target 开启 iCloud／CloudKit，创建自己的私有容器。默认容器 `iCloud.io.github.shikanon.wristjournal` 必须同时出现在 `Phone/Info.plist` 与手机 entitlements 中；更换 Bundle ID 时同步修改手表 companion ID、容器 ID 和签名配置。详见[真机验收与性能方案](docs/性能省电与真机验收.md)。

官方 Key 可由管理配置 `ArkAPIKey` 提供，或在 Debug 通过环境变量 `WRIST_JOURNAL_ARK_DEFAULT` 写入。默认模型 `doubao-seed-2-1-lite-260915`，也可配置模型或接入点 ID。仓库不包含密钥。

```sh
xcodebuild -project WristJournal.xcodeproj -scheme WristJournal \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

## 模拟验证

纯 Swift 回归：

```sh
swiftc Shared/Models.swift Shared/DailyInsights.swift Shared/JournalStore.swift \
  Tests/CoreRegression.swift -o /tmp/wrist-journal-core
/tmp/wrist-journal-core
```

在已经启动的独立 iOS／watchOS 模拟器上运行应用内回归：

```sh
xcodebuild -project WristJournal.xcodeproj -scheme PhoneUITests \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/wj-phone \
  CODE_SIGNING_ALLOWED=NO build-for-testing
xcodebuild -project WristJournal.xcodeproj -scheme WatchUITests \
  -destination 'generic/platform=watchOS Simulator' -derivedDataPath /tmp/wj-watch \
  CODE_SIGNING_ALLOWED=NO build-for-testing
python3 Tests/SimulatorRegression.py \
  --simctl "$(xcrun -f simctl)" --phone <phone-udid> --watch <watch-udid> \
  --phone-app /tmp/wj-phone/Build/Products/Debug-iphonesimulator/WristJournal.app \
  --watch-app /tmp/wj-watch/Build/Products/Debug-watchsimulator/WristJournalWatch.app \
  --output /tmp/wj-results
```

四个场景使用独立 Debug 存储目录和合成输入，验证真实应用内的日报关联、清理、损坏日期保留、重启后偏好与回顾持久化、备份失败以及手表权限／清理路径。不会访问方舟或实际上传云备份。结果见 [验证记录](docs/validation)。

Xcode 环境完整时，可另外运行 `PhoneUITests`／`WatchUITests` 的 XCTest 界面测试。手表用例要求先安装应用并拒绝麦克风。当前机器已运行上述应用内模拟回归；XCTest 界面测试包已编译，但其调度被 CoreSimulator 版本不匹配阻塞，不能视为界面用例已运行。

真实定位、HealthKit 采样、熄屏录音、两端离线传输、CloudKit 成功备份和实际续航由配对真机验收。
