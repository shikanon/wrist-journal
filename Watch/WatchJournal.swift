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
    @Published private(set) var generatingReport = false
    @Published var message: String?
    @Published private(set) var collectLocation = UserDefaults.standard.bool(forKey: "collectMeetingLocation")
    @Published private(set) var collectionMode = CollectionMode.system
    @Published private(set) var collectionStatus: String?

    let store: JournalStore
    private let health = HealthReader()
    private var recorder: AVAudioRecorder?
    private var interruptionObserver: NSObjectProtocol?
    private lazy var locationManager: CLLocationManager = {
        let manager = CLLocationManager()
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.delegate = self
        return manager
    }()
    private var locating: UUID?
    private var locationDeadline: Task<Void, Never>?
    private var deferredKnown: Set<UUID>?
    private var deferredPurges: Set<UUID> = []
    private lazy var precise = PreciseCollection { [weak self] text in self?.collectionStatus = text }

    lazy var transfer: CompanionTransfer = CompanionTransfer(store: store) { [weak self] event in
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch event {
            case .message(let message): self.message = message
            case .ready:
                if self.current == nil { self.collectionMode = self.transfer.collectionMode }
                self.queueRecordings()
            case .sync(let known, let purged):
                self.purge(purged)
                self.queueRecordings(known: known)
            case .received(let id): self.confirmPhoneStorage(id)
            case .purge(let ids):
                self.purge(ids)
            case .updated: break
            }
        }
    }

    private func purge(_ ids: [UUID]) {
        var acknowledged: [UUID] = []
        for id in ids where current?.id != id {
            do {
                transfer.cancelTransfer(id)
                try store.purgeRaw(id)
                // Unknown IDs are already absent. Never ACK a failed unlink.
                guard !FileManager.default.fileExists(atPath: try store.audio(id).path) else { continue }
                acknowledged.append(id)
                try store.acknowledgePurge([id])
            } catch { message = error.localizedDescription }
        }
        deferredPurges.formUnion(ids.filter { current?.id == $0 })
        try? transfer.acknowledgePurge(acknowledged)
        reload()
    }

    override init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-journal-watch-simulation") {
            let root = URL.applicationSupportDirectory.appendingPathComponent("WristJournalWatchUITests")
            try? FileManager.default.removeItem(at: root)
            store = JournalStore(root: root)
        } else { store = JournalStore() }
        #else
        store = JournalStore()
        #endif
        super.init()
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(), queue: .main
        ) { [weak self] notification in
            guard notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                    == AVAudioSession.InterruptionType.began.rawValue else { return }
            Task { @MainActor [weak self] in self?.finish(interrupted: true) }
        }
        reload()
        transfer.activate()
    }

    #if DEBUG
    func runSimulation() async {
        let result = URL.applicationSupportDirectory.appendingPathComponent("WristJournalWatchUITests/simulation-result.json")
        var evidence: [String: Any]
        do {
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

    private func reload() {
        do {
            for id in try store.pendingPurgeIDs() {
                if FileManager.default.fileExists(atPath: try store.audio(id).path) { try store.purgeRaw(id) }
                try store.acknowledgePurge([id])
            }
            let entries = try store.pendingRecordings()
            recordings = try entries.map { entry in
                guard entry.state == .recording, current?.id != entry.id else { return entry }
                return try finalize(entry, interrupted: true)
            }.filter { $0.state != .recording && $0.rawDeletedAt == nil }
            report = try store.report()
        } catch {
            message = error.localizedDescription
        }
    }

    func start() async {
        guard !starting, current == nil else { return }
        starting = true
        defer { starting = false }

        let session = AVAudioSession.sharedInstance()
        var pending: Recording?
        do {
            guard await AVAudioApplication.requestRecordPermission() else { throw JournalError.microphoneDenied }
            transfer.pauseFileTransfers()
            let space = try store.availableStorage()
            if let free = space.free, free < 16 * 1024 * 1024 { throw JournalError.storageFull }
            try session.setCategory(.record)
            try session.setActive(true)
            var entry = Recording(id: UUID(), startedAt: .now)
            entry.timeZoneIdentifier = TimeZone.current.identifier
            entry.storage = transfer.storage.destination(free: space.free, capacity: space.capacity)
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
            collectionMode = transfer.collectionMode
            if collectionMode == .precise { await precise.start(at: entry.startedAt) }
            WKInterfaceDevice.current().play(.start)
            requestLocation(for: entry.id)
        } catch {
            if let pending { try? store.delete(pending.id) }
            try? session.setActive(false)
            message = error.localizedDescription
        }
    }

    func checkRecording() {
        if current != nil, recorder?.isRecording != true {
            finish(interrupted: true)
        }
        queueRecordings()
    }

    func setCollectLocation(_ enabled: Bool) {
        collectLocation = enabled
        UserDefaults.standard.set(enabled, forKey: "collectMeetingLocation")
        guard enabled else { cancelLocation(); return }
        if locationManager.authorizationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        } else if locationManager.authorizationStatus == .denied || locationManager.authorizationStatus == .restricted {
            message = "请在手表的定位设置中允许手记使用位置。"
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
        guard let current else { return }
        let motion = precise.stop()
        cancelLocation()
        let recorder = self.recorder
        self.recorder = nil
        self.current = nil
        recorder?.stop()
        WKInterfaceDevice.current().play(.stop)
        try? AVAudioSession.sharedInstance().setActive(false)

        do {
            var source = current
            source.motionWindows = motion.isEmpty ? nil : motion
            let saved = try finalize(source, interrupted: interrupted)
            reload()
            if !saved.isPlayable {
                message = JournalError.recordingFailed.localizedDescription
            } else if interrupted {
                message = "音频会话被系统中断，已保存可播放的部分。"
            }
            if !deferredPurges.isEmpty {
                let ids = Array(deferredPurges)
                deferredPurges.removeAll()
                purge(ids)
            }
            if saved.isPlayable { queueRecordings() }
        } catch {
            message = error.localizedDescription
        }
    }

    private func queueRecordings(known: Set<UUID>? = nil) {
        if let known { deferredKnown = known }
        let device = WKInterfaceDevice.current()
        device.isBatteryMonitoringEnabled = true
        guard TransferPolicy.allowsAutomatic(recording: current != nil || starting,
            chargingOnly: transfer.transferChargingOnly, charging: [.charging, .full].contains(device.batteryState)) else {
            if transfer.transferChargingOnly, current == nil, !recordings.isEmpty {
                WKApplication.shared().scheduleBackgroundRefresh(withPreferredDate: .now.addingTimeInterval(1800),
                    userInfo: nil) { _ in }
            }
            return
        }
        let known = deferredKnown
        deferredKnown = nil
        for entry in recordings where entry.isPlayable {
            if known?.contains(entry.id) == true {
                if entry.storage == .phone { confirmPhoneStorage(entry.id) }
                continue
            }
            if known != nil || entry.storage == .phone { _ = try? transfer.send(entry) }
        }
    }

    private func confirmPhoneStorage(_ id: UUID) {
        guard let entry = recordings.first(where: { $0.id == id }), entry.storage == .phone else { return }
        do {
            try store.delete(id)
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
        if transfer.isQueued(entry.id) {
            message = "录音正在传输。传输结束后可删除。"
            return false
        }
        do {
            try store.delete(entry.id)
            reload()
            return true
        } catch {
            message = error.localizedDescription
            return false
        }
    }

    func send(_ entry: Recording) {
        guard current == nil, !starting else {
            message = "请先结束录音，再发送文件。"
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
