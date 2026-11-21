import SwiftUI

@MainActor
final class PhoneJournal: ObservableObject {
    @Published private(set) var recordings: [Recording] = []
    @Published private(set) var report: HealthReport?
    @Published private(set) var reportIsDaily = false
    @Published private(set) var jobs: [UUID: MeetingAnalysisJob] = [:]
    @Published private(set) var analyzing: UUID?
    @Published private(set) var syncStatus: String?
    @Published private(set) var hasPersonalKey = ArkCredential.personal.load() != nil
    @Published private(set) var hasOfficialKey = false
    @Published var days: [DailyJournalReport] = []
    @Published var processingDays = false
    @Published var dailyStatus: String?
    @Published var dailySettings = DailySettings.load() {
        didSet {
            dailySettings.save()
            AnalysisScheduling.schedule(settings: dailySettings)
            if !dailySettings.automatic { automaticDailyTask?.cancel() }
        }
    }
    @Published var storage = RecordingStorage(rawValue: UserDefaults.standard.string(forKey: RecordingStorage.settingsKey) ?? "") ?? .automatic {
        didSet {
            UserDefaults.standard.set(storage.rawValue, forKey: RecordingStorage.settingsKey)
            publishStorage()
        }
    }
    @Published var credential = ArkCredential(rawValue: UserDefaults.standard.string(forKey: "arkCredential") ?? "") ?? .official {
        didSet { UserDefaults.standard.set(credential.rawValue, forKey: "arkCredential") }
    }
    @Published var model = UserDefaults.standard.string(forKey: "arkModel") ?? MeetingAnalyzer.defaultModel {
        didSet { UserDefaults.standard.set(model, forKey: "arkModel") }
    }
    @Published var includeContext = UserDefaults.standard.bool(forKey: "includeMeetingContext") {
        didSet { UserDefaults.standard.set(includeContext, forKey: "includeMeetingContext") }
    }
    @Published var message: String?

    let store: JournalStore
    let analyzer = MeetingAnalyzer()
    let dailyHealth = DailyHealthReader()
    lazy var cloudBackup = CloudBackup()
    private var worker: Task<Void, Never>?
    private var automaticDailyTask: Task<Void, Never>?
    var hasAnalysisWorker: Bool { worker != nil }

    func foregroundEntered() {
        resumeAnalysis()
        guard automaticDailyTask == nil, dailySettings.automatic else { return }
        automaticDailyTask = Task { [weak self] in
            guard let self else { return }
            defer { self.automaticDailyTask = nil }
            _ = await self.processDays(automatic: true)
        }
    }

    func foregroundExited() {
        automaticDailyTask?.cancel()
        AnalysisScheduling.schedule(settings: dailySettings)
    }

    private lazy var transfer = CompanionTransfer(store: store) { [weak self] event in
        Task { @MainActor [weak self] in
            switch event {
            case .updated:
                let before = self?.recordings.count
                self?.reload()
                if self?.recordings.count != before { self?.syncStatus = "已收到手表录音" }
            case .message(let message): self?.message = message
            case .ready:
                self?.publishStorage()
                if let ids = try? self?.store.purgedIDs() { self?.notifyWatchPurge(ids) }
            }
        }
    }

