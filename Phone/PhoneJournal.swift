import SwiftUI
import CryptoKit

@MainActor
final class PhoneJournal: ObservableObject {
    @Published private(set) var recordings: [Recording] = []
    @Published private(set) var report: HealthReport?
    @Published private(set) var reportIsDaily = false
    @Published private(set) var jobs: [UUID: MeetingAnalysisJob] = [:]
    @Published private(set) var analyzing: UUID?
    @Published private(set) var syncStatus: String?
    @Published private(set) var lastWatchImport = UserDefaults.standard.object(forKey: "lastWatchAudioImport") as? Date
    private var syncRequestID: UUID?
    @Published private(set) var hasPersonalKey = ArkCredential.personal.load() != nil
    @Published private(set) var hasOfficialKey = false
    @Published var days: [DailyJournalReport] = []
    @Published private(set) var reportArchiveDates: [String] = []
    @Published private(set) var reportArchiveRevision = UUID()
    @Published private(set) var dailyEditionRevision = UUID()
    @Published var processingDays = false
    @Published var dailyStatus: String?
    @Published var dailyIssues: [DailyAnalysisIssue: [String]] = [:]
    @Published var readingHealth = false
    @Published var healthReadError: String?
    @Published private(set) var hasMoreRecordings = false
    private var recordingLimit = 50
    @Published var dailySettings = DailySettings.load() {
        didSet {
            dailySettings.save()
            AnalysisScheduling.schedule(settings: dailySettings)
            if !dailySettings.automatic { automaticDailyTask?.cancel() }
            processingChanged()
            publishStorage()
        }
    }
    @Published var storage = RecordingStorage.preference(UserDefaults.standard.string(forKey: RecordingStorage.settingsKey)) {
        didSet {
            UserDefaults.standard.set(storage.rawValue, forKey: RecordingStorage.settingsKey)
            if storage == .cloud { UserDefaults.standard.set(true, forKey: "cloudInboxEnabled") }
            publishStorage()
        }
    }
    @Published var credential = ArkCredential(rawValue: UserDefaults.standard.string(forKey: "arkCredential") ?? "") ?? .official {
        didSet { UserDefaults.standard.set(credential.rawValue, forKey: "arkCredential"); processingChanged() }
    }
    @Published var model = UserDefaults.standard.string(forKey: "arkModel") ?? MeetingAnalyzer.defaultModel {
        didSet { UserDefaults.standard.set(model, forKey: "arkModel"); processingChanged() }
    }
    @Published var includeContext = UserDefaults.standard.bool(forKey: "includeMeetingContext") {
        didSet { UserDefaults.standard.set(includeContext, forKey: "includeMeetingContext"); processingChanged() }
    }
    @Published var message: String?

