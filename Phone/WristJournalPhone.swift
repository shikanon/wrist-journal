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
        if ProcessInfo.processInfo.arguments.contains("-journal-simulation-run") ||
            ProcessInfo.processInfo.arguments.contains("-journal-fixture-verify-restart") { _tab = State(initialValue: 2) }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            TabView(selection: $tab) {
                NavigationStack { PhoneRecordings(journal: journal) }
                    .tabItem { Label("录音", systemImage: "waveform") }
                    .tag(0)
                NavigationStack { PhoneHealth(journal: journal) }
                    .tabItem { Label("健康", systemImage: "heart.text.clipboard") }
                    .tag(1)
                NavigationStack { JournalReviewView(journal: journal) }
                    .tabItem { Label("回顾", systemImage: "calendar") }
                    .tag(2)
                NavigationStack { JournalSettings(journal: journal) }
                    .tabItem { Label("设置", systemImage: "gearshape") }
                    .tag(3)
            }
            .tint(.teal)
            .modifier(JournalNotice(message: $journal.message))
            .task {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-journal-power-simulation") { await journal.runPowerSimulation() }
                if ProcessInfo.processInfo.arguments.contains("-journal-simulation-run") { await journal.runSimulation() }
                if ProcessInfo.processInfo.arguments.contains("-journal-fixture-verify-restart") { journal.verifySimulationPersistence() }
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
}

private struct PhoneRecordings: View {
    @ObservedObject var journal: PhoneJournal
    @State private var exporting = false

    var body: some View {
        Group {
            if journal.recordings.isEmpty {
                ContentUnavailableView {
                    Label("暂无录音", systemImage: "waveform")
                } description: {
                    Text(journal.syncStatus ?? "在手表结束录音后，点这里从手表同步。")
                } actions: {
                    Button("同步手表录音") { journal.syncRecordings() }
                }
            } else {
                List {
                    Section("已导入") {
                        LabeledContent("录音段数", value: journal.recordings.count.formatted())
                        LabeledContent("总时长", value: durationText(journal.recordings.reduce(0) { $0 + $1.duration }))
                        if let status = journal.syncStatus { Text(status).font(.footnote).foregroundStyle(.secondary) }
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
                Button { journal.syncRecordings() } label: {
                    Label("同步手表录音", systemImage: "arrow.triangle.2.circlepath")
                }
                Button { exporting = true } label: {
                    Label("导出录音索引", systemImage: "square.and.arrow.up")
                }
            }
        }
        .fileExporter(isPresented: $exporting, document: Export.recordings(journal.recordings),
                      contentType: .commaSeparatedText, defaultFilename: "WristJournal-Recordings") { result in
            if case .failure(let error) = result { journal.message = error.localizedDescription }
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
                Section {
                    Text(entry.startedAt.formatted(date: .long, time: .shortened))
                    if entry.state == .interrupted {
                        Text("录音中断，已保存可播放部分。").foregroundStyle(.secondary)
                    }
                    if !entry.note.isEmpty { Text(entry.note).textSelection(.enabled) }
                    if let location = entry.location {
                        Text("会议地点（粗略）：\(location.description)").textSelection(.enabled)
                    }
                    if let zone = entry.timeZoneIdentifier { Text(zone).font(.caption).foregroundStyle(.secondary) }
                }
                if entry.isPlayable {
                    Section("播放") {
                    VStack {
                        Slider(value: $position, in: 0...entry.duration) { editing in
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
                            do { try playback.play(journal.store.audio(id), startingAt: position) }
                            catch { journal.message = error.localizedDescription }
                        }
                    } label: {
                        Label(playback.playing ? "暂停" : "播放", systemImage: playback.playing ? "pause.fill" : "play.fill")
                    }
                    }
                    if let url = try? journal.store.audio(id) {
                        ShareLink(item: url) { Label("导出 M4A", systemImage: "square.and.arrow.up") }
                    }
                } else if entry.rawDeletedAt != nil {
                    Text("日报已保存，原音已按设置清理。会议纪要和地点可继续查看。").foregroundStyle(.secondary)
                }
                meetingAnalysis(entry)
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

    private func meetingAnalysis(_ entry: Recording) -> some View {
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
                        ShareLink(item: minutes) { Label("分享会议纪要", systemImage: "square.and.arrow.up") }
                    }
                }
            }
            if entry.isPlayable, journal.jobs[id]?.state != .queued {
                Button(journal.jobs[id] == nil ? "分析录音" : "重新分析") { confirmingAnalysis = true }
                    .disabled(journal.processingDays)
                    .confirmationDialog("发送到火山方舟进行分析？", isPresented: $confirmingAnalysis) {
                        Button("开始分析") { Task { await journal.analyze(entry) } }
                    } message: {
                        Text(journal.includeContext
                             ? "将分段上传这条录音，并使用可用的会议时段心率汇总和粗略地点。"
                             : "将分段上传这条录音。会议纪要会保存在此 iPhone。")
                    }
            }
        }
    }
}

