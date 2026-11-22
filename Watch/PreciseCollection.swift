import CoreMotion
import HealthKit

/// Opt-in, recording-scoped motion acquisition and live observation of system heart samples.
/// HealthKit does not expose a general-purpose switch for faster heart sampling.
@MainActor
final class PreciseCollection {
    private let motion = CMMotionManager()
    private let health = HKHealthStore()
    private var query: HKAnchoredObjectQuery?
    private var token: UUID?
    private var bucketStart: Date?
    private var moving = 0
    private var samples = 0
    private var windows: [ActivityWindow] = []
    private let status: (String) -> Void
    init(status: @escaping (String) -> Void) { self.status = status }

    func start(at start: Date) async {
        _ = stop()
        let token = UUID()
        self.token = token
        status("精准模式 · 心率由系统采样")
        if motion.isDeviceMotionAvailable {
            motion.deviceMotionUpdateInterval = 0.1
            let bootDate = Date.now.addingTimeInterval(-ProcessInfo.processInfo.systemUptime)
            motion.startDeviceMotionUpdates(to: .main) { [weak self] value, error in
                Task { @MainActor in
                    guard let self, self.token == token else { return }
                    guard let value else {
                        if error != nil { self.status("运动采集不可用 · 继续使用系统健康数据") }
                        return
                    }
                    let date = bootDate.addingTimeInterval(value.timestamp)
                    if let bucketStart = self.bucketStart, date.timeIntervalSince(bucketStart) >= 5 {
                        self.flush(at: date)
                    }
                    if self.bucketStart == nil { self.bucketStart = date }
                    let a = value.userAcceleration
                    if a.x * a.x + a.y * a.y + a.z * a.z > 0.0016 { self.moving += 1 }
                    self.samples += 1
                }
            }
        } else { status("运动传感器不可用 · 心率由系统采样") }
        guard HKHealthStore.isHealthDataAvailable() else { return }
        do {
            try await health.requestAuthorization(toShare: [], read: [HKQuantityType(.heartRate)])
            guard self.token == token else { return }
            let predicate = HKQuery.predicateForSamples(withStart: start, end: nil, options: .strictStartDate)
            let handler: @Sendable (HKAnchoredObjectQuery, [HKSample]?, [HKDeletedObject]?, HKQueryAnchor?, Error?) -> Void = {
                [weak self] _, added, _, _, error in
                let sample = (added as? [HKQuantitySample])?.max { $0.startDate < $1.startDate }
                let bpm = sample?.quantity.doubleValue(for: .count().unitDivided(by: .minute()))
                Task { @MainActor in
                    guard let self, self.token == token else { return }
                    if let bpm, bpm.isFinite, (1...400).contains(bpm) {
                        self.status("精准模式 · 最近心率 \(Int(bpm)) bpm")
                    } else if error != nil { self.status("心率不可读 · 运动采集继续") }
                }
            }
            let query = HKAnchoredObjectQuery(type: HKQuantityType(.heartRate), predicate: predicate,
                anchor: nil, limit: HKObjectQueryNoLimit, resultsHandler: handler)
            query.updateHandler = handler
            self.query = query
            health.execute(query)
        } catch { status("心率不可读 · 运动采集继续") }
    }

    private func flush(at end: Date) {
        if let start = bucketStart, samples >= 5, moving * 5 >= samples, end > start {
            // Wrist motion is activity evidence, not an inferred workout or a diagnosis.
            if let previous = windows.last, start.timeIntervalSince(previous.end) < 1 {
                windows[windows.count - 1] = ActivityWindow(start: previous.start, end: end, kind: "手腕运动")
            } else { windows.append(ActivityWindow(start: start, end: end, kind: "手腕运动")) }
        }
        bucketStart = nil; samples = 0; moving = 0
    }

    @discardableResult
    func stop() -> [ActivityWindow] {
        token = nil
        motion.stopDeviceMotionUpdates()
        if let query { health.stop(query) }
        query = nil
        flush(at: .now)
        let result = windows
        windows = []
        return result
    }
}
