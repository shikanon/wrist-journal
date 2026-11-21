import HealthKit

extension HealthMetric {
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
