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
    @State private var crownTurn = 0.0
    @FocusState private var crownFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 6) {
                if let entry = journal.current {
                    Label("录音中", systemImage: "record.circle.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.red)
                    Text(entry.startedAt, style: .timer)
                        .font(.title2.monospacedDigit())
                    if let status = journal.collectionStatus, journal.collectionMode == .precise {
                        Text(status).font(.caption2).foregroundStyle(.secondary)
                    }
                    Button(role: .destructive) { journal.finish() } label: {
                        Label("停止并保存", systemImage: "stop.fill")
                    }
                    .tint(.red)
                } else {
                    Button { startRecording() } label: {
                        Label(journal.starting ? "正在准备…" : "开始录音", systemImage: "mic.fill")
                            .font(.headline)
                    }
                    .tint(.red)
                    .disabled(journal.starting)
                    .focusable()
                    .focused($crownFocused)
                    .digitalCrownRotation($crownTurn, from: -1, through: 1, by: 1,
                                          sensitivity: .medium, isContinuous: false, isHapticFeedbackEnabled: false)
                    .onChange(of: crownTurn) {
                        guard crownTurn != 0 else { return }
                        crownTurn = 0
                        if phase == .active { startRecording() }
                    }
                    .onAppear { crownFocused = true }
                    Text("也可转动数码表冠")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    NavigationLink {
                        WatchLibrary(journal: journal)
                    } label: {
                        Label("录音与健康", systemImage: "folder")
                    }
                }
            }
            .padding(.horizontal, 4)
            .navigationTitle("手记")
            .modifier(JournalNotice(message: $journal.message))
        }
    }

    private func startRecording() { Task { await journal.start() } }
}

private struct WatchLibrary: View {
    @ObservedObject var journal: WatchJournal

    var body: some View {
        List {
            Section("数据处理") {
                Text(journal.processingMode.title).font(.footnote)
                if let status = journal.processingStatus { Text(status).font(.caption2) }
                if journal.processingMode == .watch {
                    Button("处理已结束日期") {
                        journal.requestProcessing(journal.recordings.filter { JournalDayKey(recording: $0).hasEnded() }.map(\.id))
                    }
                    .disabled(journal.current != nil || journal.starting)
                    Text("将使用手机配置的接口上传录音并生成纪要。").font(.caption2)
                }
                ForEach(journal.watchMinutes.keys.sorted(by: { $0.uuidString < $1.uuidString }), id: \.self) { id in
                    NavigationLink(String((journal.watchMinutes[id] ?? "查看纪要").prefix(28))) {
                        ScrollView { Text(journal.watchMinutes[id] ?? "").padding() }
                    }
                }
            }
            Section("健康") {
                NavigationLink {
                    WatchHealth(journal: journal)
                } label: {
                    Label("健康报告", systemImage: "heart.text.clipboard")
                }
            }
            Section("录音") {
                Text(journal.transfer.storage.title).font(.caption)
                if let status = journal.storageStatus { Text(status).font(.caption2).foregroundStyle(.secondary) }
                if journal.recordings.isEmpty {
                    Text("暂无录音").foregroundStyle(.secondary)
                }
                ForEach(journal.recordings) { entry in
                    NavigationLink {
                        WatchRecording(journal: journal, id: entry.id, note: entry.note)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.title).lineLimit(1)
                            Text(entry.cloudUploadedAt != nil && entry.localEvictedAt != nil ? "已存云端，等待手机分析" :
                                    (entry.isPlayable ? durationText(entry.duration) : "文件无法播放"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if entry.isPlayable, entry.storage == .phone {
                                Text("等待 iPhone 保存").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            Toggle("记录会议地点", isOn: Binding(get: { journal.collectLocation }, set: journal.setCollectLocation))
        }
        .navigationTitle("录音与健康")
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
            if let entry = journal.recordings.first(where: { $0.id == id }) {
                Section {
                    Text(entry.startedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.footnote)
                    if entry.isPlayable {
                        LabeledContent("时长", value: durationText(entry.duration))
                    }
                    if entry.state == .interrupted {
                        Text("录音中断，已保存可播放部分。").font(.footnote)
                    }
                    if entry.state == .damaged {
                        Text("文件无法播放。").font(.footnote)
                    }
                }
                Section("备注") {
                    TextField("添加备注", text: $note)
                    if note != entry.note {
                        Button("保存备注") { journal.saveNote(note, for: entry) }
                    }
                }
                if entry.isPlayable {
                    Button {
                        if playback.playing {
                            playback.stop()
                        } else {
                            do { try playback.play(journal.store.audio(id)) }
                            catch { journal.message = error.localizedDescription }
                        }
                    } label: {
                        Label(playback.playing ? "停止播放" : "播放",
                              systemImage: playback.playing ? "stop.fill" : "play.fill")
                    }
                    .disabled(journal.current != nil || journal.starting)
                    Button { journal.send(entry) } label: {
                        Label("发送到 iPhone", systemImage: "iphone.and.arrow.forward")
                    }
                }
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
