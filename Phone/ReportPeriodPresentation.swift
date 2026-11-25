import SwiftUI

extension ReportPeriod {
    var title: String {
        switch self {
        case .day: "日报"
        case .week: "周报"
        case .month: "月报"
        }
    }

    var currentTitle: String {
        switch self {
        case .day: "今天"
        case .week: "本周"
        case .month: "本月"
        }
    }

    var emptyTitle: String {
        switch self {
        case .day: "这一天暂无日报"
        case .week: "这一周暂无周报"
        case .month: "这个月暂无月报"
        }
    }

    func dateTitle(_ range: Range) -> String {
        switch self {
        case .day: range.start
        case .week: "\(range.start) 至 \(range.end)"
        case .month: String(range.start.prefix(7))
        }
    }
}

struct ReportCalendarHeader: View {
    @ScaledMetric(relativeTo: .caption) private var slotWidth = 44.0
    let period: ReportPeriod
    let slots: [ReportPeriod.Range]
    let selected: ReportPeriod.Range
    let current: ReportPeriod.Range
    let archiveDates: [String]
    let changePeriod: (ReportPeriod) -> Void
    let selectSlot: (ReportPeriod.Range) -> Void
    let returnToRecent: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Picker("报告类型", selection: Binding(get: { period }, set: changePeriod)) {
                ForEach(ReportPeriod.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)

            ViewThatFits(in: .horizontal) {
                row()
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) { row().fixedSize(horizontal: true, vertical: false) }
                        .scrollIndicators(.hidden)
                        .onAppear { proxy.scrollTo(selected.id, anchor: .center) }
                        .onChange(of: selected.id) { _, value in proxy.scrollTo(value, anchor: .center) }
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { context.fixedSize(); Spacer(minLength: 0); legend.fixedSize() }
                VStack(alignment: .leading, spacing: 5) { context; legend }
            }
            .font(.caption)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(.background)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var context: some View {
        let text = period.dateTitle(selected)
        return Text(selected == current ? "\(period.currentTitle) · \(text)" : text)
            .fontWeight(.medium)
            .monospacedDigit()
            .accessibilityIdentifier("report-calendar.range")
    }

    @ViewBuilder
    private var legend: some View {
        if let returnToRecent {
            Button("回到最近", action: returnToRecent)
                .padding(.vertical, 5)
        } else {
            HStack(spacing: 4) {
                Circle().fill(.teal).frame(width: 5, height: 5).accessibilityHidden(true)
                Text("有报告").foregroundStyle(.secondary)
            }
        }
    }

    private func row() -> some View {
        HStack(spacing: 3) {
            ForEach(Array(slots.enumerated()), id: \.element.id) { index, range in
                let filled = archiveDates.contains(where: { range.contains($0) })
                let active = range == selected
                let labels = slotLabels(range)
                Button { selectSlot(range) } label: {
                    VStack(spacing: 2) {
                        Text(labels.0).font(.caption.weight(.semibold))
                        Text(labels.1).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                        Circle().fill(filled ? Color.teal : .clear)
                            .frame(width: 5, height: 5)
                            .accessibilityHidden(true)
                    }
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(minWidth: max(44, slotWidth), maxWidth: .infinity, minHeight: 54)
                    .padding(.vertical, 2)
                    .background(active ? Color.teal.opacity(0.14) : Color.secondary.opacity(0.07),
                                in: RoundedRectangle(cornerRadius: 11))
                    .overlay {
                        if active { RoundedRectangle(cornerRadius: 11).strokeBorder(.teal, lineWidth: 1.5) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(range == current ? period.currentTitle + "，" : "")\(period.title)，\(period.dateTitle(range))")
                .accessibilityValue(filled ? "已有报告" : "暂无报告")
                .accessibilityAddTraits(active ? .isSelected : [])
                .accessibilityIdentifier("report-calendar.slot.\(index)")
                .id(range.id)
            }
        }
    }

    private func slotLabels(_ range: ReportPeriod.Range) -> (String, String) {
        switch period {
        case .day:
            let weekday = ReportPeriod.date(range.start).map { ReportPeriod.calendar.component(.weekday, from: $0) }
            let weekdays = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
            return (shortDate(range.start), range == current ? "今天" : (weekday.map { weekdays[$0 - 1] } ?? ""))
        case .week: return (shortDate(range.start), "–\(shortDate(range.end))")
        case .month:
            let month = Int(range.start.dropFirst(5).prefix(2)) ?? 0
            return ("\(month)月", String(range.start.prefix(4)))
        }
    }

    private func shortDate(_ date: String) -> String {
        let parts = date.split(separator: "-").dropFirst().compactMap { Int($0) }
        return parts.map(String.init).joined(separator: "/")
    }
}

struct ReportDatePicker: View {
    @Environment(\.dismiss) private var dismiss
    @State private var date: Date
    let period: ReportPeriod
    let today: Date
    let archiveDates: [String]
    let choose: (String) -> Void

    init(period: ReportPeriod, selected: String, today: String, archiveDates: [String], choose: @escaping (String) -> Void) {
        self.period = period
        let end = ReportPeriod.date(today) ?? .now
        self.today = end
        self.archiveDates = archiveDates.filter { $0 <= today }
        self.choose = choose
        _date = State(initialValue: ReportPeriod.date(selected) ?? end)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    DatePicker("日期", selection: $date, in: ...today, displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .environment(\.calendar, ReportPeriod.calendar)
                        .environment(\.timeZone, ReportPeriod.calendar.timeZone)
                } footer: {
                    Text("选择任意一天，打开它所在的\(period.title)。")
                }
                if !archiveDates.isEmpty {
                    Section("已归档日期") {
                        ForEach(archiveDates.reversed(), id: \.self) { label in
                            Button { open(label) } label: {
                                LabeledContent(label) { Image(systemName: "arrow.up.right").accessibilityHidden(true) }
                            }
                            .accessibilityIdentifier("report-calendar.archive.\(label)")
                        }
                    }
                }
            }
            .navigationTitle("选日期")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("查看\(period.title)") { open(ReportPeriod.label(date)) } }
            }
        }
    }

    private func open(_ label: String) {
        choose(label)
        dismiss()
    }
}

