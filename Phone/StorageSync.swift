import Foundation

@MainActor
extension PhoneJournal {
    /// Storage consent is independent of consent to upload speech to the analysis provider.
    @discardableResult
    func synchronizeSources(force: Bool = false, requestWatch: Bool = true) async -> Int {
        guard !synchronizingStorage else { return 0 }
        synchronizingStorage = true
        defer { synchronizingStorage = false; reload() }
        var state = StorageWorkState.load(store)
        guard force || (state.nextSourceSync ?? .distantPast) <= .now else { return 0 }
        if requestWatch { requestRecordings(endedOnly: true) }
        state.nextSourceSync = .now.addingTimeInterval(3600)
        do {
            try state.save(store)
            let completions = try store.pendingCloudCompletionIDs()
            guard storage == .cloud || UserDefaults.standard.bool(forKey: "cloudInboxEnabled") || !completions.isEmpty else { return 0 }
            guard network.allows(wifiOnly: dailySettings.wifiOnly ?? true) else {
                state.nextSourceSync = .now.addingTimeInterval(300)
                try state.save(store)
                storageSyncStatus = "云端同步等待符合设置的网络"
                return 0
            }
            guard state.cloudRetry.allows(configuration: "cloud") else {
                state.nextSourceSync = state.cloudRetry.nextAttempt
                try state.save(store)
                storageSyncStatus = "云端同步等待重试"
                return 0
            }
            storageSyncStatus = "正在检查云端录音"
            for id in try store.pendingCloudCompletionIDs() {
                try Task.checkCancellation()
                try await cloudBackup.complete(id, wifiOnly: dailySettings.wifiOnly ?? true)
                try store.acknowledgeCloudCompletion(id)
            }
            let count = try await cloudBackup.importPending(into: store, wifiOnly: dailySettings.wifiOnly ?? true)
            state.cloudRetry = RetryState()
            try state.save(store)
            storageSyncStatus = count > 0 ? "已接收 \(count) 段录音" : "没有新的待同步录音"
            let completed = Date.now
            lastCloudSync = completed
            UserDefaults.standard.set(completed, forKey: "lastCloudAudioSync")
            return count
        } catch {
            if !Task.isCancelled, !(error is CancellationError) {
                state.cloudRetry.fail(configuration: "cloud", authentication: false)
                state.nextSourceSync = state.cloudRetry.nextAttempt
                try? state.save(store)
                storageSyncStatus = "云端同步未完成，原音保留在来源端：\(error.localizedDescription)"
            } else {
                storageSyncStatus = "云端同步已暂停"
            }
            return 0
        }
    }

    func scheduleSourceSync(force: Bool = false, requestWatch: Bool = true) {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-journal-processing-simulation") { return }
        if ProcessInfo.processInfo.arguments.contains("-journal-fixture") ||
            ProcessInfo.processInfo.arguments.contains("-journal-storage-simulation") { return }
        #endif
        guard sourceTask == nil else { return }
        sourceTask = Task { [weak self] in
            guard let self else { return }
            let count = await self.synchronizeSources(force: force, requestWatch: requestWatch)
            self.sourceTask = nil
            if count > 0, !Task.isCancelled { self.foregroundEntered() }
        }
    }

    func scheduledWork() async -> Bool {
        requestRecordings(endedOnly: true)
        let local = await processDays(automatic: true)
        guard !Task.isCancelled else { return false }
        let imported = await synchronizeSources()
        if imported > 0 { return await processDays(automatic: true) }
        return local || (!dailySettings.automatic && !dailySettings.healthEnabled)
    }
}