    let store: JournalStore
    let analyzer = MeetingAnalyzer()
    let dailyHealth = DailyHealthReader()
    let network = UploadNetwork()
    lazy var workState = DailyWorkState.load(store)
    lazy var cloudBackup = CloudBackup()
    lazy var localDownload = LocalDownloadServer(store: store)
    @Published var storageSyncStatus: String?
    @Published var lastCloudSync = UserDefaults.standard.object(forKey: "lastCloudAudioSync") as? Date
    var synchronizingStorage = false
    var sourceTask: Task<Void, Never>?
    private var worker: Task<Void, Never>?
    private var automaticDailyTask: Task<Void, Never>?
    private var automaticWorkRequested = false
    var dailyAnalysisTask: Task<MeetingAnalysisJob, Error>?
    var processingGeneration = UUID()
    @Published var watchConfigurationStatus = "等待与手表同步"
    var processingMode: ProcessingMode { dailySettings.mode }
    var processingConfiguration: ProcessingConfiguration {
        var config = ProcessingConfiguration()
        config.mode = processingMode
        config.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if config.model.isEmpty { config.model = MeetingAnalyzer.defaultModel }
        config.credential = credential.rawValue
        if let revision = UserDefaults.standard.string(forKey: "processingRevision") { config.revision = revision }
        else { UserDefaults.standard.set(config.revision, forKey: "processingRevision") }
        config.automatic = dailySettings.automatic
        config.chargingOnly = dailySettings.chargingOnly
        config.wifiOnly = dailySettings.wifiOnly ?? true
        config.skipSilence = dailySettings.skipSilence ?? true
        config.audioFormat = dailySettings.audioFormat ?? .automatic
        config.includeContext = includeContext
        return config
    }
    private func processingChanged() {
        processingGeneration = UUID()
        UserDefaults.standard.set(UUID().uuidString, forKey: "processingRevision")
        watchConfigurationStatus = "设置已更新，等待手表同步"
        worker?.cancel()
        dailyAnalysisTask?.cancel()
        automaticDailyTask?.cancel()
        try? transfer.publishProcessing(processingConfiguration)
    }
    func requirePhoneProcessing() throws {
        try Task.checkCancellation()
        guard processingMode.allowsModel(on: .phone) else { throw CancellationError() }
    }
    func requestWatchProcessing(_ entries: [Recording], manual: Bool) throws {
        guard processingMode == .watch else { throw CancellationError() }
        try transfer.publishProcessing(processingConfiguration)
        try transfer.requestProcessing(entries, manual: manual)
        dailyStatus = "已请求 Watch 处理，录音和结果会在设备可用时同步。"
    }
    var hasAnalysisWorker: Bool { worker != nil }

    func saveDailyEdition(_ edition: DailyReportEdition, for day: JournalDayKey) throws {
        try store.saveDailyEdition(edition, for: day)
        dailyEditionRevision = UUID()
    }

