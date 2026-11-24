import AVFoundation
import CoreLocation
import SwiftUI
import WatchKit

@MainActor
final class WatchJournal: NSObject, ObservableObject, AVAudioRecorderDelegate, @preconcurrency CLLocationManagerDelegate {
    @Published private(set) var current: Recording?
    @Published private(set) var recordings: [Recording] = []
    @Published private(set) var report: HealthReport?
    @Published private(set) var starting = false
    @Published private(set) var receipt: RecordingReceipt?
    @Published private(set) var automaticResume = UserDefaults.standard.bool(forKey: "automaticRecordingResume")
    @Published private(set) var recovery = RecordingRecovery()
    @Published private(set) var markerStatus: String?
    private var resumeTask: Task<Void, Never>?
    private var recoveryDeadlineTask: Task<Void, Never>?
    private var startGeneration = UUID()
    @Published private(set) var generatingReport = false
    @Published var message: String?
    @Published private(set) var collectLocation = UserDefaults.standard.bool(forKey: "collectMeetingLocation")
    @Published private(set) var collectionMode = CollectionMode.system
    @Published private(set) var collectionStatus: String?
    @Published private(set) var storageStatus: String?
    @Published var processingStatus: String?
    @Published var processingID: UUID?
    @Published var watchMinutes: [UUID: String] = [:]
    @Published private(set) var recentReviewEntries: [Recording] = []
    var processingTask: Task<Void, Never>?
    var activeProcessingConfiguration: ProcessingConfiguration?
    let watchAnalyzer = MeetingAnalyzer()

    let store: JournalStore
    private let health = HealthReader()
    private var recorder: AVAudioRecorder?
    private var preciseTask: Task<Void, Never>?
    #if DEBUG
    private var recordingFeedback: [String] = []
    private var fixtureRecording: Bool {
        ProcessInfo.processInfo.arguments.contains("-journal-recording-fixture")
    }
    #endif
    private var interruptionObserver: NSObjectProtocol?
    private lazy var locationManager: CLLocationManager = {
        let manager = CLLocationManager()
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.delegate = self
        return manager
    }()
    private var locating: UUID?
    private var locationDeadline: Task<Void, Never>?
    private let cloudStorage = WatchCloudStorage()
    private var nextStorageRefresh: Date?
    private var deferredPurges: Set<UUID> = []
    private lazy var precise = PreciseCollection { [weak self] text in self?.collectionStatus = text }

