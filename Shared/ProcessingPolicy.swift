import Foundation

enum ProcessingDeferred: LocalizedError {
    case watch
    var errorDescription: String? { "等待 Watch 完成处理并回传结果；原音已保留。" }
}

enum ProcessingMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case watch, phone, none
    var id: Self { self }
    static func preference(_ raw: String?) -> Self { raw.flatMap(Self.init(rawValue:)) ?? .phone }
    var title: String {
        switch self {
        case .watch: "在 Watch 上处理"
        case .phone: "在手机上处理"
        case .none: "不处理，导出到 Mac"
        }
    }
    func allowsModel(on device: Self) -> Bool { self != .none && self == device }
    func retainsWatchAudio(completed: Bool, forwardedForProcessing: Bool = false) -> Bool {
        !completed && (self == .watch || forwardedForProcessing)
    }
}

/// Public paired configuration. Never include secrets or key-derived hashes.
struct ProcessingConfiguration: Codable, Equatable, Sendable {
    var mode: ProcessingMode = .phone
    var model = "doubao-seed-2-1-lite-260915"
    var credential = "official"
    var revision = UUID().uuidString
    var automatic = false
    var chargingOnly = true
    var wifiOnly = true
    var skipSilence = true
    var audioFormat: AudioUploadFormat = .automatic
    var includeContext = false
}

enum AudioUploadFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic, m4a, wav
    var id: Self { self }
    var title: String {
        switch self {
        case .automatic: "自动（已验证模型用 M4A）"
        case .m4a: "M4A 压缩音频"
        case .wav: "WAV 兼容模式"
        }
    }
    func resolved(model: String) -> Self {
        self == .automatic ? (model == ProcessingConfiguration().model ? .m4a : .wav) : self
    }
}

struct AudioSegment: Codable, Sendable {
    let startFrame: Int64
    let frameCount: Int64
}
struct AudioPlan: Codable, Sendable {
    let sampleRate: Double
    let sourceFrames: Int64
    let segments: [AudioSegment]
    var skippedSeconds: Double {
        Double(sourceFrames - segments.reduce(Int64(0)) { $0 + $1.frameCount }) / sampleRate
    }
}

struct MeetingAnalysisJob: Codable, Sendable {
    enum State: String, Codable { case queued, failed, complete }
    let model: String
    let credential: String
    let includeContext: Bool
    var state: State = .queued
    var notes: [String] = []
    var totalChunks = 0
    var minutes: String?
    var error: String?
    var speechWindows: [SpeechWindow]?
    var retry: RetryState?
    var automatic: Bool?
    var audioPlan: AudioPlan?
    var uploadFormat: AudioUploadFormat?
    var uploadedBytes: Int?
    var processor: ProcessingMode?
    var resultID: UUID?
    var citations: [SourceCitation]?
}

struct ProcessingResult: Codable, Sendable {
    let id: UUID
    let recording: Recording
    let job: MeetingAnalysisJob

    func validate() throws {
        guard recording.duration.isFinite, recording.duration > 0,
              recording.startedAt.timeIntervalSince1970.isFinite,
              recording.rawDeletedAt == nil,
              recording.state == .saved || recording.state == .interrupted,
              job.processor == .watch, job.resultID == id, job.state == .complete,
              let minutes = job.minutes, !minutes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              minutes.utf8.count <= 2_000_000,
              (job.citations ?? []).allSatisfy({ $0.isValid(for: recording) }),
              recording.validTimeline,
              (job.speechWindows ?? []).allSatisfy({
                  $0.start.timeIntervalSince1970.isFinite && $0.end.timeIntervalSince1970.isFinite &&
                  $0.start >= recording.startedAt && $0.end > $0.start &&
                  $0.end <= recording.startedAt.addingTimeInterval(recording.duration + 1)
              }) else { throw JournalError.invalidTransfer }
    }
}

struct WatchProcessingState: Codable {
    // WC applicationContext, userInfo and files have independent delivery order.
    // A request only authorizes work under the exact public configuration it named.
    var manual: [String: Set<UUID>] = [:]
    var retry = RetryState()
    static func load(_ store: JournalStore) -> Self {
        guard let url = try? store.localStateURL("watch-processing.json"),
              let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return state
    }
    func save(_ store: JournalStore) throws {
        try JSONEncoder().encode(self).write(to: store.localStateURL("watch-processing.json"), options: .atomic)
    }
}
