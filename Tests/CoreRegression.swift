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
        let tombstoneURL = root.appendingPathComponent(recording.id.uuidString).appendingPathComponent("recording.json")
        let beforeRepeat = try Data(contentsOf: tombstoneURL)
        try check(try store.purgeDaily(day).isEmpty, "completed tombstones are not rewritten")
        try check(try Data(contentsOf: tombstoneURL) == beforeRepeat, "repeat cleanup preserves tombstone")
        // Simulate a crash after marking deleted but before unlinking.
        try Data([1, 2]).write(to: audio)
        try store.purgeRaw(recording.id)
        try check(!FileManager.default.fileExists(atPath: audio.path), "restart completes pending unlink")
        try store.completeCleanup(day)
        try check(try store.daily(day)?.cleanupCompletedAt != nil, "cleanup completion persisted")
        try check(try !store.pendingDays().contains(day), "completed day excluded from work index")
        try check(try store.pendingPurgeIDs().contains(recording.id), "purge stays pending before watch acknowledgement")
        try store.acknowledgePurge([recording.id])
        let reopened = JournalStore(root: root)
        try check(try reopened.pendingPurgeIDs().isEmpty, "acknowledgement survives restart")
        try check(try reopened.pendingDays().isEmpty, "restart only restores unfinished days")
        try store.receive(source, recording: recording)
        try check(try store.pendingPurgeIDs() == [recording.id], "late duplicate requeues purge without resurrection")
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
        try check(RecordingStorage.automatic.destination(free: nil, capacity: nil) == .watch, "legacy automatic storage favors watch")
        var retry = RetryState()
        retry.fail(configuration: "key-a", authentication: false, now: start)
        try check(!retry.allows(configuration: "key-a", now: start.addingTimeInterval(59)), "retry cooling survives foreground reentry")
        try check(retry.allows(configuration: "key-a", now: start.addingTimeInterval(60)), "retry opens at persisted deadline")
        retry.fail(configuration: "key-a", authentication: false, now: start)
        try check(retry.nextAttempt == start.addingTimeInterval(300), "backoff increases")
        for _ in 0..<20 { retry.fail(configuration: "key-a", authentication: false, now: start) }
        try check(retry.nextAttempt == start.addingTimeInterval(21600), "backoff bounded at six hours")
        retry.fail(configuration: "key-a", authentication: true, now: start)
        let restoredRetry = try JSONDecoder().decode(RetryState.self, from: JSONEncoder().encode(retry))
        try check(!restoredRetry.allows(configuration: "key-a", now: start.addingTimeInterval(86400 * 30)),
                  "invalid key remains blocked after restart")
        try check(restoredRetry.allows(configuration: "key-b", now: start), "configuration change releases authentication block")
        try check(!TransferPolicy.allowsAutomatic(recording: true, chargingOnly: false, charging: true),
                  "recording excludes automatic file transfer")
        try check(!TransferPolicy.allowsAutomatic(recording: false, chargingOnly: true, charging: false),
                  "charging batch waits for power")
        try check(TransferPolicy.allowsAutomatic(recording: false, chargingOnly: true, charging: true),
                  "charging batch resumes with power")
        let rangeA = DateInterval(start: start, duration: 300)
        let rangeB = DateInterval(start: start.addingTimeInterval(330), duration: 100)
        let rangeC = DateInterval(start: start.addingTimeInterval(600), duration: 60)
        let merged = HealthQueryRanges.merged([rangeC, rangeB, rangeA])
        try check(merged.count == 2 && merged[0].duration == 430, "adjacent meeting queries merged")
        try check(!HealthQueryRanges.overlaps(rangeA, DateInterval(start: rangeA.end, duration: 10)),
                  "health invalidation uses half open ranges")
        try check(try store.affectedHealthDays([DateInterval(start: start.addingTimeInterval(30), duration: 1)]).contains(day),
                  "late samples invalidate archived meeting date")
        try check(try store.affectedHealthDays([DateInterval(start: start.addingTimeInterval(-86400 * 10), duration: 1)]).isEmpty,
                  "unrelated sample leaves history cached")
        let queueID = UUID()
        let queued = Recording(id: queueID, startedAt: start.addingTimeInterval(600), duration: 20, state: .saved)
        try store.save(queued)
        try store.saveAnalysis(Data(#"{"state":"queued"}"#.utf8), id: queueID, complete: false)
        try check(try JournalStore(root: root).unfinishedAnalysisIDs() == [queueID], "analysis work index survives restart")
        try store.saveAnalysis(Data(#"{"state":"complete"}"#.utf8), id: queueID, complete: true)
        try check(try store.unfinishedAnalysisIDs().isEmpty, "completed analysis leaves work queue")
        for index in 0..<55 {
            try store.save(Recording(id: UUID(), startedAt: start.addingTimeInterval(Double(index)), duration: 1, state: .saved))
        }
        let page1 = try store.list(limit: 20)
        let page2 = try store.list(offset: 20, limit: 20)
        try check(page1.count == 20 && page2.count == 20 &&
                  Set(page1.map(\.id)).isDisjoint(with: page2.map(\.id)), "history pagination has no duplicates")
        // An interrupted file/index commit is recovered from source files once.
        try Data([1]).write(to: root.appendingPathComponent(".catalog-dirty"))
        let recovered = JournalStore(root: root)
        try check(try recovered.list().count == 57, "dirty catalog recovered from committed files")
        try check(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".catalog-dirty").path),
                  "catalog recovery clears dirty marker")
        print("PASS: \(checks) core regression checks")
        try check(RecordingStorage.preference(nil) == .watch && RecordingStorage.preference("automatic") == .watch,
                  "new and legacy automatic preferences default to watch")
        try check(RecordingStorage.preference("phone") == .phone && RecordingStorage.allCases == [.watch, .phone, .cloud],
                  "explicit preference and three choices preserved")
        var staged = Recording(id: UUID(), startedAt: start, duration: 120, state: .saved, storage: .watch)
        try check(!StoragePolicy.shouldSend(staged, requested: false, endedOnly: false, batchDue: true, recording: false),
                  "watch priority waits for phone request")
        staged.storage = .phone
        try check(!StoragePolicy.shouldSend(staged, requested: false, endedOnly: false, batchDue: false, recording: false),
                  "phone priority batches recordings")
        try check(StoragePolicy.shouldSend(staged, requested: false, endedOnly: false, batchDue: true, recording: false),
                  "phone priority transfers when batch due")
        try check(!StoragePolicy.shouldSend(staged, requested: true, endedOnly: false, batchDue: true, recording: true),
                  "manual request cannot interrupt recording")
        try check(!StoragePolicy.batchDue(last: start, minutes: 60, now: start.addingTimeInterval(3599)) &&
                   StoragePolicy.batchDue(last: start, minutes: 60, now: start.addingTimeInterval(3600)), "batch deadline")
        staged.storage = .cloud
        try store.receive(source, recording: staged)
        do { try store.evictLocal(staged.id); fatalError("Unconfirmed cloud eviction") } catch { checks += 1 }
        try check(FileManager.default.fileExists(atPath: try store.audio(staged.id).path), "cloud failure retains original")
        try store.evictLocal(staged.id, cloudConfirmedAt: start)
        let remote = try store.recording(staged.id)
        try check(remote.cloudUploadedAt == start && remote.localEvictedAt != nil && remote.rawDeletedAt == nil,
                  "cloud eviction distinct from final purge")
        try check(!remote.isPlayable && !FileManager.default.fileExists(atPath: try store.audio(staged.id).path),
                  "cloud acknowledgement releases watch bytes")
        let evictions = root.appendingPathComponent("PendingEviction")
        try Data().write(to: evictions.appendingPathComponent(staged.id.uuidString))
        try Data([7]).write(to: store.audio(staged.id))
        try JournalStore(root: root).recoverEvictions()
        try check(!FileManager.default.fileExists(atPath: try store.audio(staged.id).path), "restart finishes committed eviction")
        try store.receive(source, recording: remote)
        try store.receive(source, recording: remote)
        try check(try store.recording(staged.id).isPlayable, "cloud import clears local eviction idempotently")
        try store.receive(source, recording: staged)
        try check(try store.recording(staged.id).cloudUploadedAt == start, "late watch metadata preserves cloud acknowledgment")
        try store.purgeRaw(staged.id)
        try check(try store.pendingCloudCompletionIDs().contains(staged.id), "cloud completion queued before final cleanup")
        try store.receive(source, recording: remote)
        try check(!FileManager.default.fileExists(atPath: try store.audio(staged.id).path), "cloud download cannot revive purged audio")
        var lease = LocalAccessLease(timeout: 600, now: 10)
        try check(!lease.expired(at: 609) && lease.touch(at: 609) && lease.deadline == 1209, "authenticated activity extends idle lease")
        try check(!lease.touch(at: 1209) && lease.expired(at: 1209), "expired lease cannot revive")
        let valid = Data("GET /api/recordings HTTP/1.1\r\nHost: 127.0.0.1:1234\r\nAuthorization: Bearer secret\r\n\r\n".utf8)
        try check(LocalHTTPRequest(valid, host: "127.0.0.1:1234")?.authorized(token: "secret") == true, "HTTP bearer authorization")
        try check(LocalHTTPRequest(valid, host: "evil.test") == nil, "Host mismatch rejected")
        try check(LocalHTTPRequest(valid, host: "127.0.0.1:1234")?.authorized(token: "wrong") == false, "invalid bearer rejected")
        let duplicate = Data("GET / HTTP/1.1\r\nHost: a\r\nHost: a\r\n\r\n".utf8)
        try check(LocalHTTPRequest(duplicate, host: "a") == nil, "duplicate headers rejected")
        let phoneCopy = Recording(id: UUID(), startedAt: start, duration: 120, state: .saved, storage: .phone)
        try store.receive(source, recording: phoneCopy)
        try store.evictLocal(phoneCopy.id)
        try check(try !store.pendingRecordings().contains { $0.id == phoneCopy.id }, "acknowledged phone copy leaves watch work index")
        var savedWork = StorageWorkState()
        savedWork.request = StorageSyncRequest(known: [UUID()], endedOnly: true)
        savedWork.lastBatch = start
        try savedWork.save(store)
        let resumedWork = StorageWorkState.load(JournalStore(root: root))
        try check(resumedWork.request?.endedOnly == true && resumedWork.lastBatch == start, "pending request and batch survive restart")
        print("PASS: \(checks) total core and storage regression checks")
    }
}
