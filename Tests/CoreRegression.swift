import Foundation

@main
enum CoreRegression {
    static var checks = 0
    static func check(_ value: @autoclosure () throws -> Bool, _ name: String) throws {
        guard try value() else { fatalError("FAIL: \(name)") }
        checks += 1
    }
    static func main() throws {
        let start = ISO8601DateFormatter().date(from: "2026-11-20T12:00:00Z")!
        let speech = [SpeechWindow(start: start, end: start.addingTimeInterval(120), cue: "语速加快")]
        let baseline = [-240.0, -180, -60].map { HeartSample(date: start.addingTimeInterval($0), bpm: 75) }
        let high = HeartSample(date: start.addingTimeInterval(30), bpm: 120)
        let settings = HeartRateSettings()
        let events = HeartRateCorrelation.events(speech: speech, samples: baseline + [high], activity: [], settings: settings)
        try check(events.count == 1 && events[0].baselineBPM == 75 && !events[0].activityPresent, "speech and heart association")
        try check(HeartRateCorrelation.events(speech: [], samples: baseline + [high], activity: [], settings: settings).isEmpty, "no speech no association")
        try check(HeartRateCorrelation.events(speech: speech, samples: [baseline[0], high], activity: [], settings: settings).isEmpty, "insufficient baseline")
        try check(HeartRateCorrelation.events(speech: speech, samples: baseline + [
            HeartSample(date: speech[0].end, bpm: 140)], activity: [], settings: settings).isEmpty, "half open speech range")
        let moving = [ActivityWindow(start: start, end: start.addingTimeInterval(120), kind: "运动")]
        let exercise = HeartRateCorrelation.events(speech: speech, samples: baseline + [high], activity: moving, settings: settings)
        try check(exercise.count == 1 && exercise[0].activityPresent, "exercise separately marked")
        let baselineExercise = [ActivityWindow(start: start.addingTimeInterval(-300), end: start, kind: "步行")]
        try check(HeartRateCorrelation.events(speech: speech, samples: baseline + [high], activity: baselineExercise, settings: settings).isEmpty, "exercise excluded from baseline")
        let strict = HeartRateSettings(highBPM: 130, riseBPM: 25)
        try check(HeartRateCorrelation.events(speech: speech, samples: baseline + [high], activity: [], settings: strict).isEmpty, "absolute threshold")
        let rising = HeartRateSettings(highBPM: 110, riseBPM: 50)
        try check(HeartRateCorrelation.events(speech: speech, samples: baseline + [high], activity: [], settings: rising).isEmpty, "relative threshold")
        let duplicates = HeartRateCorrelation.events(speech: speech + speech, samples: baseline + [high], activity: [], settings: settings)
        try check(duplicates.count == 1, "duplicate speech windows deduplicated")
        let json = #"{"minutes":"会议决定","energeticSpeech":[{"startSeconds":10,"endSeconds":20,"evidence":"音量升高"},{"startSeconds":90,"endSeconds":130,"evidence":"越界"}]}"#
        let parsed = try SpeechChunk.parse(json, start: start, duration: 120)
        try check(parsed.0 == "会议决定" && parsed.1.count == 1 && parsed.1[0].start == start.addingTimeInterval(10), "validated chunk offsets")
        try check(try SpeechChunk.parse("普通文本纪要", start: start, duration: 120).1.isEmpty, "legacy prose has no invented cues")
        do {
            _ = try SpeechChunk.parse("{bad json}", start: start, duration: 120)
            fatalError("Malformed JSON accepted")
        } catch { checks += 1 }
        do {
            _ = try SpeechChunk.parse("```json\n{}", start: start, duration: 120)
            fatalError("Unclosed JSON fence accepted")
        } catch { checks += 1 }
        let boundary = ISO8601DateFormatter().date(from: "2026-11-20T23:30:00Z")!
        try check(JournalDayKey(date: boundary, timeZone: "Asia/Shanghai").localDate == "2026-11-21", "travel timezone")
        try check(JournalDayKey(date: boundary, timeZone: "America/New_York").localDate == "2026-11-20", "different meeting timezone")
        let dst = JournalDayKey(localDate: "2026-03-08", timeZoneIdentifier: "America/New_York")
        try check(dst.interval?.duration == 23 * 3600, "spring DST day")
        let fall = JournalDayKey(localDate: "2026-11-01", timeZoneIdentifier: "America/New_York")
        try check(fall.interval?.duration == 25 * 3600, "fall DST day")
        try check(!JournalDayKey(date: .now, timeZone: "Asia/Shanghai").hasEnded(), "today is retained")

        let root = URL.temporaryDirectory.appendingPathComponent("WristJournalRegression-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JournalStore(root: root)
        var recording = Recording(id: UUID(), startedAt: start, duration: 120, state: .saved)
        recording.timeZoneIdentifier = "Asia/Shanghai"
        try store.save(recording)
        let source = root.appendingPathComponent("source.m4a")
        try Data(repeating: 7, count: 4096).write(to: source)
        try store.receive(source, recording: recording)
        let audio = try store.audio(recording.id)
        try check(FileManager.default.fileExists(atPath: audio.path), "audio imported")
        let day = JournalDayKey(recording: recording)
        let digest = MeetingDigest(id: recording.id, startedAt: start, duration: 120, title: "差旅会议",
                                   location: MeetingLocation(latitude: 31.2, longitude: 121.5),
                                   minutes: "决定与待办", events: events + exercise, healthNote: nil)
        var report = DailyJournalReport(day: day, generatedAt: .now, meetings: [digest],
            health: HealthDay(start: day.interval!.start, localDate: day.localDate),
            healthNote: nil, thresholds: settings, cloudBackupRequired: true)
        do { _ = try store.purgeDaily(day); fatalError("Uncommitted report cleaned audio") } catch { checks += 1 }
        try store.saveDaily(report)
        try check(try store.purgeDaily(day).isEmpty, "failed cloud backup prevents cleanup")
        try check(FileManager.default.fileExists(atPath: audio.path), "backup failure retains file")
        report.backedUpRecordingIDs = [recording.id]
        try store.saveDaily(report)
        try check(try store.purgeDaily(day) == [recording.id], "acknowledged cloud allows cleanup")
        try check(!FileManager.default.fileExists(atPath: audio.path), "raw audio removed")
        try check(try !store.recording(recording.id).isPlayable, "cleanup tombstone persisted")
        try store.receive(source, recording: recording)
        try check(!FileManager.default.fileExists(atPath: audio.path), "late duplicate cannot resurrect audio")
        try check(try store.dailyReports().first?.meetings.first?.minutes == "决定与待办", "minutes survive cleanup")
        try check(try store.purgeDaily(day) == [recording.id], "cleanup idempotent")
        // Simulate a crash after marking deleted but before unlinking.
        try Data([1, 2]).write(to: audio)
        try store.purgeRaw(recording.id)
        try check(!FileManager.default.fileExists(atPath: audio.path), "restart completes pending unlink")
        let review = JournalReview.grouped([report], monthly: false)
        try check(review.count == 1 && review[0].meetingCount == 1 && review[0].sedentaryEvents == 1 && review[0].activityEvents == 1,
                  "weekly summary counts saved insights")
        try check(JournalReview.grouped([report], monthly: true).first?.id == "2026-11", "monthly calendar grouping")
        var duplicateHealth = report
        duplicateHealth.meetings = []
        let duplicatedReview = JournalReview(id: "travel", days: [report, duplicateHealth])
        try check(duplicatedReview.healthDays.count == 1, "travel health statistics counted once")
        var todayReport = report
        let todayDay = JournalDayKey(date: .now, timeZone: "Asia/Shanghai")
        todayReport = DailyJournalReport(day: todayDay, generatedAt: .now, meetings: [digest],
            health: HealthDay(start: todayDay.interval!.start, localDate: todayDay.localDate),
            healthNote: nil, thresholds: settings, cloudBackupRequired: false)
        try store.saveDaily(todayReport)
        try check(try store.purgeDaily(todayDay).isEmpty, "store refuses today's raw cleanup")
        let legacy = #"{"id":"00000000-0000-0000-0000-000000000001","startedAt":0,"duration":10,"state":"saved","note":""}"#
        let old = try JSONDecoder().decode(Recording.self, from: Data(legacy.utf8))
        try check(old.isPlayable && old.timeZoneIdentifier == nil && old.rawDeletedAt == nil, "old recordings decode")
        try check(RecordingStorage.automatic.destination(free: nil, capacity: nil) == .phone, "automatic storage favors phone")
        print("PASS: \(checks) core regression checks")
    }
}
