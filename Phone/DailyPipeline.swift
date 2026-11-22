import Foundation

struct DailySettings: Codable {
    var automatic = false
    var healthEnabled = false
    var chargingOnly = true
    var cloudBackup = false
    var thresholds = HeartRateSettings()
    var healthTimeZoneIdentifier: String? = TimeZone.current.identifier
    var wifiOnly: Bool? = true
    var transferChargingOnly: Bool? = false
    var collectionMode: CollectionMode?
    var skipSilence: Bool? = true
    var audioFormat: AudioUploadFormat?
    var batchMinutes: Int?
    var localAccessMinutes: Int?
    var processingMode: ProcessingMode?
    var mode: ProcessingMode { processingMode ?? .phone }

    static func load() -> Self {
        guard let data = UserDefaults.standard.data(forKey: "dailySettings"),
              let settings = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return settings
    }
    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: "dailySettings") }
    }
}

struct DailyWorkState: Codable {
    var uploadRetry = RetryState()
    var backupRetries: [String: RetryState] = [:]
    var dirtyHealthDays: Set<JournalDayKey> = []
    var seededHealthThrough: Date?

    static func load(_ store: JournalStore) -> Self {
        guard let url = try? store.localStateURL("daily-work.json"),
              let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return state
    }
    func save(_ store: JournalStore) throws {
        try JSONEncoder().encode(self).write(to: store.localStateURL("daily-work.json"), options: .atomic)
    }
}

