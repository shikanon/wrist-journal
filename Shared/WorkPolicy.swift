import Foundation

enum CollectionMode: String, Codable, CaseIterable, Identifiable {
    case system, precise
    var id: Self { self }
    var title: String { self == .system ? "系统采样（省电）" : "精准模式" }
}

struct RetryState: Codable, Sendable {
    var failures = 0
    var nextAttempt: Date?
    var blockedConfiguration: String?

    func allows(configuration: String, now: Date = .now) -> Bool {
        if let blockedConfiguration { return blockedConfiguration != configuration }
        return nextAttempt.map { $0 <= now } ?? true
    }

    mutating func fail(configuration: String, authentication: Bool, now: Date = .now) {
        failures += 1
        if authentication {
            blockedConfiguration = configuration
            nextAttempt = nil
        } else {
            blockedConfiguration = nil
            let intervals: [TimeInterval] = [60, 300, 900, 3600, 10800, 21600]
            nextAttempt = now.addingTimeInterval(intervals[min(max(0, failures - 1), intervals.count - 1)])
        }
    }
}

enum TransferPolicy {
    static func allowsAutomatic(recording: Bool, chargingOnly: Bool, charging: Bool) -> Bool {
        !recording && (!chargingOnly || charging)
    }
}

enum HealthQueryRanges {
    static func merged(_ ranges: [DateInterval], gap: TimeInterval = 60) -> [DateInterval] {
        var result: [DateInterval] = []
        for range in ranges.sorted(by: { $0.start < $1.start }) where range.duration > 0 {
            if let last = result.last, range.start <= last.end.addingTimeInterval(gap) {
                result[result.count - 1] = DateInterval(start: last.start, end: max(last.end, range.end))
            } else { result.append(range) }
        }
        return result
    }

    static func overlaps(_ lhs: DateInterval, _ rhs: DateInterval) -> Bool {
        lhs.start < rhs.end && rhs.start < lhs.end
    }
}
