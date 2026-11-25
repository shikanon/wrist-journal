import SwiftUI
import WatchConnectivity
import WatchKit

@main
struct WristJournalWatch: App {
    @WKApplicationDelegateAdaptor(WatchApplicationDelegate.self) private var delegate
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            WatchHome(journal: delegate.journal)
                .task {
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("-journal-recording-simulation") {
                        await delegate.journal.runRecordingSimulation()
                    }
                    if ProcessInfo.processInfo.arguments.contains("-journal-recording-verify") {
                        delegate.journal.verifyRecordingColdStart()
                    }
                    if ProcessInfo.processInfo.arguments.contains("-journal-recording-preview") {
                        await delegate.journal.start()
                    }
                    if ProcessInfo.processInfo.arguments.contains("-journal-processing-simulation") {
                        await delegate.journal.runProcessingSimulation()
                    }
                    if ProcessInfo.processInfo.arguments.contains("-journal-watch-simulation") {
                        await delegate.journal.runSimulation()
                    }
                    #endif
                }
                .onChange(of: phase) {
                    if phase == .active { delegate.journal.checkRecording() }
                    if phase == .background { delegate.journal.pauseBackgroundStorage() }
                }
        }
    }
}

@MainActor
private final class WatchApplicationDelegate: NSObject, WKApplicationDelegate {
    let journal = WatchJournal()
    private var tasks: [WKWatchConnectivityRefreshBackgroundTask] = []
    private var observations: [NSKeyValueObservation] = []
    private var storageTasks: [ObjectIdentifier: (WKRefreshBackgroundTask, Task<Void, Never>)] = [:]

    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            if let task = task as? WKWatchConnectivityRefreshBackgroundTask {
                tasks.append(task)
                task.expirationHandler = { [weak self, weak task] in
                    Task { @MainActor in
                        guard let self, let task else { return }
                        self.journal.pauseBackgroundStorage()
                        if let index = self.tasks.firstIndex(where: { $0 === task }) {
                            self.tasks.remove(at: index)
                            task.expirationHandler = nil
                            task.setTaskCompletedWithSnapshot(false)
                        }
                    }
                }
            } else if task is WKApplicationRefreshBackgroundTask {
                let id = ObjectIdentifier(task)
                let run = Task {
                    await journal.refreshStorageInBackground()
                    finishStorageTask(id)
                }
                storageTasks[id] = (task, run)
                task.expirationHandler = { [weak self] in
                    Task { @MainActor in
                        self?.journal.pauseBackgroundStorage()
                        self?.storageTasks[id]?.1.cancel()
                        self?.finishStorageTask(id)
                    }
                }
            } else if let snapshot = task as? WKSnapshotRefreshBackgroundTask {
                snapshot.setTaskCompleted(restoredDefaultState: true, estimatedSnapshotExpiration: .distantFuture, userInfo: nil)
            } else {
                task.setTaskCompletedWithSnapshot(false)
            }
        }
        guard !tasks.isEmpty else { return }
        let session = WCSession.default
        if observations.isEmpty {
            observations = [session.observe(\.activationState) { [weak self] _, _ in
                Task { @MainActor in self?.completeConnectivityTasks() }
            }, session.observe(\.hasContentPending) { [weak self] _, _ in
                Task { @MainActor in self?.completeConnectivityTasks() }
            }]
        }
        Task { @MainActor in completeConnectivityTasks() }
    }

    private func finishStorageTask(_ id: ObjectIdentifier) {
        guard let (task, _) = storageTasks.removeValue(forKey: id) else { return }
        task.expirationHandler = nil
        task.setTaskCompletedWithSnapshot(false)
    }

    private func completeConnectivityTasks() {
        guard WCSession.default.activationState == .activated, !WCSession.default.hasContentPending else { return }
        Task {
            await journal.waitForCloudStorage()
            guard !WCSession.default.hasContentPending else { return }
            for task in tasks {
                task.expirationHandler = nil
                task.setTaskCompletedWithSnapshot(false)
            }
            tasks.removeAll()
            observations.removeAll()
        }
    }
}

private struct WatchHome: View {
    @ObservedObject var journal: WatchJournal
    @Environment(\.scenePhase) private var phase
    @State private var preflightWarning: String?

