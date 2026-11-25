import Foundation

struct JournalDayKey: Codable, Hashable, Identifiable, Sendable {
    let localDate: String
    let timeZoneIdentifier: String
    var id: String { localDate + "|" + timeZoneIdentifier }
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .current
        return calendar
    }
    var interval: DateInterval? {
        guard let date = formatter.date(from: localDate) else { return nil }
        return calendar.dateInterval(of: .day, for: date)
    }
    private var formatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }
    init(date: Date, timeZone: String) {
        timeZoneIdentifier = TimeZone(identifier: timeZone)?.identifier ?? TimeZone.current.identifier
        // Initialize the date with the same Gregorian/time-zone convention used for reads.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: timeZoneIdentifier)
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        localDate = formatter.string(from: date)
    }
    init(localDate: String, timeZoneIdentifier: String) {
        self.localDate = localDate
        self.timeZoneIdentifier = timeZoneIdentifier
    }
    init(recording: Recording) {
        self.init(date: recording.startedAt, timeZone: recording.timeZoneIdentifier ?? TimeZone.current.identifier)
    }
    func hasEnded(at date: Date = .now) -> Bool { interval.map { $0.end <= date } ?? false }

    func recordingTime(_ date: Date, includeDate: Bool = false) -> String {
        let time = date.formatted(Date.FormatStyle(date: includeDate ? .abbreviated : .omitted,
                                                   time: .shortened, calendar: calendar, timeZone: calendar.timeZone))
        return "\(time) · \(Self.utcOffset(at: date, in: calendar.timeZone))"
    }

    static func utcOffset(at date: Date, in zone: TimeZone) -> String {
        let minutes = zone.secondsFromGMT(for: date) / 60
        return String(format: "UTC%@%02d:%02d", minutes < 0 ? "−" : "+", abs(minutes) / 60, abs(minutes) % 60)
    }
}

enum ReportPeriod: String, CaseIterable, Hashable {
    case day, week, month

    struct Range: Hashable, Identifiable {
        let start: String
        let end: String
        var id: String { start + "/" + end }
        func contains(_ date: String) -> Bool { start <= date && date <= end }
    }

    // Archive labels are civil dates. UTC here is only a neutral calendar for
    // comparing labels; it never rebuckets a recording into another date.
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }()

    static func date(_ label: String) -> Date? {
        let pieces = label.split(separator: "-", omittingEmptySubsequences: false)
        guard pieces.count == 3, let year = Int(pieces[0]), (1...9999).contains(year),
              let month = Int(pieces[1]), let day = Int(pieces[2]),
              let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
              Self.label(date) == label else { return nil }
        return date
    }

    static func label(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private var component: Calendar.Component {
        switch self {
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        }
    }

    func range(containing label: String) -> Range? {
        guard let date = Self.date(label) else { return nil }
        return range(containing: date)
    }

    private func range(containing date: Date) -> Range? {
        guard let interval = Self.calendar.dateInterval(of: component, for: date),
              let last = Self.calendar.date(byAdding: .day, value: -1, to: interval.end) else { return nil }
        return Range(start: Self.label(interval.start), end: Self.label(last))
    }

    func sixSlots(endingAt label: String) -> [Range] {
        guard let date = Self.date(label),
              let start = Self.calendar.dateInterval(of: component, for: date)?.start else { return [] }
        return (-5...0).compactMap { offset in
            Self.calendar.date(byAdding: component, value: offset, to: start).flatMap { range(containing: $0) }
        }
    }
}

struct SpeechWindow: Codable, Sendable {
    let start: Date
    let end: Date
    let cue: String
}

struct SpeechChunk: Decodable {
    struct Cue: Decodable {
        let startSeconds: Double
        let endSeconds: Double
        let evidence: String
    }
    let minutes: String
    let energeticSpeech: [Cue]
    struct Transcript: Decodable {
        let startSeconds: Double
        let endSeconds: Double
        let text: String
    }
    struct Highlight: Decodable {
        let statement: String
        let transcriptIndex: Int
    }
    var transcript: [Transcript]?
    var highlights: [Highlight]?

