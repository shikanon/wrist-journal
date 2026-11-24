import CloudKit

actor CloudBackup {
    init() {}
    #if DEBUG
    private var fixtureDirectory: URL?
    private var fixtureFailure = false
    init(fixtureDirectory: URL) { self.fixtureDirectory = fixtureDirectory }
    func simulateUploadFailure(_ value: Bool) { fixtureFailure = value }
    #endif
    private lazy var database: CKDatabase = {
        let name = Bundle.main.object(forInfoDictionaryKey: "JournalCloudContainer") as? String
            ?? "iCloud.io.github.shikanon.wristjournal"
        return CKContainer(identifier: name).privateCloudDatabase
    }()

    /// Only audio and location. HealthKit data is never stored in iCloud.
    func save(recording: Recording, audio: URL, wifiOnly: Bool = false) async throws {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-journal-fixture-cloud-failure") {
            throw CKError(.networkUnavailable)
        }
        #endif
        try Task.checkCancellation()
        let id = CKRecord.ID(recordName: "audio-" + recording.id.uuidString)
        let record: CKRecord
        do {
            record = try await fetch(id, wifiOnly: wifiOnly)
        } catch let error as CKError where error.code == .unknownItem {
            record = CKRecord(recordType: "JournalAudio", recordID: id)
        }
        try Task.checkCancellation()
        if record["audio"] as? CKAsset != nil, record["metadata"] as? Data != nil { return }
        record["audio"] = CKAsset(fileURL: audio)
        var metadata = recording
        metadata.motionWindows = nil
        metadata.localEvictedAt = nil
        metadata.cloudUploadedAt = .now
        record["metadata"] = try JSONEncoder().encode(metadata) as CKRecordValue
        record["pendingAnalysis"] = (recording.storage == .cloud ? 1 : 0) as CKRecordValue
        try await upload(record, wifiOnly: wifiOnly)
        try Task.checkCancellation()
    }

    func complete(_ id: UUID, wifiOnly: Bool = true) async throws {
        let record = try await fetch(CKRecord.ID(recordName: "audio-" + id.uuidString), wifiOnly: wifiOnly)
        guard (record["pendingAnalysis"] as? NSNumber)?.intValue != 0 else { return }
        record["pendingAnalysis"] = 0 as CKRecordValue
        try await upload(record, wifiOnly: wifiOnly)
    }

    /// Query lightweight metadata first. Existing durable originals are never downloaded twice.
    func importPending(into store: JournalStore, wifiOnly: Bool = true) async throws -> Int {
        var cursor: CKQueryOperation.Cursor?
        var imported = 0
        repeat {
            let page = try await pendingPage(cursor: cursor, wifiOnly: wifiOnly)
            for row in page.records {
                try Task.checkCancellation()
                guard let data = row["metadata"] as? Data else { throw JournalError.invalidTransfer }
                let metadata = try JSONDecoder().decode(Recording.self, from: data)
                guard row.recordID.recordName == "audio-" + metadata.id.uuidString,
                      metadata.storage == .cloud, metadata.rawDeletedAt == nil else { throw JournalError.invalidTransfer }
                if let existing = try? store.recording(metadata.id) {
                    if existing.rawDeletedAt != nil {
                        try await complete(metadata.id, wifiOnly: wifiOnly)
                        try store.acknowledgeCloudCompletion(metadata.id)
                        continue
                    }
                    if existing.isPlayable, FileManager.default.fileExists(atPath: try store.audio(metadata.id).path) { continue }
                }
                let full = try await fetch(row.recordID, wifiOnly: wifiOnly)
                guard let audio = (full["audio"] as? CKAsset)?.fileURL else { throw JournalError.invalidTransfer }
                if try store.receive(audio, recording: metadata) { imported += 1 }
            }
            cursor = page.cursor
        } while cursor != nil
        return imported
    }

    private func pendingPage(cursor: CKQueryOperation.Cursor?, wifiOnly: Bool) async throws -> CloudPage {
        #if DEBUG
        if let fixtureDirectory {
            let rows = try FileManager.default.contentsOfDirectory(at: fixtureDirectory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }.compactMap { url -> CKRecord? in
                    let record = try fixtureRecord(CKRecord.ID(recordName: url.deletingPathExtension().lastPathComponent))
                    return (record["pendingAnalysis"] as? NSNumber)?.intValue == 1 ? record : nil
                }
            return CloudPage(records: rows, cursor: nil)
        }
        #endif
        let operation = cursor.map(CKQueryOperation.init(cursor:)) ??
            CKQueryOperation(query: CKQuery(recordType: "JournalAudio", predicate: NSPredicate(format: "pendingAnalysis == 1")))
        operation.desiredKeys = ["metadata"]
        operation.resultsLimit = 100
        operation.configuration.allowsCellularAccess = !wifiOnly
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let rows = CloudQueryRows()
                operation.recordMatchedBlock = { _, result in rows.append(result) }
                operation.queryResultBlock = { result in
                    do {
                        let cursor = try result.get()
                        continuation.resume(returning: CloudPage(records: try rows.values(), cursor: cursor))
                    } catch { continuation.resume(throwing: error) }
                }
                database.add(operation)
            }
        } onCancel: { operation.cancel() }
    }

    private func fetch(_ id: CKRecord.ID, wifiOnly: Bool) async throws -> CKRecord {
        #if DEBUG
        if fixtureDirectory != nil { return try fixtureRecord(id) }
        #endif
        let operation = CKFetchRecordsOperation(recordIDs: [id])
        operation.configuration.allowsCellularAccess = !wifiOnly
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let completion = CloudRecordCompletion(continuation)
                operation.perRecordResultBlock = { _, result in completion.set(result) }
                operation.fetchRecordsResultBlock = { completion.finish($0) }
                database.add(operation)
            }
        } onCancel: { operation.cancel() }
    }

    private func upload(_ record: CKRecord, wifiOnly: Bool) async throws {
        #if DEBUG
        if let fixtureDirectory {
            if fixtureFailure { throw CKError(.networkUnavailable) }
            let base = fixtureDirectory.appendingPathComponent(record.recordID.recordName)
            let destination = base.appendingPathExtension("m4a")
            if !FileManager.default.fileExists(atPath: destination.path),
               let audio = (record["audio"] as? CKAsset)?.fileURL { try FileManager.default.copyItem(at: audio, to: destination) }
            guard let metadata = record["metadata"] as? Data else { throw JournalError.invalidTransfer }
            try metadata.write(to: base.appendingPathExtension("json"), options: .atomic)
            try Data([UInt8((record["pendingAnalysis"] as? NSNumber)?.intValue ?? 0)])
                .write(to: base.appendingPathExtension("pending"), options: .atomic)
            return
        }
        #endif
        let operation = CKModifyRecordsOperation(recordsToSave: [record])
        operation.configuration.allowsCellularAccess = !wifiOnly
        let _: CKRecord = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let completion = CloudRecordCompletion(continuation)
                operation.perRecordSaveBlock = { _, result in completion.set(result) }
                operation.modifyRecordsResultBlock = { completion.finish($0) }
                database.add(operation)
            }
        } onCancel: { operation.cancel() }
    }
    #if DEBUG
    private func fixtureRecord(_ id: CKRecord.ID) throws -> CKRecord {
        guard let fixtureDirectory else { throw JournalError.invalidTransfer }
        let base = fixtureDirectory.appendingPathComponent(id.recordName)
        guard let metadata = try? Data(contentsOf: base.appendingPathExtension("json")) else { throw CKError(.unknownItem) }
        let record = CKRecord(recordType: "JournalAudio", recordID: id)
        record["metadata"] = metadata as CKRecordValue
        record["audio"] = CKAsset(fileURL: base.appendingPathExtension("m4a"))
        record["pendingAnalysis"] = Int(try Data(contentsOf: base.appendingPathExtension("pending")).first ?? 0) as CKRecordValue
        return record
    }
    #endif
}

private struct CloudPage {
    let records: [CKRecord]
    let cursor: CKQueryOperation.Cursor?
}
private final class CloudQueryRows: @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [Result<CKRecord, Error>] = []
    func append(_ result: Result<CKRecord, Error>) { lock.withLock { rows.append(result) } }
    func values() throws -> [CKRecord] { try lock.withLock { try rows.map { try $0.get() } } }
}

private final class CloudRecordCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<CKRecord, Error>?
    private let continuation: CheckedContinuation<CKRecord, Error>
    init(_ continuation: CheckedContinuation<CKRecord, Error>) { self.continuation = continuation }
    func set(_ value: Result<CKRecord, Error>) { lock.withLock { result = value } }
    func finish(_ operation: Result<Void, Error>) {
        let saved = lock.withLock { result }
        switch operation {
        case .failure(let error):
            // Preserve per-record errors (such as unknownItem) instead of a partialFailure wrapper.
            if case .failure(let recordError) = saved { continuation.resume(throwing: recordError) }
            else { continuation.resume(throwing: error) }
        case .success:
            continuation.resume(with: saved ?? .failure(JournalError.invalidTransfer))
        }
    }
}
