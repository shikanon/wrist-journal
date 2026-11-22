import BackgroundTasks
import UIKit
import Network

@MainActor
final class UploadNetwork {
    private let monitor = NWPathMonitor()
    private var path: NWPath?
    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in self?.path = path }
        }
        monitor.start(queue: DispatchQueue(label: "journal.network"))
    }
    deinit { monitor.cancel() }
    func allows(wifiOnly: Bool) -> Bool {
        guard let path, path.status == .satisfied else { return false }
        return !wifiOnly || (path.usesInterfaceType(.wifi) && !path.isExpensive && !path.isConstrained)
    }
}

enum WorkDeferred: LocalizedError {
    case network, cooldown, configuration
    var errorDescription: String? {
        switch self {
        case .network: "等待符合设置的网络；健康本地统计不受影响。"
        case .cooldown: "请求处于重试冷却期，稍后自动继续。"
        case .configuration: "请求已暂停，请更新 API Key 或模型配置后重试。"
        }
    }
}

@MainActor
enum AnalysisScheduling {
    static let identifier = "io.github.shikanon.wristjournal.daily"
    private static var registered = false

    static func register(journal: PhoneJournal) {
        registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
            guard let task = task as? BGProcessingTask else { task.setTaskCompleted(success: false); return }
            Task { @MainActor in
                let run = Task { await journal.scheduledWork() }
                task.expirationHandler = { run.cancel() }
                let success = await run.value
                task.setTaskCompleted(success: success)
                schedule(settings: journal.dailySettings)
            }
        }
    }

    static func schedule(settings: DailySettings) {
        guard registered else { return }
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
        let request = BGProcessingTaskRequest(identifier: identifier)
        request.requiresExternalPower = false
        // Local health work must be eligible even without a network.
        request.requiresNetworkConnectivity = false
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
