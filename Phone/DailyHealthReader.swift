import HealthKit

actor DailyHealthReader {
    private let store = HKHealthStore()
    private var resetAnchors = false
    #if DEBUG
    private var simulatedChanges: [DateInterval] = []
    private var simulatedPeak = 120.0
    private var dailyReads = 0
    private var meetingReads = 0
    func simulateChanges(_ ranges: [DateInterval], peak: Double) {
        simulatedChanges = ranges; simulatedPeak = peak
    }
    func simulationReads() -> [Int] { [dailyReads, meetingReads] }
    #endif

    private struct SyncState: Codable {
        var start: Date
        var anchors: [String: Data] = [:]
        var sampleTimes: [String: DateInterval] = [:]
        var dirty: [DateInterval] = []
    }

    func authorize() async throws {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-journal-fixture") { return }
        #endif
        guard HKHealthStore.isHealthDataAvailable() else { throw JournalError.healthUnavailable }
        var types = Set(HealthMetric.allCases.map { $0.quantityType as HKObjectType })
        types.insert(HKObjectType.workoutType())
        try await store.requestAuthorization(toShare: [], read: types)
        resetAnchors = true
    }

    /// Persist changed intervals in the same atomic write as the new anchor.
    /// The caller acknowledges only after its own invalidation queue is durable.
    func changedIntervals(at url: URL, since start: Date) async throws -> [DateInterval] {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-journal-fixture") { return simulatedChanges }
        #endif
        var state = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(SyncState.self, from: $0) }
            ?? SyncState(start: start)
        if start < state.start || resetAnchors {
            state = SyncState(start: min(start, state.start),
                              dirty: state.dirty + [DateInterval(start: min(start, state.start), end: .now)])
            // Keep the reset durable even if the first query fails or is cancelled.
            try JSONEncoder().encode(state).write(to: url, options: .atomic)
            resetAnchors = false
        }
        let types: [HKSampleType] = HealthMetric.allCases.map(\.quantityType) + [HKObjectType.workoutType()]
        for type in types {
            var hasMore = true
            while hasMore {
                try Task.checkCancellation()
                let anchor = try state.anchors[type.identifier].flatMap {
                    try NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: $0)
                }
                let predicate = HKQuery.predicateForSamples(withStart: state.start, end: nil, options: [])
                let batch: ([HKSample], [HKDeletedObject], HKQueryAnchor?) = try await withCheckedThrowingContinuation { continuation in
                    let query = HKAnchoredObjectQuery(type: type, predicate: predicate, anchor: anchor, limit: 1000) {
                        _, samples, deleted, next, error in
                        if let error { continuation.resume(throwing: error) }
                        else { continuation.resume(returning: (samples ?? [], deleted ?? [], next)) }
                    }
                    store.execute(query)
                }
                var updated = !batch.0.isEmpty || !batch.1.isEmpty
                for sample in batch.0 {
                    let interval = DateInterval(start: sample.startDate,
                        end: max(sample.endDate, sample.startDate.addingTimeInterval(1)))
                    state.sampleTimes[sample.uuid.uuidString] = interval
                    state.dirty.append(interval)
                }
                for deleted in batch.1 {
                    if let interval = state.sampleTimes.removeValue(forKey: deleted.uuid.uuidString) {
                        state.dirty.append(interval)
                    } else {
                        // A deletion without an observed insertion cannot be dated safely.
                        state.dirty.append(DateInterval(start: state.start, end: .now))
                    }
                }
                if let next = batch.2 {
                    let data = try NSKeyedArchiver.archivedData(withRootObject: next, requiringSecureCoding: true)
                    if state.anchors[type.identifier] != data {
                        state.anchors[type.identifier] = data
                        updated = true
                    }
                }
                if updated {
                    state.dirty = HealthQueryRanges.merged(state.dirty, gap: 0)
                    try JSONEncoder().encode(state).write(to: url, options: .atomic)
                }
                hasMore = batch.0.count + batch.1.count >= 1000
            }
        }
        return state.dirty
    }

    func acknowledgeChanges(at url: URL) throws {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-journal-fixture") { simulatedChanges = []; return }
        #endif
        guard let data = try? Data(contentsOf: url) else { return }
        var state = try JSONDecoder().decode(SyncState.self, from: data)
        guard !state.dirty.isEmpty else { return }
        state.dirty = []
        try JSONEncoder().encode(state).write(to: url, options: .atomic)
    }

    func daily(_ day: JournalDayKey) async throws -> HealthDay {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-journal-fixture"), let interval = day.interval {
            dailyReads += 1
            return HealthDay(start: interval.start, localDate: day.localDate,
                             metrics: [.heartRate: Measurement(samples: [75, simulatedPeak])!, .steps: Measurement(total: 3200)])
        }
        #endif
        guard HKHealthStore.isHealthDataAvailable(), let interval = day.interval else {
            throw JournalError.healthUnavailable
        }
        var result = HealthDay(start: interval.start, localDate: day.localDate)
        let boundaries = HKQuery.predicateForSamples(withStart: interval.start, end: interval.end,
                                                     options: [.strictStartDate, .strictEndDate])
        for metric in HealthMetric.allCases {
            try Task.checkCancellation()
            let predicate = HKSamplePredicate.quantitySample(type: metric.quantityType, predicate: boundaries)
            let query = HKStatisticsQueryDescriptor(predicate: predicate,
                options: metric.isCumulative ? .cumulativeSum : [.discreteAverage, .discreteMin, .discreteMax])
            if let stats = try await query.result(for: store),
               let quantity = metric.isCumulative ? stats.sumQuantity() : stats.averageQuantity() {
                let value = quantity.doubleValue(for: metric.healthUnit)
                guard value.isFinite else { continue }
                result.metrics[metric] = metric.isCumulative ? Measurement(total: value) :
                    Measurement(value: value, minimum: stats.minimumQuantity()?.doubleValue(for: metric.healthUnit),
                                maximum: stats.maximumQuantity()?.doubleValue(for: metric.healthUnit))
            }
        }
        return result
    }

    func meeting(_ entry: Recording) async throws -> MeetingHealthData {
        try await meetings([entry])[entry.id] ?? MeetingHealthData()
    }

    func meetings(_ entries: [Recording]) async throws -> [UUID: MeetingHealthData] {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-journal-fixture") {
            if !entries.isEmpty { meetingReads += 1 }
            return Dictionary(uniqueKeysWithValues: entries.map { entry in
                let baseline = [-180.0, -120, -60].map { HeartSample(date: entry.startedAt.addingTimeInterval($0), bpm: 75) }
                return (entry.id, MeetingHealthData(heart: baseline + [HeartSample(date: entry.startedAt.addingTimeInterval(60), bpm: simulatedPeak)]))
            })
        }
        #endif
        let ranges = HealthQueryRanges.merged(entries.map {
            DateInterval(start: $0.startedAt.addingTimeInterval(-300),
                         end: $0.startedAt.addingTimeInterval(max(0, $0.duration)))
        })
        var result: [UUID: MeetingHealthData] = [:]
        for range in ranges {
            let data = try await readMeetingRange(start: range.start, end: range.end)
            for entry in entries {
                let start = entry.startedAt.addingTimeInterval(-300)
                let end = entry.startedAt.addingTimeInterval(max(0, entry.duration))
                guard start >= range.start, end <= range.end else { continue }
                let heart = data.heart.filter { $0.date >= start && $0.date < end }
                let activity = data.activity.filter { $0.start < end && $0.end > start } + (entry.motionWindows ?? [])
                result[entry.id] = MeetingHealthData(heart: heart, activity: activity,
                    note: heart.isEmpty ? "没有可读的心率样本；可能尚未同步、未授权或系统未采样。未做关联判断。" : nil)
            }
        }
        return result
    }

    private func readMeetingRange(start: Date, end: Date) async throws -> MeetingHealthData {
        let boundaries = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        let heartPredicate = HKSamplePredicate.quantitySample(type: HKQuantityType(.heartRate), predicate: boundaries)
        let heart = try await HKSampleQueryDescriptor(predicates: [heartPredicate],
            sortDescriptors: [SortDescriptor(\.startDate, order: .forward)]).result(for: store)
        try Task.checkCancellation()
        let stepsPredicate = HKSamplePredicate.quantitySample(type: HKQuantityType(.stepCount), predicate: boundaries)
        let steps = try await HKSampleQueryDescriptor(predicates: [stepsPredicate], sortDescriptors: []).result(for: store)
        let workoutPredicate = HKSamplePredicate.workout(boundaries)
        let workouts = try await HKSampleQueryDescriptor(predicates: [workoutPredicate], sortDescriptors: []).result(for: store)
        let samples = heart.filter { $0.startDate >= start && $0.startDate < end }.map {
            HeartSample(date: $0.startDate, bpm: $0.quantity.doubleValue(for: .count().unitDivided(by: .minute())))
        }
        var activity = workouts.map { ActivityWindow(start: $0.startDate, end: $0.endDate, kind: "运动训练") }
        activity += steps.filter { $0.quantity.doubleValue(for: .count()) > 0 }.map {
            ActivityWindow(start: $0.startDate, end: max($0.endDate, $0.startDate.addingTimeInterval(1)), kind: "步行")
        }
        return MeetingHealthData(heart: samples, activity: activity,
            note: samples.isEmpty ? "没有可读的心率样本；可能尚未同步、未授权或系统未采样。未做关联判断。" : nil)
    }
}