struct SelectedReportList: View {
    @ObservedObject var journal: PhoneJournal
    let period: ReportPeriod
    let range: ReportPeriod.Range
    @Binding var chosenZone: String?
    let openRecordings: () -> Void
    let openPeriod: (String, ReportPeriod) -> Void
    let showAnalysis: () -> Void
    @State private var result: Result<[DailyJournalReport], Error>?
    @State private var retry = UUID()

    private struct ReadRequest: Equatable {
        let archive: UUID
        let retry: UUID
    }

    var body: some View {
        List {
            switch result {
            case .none:
                ProgressView("正在读取\(period.title)")
            case .failure:
                ContentUnavailableView {
                    Label("无法读取\(period.title)", systemImage: "exclamationmark.circle")
                } actions: {
                    Button("重试") { retry = UUID() }
                }
                .listRowBackground(Color.clear)
            case .success(let reports) where reports.isEmpty:
                ContentUnavailableView {
                    Label(period.emptyTitle, systemImage: "calendar")
                } description: {
                    Text(period == .day
                         ? "可以点选其他日期，或同步录音后生成已结束日期的日报。"
                         : "这一期还没有归档的日报。点选另一格可直接查看。")
                } actions: {
                    if period == .day { Button("前往录音", action: openRecordings) }
                }
                .accessibilityIdentifier("report-calendar.empty")
                .listRowBackground(Color.clear)
            case .success(let reports):
                if period == .day {
                    if let report = reports.first(where: { $0.id == chosenZone })
                        ?? DailyJournalReport.preferred(in: reports) ?? reports.first {
                        if reports.count > 1 {
                            Section {
                                Picker("归档时区", selection: Binding(get: { report.id }, set: { chosenZone = $0 })) {
                                    ForEach(reports) { value in
                                        Text(value.day.timeZoneIdentifier).tag(value.id)
                                    }
                                }
                            }
                        }
                        DailyReportSections(journal: journal, report: report).id(report.id)
                    }
                } else {
                    PeriodArchiveSections(period: period, range: range, reports: reports, openPeriod: openPeriod)
                }
            }
            // Keep generation controls and failure details reachable from every period.
            ReportAnalysisSection(journal: journal, onRequest: showAnalysis)
        }
        .task(id: ReadRequest(archive: journal.reportArchiveRevision, retry: retry)) {
            result = Result { try journal.store.dailyReports(from: range.start, through: range.end) }
        }
    }
}

private struct PeriodArchiveSections: View {
    let period: ReportPeriod
    let range: ReportPeriod.Range
    let reports: [DailyJournalReport]
    let openPeriod: (String, ReportPeriod) -> Void

