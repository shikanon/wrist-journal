import Foundation
import WatchKit

@MainActor
extension WatchJournal {
    var processingMode: ProcessingMode { transfer.processing.mode }

    func requestProcessing(_ ids: [UUID], revision: String? = nil) {
        let revision = revision ?? transfer.processing.revision
        var state = WatchProcessingState.load(store)
        state.manual[revision, default: []].formUnion(ids)
        do { try state.save(store); queueProcessing() }
        catch { processingStatus = error.localizedDescription }
    }

    func pauseProcessing() { processingTask?.cancel() }
    func waitForProcessing() async { await processingTask?.value }

    func queueProcessing() {
        let config = transfer.processing
        if activeProcessingConfiguration != config { pauseProcessing() }
        guard current == nil, !starting, recovery.pending == nil else { pauseProcessing(); return }
        try? transfer.sendResults()
        if ((try? store.pendingResults().count) ?? 0) > 0 {
            scheduleStorage(at: .now.addingTimeInterval(900))
        }
        guard config.mode == .watch else {
            processingStatus = config.mode.title
            releaseConfirmedAudio()
            return
        }
        guard processingTask == nil else { return }
        activeProcessingConfiguration = config
        processingTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.processingTask = nil
                self.processingID = nil
                self.reload()
                // A new configuration may have cancelled the preceding worker.
                if self.transfer.processing != config { self.queueProcessing() }
            }
            do {
                // Restore completion after a crash between outbox and job commits.
                for url in try self.store.pendingResults() {
                    let result = try JSONDecoder().decode(ProcessingResult.self, from: Data(contentsOf: url))
                    if (try? self.store.recording(result.recording.id).rawDeletedAt) == nil {
                        try self.store.saveWatchResult(result)
                    }
                }
                let state = WatchProcessingState.load(self.store)
                let entries = try self.store.pendingRecordings().filter {
                    $0.isPlayable && (state.manual[config.revision]?.contains($0.id) == true ||
                        (config.automatic && JournalDayKey(recording: $0).hasEnded()))
                }
                guard !entries.isEmpty else {
                    self.processingStatus = "等待结束日期的录音或手动请求"
                    self.releaseConfirmedAudio()
                    if config.automatic {
                        let nextDay = try self.store.pendingRecordings().filter(\.isPlayable)
                            .compactMap { JournalDayKey(recording: $0).interval?.end }.filter { $0 > .now }.min()
                        if let nextDay { self.scheduleStorage(at: nextDay.addingTimeInterval(60)) }
                    }
                    return
                }
                for entry in entries {
                    if let job = try self.store.analysis(entry.id), job.state == .complete {
                        self.watchMinutes[entry.id] = job.minutes
                        var state = WatchProcessingState.load(self.store)
                        state.manual[config.revision]?.remove(entry.id)
                        try state.save(self.store)
                        continue
                    }
                    var state = WatchProcessingState.load(self.store)
                    guard state.retry.allows(configuration: config.revision) else {
                        self.processingStatus = state.retry.blockedConfiguration == config.revision ?
                            "等待手机更新 API 配置" : "等待重试冷却"
                        if let date = state.retry.nextAttempt { self.scheduleStorage(at: date) }
                        return
                    }
                    let manual = state.manual[config.revision]?.contains(entry.id) == true
                    try self.requireWatchProcessing(config, manual: manual)
                    self.processingStatus = "正在同步 API 配置"
                    let key = try await self.transfer.processingKey(config)
                    try self.requireWatchProcessing(config, manual: manual)
                    var job = MeetingAnalysisJob(model: config.model, credential: config.credential,
                                                 includeContext: config.includeContext)
                    if let previous = try self.store.analysis(entry.id),
                       previous.model == config.model, previous.credential == config.credential,
                       previous.includeContext == config.includeContext { job = previous }
                    job.processor = .watch
                    job.automatic = !manual
                    job.state = .queued
                    job.error = nil
                    self.processingID = entry.id
                    let result = try await self.watchAnalyzer.run(recording: entry, url: self.store.audio(entry.id),
                        job: job, key: key, format: config.audioFormat, skipSilence: config.skipSilence,
                        wifiOnly: !manual && config.wifiOnly,
                        beforeRequest: { [weak self] in try await self?.requireWatchProcessing(config, manual: manual) },
                        checkpoint: { [weak self] snapshot in
                            try await self?.watchCheckpoint(snapshot, id: entry.id, config: config, manual: manual)
                        })
                    try self.requireWatchProcessing(config, manual: manual)
                    var completed = result
                    completed.resultID = UUID()
                    try self.store.saveWatchResult(ProcessingResult(id: completed.resultID!, recording: entry, job: completed))
                    self.watchMinutes[entry.id] = completed.minutes
                    state = WatchProcessingState.load(self.store)
                    state.manual[config.revision]?.remove(entry.id)
                    state.retry = RetryState()
                    try state.save(self.store)
                    try? self.transfer.sendResults()
                    self.releaseConfirmedAudio()
                }
                self.processingStatus = "处理完成，结果等待手机确认"
            } catch is CancellationError {
                self.processingStatus = "处理已暂停，进度已保存"
                self.scheduleStorage(at: .now.addingTimeInterval(900))
            } catch {
                var state = WatchProcessingState.load(self.store)
                let authentication: Bool
                switch error as? AnalysisError {
                case .missingCredential, .http(401), .http(403): authentication = true
                default: authentication = false
                }
                if !Task.isCancelled {
                    state.retry.fail(configuration: config.revision, authentication: authentication)
                    try? state.save(self.store)
                    if let date = state.retry.nextAttempt { self.scheduleStorage(at: date) }
                }
                self.processingStatus = "原音已保留：\(error.localizedDescription)"
            }
        }
    }

    func requireWatchProcessing(_ config: ProcessingConfiguration, manual: Bool) throws {
        try Task.checkCancellation()
        guard transfer.processing == config, config.mode.allowsModel(on: .watch),
              current == nil, !starting, recovery.pending == nil else { throw CancellationError() }
        if !manual {
            let device = WKInterfaceDevice.current()
            device.isBatteryMonitoringEnabled = true
            guard config.automatic,
                  !ProcessInfo.processInfo.isLowPowerModeEnabled,
                  ![.serious, .critical].contains(ProcessInfo.processInfo.thermalState),
                  !config.chargingOnly || [.charging, .full].contains(device.batteryState) else {
                throw CancellationError()
            }
        }
    }

    private func watchCheckpoint(_ job: MeetingAnalysisJob, id: UUID, config: ProcessingConfiguration,
                                 manual: Bool) throws {
        try requireWatchProcessing(config, manual: manual)
        guard try store.recording(id).rawDeletedAt == nil else { throw CancellationError() }
        try store.saveAnalysis(JSONEncoder().encode(job), id: id, complete: false)
        processingStatus = "正在处理 \(job.notes.count)/\(job.totalChunks) 段"
    }

    func releaseConfirmedAudio() {
        do {
            for entry in try store.pendingRecordings() where entry.isPlayable {
                let complete = try store.analysis(entry.id)?.state == .complete
                guard !processingMode.retainsWatchAudio(completed: complete,
                    forwardedForProcessing: entry.awaitingWatchResult == true) else { continue }
                if entry.storage == .phone, entry.phoneReceivedAt != nil {
                    try store.evictLocal(entry.id)
                } else if entry.storage == .cloud, let date = entry.cloudUploadedAt {
                    try store.evictLocal(entry.id, cloudConfirmedAt: date)
                }
            }
        } catch { processingStatus = error.localizedDescription }
    }
}
