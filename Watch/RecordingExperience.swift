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

/// In-memory intent only: relaunch never grants permission to reopen the microphone.
struct RecordingRecovery {
    struct Pending {
        let token = UUID()
        let recordingID: UUID
        let interruptedAt: Date
        let deadline: Date
    }
    private(set) var pending: Pending?
    private(set) var attempts = 0
    static let delays: [TimeInterval] = [0, 2, 5]

    mutating func begin(recordingID: UUID, enabled: Bool, now: Date = .now) {
        cancel()
        if enabled { pending = Pending(recordingID: recordingID, interruptedAt: now, deadline: now.addingTimeInterval(120)) }
    }

    mutating func nextAttempt(shouldResume: Bool, now: Date = .now) -> TimeInterval? {
        guard shouldResume, let pending, now < pending.deadline,
              attempts < Self.delays.count else { cancel(); return nil }
        defer { attempts += 1 }
        return Self.delays[attempts]
    }

    mutating func expire(now: Date = .now) {
        if let pending, now >= pending.deadline { cancel() }
    }

    mutating func cancel() { pending = nil; attempts = 0 }
}