    var body: some View {
        let review = JournalReview(id: range.id, days: reports)
        let dates = Dictionary(grouping: reports, by: \.day.localDate)
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Text(period.title)
                    .font(.system(.largeTitle, design: .serif).weight(.bold))
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("report-calendar.summary")
                Text(period.dateTitle(range)).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                Label("\(dates.count) 天有日报", systemImage: "calendar.badge.checkmark")
                    .font(.subheadline)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .background(Color.teal.opacity(0.12).gradient, in: RoundedRectangle(cornerRadius: 20))
            .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(.teal.opacity(0.2)) }
            .listRowInsets(.init())
            .listRowBackground(Color.clear)
        }

        let highlights = representativeHighlights
        if !highlights.isEmpty {
            Section {
                ForEach(highlights) { item in
                    Button { openPeriod(item.date, .day) } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(item.date).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                Text(item.text).font(.subheadline).foregroundStyle(.primary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary).accessibilityHidden(true)
                        }
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("查看该日日报")
                }
            } header: {
                Text("当日记录摘录")
            } footer: {
                Text("点开摘录可查看当天的完整日报。")
            }
        }

        let child: ReportPeriod = period == .month ? .week : .day
        let groups = Dictionary(grouping: reports) { child.range(containing: $0.day.localDate) }
        Section(period == .month ? "本期周报" : "本期日报") {
            ForEach(groups.keys.compactMap { $0 }.sorted { $0.start > $1.start }) { item in
                Button { openPeriod(max(item.start, range.start), child) } label: {
                    LabeledContent(child.dateTitle(item)) {
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary).accessibilityHidden(true)
                    }
                }
                .accessibilityIdentifier("report-calendar.drill.\(child.rawValue)")
                .accessibilityHint("查看\(child.title)")
            }
        }
        let health = HealthReport(generatedAt: .now, timeZone: "各日报当地时区",
                                  days: review.healthDays, unavailableMetrics: [])
        if health.days.contains(where: { !$0.metrics.isEmpty }) || review.sedentaryEvents + review.activityEvents > 0 {
            Section {
                DisclosureGroup("健康概况") {
                    ForEach(HealthMetric.allCases) { metric in
                        if let value = health.summary(metric) {
                            LabeledContent(metric.title, value: "\(metric.display(value)) \(metric.unit)")
                        }
                    }
                    LabeledContent("未发现运动的心率与语音重合", value: "\(review.sedentaryEvents) 次")
                    LabeledContent("伴随运动的重合", value: "\(review.activityEvents) 次")
                }
            }
        }
    }

    private struct Highlight: Identifiable {
        let date: String
        let text: String
        var id: String { date }
    }

    private var representativeHighlights: [Highlight] {
        var seen: Set<String> = []
        var items: [Highlight] = []
        for report in reports where !seen.contains(report.day.localDate) {
            guard let excerpt = report.journalExcerpt else { continue }
            seen.insert(report.day.localDate)
            items.append(Highlight(date: report.day.localDate, text: excerpt))
            if items.count == 5 { break }
        }
        return items
    }
}

#if DEBUG
var calendarFixtureReportDate: String {
    let today = JournalDayKey(date: .now, timeZone: TimeZone.current.identifier).localDate
    return ReportPeriod.day.sixSlots(endingAt: today).first?.start ?? today
}

@MainActor
extension PhoneJournal {
    func seedReportCalendarFixture() throws {
        let recent = calendarFixtureReportDate
        let week = ReportPeriod.week.sixSlots(endingAt: recent).dropFirst(1).first?.start
        let month = ReportPeriod.month.sixSlots(endingAt: recent).dropFirst(1).first?.start
        for (index, label) in [recent, week, month].compactMap({ $0 }).enumerated() {
            guard let start = ReportPeriod.date(label) else { continue }
            let day = JournalDayKey(localDate: label, timeZoneIdentifier: "UTC")
            let source = MeetingDigest(id: UUID(), startedAt: start.addingTimeInterval(36000),
                duration: 5400, title: "随手记录", location: nil,
                minutes: ["""
                    早上沿河走了一段，桥边的银杏已经变黄。下次想带相机去拍几张。

                    午后试着把零散的读书笔记归到同一页，按问题整理，比按章节翻找更方便。

                    晚些时候想起来，出门前要给自行车打气。
                    """,
                    "找到一家周末也开门的图书馆，想找个下午去看看。",
                    "把家里积攒的旧照片分了几类，先整理旅行的那一盒。"][index],
                events: [], healthNote: nil)
            try store.saveDaily(DailyJournalReport(day: day, generatedAt: .now, meetings: [source],
                health: HealthDay(start: start, localDate: label), healthNote: nil,
                thresholds: HeartRateSettings(), cloudBackupRequired: false, retainsAudio: true))
        }
        reload()
    }
}
#endif
