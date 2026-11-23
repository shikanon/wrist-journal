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
        guard !result.minutes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw JournalError.invalidTransfer
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
}

struct JournalReview: Identifiable {
    let id: String
    let days: [DailyJournalReport]
    var meetingCount: Int { days.reduce(0) { $0 + $1.meetings.count } }
    var duration: TimeInterval { days.flatMap(\.meetings).reduce(0) { $0 + $1.duration } }
    var sedentaryEvents: Int { days.flatMap(\.meetings).flatMap(\.events).filter { !$0.activityPresent }.count }
    var activityEvents: Int { days.flatMap(\.meetings).flatMap(\.events).filter(\.activityPresent).count }
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
            var calendar = report.day.calendar
            calendar.firstWeekday = 2
            calendar.minimumDaysInFirstWeek = 4
            let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: start)
            return String(format: "%04d-W%02d", components.yearForWeekOfYear ?? 0, components.weekOfYear ?? 0)
        }
        return grouped.map { Self(id: $0.key, days: $0.value.sorted { $0.day.localDate > $1.day.localDate }) }
            .sorted { $0.id > $1.id }
    }
}