    var body: some View {
        NavigationStack {
            Group {
                if let entry = journal.current {
                    RecordingScreen(journal: journal, entry: entry).id(entry.id)
                        #if DEBUG
                        // A headless simulator has no active interactive scene. Render-only probe.
                        .environment(\.scenePhase, ProcessInfo.processInfo.arguments.contains("-journal-recording-controls-preview") ? .active : phase)
                        #endif
                } else {
                    ScrollView {
                        VStack(spacing: 10) {
                            if let receipt = journal.receipt {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 2) {
                                        Label(receipt.title, systemImage: receipt.outcome == .saved ? "checkmark.circle" : "exclamationmark.triangle")
                                            .font(.footnote.weight(.semibold))
                                            .foregroundStyle(receipt.outcome == .saved ? .green : .orange)
                                        Spacer(minLength: 0)
                                        Button { journal.dismissReceipt() } label: {
                                            Image(systemName: "xmark")
                                                .font(.caption2)
                                                .frame(width: 44, height: 44)
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel("关闭录音结果提示")
                                    }
                                    Text(journal.receiptDetail).font(.caption2)
                                }
                                .accessibilityIdentifier("recording.receipt")
                            }
                            if journal.recovery.pending != nil {
                                Text("当前未录音 · 等待自动续录")
                                    .font(.footnote).foregroundStyle(.orange)
                                Button("取消续录") {
                                    journal.cancelRecovery(detail: "已取消续录，已录部分保留。")
                                }
                                .accessibilityIdentifier("recording.cancel-resume")
                            }
                            Button { requestStart() } label: {
                                Label(journal.starting ? "正在准备…" : "开始录音", systemImage: "mic.fill")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity, minHeight: 48)
                            }
                            .tint(.red)
                            .disabled(journal.starting)
                            .accessibilityIdentifier("recording.start")
                            Text("开始后自动锁定屏幕")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            NavigationLink {
                                WatchLibrary(journal: journal)
                            } label: {
                                Label("录音与健康", systemImage: "folder")
                            }
                        }
                        .padding(.horizontal, 4)
                    }
                    .navigationTitle("恩名手记")
                }
            }
            .alert(preflightWarning != nil ? "录音前提醒" : "恩名手记", isPresented: Binding(
                get: { preflightWarning != nil || journal.message != nil },
                set: { if !$0 { preflightWarning = nil; journal.message = nil } })) {
                if preflightWarning != nil {
                    Button("继续录音") { preflightWarning = nil; startRecording() }
                    Button("取消", role: .cancel) { preflightWarning = nil }
                } else {
                    Button("好", role: .cancel) { journal.message = nil }
                }
            } message: { Text(preflightWarning ?? journal.message ?? "") }
        }
        .id(journal.current?.id) // A resumed recording also returns from Library to the locked recorder.
    }

    private func requestStart() {
        if let warning = journal.recordingWarning() { preflightWarning = warning }
        else { startRecording() }
    }
    private func startRecording() { Task { await journal.start() } }
}

private struct WatchLibrary: View {
    @ObservedObject var journal: WatchJournal

    var body: some View {
        let visible = Set(journal.recordings.map(\.id))
        let recent = (journal.recordings + journal.recentReviewEntries.filter {
            !visible.contains($0.id) && $0.state != .recording
        }).sorted { $0.startedAt > $1.startedAt }
        List {
            Section("最近录音") {
                if recent.isEmpty {
                    Text("暂无录音").font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(recent.prefix(5)) { entry in
                    recordingLink(entry)
                }
                if recent.count > 5 {
                    NavigationLink("更多录音") {
                        List {
                            ForEach(recent) { entry in recordingLink(entry) }
                        }
                        .navigationTitle("更多录音")
                    }
                }
            }
            NavigationLink {
                WatchHealth(journal: journal)
            } label: {
                Label("健康报告", systemImage: "heart.text.clipboard")
            }
            NavigationLink {
                WatchLibrarySettings(journal: journal)
            } label: {
                Label("录音设置", systemImage: "gearshape")
            }
        }
        .navigationTitle("录音与健康")
    }

    private func recordingLink(_ entry: Recording) -> some View {
        NavigationLink {
            WatchRecording(journal: journal, id: entry.id, note: entry.note)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title).lineLimit(2)
                Text(watchAudioStatus(entry, store: journal.store)).font(.caption2).foregroundStyle(.secondary)
                if journal.watchMinutes[entry.id] != nil {
                    Label("录音已整理", systemImage: "doc.text").font(.caption2)
                }
            }
        }
    }
}

