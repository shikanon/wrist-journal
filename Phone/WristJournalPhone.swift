import Charts
import Combine
import SwiftUI
import UniformTypeIdentifiers

@main
struct WristJournalPhone: App {
    @StateObject private var journal: PhoneJournal
    @Environment(\.scenePhase) private var phase
    @State private var tab = 0

    init() {
        let journal = PhoneJournal()
        _journal = StateObject(wrappedValue: journal)
        AnalysisScheduling.register(journal: journal)
        AnalysisScheduling.schedule(settings: journal.dailySettings)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-journal-storage-simulation") { _tab = State(initialValue: 3) }
        if ProcessInfo.processInfo.arguments.contains("-journal-map-preview-detail") { _tab = State(initialValue: 2) }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            TabView(selection: $tab) {
                NavigationStack { DailyReportHome(journal: journal, openRecordings: { tab = 2 }) }
                    .tabItem { Label("日报", systemImage: "doc.text") }
                    .tag(0)
                NavigationStack { PhoneHealth(journal: journal) }
                    .tabItem { Label("健康", systemImage: "heart.text.clipboard") }
                    .tag(1)
                NavigationStack { recordingsRoot }
                    .tabItem { Label("录音", systemImage: "waveform") }
                    .tag(2)
                NavigationStack { JournalSettings(journal: journal) }
                    .tabItem { Label("设置", systemImage: "gearshape") }
                    .tag(3)
            }
            .tint(.teal)
            .modifier(JournalNotice(message: $journal.message))
            .task {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-journal-processing-simulation") { await journal.runProcessingSimulation() }
                if ProcessInfo.processInfo.arguments.contains("-journal-storage-simulation") { await journal.runStorageSimulation() }
                if ProcessInfo.processInfo.arguments.contains("-journal-power-simulation") { await journal.runPowerSimulation() }
                if ProcessInfo.processInfo.arguments.contains("-journal-simulation-run") { await journal.runSimulation() }
                if ProcessInfo.processInfo.arguments.contains("-journal-fixture-verify-restart") { journal.verifySimulationPersistence() }
                if ProcessInfo.processInfo.arguments.contains("-journal-report-edition-simulation") { await journal.runDailyReportEditionSimulation() }
                if ProcessInfo.processInfo.arguments.contains("-journal-report-edition-verify") { journal.verifyDailyReportEditionSimulation() }
                #endif
                journal.foregroundEntered()
            }
            .onChange(of: phase) {
                if phase == .active {
                    journal.foregroundEntered()
                }
                if phase == .background { journal.foregroundExited() }
            }
        }
    }

    @ViewBuilder
    private var recordingsRoot: some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-journal-fixture"),
           ProcessInfo.processInfo.arguments.contains("-journal-map-preview-detail"),
           let entry = journal.recordings.first {
            PhoneRecording(journal: journal, id: entry.id)
        } else {
            PhoneRecordings(journal: journal)
        }
        #else
        PhoneRecordings(journal: journal)
        #endif
    }
}

private struct PhoneRecordings: View {
    @ObservedObject var journal: PhoneJournal
    @State private var exporting = false