    lazy var transfer: CompanionTransfer = CompanionTransfer(store: store) { [weak self] event in
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch event {
            case .message(let message): self.message = message
            case .ready:
                if self.current == nil { self.collectionMode = self.transfer.collectionMode }
                self.queueProcessing()
                self.queueRecordings()
            case .sync(let known, let purged, let endedOnly):
                self.purge(purged)
                var state = StorageWorkState.load(self.store)
                // Preserve a queued manual request when an automatic request arrives later.
                state.request = StorageSyncRequest(known: known, endedOnly: endedOnly && (state.request?.endedOnly ?? true))
                do { try state.save(self.store); self.queueRecordings() }
                catch { self.message = error.localizedDescription }
            case .received(let id): self.confirmPhoneStorage(id)
            case .purge(let ids):
                self.purge(ids)
            case .updated: self.reload(); self.queueProcessing()
            case .process(let ids, let revision): self.requestProcessing(ids, revision: revision)
            }
        }
    }

    private func purge(_ ids: [UUID]) {
        var acknowledged: [UUID] = []
        for id in ids where current?.id != id {
            do {
                transfer.cancelTransfer(id)
                try store.purgeRaw(id)
                if recovery.pending?.recordingID == id {
                    cancelRecovery(detail: "原音已清理，已取消续录。")
                }
                // Unknown IDs are already absent. Never ACK a failed unlink.
                guard !FileManager.default.fileExists(atPath: try store.audio(id).path) else { continue }
                acknowledged.append(id)
                try store.acknowledgePurge([id])
                try store.acknowledgeCloudCompletion(id)
            } catch { message = error.localizedDescription }
        }
        deferredPurges.formUnion(ids.filter { current?.id == $0 })
        try? transfer.acknowledgePurge(acknowledged)
        reload()
    }

    override init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-journal-recording-simulation") ||
            ProcessInfo.processInfo.arguments.contains("-journal-recording-ui") {
            let root = URL.applicationSupportDirectory.appendingPathComponent("WristJournalRecordingTests")
            if ProcessInfo.processInfo.arguments.contains("-journal-recording-reset") {
                try? FileManager.default.removeItem(at: root)
            }
            store = JournalStore(root: root)
        } else if ProcessInfo.processInfo.arguments.contains("-journal-processing-simulation") {
            let root = URL.applicationSupportDirectory.appendingPathComponent("WristJournalProcessingTests")
            try? FileManager.default.removeItem(at: root)
            store = JournalStore(root: root)
        } else if ProcessInfo.processInfo.arguments.contains("-journal-watch-simulation") {
            let root = URL.applicationSupportDirectory.appendingPathComponent("WristJournalWatchUITests")
            try? FileManager.default.removeItem(at: root)
            store = JournalStore(root: root)
        } else { store = JournalStore() }
        #else
        store = JournalStore()
        #endif
        super.init()
        WKInterfaceDevice.current().isBatteryMonitoringEnabled = true
        if let url = try? store.localStateURL("recording-receipt.json"),
           let data = try? Data(contentsOf: url) {
            receipt = try? JSONDecoder().decode(RecordingReceipt.self, from: data)
        }
        if let receipt, receipt.outcome == .interrupted {
            persistReceipt(RecordingReceipt(id: receipt.id, outcome: .interrupted,
                detail: "上次录音已中断，已录部分保留。请手动开始；重启不会自动续录。"))
        }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(), queue: .main
        ) { [weak self] notification in
            let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { @MainActor [weak self] in
                if type == AVAudioSession.InterruptionType.began.rawValue {
                    self?.cancelRecovery()
                    self?.finish(interrupted: true)
                } else if type == AVAudioSession.InterruptionType.ended.rawValue {
                    self?.resumeAfterInterruption(shouldResume:
                        AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume))
                }
            }
        }
        reload()
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-journal-processing-simulation") ||
            ProcessInfo.processInfo.arguments.contains("-journal-recording-simulation") ||
            ProcessInfo.processInfo.arguments.contains("-journal-recording-ui") { return }
        #endif
        transfer.activate()
    }

    #if DEBUG
    func runRecordingSimulation() async {
        var evidence: [String: Any] = [:]
        let originalResume = automaticResume
        setAutomaticResume(false)
        defer { setAutomaticResume(originalResume) }
        do {
            await start()
            guard let entry = current, (fixtureRecording || recorder?.isRecording == true),
                  recordingFeedback == ["start"] else {
                throw JournalError.recordingFailed
            }
            if !fixtureRecording { try await Task.sleep(for: .seconds(1.4)) }
            checkRecording()
            guard current?.id == entry.id else { throw JournalError.recordingFailed }
            markMoment()
            markMoment()
            finish()
            let saved = try store.recording(entry.id)
            guard saved.isPlayable, saved.duration > 0, current == nil,
                  recordingFeedback == ["start", "success"], receipt?.outcome == .saved else {
                throw JournalError.recordingFailed
            }
            evidence["actualRecorderSaved"] = !fixtureRecording
            evidence["syntheticEncodedAudio"] = fixtureRecording
            evidence["duration"] = saved.duration
            evidence["fileFrames"] = try AVAudioFile(forReading: store.audio(entry.id)).length
            evidence["feedbackAfterValidatedSave"] = true
            guard saved.markers?.count == 1, saved.validTimeline else { throw JournalError.invalidTransfer }
            evidence["markerPersistedAndRepeatedTapCoalesced"] = true
            finish()
            guard recordingFeedback.count == 2 else { throw JournalError.invalidTransfer }
            evidence["duplicateStopIgnored"] = true

            await start()
            guard current != nil else { throw JournalError.recordingFailed }
            if !fixtureRecording { try await Task.sleep(for: .seconds(1.4)) }
            NotificationCenter.default.post(name: AVAudioSession.interruptionNotification,
                object: AVAudioSession.sharedInstance(),
                userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
            try await Task.sleep(for: .milliseconds(150))
            guard current == nil, receipt?.outcome == .interrupted,
                  recordingFeedback.last == "interrupted" else { throw JournalError.invalidTransfer }
            let url = try store.localStateURL("recording-receipt.json")
            let persisted = try JSONDecoder().decode(RecordingReceipt.self, from: Data(contentsOf: url))
            guard persisted == receipt else { throw JournalError.invalidTransfer }
            evidence["interruptionObserverSavedPlayablePart"] = true
            evidence["persistentInterruptionReceipt"] = true
            guard recovery.pending == nil else { throw JournalError.invalidTransfer }
            evidence["disabledResumeNeverArmed"] = true

            setAutomaticResume(true)
            await start()
            guard let beforeResume = current else { throw JournalError.recordingFailed }
            if !fixtureRecording { try await Task.sleep(for: .seconds(1.4)) }
            postInterruption(.began)
            try await Task.sleep(for: .milliseconds(150))
            guard current == nil, recovery.pending != nil else { throw JournalError.invalidTransfer }
            postInterruption(.ended, shouldResume: true)
            // A duplicate ended notification must not open a second recorder.
            postInterruption(.ended, shouldResume: true)
            try await Task.sleep(for: .milliseconds(250))
            guard let resumed = current,
                  resumed.continuation?.previousRecordingID == beforeResume.id,
                  resumed.continuation?.sessionID == beforeResume.id,
                  recovery.pending == nil else { throw JournalError.invalidTransfer }
            if !fixtureRecording { try await Task.sleep(for: .seconds(1.4)) }
            finish()
            guard try store.recording(resumed.id).validTimeline else { throw JournalError.invalidTransfer }
            postInterruption(.ended, shouldResume: true)
            try await Task.sleep(for: .milliseconds(100))
            guard current == nil else { throw JournalError.invalidTransfer }
            evidence["optInResumesSeparateLinkedFile"] = true
            evidence["duplicateEndedAndStopDoNotResume"] = true

            for cancellation in ["user", "setting", "system", "deleted"] {
                setAutomaticResume(true)
                await start()
                if !fixtureRecording { try await Task.sleep(for: .seconds(1.4)) }
                guard current != nil else { throw JournalError.recordingFailed }
                postInterruption(.began)
                try await Task.sleep(for: .milliseconds(150))
                guard recovery.pending != nil else { throw JournalError.invalidTransfer }
                if cancellation == "user" { cancelRecovery() }
                if cancellation == "setting" { setAutomaticResume(false) }
                if cancellation == "deleted", let pending = recovery.pending {
                    guard delete(try store.recording(pending.recordingID)) else { throw JournalError.invalidTransfer }
                }
                postInterruption(.ended, shouldResume: cancellation != "system")
                try await Task.sleep(for: .milliseconds(150))
                guard current == nil, recovery.pending == nil else { throw JournalError.invalidTransfer }
                evidence["resumeCancelledBy_" + cancellation] = true
            }

            // A playable orphan left marked recording must recover during reload.
            var orphan = saved
            orphan.state = .recording
            try store.save(orphan)
            reload()
            guard try store.recording(orphan.id).state == .interrupted,
                  receipt?.id == orphan.id, receipt?.outcome == .interrupted else { throw JournalError.invalidTransfer }
            evidence["orphanRecovered"] = true

            await start()
            guard let damaged = current else { throw JournalError.recordingFailed }
            try await Task.sleep(for: .milliseconds(300))
            try FileManager.default.removeItem(at: store.audio(damaged.id))
            finish()
            guard try store.recording(damaged.id).state == .damaged,
                  receipt?.outcome == .failed, recordingFeedback.last == "failure" else { throw JournalError.invalidTransfer }
            evidence["missingAudioNeverSignalsSuccess"] = true
            dismissReceipt()
            guard receipt == nil, !FileManager.default.fileExists(atPath: url.path) else { throw JournalError.invalidTransfer }
            evidence["explicitAcknowledgementClearsReceipt"] = true
            evidence["feedback"] = recordingFeedback
            // Leave a durable interruption card for the separate cold-launch verification.
            persistReceipt(RecordingReceipt(id: orphan.id, outcome: .interrupted,
                detail: "已保留录音，等待系统允许续录。"))
            evidence["passed"] = true
        } catch {
            evidence["passed"] = false
            evidence["error"] = error.localizedDescription
            evidence["message"] = message
            evidence["feedback"] = recordingFeedback
        }
        try? JSONSerialization.data(withJSONObject: evidence, options: .prettyPrinted)
            .write(to: store.localStateURL("simulation-result.json"), options: .atomic)
    }

    func verifyRecordingColdStart() {
        let passed = receipt?.outcome == .interrupted && current == nil && recovery.pending == nil &&
            receipt?.detail.contains("手动开始") == true &&
            recordings.contains { $0.id == receipt?.id && $0.isPlayable }
        try? JSONSerialization.data(withJSONObject: ["passed": passed, "receiptRestoredAfterLaunch": passed,
                                                     "coldStartNeverResumesMicrophone": passed,
                                                     "staleWaitingReceiptCleared": passed])
            .write(to: store.localStateURL("cold-start-result.json"), options: .atomic)
    }

    private func postInterruption(_ type: AVAudioSession.InterruptionType, shouldResume: Bool = false) {
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [AVAudioSessionInterruptionTypeKey: type.rawValue,
                       AVAudioSessionInterruptionOptionKey: shouldResume ? AVAudioSession.InterruptionOptions.shouldResume.rawValue : 0])
    }

    func runSimulation() async {
        let result = URL.applicationSupportDirectory.appendingPathComponent("WristJournalWatchUITests/simulation-result.json")
        var evidence: [String: Any]
        do {
            try store.recoverEvictions()
            await start()
            guard current == nil, !starting, message == JournalError.microphoneDenied.localizedDescription else {
                finish()
                throw JournalError.invalidTransfer
            }
            let entry = Recording(id: UUID(), startedAt: .now, duration: 60, state: .saved, storage: .watch)
            try store.save(entry)
            try Data([1, 2, 3]).write(to: store.audio(entry.id))
            current = entry
            await generateReport()
            guard !generatingReport, message == "请先结束录音，再生成健康报告。" else { throw JournalError.invalidTransfer }
            current = nil
            reload()
            purge([entry.id])
            guard recordings.isEmpty, try store.recording(entry.id).rawDeletedAt != nil,
                  !FileManager.default.fileExists(atPath: try store.audio(entry.id).path) else { throw JournalError.invalidTransfer }
            evidence = ["passed": true, "microphoneDenied": true, "reportBlockedDuringRecording": true,
                        "watchPurgeVerified": true]
        } catch {
            evidence = ["passed": false, "error": error.localizedDescription]
        }
        // Ensure a directory exists even when the initial recording permission was denied.
        try? FileManager.default.createDirectory(at: result.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONSerialization.data(withJSONObject: evidence, options: .prettyPrinted).write(to: result, options: .atomic)
    }
    #endif

    deinit {
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
    }

    func reload() {
        do {
            try store.recoverEvictions()
            for id in try store.pendingPurgeIDs() {
                if FileManager.default.fileExists(atPath: try store.audio(id).path) { try store.purgeRaw(id) }
                try store.acknowledgePurge([id])
            }
            let entries = try store.pendingRecordings()
            recordings = try entries.map { entry in
                guard entry.state == .recording, current?.id != entry.id else { return entry }
                let recovered = try finalize(entry, interrupted: true)
                publishReceipt(for: recovered, interrupted: true)
                return recovered
            }.filter { $0.state != .recording && $0.rawDeletedAt == nil && !($0.storage == .phone && $0.localEvictedAt != nil) }
                .sorted { $0.startedAt > $1.startedAt }
            report = try store.report()
            recentReviewEntries = try store.list(limit: 30)
            var minutes: [UUID: String] = [:]
            for entry in recentReviewEntries {
                if let job = try store.analysis(entry.id), job.state == .complete { minutes[entry.id] = job.minutes }
            }
            watchMinutes = minutes
        } catch {
            message = error.localizedDescription
        }
    }

    @discardableResult
    func start(continuing previous: Recording? = nil, recoveryToken: UUID? = nil) async -> Bool {
        guard !starting, current == nil else { return false }
        if let recoveryToken {
            guard automaticResume, recovery.pending?.token == recoveryToken else { return false }
        } else { cancelRecovery() }
        let generation = UUID()
        startGeneration = generation
        starting = true
        message = nil
        markerStatus = nil
        pauseProcessing()
        defer { starting = false }

        let session = AVAudioSession.sharedInstance()
        var pending: Recording?
        do {
            if recoveryToken == nil {
                guard await AVAudioApplication.requestRecordPermission() else { throw JournalError.microphoneDenied }
            } else {
                guard AVAudioApplication.shared.recordPermission == .granted else { throw JournalError.microphoneDenied }
            }
            guard !Task.isCancelled, startGeneration == generation,
                  recoveryToken == nil || recovery.pending?.token == recoveryToken else { return false }
            transfer.pauseFileTransfers()
            cloudStorage.pause()
            let space = try store.availableStorage()
            if let free = space.free, free < RecordingPreflight.minimumFree { throw JournalError.storageFull }
            #if DEBUG
            if fixtureRecording {
                var entry = Recording(id: UUID(), startedAt: .now, storage: .watch)
                entry.timeZoneIdentifier = TimeZone.current.identifier
                entry.continuation = continuation(from: previous, at: entry.startedAt)
                pending = entry
                try store.save(entry)
                try AnalysisFixture.makeAudio(store.audio(entry.id))
                current = entry
                feedback(.start)
                return true
            }
            #endif
            try session.setCategory(.record)
            // watchOS suppresses haptics during input by default. This is a preference, not a guarantee.
            try? session.setAllowHapticsAndSystemSoundsDuringRecording(true)
            try? session.setPrefersNoInterruptionsFromSystemAlerts(true)
            try session.setActive(true)
            var entry = Recording(id: UUID(), startedAt: .now)
            entry.timeZoneIdentifier = TimeZone.current.identifier
            entry.storage = transfer.storage.destination(free: space.free, capacity: space.capacity)
            entry.continuation = continuation(from: previous, at: entry.startedAt)
            pending = entry
            try store.save(entry)

            let recorder = try AVAudioRecorder(url: store.audio(entry.id), settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 32_000
            ])
            recorder.isMeteringEnabled = false
            recorder.delegate = self
            guard recorder.record() else { throw JournalError.recordingFailed }
            self.recorder = recorder
            current = entry
            feedback(.start)
            collectionMode = transfer.collectionMode
            requestLocation(for: entry.id)
            if collectionMode == .precise {
                preciseTask = Task { [weak self] in
                    guard let self, self.current?.id == entry.id, !Task.isCancelled else { return }
                    await self.precise.start(at: entry.startedAt)
                }
            }
            return true
        } catch {
            if let pending { try? store.delete(pending.id) }
            try? session.setActive(false)
            if recoveryToken == nil {
                message = error.localizedDescription
                feedback(.failure)
            }
            return false
        }
    }

    private func continuation(from previous: Recording?, at date: Date) -> RecordingContinuation? {
        guard let previous else { return nil }
        return RecordingContinuation(sessionID: previous.continuation?.sessionID ?? previous.id,
            previousRecordingID: previous.id,
            gapStartedAt: min(date, recovery.pending?.interruptedAt ?? previous.startedAt.addingTimeInterval(previous.duration)),
            resumedAt: date)
    }

    func setAutomaticResume(_ enabled: Bool) {
        automaticResume = enabled
        UserDefaults.standard.set(enabled, forKey: "automaticRecordingResume")
        if !enabled { cancelRecovery(detail: "已关闭自动续录，已录部分保留。") }
    }

    func cancelRecovery(detail: String? = nil) {
        let wasPending = recovery.pending != nil
        startGeneration = UUID()
        resumeTask?.cancel()
        resumeTask = nil
        recoveryDeadlineTask?.cancel()
        recoveryDeadlineTask = nil
        recovery.cancel()
        if wasPending, let detail, let receipt {
            persistReceipt(RecordingReceipt(id: receipt.id, outcome: receipt.outcome, detail: detail))
            Task { @MainActor [weak self] in
                self?.reload()
                self?.queueRecordings()
                self?.queueProcessing()
            }
        }
    }

    private func armRecovery(for entry: Recording) {
        cancelRecovery()
        recovery.begin(recordingID: entry.id, enabled: automaticResume && entry.isPlayable)
        guard let pending = recovery.pending else { return }
        persistReceipt(RecordingReceipt(id: entry.id, outcome: .interrupted,
            detail: "已保留录音，等待系统允许续录。"))
        recoveryDeadlineTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(120))
            guard !Task.isCancelled, let self, self.recovery.pending?.token == pending.token else { return }
            self.cancelRecovery(detail: "等待续录已超时，已录部分保留。请手动开始。")
        }
    }

    private func resumeAfterInterruption(shouldResume: Bool) {
        guard let pending = recovery.pending else { return }
        guard shouldResume, automaticResume else {
            cancelRecovery(detail: "系统未允许自动续录，已录部分保留。请手动开始。")
            return
        }
        guard resumeTask == nil else { return }
        resumeTask = Task { [weak self] in
            guard let self else { return }
            while self.recovery.pending?.token == pending.token,
                  let delay = self.recovery.nextAttempt(shouldResume: true) {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, self.recovery.pending?.token == pending.token else { return }
                guard let previous = try? self.store.recording(pending.recordingID),
                      previous.isPlayable else { break }
                if await self.start(continuing: previous, recoveryToken: pending.token) {
                    self.cancelRecovery()
                    return
                }
            }
            guard !Task.isCancelled else { return }
            // nextAttempt can clear its intent after exhausting retries.
            self.cancelRecovery()
            if let receipt = self.receipt {
                self.persistReceipt(RecordingReceipt(id: receipt.id, outcome: receipt.outcome,
                    detail: "未能自动续录，已录部分保留。请手动开始。"))
            }
            self.queueRecordings()
            self.queueProcessing()
        }
    }

    func markMoment() {
        guard var entry = current else { return }
        let offset: TimeInterval
        #if DEBUG
        if fixtureRecording { offset = min(3.5, max(0, Date.now.timeIntervalSince(entry.startedAt))) }
        else { guard let recorder, recorder.isRecording else { return }; offset = recorder.currentTime }
        #else
        guard let recorder, recorder.isRecording else { return }
        offset = recorder.currentTime
        #endif
        guard let marker = entry.addMarker(at: offset) else { return }
        do {
            try store.save(entry)
            current = entry
            markerStatus = "已标记 \(durationText(marker.offset))"
            WKInterfaceDevice.current().play(.click)
        } catch { message = "标记未保存：\(error.localizedDescription)" }
    }

    func recordingWarning() -> String? {
        let device = WKInterfaceDevice.current()
        device.isBatteryMonitoringEnabled = true
        let free = try? store.availableStorage().free
        return RecordingPreflight.warning(battery: device.batteryLevel,
            charging: [.charging, .full].contains(device.batteryState), free: free)
    }

    var receiptDetail: String {
        guard let receipt else { return "" }
        guard receipt.outcome != .failed, let entry = try? store.recording(receipt.id) else { return receipt.detail }
        let location: String
        if entry.rawDeletedAt != nil { location = "原音已清理，报告保留" }
        else if entry.phoneReceivedAt != nil { location = "iPhone 已确认接收" }
        else if entry.cloudUploadedAt != nil { location = "云端已确认保存" }
        else if entry.storage == .phone { location = "已存手表 · 等待 iPhone 确认" }
        else if entry.storage == .cloud { location = "已存手表 · 等待云端确认" }
        else { location = "已存手表" }
        let prefix = receipt.outcome == .saved ? "" : "\(receipt.detail)\n"
        return "\(prefix)\(location) · \(durationText(entry.duration))"
    }

    func dismissReceipt() {
        do {
            let url = try store.localStateURL("recording-receipt.json")
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            receipt = nil
        } catch { message = error.localizedDescription }
    }

    private func publishReceipt(for entry: Recording, interrupted: Bool) {
        let outcome: RecordingReceipt.Outcome = !entry.isPlayable ? .failed : (interrupted ? .interrupted : .saved)
        let detail = !entry.isPlayable ? "文件未通过播放校验，请在录音列表检查。" :
            (interrupted ? "已保留可播放部分，请重新开始续录。" : "录音已通过播放校验。")
        persistReceipt(RecordingReceipt(id: entry.id, outcome: outcome, detail: detail))
    }

    private func persistReceipt(_ value: RecordingReceipt) {
        receipt = value
        do {
            try JSONEncoder().encode(value).write(to: store.localStateURL("recording-receipt.json"), options: .atomic)
        } catch { message = "录音结果提示未能持久保存：\(error.localizedDescription)" }
    }

    private func feedback(_ type: WKHapticType) {
        #if DEBUG
        recordingFeedback.append(type == .start ? "start" : type == .success ? "success" : type == .notification ? "interrupted" : "failure")
        #endif
        WKInterfaceDevice.current().play(type)
    }

    func checkRecording() {
        #if DEBUG
        if fixtureRecording, current != nil { return }
        #endif
        if current != nil, recorder?.isRecording != true {
            finish(interrupted: true)
        }
        queueRecordings()
        queueProcessing()
    }
    func refreshStorageInBackground() async {
        nextStorageRefresh = nil
        checkRecording()
        await cloudStorage.waitForCompletion()
        await waitForProcessing()
    }
    func waitForCloudStorage() async {
        await cloudStorage.waitForCompletion()
        await waitForProcessing()
    }
    func pauseBackgroundStorage() {
        cloudStorage.pause()
        pauseProcessing()
        scheduleStorage(at: .now.addingTimeInterval(900))
    }

    func setCollectLocation(_ enabled: Bool) {
        collectLocation = enabled
        UserDefaults.standard.set(enabled, forKey: "collectMeetingLocation")
        guard enabled else { cancelLocation(); return }
        if locationManager.authorizationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        } else if locationManager.authorizationStatus == .denied || locationManager.authorizationStatus == .restricted {
            message = "请在手表的定位设置中允许恩名手记使用位置。"
        }
    }

    private func requestLocation(for id: UUID) {
        guard locating == nil, collectLocation, [.authorizedWhenInUse, .authorizedAlways].contains(locationManager.authorizationStatus) else { return }
        locating = id
        locationManager.requestLocation()
        locationDeadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled else { return }
            self?.cancelLocation()
        }
    }

    private func cancelLocation() {
        locationDeadline?.cancel()
        locationDeadline = nil
        locationManager.stopUpdatingLocation()
        locating = nil
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        defer { cancelLocation() }
        guard collectLocation, var entry = current, entry.id == locating, let location = locations.last,
              (0...1_000).contains(location.horizontalAccuracy),
              abs(location.timestamp.timeIntervalSince(entry.startedAt)) <= 120 else { return }
        let coordinate = location.coordinate
        guard CLLocationCoordinate2DIsValid(coordinate) else { return }
        entry.location = MeetingLocation(latitude: (coordinate.latitude * 1_000).rounded() / 1_000,
                                         longitude: (coordinate.longitude * 1_000).rounded() / 1_000,
                                         accuracy: max(location.horizontalAccuracy, 150), capturedAt: location.timestamp)
        current = entry
        try? store.save(entry)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) { cancelLocation() }

    func finish(interrupted: Bool = false) {
        if !interrupted { cancelRecovery() }
        startGeneration = UUID()
        guard let current else { return }
        preciseTask?.cancel()
        preciseTask = nil
        let motion = precise.stop()
        cancelLocation()
        let recorder = self.recorder
        self.recorder = nil
        self.current = nil
        recorder?.stop()
        try? AVAudioSession.sharedInstance().setActive(false)

        do {
            var source = current
            source.motionWindows = motion.isEmpty ? nil : motion
            let saved = try finalize(source, interrupted: interrupted)
            publishReceipt(for: saved, interrupted: interrupted)
            if interrupted { armRecovery(for: saved) }
            feedback(!saved.isPlayable ? .failure : (interrupted ? .notification : .success))
            reload()
            if !deferredPurges.isEmpty {
                let ids = Array(deferredPurges)
                deferredPurges.removeAll()
                purge(ids)
            }
            if saved.isPlayable { queueRecordings() }
            queueProcessing()
        } catch {
            persistReceipt(RecordingReceipt(id: current.id, outcome: .failed,
                detail: "保存未完成，原始文件保留待恢复。\(error.localizedDescription)"))
            feedback(.failure)
            message = error.localizedDescription
        }
    }

    private func queueRecordings() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-journal-recording-simulation") ||
            ProcessInfo.processInfo.arguments.contains("-journal-recording-ui") { return }
        #endif
        let device = WKInterfaceDevice.current()
        device.isBatteryMonitoringEnabled = true
        guard TransferPolicy.allowsAutomatic(recording: current != nil || starting || recovery.pending != nil,
            chargingOnly: transfer.transferChargingOnly, charging: [.charging, .full].contains(device.batteryState)) else {
            if transfer.transferChargingOnly, current == nil, !recordings.isEmpty {
                scheduleStorage(at: .now.addingTimeInterval(1800))
            }
            return
        }
        var state = StorageWorkState.load(store)
        let request = state.request
        let due = StoragePolicy.batchDue(last: state.lastBatch, minutes: transfer.batchMinutes)
        var queuedPhone = false
        var failed = false
        for entry in recordings where entry.isPlayable {
            if entry.phoneReceivedAt != nil, entry.storage == .phone { continue }
            if request?.known.contains(entry.id) == true {
                if entry.storage == .phone { confirmPhoneStorage(entry.id) }
                continue
            }
            guard StoragePolicy.shouldSend(entry, requested: request != nil, endedOnly: request?.endedOnly ?? false,
                                            batchDue: due, recording: false) else { continue }
            do {
                _ = try transfer.send(entry)
                queuedPhone = queuedPhone || entry.storage == .phone
            } catch { failed = true; storageStatus = error.localizedDescription }
        }
        if queuedPhone { state.lastBatch = .now }
        if !failed { state.request = nil }
        try? state.save(store)
        let hasPhone = recordings.contains { $0.storage == .phone && $0.isPlayable }
        if hasPhone || failed {
            let next = failed ? Date.now.addingTimeInterval(900) :
                (state.lastBatch ?? .now).addingTimeInterval(Double(transfer.batchMinutes) * 60)
            scheduleStorage(at: max(next, .now.addingTimeInterval(60)))
        }
        if recordings.contains(where: { $0.storage == .cloud && $0.isPlayable }) {
            cloudStorage.run(store: store, mayRelease: { [weak self] id in
                guard let self else { return false }
                return !self.processingMode.retainsWatchAudio(
                    completed: (try? self.store.analysis(id)?.state) == .complete,
                    forwardedForProcessing: (try? self.store.recording(id).awaitingWatchResult) == true)
            }) { [weak self] status, retry in
                guard let self else { return }
                self.storageStatus = status ?? "云端保存已确认"
                self.reload()
                if let retry { self.scheduleStorage(at: retry) }
                self.notifyCloudIfNeeded()
            }
        } else { notifyCloudIfNeeded() }
    }

    private func notifyCloudIfNeeded() {
        var state = StorageWorkState.load(store)
        guard let latest = recordings.compactMap(\.cloudUploadedAt).max(),
              latest > (state.lastCloudNoticeAt ?? .distantPast) else { return }
        do {
            try transfer.notifyCloudAvailable()
            state.lastCloudNoticeAt = latest
            try state.save(store)
        } catch { scheduleStorage(at: .now.addingTimeInterval(900)) }
    }

    func scheduleStorage(at date: Date) {
        if let existing = nextStorageRefresh, existing > .now, existing <= date { return }
        nextStorageRefresh = date
        WKApplication.shared().scheduleBackgroundRefresh(withPreferredDate: date, userInfo: nil) { _ in }
    }

    private func confirmPhoneStorage(_ id: UUID) {
        guard let entry = recordings.first(where: { $0.id == id }), entry.storage == .phone else { return }
        do {
            var saved = try store.recording(id)
            saved.phoneReceivedAt = .now
            try store.save(saved)
            releaseConfirmedAudio()
            reload()
        } catch {
            message = error.localizedDescription
        }
    }

    private func finalize(_ entry: Recording, interrupted: Bool) throws -> Recording {
        var entry = entry
        let url = try store.audio(entry.id)
        if let audio = try? AVAudioFile(forReading: url), audio.length > 0,
           audio.processingFormat.sampleRate.isFinite, audio.processingFormat.sampleRate > 0 {
            entry.duration = Double(audio.length) / audio.processingFormat.sampleRate
            entry.state = interrupted ? .interrupted : .saved
            entry.markers = entry.markers?.map {
                RecordingMarker(id: $0.id, offset: min($0.offset, entry.duration), label: $0.label)
            }
        } else {
            entry.state = .damaged
        }
        try store.save(entry)
        return entry
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        recorderEnded(ObjectIdentifier(recorder))
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        recorderEnded(ObjectIdentifier(recorder))
    }

    private nonisolated func recorderEnded(_ identifier: ObjectIdentifier) {
        Task { @MainActor in
            if let recorder, ObjectIdentifier(recorder) == identifier {
                finish(interrupted: true)
            }
        }
    }

    func saveNote(_ note: String, for entry: Recording) {
        var updated = entry
        updated.note = String(note.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
        do {
            try store.save(updated)
            reload()
        } catch {
            message = error.localizedDescription
        }
    }

    @discardableResult
    func delete(_ entry: Recording) -> Bool {
        if processingID == entry.id || transfer.isQueued(entry.id) || (entry.storage == .cloud && cloudStorage.uploading) {
            message = "录音正在传输。传输结束后可删除。"
            return false
        }
        do {
            try store.delete(entry.id)
            if recovery.pending?.recordingID == entry.id { cancelRecovery() }
            if receipt?.id == entry.id { dismissReceipt() }
            reload()
            return true
        } catch {
            message = error.localizedDescription
            return false
        }
    }

    func send(_ entry: Recording) {
        guard current == nil, !starting, recovery.pending == nil else {
            message = "请先结束录音或取消续录，再发送文件。"
            return
        }
        do {
            let queued = try transfer.send(entry)
            message = queued ? "已加入发送队列。" : "这段录音正在等待发送。"
        } catch {
            message = error.localizedDescription
        }
    }

    func generateReport() async {
        guard !generatingReport, current == nil, !starting else {
            message = "请先结束录音，再生成健康报告。"
            return
        }
        generatingReport = true
        defer { generatingReport = false }
        do {
            let latest = try await health.makeReport()
            try store.saveReport(latest)
            report = latest
        } catch {
            message = error.localizedDescription
        }
    }

    func sendReport() {
        guard let report else { return }
        do {
            try transfer.send(report)
            message = "健康报告已加入发送队列。"
        } catch {
            message = error.localizedDescription
        }
    }

    func deleteReport() {
        do {
            try store.deleteReport()
            report = nil
        } catch {
            message = error.localizedDescription
        }
    }
}
