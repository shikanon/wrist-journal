import CloudKit

actor CloudBackup {
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
        record["metadata"] = try JSONEncoder().encode(metadata) as CKRecordValue
        try await upload(record, wifiOnly: wifiOnly)
        try Task.checkCancellation()
    }

    private func fetch(_ id: CKRecord.ID, wifiOnly: Bool) async throws -> CKRecord {
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