@MainActor
extension PhoneJournal {
    /// One serial executor for both manual meeting work and daily work.
    func processDays(automatic: Bool, externalPowerGranted: Bool = false) async -> Bool {
        guard processingMode != .none else {
            dailyStatus = "不处理模式：原音已保留，可导出到 Mac。"
            return false
        }
        guard !processingDays, !hasAnalysisWorker else { return false }
        let settings = dailySettings
        let generation = processingGeneration
        if automatic {
            guard (settings.automatic || settings.healthEnabled),
                  AnalysisScheduling.canRun(settings: settings, externalPowerGranted: externalPowerGranted)
            else { return false }
        }
        processingDays = true
        defer { processingDays = false; reload(); resumeAnalysis() }
        do {
            // Local work comes first and does not depend on upload policy, credentials or cloud availability.
            let healthSamples = try await refreshLocalHealth()
            guard generation == processingGeneration else { throw CancellationError() }
            if automatic && !settings.automatic {
                dailyStatus = "健康本地统计已更新。"
                return true
            }
            let healthZone = settings.healthTimeZoneIdentifier ?? TimeZone.current.identifier
            var deferred: [String] = []
            for day in try store.pendingDays() where day.hasEnded() {
                try Task.checkCancellation()
                if automatic && !AnalysisScheduling.canRun(settings: settings, externalPowerGranted: externalPowerGranted) {
                    dailyStatus = "自动分析已暂停，等待充电、退出低电量模式或设备降温。"
                    return false
                }
                let entries = try store.pendingRecordings(day: day)
                let healthKey = JournalDayKey(localDate: day.localDate, timeZoneIdentifier: healthZone)
                if settings.healthEnabled, !healthKey.hasEnded() { continue }
                let previous = try store.daily(day)
                do {
                    let cloudSource = entries.contains { $0.storage == .cloud }
                    let needsBackup = settings.cloudBackup || cloudSource || (previous?.cloudBackupRequired ?? false)
                    if let previous, previous.cloudBackupRequired, !previous.canPurge, !settings.cloudBackup, !cloudSource {
                        deferred.append("\(day.localDate) 等待重新开启云备份。")
                        continue
                    }
                    let previousIDs = Set(previous?.meetings.map(\.id) ?? [])
                    let pending = entries.filter { $0.rawDeletedAt == nil && !previousIDs.contains($0.id) }
                    // Interrupted files can be analyzed; damaged/incomplete recordings block this day's cleanup.
                    guard try pending.allSatisfy({ entry in
                        if entry.isPlayable { return true }
                        return try store.analysis(entry.id)?.state == .complete
                    }) else {
                        deferred.append("\(day.localDate) 有不完整录音，原音已保留。")
                        continue
                    }
                    dailyStatus = "正在整理 \(day.localDate) · \(day.timeZoneIdentifier)"
                    var meetings = previous?.meetings ?? []
                    var analyzed: [(Recording, MeetingAnalysisJob)] = []
                    if processingMode == .watch {
                        let waiting = try pending.filter { try store.analysis($0.id)?.state != .complete }
                        if !waiting.isEmpty {
                            try requestWatchProcessing(waiting, manual: !automatic)
                            deferred.append("\(day.localDate)：等待 Watch 完成 \(waiting.count) 段录音")
                            continue
                        }
                    }
                    for entry in pending {
                        try Task.checkCancellation()
                        let job = try await analyzeForDay(entry, automatic: automatic, externalPowerGranted: externalPowerGranted)
                        guard generation == processingGeneration else { throw CancellationError() }
                        if automatic && !AnalysisScheduling.canRun(settings: settings, externalPowerGranted: externalPowerGranted) {
                            throw CancellationError()
                        }
                        analyzed.append((entry, job))
                    }
                    let additionalHealth = settings.healthEnabled ? try await dailyHealth.meetings(
                        analyzed.map(\.0).filter { healthSamples[$0.id] == nil }) : [:]
                    for (entry, job) in analyzed {
                        let health = healthSamples[entry.id] ?? additionalHealth[entry.id] ?? MeetingHealthData(note:
                            settings.healthEnabled ? "暂无可读心率样本，后续同步后更新。" : "未开启健康关联。")
                        meetings.append(MeetingDigest(id: entry.id, startedAt: entry.startedAt, duration: entry.duration,
                            title: entry.title, location: entry.location, minutes: job.minutes ?? "",
                            events: HeartRateCorrelation.events(speech: job.speechWindows ?? [], samples: health.heart,
                                activity: health.activity, settings: settings.thresholds),
                            healthNote: health.note ?? ((job.speechWindows ?? []).isEmpty ? "没有可用的激动说话时间线索，未做语音与心率关联。" : nil),
                            speechWindows: job.speechWindows ?? []))
                    }
                    guard generation == processingGeneration else { throw CancellationError() }
                    guard (!meetings.isEmpty || settings.healthEnabled), let interval = day.interval else { continue }
                    let healthDay = previous?.health ?? HealthDay(start: healthKey.interval?.start ?? interval.start, localDate: day.localDate)
                    var report = previous ?? DailyJournalReport(day: day, generatedAt: .now, meetings: [],
                        health: healthDay, healthNote: nil, thresholds: settings.thresholds, cloudBackupRequired: needsBackup)
                    if !pending.isEmpty {
                        report = DailyJournalReport(day: day, generatedAt: .now,
                            meetings: meetings.sorted { $0.startedAt < $1.startedAt }, health: healthDay,
                            healthNote: !settings.healthEnabled ? "未开启健康读取。" :
                                (healthDay.metrics.isEmpty ? "没有可读健康数据，请检查授权和设备同步。" : nil),
                            thresholds: settings.thresholds, cloudBackupRequired: needsBackup,
                            backedUpRecordingIDs: previous?.backedUpRecordingIDs ?? [],
                            requiredBackupIDs: Array(Set(previous?.cloudBackupRequired == true ?
                                (previous?.requiredBackupIDs ?? previous?.meetings.map(\.id) ?? []) : []).union(
                                entries.filter { $0.rawDeletedAt == nil && (settings.cloudBackup || $0.storage == .cloud) }.map(\.id))),
                            healthTimeZoneIdentifier: previous?.healthTimeZoneIdentifier ?? healthZone)
                        try store.saveDaily(report)
                    }
                    if report.cloudBackupRequired {
                        let requiredIDs = Set(report.requiredBackupIDs ?? report.meetings.map(\.id))
                        for entry in entries where requiredIDs.contains(entry.id)
                            && !report.backedUpRecordingIDs.contains(entry.id) {
                            try Task.checkCancellation()
                            if entry.cloudUploadedAt != nil {
                                report.backedUpRecordingIDs.append(entry.id)
                                try store.saveDaily(report)
                                continue
                            }
                            if automatic { try requireAutomaticUpload(externalPowerGranted: externalPowerGranted) }
                            let configuration = "cloud"
                            if let retry = workState.backupRetries[day.id], !retry.allows(configuration: configuration) {
                                throw WorkDeferred.cooldown
                            }
                            guard entry.rawDeletedAt == nil else {
                                // Old reports may contain already-purged recordings. Never claim they were backed up.
                                dailyStatus = "部分历史原音已清理，无法补备份；已保留本次原音。"
                                return false
                            }
                            do {
                                try await cloudBackup.save(recording: entry, audio: store.audio(entry.id),
                                    wifiOnly: automatic && (settings.wifiOnly ?? true))
                                workState.backupRetries.removeValue(forKey: day.id)
                                try workState.save(store)
                            } catch {
                                if !Task.isCancelled, !(error is CancellationError) {
                                    var retry = workState.backupRetries[day.id] ?? RetryState()
                                    retry.fail(configuration: configuration, authentication: false)
                                    workState.backupRetries[day.id] = retry
                                    try workState.save(store)
                                }
                                try Task.checkCancellation()
                                throw error
                            }
                            report.backedUpRecordingIDs.append(entry.id)
                            try store.saveDaily(report)
                        }
                    }
                    guard report.canPurge else {
                        deferred.append("\(day.localDate) 的备份尚未齐全，原音继续保留。")
                        continue
                    }
                    try Task.checkCancellation()
                    guard generation == processingGeneration, processingMode != .none else { throw CancellationError() }
                    _ = try store.purgeDaily(day)
                    for meeting in report.meetings { try compactAnalysis(meeting.id) }
                    try store.completeCleanup(day)
                    notifyWatchPurge(try store.pendingPurgeIDs())
                } catch is CancellationError { throw CancellationError() }
                catch { deferred.append("\(day.localDate)：\(error.localizedDescription)") }
            }
            if !deferred.isEmpty {
                dailyStatus = "分析或备份未完成，原音已保留。\n" + deferred.prefix(3).joined(separator: "\n")
                return false
            }
            dailyStatus = "已完成手机已收到的结束日期录音；后续同步会继续处理。日报、纪要和地点已保留。"
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
