import AVFoundation
import SwiftUI

@MainActor
final class WatchJournal: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published private(set) var current: Recording?
    @Published private(set) var recordings: [Recording] = []
    @Published private(set) var report: HealthReport?
    @Published private(set) var starting = false
    @Published private(set) var generatingReport = false
    @Published var message: String?

    let store = JournalStore()
    private let health = HealthReader()
    private var recorder: AVAudioRecorder?
    private var interruptionObserver: NSObjectProtocol?

    lazy var transfer = CompanionTransfer(store: store) { [weak self] event in
        if case let .message(message) = event {
            Task { @MainActor [weak self] in self?.message = message }
        }
    }

    override init() {
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

    deinit {
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
    }

    private func reload() {
        do {
            let entries = try store.list()
            recordings = try entries.map { entry in
                guard entry.state == .recording, current?.id != entry.id else { return entry }
                return try finalize(entry, interrupted: true)
            }.filter { $0.state != .recording }
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
            try session.setCategory(.record)
            try session.setActive(true)
            let entry = Recording(id: UUID(), startedAt: .now)
            pending = entry
            try store.save(entry)

            let recorder = try AVAudioRecorder(url: store.audio(entry.id), settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 24_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 48_000
            ])
            recorder.delegate = self
            guard recorder.record() else { throw JournalError.recordingFailed }
            self.recorder = recorder
            current = entry
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
    }

    func finish(interrupted: Bool = false) {
        guard let current else { return }
        let recorder = self.recorder
        self.recorder = nil
        self.current = nil
        recorder?.stop()
        try? AVAudioSession.sharedInstance().setActive(false)

        do {
            let saved = try finalize(current, interrupted: interrupted)
            reload()
            if !saved.isPlayable {
                message = JournalError.recordingFailed.localizedDescription
            } else if interrupted {
                message = "音频会话被系统中断，已保存可播放的部分。"
            }
        } catch {
            message = error.localizedDescription
        }
    }

    private func finalize(_ entry: Recording, interrupted: Bool) throws -> Recording {
        var entry = entry
        let url = try store.audio(entry.id)
        if let audio = try? AVAudioPlayer(contentsOf: url), audio.duration.isFinite, audio.duration > 0 {
            entry.duration = audio.duration
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
        do {
            let queued = try transfer.send(entry)
            message = queued ? "已加入发送队列。" : "这段录音正在等待发送。"
        } catch {
            message = error.localizedDescription
        }
    }

    func generateReport() async {
        guard !generatingReport else { return }
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