    init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-journal-fixture") {
            let root = URL.applicationSupportDirectory.appendingPathComponent("WristJournalUITests")
            if ProcessInfo.processInfo.arguments.contains("-journal-fixture-reset") { try? FileManager.default.removeItem(at: root) }
            store = JournalStore(root: root)
        } else { store = JournalStore() }
        #else
        store = JournalStore()
        #endif
        ArkCredential.loadManagedDefault()
        hasOfficialKey = ArkCredential.official.load() != nil
        reload()
        for entry in recordings {
            if let url = try? store.analysisURL(entry.id), let data = try? Data(contentsOf: url),
               let job = try? JSONDecoder().decode(MeetingAnalysisJob.self, from: data) {
                jobs[entry.id] = job
            }
        }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-journal-fixture"),
           ProcessInfo.processInfo.arguments.contains("-journal-fixture-reset") {
            do { try seedSimulation() }
            catch { message = error.localizedDescription }
        }
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
            let success = await processDays(automatic: false)
            let saved = try store.recording(entry.id)
            let exists = FileManager.default.fileExists(atPath: try store.audio(entry.id).path)
            let digests = days.flatMap(\.meetings)
            guard digests.count == 1, digests[0].events.count == 1,
                  digests[0].location?.latitude == 31.230,
                  digests[0].events[0].peakBPM == 120,
                  success != cloudFailure, exists == cloudFailure,
                  (saved.rawDeletedAt == nil) == cloudFailure else { throw JournalError.invalidTransfer }
            if !cloudFailure {
                guard jobs[entry.id]?.notes.isEmpty == true else { throw JournalError.invalidTransfer }
                _ = await processDays(automatic: false)
                guard days.flatMap(\.meetings).count == 1 else { throw JournalError.invalidTransfer }
                let damaged = Recording(id: UUID(), startedAt: entry.startedAt, duration: 10,
                    state: .damaged, note: "模拟损坏录音", timeZoneIdentifier: entry.timeZoneIdentifier)
                try store.save(damaged)
                try Data([0]).write(to: store.audio(damaged.id))
                guard await processDays(automatic: false) == false,
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
                        "weeklyMonthlyVerified": true, "damagedDayRetained": !cloudFailure]
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
        entry.location = MeetingLocation(latitude: 31.230, longitude: 121.474, accuracy: 150, capturedAt: start)
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
        do {
            try transfer.publishStorage(storage)
            let known = recordings.lazy.filter { entry in
                guard entry.isPlayable, let url = try? self.store.audio(entry.id) else { return false }
                return FileManager.default.fileExists(atPath: url.path)
            }.prefix(500).map(\.id)
            let direct = try transfer.syncRecordings(known: Array(known), purged: store.purgedIDs())
            syncStatus = direct ? "正在请求录音，文件会陆续到达" : "已排队，手表可用后会自动同步"
        } catch {
            message = error.localizedDescription
        }
    }

    private func publishStorage() { try? transfer.publishStorage(storage) }

    func savePersonalKey(_ key: String) -> Bool {
        do {
            try ArkCredential.personal.save(key)
            hasPersonalKey = true
            credential = .personal
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
        } catch {
            message = error.localizedDescription
        }
    }

    func analyze(_ entry: Recording) async {
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
            job.notes = previous.notes
            job.totalChunks = previous.totalChunks
            job.speechWindows = previous.speechWindows
        }
        do {
            try save(job, for: entry.id)
            resumeAnalysis()
        } catch {
            message = error.localizedDescription
        }
    }

    func resumeAnalysis() {
        guard worker == nil, !processingDays, jobs.values.contains(where: { $0.state == .queued }) else { return }
        worker = Task { [weak self] in await self?.runAnalysis() }
    }

    private func runAnalysis() async {
        defer { worker = nil; analyzing = nil }
        while let entry = recordings.reversed().first(where: { jobs[$0.id]?.state == .queued }),
              var job = jobs[entry.id] {
            analyzing = entry.id
            do {
                guard let key = ArkCredential(rawValue: job.credential)?.load() else {
                    throw AnalysisError.missingCredential
                }
                let result = try await analyzer.run(recording: entry, url: store.audio(entry.id), job: job, key: key) {
                    [weak self] snapshot in
                    try await self?.save(snapshot, for: entry.id)
                }
                try save(result, for: entry.id)
            } catch {
                job = jobs[entry.id] ?? job
                job.state = .failed
                job.error = error.localizedDescription
                do { try save(job, for: entry.id) }
                catch {
                    jobs[entry.id] = job
                    message = error.localizedDescription
                }
            }
        }
    }

    func save(_ job: MeetingAnalysisJob, for id: UUID) throws {
        try JSONEncoder().encode(job).write(to: store.analysisURL(id), options: .atomic)
        jobs[id] = job
    }

    func reload() {
        do {
            recordings = try store.list()
            report = try store.report()
            days = try store.dailyReports()
            reportIsDaily = false
            if let latest = days.map(\.generatedAt).max(), latest >= (report?.generatedAt ?? .distantPast) {
                report = HealthReport(generatedAt: latest,
                    timeZone: dailySettings.healthTimeZoneIdentifier ?? TimeZone.current.identifier,
                    days: Array(JournalReview(id: "health", days: days).healthDays.suffix(7)),
                    unavailableMetrics: [])
                reportIsDaily = true
            }
        } catch {
            message = error.localizedDescription
        }
    }

    func authorizeDailyHealth() async {
        do { try await dailyHealth.authorize() }
        catch { message = error.localizedDescription }
    }

    func analyzeForDay(_ entry: Recording, automatic: Bool = false, externalPowerGranted: Bool = false) async throws -> MeetingAnalysisJob {
        if let job = jobs[entry.id], job.state == .complete, let minutes = job.minutes, !minutes.isEmpty { return job }
        let resolvedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        var job = MeetingAnalysisJob(
            model: resolvedModel.isEmpty ? MeetingAnalyzer.defaultModel : resolvedModel,
            credential: credential.rawValue, includeContext: false)
        if let previous = jobs[entry.id], previous.model == job.model, previous.credential == job.credential {
            job = previous
        }
        guard let key = ArkCredential(rawValue: job.credential)?.load() else { throw AnalysisError.missingCredential }
        job.state = .queued
        job.error = nil
        try save(job, for: entry.id)
        do {
            let result = try await analyzer.run(recording: entry, url: store.audio(entry.id), job: job, key: key) {
                [weak self] snapshot in
                try await self?.saveDailyCheckpoint(snapshot, id: entry.id, automatic: automatic,
                                                     externalPowerGranted: externalPowerGranted)
            }
            try save(result, for: entry.id)
            return result
        } catch {
            job = jobs[entry.id] ?? job
            job.state = .failed
            job.error = error.localizedDescription
            try save(job, for: entry.id)
            throw error
        }
    }

    private func saveDailyCheckpoint(_ job: MeetingAnalysisJob, id: UUID, automatic: Bool,
                                     externalPowerGranted: Bool) throws {
        try save(job, for: id)
        if automatic && (!dailySettings.automatic ||
            !AnalysisScheduling.canRun(settings: dailySettings, externalPowerGranted: externalPowerGranted)) {
            throw CancellationError()
        }
    }

    func compactAnalysis(_ id: UUID) throws {
        guard var job = jobs[id] else { return }
        job.notes = []
        job.speechWindows = nil
        try save(job, for: id)
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
            try store.delete(entry.id)
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
