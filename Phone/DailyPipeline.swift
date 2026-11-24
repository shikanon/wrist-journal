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
    var keepReviewAudio: Bool?
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

struct DailyAnalysisPreview: Identifiable {
    struct Day: Identifiable {
        let key: JournalDayKey
        let recordingIDs: Set<UUID>
        let archivedIDs: Set<UUID>
        let needsBackup: Bool
        var id: String { key.id }
    }
    let id = UUID()
    let days: [Day]
    let mode: ProcessingMode
    let retainsAudio: Bool
    let generation: UUID
    var recordingCount: Int { days.reduce(0) { $0 + $1.recordingIDs.count } }
}

enum DailyAnalysisIssue: String, CaseIterable, Identifiable {
    case watch, backupOff, backup, network, settings, cooldown, audio, scopeChanged, archive
    var id: Self { self }
    var title: String {
        switch self {
        case .watch: "等待 Watch 处理"
        case .backupOff: "需要重新开启云备份"
        case .backup: "云备份未完成"
        case .network: "等待网络"
        case .settings: "分析配置有误"
        case .cooldown: "稍后才能重试"
        case .audio: "录音不完整"
        case .scopeChanged: "归档范围已变化"
        case .archive: "分析或归档未完成"
        }
    }
    var nextStep: String {
        switch self {
        case .watch: "保持设备靠近，打开两端 App，等手表完成处理后再试。"
        case .backupOff: "到设置开启「云端备份原始录音」，然后重试。"
        case .backup: "确认已登录 iCloud、空间充足，并在网络稳定时重试。"
        case .network: "连接稳定的 Wi-Fi 后重试。"
        case .settings: "到设置的「进阶设置」检查方舟 API Key 和模型 ID。"
        case .cooldown: "稍后再试；如果已开启自动分析，App 会继续尝试。"
        case .audio: "先重新同步录音，或在录音详情检查是否还有可用的原音。"
        case .scopeChanged: "重新打开分析确认页，查看最新范围。"
        case .archive: "查看下方信息，然后重试。"
        }
    }
}

@MainActor
extension PhoneJournal {
    func analysisPreview() throws -> DailyAnalysisPreview {
        let settings = dailySettings
        let retainsAudio = settings.keepReviewAudio == true
        let now = Date.now
        let days = try store.pendingDays().filter { eligibleForAnalysis($0, settings: settings, at: now) }.compactMap { day -> DailyAnalysisPreview.Day? in
            let entries = try store.pendingRecordings(day: day)
            let previous = try store.daily(day)
            let recordingIDs = Set(entries.map(\.id))
            let archivedIDs = Set(previous?.meetings.map(\.id) ?? [])
            let backupMissing = previous.map {
                $0.cloudBackupRequired && !Set($0.requiredBackupIDs ?? $0.meetings.map(\.id)).isSubset(of: Set($0.backedUpRecordingIDs))
            } ?? false
            let retentionWork = !archivedIDs.isEmpty && previous?.cleanupCompletedAt == nil &&
                (!retainsAudio || previous?.retainsAudio != true)
            guard !recordingIDs.isSubset(of: archivedIDs) || backupMissing || retentionWork else { return nil }
            return DailyAnalysisPreview.Day(key: day, recordingIDs: recordingIDs,
                archivedIDs: archivedIDs,
                needsBackup: settings.cloudBackup || entries.contains { $0.storage == .cloud } || previous?.cloudBackupRequired == true)
        }
        return DailyAnalysisPreview(days: days, mode: settings.mode, retainsAudio: retainsAudio,
                                    generation: processingGeneration)
    }

    private func eligibleForAnalysis(_ day: JournalDayKey, settings: DailySettings, at date: Date) -> Bool {
        guard day.hasEnded(at: date) else { return false }
        let healthZone = settings.healthTimeZoneIdentifier ?? TimeZone.current.identifier
        return !settings.healthEnabled ||
            JournalDayKey(localDate: day.localDate, timeZoneIdentifier: healthZone).hasEnded(at: date)
    }

