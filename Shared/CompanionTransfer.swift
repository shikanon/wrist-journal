import Foundation
import WatchConnectivity

final class CompanionTransfer: NSObject, WCSessionDelegate, @unchecked Sendable {
    private enum Key {
        static let kind = "kind"
        static let recording = "recording"
        static let report = "health-report"
        static let metadata = "recording-metadata"
        static let sync = "sync-recordings"
        static let receipt = "recording-receipt"
        static let purge = "purge-recordings"
        static let purgeAck = "purge-ack"
    }

    enum Event: Sendable {
        case updated
        case message(String)
        #if os(watchOS)
        case ready, sync(Set<UUID>, [UUID]), received(UUID), purge([UUID])
        #else
        case ready, purgeAcknowledged([UUID])
        #endif
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
    var storage: RecordingStorage {
        let raw = WCSession.isSupported()
            ? WCSession.default.receivedApplicationContext[RecordingStorage.settingsKey] as? String : nil
        return raw.flatMap(RecordingStorage.init(rawValue:)) ?? .automatic
    }
    var transferChargingOnly: Bool {
        WCSession.default.receivedApplicationContext["transferChargingOnly"] as? Bool ?? false
    }
    var collectionMode: CollectionMode {
        (WCSession.default.receivedApplicationContext["collectionMode"] as? String)
            .flatMap(CollectionMode.init(rawValue:)) ?? .system
    }
    func acknowledgePurge(_ ids: [UUID]) throws {
        guard !ids.isEmpty else { return }
        let session = try activeSession()
        let values = ids.map(\.uuidString).sorted()
        guard !session.outstandingUserInfoTransfers.contains(where: {
            $0.userInfo[Key.kind] as? String == Key.purgeAck && $0.userInfo["ids"] as? [String] == values
        }) else { return }
        session.transferUserInfo([Key.kind: Key.purgeAck, "ids": values])
    }
    func pauseFileTransfers() {
        for transfer in WCSession.default.outstandingFileTransfers
            where transfer.file.metadata?[Key.kind] as? String == Key.recording { transfer.cancel() }
    }

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

    func cancelTransfer(_ id: UUID) {
        for transfer in WCSession.default.outstandingFileTransfers where transfer.file.metadata?["id"] as? String == id.uuidString {
            transfer.cancel()
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

    private func request(_ info: [String: Any]) {
        switch info[Key.kind] as? String {
        case Key.sync:
            let purged = (info["purged"] as? [String] ?? []).compactMap(UUID.init(uuidString:))
            let ids = (info["known"] as? [String] ?? []).compactMap(UUID.init(uuidString:))
            onEvent(.sync(Set(ids), purged))
        case Key.purge:
            onEvent(.purge((info["ids"] as? [String] ?? []).compactMap(UUID.init(uuidString:))))
        case Key.receipt:
            if let raw = info["id"] as? String, let id = UUID(uuidString: raw) { onEvent(.received(id)) }
        default: break
        }
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) { request(userInfo) }
    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        onEvent(.ready)
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                 replyHandler: @escaping ([String: Any]) -> Void) {
        request(message)
        replyHandler(["accepted": true])
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        if session.isReachable { onEvent(.ready) }
    }
    #else
    private func watchSession() throws -> WCSession {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated,
              WCSession.default.isPaired, WCSession.default.isWatchAppInstalled else {
            throw JournalError.watchUnavailable
        }
        return .default
    }

    func publishSettings(storage: RecordingStorage, settings: DailySettings) throws {
        let session = try watchSession()
        var context = session.applicationContext
        context[RecordingStorage.settingsKey] = storage.rawValue
        context["transferChargingOnly"] = settings.transferChargingOnly ?? false
        context["collectionMode"] = (settings.collectionMode ?? .system).rawValue
        guard !NSDictionary(dictionary: context).isEqual(to: session.applicationContext) else { return }
        try session.updateApplicationContext(context)
    }

    func syncRecordings(known: [UUID], purged: [UUID]) throws -> Bool {
        let session = try watchSession()
        let request: [String: Any] = [Key.kind: Key.sync, "known": known.map(\.uuidString),
                                     "purged": purged.prefix(500).map(\.uuidString)]
        try purgeRecordings(Array(purged.dropFirst(500)))
        if session.isReachable {
            session.sendMessage(request, replyHandler: { _ in }, errorHandler: { [weak self] _ in
                guard session.activationState == .activated else {
                    self?.onEvent(.message(JournalError.watchUnavailable.localizedDescription))
                    return
                }
                session.transferUserInfo(request)
            })
            return true
        }
        session.transferUserInfo(request)
        return false
    }

    func purgeRecordings(_ ids: [UUID]) throws {
        let session = try watchSession()
        let queued = Set(session.outstandingUserInfoTransfers.filter {
            $0.userInfo[Key.kind] as? String == Key.purge
        }.flatMap { $0.userInfo["ids"] as? [String] ?? [] })
        let additions = ids.map(\.uuidString).filter { !queued.contains($0) }.sorted()
        for offset in stride(from: 0, to: additions.count, by: 200) {
            let batch = Array(additions[offset..<min(offset + 200, additions.count)])
            guard !session.outstandingUserInfoTransfers.contains(where: {
                $0.userInfo[Key.kind] as? String == Key.purge && $0.userInfo["ids"] as? [String] == batch
            }) else { continue }
            session.transferUserInfo([Key.kind: Key.purge, "ids": batch])
        }
    }
    #endif

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {
        if let error {
            onEvent(.message("设备连接：\(error.localizedDescription)"))
            return
        }
        if activationState == .activated { onEvent(.ready) }
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
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        if userInfo[Key.kind] as? String == Key.purgeAck {
            onEvent(.purgeAcknowledged((userInfo["ids"] as? [String] ?? []).compactMap(UUID.init(uuidString:))))
        }
    }
    func sessionWatchStateDidChange(_ session: WCSession) { onEvent(.ready) }
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
                if (try? store.recording(recording.id).rawDeletedAt) != nil, session.activationState == .activated {
                    session.transferUserInfo([Key.kind: Key.purge, "ids": [recording.id.uuidString]])
                }
                if session.activationState == .activated {
                    session.transferUserInfo([Key.kind: Key.receipt, "id": recording.id.uuidString])
                }
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
