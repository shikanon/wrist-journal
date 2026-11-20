import Charts
import Combine
import SwiftUI
import UniformTypeIdentifiers

@main
struct WristJournalPhone: App {
    @StateObject private var journal: PhoneJournal

    init() {
        let journal = PhoneJournal()
        _journal = StateObject(wrappedValue: journal)
    }

    var body: some Scene {
        WindowGroup {
            TabView {
                NavigationStack { PhoneRecordings(journal: journal) }
                    .tabItem { Label("录音", systemImage: "waveform") }
                NavigationStack { PhoneHealth(journal: journal) }
                    .tabItem { Label("健康", systemImage: "heart.text.clipboard") }
            }
            .tint(.teal)
            .modifier(JournalNotice(message: $journal.message))
        }
    }
}

private struct PhoneRecordings: View {
    @ObservedObject var journal: PhoneJournal
    @State private var exporting = false

    var body: some View {
        Group {
            if journal.recordings.isEmpty {
                ContentUnavailableView("暂无录音", systemImage: "waveform",
                                       description: Text("在 Apple Watch 的录音详情中选择「发送到 iPhone」。"))
            } else {
                List {
                    Section("已导入") {
                        LabeledContent("录音段数", value: journal.recordings.count.formatted())
                        LabeledContent("总时长", value: durationText(journal.recordings.reduce(0) { $0 + $1.duration }))
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
                                }
                            }
                        }
                    }
                }
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
    private let timer = Timer.publish(every: 0.3, on: .main, in: .common).autoconnect()

    var body: some View {
        List {
            if let entry = journal.recordings.first(where: { $0.id == id }) {
                Section {
                    Text(entry.startedAt.formatted(date: .long, time: .shortened))
                    if entry.state == .interrupted {
                        Text("录音中断，已保存可播放部分。").foregroundStyle(.secondary)
                    }
                    if !entry.note.isEmpty { Text(entry.note).textSelection(.enabled) }
                }
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
                Button("删除录音", role: .destructive) { confirmingDelete = true }
                    .confirmationDialog("删除 iPhone 上的录音？", isPresented: $confirmingDelete) {
                        Button("删除", role: .destructive) {
                            playback.stop()
                            if journal.delete(entry) { dismiss() }
                        }
                    }
            }
        }
        .navigationTitle("录音详情")
        .onReceive(timer) { _ in
            if playback.playing && !scrubbing { position = playback.position }
        }
        .onDisappear { playback.stop() }
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
                    Button("删除本机报告", role: .destructive) { confirmingDelete = true }
                        .confirmationDialog("删除 iPhone 上的报告？", isPresented: $confirmingDelete) {
                            Button("删除", role: .destructive) { journal.deleteReport() }
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
                        if let count = result?.sampleCount, let min = result?.minimum, let max = result?.maximum {
                            Text("\(selected.display(min))–\(selected.display(max)) · \(count) 个样本")
                                .font(.caption)
                        }
                    }
                }
            }
        } header: {
            Text("每日趋势")
        } footer: {
            Text("步数和活动能量为累计值，其余指标为样本均值。当天数据截至报告生成时。")
        }
    }

    private func display(_ measurement: Measurement) -> String {
        "\(selected.display(measurement.value)) \(selected.unit)"
    }
}