    var body: some View {
        Group {
            if journal.recordings.isEmpty {
                List {
                    RecordingSyncCard(journal: journal)
                    ContentUnavailableView("暂无录音", systemImage: "waveform",
                        description: Text("在手表结束录音后，就可以从这里同步。"))
                }
            } else {
                List {
                    RecordingSyncCard(journal: journal)
                    Section("已导入") {
                        LabeledContent(journal.hasMoreRecordings ? "已加载录音" : "录音段数",
                                       value: journal.recordings.count.formatted())
                        LabeledContent(journal.hasMoreRecordings ? "已加载时长" : "总时长",
                                       value: durationText(journal.recordings.reduce(0) { $0 + $1.duration }))
                    }
                    Section("录音") {
                        ForEach(journal.recordings) { entry in
                            NavigationLink {
                                PhoneRecording(journal: journal, id: entry.id)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(entry.title).lineLimit(2)
                                    Text(durationText(entry.duration))
                                        .font(.subheadline.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                    if let job = journal.jobs[entry.id], job.state == .complete {
                                        Text("会议纪要已生成").font(.caption).foregroundStyle(.secondary)
                                    }
                                    if entry.rawDeletedAt != nil {
                                        Text("原音已清理 · 纪要在回顾中保留").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        if journal.hasMoreRecordings {
                            Button("加载更早录音") { journal.loadMoreRecordings() }
                        }
                    }
                }
                .refreshable { journal.syncRecordings() }
            }
        }
        .navigationTitle("录音")
        .toolbar {
            if !journal.recordings.isEmpty {
                Button { exporting = true } label: {
                    Label("导出录音索引", systemImage: "square.and.arrow.up")
                }
            }
        }
        .fileExporter(isPresented: $exporting, document: Export.recordings(journal.recordings, store: journal.store),
                      contentType: .commaSeparatedText, defaultFilename: "WristJournal-Recordings") { result in
            if case .failure(let error) = result { journal.message = error.localizedDescription }
        }
    }
}

private struct RecordingSyncCard: View {
    @ObservedObject var journal: PhoneJournal
    @State private var expanded = false

    var body: some View {
        Section {
            DisclosureGroup(isExpanded: $expanded) {
                LabeledContent("最近收到手表录音",
                               value: journal.lastWatchImport?.formatted(date: .abbreviated, time: .shortened) ?? "暂无确认记录")
                if journal.syncStatus != nil {
                    Text("如果录音迟迟未到，请让两台设备靠近并打开两端 App。系统会安排文件传输。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let status = journal.storageSyncStatus {
                    LabeledContent("iCloud", value: status).font(.footnote)
                }
                if let date = journal.lastCloudSync {
                    LabeledContent("最近完成 iCloud 同步", value: date.formatted(date: .abbreviated, time: .shortened))
                }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Label("同步状态", systemImage: "arrow.triangle.2.circlepath")
                    if let status = journal.syncStatus {
                        Text(status).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            Button("同步手表录音") { journal.syncRecordings() }
        }
    }
}

private struct PhoneRecording: View {
    @ObservedObject var journal: PhoneJournal
    @StateObject private var playback = LocalPlayback()
    @Environment(\.dismiss) private var dismiss
    let id: UUID
    @State private var position: TimeInterval = 0
    @State private var scrubbing = false
    @State private var confirmingDelete = false
    @State private var confirmingAnalysis = false

    var body: some View {
        List {
            if let entry = journal.recordings.first(where: { $0.id == id }) {
                let audio = journal.store.sourceAudio(id)
                Section {
                    Text(JournalDayKey(recording: entry).recordingTime(entry.startedAt, includeDate: true))
                    if entry.state == .interrupted {
                        Text("录音中断，已保存可播放部分。").foregroundStyle(.secondary)
                    }
                    if let continuation = entry.continuation {
                        Text(continuation.detail).foregroundStyle(.orange)
                        if journal.recordings.contains(where: { $0.id == continuation.previousRecordingID }) {
                            NavigationLink("查看中断前一段") {
                                PhoneRecording(journal: journal, id: continuation.previousRecordingID)
                            }
                        }
                    }
                    if !entry.note.isEmpty { Text(entry.note).textSelection(.enabled) }
                    Text(entry.timeZoneIdentifier.map { "录制时区：\($0)" } ?? "旧录音未记录时区 · 按手机当前时区显示")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let url = audio.url {
                    Section("播放") {
                        if let source = playback.source {
                            Label("正在回听 · \(source.detail)", systemImage: "waveform")
                                .font(.subheadline)
                        }
                        VStack {
                            Slider(value: $position, in: 0...max(0, entry.duration)) { editing in
                                scrubbing = editing
                                if !editing { playback.seek(to: position) }
                            }
                            .accessibilityLabel("播放位置")
                            .accessibilityValue(durationText(position))
                            HStack {
                                Text(durationText(position))
                                Spacer()
                                Text(durationText(entry.duration)).foregroundStyle(.secondary)
                            }
                            .font(.caption.monospacedDigit())
                        }
                        Button {
                            if playback.playing {
                                position = playback.position
                                playback.stop()
                            } else {
                                if position >= entry.duration { position = 0 }
                                do { try playback.play(url, startingAt: position) }
                                catch { journal.message = error.localizedDescription }
                            }
                        } label: {
                            Label(playback.playing ? "暂停" : "播放", systemImage: playback.playing ? "pause.fill" : "play.fill")
                        }
                    }
                    ShareLink(item: url) { Label("导出 M4A", systemImage: "square.and.arrow.up") }
                } else {
                    Section("原音") {
                        if entry.state == .damaged {
                            Label("录音文件不完整，无法播放。", systemImage: "exclamationmark.triangle")
                        } else {
                            Label(audio.detail, systemImage: "speaker.slash")
                        }
                    }
                    .foregroundStyle(.secondary)
                }
                Section("会议地点") {
                    MeetingLocationView(location: entry.location)
                }
                meetingAnalysis(entry, hasLocalAudio: audio.url != nil)
                if journal.jobs[id]?.state == .complete || !(entry.markers ?? []).isEmpty {
                    Section("标记与原文引用") {
                        RecordingSourcesView(store: journal.store, recordingID: id, recordingTitle: entry.title,
                            citations: journal.jobs[id]?.citations ?? [], markers: entry.markers ?? [], playback: playback)
                    }
                }
                Button("删除录音", role: .destructive) { confirmingDelete = true }
                    .disabled(journal.processingDays)
                    .confirmationDialog("删除 iPhone 上的录音？", isPresented: $confirmingDelete) {
                        Button("删除", role: .destructive) {
                            playback.stop()
                            if journal.delete(entry) { dismiss() }
                        }
                    }
            }
        }
        .navigationTitle("录音详情")
        .task(id: playback.playing) {
            guard playback.playing else { return }
            while !Task.isCancelled && playback.playing {
                if !scrubbing { position = playback.position }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        .onDisappear { playback.stop() }
    }

    private func meetingAnalysis(_ entry: Recording, hasLocalAudio: Bool) -> some View {
        Section("会议分析") {
            if let job = journal.jobs[id] {
                switch job.state {
                case .queued:
                    if journal.analyzing == id {
                        if job.totalChunks > 0, job.notes.count < job.totalChunks {
                            ProgressView("正在分析第 \(job.notes.count + 1) / \(job.totalChunks) 段",
                                         value: Double(job.notes.count), total: Double(job.totalChunks))
                        } else {
                            ProgressView(job.totalChunks == 0 ? "正在准备录音" : "正在整理会议纪要")
                        }
                    } else {
                        Text("等待分析").foregroundStyle(.secondary)
                    }
                case .failed:
                    Text(job.error ?? "分析失败").foregroundStyle(.secondary)
                case .complete:
                    if let minutes = job.minutes {
                        Text(minutes).textSelection(.enabled)
                        ShareLink(item: ([minutes] + (job.citations ?? []).map(\.shareText)).joined(separator: "\n\n")) {
                            Label("分享纪要与来源", systemImage: "square.and.arrow.up")
                        }
                    }
                }
            }
            if entry.isPlayable, (hasLocalAudio || journal.processingMode == .watch),
               journal.jobs[id]?.state != .queued, journal.processingMode != .none {
                Button(journal.processingMode == .watch ? "在 Watch 上处理" :
                    (journal.jobs[id] == nil ? "分析录音" : "重新分析")) { confirmingAnalysis = true }
                    .disabled(journal.processingDays)
                    .confirmationDialog("发送到火山方舟进行分析？", isPresented: $confirmingAnalysis) {
                        Button("开始分析") { Task { await journal.analyze(entry) } }
                    } message: {
                        Text(journal.includeContext
                             ? "将分段上传这条录音，并附上可用的会议时段心率汇总。"
                             : "将分段上传这条录音。会议纪要会保存在此 iPhone。")
                    }
            }
        }
    }
}

private struct JournalSettings: View {
    @ObservedObject var journal: PhoneJournal

    var body: some View {
        Form {
            Section {
                Picker("数据处理", selection: Binding(
                    get: { journal.processingMode },
                    set: { journal.dailySettings.processingMode = $0 })) {
                    ForEach(ProcessingMode.allCases) { Text($0.title).tag($0) }
                }
                if journal.processingMode == .watch {
                    Text(journal.watchConfigurationStatus).font(.footnote)
                }
                if journal.processingMode == .none { macDownload }
            } footer: {
                Text(journal.processingMode == .none ?
                     "保留原音，不调用模型、不自动生成日报或清理。同步后可在「Mac 临时下载」导出原音和元数据，自行处理。" :
                     journal.processingMode == .watch ?
                     "Watch 使用进阶设置中的方舟配置，结果回传手机归档。首次同步 Key 请同时打开两端 App。录音期间暂停处理，处理完成前保留手表原音。" :
                     "默认由手机调用模型；录音存储位置可独立选择。自动开关关闭时仍可手动处理。")
            }
            Section {
                Picker("录音存储", selection: $journal.storage) {
                    ForEach(RecordingStorage.allCases) { Text($0.title).tag($0) }
                }
            } footer: {
                Text(journal.storage == .cloud ?
                     "新录音和地点备份到私人 iCloud。上传确认且手表不再需要原音后，释放手表副本。健康样本不上传 iCloud。" :
                     journal.storage == .watch ? "新录音优先留在手表；iPhone 定期拉取结束日期的录音。" :
                     "新录音由手表暂存，等 iPhone 确认保存后再释放手表副本。")
            }
            Section {
                if journal.processingMode != .none {
                    Toggle("日报后保留原音", isOn: Binding(
                        get: { journal.dailySettings.keepReviewAudio ?? false },
                        set: { journal.dailySettings.keepReviewAudio = $0 }))
                    Toggle("自动每日分析", isOn: $journal.dailySettings.automatic)
                } else {
                    LabeledContent("原音清理", value: "已暂停")
                }
                if journal.storage == .cloud {
                    LabeledContent("新录音云端备份", value: "已随云端模式开启")
                } else if journal.processingMode != .none {
                    Toggle("云端备份原始录音", isOn: $journal.dailySettings.cloudBackup)
                }
            } header: {
                Text("保留与备份")
            } footer: {
                if journal.processingMode != .none {
                    Text("保留原音才能在本机回听。关闭保留后，日报和所需备份成功才会清理；已清理音频无法恢复。自动分析会将结束日期的待分析录音分段发送到火山方舟。")
                }
            }
            if journal.processingMode != .none { Section { macDownload } }
            Section {
                NavigationLink("进阶设置") { AdvancedJournalSettings(journal: journal) }
            }
            Section {
                Image("BrandLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 210)
                    .clipShape(.rect(cornerRadius: 12))
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("恩名手记")
                    .listRowBackground(Color.clear)
            }
        }
        .disabled(journal.processingDays || journal.readingHealth)
        .navigationTitle("设置")
    }

    private var macDownload: some View {
        NavigationLink {
            LocalDownloadView(journal: journal, server: journal.localDownload)
        } label: {
            Label("Mac 临时下载", systemImage: "laptopcomputer.and.arrow.down")
        }
    }
}

private struct AdvancedJournalSettings: View {
    @ObservedObject var journal: PhoneJournal
    @State private var key = ""

    var body: some View {
        Form {
            if journal.processingMode != .none { analysisOptions }
            Section {
                Toggle("手表仅充电时自动传输", isOn: Binding(
                    get: { journal.dailySettings.transferChargingOnly ?? false },
                    set: { journal.dailySettings.transferChargingOnly = $0 }))
                if journal.storage == .phone {
                    Stepper("批量间隔：\(StoragePolicy.batchMinutes(journal.dailySettings.batchMinutes)) 分钟",
                            value: Binding(get: { StoragePolicy.batchMinutes(journal.dailySettings.batchMinutes) },
                                           set: { journal.dailySettings.batchMinutes = $0 }), in: 15...360, step: 15)
                }
                if journal.processingMode == .none { wifiOnly }
            } header: {
                Text("录音传输")
            } footer: {
                Text("录音期间暂停自动大文件传输，实际后台时机由系统安排。优先云端时，请求禁用蜂窝，系统可能经配对手机转发。")
            }
            if journal.processingMode != .none { healthOptions }
        }
        .disabled(journal.processingDays || journal.readingHealth)
        .navigationTitle("进阶设置")
    }

    private var wifiOnly: some View {
        Toggle("自动上传与云同步仅用 Wi-Fi", isOn: Binding(
            get: { journal.dailySettings.wifiOnly ?? true },
            set: { journal.dailySettings.wifiOnly = $0 }))
    }

    @ViewBuilder
    private var analysisOptions: some View {
            Section("火山方舟") {
                Picker("API Key 来源", selection: $journal.credential) {
                    ForEach(ArkCredential.allCases) { Text($0.title).tag($0) }
                }
                if journal.credential == .official {
                    LabeledContent("官方 Key", value: journal.hasOfficialKey ? "已配置" : "未配置")
                }
                SecureField("输入个人 API Key", text: $key)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("保存个人 Key") {
                    if journal.savePersonalKey(key) { key = "" }
                }
                .disabled(key.isEmpty)
                if journal.hasPersonalKey {
                    Button("移除个人 Key", role: .destructive) { journal.removePersonalKey() }
                }
                TextField("模型 ID 或接入点 ID", text: $journal.model)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Picker("音频上传", selection: Binding(
                    get: { journal.dailySettings.audioFormat ?? .automatic },
                    set: { journal.dailySettings.audioFormat = $0 })) {
                    ForEach(AudioUploadFormat.allCases) { Text($0.title).tag($0) }
                }
            }
            Section {
                Toggle("分析时附加心率汇总", isOn: $journal.includeContext)
            } footer: {
                Text("向分析服务发送会议时段的心率汇总。地点可在手表「录音设置」开启记录。")
            }
            Section {
                Toggle("仅充电时自动分析", isOn: $journal.dailySettings.chargingOnly)
                wifiOnly
                Toggle("跳过明确的长静音", isOn: Binding(
                    get: { journal.dailySettings.skipSilence ?? true },
                    set: { journal.dailySettings.skipSilence = $0 }))
            } header: {
                Text("自动分析条件")
            } footer: {
                Text("后台时机由系统安排，打开 App 可补跑。手动分析不受自动分析条件限制。")
            }
    }

    @ViewBuilder
    private var healthOptions: some View {
            Section {
                Toggle("读取健康与运动数据", isOn: Binding(
                    get: { journal.dailySettings.healthEnabled },
                    set: journal.updateHealthReading))
                Picker("采集模式", selection: Binding(
                    get: { journal.dailySettings.collectionMode ?? .system },
                    set: {
                        journal.dailySettings.collectionMode = $0
                        if $0 == .precise, !journal.dailySettings.healthEnabled { journal.updateHealthReading(enabled: true) }
                    })) {
                    ForEach(CollectionMode.allCases) { Text($0.title).tag($0) }
                }
                LabeledContent("健康统计时区", value: journal.dailySettings.healthTimeZoneIdentifier ?? TimeZone.current.identifier)
            } footer: {
                Text("系统模式读取已有心率与运动数据。精准模式在手表录音期间主动采集更细的手腕运动，并监听新增心率；结束即停止，更耗电。心率采样频率仍由 watchOS 控制，普通会议不会启动训练或保证连续心率。设置同步到手表后，对下一段录音生效。")
            }
            Section {
                Stepper("高心率：\(Int(journal.dailySettings.thresholds.highBPM)) bpm",
                        value: $journal.dailySettings.thresholds.highBPM, in: 80...180, step: 5)
                Stepper("较基线上升：\(Int(journal.dailySettings.thresholds.riseBPM)) bpm",
                        value: $journal.dailySettings.thresholds.riseBPM, in: 10...60, step: 5)
            } header: {
                Text("心率关联阈值")
            } footer: {
                Text("按激动说话前 5 分钟至少 3 个非运动样本建立基线。运动期间的重合单独标记。此功能用于回顾，不能诊断疾病或保证捕捉每次心率变化。")
            }
    }
}

private struct PhoneHealth: View {
    @ObservedObject var journal: PhoneJournal
    @State private var selected: HealthMetric = .heartRate
    @State private var confirmingDelete = false
    @State private var exporting = false
    @State private var exportType: UTType = .commaSeparatedText
    @State private var document: Export?

    private var canReadHere: Bool { journal.processingMode != .none }
    private var isReading: Bool { journal.readingHealth || journal.processingDays }

    var body: some View {
        Group {
            if let report = journal.report, report.days.contains(where: { !$0.metrics.isEmpty }) {
                List {
                    if let error = journal.healthReadError, canReadHere, journal.dailySettings.healthEnabled {
                        Section("更新失败 · 显示上次数据") {
                            Text(error).font(.footnote).foregroundStyle(.secondary)
                            refresh
                        }
                    }
                    Section("近 7 天概况") {
                        ForEach(HealthMetric.allCases) { metric in
                            MetricRow(metric: metric, value: report.summary(metric))
                        }
                        Text("更新于 \(report.generatedAt.formatted(date: .abbreviated, time: .shortened)) · \(report.timeZone)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    HealthTrend(days: report.days, selected: $selected)
                    if !report.unavailableMetrics.isEmpty {
                        Text("读取失败：\(report.unavailableMetrics.map(\.title).joined(separator: "、"))")
                            .foregroundStyle(.secondary)
                        Text("可以在 Watch 重新生成报告并发送到 iPhone。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if !journal.reportIsDaily {
                        Button("删除本机报告", role: .destructive) { confirmingDelete = true }
                            .confirmationDialog("删除 iPhone 上的报告？", isPresented: $confirmingDelete) {
                                Button("删除", role: .destructive) { journal.deleteReport() }
                            }
                    }
                }
                .toolbar {
                    Menu {
                        Button("导出 HTML 报告") { prepareExport(.healthHTML(report), type: .html) }
                        Button("导出健康数据 CSV") { prepareExport(.healthCSV(report), type: .commaSeparatedText) }
                    } label: {
                        Label("导出", systemImage: "square.and.arrow.up")
                    }
                }
            } else {
                emptyHealth
            }
        }
        .navigationTitle("健康")
        .fileExporter(isPresented: $exporting, document: document, contentType: exportType,
                      defaultFilename: "WristJournal-Health") { result in
            document = nil
            if case .failure(let error) = result { journal.message = error.localizedDescription }
        }
    }

    private var emptyHealth: some View {
        let watchImport = "也可在 Watch 的「健康报告」生成报告，再发送到 iPhone。"
        return ContentUnavailableView {
            Label(healthEmptyTitle, systemImage: "heart.text.clipboard")
        } description: {
            if !canReadHere {
                Text("「不处理」模式下不会在手机上生成健康日报。请在 Watch 生成健康报告并发送到 iPhone。")
            } else if !journal.dailySettings.healthEnabled {
                Text("可开启手机读取，查看已结束日期的健康统计。" + watchImport)
            } else if let error = journal.healthReadError {
                Text("\(error) 请检查 iPhone 的「健康」是否有样本，以及恩名手记的读取权限，然后重试。")
            } else if journal.report?.unavailableMetrics.isEmpty == false {
                Text("手表报告未能读取相关指标。请在 Watch 重新生成并发送，或检查 iPhone 的健康数据来源后刷新。")
            } else {
                Text("已结束日期暂无可读样本。请在 iPhone 的「健康」检查数据来源和读取权限，待手表同步后刷新。" + watchImport)
            }
        } actions: {
            if isReading && canReadHere {
                ProgressView("正在更新…")
            } else if canReadHere, !journal.dailySettings.healthEnabled {
                Button("开启健康读取") { journal.updateHealthReading(enabled: true) }
            } else if canReadHere {
                refresh
            }
            if let report = journal.report, !journal.reportIsDaily, !report.days.contains(where: { !$0.metrics.isEmpty }) {
                Button("删除本机报告", role: .destructive) { confirmingDelete = true }
                    .confirmationDialog("删除 iPhone 上的报告？", isPresented: $confirmingDelete) {
                        Button("删除", role: .destructive) { journal.deleteReport() }
                    }
            }
        }
    }

    private var healthEmptyTitle: String {
        if !canReadHere || !journal.dailySettings.healthEnabled { return "暂无健康报告" }
        if isReading { return "正在读取健康数据" }
        if journal.healthReadError != nil || journal.report?.unavailableMetrics.isEmpty == false { return "暂时无法读取健康数据" }
        return "还没有可读样本"
    }

    private var refresh: some View {
        Button(journal.healthReadError == nil ? "刷新健康数据" : "重试健康读取") {
            Task { await journal.refreshHealthFromScreen() }
        }
        .disabled(isReading)
    }

    private func prepareExport(_ file: Export, type: UTType) {
        document = file
        exportType = type
        exporting = true
    }
}

private struct HealthTrend: View {
    let days: [HealthDay]
    @Binding var selected: HealthMetric

    private var chart: some View {
        Chart(days) { day in
            if let measurement = day.metrics[selected] {
                PointMark(x: .value("日期", String(day.localDate.suffix(5))),
                          y: .value(selected.unit, measurement.value))
                    .foregroundStyle(Color.teal)
                    .accessibilityLabel(Text(day.localDate))
                    .accessibilityValue(Text(display(measurement)))
            }
        }
        .chartXScale(domain: days.map { String($0.localDate.suffix(5)) })
        .frame(height: 180)
    }

    var body: some View {
        Section {
            Picker("指标", selection: $selected) {
                ForEach(HealthMetric.allCases) { metric in
                    Text(metric.title).tag(metric)
                }
            }
            if days.contains(where: { $0.metrics[selected] != nil }) {
                chart
            } else {
                Text("暂无\(selected.title)样本。可在 iPhone 的「健康」检查数据来源与同步状态，或切换查看其他指标。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(days.reversed()) { day in
                LabeledContent(day.localDate) {
                    VStack(alignment: .trailing) {
                        let result = day.metrics[selected]
                        Text(result.map(display) ?? "无数据")
                        if let min = result?.minimum, let max = result?.maximum {
                            Text("\(selected.display(min))–\(selected.display(max))"
                                 + (result?.sampleCount.map { " · \($0) 个样本" } ?? ""))
                                .font(.caption)
                        }
                    }
                }
            }
        } header: {
            Text("每日趋势")
        } footer: {
            Text("步数和活动能量为累计值，其余指标为日样本均值，跨日按有数据的日期求均值。当天数据截至手表报告生成时。")
        }
    }

    private func display(_ measurement: Measurement) -> String {
        "\(selected.display(measurement.value)) \(selected.unit)"
    }
}
