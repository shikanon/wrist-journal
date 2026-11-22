# 手记 · WristJournal

Apple Watch 录音并记录每次会议的大致地点，iPhone 生成语音与健康日报，以及周／月回顾。录音与健康读取可离线完成，语音分析使用火山方舟，原音可选择备份到私人 iCloud。

## 使用

1. 在手表首页转动数码表冠，或点「开始录音」。允许麦克风权限后，开始录音可放下手腕或切回表盘，结束时回到手记停止并保存。系统中断会尽量保存可播放部分。
2. 在手表「录音与健康」开启「记录会议地点」。每段录音记录当时时区，并在开始时获取一次粗略位置；15 秒无结果、停止录音或关闭设置都会取消定位。
3. 在 iPhone 设置选择「优先手表」「优先手机」「优先云端」，默认优先手表。手表模式等待手机定期拉取结束日期；手机模式默认每 60 分钟批量发送，确认入库后释放手表副本；云端模式确认私人 iCloud 保存后释放手表原音，再由手机读取分析。设置对后续录音生效，实际后台时机由系统决定。手机「录音」页可主动同步、回听和导出。
4. 在 iPhone 设置配置方舟 Key。进入「回顾」点「分析已结束日期」，确认上传后分析；也可开启「自动每日分析」。自动任务默认只在充电、非低电量模式且设备未过热时运行，并仅使用 Wi-Fi 上传。失败请求保存重试冷却，Key 无效时等待配置变化。
5. 开启「读取健康与运动数据」并完成 HealthKit 授权。默认使用系统采样；可选择「精准模式」，在录音期间以约 10 Hz 主动采集手腕运动并监听新增心率，结束即停止。**普通会议的心率频率仍由 watchOS 控制**，精准模式不启动虚构训练，也不保证连续心率。
6. 日报保留会议纪要、每段地点、健康统计与心率／语音时间重合事件。「每周」「每月」复用日报，不再上传录音；「健康」页可导出日统计。
7. Mac 下载：手机设置 →「Mac 临时下载」，先同步录音，再开启。两台设备连接同一 Wi-Fi，Mac 打开手机给出的完整 HTTPS 网址，核对证书 SHA-256 指纹后允许本次连接。默认 10 分钟无有效操作自动关闭，可设 1–60 分钟；手机进入后台、Wi-Fi 变化或手动关闭也会停止。

watchOS 普通应用不支持此类局域网网页监听，因此 **Mac 下载需要 iPhone 中转**。手表云端上传使用 CloudKit 并禁止蜂窝请求，但 Apple 决定使用配对手机代理还是手表网络，无法强制直连手表自身 Wi-Fi。脱离手机时需已知可用的 Wi-Fi。详见[存储模式与连接限制](docs/存储模式与本地下载.md)。

## 原始数据与备份

- 手表录制 16 kHz、32 kbps、单声道 AAC，约 14.4 MB/小时，不开启实时音量计。定位不是连续追踪。
- 日报原子保存后，删除两端应用内的原音，保留摘要、地点及清理标记。今日、不完整录音、语音失败或健康查询出错时不清理；清理中断后可重试，迟到的同 ID 录音不会复活。
- 手表／手机模式的「云端备份原始录音」默认关闭；云端模式自带备份授权，选择即允许将录音与地点存入私人 iCloud。云端上传确认与日报最终清理分别记录；云端保留原音，健康窗口不上传。切换存储模式只影响后续录音，已有云端录音仍继续同步。存储同步不会自动开启方舟分析。
- 心率数值和步数原始样本在内存中用于本地关联；本地持久化查询锚点、样本 UUID／时间索引、手腕运动窗口和日报结果，用于增量更新与删除补偿。这些健康资料不写入 iCloud，也不删除系统健康库中的数据。本地目录排除系统备份。
- 激动说话前 5 分钟至少 3 个非运动心率样本才建立基线。默认同时达到 110 bpm、较基线上升 25 bpm 才记录重合，阈值可调；伴随运动单独标记。录音里的发言者不一定是佩戴者，结果用于回顾，不能证明因果或诊断疾病。系统采样可能遗漏变化。
- 会议按开始时的当地日期归档，跨午夜仍读取完整会议时段的心率。健康日统计使用首次设置时保存的固定时区；同一健康日的周／月累计只计算一次，避免差旅中更换时区造成重复统计。
- 默认模型已核实支持 M4A，按最多两分钟／4 MiB 解码负载分段上传压缩音频；完整短 M4A 直接复用文件，裁剪片段编码为 AAC。未知自定义模型自动使用 WAV，也可在设置中选择格式。上传仍有 Base64 开销。
- 手机仅跳过至少 8 秒、低于保守能量阈值的明确静音，边缘留半秒缓冲；不确定声音保留。分段保存原始 frame 范围，心率关联保持原始时间映射。全静音可在本地完成；静音检测可关闭。
- 日任务只恢复索引中的未完成工作，完成清理不重复写标记；录音／日报历史分页加载。健康统计无网络也可运行，新增或删除样本只更新受影响日期，保留的语音窗口允许原音清理后补算关联。
- 手机只补发尚未收到手表确认的清理通知。手表录音期间暂停自动大文件队列，可选仅充电时集中传输；实际后台执行仍由系统安排。个人 Key 存在 iPhone 钥匙串。

