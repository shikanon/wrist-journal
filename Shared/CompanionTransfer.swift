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
        static let processing = "processing-configuration"
        static let result = "processing-result"
        static let resultAck = "processing-result-ack"
        static let processingAudio = "processing-audio"
    }

    enum Event: Sendable {
        case updated
        case message(String)
        #if os(watchOS)
        case ready, sync(Set<UUID>, [UUID], Bool), received(UUID), purge([UUID]), process([UUID], String)
        #else
        case ready, cloudAvailable, purgeAcknowledged([UUID]), credentialReady(String)
        #endif
    }

    private let store: JournalStore
    private let onEvent: @Sendable (Event) -> Void
    private let credentialProvider: @Sendable (String) async -> (Data, String)?

    init(store: JournalStore,
         credentialProvider: @escaping @Sendable (String) async -> (Data, String)? = { _ in nil },
         onEvent: @escaping @Sendable (Event) -> Void) {
        self.store = store
        self.credentialProvider = credentialProvider
        self.onEvent = onEvent
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    #if os(watchOS)
    var processing: ProcessingConfiguration {
        guard let data = WCSession.default.receivedApplicationContext[Key.processing] as? Data,
              let config = try? JSONDecoder().decode(ProcessingConfiguration.self, from: data) else {
            // Stable default must not invalidate a running worker on every read.
            var config = ProcessingConfiguration()
            config.revision = "unsynchronized"
            return config
        }
        return config
    }
    func processingKey(_ config: ProcessingConfiguration) async throws -> String {
        guard config.mode == .watch, processing == config else { throw CancellationError() }
        if UserDefaults.standard.string(forKey: "watchCredentialRevision") == config.revision,
           let key = ArkCredential(rawValue: config.credential)?.load() { return key }
        let session = try activeSession()
        guard session.isReachable else { throw JournalError.phoneUnavailable }
        let key: String = try await withCheckedThrowingContinuation { continuation in
            session.sendMessage([Key.kind: "processing-credentials", "revision": config.revision], replyHandler: { reply in
                guard let data = reply["configuration"] as? Data,
                      let received = try? JSONDecoder().decode(ProcessingConfiguration.self, from: data),
                      received == config, let key = reply["key"] as? String, !key.isEmpty else {
                    continuation.resume(throwing: AnalysisError.missingCredential)
                    return
                }
                continuation.resume(returning: key)
            }, errorHandler: { continuation.resume(throwing: $0) })
        }
        try Task.checkCancellation()
        guard processing == config, let credential = ArkCredential(rawValue: config.credential) else {
            throw CancellationError()
        }
        try credential.save(key)
        UserDefaults.standard.set(config.revision, forKey: "watchCredentialRevision")
        session.transferUserInfo([Key.kind: "credential-ready", "revision": config.revision])
        return key
    }
    func sendResults() throws {
        let session = try activeSession()
        for url in try store.pendingResults() {
            let id = url.deletingPathExtension().lastPathComponent
            guard !session.outstandingFileTransfers.contains(where: {
                $0.file.metadata?[Key.kind] as? String == Key.result && $0.file.metadata?["resultID"] as? String == id
            }) else { continue }
            session.transferFile(url, metadata: [Key.kind: Key.result, "resultID": id])
        }
    }
    var storage: RecordingStorage {
        let raw = WCSession.isSupported()
            ? WCSession.default.receivedApplicationContext[RecordingStorage.settingsKey] as? String : nil
        return RecordingStorage.preference(raw)
    }
    var batchMinutes: Int { StoragePolicy.batchMinutes(WCSession.default.receivedApplicationContext["batchMinutes"] as? Int) }
    func notifyCloudAvailable() throws {
        let session = try activeSession()
        guard !session.outstandingUserInfoTransfers.contains(where: { $0.userInfo[Key.kind] as? String == "cloud-available" }) else { return }
        session.transferUserInfo([Key.kind: "cloud-available"])
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
            onEvent(.sync(Set(ids), purged, info["endedOnly"] as? Bool ?? false))
        case Key.purge:
            onEvent(.purge((info["ids"] as? [String] ?? []).compactMap(UUID.init(uuidString:))))
        case Key.receipt:
            if let raw = info["id"] as? String, let id = UUID(uuidString: raw) { onEvent(.received(id)) }
        case "process-recordings":
            if let revision = info["revision"] as? String {
                onEvent(.process((info["ids"] as? [String] ?? []).compactMap(UUID.init(uuidString:)), revision))
            }
        case Key.resultAck:
            if let raw = info["resultID"] as? String, let id = UUID(uuidString: raw) {
                try? store.acknowledgeResult(id)
            }
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
    func publishProcessing(_ configuration: ProcessingConfiguration) throws {
        let session = try watchSession()
        var context = session.applicationContext
        context[Key.processing] = try JSONEncoder().encode(configuration)
        guard !NSDictionary(dictionary: context).isEqual(to: session.applicationContext) else { return }
        try session.updateApplicationContext(context)
    }
    func requestProcessing(_ entries: [Recording], manual: Bool) throws {
        let session = try watchSession()
        guard let data = session.applicationContext[Key.processing] as? Data,
              let config = try? JSONDecoder().decode(ProcessingConfiguration.self, from: data),
              config.mode == .watch else { throw CancellationError() }
        // A file request itself is durable; send originals missing from the Watch as idempotent deliveries.
        for entry in entries where entry.isPlayable && entry.watchProcessingReceivedAt == nil {
            guard !session.outstandingFileTransfers.contains(where: {
                $0.file.metadata?[Key.kind] as? String == Key.processingAudio &&
                $0.file.metadata?["id"] as? String == entry.id.uuidString
            }), FileManager.default.fileExists(atPath: try store.audio(entry.id).path) else { continue }
            session.transferFile(try store.outgoingAudio(entry.id), metadata: [
                Key.kind: Key.processingAudio, Key.metadata: try JSONEncoder().encode(entry),
                "id": entry.id.uuidString, "manual": manual, "revision": config.revision
            ])
        }
        if manual {
            let ids = entries.map(\.id.uuidString).sorted()
            guard !ids.isEmpty, !session.outstandingUserInfoTransfers.contains(where: {
                $0.userInfo[Key.kind] as? String == "process-recordings" && $0.userInfo["ids"] as? [String] == ids &&
                $0.userInfo["revision"] as? String == config.revision
            }) else { return }
            session.transferUserInfo([Key.kind: "process-recordings", "ids": ids, "revision": config.revision])
        }
    }
    func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                 replyHandler: @escaping ([String: Any]) -> Void) {
        guard message[Key.kind] as? String == "processing-credentials",
              let revision = message["revision"] as? String else { replyHandler([:]); return }
        Task {
            if let (configuration, key) = await credentialProvider(revision) {
                replyHandler(["configuration": configuration, "key": key])
            } else { replyHandler([:]) }
        }
    }
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
        context["batchMinutes"] = StoragePolicy.batchMinutes(settings.batchMinutes)
        context["localAccessMinutes"] = StoragePolicy.idleMinutes(settings.localAccessMinutes)
        guard !NSDictionary(dictionary: context).isEqual(to: session.applicationContext) else { return }
        try session.updateApplicationContext(context)
    }

    func syncRecordings(known: [UUID], purged: [UUID], endedOnly: Bool = false) throws -> Bool {
        let session = try watchSession()
        let request: [String: Any] = [Key.kind: Key.sync, "known": known.map(\.uuidString),
                                     "purged": purged.prefix(500).map(\.uuidString), "endedOnly": endedOnly]
        try purgeRecordings(Array(purged.dropFirst(500)))
        if session.isReachable {
            session.sendMessage(request, replyHandler: { _ in }, errorHandler: { [weak self] _ in
                guard session.activationState == .activated else {
                    self?.onEvent(.message(JournalError.watchUnavailable.localizedDescription))
                    return
                }
                self?.enqueueSync(request, session: session)
            })
            return true
        }
        enqueueSync(request, session: session)
        return false
    }
    private func enqueueSync(_ request: [String: Any], session: WCSession) {
        guard !session.outstandingUserInfoTransfers.contains(where: {
            $0.userInfo[Key.kind] as? String == Key.sync && NSDictionary(dictionary: $0.userInfo).isEqual(to: request)
        }) else { return }
        session.transferUserInfo(request)
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
        if activationState == .activated {
            DispatchQueue.main.async { [self] in
                let pending = session.outstandingFileTransfers.map { $0.file.fileURL.standardizedFileURL }
                try? store.cleanOutgoingReports(keeping: Set(pending))
            }
        }
    }

    #if os(iOS)
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        if userInfo[Key.kind] as? String == "processing-audio-receipt",
           let raw = userInfo["id"] as? String, let id = UUID(uuidString: raw) {
            do {
                try store.confirmWatchProcessingReceipt(id)
            } catch { onEvent(.message("手表接收状态未保存，请稍后重试。")) }
        }
        if userInfo[Key.kind] as? String == "cloud-available" { onEvent(.cloudAvailable) }
        if userInfo[Key.kind] as? String == Key.purgeAck {
            onEvent(.purgeAcknowledged((userInfo["ids"] as? [String] ?? []).compactMap(UUID.init(uuidString:))))
        }
        if userInfo[Key.kind] as? String == "credential-ready", let revision = userInfo["revision"] as? String {
            onEvent(.credentialReady(revision))
        }
    }
    func sessionWatchStateDidChange(_ session: WCSession) { onEvent(.ready) }
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }

    #endif

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        // The system removes this temporary URL when the delegate method returns.
        do {
            switch file.metadata?[Key.kind] as? String {
            #if os(watchOS)
            case Key.processingAudio:
                guard let data = file.metadata?[Key.metadata] as? Data else { throw JournalError.invalidTransfer }
                var entry = try JSONDecoder().decode(Recording.self, from: data)
                entry.phoneReceivedAt = .now
                entry.awaitingWatchResult = true
                if (try? store.analysis(entry.id)?.state) != .complete {
                    try store.receive(file.fileURL, recording: entry)
                }
                session.transferUserInfo([Key.kind: "processing-audio-receipt", "id": entry.id.uuidString])
                if file.metadata?["manual"] as? Bool == true, let revision = file.metadata?["revision"] as? String {
                    onEvent(.process([entry.id], revision))
                }
            #else
            case Key.result:
                let data = try Data(contentsOf: file.fileURL)
                guard data.count <= 8_000_000 else { throw JournalError.invalidTransfer }
                let result = try JSONDecoder().decode(ProcessingResult.self, from: data)
                try store.receiveResult(result)
                session.transferUserInfo([Key.kind: Key.resultAck, "resultID": result.id.uuidString])
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
            #endif
            default:
                throw JournalError.invalidTransfer
            }
            onEvent(.updated)
        } catch {
            onEvent(.message("导入失败：\(error.localizedDescription)"))
        }
    }
    func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        if [Key.report, Key.processingAudio].contains(fileTransfer.file.metadata?[Key.kind] as? String ?? "") {
            try? FileManager.default.removeItem(at: fileTransfer.file.fileURL)
        }
        if let error {
            onEvent(.message("发送失败，可以重试。\(error.localizedDescription)"))
        } else {
            onEvent(.message("传输完成。请在 iPhone 手记中查看。"))
        }
    }
}
