import SwiftUI

@MainActor
final class PhoneJournal: ObservableObject {
    @Published private(set) var recordings: [Recording] = []
    @Published private(set) var report: HealthReport?
    @Published private(set) var jobs: [UUID: MeetingAnalysisJob] = [:]
    @Published private(set) var analyzing: UUID?
    @Published private(set) var syncStatus: String?
    @Published private(set) var hasPersonalKey = ArkCredential.personal.load() != nil
    @Published private(set) var hasOfficialKey = false
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

    let store = JournalStore()
    private let analyzer = MeetingAnalyzer()
    private var worker: Task<Void, Never>?

    private lazy var transfer = CompanionTransfer(store: store) { [weak self] event in
        Task { @MainActor [weak self] in
            switch event {
            case .updated:
                let before = self?.recordings.count
                self?.reload()
                if self?.recordings.count != before { self?.syncStatus = "已收到手表录音" }
            case .message(let message): self?.message = message
            case .ready: self?.publishStorage()
            }
        }
    }

    init() {
        ArkCredential.loadManagedDefault()
        hasOfficialKey = ArkCredential.official.load() != nil
        reload()
        for entry in recordings {
            if let url = try? store.analysisURL(entry.id), let data = try? Data(contentsOf: url),
               let job = try? JSONDecoder().decode(MeetingAnalysisJob.self, from: data) {
                jobs[entry.id] = job
            }
        }
        transfer.activate()
    }

    func syncRecordings() {
        do {
            try transfer.publishStorage(storage)
            let known = recordings.lazy.filter { entry in
                guard entry.isPlayable, let url = try? self.store.audio(entry.id) else { return false }
                return FileManager.default.fileExists(atPath: url.path)
            }.prefix(500).map(\.id)
            let direct = try transfer.syncRecordings(known: Array(known))
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
        }
        do {
            try save(job, for: entry.id)
            resumeAnalysis()
        } catch {
            message = error.localizedDescription
        }
    }

    func resumeAnalysis() {
        guard worker == nil, jobs.values.contains(where: { $0.state == .queued }) else { return }
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

    private func save(_ job: MeetingAnalysisJob, for id: UUID) throws {
        try JSONEncoder().encode(job).write(to: store.analysisURL(id), options: .atomic)
        jobs[id] = job
    }

    private func reload() {
        do {
            recordings = try store.list()
            report = try store.report()
        } catch {
            message = error.localizedDescription
        }
    }

    func delete(_ entry: Recording) -> Bool {
        guard analyzing != entry.id else {
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
