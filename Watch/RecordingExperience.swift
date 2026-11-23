import Foundation

/// No timer is needed while locked. Only confirmation and visible controls have a deadline.
struct RecordingGuard: Equatable {
    enum Mode: Equatable { case confirming, locked, controls }
    static let holdDuration: TimeInterval = 1.5
    private(set) var mode: Mode = .locked
    private(set) var deadline: Date?

    mutating func begin(immediate: Bool, now: Date = .now) {
        mode = immediate ? .locked : .confirming
        deadline = immediate ? nil : now.addingTimeInterval(1)
    }

    mutating func unlock(active: Bool, reduced: Bool, voiceOver: Bool, now: Date = .now) {
        guard active, !reduced else { return }
        mode = .controls
        deadline = voiceOver ? nil : now.addingTimeInterval(5)
    }

    mutating func lock() { mode = .locked; deadline = nil }

    mutating func interact(voiceOver: Bool, now: Date = .now) {
        guard mode == .controls else { return }
        deadline = voiceOver ? nil : now.addingTimeInterval(5)
    }

    mutating func expire(now: Date = .now) {
        if let deadline, now >= deadline { lock() }
    }
}

struct RecordingReceipt: Codable, Equatable {
    enum Outcome: String, Codable { case saved, interrupted, failed }
    let id: UUID
    let outcome: Outcome
    let detail: String

    var title: String {
        switch outcome {
        case .saved: "已保存"
        case .interrupted: "录音已中断"
        case .failed: "录音未保存完整"
        }
    }
}

enum RecordingPreflight {
    static let minimumFree: Int64 = 16 * 1024 * 1024
    static func warning(battery: Float, charging: Bool, free: Int64?) -> String? {
        var warnings: [String] = []
        if !charging, battery >= 0, battery <= 0.2 {
            warnings.append("手表电量不超过 20%，长时间录音可能提前结束。")
        }
        if let free, free >= minimumFree, free < 64 * 1024 * 1024 {
            warnings.append("手表可用空间不足 64 MB，建议先同步已有录音。")
        }
        return warnings.isEmpty ? nil : warnings.joined(separator: "\n")
    }
}