    static func parse(_ text: String, start: Date, duration: TimeInterval,
                      recordingID: UUID? = nil, sourceOffset: TimeInterval = 0) throws -> (String, [SpeechWindow], [SourceCitation]) {
        var clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.hasPrefix("```") {
            guard let first = clean.firstIndex(of: "\n"), let last = clean.range(of: "```", options: .backwards),
                  last.lowerBound > first else { throw JournalError.invalidTransfer }
            clean = String(clean[clean.index(after: first)..<last.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Older models returning prose can still produce minutes, but no timing evidence.
        guard clean.hasPrefix("{") || clean.hasPrefix("[") else { return (text, [], []) }
        let result = try JSONDecoder().decode(Self.self, from: Data(clean.utf8))
        if result.minutes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard result.energeticSpeech.isEmpty, result.transcript?.isEmpty != false,
                  result.highlights?.isEmpty != false else { throw JournalError.invalidTransfer }
            return ("", [], [])
        }
        let windows = result.energeticSpeech.compactMap { cue -> SpeechWindow? in
            guard cue.startSeconds.isFinite, cue.endSeconds.isFinite,
                  cue.startSeconds >= 0, cue.endSeconds > cue.startSeconds,
                  cue.endSeconds <= duration, !cue.evidence.isEmpty else { return nil }
            return SpeechWindow(start: start.addingTimeInterval(cue.startSeconds),
                                end: start.addingTimeInterval(cue.endSeconds),
                                cue: String(cue.evidence.prefix(200)))
        }
        let transcript = result.transcript ?? []
        var seen: Set<String> = []
        let citations = (result.highlights ?? []).prefix(64).compactMap { highlight -> SourceCitation? in
            guard let recordingID, sourceOffset.isFinite, sourceOffset >= 0,
                  transcript.indices.contains(highlight.transcriptIndex),
                  !highlight.statement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  highlight.statement.count <= 1000 else { return nil }
            let quote = transcript[highlight.transcriptIndex]
            guard quote.startSeconds.isFinite, quote.endSeconds.isFinite,
                  quote.startSeconds >= 0, quote.endSeconds > quote.startSeconds,
                  quote.endSeconds <= duration,
                  !quote.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  quote.text.count <= 4000,
                  seen.insert("\(highlight.transcriptIndex)|\(highlight.statement)").inserted else { return nil }
            return SourceCitation(id: UUID(), recordingID: recordingID,
                startSeconds: sourceOffset + quote.startSeconds, endSeconds: sourceOffset + quote.endSeconds,
                statement: highlight.statement, quote: quote.text)
        }
        return (result.minutes, windows, citations)
    }
}

/// The quote is copied from a transcript entry, never from rewritten minutes.
/// Word timing comes from the audio model; UI must label it approximate.
struct SourceCitation: Codable, Identifiable, Sendable, Equatable {
    let id: UUID
    let recordingID: UUID
    let startSeconds: TimeInterval
    let endSeconds: TimeInterval
    let statement: String
    let quote: String

    func isValid(for recording: Recording) -> Bool {
        recordingID == recording.id && startSeconds.isFinite && endSeconds.isFinite &&
        startSeconds >= 0 && endSeconds > startSeconds && endSeconds <= recording.duration + 1 &&
        !statement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && statement.count <= 1000 &&
        !quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && quote.count <= 4000
    }
    var timeRange: String { "\(durationText(startSeconds))–\(durationText(endSeconds))" }
    var shareText: String {
        "\(statement)\n转写原文（AI 识别）：「\(quote)」\n录音 \(recordingID.uuidString) · 约 \(timeRange)"
    }
}

enum SourceAudioAvailability: Equatable {
    case available(URL), cleaned, unavailable
    var url: URL? { if case .available(let url) = self { return url }; return nil }
    var detail: String {
        switch self {
        case .available: "原音可回听，时间范围为 AI 估计。"
        case .cleaned: "原音已清理，转写原文和时间引用保留，无法回听。"
        case .unavailable: "本机没有可播放的原音。可检查手表同步或已有备份。"
        }
    }
}

struct HeartSample: Codable, Sendable {
    let date: Date
    let bpm: Double
}

struct ActivityWindow: Codable, Sendable {
    let start: Date
    let end: Date
    let kind: String
    func contains(_ date: Date) -> Bool { start <= date && date < end }
}

struct HeartRateSettings: Codable, Sendable {
    var highBPM: Double = 110
    var riseBPM: Double = 25
}

struct HeartRateEvent: Codable, Identifiable, Sendable {
    let id: UUID
    let start: Date
    var end: Date
    var peakBPM: Double
    let baselineBPM: Double
    let speechCue: String
    let activityPresent: Bool
}

enum HeartRateCorrelation {
    static func events(speech: [SpeechWindow], samples: [HeartSample], activity: [ActivityWindow],
                       settings: HeartRateSettings) -> [HeartRateEvent] {
        guard settings.highBPM.isFinite, settings.riseBPM.isFinite,
              settings.highBPM > 0, settings.riseBPM > 0 else { return [] }
        let valid = samples.filter { $0.bpm.isFinite && (1...400).contains($0.bpm) }.sorted { $0.date < $1.date }
        var result: [HeartRateEvent] = []
        var seen: Set<Date> = []
        for window in speech.sorted(by: { $0.start < $1.start }) where window.end > window.start {
            let baseline = valid.filter {
                $0.date >= window.start.addingTimeInterval(-300) && $0.date < window.start
            }
            // Use only samples before the speaking window, excluding periods with activity.
            let resting = baseline.filter { sample in !activity.contains { $0.contains(sample.date) } }
            guard resting.count >= 3 else { continue }
            let sorted = resting.map(\.bpm).sorted()
            let middle = sorted.count / 2
            let baselineBPM = sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
            for sample in valid where sample.date >= window.start && sample.date < window.end {
                guard sample.bpm >= settings.highBPM, sample.bpm - baselineBPM >= settings.riseBPM,
                      seen.insert(sample.date).inserted else { continue }
                let moving = activity.contains { $0.contains(sample.date) }
                if let last = result.last, last.activityPresent == moving,
                   last.speechCue == window.cue, sample.date.timeIntervalSince(last.end) <= 120 {
                    result[result.count - 1].end = sample.date
                    result[result.count - 1].peakBPM = max(last.peakBPM, sample.bpm)
                } else {
                    result.append(HeartRateEvent(id: UUID(), start: sample.date, end: sample.date,
                                                 peakBPM: sample.bpm, baselineBPM: baselineBPM,
                                                 speechCue: window.cue, activityPresent: moving))
                }
            }
        }
        return result
    }
}

struct MeetingHealthData: Codable, Sendable {
    var heart: [HeartSample] = []
    var activity: [ActivityWindow] = []
    var note: String?
}

struct MeetingDigest: Codable, Identifiable, Sendable {
    let id: UUID
    let startedAt: Date
    let duration: TimeInterval
    let title: String
    let location: MeetingLocation?
    let minutes: String
    let events: [HeartRateEvent]
    let healthNote: String?
    var speechWindows: [SpeechWindow]?
    var citations: [SourceCitation]?
    var markers: [RecordingMarker]?
    var continuation: RecordingContinuation?

    static let silenceSummary = "录音中仅检测到持续静音，未上传音频；没有可整理的录音内容。"
    static let noSpeechSummary = "录音中没有听清可整理的内容。"

    var journalParagraphs: [String] {
        // Both the old and new silence summaries are status messages, not journal content.
        let summary = minutes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard summary != Self.noSpeechSummary,
              !summary.hasPrefix("录音中仅检测到持续静音，未上传音频") else { return [] }
        let paragraphs = minutes.split(whereSeparator: \.isNewline).compactMap { raw -> String? in
            let line = raw.trimmingCharacters(in: .whitespaces)
            // Old archives can contain headings such as “会议要点” above the actual content.
            guard !line.hasPrefix("#"), !line.hasPrefix("```") else { return nil }
            let prefix = ["- ", "* ", "• ", "> "].first(where: { line.hasPrefix($0) })
            let paragraph = prefix.map { String(line.dropFirst($0.count)).trimmingCharacters(in: .whitespaces) } ?? line
            let metadata = ["录制时间 ", "录音时长 ", "录音时段心率平均 ", "会议时段心率平均 "]
            guard !metadata.contains(where: { paragraph.hasPrefix($0) }) else { return nil }
            return paragraph.isEmpty ? nil : paragraph
        }
        if !paragraphs.isEmpty { return paragraphs }
        return (citations ?? []).map(\.statement).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var shareText: String {
        ([minutes] + (citations ?? []).map(\.shareText) +
         (markers ?? []).map { "\($0.label) · \(durationText($0.offset)) · 录音 \(id.uuidString)" } +
         [continuation?.detail].compactMap { $0 }).joined(separator: "\n\n")
    }
}

struct DailyJournalReport: Codable, Identifiable, Sendable {
    let day: JournalDayKey
    let generatedAt: Date
    var meetings: [MeetingDigest]
    let health: HealthDay
    let healthNote: String?
    let thresholds: HeartRateSettings
    let cloudBackupRequired: Bool
    var backedUpRecordingIDs: [UUID] = []
    var requiredBackupIDs: [UUID]?
    var healthTimeZoneIdentifier: String?
    var cleanupCompletedAt: Date?
    var retainsAudio: Bool?
    var id: String { day.id }
    var canPurge: Bool {
        retainsAudio != true && !meetings.isEmpty && (!cloudBackupRequired || Set(requiredBackupIDs ?? meetings.map(\.id)).isSubset(of: Set(backedUpRecordingIDs)))
    }

    static func preferred(in reports: [Self]) -> Self? {
        reports.first { $0.meetings.contains { !$0.journalParagraphs.isEmpty } }
            ?? reports.first { !$0.health.metrics.isEmpty }
    }

    var meetingIDs: Set<UUID> { Set(meetings.map(\.id)) }

    var draftSourceNotes: [String] {
        meetings.sorted { $0.startedAt < $1.startedAt }.compactMap { source in
            let paragraphs = source.journalParagraphs
            guard !paragraphs.isEmpty else { return nil }
            let original = source.minutes.trimmingCharacters(in: .whitespacesAndNewlines)
            return original.isEmpty ? paragraphs.joined(separator: "\n") : original
        }
    }

    var journalExcerpt: String? {
        for source in meetings.sorted(by: { $0.startedAt < $1.startedAt }) {
            if let paragraph = source.journalParagraphs.first { return paragraph.journalExcerpt(limit: 176) }
        }
        return nil
    }

    var narrative: DailyReportNarrative {
        var seen: Set<String> = []
        let notes = meetings.sorted { $0.startedAt < $1.startedAt }.map { source in
            source.journalParagraphs.map { $0.journalExcerpt(limit: 360) }.filter { seen.insert($0).inserted }
        }.filter { !$0.isEmpty }
        if notes.isEmpty {
            let message = health.metrics.isEmpty ? "这一天没有可整理的录音内容。"
                : "这一天没有可整理的录音内容，可在下方查看健康数据。"
            return DailyReportNarrative(title: "当日记录", markdown: message)
        }
        var selected = Array(repeating: [String](), count: notes.count)
        var remaining = 12
        // Give each source a turn, then present the chosen text in recording order.
        picks: for paragraph in 0..<(notes.map(\.count).max() ?? 0) {
            for index in notes.indices where notes[index].indices.contains(paragraph) {
                selected[index].append(notes[index][paragraph])
                remaining -= 1
                if remaining == 0 { break picks }
            }
        }
        return DailyReportNarrative(title: "当日记录", markdown: selected.flatMap { $0 }.joined(separator: "\n\n"))
    }
}

struct DailyReportNarrative: Codable, Equatable, Sendable {
    var title: String
    var markdown: String

    var isValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && title.count <= 120 &&
            !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && markdown.count <= 16_000
    }
}

/// User edits are independent of generated archives, backups, and raw audio cleanup.
struct DailyReportEdition: Codable, Equatable, Sendable {
    struct Photo: Codable, Identifiable, Equatable, Sendable {
        var id = UUID()
        let jpeg: Data
        var caption = ""
        var isValid: Bool { !jpeg.isEmpty && jpeg.count <= 1_048_576 && caption.count <= 160 }
    }

    var narrative: DailyReportNarrative
    var photos: [Photo] = []
    var meetingIDs: Set<UUID>
    var editedAt: Date = .now

    var isValid: Bool {
        narrative.isValid && photos.count <= 3 &&
            Set(photos.map(\.id)).count == photos.count && photos.allSatisfy(\.isValid)
    }
}

private extension String {
    func journalExcerpt(limit: Int) -> String {
        if count <= limit { return self }
        // Avoid leaving half a Markdown emphasis marker in a truncated excerpt.
        return String(prefix(limit)).replacingOccurrences(of: "**", with: "") + "…"
    }
}

struct JournalReview: Identifiable {
    let id: String
    let days: [DailyJournalReport]
    var meetingCount: Int { days.reduce(0) { $0 + $1.meetings.count } }
    var duration: TimeInterval { days.flatMap(\.meetings).reduce(0) { $0 + $1.duration } }
    var sedentaryEvents: Int { days.flatMap(\.meetings).flatMap(\.events).filter { !$0.activityPresent }.count }
    var activityEvents: Int { days.flatMap(\.meetings).flatMap(\.events).filter(\.activityPresent).count }
    var title: String {
        guard id.contains("-W"), let day = days.first?.day, let start = day.interval?.start else { return id }
        let calendar = Self.weekCalendar(day)
        guard let week = calendar.dateInterval(of: .weekOfYear, for: start),
              let sunday = calendar.date(byAdding: .day, value: -1, to: week.end) else { return id }
        return "\(JournalDayKey(date: week.start, timeZone: day.timeZoneIdentifier).localDate) 至 \(JournalDayKey(date: sunday, timeZone: day.timeZoneIdentifier).localDate)"
    }
    var healthDays: [HealthDay] {
        // Multiple meetings may use different time zones on the same date; count the fixed-zone health day once.
        Dictionary(grouping: days.map(\.health), by: \.start).values.compactMap {
            $0.max { $0.metrics.count < $1.metrics.count }
        }.sorted { $0.start < $1.start }
    }

    static func grouped(_ days: [DailyJournalReport], monthly: Bool) -> [Self] {
        let grouped = Dictionary(grouping: days) { report in
            if monthly { return String(report.day.localDate.prefix(7)) }
            guard let start = report.day.interval?.start else { return report.day.localDate }
            let components = weekCalendar(report.day).dateComponents([.yearForWeekOfYear, .weekOfYear], from: start)
            return String(format: "%04d-W%02d", components.yearForWeekOfYear ?? 0, components.weekOfYear ?? 0)
        }
        return grouped.map { Self(id: $0.key, days: $0.value.sorted { $0.day.localDate > $1.day.localDate }) }
            .sorted { $0.id > $1.id }
    }

    private static func weekCalendar(_ day: JournalDayKey) -> Calendar {
        var calendar = day.calendar
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }
}
