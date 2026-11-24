import SwiftUI

struct JournalReviewView: View {
    @ObservedObject var journal: PhoneJournal
    @State private var period = 0
    @State private var confirm = false

    var body: some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-journal-sources-preview") {
            SourceReviewPreview(journal: journal)
        } else if ProcessInfo.processInfo.arguments.contains("-journal-fixture"),
                  ProcessInfo.processInfo.arguments.contains("-journal-map-preview-report"),
                  let firstMeetingDay = journal.days.first(where: { !$0.meetings.isEmpty }) {
            DailyReportView(journal: journal, report: firstMeetingDay)
        } else { content }
        #else
        content
        #endif
    }

    private var content: some View {
        List {
            Section {
                Picker("回顾范围", selection: $period) {
                    Text("每日").tag(0)
                    Text("每周").tag(1)
                    Text("每月").tag(2)
                }.pickerStyle(.segmented)
                Button(journal.processingMode == .watch ? "请求 Watch 处理并归档" : "分析已结束日期") { confirm = true }
                    .disabled(journal.processingMode == .none || journal.processingDays || journal.hasAnalysisWorker)
                if journal.processingMode == .none {
                    Text("当前不处理，原音保留。请在设置中打开 Mac 临时下载。").font(.footnote)
                }
                if journal.processingDays { ProgressView("正在分析，已完成分段会保存进度") }
                if let status = journal.dailyStatus { Text(status).font(.footnote).foregroundStyle(.secondary) }
            } footer: {
                Text("按录音开始时的当地日期归档。今日暂不清理；周和月回顾复用日报。")
            }
            if journal.hasMoreDays {
                Section {
                    Text("当前显示已加载日期的回顾；更早日期按需加载。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("加载更早日期") { journal.loadMoreDays() }
                }
            }
            if journal.days.isEmpty {
                Section { Text("暂无日报。同步录音后，分析已结束日期即可生成回顾。").foregroundStyle(.secondary) }
            } else if period == 0 {
                ForEach(journal.days) { day in
                    NavigationLink {
                        DailyReportView(journal: journal, report: day)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(day.day.localDate)
                            Text("\(day.meetings.count) 段会议 · \(day.day.timeZoneIdentifier)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                ForEach(JournalReview.grouped(journal.days, monthly: period == 2)) { review in
                    Section(review.id) {
                        LabeledContent("会议", value: "\(review.meetingCount) 段 · \(durationText(review.duration))")
                        ForEach(HealthMetric.allCases) { metric in
                            let health = HealthReport(generatedAt: .now, timeZone: "各日报当地时区",
                                days: review.healthDays, unavailableMetrics: [])
                            LabeledContent(metric.title, value: health.summary(metric).map {
                                "\(metric.display($0)) \(metric.unit)"
                            } ?? "无数据")
                        }
                        LabeledContent("未发现运动的心率与语音重合", value: "\(review.sedentaryEvents) 次")
                        LabeledContent("伴随运动的重合", value: "\(review.activityEvents) 次")
                        ForEach(review.days) { day in
                            NavigationLink(day.day.localDate + " · " + day.day.timeZoneIdentifier) {
                                DailyReportView(journal: journal, report: day)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("回顾")
        .confirmationDialog(journal.dailySettings.keepReviewAudio == true ? "分析结束日期的录音并保留原音？" : "分析并清理结束日期的原音？", isPresented: $confirm) {
            Button("开始每日分析") { Task { _ = await journal.processDays(automatic: false) } }
        } message: {
            Text("录音会分段发送到火山方舟。日报保留纪要、转写摘录、时间标记和关联结果。"
                 + (journal.dailySettings.keepReviewAudio == true ? "当前设置保留原音，可以回听。" : "当前设置在日报和所需备份成功后清理原音，之后引用只能查看原文。可在设置中开启「日报后保留原音」。"))
        }
    }
}

#if DEBUG
/// Render-only probe using the same source component and real persisted fixture report.
private struct SourceReviewPreview: View {
    @ObservedObject var journal: PhoneJournal
    @StateObject private var playback = LocalPlayback()
    private var meeting: MeetingDigest? {
        journal.days.flatMap(\.meetings).first { !($0.citations ?? []).isEmpty }
    }
    var body: some View {
        List {
            if let meeting {
                Section("纪要") { Text(meeting.minutes) }
                Section("来源与标记") {
                    RecordingSourcesView(store: journal.store, recordingID: meeting.id,
                        citations: meeting.citations ?? [], markers: meeting.markers ?? [], playback: playback)
                }
            } else { ProgressView("正在载入来源") }
        }
        .navigationTitle("来源回顾")
        .task(id: meeting.map { journal.store.sourceAudio($0.id).detail }) {
            guard let meeting else { return }
            try? JSONSerialization.data(withJSONObject: [
                "passed": true, "nativeSourceViewRendered": true,
                "quote": meeting.citations?.first?.quote ?? "",
                "audioCleaned": journal.store.sourceAudio(meeting.id) == .cleaned,
                "playbackGestureTested": false
            ]).write(to: journal.store.localStateURL("source-ui-result.json"), options: .atomic)
        }
        .onDisappear { playback.stop() }
    }
}
#endif

private struct DailyReportView: View {
    @ObservedObject var journal: PhoneJournal
    @StateObject private var playback = LocalPlayback()
    let report: DailyJournalReport
    var body: some View {
        List {
            ForEach(report.meetings) { meeting in
                Section(meeting.title) {
                    Text(meeting.startedAt.formatted(Date.FormatStyle(date: .omitted, time: .shortened,
                                                                     timeZone: report.day.calendar.timeZone))
                         + " · " + durationText(meeting.duration))
                    if let continuation = meeting.continuation {
                        Text(continuation.detail).font(.footnote).foregroundStyle(.orange)
                    }
                    Text(meeting.minutes).textSelection(.enabled)
                    MeetingLocationView(location: meeting.location)
                    ShareLink(item: meeting.shareText) { Label("分享纪要与来源", systemImage: "square.and.arrow.up") }
                    RecordingSourcesView(store: journal.store, recordingID: meeting.id,
                        citations: meeting.citations ?? [], markers: meeting.markers ?? [], playback: playback)
                    ForEach(meeting.events) { event in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(event.activityPresent ? "心率与语音重合 · 伴随运动" : "心率与语音重合 · 未发现运动")
                            Text("录音 \(durationText(event.start.timeIntervalSince(meeting.startedAt))) · 基线 \(Int(event.baselineBPM)) → 峰值 \(Int(event.peakBPM)) bpm")
                                .font(.subheadline.monospacedDigit())
                            Text(event.speechCue).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let note = meeting.healthNote { Text(note).font(.footnote).foregroundStyle(.secondary) }
                }
            }
            Section("当日健康") {
                Text("健康统计时区：\(report.healthTimeZoneIdentifier ?? report.day.timeZoneIdentifier)")
                    .font(.footnote).foregroundStyle(.secondary)
                ForEach(HealthMetric.allCases) { metric in
                    LabeledContent(metric.title, value: report.health.metrics[metric].map {
                        "\(metric.display($0.value)) \(metric.unit)"
                    } ?? "无数据")
                }
                if let note = report.healthNote { Text(note).font(.footnote).foregroundStyle(.secondary) }
            }
            Section {
                Text("录音可能包含其他发言者，语音线索不一定来自佩戴者本人。与心率变化的时间重合不证明因果，也不等于疾病诊断。HealthKit 采样和同步可能不完整。")
                    .font(.footnote).foregroundStyle(.secondary)
                if !report.meetings.isEmpty {
                    Text(report.cleanupCompletedAt != nil ? "原音清理已完成。" : report.retainsAudio == true ? "已按设置保留原音；本机有音频时可回听来源。" :
                        (report.canPurge ? "日报已保存，等待完成原音清理。" : "等待备份完成，原音保留。"))
                        .font(.footnote)
                }
            }
        }.navigationTitle(report.day.localDate)
            .onDisappear { playback.stop() }
    }
}

/// Used by both recording details and daily / weekly / monthly drill-down.
struct RecordingSourcesView: View {
    let store: JournalStore
    let recordingID: UUID
    let citations: [SourceCitation]
    let markers: [RecordingMarker]
    @ObservedObject var playback: LocalPlayback
    @State private var error: String?

    var body: some View {
        let audio = store.sourceAudio(recordingID)
        VStack(alignment: .leading, spacing: 12) {
            if !markers.isEmpty {
                Text("时间点标记").font(.headline)
                ForEach(markers) { marker in
                    let label = "\(marker.label) · \(durationText(marker.offset))"
                    if audio.url != nil {
                        Button { play(at: marker.offset) } label: {
                            Label(label, systemImage: "bookmark")
                        }
                        .accessibilityHint("回听此标记")
                    } else {
                        Label(label, systemImage: "bookmark").foregroundStyle(.secondary)
                    }
                }
            }
            Text("有来源的要点").font(.headline)
            if citations.isEmpty {
                Text("暂无可用的原文引用。分析完成后可查看返回的来源；旧纪要不会自动补造原文。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(citations) { citation in
                VStack(alignment: .leading, spacing: 6) {
                    Text(citation.statement).font(.subheadline.weight(.semibold)).textSelection(.enabled)
                    Text("转写原文（AI 识别）").font(.caption).foregroundStyle(.secondary)
                    Text("「\(citation.quote)」").textSelection(.enabled)
                    if audio.url != nil {
                        Button { play(at: max(0, citation.startSeconds - 1)) } label: {
                            Label("回听约 \(citation.timeRange)", systemImage: "play.circle")
                        }
                    } else {
                        Label("原音约 \(citation.timeRange)", systemImage: "clock")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    ShareLink(item: citation.shareText) { Label("分享此来源", systemImage: "square.and.arrow.up") }
                        .font(.footnote)
                }
                Divider()
            }
            if !citations.isEmpty || !markers.isEmpty {
                Text(audio.detail).font(.footnote).foregroundStyle(.secondary)
                if !citations.isEmpty {
                    Text(audio.url == nil ? "转写和时间为 AI 估计。" : "转写和时间为 AI 估计，可从引用前 1 秒回听核对。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if audio.url != nil, playback.playing { Button("停止回听") { playback.stop() } }
            }
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
        }
        .buttonStyle(.borderless)
    }

    private func play(at offset: TimeInterval) {
        // Recheck at the moment of action; a daily cleanup may have run since rendering.
        let availability = store.sourceAudio(recordingID)
        guard let url = availability.url else { error = availability.detail; return }
        do { try playback.play(url, startingAt: offset); error = nil }
        catch { self.error = error.localizedDescription }
    }
}