## 从源码运行

最低 iOS 17／watchOS 10，使用 Xcode 16 或更新版本打开 `WristJournal.xcodeproj`，无需包依赖。

为手机和手表选择同一个开发团队并配置 HealthKit。云端功能需在两个 target 开启 iCloud／CloudKit，并使用同一个私人容器。默认容器 `iCloud.io.github.shikanon.wristjournal` 必须同时出现在两端的 `Info.plist` 与 entitlements 中。`JournalAudio.pendingAnalysis`（Int64）需设为 Queryable 并部署 schema；更换 Bundle ID 时同步修改手表 companion ID、容器 ID 和签名配置。详见[存储部署步骤](docs/存储模式与本地下载.md)及[真机验收与性能方案](docs/性能省电与真机验收.md)。

官方 Key 可由管理配置 `ArkAPIKey` 提供，或在 Debug 通过环境变量 `WRIST_JOURNAL_ARK_DEFAULT` 写入。默认模型 `doubao-seed-2-1-lite-260915`，也可配置模型或接入点 ID。仓库不包含密钥。

```sh
xcodebuild -project WristJournal.xcodeproj -scheme WristJournal \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

## 模拟验证

纯 Swift 回归：

```sh
swiftc Shared/Models.swift Shared/DailyInsights.swift Shared/WorkPolicy.swift Shared/StoragePolicy.swift Shared/JournalStore.swift \
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

新增存储与 HTTPS 模拟验证：

```sh
python3 Tests/LocalDownloadRegression.py \
  --simctl "$(xcrun -f simctl)" --phone <phone-udid> \
  --app /tmp/wj-phone/Build/Products/Debug-iphonesimulator/WristJournal.app \
  --output /tmp/wj-results
```

84 项核心回归与六组模拟器场景已通过。原五组覆盖日报清理、重启、失败冷却、手表权限、压缩静音及增量健康；新增场景覆盖云失败保留、确认释放、重复导入、迟到混合日期、真实 HTTPS 证书校验、鉴权、一次性下载、内容一致及空闲关闭。使用独立 Debug 目录和合成输入；云传输由本地 fixture 替代，HTTPS 是实际 Network.framework 连接，不访问方舟或真实云账号。结果见 [验证记录](docs/validation)。

Xcode 环境完整时，可另外运行 `PhoneUITests`／`WatchUITests` 的 XCTest 界面测试。手表用例要求先安装应用并拒绝麦克风。当前机器已运行上述应用内模拟回归；XCTest 界面测试包已编译，但其调度被 CoreSimulator 版本不匹配阻塞，不能视为界面用例已运行。

真实定位、HealthKit 采样、熄屏录音、两端离线批量传输、CloudKit 账号及索引、Mac 浏览器的证书信任操作、Wi-Fi 后台行为和实际续航由配对真机验收。