    func draftDailyReport(_ report: DailyJournalReport) async throws -> DailyReportNarrative {
        try requirePhoneProcessing()
        let generation = processingGeneration
        let notes = report.meetings.sorted { $0.startedAt < $1.startedAt }.map(\.minutes)
        guard notes.count >= 2 else { throw AnalysisError.invalidResponse }
        let key: String
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-journal-report-edition-simulation") {
            key = "fixture-key"
        } else if let configured = credential.load() { key = configured }
        else { throw AnalysisError.missingCredential }
        #else
        guard let configured = credential.load() else { throw AnalysisError.missingCredential }
        key = configured
        #endif
        let result = try await analyzer.draftDailyReport(notes: notes, model: processingConfiguration.model, key: key)
        try Task.checkCancellation()
        guard generation == processingGeneration else { throw CancellationError() }
        return result
    }

    func foregroundEntered() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-journal-processing-simulation") { return }
        if ProcessInfo.processInfo.arguments.contains("-journal-fixture") ||
            ProcessInfo.processInfo.arguments.contains("-journal-storage-simulation") { return }
        #endif
        scheduleSourceSync()
        resumeAnalysis()
        automaticWorkRequested = true
        guard automaticDailyTask == nil, dailySettings.automatic || dailySettings.healthEnabled else { return }
        automaticDailyTask = Task { [weak self] in
            guard let self else { return }
            defer { self.automaticDailyTask = nil }
            repeat {
                self.automaticWorkRequested = false
                _ = await self.processDays(automatic: true)
            } while self.automaticWorkRequested && !Task.isCancelled
        }
    }

    func foregroundExited() {
        automaticDailyTask?.cancel()
        sourceTask?.cancel()
        localDownload.stop(reason: "App 已进入后台，下载服务已关闭")
        AnalysisScheduling.schedule(settings: dailySettings)
    }

    private lazy var transfer = CompanionTransfer(store: store, credentialProvider: { [weak self] revision in
        await self?.watchCredential(revision)
    }) { [weak self] event in
        Task { @MainActor [weak self] in
            switch event {
            case .updated, .recordingImported:
                if case let .recordingImported(date) = event, let self {
                    self.syncRequestID = nil
                    self.syncStatus = "已收到手表录音"
                    let latest = max(date, self.lastWatchImport ?? .distantPast)
                    self.lastWatchImport = latest
                    UserDefaults.standard.set(latest, forKey: "lastWatchAudioImport")
                }
                self?.reload()
                if UIApplication.shared.applicationState == .active { self?.foregroundEntered() }
            case .syncFallback(let id, let queued):
                guard let self, self.syncRequestID == id else { return }
                self.syncStatus = queued ? "等待手表 · 请求已排队" : "无法连接手表"
            case .cloudAvailable:
                UserDefaults.standard.set(true, forKey: "cloudInboxEnabled")
                self?.scheduleSourceSync(force: true)
            case .message(let message): self?.message = message
            case .ready:
                self?.publishStorage()
                if let ids = try? self?.store.pendingPurgeIDs() { self?.notifyWatchPurge(ids) }
                if UIApplication.shared.applicationState == .active { self?.scheduleSourceSync() }
            case .purgeAcknowledged(let ids):
                try? self?.store.acknowledgePurge(ids)
            case .credentialReady(let revision):
                if self?.processingConfiguration.revision == revision { self?.watchConfigurationStatus = "手表已确认当前 API 配置" }
            }
        }
    }
    private func watchCredential(_ revision: String) -> (Data, String)? {
        let config = processingConfiguration
        guard config.mode == .watch, config.revision == revision,
              let key = credential.load(), let data = try? JSONEncoder().encode(config) else { return nil }
        return (data, key)
    }

    init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-journal-processing-simulation") {
            let root = URL.applicationSupportDirectory.appendingPathComponent("WristJournalProcessingTests")
            try? FileManager.default.removeItem(at: root)
            store = JournalStore(root: root)
        } else if ProcessInfo.processInfo.arguments.contains("-journal-storage-simulation") {
            let root = URL.applicationSupportDirectory.appendingPathComponent("WristJournalStorageTests")
            try? FileManager.default.removeItem(at: root)
            store = JournalStore(root: root)
        } else if ProcessInfo.processInfo.arguments.contains("-journal-fixture") {
            let root = URL.applicationSupportDirectory.appendingPathComponent("WristJournalUITests")
            if ProcessInfo.processInfo.arguments.contains("-journal-fixture-reset") { try? FileManager.default.removeItem(at: root) }
            store = JournalStore(root: root)
        } else { store = JournalStore() }
        #else
        store = JournalStore()
        #endif
        let previousManagedKey = ArkCredential.official.load()
        ArkCredential.loadManagedDefault()
        if previousManagedKey != ArkCredential.official.load() {
            UserDefaults.standard.set(UUID().uuidString, forKey: "processingRevision")
        }
        hasOfficialKey = ArkCredential.official.load() != nil
        reload()
        for id in (try? store.unfinishedAnalysisIDs()) ?? [] { loadJob(id) }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-journal-fixture"),
           ProcessInfo.processInfo.arguments.contains("-journal-fixture-reset") {
            do {
                if ProcessInfo.processInfo.arguments.contains("-journal-report-calendar-fixture") {
                    try seedReportCalendarFixture()
                } else {
                    try seedSimulation()
                }
            }
            catch { message = error.localizedDescription }
        }
        #endif
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-journal-processing-simulation") { return }
        #endif
        transfer.activate()
    }

    #if DEBUG
    func verifySimulationPersistence() {
        let result = URL.applicationSupportDirectory.appendingPathComponent("WristJournalUITests/simulation-result.json")
        let meetings = days.flatMap(\.meetings)
        let settings = DailySettings.load()
        let cleared = recordings.filter { $0.rawDeletedAt != nil }
        let passed = meetings.count == 1 && meetings[0].events.count == 1 &&
            meetings[0].location?.latitude == 31.230 && cleared.count == 1 &&
            jobs[cleared[0].id]?.notes.isEmpty == true && settings.healthEnabled &&
            settings.chargingOnly && !settings.cloudBackup &&
            JournalReview.grouped(days, monthly: true).reduce(0, { $0 + $1.meetingCount }) == 1
        let evidence: [String: Any] = ["passed": passed, "scenario": "restart-review",
            "settingsPersisted": settings.healthEnabled && settings.chargingOnly && !settings.cloudBackup,
            "deletedRawCount": cleared.count, "meetingCount": meetings.count,
            "eventCount": meetings.first?.events.count ?? 0]
        try? JSONSerialization.data(withJSONObject: evidence, options: .prettyPrinted).write(to: result, options: .atomic)
    }

    func runSimulation() async {
        let result = URL.applicationSupportDirectory.appendingPathComponent("WristJournalUITests/simulation-result.json")
        var evidence: [String: Any] = [:]
        do {
            guard let entry = recordings.first else { throw JournalError.invalidTransfer }
            let cloudFailure = ProcessInfo.processInfo.arguments.contains("-journal-fixture-cloud-failure")
            dailySettings.cloudBackup = cloudFailure
            let scope = try analysisPreview()
            guard scope.days.count == 1, scope.recordingCount == 1,
                  scope.days[0].needsBackup == cloudFailure else { throw JournalError.invalidTransfer }
            // Arrives after the confirmation, on the very same day. It must not change this run.
            let damaged = Recording(id: UUID(), startedAt: entry.startedAt, duration: 10,
                state: .damaged, note: "模拟损坏录音", timeZoneIdentifier: entry.timeZoneIdentifier)
            if !cloudFailure {
                try store.save(damaged)
                try Data([0]).write(to: store.audio(damaged.id))
            }
            let success = await processDays(automatic: false, preview: scope)
            let saved = try store.recording(entry.id)
            let exists = FileManager.default.fileExists(atPath: try store.audio(entry.id).path)
            let digests = days.flatMap(\.meetings)
            guard digests.count == 1, digests[0].events.count == 1,
                  digests[0].location?.latitude == 31.230,
                  digests[0].events[0].peakBPM == 120,
                  success != cloudFailure, exists == cloudFailure,
                  (saved.rawDeletedAt == nil) == cloudFailure else { throw JournalError.invalidTransfer }
            if cloudFailure {
                let day = JournalDayKey(recording: entry)
                guard dailyIssues[.backup]?.isEmpty == false,
                      let deadline = workState.backupRetries[day.id]?.nextAttempt else {
                    throw JournalError.invalidTransfer
                }
                guard await processDays(automatic: false) == false,
                      workState.backupRetries[day.id]?.nextAttempt == deadline,
                      workState.backupRetries[day.id]?.failures == 1,
                      var legacy = try store.daily(day) else { throw JournalError.invalidTransfer }
                legacy.requiredBackupIDs = nil
                try store.saveDaily(legacy)
                workState.backupRetries.removeValue(forKey: day.id)
                try workState.save(store)
                guard await processDays(automatic: false) == false,
                      workState.backupRetries[day.id]?.failures == 1 else { throw JournalError.invalidTransfer }
            }
            if !cloudFailure {
                guard jobs[entry.id]?.notes.isEmpty == true else { throw JournalError.invalidTransfer }
                guard await processDays(automatic: false) == false,
                      dailyIssues[.audio]?.isEmpty == false,
                      days.flatMap(\.meetings).count == 1,
                      try store.recording(damaged.id).rawDeletedAt == nil,
                      FileManager.default.fileExists(atPath: try store.audio(damaged.id).path) else {
                    throw JournalError.invalidTransfer
                }
            }
            guard JournalReview.grouped(days, monthly: true).reduce(0, { $0 + $1.meetingCount }) == 1,
                  JournalReview.grouped(days, monthly: false).reduce(0, { $0 + $1.sedentaryEvents }) == 1 else {
                throw JournalError.invalidTransfer
            }
            evidence = ["passed": true, "scenario": cloudFailure ? "backup-failure" : "daily-cleanup",
                        "meetingCount": digests.count, "eventCount": digests[0].events.count,
                        "healthDayCount": days.count, "originalExists": exists,
                        "minutesPreserved": digests[0].minutes.contains("行动项"),
                        "weeklyMonthlyVerified": true, "damagedDayRetained": !cloudFailure,
                        "lateRecordingExcludedFromConfirmedScope": !cloudFailure,
                        "backupCooldownVerified": cloudFailure, "legacyBackupRetried": cloudFailure]
        } catch {
            evidence = ["passed": false, "error": error.localizedDescription]
        }
        try? JSONSerialization.data(withJSONObject: evidence, options: .prettyPrinted).write(to: result, options: .atomic)
    }

    private func seedSimulation() throws {
        dailySettings = DailySettings(healthEnabled: true)
        let start = Calendar.current.startOfDay(for: .now).addingTimeInterval(-36 * 3600)
        var entry = Recording(id: UUID(), startedAt: start, duration: 120, state: .saved, note: "差旅模拟会议")
        entry.timeZoneIdentifier = "Asia/Shanghai"
        if !ProcessInfo.processInfo.arguments.contains("-journal-map-preview-no-location") {
            entry.location = MeetingLocation(latitude: 31.230, longitude: 121.474, accuracy: 150, capturedAt: start)
        }
        try store.save(entry)
        try Data(repeating: 0, count: 4096).write(to: store.audio(entry.id))
        var job = MeetingAnalysisJob(model: "simulation", credential: "personal", includeContext: false)
        job.state = .complete
        job.minutes = "模拟纪要：确认差旅会议的行动项，下周跟进。"
        job.notes = ["模拟分段笔记"]
        job.speechWindows = [SpeechWindow(start: start.addingTimeInterval(30), end: start.addingTimeInterval(90), cue: "语速加快")]
        try save(job, for: entry.id)
        reload()
    }
    #endif

    func syncRecordings() {
        requestRecordings(endedOnly: false, showStatus: true)
        scheduleSourceSync(force: true, requestWatch: false)
    }

    func requestRecordings(endedOnly: Bool, showStatus: Bool = false) {
        let requestID = showStatus ? UUID() : nil
        if let requestID { syncRequestID = requestID }
        do {
            try transfer.publishSettings(storage: storage, settings: dailySettings)
            let known = try store.pendingRecordings().lazy.filter { entry in
                guard entry.isPlayable, let url = try? self.store.audio(entry.id) else { return false }
                return FileManager.default.fileExists(atPath: url.path)
            }.prefix(500).map(\.id)
            let direct = try transfer.syncRecordings(known: Array(known), purged: store.pendingPurgeIDs(),
                                                     endedOnly: endedOnly, requestID: requestID)
            if showStatus { syncStatus = direct ? "已请求 · 等待录音" : "等待手表 · 请求已排队" }
        } catch {
            if showStatus { syncStatus = "无法连接手表" }
        }
    }

    private func publishStorage() {
        try? transfer.publishSettings(storage: storage, settings: dailySettings)
        try? transfer.publishProcessing(processingConfiguration)
    }

    var analysisConfiguration: String {
        analysisConfiguration(model: model, credential: credential.rawValue)
    }

    private func analysisConfiguration(model: String, credential: String) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = trimmed.isEmpty ? MeetingAnalyzer.defaultModel : trimmed
        let value = "\(credential)|\(resolved)|\(ArkCredential(rawValue: credential)?.load() ?? "missing")"
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func requireAutomaticUpload(externalPowerGranted: Bool = false) throws {
        try Task.checkCancellation()
        guard dailySettings.automatic,
              AnalysisScheduling.canRun(settings: dailySettings, externalPowerGranted: externalPowerGranted) else {
            throw CancellationError()
        }
        guard network.allows(wifiOnly: dailySettings.wifiOnly ?? true) else { throw WorkDeferred.network }
    }

    private func loadJob(_ id: UUID) {
        guard let url = try? store.analysisURL(id), let data = try? Data(contentsOf: url),
              let job = try? JSONDecoder().decode(MeetingAnalysisJob.self, from: data) else { return }
        jobs[id] = job
    }

    func savePersonalKey(_ key: String) -> Bool {
        do {
            try ArkCredential.personal.save(key)
            hasPersonalKey = true
            credential = .personal
            processingChanged()
            return true
        } catch {
            message = error.localizedDescription
            return false
        }
    }

    func removePersonalKey() {
        do {
            try ArkCredential.personal.remove()
            hasPersonalKey = false
            if credential == .personal { credential = .official }
            processingChanged()
        } catch {
            message = error.localizedDescription
        }
    }

    func analyze(_ entry: Recording) async {
        guard processingMode != .none else { message = "当前不处理，请将数据导出到 Mac。"; return }
        if processingMode == .watch {
            do { try requestWatchProcessing([entry], manual: true); message = dailyStatus }
            catch { message = error.localizedDescription }
            return
        }
        guard entry.isPlayable, jobs[entry.id]?.state != .queued || worker == nil else { return }
        guard credential.load() != nil else {
            message = AnalysisError.missingCredential.localizedDescription
            return
        }
        let selectedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedCredential = credential.rawValue
        let selectedContext = includeContext
        if selectedContext { try? await MeetingHeartRate.authorize() }
        guard recordings.contains(where: { $0.id == entry.id }), analyzing != entry.id else { return }
        let resolvedModel = selectedModel.isEmpty ? MeetingAnalyzer.defaultModel : selectedModel
        var job = MeetingAnalysisJob(model: resolvedModel, credential: selectedCredential, includeContext: selectedContext)
        if let previous = jobs[entry.id], previous.state != .complete, previous.model == resolvedModel,
           previous.credential == selectedCredential, previous.includeContext == selectedContext {
            guard previous.retry?.blockedConfiguration != analysisConfiguration else {
                message = WorkDeferred.configuration.localizedDescription
                return
            }
            job = previous
            job.state = .queued
            job.retry = nil
            job.error = nil
        }
        job.automatic = false
        do {
            try save(job, for: entry.id)
            resumeAnalysis()
        } catch {
            message = error.localizedDescription
        }
    }

    func resumeAnalysis() {
        // Legacy jobs have no source flag. Only explicitly manual jobs may bypass automatic policy.
        guard processingMode == .phone, worker == nil, !processingDays, jobs.values.contains(where: { $0.state == .queued && $0.automatic == false }) else { return }
        worker = Task { [weak self] in await self?.runAnalysis() }
    }

    private func runAnalysis() async {
        defer { worker = nil; analyzing = nil }
        while let id = jobs.first(where: { $0.value.state == .queued && $0.value.automatic == false })?.key,
              !Task.isCancelled, processingMode == .phone,
              let entry = try? store.recording(id),
              var job = jobs[entry.id] {
            analyzing = entry.id
            let configuration = analysisConfiguration(model: job.model, credential: job.credential)
            do {
                try requirePhoneProcessing()
                job.processor = .phone
                guard let key = ArkCredential(rawValue: job.credential)?.load() else {
                    throw AnalysisError.missingCredential
                }
                let result = try await analyzer.run(recording: entry, url: store.audio(entry.id), job: job, key: key,
                    format: dailySettings.audioFormat ?? .automatic, skipSilence: dailySettings.skipSilence ?? true,
                    beforeRequest: { [weak self] in try await self?.requirePhoneProcessing() }) {
                    [weak self] snapshot in
                    try await self?.save(snapshot, for: entry.id)
                }
                try requirePhoneProcessing()
                try save(result, for: entry.id)
            } catch {
                job = jobs[entry.id] ?? job
                job.state = .failed
                job.error = error.localizedDescription
                if !Task.isCancelled, !(error is CancellationError) {
                    var retry = job.retry ?? RetryState()
                    retry.fail(configuration: configuration, authentication: isAuthenticationError(error))
                    job.retry = retry
                }
                do { try save(job, for: entry.id) }
                catch {
                    jobs[entry.id] = job
                    message = error.localizedDescription
                }
            }
        }
    }

    func save(_ job: MeetingAnalysisJob, for id: UUID) throws {
        try store.saveAnalysis(JSONEncoder().encode(job), id: id, complete: job.state == .complete)
        jobs[id] = job
    }

    func reload() {
        do {
            let page = try store.list(limit: recordingLimit + 1)
            hasMoreRecordings = page.count > recordingLimit
            recordings = Array(page.prefix(recordingLimit))
            for entry in recordings { loadJob(entry.id) }
            reportArchiveDates = Set(try store.dailyKeys().map(\.localDate)).sorted()
            reportArchiveRevision = UUID()
            report = try store.report()
            days = try store.dailyReports(limit: 31)
            reportIsDaily = false
            if let latest = days.map(\.generatedAt).max(), latest >= (report?.generatedAt ?? .distantPast) {
                let recentHealth = Array(JournalReview(id: "health", days: days).healthDays.suffix(7))
                if recentHealth.contains(where: { !$0.metrics.isEmpty }) || report == nil {
                    report = HealthReport(generatedAt: latest,
                        timeZone: dailySettings.healthTimeZoneIdentifier ?? TimeZone.current.identifier,
                        days: recentHealth, unavailableMetrics: [])
                    reportIsDaily = true
                }
            }
        } catch {
            message = error.localizedDescription
        }
    }

    func loadMoreRecordings() { recordingLimit += 50; reload() }

    func updateHealthReading(enabled: Bool) {
        dailySettings.healthEnabled = enabled
        healthReadError = nil
        if enabled { Task { await refreshHealthFromScreen(requestAccess: true) } }
    }

    func refreshHealthFromScreen(requestAccess: Bool = false) async {
        guard processingMode != .none, dailySettings.healthEnabled, !processingDays, !readingHealth else { return }
        readingHealth = true
        defer { readingHealth = false; reload() }
        let generation = processingGeneration
        do {
            if requestAccess {
                try await dailyHealth.authorize()
                guard generation == processingGeneration else { return }
                workState.dirtyHealthDays.formUnion(try store.dailyKeys())
                try workState.save(store)
            }
            _ = try await readLocalHealth()
        } catch is CancellationError {
        } catch {
            if generation == processingGeneration { healthReadError = error.localizedDescription }
        }
    }

    func readLocalHealth() async throws -> [UUID: MeetingHealthData] {
        let generation = processingGeneration
        do {
            let samples = try await refreshLocalHealth()
            if generation == processingGeneration { healthReadError = nil }
            return samples
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if generation == processingGeneration { healthReadError = error.localizedDescription }
            throw error
        }
    }

    func analyzeForDay(_ entry: Recording, automatic: Bool = false, externalPowerGranted: Bool = false) async throws -> MeetingAnalysisJob {
        guard processingMode != .none else { throw CancellationError() }
        loadJob(entry.id)
        if let job = jobs[entry.id], job.state == .complete, let minutes = job.minutes, !minutes.isEmpty { return job }
        if processingMode == .watch {
            try requestWatchProcessing([entry], manual: !automatic)
            throw ProcessingDeferred.watch
        }
        try requirePhoneProcessing()
        let resolvedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        var job = MeetingAnalysisJob(
            model: resolvedModel.isEmpty ? MeetingAnalyzer.defaultModel : resolvedModel,
            credential: credential.rawValue, includeContext: false)
        if let previous = jobs[entry.id], previous.model == job.model, previous.credential == job.credential {
            job = previous
        }
        let configuration = analysisConfiguration(model: job.model, credential: job.credential)
        if let retry = job.retry, !retry.allows(configuration: configuration) {
            throw retry.blockedConfiguration == configuration ? WorkDeferred.configuration : WorkDeferred.cooldown
        }
        if !workState.uploadRetry.allows(configuration: configuration) {
            throw workState.uploadRetry.blockedConfiguration == configuration ? WorkDeferred.configuration : WorkDeferred.cooldown
        }
        job.state = .queued
        job.automatic = true
        job.processor = .phone
        job.error = nil
        try save(job, for: entry.id)
        do {
            if automatic { try requireAutomaticUpload(externalPowerGranted: externalPowerGranted) }
            guard let key = ArkCredential(rawValue: job.credential)?.load() else { throw AnalysisError.missingCredential }
            let task = Task { [self, job] in try await analyzer.run(recording: entry, url: store.audio(entry.id), job: job, key: key,
                format: dailySettings.audioFormat ?? .automatic, skipSilence: dailySettings.skipSilence ?? true,
                wifiOnly: automatic && (dailySettings.wifiOnly ?? true),
                beforeRequest: { [weak self] in
                    try await self?.requirePhoneProcessing()
                    if automatic { try await self?.requireAutomaticUpload(externalPowerGranted: externalPowerGranted) }
                }) {
                [weak self] snapshot in
                try await self?.saveDailyCheckpoint(snapshot, id: entry.id, automatic: automatic,
                                                     externalPowerGranted: externalPowerGranted)
            } }
            dailyAnalysisTask = task
            defer { dailyAnalysisTask = nil }
            let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try requirePhoneProcessing()
            try save(result, for: entry.id)
            workState.uploadRetry = RetryState()
            try workState.save(store)
            return result
        } catch {
            job = jobs[entry.id] ?? job
            job.state = .failed
            job.error = error.localizedDescription
            if !Task.isCancelled, !(error is CancellationError), !(error is WorkDeferred) {
                var retry = job.retry ?? RetryState()
                retry.fail(configuration: configuration, authentication: isAuthenticationError(error))
                job.retry = retry
                workState.uploadRetry = retry
                try workState.save(store)
            }
            try save(job, for: entry.id)
            try Task.checkCancellation()
            throw error
        }
    }

    private func saveDailyCheckpoint(_ job: MeetingAnalysisJob, id: UUID, automatic: Bool,
                                     externalPowerGranted: Bool) throws {
        try save(job, for: id)
        try requirePhoneProcessing()
        if automatic && (!dailySettings.automatic ||
            !AnalysisScheduling.canRun(settings: dailySettings, externalPowerGranted: externalPowerGranted)) {
            throw CancellationError()
        }
    }

    func compactAnalysis(_ id: UUID) throws {
        if jobs[id] == nil { loadJob(id) }
        guard var job = jobs[id] else { return }
        guard !job.notes.isEmpty || job.speechWindows != nil || job.audioPlan != nil else { return }
        job.notes = []
        job.speechWindows = nil
        job.audioPlan = nil
        try save(job, for: id)
    }

    func isAuthenticationError(_ error: Error) -> Bool {
        guard let error = error as? AnalysisError else { return false }
        switch error {
        case .missingCredential, .http(401), .http(403): return true
        default: return false
        }
    }

    func notifyWatchPurge(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        try? transfer.purgeRecordings(ids)
    }

    func delete(_ entry: Recording) -> Bool {
        guard analyzing != entry.id, !processingDays else {
            message = "这段录音正在分析，完成后可以删除。"
            return false
        }
        do {
            if entry.storage == .cloud {
                try store.purgeRaw(entry.id)
                notifyWatchPurge(try store.pendingPurgeIDs())
            } else { try store.delete(entry.id) }
            jobs.removeValue(forKey: entry.id)
            reload()
            return true
        } catch {
            message = error.localizedDescription
            return false
        }
    }

    func deleteReport() {
        do {
            try store.deleteReport()
            report = nil
        } catch {
            message = error.localizedDescription
        }
    }
}
