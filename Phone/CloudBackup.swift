import CloudKit

actor CloudBackup {
    private lazy var database: CKDatabase = {
        let name = Bundle.main.object(forInfoDictionaryKey: "JournalCloudContainer") as? String
            ?? "iCloud.io.github.shikanon.wristjournal"
        return CKContainer(identifier: name).privateCloudDatabase
    }()

    /// Only audio and location. HealthKit data is never stored in iCloud.
    func save(recording: Recording, audio: URL) async throws {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-journal-fixture-cloud-failure") {
            throw CKError(.networkUnavailable)
        }
        #endif
        try Task.checkCancellation()
        let id = CKRecord.ID(recordName: "audio-" + recording.id.uuidString)
        let record: CKRecord
        do {
            record = try await database.record(for: id)
            if record["audio"] as? CKAsset != nil, record["metadata"] as? Data != nil { return }
        } catch let error as CKError where error.code == .unknownItem {
            record = CKRecord(recordType: "JournalAudio", recordID: id)
        }
        record["audio"] = CKAsset(fileURL: audio)
        record["metadata"] = try JSONEncoder().encode(recording) as CKRecordValue
        _ = try await database.save(record)
    }
}