private func watchAudioStatus(_ entry: Recording, store: JournalStore) -> String {
    let availability = store.sourceAudio(entry)
    if availability == .cleaned { return "原音已清理" }
    let playable = availability.url != nil
    if entry.phoneReceivedAt != nil, entry.storage == .phone {
        return playable ? "iPhone 已保存 · 手表可回听" : "已转移至 iPhone"
    }
    if entry.cloudUploadedAt != nil { return playable ? "已存 iCloud · 手表可回听" : "已存 iCloud · 手表无原音" }
    guard playable else { return "手表无可播放原音" }
    if entry.storage == .phone { return "手表暂存 · 等待 iPhone 保存" }
    return "\(durationText(entry.duration)) · 手表可回听"
}

private struct WatchLibrarySettings: View {
    @ObservedObject var journal: WatchJournal
    @AppStorage("immediateRecordingLock") private var immediateLock = true

    var body: some View {
        List {
            Section("录音体验") {
                Toggle("开始后立即锁定", isOn: $immediateLock)
                Text("关闭后显示 1 秒开始确认，再锁定。长按解锁后可停止；抬腕仍保持锁定。熄屏由系统控制。")
                    .font(.caption2)
                Toggle("中断后自动续录", isOn: Binding(
                    get: { journal.automaticResume }, set: journal.setAutomaticResume))
                Text("默认关闭。开启后，系统允许时最多尝试 3 次，等待超过 2 分钟结束。续录单独保存并标明漏录时间；停止或重启 App 后不会自动录音。")
                    .font(.caption2)
            }
            Section("数据处理") {
                Text(journal.processingMode.title).font(.footnote)
                if let status = journal.processingStatus { Text(status).font(.caption2) }
                if journal.processingMode == .watch {
                    Button("处理已结束日期") {
                        journal.requestProcessing(journal.recordings.filter { JournalDayKey(recording: $0).hasEnded() }.map(\.id))
                    }
                    .disabled(journal.current != nil || journal.starting || journal.recovery.pending != nil)
                    Text("将使用手机配置的接口上传并整理录音。").font(.caption2)
                }
            }
            Section("存储") {
                Text(journal.transfer.storage.title).font(.caption)
                if let status = journal.storageStatus { Text(status).font(.caption2).foregroundStyle(.secondary) }
            }
            Toggle("记录录音地点", isOn: Binding(get: { journal.collectLocation }, set: journal.setCollectLocation))
        }
        .navigationTitle("录音设置")
    }
}

private struct WatchReview: View {
    @ObservedObject var journal: WatchJournal
    let id: UUID
    @StateObject private var playback = LocalPlayback()
    var body: some View {
        let citations = (try? journal.store.analysis(id))?.citations ?? []
        let audio = journal.store.sourceAudio(id)
        List {
            Section("整理内容") { Text(journal.watchMinutes[id] ?? "") }
            Section("原文来源") {
                if citations.isEmpty {
                    Text("这条记录暂无原文引用。").font(.footnote)
                }
                ForEach(citations) { citation in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(citation.statement).font(.headline)
                        Text("「\(citation.quote)」").font(.footnote)
                        Text("AI 转写 · 约 \(citation.timeRange)").font(.caption2)
                        Button("回听来源") {
                            guard let url = journal.store.sourceAudio(id).url else {
                                journal.message = journal.store.sourceAudio(id).detail
                                return
                            }
                            do { try playback.play(url, startingAt: max(0, citation.startSeconds - 1)) }
                            catch { journal.message = error.localizedDescription }
                        }
                        .disabled(audio.url == nil || journal.current != nil || journal.starting || journal.recovery.pending != nil)
                    }
                }
                if !citations.isEmpty { Text(audio.detail).font(.caption2) }
                if playback.playing { Button("停止回听") { playback.stop() } }
            }
        }
        .navigationTitle("记录与来源")
        .onDisappear { playback.stop() }
    }
}

private struct WatchRecording: View {
    @ObservedObject var journal: WatchJournal
    @StateObject private var playback = LocalPlayback()
    @Environment(\.dismiss) private var dismiss
    let id: UUID
    @State var note: String
    @State private var confirmingDelete = false

