import Foundation

struct Recording: Codable, Identifiable, Sendable {
    enum State: String, Codable {
        case recording, saved, interrupted, damaged
    }

    let id: UUID
    let startedAt: Date
    var duration: TimeInterval = 0
    var state: State = .recording
    var note = ""
    var storage: RecordingStorage?
    var location: MeetingLocation?
    var timeZoneIdentifier: String?
    var rawDeletedAt: Date?
    var motionWindows: [ActivityWindow]?
    var cloudUploadedAt: Date?
    var localEvictedAt: Date?
    var phoneReceivedAt: Date?
    var remoteAnalysisComplete: Bool?
    var watchProcessingReceivedAt: Date?
    var awaitingWatchResult: Bool?
    var markers: [RecordingMarker]?
    var continuation: RecordingContinuation?

    var validTimeline: Bool {
        let values = markers ?? []
        guard Set(values.map(\.id)).count == values.count,
              values.allSatisfy({ $0.offset.isFinite && $0.offset >= 0 && $0.offset <= duration + 1
                  && !$0.label.isEmpty && $0.label.count <= 200 }) else { return false }
        if let continuation {
            return continuation.previousRecordingID != id &&
                continuation.gapStartedAt.timeIntervalSince1970.isFinite &&
                continuation.resumedAt.timeIntervalSince1970.isFinite &&
                continuation.resumedAt == startedAt &&
                continuation.gapStartedAt <= continuation.resumedAt
        }
        return true
    }

    mutating func addMarker(at offset: TimeInterval) -> RecordingMarker? {
        guard offset.isFinite, offset >= 0,
              (markers?.last.map { offset - $0.offset >= 1 } ?? true) else { return nil }
        let marker = RecordingMarker(id: UUID(), offset: offset, label: "标记 \((markers?.count ?? 0) + 1)")
        markers = (markers ?? []) + [marker]
        return marker
    }

    var isPlayable: Bool { rawDeletedAt == nil && localEvictedAt == nil && (state == .saved || state == .interrupted) }
    var needsLocalProcessing: Bool {
        rawDeletedAt == nil && (remoteAnalysisComplete == true || !(storage == .phone && localEvictedAt != nil))
    }

    var title: String {
        note.isEmpty ? startedAt.formatted(date: .abbreviated, time: .shortened) : note
    }
}

struct RecordingMarker: Codable, Identifiable, Sendable, Equatable {
    let id: UUID
    let offset: TimeInterval
    let label: String
}

struct RecordingContinuation: Codable, Sendable {
    let sessionID: UUID
    let previousRecordingID: UUID
    let gapStartedAt: Date
    let resumedAt: Date
    var gapDuration: TimeInterval { max(0, resumedAt.timeIntervalSince(gapStartedAt)) }
    var detail: String { "中断后续录 · 中间约 \(durationText(gapDuration)) 未录制" }
}

enum RecordingStorage: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic, watch, phone, cloud

    static let settingsKey = "recordingStorage"
    static var allCases: [Self] { [.watch, .phone, .cloud] }
    static func preference(_ raw: String?) -> Self {
        guard let raw, let value = Self(rawValue: raw), value != .automatic else { return .watch }
        return value
    }
    var id: Self { self }

    var title: String {
        switch self {
        case .automatic, .watch: "优先手表（省电）"
        case .phone: "优先手机（省手表空间）"
        case .cloud: "优先云端"
        }
    }

    func destination(free: Int64?, capacity: Int64?) -> Self {
        guard self == .automatic else { return self }
        return .watch
    }
}

struct MeetingLocation: Codable, Sendable {
    let latitude: Double
    let longitude: Double
    var accuracy: Double?
    var capturedAt: Date?
}

enum HealthMetric: String, Codable, CaseIterable, Identifiable, Sendable {
    case heartRate, restingHeartRate, variability, steps, activeEnergy

    var id: Self { self }

    var title: String {
        switch self {
        case .heartRate: "心率"
        case .restingHeartRate: "静息心率"
        case .variability: "心率变异性（SDNN）"
        case .steps: "步数"
        case .activeEnergy: "活动能量"
        }
    }

    var unit: String {
        switch self {
        case .heartRate, .restingHeartRate: "bpm"
        case .variability: "ms"
        case .steps: "步"
        case .activeEnergy: "kcal"
        }
    }

    var isCumulative: Bool { self == .steps || self == .activeEnergy }

    func display(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(isCumulative ? 0 : 1)))
    }
}

struct Measurement: Codable, Sendable {
    let value: Double
    let minimum: Double?
    let maximum: Double?
    let sampleCount: Int?

    init(total: Double) {
        value = total
        minimum = nil
        maximum = nil
        sampleCount = nil
    }

    init?(samples: [Double]) {
        guard let lowest = samples.min(), let highest = samples.max() else { return nil }
        value = samples.reduce(0, +) / Double(samples.count)
        minimum = lowest
        maximum = highest
        sampleCount = samples.count
    }

    init(value: Double, minimum: Double?, maximum: Double?, sampleCount: Int? = nil) {
        self.value = value
        self.minimum = minimum
        self.maximum = maximum
        self.sampleCount = sampleCount
    }
}

struct HealthDay: Codable, Identifiable, Sendable {
    let start: Date
    let localDate: String
    var metrics: [HealthMetric: Measurement] = [:]

    var id: Date { start }
}

struct HealthReport: Codable, Sendable {
    let generatedAt: Date
    let timeZone: String
    let days: [HealthDay]
    let unavailableMetrics: [HealthMetric]

    func summary(_ metric: HealthMetric) -> Double? {
        let values = days.compactMap { $0.metrics[metric] }
        guard !values.isEmpty else { return nil }

        if metric.isCumulative {
            return values.reduce(0) { $0 + $1.value }
        }

        let count = values.reduce(0) { $0 + ($1.sampleCount ?? 1) }
        guard count > 0 else { return nil }
        return values.reduce(0) { $0 + $1.value * Double($1.sampleCount ?? 1) } / Double(count)
    }
}

enum JournalError: LocalizedError {
    case microphoneDenied, recordingFailed, playbackFailed, healthUnavailable
    case phoneUnavailable, watchUnavailable, invalidTransfer, storageFull

    var errorDescription: String? {
        switch self {
        case .microphoneDenied: "请在系统设置中允许访问麦克风。"
        case .recordingFailed: "录音未能保存为可播放文件。"
        case .playbackFailed: "无法开始播放这段录音。"
        case .healthUnavailable: "此设备无法读取健康数据。"
        case .phoneUnavailable: "请确认配对 iPhone 已安装并打开恩名手记，然后重试。"
        case .watchUnavailable: "正在等待手表连接。请确认手表已安装恩名手记，并保持两台设备在附近。"
        case .invalidTransfer: "收到的文件不完整或无法识别。"
        case .storageFull: "手表可用空间不足以安全录音。请先同步已有录音，或清理手表空间。"
        }
    }
}

func durationText(_ seconds: TimeInterval) -> String {
    let whole = Int(max(0, seconds))
    let minutes = (whole / 60) % 60
    let seconds = whole % 60
    if whole >= 3600 {
        return String(format: "%d:%02d:%02d", whole / 3600, minutes, seconds)
    }
    return String(format: "%02d:%02d", minutes, seconds)
}