    /// One serial executor for both manual meeting work and daily work.
    func processDays(automatic: Bool, externalPowerGranted: Bool = false, preview: DailyAnalysisPreview? = nil) async -> Bool {
        guard processingMode != .none else {
            dailyStatus = "不处理模式：原音已保留，可导出到 Mac。"
            return false
        }
        guard !processingDays, !hasAnalysisWorker, !readingHealth else {
            if preview != nil {
                message = "正在执行另一项更新，完成后请重新确认分析范围。"
            }
            return false
        }
        if let preview, preview.generation != processingGeneration {
            dailyStatus = "设置已更改，请重新查看分析范围。"
            return false
        }
        let settings = dailySettings
        let generation = processingGeneration
        if automatic {
            guard (settings.automatic || settings.healthEnabled),
                  AnalysisScheduling.canRun(settings: settings, externalPowerGranted: externalPowerGranted)
            else { return false }
        }
        processingDays = true
        dailyIssues = [:]
        defer { processingDays = false; reload(); resumeAnalysis() }
        do {
            // Local work comes first and does not depend on upload policy, credentials or cloud availability.
            let healthSamples = try await readLocalHealth()
            guard generation == processingGeneration else { throw CancellationError() }
            if automatic && !settings.automatic {
                dailyStatus = "健康本地统计已更新。"
                return true
            }
            let healthZone = settings.healthTimeZoneIdentifier ?? TimeZone.current.identifier
            let scope = preview.map { Dictionary(uniqueKeysWithValues: $0.days.map { ($0.key, $0) }) }
            let targetDays = try preview?.days.map(\.key) ?? store.pendingDays()
            for day in targetDays where eligibleForAnalysis(day, settings: settings, at: .now) {
                try Task.checkCancellation()
                if automatic && !AnalysisScheduling.canRun(settings: settings, externalPowerGranted: externalPowerGranted) {
                    dailyStatus = "自动分析已暂停，等待充电、退出低电量模式或设备降温。"
                    return false
                }
                let approved = scope?[day]
                let entries = try store.pendingRecordings(day: day).filter { approved?.recordingIDs.contains($0.id) ?? true }
                let healthKey = JournalDayKey(localDate: day.localDate, timeZoneIdentifier: healthZone)
                let previous = try store.daily(day)
                var backingUp = false
                func deferDay(_ reason: DailyAnalysisIssue, detail: String? = nil) {
                    dailyIssues[reason, default: []].append(day.localDate + (detail.map { " · \($0)" } ?? ""))
                }
                if let approved, let previous,
                   !Set(previous.meetings.map(\.id)).isSubset(of: approved.recordingIDs.union(approved.archivedIDs)) {
                    deferDay(.scopeChanged)
                    continue
                }
                do {
                    let cloudSource = entries.contains { $0.storage == .cloud }
                    let needsBackup = settings.cloudBackup || cloudSource || (previous?.cloudBackupRequired ?? false)
                    if let previous, previous.cloudBackupRequired,
                       !Set(previous.requiredBackupIDs ?? previous.meetings.map(\.id)).isSubset(of: Set(previous.backedUpRecordingIDs)),
                       !settings.cloudBackup, !cloudSource {
                        deferDay(.backupOff)
                        continue
                    }
                    let previousIDs = Set(previous?.meetings.map(\.id) ?? [])
                    let pending = entries.filter { $0.rawDeletedAt == nil && !previousIDs.contains($0.id) }
                    // Interrupted files can be analyzed; damaged/incomplete recordings block this day's cleanup.
                    guard try pending.allSatisfy({ entry in
                        if entry.isPlayable { return true }
                        return try store.analysis(entry.id)?.state == .complete
                    }) else {
                        deferDay(.audio)
                        continue
                    }
                    dailyStatus = "正在整理 \(day.localDate)"
                    var meetings = previous?.meetings ?? []
                    var analyzed: [(Recording, MeetingAnalysisJob)] = []
                    if processingMode == .watch {
                        let waiting = try pending.filter { try store.analysis($0.id)?.state != .complete }
                        if !waiting.isEmpty {
                            do { try requestWatchProcessing(waiting, manual: !automatic) }
                            catch is CancellationError { throw CancellationError() }
                            catch { deferDay(.watch, detail: error.localizedDescription); continue }
                            deferDay(.watch, detail: "\(waiting.count) 段")
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
                            speechWindows: job.speechWindows ?? [], citations: job.citations,
                            markers: entry.markers, continuation: entry.continuation))
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
                            healthTimeZoneIdentifier: previous?.healthTimeZoneIdentifier ?? healthZone,
                            retainsAudio: settings.keepReviewAudio ?? false)
                        try store.saveDaily(report)
                    }
                    // Health-only days (or entries removed after confirmation) have nothing to clean.
                    guard !report.meetings.isEmpty else { continue }
                    if report.cloudBackupRequired {
                        backingUp = true
                        var missingHistoricalAudio = false
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
                                deferDay(.backup, detail: "历史原音已清理，无法补备份。")
                                missingHistoricalAudio = true
                                break
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
                        backingUp = false
                        if missingHistoricalAudio { continue }
                        if !Set(report.requiredBackupIDs ?? report.meetings.map(\.id)).isSubset(of: Set(report.backedUpRecordingIDs)) {
                            deferDay(.backup)
                            continue
                        }
                    }
                    if report.retainsAudio != (settings.keepReviewAudio ?? false) {
                        report.retainsAudio = settings.keepReviewAudio ?? false
                        try store.saveDaily(report)
                    }
                    if report.retainsAudio == true { continue }
                    guard report.canPurge else {
                        if !report.meetings.isEmpty { deferDay(.backup) }
                        continue
                    }
                    try Task.checkCancellation()
                    guard generation == processingGeneration, processingMode != .none else { throw CancellationError() }
                    _ = try store.purgeDaily(day)
                    for meeting in report.meetings { try compactAnalysis(meeting.id) }
                    try store.completeCleanup(day)
                    notifyWatchPurge(try store.pendingPurgeIDs())
                } catch is CancellationError { throw CancellationError() }
                catch {
                    let reason: DailyAnalysisIssue
                    switch error {
                    case WorkDeferred.network, is URLError: reason = .network
                    case WorkDeferred.configuration, AnalysisError.missingCredential, AnalysisError.http(401), AnalysisError.http(403):
                        reason = .settings
                    case WorkDeferred.cooldown: reason = .cooldown
                    case AnalysisError.unreadableAudio: reason = .audio
                    default: reason = backingUp ? .backup : .archive
                    }
                    deferDay(reason, detail: error.localizedDescription)
                }
            }
            if !dailyIssues.isEmpty {
                dailyStatus = "部分日期尚未完成。待处理或待备份的原音继续保留。"
                return false
            }
            dailyStatus = (preview != nil ? "已完成此次确认的录音整理。" : "已完成手机已收到的结束日期录音。")
                + (settings.keepReviewAudio == true ? "原音继续保留，可回听引用。" : "")
            return true
        } catch is CancellationError {
            dailyStatus = "分析已暂停，已保存进度。原音保留与清理遵循日报设置。"
            return false
        } catch {
            dailyStatus = healthReadError == nil ? "整理未完成：\(error.localizedDescription)" :
                "健康数据读取未完成。请到「健康」页查看原因并重试；本次未清理原音。"
            return false
        }
    }
}
