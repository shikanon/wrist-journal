import Foundation

struct DailySettings: Codable {
    var automatic = false
    var healthEnabled = false
    var chargingOnly = true
    var cloudBackup = false
    var thresholds = HeartRateSettings()
    var healthTimeZoneIdentifier: String? = TimeZone.current.identifier

    static func load() -> Self {
        guard let data = UserDefaults.standard.data(forKey: "dailySettings"),
              let settings = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return settings
    }
    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: "dailySettings") }
    }
}

@MainActor
extension PhoneJournal {
    /// One serial executor for both manual meeting work and daily work.
    func processDays(automatic: Bool, externalPowerGranted: Bool = false) async -> Bool {
        guard !processingDays, !hasAnalysisWorker else { return false }
        let settings = dailySettings
        if automatic {
            guard settings.automatic, AnalysisScheduling.canRun(settings: settings, externalPowerGranted: externalPowerGranted)
            else { return false }
        }
        processingDays = true
        defer { processingDays = false; reload(); resumeAnalysis() }
        do {
            let existing = try store.dailyReports()
            var grouped = Dictionary(grouping: try store.list(), by: JournalDayKey.init(recording:))
            let healthZone = settings.healthTimeZoneIdentifier ?? TimeZone.current.identifier
            var healthCache: [String: HealthDay] = [:]
            var incompleteDays: [String] = []
            if settings.healthEnabled {
                // Include health-only days, also catching up a week after the phone has been offline.
                for offset in 1...7 {
                    if let date = Calendar.current.date(byAdding: .day, value: -offset, to: .now) {
                        let day = JournalDayKey(date: date, timeZone: healthZone)
                        if !grouped.keys.contains(where: { $0.localDate == day.localDate }) { grouped[day] = [] }
                    }
                }
            }
            for day in grouped.keys.sorted(by: { $0.localDate < $1.localDate }) where day.hasEnded() {
                try Task.checkCancellation()
                if automatic && !AnalysisScheduling.canRun(settings: settings, externalPowerGranted: externalPowerGranted) {
                    dailyStatus = "自动分析已暂停，等待充电、退出低电量模式或设备降温。"
                    return false
                }
                guard let entries = grouped[day] else { continue }
                let healthKey = JournalDayKey(localDate: day.localDate, timeZoneIdentifier: healthZone)
                if settings.healthEnabled, !healthKey.hasEnded() { continue }
                let previous = existing.first { $0.day == day }
                if let previous, previous.cloudBackupRequired, !previous.canPurge,
                   entries.contains(where: { entry in
                       entry.rawDeletedAt == nil && previous.meetings.contains(where: { $0.id == entry.id })
                   }), !settings.cloudBackup {
                    dailyStatus = "\(day.localDate) 的备份尚未完成，原音保留。请重新开启云备份后重试，或在录音详情手动删除原音。"
                    return false
                }
                let needsHealthRefresh = settings.healthEnabled && (previous?.health.metrics.isEmpty ?? true)
                if entries.isEmpty, previous != nil, !needsHealthRefresh { continue }
                let previousIDs = Set(previous?.meetings.map(\.id) ?? [])
                let pending = entries.filter { $0.rawDeletedAt == nil && !previousIDs.contains($0.id) }
                // Interrupted files can be analyzed; damaged/incomplete recordings block this day's cleanup.
                guard pending.allSatisfy(\.isPlayable) else {
                    dailyStatus = "\(day.localDate) 有不完整录音，请先处理后再分析。"
                    incompleteDays.append(day.localDate)
                    continue
                }
                if pending.isEmpty, let previous, previous.canPurge,
                   entries.allSatisfy({ $0.rawDeletedAt != nil }), !needsHealthRefresh {
                    // Reconcile files left after a crash without re-reading HealthKit or re-analyzing audio.
                    _ = try store.purgeDaily(day)
                    for entry in entries where jobs[entry.id]?.notes.isEmpty == false { try compactAnalysis(entry.id) }
                    continue
                }
                dailyStatus = "正在整理 \(day.localDate) · \(day.timeZoneIdentifier)"
                var meetings = previous?.meetings ?? []
                for entry in pending {
                    try Task.checkCancellation()
                    let job = try await analyzeForDay(entry, automatic: automatic, externalPowerGranted: externalPowerGranted)
                    if automatic && !AnalysisScheduling.canRun(settings: settings, externalPowerGranted: externalPowerGranted) {
                        throw CancellationError()
                    }
                    let health = settings.healthEnabled ? try await dailyHealth.meeting(entry) :
                        MeetingHealthData(note: "未开启健康关联。")
                    meetings.append(MeetingDigest(id: entry.id, startedAt: entry.startedAt, duration: entry.duration,
                        title: entry.title, location: entry.location, minutes: job.minutes ?? "",
                        events: HeartRateCorrelation.events(speech: job.speechWindows ?? [], samples: health.heart,
                                                           activity: health.activity, settings: settings.thresholds),
                        healthNote: health.note ?? ((job.speechWindows ?? []).isEmpty ? "没有可用的激动说话时间线索，未做语音与心率关联。" : nil)))
                }
                guard (!meetings.isEmpty || settings.healthEnabled), let interval = day.interval else { continue }
                let healthDay: HealthDay
                if pending.isEmpty, let previous, !needsHealthRefresh { healthDay = previous.health }
                else {
                    if let cached = healthCache[day.localDate] { healthDay = cached }
                    else {
                        healthDay = settings.healthEnabled ? try await dailyHealth.daily(healthKey) :
                            HealthDay(start: healthKey.interval?.start ?? interval.start, localDate: day.localDate)
                        healthCache[day.localDate] = healthDay
                    }
                }
                var report = DailyJournalReport(day: day, generatedAt: .now,
                    meetings: meetings.sorted { $0.startedAt < $1.startedAt }, health: healthDay,
                    healthNote: !settings.healthEnabled ? "未开启健康读取。" :
                        (healthDay.metrics.isEmpty ? "没有可读健康数据，请检查授权和设备同步。" : nil),
                    thresholds: settings.thresholds, cloudBackupRequired: settings.cloudBackup,
                    backedUpRecordingIDs: previous?.backedUpRecordingIDs ?? [],
                    requiredBackupIDs: Array(Set(previous?.requiredBackupIDs ?? []) .union(
                        entries.filter { $0.rawDeletedAt == nil }.map(\.id))),
                    healthTimeZoneIdentifier: previous?.healthTimeZoneIdentifier ?? healthZone)
                try store.saveDaily(report)
                if report.cloudBackupRequired {
                    for entry in entries where (report.requiredBackupIDs ?? []).contains(entry.id)
                        && !report.backedUpRecordingIDs.contains(entry.id) {
                        try Task.checkCancellation()
                        if automatic && !AnalysisScheduling.canRun(settings: settings, externalPowerGranted: externalPowerGranted) {
                            throw CancellationError()
                        }
                        guard entry.rawDeletedAt == nil else {
                            // Old reports may contain already-purged recordings. Never claim they were backed up.
                            dailyStatus = "部分历史原音已清理，无法补备份；已保留本次原音。"
                            return false
                        }
                        try await cloudBackup.save(recording: entry, audio: store.audio(entry.id))
                        report.backedUpRecordingIDs.append(entry.id)
                        try store.saveDaily(report)
                    }
                }
                try Task.checkCancellation()
                let purged = try store.purgeDaily(day)
                for id in purged { try compactAnalysis(id) }
                notifyWatchPurge(purged)
            }
            if !incompleteDays.isEmpty {
                dailyStatus = "\(incompleteDays.joined(separator: "、")) 有不完整录音待处理；这些日期的原音已保留。"
                return false
            }
            dailyStatus = "已完成结束日期的分析；日报、纪要和地点已保留。"
            return true
        } catch is CancellationError {
            dailyStatus = "分析已暂停，已保存进度，原音会在日报和备份成功后清理。"
            return false
        } catch {
            dailyStatus = "分析或备份未完成，原音已保留。\(error.localizedDescription)"
            return false
        }
    }
}
