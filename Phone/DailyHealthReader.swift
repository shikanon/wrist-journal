import HealthKit

actor DailyHealthReader {
    private let store = HKHealthStore()

    func authorize() async throws {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-journal-fixture") { return }
        #endif
        guard HKHealthStore.isHealthDataAvailable() else { throw JournalError.healthUnavailable }
        var types = Set(HealthMetric.allCases.map { $0.quantityType as HKObjectType })
        types.insert(HKObjectType.workoutType())
        try await store.requestAuthorization(toShare: [], read: types)
    }

    func daily(_ day: JournalDayKey) async throws -> HealthDay {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-journal-fixture"), let interval = day.interval {
            return HealthDay(start: interval.start, localDate: day.localDate,
                             metrics: [.heartRate: Measurement(samples: [75, 120])!, .steps: Measurement(total: 3200)])
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
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-journal-fixture") {
            let baseline = [-180.0, -120, -60].map { HeartSample(date: entry.startedAt.addingTimeInterval($0), bpm: 75) }
            return MeetingHealthData(heart: baseline + [HeartSample(date: entry.startedAt.addingTimeInterval(60), bpm: 120)])
        }
        #endif
        let start = entry.startedAt.addingTimeInterval(-300)
        let end = entry.startedAt.addingTimeInterval(entry.duration)
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
