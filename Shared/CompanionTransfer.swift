import Foundation
import WatchConnectivity

final class CompanionTransfer: NSObject, WCSessionDelegate, @unchecked Sendable {
    private enum Key {
        static let kind = "kind"
        static let recording = "recording"
        static let report = "health-report"
        static let metadata = "recording-metadata"
    }

    enum Event: Sendable {
        case updated
        case message(String)
    }

    private let store: JournalStore
    private let onEvent: @Sendable (Event) -> Void

    init(store: JournalStore, onEvent: @escaping @Sendable (Event) -> Void) {
        self.store = store
        self.onEvent = onEvent
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    #if os(watchOS)
    private func activeSession() throws -> WCSession {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated,
              WCSession.default.isCompanionAppInstalled else {
            throw JournalError.phoneUnavailable
        }
        return .default
    }

    func isQueued(_ id: UUID) -> Bool {
        guard WCSession.isSupported() else { return false }
        return WCSession.default.outstandingFileTransfers.contains {
            $0.file.metadata?["id"] as? String == id.uuidString
        }
    }

    func send(_ recording: Recording) throws -> Bool {
        let session = try activeSession()
        guard recording.isPlayable else { throw JournalError.invalidTransfer }
        guard !isQueued(recording.id) else { return false }
        let metadata = try JSONEncoder().encode(recording)
        session.transferFile(try store.audio(recording.id), metadata: [
            Key.kind: Key.recording, Key.metadata: metadata, "id": recording.id.uuidString
        ])
        return true
    }

    func send(_ report: HealthReport) throws {
        let session = try activeSession()
        session.transferFile(try store.outgoingReport(report), metadata: [Key.kind: Key.report])
    }
    #endif

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {
        if let error {
            onEvent(.message("设备连接：\(error.localizedDescription)"))
            return
        }
        #if os(watchOS)
        if activationState == .activated {
            DispatchQueue.main.async { [self] in
                let pending = session.outstandingFileTransfers.map { $0.file.fileURL.standardizedFileURL }
                try? store.cleanOutgoingReports(keeping: Set(pending))
            }
        }
        #endif
    }

    #if os(iOS)
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        // The system removes this temporary URL when the delegate method returns.
        do {
            switch file.metadata?[Key.kind] as? String {
            case Key.recording:
                guard let data = file.metadata?[Key.metadata] as? Data else { throw JournalError.invalidTransfer }
                let recording = try JSONDecoder().decode(Recording.self, from: data)
                try store.receive(file.fileURL, recording: recording)
            case Key.report:
                let report = try JSONDecoder().decode(HealthReport.self, from: Data(contentsOf: file.fileURL))
                if let previous = try? store.report(), previous.generatedAt >= report.generatedAt { return }
                try store.saveReport(report)
            default:
                throw JournalError.invalidTransfer
            }
            onEvent(.updated)
        } catch {
            onEvent(.message("导入失败：\(error.localizedDescription)"))
        }
    }
    #endif

    #if os(watchOS)
    func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        if fileTransfer.file.metadata?[Key.kind] as? String == Key.report {
            try? FileManager.default.removeItem(at: fileTransfer.file.fileURL)
        }
        if let error {
            onEvent(.message("发送失败，可以重试。\(error.localizedDescription)"))
        } else {
            onEvent(.message("传输完成。请在 iPhone 手记中查看。"))
        }
    }
    #endif
}
