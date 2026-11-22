#if DEBUG
import Foundation
import CryptoKit

@MainActor
extension PhoneJournal {
    func runStorageSimulation() async {
        let root = URL.applicationSupportDirectory.appendingPathComponent("WristJournalStorageTests")
        do {
            let remote = root.appendingPathComponent("CloudFixture")
            try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
            let watch = JournalStore(root: root.appendingPathComponent("Watch"))
            let cloud = CloudBackup(fixtureDirectory: remote)
            var entry = Recording(id: UUID(), startedAt: .now.addingTimeInterval(-172800), duration: 120,
                                  state: .saved, note: "模拟会议 <script>不执行</script>", storage: .cloud)
            entry.location = MeetingLocation(latitude: 31.230, longitude: 121.474)
            entry.motionWindows = [ActivityWindow(start: entry.startedAt, end: entry.startedAt.addingTimeInterval(10), kind: "步行")]
            try watch.save(entry)
            let bytes = Data((0..<196_731).map { UInt8($0 % 251) })
            try bytes.write(to: watch.audio(entry.id))
            await cloud.simulateUploadFailure(true)
            var uploadFailed = false
            do {
                try await cloud.save(recording: entry, audio: watch.audio(entry.id), wifiOnly: true)
            } catch {
                uploadFailed = true
                guard FileManager.default.fileExists(atPath: try watch.audio(entry.id).path),
                      try watch.recording(entry.id).cloudUploadedAt == nil else { throw JournalError.invalidTransfer }
            }
            guard uploadFailed else { throw JournalError.invalidTransfer }
            await cloud.simulateUploadFailure(false)
            try await cloud.save(recording: entry, audio: watch.audio(entry.id), wifiOnly: true)
            try watch.evictLocal(entry.id, cloudConfirmedAt: .now)
            guard !FileManager.default.fileExists(atPath: try watch.audio(entry.id).path),
                  try watch.recording(entry.id).rawDeletedAt == nil else { throw JournalError.invalidTransfer }
            let first = try await cloud.importPending(into: store)
            let duplicate = try await cloud.importPending(into: store)
            guard first == 1, duplicate == 0, try Data(contentsOf: store.audio(entry.id)) == bytes,
                  try store.recording(entry.id).motionWindows == nil else { throw JournalError.invalidTransfer }
            // A late cloud recording may join a day whose earlier watch recording was already cleaned.
            let old = Recording(id: UUID(), startedAt: entry.startedAt, duration: 30, state: .saved,
                                storage: .watch, rawDeletedAt: .now)
            try store.save(old)
            let day = JournalDayKey(recording: entry)
            let oldMeeting = MeetingDigest(id: old.id, startedAt: old.startedAt, duration: old.duration,
                title: "先到的手表会议", location: nil, minutes: "已保存", events: [], healthNote: nil)
            var previous = DailyJournalReport(day: day, generatedAt: .now, meetings: [oldMeeting],
                health: HealthDay(start: day.interval!.start, localDate: day.localDate), healthNote: nil,
                thresholds: HeartRateSettings(), cloudBackupRequired: false, requiredBackupIDs: [old.id])
            previous.cleanupCompletedAt = .now
            try store.saveDaily(previous)
            var job = MeetingAnalysisJob(model: "simulation", credential: "personal", includeContext: false)
            job.state = .complete
            job.minutes = "云端迟到会议纪要"
            try save(job, for: entry.id)
            dailySettings = DailySettings(healthEnabled: false)
            guard await processDays(automatic: false),
                  let merged = try store.daily(day), merged.meetings.count == 2,
                  merged.requiredBackupIDs == [entry.id], merged.cleanupCompletedAt != nil,
                  try store.pendingCloudCompletionIDs().contains(entry.id) else { throw JournalError.invalidTransfer }
            let late = try await cloud.importPending(into: store)
            guard late == 0, !FileManager.default.fileExists(atPath: try store.audio(entry.id).path) else {
                throw JournalError.invalidTransfer
            }
            let downloadable = Recording(id: UUID(), startedAt: entry.startedAt, duration: 120, state: .saved,
                                     note: entry.note, storage: .phone)
            let staging = root.appendingPathComponent("fixture.m4a")
            try bytes.write(to: staging)
            try store.receive(staging, recording: downloadable)
            try watch.receive(staging, recording: downloadable)
            try watch.evictLocal(downloadable.id)
            guard try Data(contentsOf: store.audio(downloadable.id)) == bytes,
                  !FileManager.default.fileExists(atPath: try watch.audio(downloadable.id).path) else { throw JournalError.invalidTransfer }
            reload()
            try localDownload.startSimulation(timeout: 8)
            for _ in 0..<200 {
                if localDownload.url != nil { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            guard let url = localDownload.url, let cert = localDownload.simulationCertificate() else { throw JournalError.invalidTransfer }
            let session: [String: Any] = ["url": url.absoluteString, "certificate": cert.base64EncodedString(),
                "recording": downloadable.id.uuidString, "sha256": SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
                "byteCount": bytes.count]
            try JSONSerialization.data(withJSONObject: session).write(to: root.appendingPathComponent("server.json"), options: .atomic)
            let evidence: [String: Any] = ["passed": true, "scenario": "storage-modes",
                "cloudFailureRetainsOriginal": true, "cloudAcknowledgmentEvictsLocal": true,
                "cloudImportIdempotent": true, "purgedCloudDoesNotRevive": true,
                "healthExcludedFromCloud": true, "phoneAcknowledgmentEvictsWatch": true,
                "lateCloudMeetingMergesWithCleanedWatchDay": true,
                "cloudTransport": "Debug local fixture", "httpsTransport": "Network.framework TLS loopback"]
            try JSONSerialization.data(withJSONObject: evidence, options: .prettyPrinted)
                .write(to: root.appendingPathComponent("simulation-result.json"), options: .atomic)
        } catch {
            let evidence: [String: Any] = ["passed": false, "error": error.localizedDescription]
            try? JSONSerialization.data(withJSONObject: evidence).write(to: root.appendingPathComponent("simulation-result.json"), options: .atomic)
        }
    }
}
#endif