    var body: some View {
        List {
            if let entry = journal.recordings.first(where: { $0.id == id }) ??
                journal.recentReviewEntries.first(where: { $0.id == id }) {
                let audio = journal.store.sourceAudio(entry)
                if journal.watchMinutes[id] != nil {
                    NavigationLink("查看记录与来源") { WatchReview(journal: journal, id: id) }
                }
                Section {
                    Text(JournalDayKey(recording: entry).recordingTime(entry.startedAt, includeDate: true))
                        .font(.footnote)
                    LabeledContent("时长", value: durationText(entry.duration))
                    Text(watchAudioStatus(entry, store: journal.store)).font(.caption2).foregroundStyle(.secondary)
                    if entry.state == .interrupted {
                        Text("录音中断，已保存可播放部分。").font(.footnote)
                    }
                    if entry.state == .damaged {
                        Text("文件无法播放。").font(.footnote)
                    }
                    if let continuation = entry.continuation {
                        Text(continuation.detail).font(.footnote)
                    }
                }
                if let url = audio.url, !(entry.markers ?? []).isEmpty {
                    Section("时间点标记") {
                        ForEach(entry.markers ?? []) { marker in
                            Button("\(marker.label) · \(durationText(marker.offset))") {
                                do { try playback.play(url, startingAt: marker.offset) }
                                catch { journal.message = error.localizedDescription }
                            }
                            .disabled(journal.current != nil || journal.starting || journal.recovery.pending != nil)
                        }
                    }
                }
                if entry.rawDeletedAt == nil && !(entry.storage == .phone && entry.localEvictedAt != nil) {
                    Section("备注") {
                        TextField("添加备注", text: $note)
                        if note != entry.note {
                            Button("保存备注") { journal.saveNote(note, for: entry) }
                        }
                    }
                }
                if let url = audio.url {
                    Button {
                        if playback.playing {
                            playback.stop()
                        } else {
                            do { try playback.play(url) }
                            catch { journal.message = error.localizedDescription }
                        }
                    } label: {
                        Label(playback.playing ? "停止播放" : "播放",
                              systemImage: playback.playing ? "stop.fill" : "play.fill")
                    }
                    .disabled(journal.current != nil || journal.starting || journal.recovery.pending != nil)
                    Button { journal.send(entry) } label: {
                        Label("发送到 iPhone", systemImage: "iphone.and.arrow.forward")
                    }
                }
                if entry.rawDeletedAt == nil && !(entry.storage == .phone && entry.localEvictedAt != nil) {
                    Button("删除录音", role: .destructive) {
                        confirmingDelete = true
                    }
                    .confirmationDialog("删除这段手表录音？", isPresented: $confirmingDelete) {
                        Button("删除", role: .destructive) {
                            playback.stop()
                            if journal.delete(entry) { dismiss() }
                        }
                    }
                }
            }
        }
        .navigationTitle("录音")
        .onDisappear { playback.stop() }
    }
}

private struct WatchHealth: View {
    @ObservedObject var journal: WatchJournal
    @State private var confirmingDelete = false

    var body: some View {
        List {
            Section {
                Button {
                    Task { await journal.generateReport() }
                } label: {
                    Label(journal.generatingReport ? "正在读取…" : "生成近 7 天报告",
                          systemImage: "arrow.clockwise")
                }
                .disabled(journal.generatingReport)
            }
            if let report = journal.report {
                Section("7 天概况") {
                    ForEach(HealthMetric.allCases) { metric in
                        MetricRow(metric: metric, value: report.summary(metric))
                    }
                    Text("更新于 \(report.generatedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !report.unavailableMetrics.isEmpty {
                    Text("部分指标读取失败，可检查健康权限后重试。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(report.days.reversed()) { day in
                    Section {
                        ForEach(HealthMetric.allCases) { metric in
                            MetricRow(metric: metric, value: day.metrics[metric]?.value)
                        }
                    } header: {
                        Text(day.localDate)
                    }
                }
                Button { journal.sendReport() } label: {
                    Label("发送到 iPhone", systemImage: "iphone.and.arrow.forward")
                }
                Button("删除报告", role: .destructive) { confirmingDelete = true }
                    .disabled(journal.generatingReport)
                    .confirmationDialog("删除手表上的报告？", isPresented: $confirmingDelete) {
                        Button("删除", role: .destructive) { journal.deleteReport() }
                    }
            } else {
                Text("授权后，从手表的健康资料生成报告。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("健康报告")
    }
}
