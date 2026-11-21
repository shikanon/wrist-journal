import BackgroundTasks
import UIKit

@MainActor
enum AnalysisScheduling {
    static let identifier = "io.github.shikanon.wristjournal.daily"

    static func register(journal: PhoneJournal) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
            guard let task = task as? BGProcessingTask else { task.setTaskCompleted(success: false); return }
            Task { @MainActor in
                let run = Task { await journal.processDays(automatic: true) }
                task.expirationHandler = { run.cancel() }
                let success = await run.value
                task.setTaskCompleted(success: success)
                schedule(settings: journal.dailySettings)
            }
        }
    }

    static func schedule(settings: DailySettings) {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
        guard settings.automatic else { return }
        let request = BGProcessingTaskRequest(identifier: identifier)
        request.requiresExternalPower = settings.chargingOnly
        request.requiresNetworkConnectivity = true
        request.earliestBeginDate = Calendar.current.date(byAdding: .day, value: 1,
                                                         to: Calendar.current.startOfDay(for: .now))
        try? BGTaskScheduler.shared.submit(request)
    }

    static func canRun(settings: DailySettings, externalPowerGranted: Bool = false) -> Bool {
        guard !ProcessInfo.processInfo.isLowPowerModeEnabled,
              ProcessInfo.processInfo.thermalState != .serious,
              ProcessInfo.processInfo.thermalState != .critical else { return false }
        guard settings.chargingOnly, !externalPowerGranted else { return true }
        UIDevice.current.isBatteryMonitoringEnabled = true
        return [.charging, .full].contains(UIDevice.current.batteryState)
    }
}
