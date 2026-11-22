import Foundation

@MainActor
extension PhoneJournal {
    /// Runs without network access or API credentials. Returns only this run's meeting samples.
    func refreshLocalHealth() async throws -> [UUID: MeetingHealthData] {
        guard processingMode != .none else { throw CancellationError() }
        guard dailySettings.healthEnabled else { return [:] }
        let zone = dailySettings.healthTimeZoneIdentifier ?? TimeZone.current.identifier
        let today = JournalDayKey(date: .now, timeZone: zone)
        guard let todayStart = today.interval?.start else { return [:] }
        var calendar = today.calendar
        calendar.timeZone = today.calendar.timeZone
        let existingKeys = try store.dailyKeys()
        let pendingKeys = try store.pendingDays()
        // Catch up missed days, at most a month per invocation; no repeated seven-day scans.
        var cursor = workState.seededHealthThrough.flatMap { calendar.date(byAdding: .day, value: 1, to: $0) }
            ?? calendar.date(byAdding: .day, value: -7, to: todayStart)!
        var seeded = 0
        while cursor < todayStart && seeded < 31 {
            let key = JournalDayKey(date: cursor, timeZone: zone)
            let matching = (existingKeys + pendingKeys).filter { $0.localDate == key.localDate }
            workState.dirtyHealthDays.formUnion(matching.isEmpty ? [key] : matching)
            workState.seededHealthThrough = cursor
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor)!
            seeded += 1
        }
        // New dates need a baseline. Existing dates are refreshed only by anchored changes.
        for key in pendingKeys {
            if try store.daily(key) == nil {
                workState.dirtyHealthDays.insert(key)
            }
        }
        try workState.save(store)
        let origin = (existingKeys + pendingKeys).compactMap { $0.interval?.start }.min()
            ?? calendar.date(byAdding: .day, value: -7, to: todayStart)!
        let syncURL = try store.localStateURL("health-sync.json")
        let changed = try await dailyHealth.changedIntervals(at: syncURL, since: origin.addingTimeInterval(-300))
        guard processingMode != .none else { throw CancellationError() }
        workState.dirtyHealthDays.formUnion(try store.affectedHealthDays(changed))
        try workState.save(store)
        try await dailyHealth.acknowledgeChanges(at: syncURL)

        var healthCache: [JournalDayKey: HealthDay] = [:]
        var meetingCache: [UUID: MeetingHealthData] = [:]
        for day in workState.dirtyHealthDays.sorted(by: { $0.id < $1.id }) where day.hasEnded() {
            try Task.checkCancellation()
            let previous = try store.daily(day)
            let healthZone = previous?.healthTimeZoneIdentifier ?? zone
            let healthKey = JournalDayKey(localDate: day.localDate, timeZoneIdentifier: healthZone)
            guard healthKey.hasEnded() else { continue }
            let pending = try store.pendingRecordings(day: day)
            var entries = Dictionary(uniqueKeysWithValues: pending.filter(\.isPlayable).map { ($0.id, $0) })
            for meeting in previous?.meetings ?? [] {
                entries[meeting.id] = (try? store.recording(meeting.id)) ??
                    Recording(id: meeting.id, startedAt: meeting.startedAt, duration: meeting.duration, state: .saved)
            }
            let samples = try await dailyHealth.meetings(Array(entries.values))
            guard processingMode != .none else { throw CancellationError() }
            meetingCache.merge(samples) { _, new in new }
            let health: HealthDay
            if let cached = healthCache[healthKey] { health = cached }
            else {
                health = try await dailyHealth.daily(healthKey)
                healthCache[healthKey] = health
            }
            guard processingMode != .none else { throw CancellationError() }
            let meetings = (previous?.meetings ?? []).map { meeting -> MeetingDigest in
                guard let speech = meeting.speechWindows, let samples = samples[meeting.id] else { return meeting }
                return MeetingDigest(id: meeting.id, startedAt: meeting.startedAt, duration: meeting.duration,
                    title: meeting.title, location: meeting.location, minutes: meeting.minutes,
                    events: HeartRateCorrelation.events(speech: speech, samples: samples.heart, activity: samples.activity,
                        settings: previous?.thresholds ?? dailySettings.thresholds),
                    healthNote: samples.note, speechWindows: speech)
            }
            let report = DailyJournalReport(day: day, generatedAt: .now, meetings: meetings, health: health,
                healthNote: health.metrics.isEmpty ? "没有可读健康数据；新增样本同步后会更新。" : nil,
                thresholds: previous?.thresholds ?? dailySettings.thresholds,
                cloudBackupRequired: previous?.cloudBackupRequired ?? false,
                backedUpRecordingIDs: previous?.backedUpRecordingIDs ?? [],
                requiredBackupIDs: previous?.requiredBackupIDs,
                healthTimeZoneIdentifier: healthZone, cleanupCompletedAt: previous?.cleanupCompletedAt)
            try store.saveDaily(report)
            workState.dirtyHealthDays.remove(day)
            try workState.save(store)
        }
        return meetingCache
    }
}
