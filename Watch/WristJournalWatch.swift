import SwiftUI

@main
struct WristJournalWatch: App {
    @StateObject private var journal = WatchJournal()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            WatchHome(journal: journal)
                .onChange(of: phase) {
                    if phase == .active { journal.checkRecording() }
                }
        }
    }
}

private struct WatchHome: View {
    @ObservedObject var journal: WatchJournal

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let entry = journal.current {
                        VStack(spacing: 2) {
                            Label("录音中", systemImage: "record.circle.fill")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.red)
                            Text(entry.startedAt, style: .timer)
                                .font(.system(.title2, design: .monospaced).weight(.semibold))
                        }
                        .frame(maxWidth: .infinity)
                        Button(role: .destructive) { journal.finish() } label: {
                            Label("停止并保存", systemImage: "stop.fill")
                        }
                        .tint(.red)
                    } else {
                        Button {
                            Task { await journal.start() }
                        } label: {
                            Label(journal.starting ? "正在准备…" : "开始录音", systemImage: "mic.fill")
                                .font(.headline)
                        }
                        .tint(.red)
                        .disabled(journal.starting)
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
                    if journal.recordings.isEmpty {
                        Text("暂无录音").foregroundStyle(.secondary)
                    }
                    ForEach(journal.recordings) { entry in
                        NavigationLink {
                            WatchRecording(journal: journal, id: entry.id, note: entry.note)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.title).lineLimit(1)
                                Text(entry.isPlayable ? durationText(entry.duration) : "文件无法播放")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("手记")
            .modifier(JournalNotice(message: $journal.message))
        }
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