private struct JournalSettings: View {
    @ObservedObject var journal: PhoneJournal
    @State private var key = ""

    var body: some View {
        Form {
            Section {
                Picker("录音存储", selection: $journal.storage) {
                    ForEach(RecordingStorage.allCases) { Text($0.title).tag($0) }
                }
                Toggle("手表仅充电时自动传输", isOn: Binding(
                    get: { journal.dailySettings.transferChargingOnly ?? false },
                    set: { journal.dailySettings.transferChargingOnly = $0 }))
            } footer: {
                Text("自动模式优先交给 iPhone。手表先离线暂存，iPhone 确认保存后清理手表副本。设置对后续录音生效；每日分析完成后，两端原音都会按清理策略删除。")
            }
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
                Toggle("分析时使用会议背景", isOn: $journal.includeContext)
            } footer: {
                Text("使用健康 App 中会议时段的心率汇总，以及手表在录音开始时记录的大概地点。地点可在手表「录音与健康」开启。")
            }
            Section {
                Toggle("自动每日分析", isOn: $journal.dailySettings.automatic)
                Toggle("仅充电时自动分析", isOn: $journal.dailySettings.chargingOnly)
                Toggle("仅 Wi-Fi 自动上传", isOn: Binding(
                    get: { journal.dailySettings.wifiOnly ?? true },
                    set: { journal.dailySettings.wifiOnly = $0 }))
                Toggle("跳过明确的长静音", isOn: Binding(
                    get: { journal.dailySettings.skipSilence ?? true },
                    set: { journal.dailySettings.skipSilence = $0 }))
                Toggle("读取健康与运动数据", isOn: $journal.dailySettings.healthEnabled)
                    .onChange(of: journal.dailySettings.healthEnabled) {
                        if journal.dailySettings.healthEnabled { Task { await journal.authorizeDailyHealth() } }
                    }
                Toggle("云端备份原始录音", isOn: $journal.dailySettings.cloudBackup)
                LabeledContent("健康统计时区", value: journal.dailySettings.healthTimeZoneIdentifier ?? TimeZone.current.identifier)
            } header: {
                Text("每日分析与存储")
            } footer: {
                Text("开启自动分析即允许将结束日期的录音分段发送到火山方舟。日报成功保存后清理两端原音；云备份开启时先备份录音与地点到私人 iCloud，备份失败会保留原音。健康样本仅在本地关联，不上传 iCloud。后台时机由系统安排，打开 App 可补跑。")
            }
            .disabled(journal.processingDays)
            Section {
                Picker("采集模式", selection: Binding(
                    get: { journal.dailySettings.collectionMode ?? .system },
                    set: {
                        journal.dailySettings.collectionMode = $0
                        if $0 == .precise { journal.dailySettings.healthEnabled = true }
                    })) {
                    ForEach(CollectionMode.allCases) { Text($0.title).tag($0) }
                }
            } footer: {
                Text("系统模式读取已有心率与运动数据。精准模式在手表录音期间主动采集更细的手腕运动，并监听新增心率；结束即停止，更耗电。心率采样频率仍由 watchOS 控制，普通会议不会启动训练或保证连续心率。设置同步到手表后，对下一段录音生效。")
            }
            .disabled(journal.processingDays)
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
            .disabled(journal.processingDays)
        }
        .navigationTitle("设置")
    }
}

private struct PhoneHealth: View {
    @ObservedObject var journal: PhoneJournal
    @State private var selected: HealthMetric = .heartRate
    @State private var confirmingDelete = false
    @State private var exporting = false
    @State private var exportType: UTType = .commaSeparatedText
    @State private var document: Export?

    var body: some View {
        Group {
            if let report = journal.report {
                List {
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
                ContentUnavailableView("暂无健康报告", systemImage: "heart.text.clipboard",
                                       description: Text("在 Apple Watch 生成健康报告，然后选择「发送到 iPhone」。"))
            }
        }
        .navigationTitle("健康")
        .fileExporter(isPresented: $exporting, document: document, contentType: exportType,
                      defaultFilename: "WristJournal-Health") { result in
            document = nil
            if case .failure(let error) = result { journal.message = error.localizedDescription }
        }
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
            if days.contains(where: { $0.metrics[selected] != nil }) { chart }
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
