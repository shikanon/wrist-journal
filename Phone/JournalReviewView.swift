import SwiftUI

struct JournalReviewView: View {
    @ObservedObject var journal: PhoneJournal
    @State private var period = 0
    @State private var confirm = false

    var body: some View {
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
                        DailyReportView(report: day)
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
                                DailyReportView(report: day)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("回顾")
        .confirmationDialog("分析并清理结束日期的原音？", isPresented: $confirm) {
            Button("开始每日分析") { Task { _ = await journal.processDays(automatic: false) } }
        } message: {
            Text("录音会分段发送到火山方舟。日报成功后保留纪要、地点和关联结果并清理原音；已开启云备份时先完成备份。请先同步手表录音与健康数据。")
        }
    }
}

private struct DailyReportView: View {
    let report: DailyJournalReport
    var body: some View {
        List {
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
            ForEach(report.meetings) { meeting in
                Section(meeting.title) {
                    Text(meeting.startedAt.formatted(Date.FormatStyle(date: .omitted, time: .shortened,
                                                                     timeZone: report.day.calendar.timeZone))
                         + " · " + durationText(meeting.duration))
                    if let location = meeting.location {
                        Text("会议地点（粗略）：\(location.description)")
                        if let accuracy = location.accuracy {
                            Text("定位精度约 \(Int(accuracy)) 米").font(.caption).foregroundStyle(.secondary)
                        }
                        if let url = URL(string: "https://maps.apple.com/?ll=\(location.latitude),\(location.longitude)") {
                            Link("在地图查看", destination: url)
                        }
                    } else { Text("未记录地点").font(.caption).foregroundStyle(.secondary) }
                    Text(meeting.minutes).textSelection(.enabled)
                    ShareLink(item: meeting.minutes) { Label("分享纪要", systemImage: "square.and.arrow.up") }
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
            Section {
                Text("录音可能包含其他发言者，语音线索不一定来自佩戴者本人。与心率变化的时间重合不证明因果，也不等于疾病诊断。HealthKit 采样和同步可能不完整。")
                    .font(.footnote).foregroundStyle(.secondary)
                Text(report.cleanupCompletedAt != nil ? "原音清理已完成。" :
                    (report.canPurge ? "日报已保存，等待完成原音清理。" : "等待备份完成，原音保留。"))
                    .font(.footnote)
            }
        }.navigationTitle(report.day.localDate)
    }
}
