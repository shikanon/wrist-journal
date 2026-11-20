import HealthKit

final class HealthReader {
    private let store = HKHealthStore()

    func makeReport(now: Date = .now, calendar: Calendar = .current) async throws -> HealthReport {
        guard HKHealthStore.isHealthDataAvailable() else { throw JournalError.healthUnavailable }
        let types = Set(HealthMetric.allCases.map { $0.quantityType as HKObjectType })
        try await store.requestAuthorization(toShare: [], read: types)

        let today = calendar.startOfDay(for: now)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"

        var days = (-6...0).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: today).map {
                HealthDay(start: $0, localDate: formatter.string(from: $0))
            }
        }
        guard let start = days.first?.start else { throw JournalError.healthUnavailable }
        var unavailable: [HealthMetric] = []

        for metric in HealthMetric.allCases {
            do {
                let values = try await dailyValues(for: metric, from: start, to: now,
                                                   calendar: calendar, days: days)
                for index in days.indices {
                    days[index].metrics[metric] = values[days[index].start]
                }
            } catch {
                try Task.checkCancellation()
                unavailable.append(metric)
            }
        }

        return HealthReport(generatedAt: now, timeZone: calendar.timeZone.identifier,
                            days: days, unavailableMetrics: unavailable)
    }

    private func dailyValues(for metric: HealthMetric, from start: Date, to end: Date,
                             calendar: Calendar, days: [HealthDay]) async throws -> [Date: Measurement] {
        let boundaries = HKQuery.predicateForSamples(withStart: start, end: end, options: [.strictEndDate])
        let predicate = HKSamplePredicate.quantitySample(type: metric.quantityType, predicate: boundaries)
        if metric.isCumulative {
            let query = HKStatisticsCollectionQueryDescriptor(
                predicate: predicate, options: .cumulativeSum, anchorDate: start,
                intervalComponents: DateComponents(calendar: calendar, timeZone: calendar.timeZone, day: 1)
            )
            let statistics = try await query.result(for: store)
            var values: [Date: Measurement] = [:]
            for day in days {
                if let quantity = statistics.statistics(for: day.start)?.sumQuantity() {
                    values[day.start] = Measurement(total: quantity.doubleValue(for: metric.healthUnit))
                }
            }
            return values
        }

        let samples = try await HKSampleQueryDescriptor(predicates: [predicate], sortDescriptors: [])
            .result(for: store)
        var byDay: [Date: [Double]] = [:]
        for sample in samples where sample.startDate >= start && sample.startDate < end {
            byDay[calendar.startOfDay(for: sample.startDate), default: []]
                .append(sample.quantity.doubleValue(for: metric.healthUnit))
        }
        return byDay.compactMapValues(Measurement.init(samples:))
    }
}

private extension HealthMetric {
    var quantityType: HKQuantityType {
        switch self {
        case .heartRate: HKQuantityType(.heartRate)
        case .restingHeartRate: HKQuantityType(.restingHeartRate)
        case .variability: HKQuantityType(.heartRateVariabilitySDNN)
        case .steps: HKQuantityType(.stepCount)
        case .activeEnergy: HKQuantityType(.activeEnergyBurned)
        }
    }

    var healthUnit: HKUnit {
        switch self {
        case .heartRate, .restingHeartRate: .count().unitDivided(by: .minute())
        case .variability: .secondUnit(with: .milli)
        case .steps: .count()
        case .activeEnergy: .kilocalorie()
        }
    }
}
