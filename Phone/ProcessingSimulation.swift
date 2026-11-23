#if DEBUG
import Foundation

@MainActor
extension PhoneJournal {
    func runProcessingSimulation() async {
        var evidence: [String: Any]
        var stage = "none"
        do {
            dailySettings = DailySettings()
            dailySettings.processingMode = ProcessingMode.none
            let raw = Recording(id: UUID(), startedAt: .now.addingTimeInterval(-86400 * 2),
                                duration: 4, state: .saved, timeZoneIdentifier: "Asia/Shanghai")
            try store.save(raw)
            try AnalysisFixture.makeAudio(store.audio(raw.id))
            let rawDay = JournalDayKey(recording: raw)
            let savedMeeting = MeetingDigest(id: raw.id, startedAt: raw.startedAt, duration: raw.duration,
                title: "之前已保存的纪要", location: nil, minutes: "已完成", events: [], healthNote: nil)
            try store.saveDaily(DailyJournalReport(day: rawDay, generatedAt: .now, meetings: [savedMeeting],
                health: HealthDay(start: rawDay.interval!.start, localDate: rawDay.localDate),
                healthNote: nil, thresholds: HeartRateSettings(), cloudBackupRequired: false))
            reload()
            await analyze(raw)
            do {
                _ = try await analyzer.run(recording: raw, url: store.audio(raw.id),
                    job: MeetingAnalysisJob(model: MeetingAnalyzer.defaultModel, credential: "personal", includeContext: false),
                    key: "fixture-key", beforeRequest: { [weak self] in try await self?.requirePhoneProcessing() },
                    checkpoint: { _ in })
                throw JournalError.invalidTransfer
            } catch is CancellationError {}
            guard !hasAnalysisWorker, await processDays(automatic: false) == false,
                  await processDays(automatic: true) == false,
                  try store.recording(raw.id).rawDeletedAt == nil,
                  FileManager.default.fileExists(atPath: try store.audio(raw.id).path) else {
                throw JournalError.invalidTransfer
            }
            stage = "watch prevents phone request"
            dailySettings.processingMode = .watch
            do { _ = try await analyzeForDay(raw); throw JournalError.invalidTransfer }
            catch is ProcessingDeferred {}
            catch JournalError.watchUnavailable {}
            guard await AnalysisFixture.shared.requests == 0 else { throw JournalError.invalidTransfer }
            stage = "receive watch result"
            let source = URL.documentsDirectory.appendingPathComponent("watch-result.json")
            let result = try JSONDecoder().decode(ProcessingResult.self, from: Data(contentsOf: source))
            try store.receiveResult(result)
            try store.receiveResult(result)
            guard try store.pendingRecordings().contains(where: { $0.id == result.recording.id }),
                  try !store.recording(result.recording.id).isPlayable else { throw JournalError.invalidTransfer }
            stage = "retain review audio"
            dailySettings.keepReviewAudio = true
            _ = await processDays(automatic: false)
            guard store.sourceAudio(raw.id).url != nil,
                  try store.daily(rawDay)?.retainsAudio == true,
                  try store.daily(rawDay)?.cleanupCompletedAt == nil else { throw JournalError.invalidTransfer }
            stage = "disable retention and archive"
            dailySettings.keepReviewAudio = false
            // Re-enabling processing permits the older committed report to finish cleanup.
            _ = await processDays(automatic: false)
            let report = try store.daily(JournalDayKey(recording: result.recording))
            guard report?.meetings.count == 1, report?.meetings.first?.minutes == result.job.minutes,
                  report?.cleanupCompletedAt != nil,
                  report?.meetings.first?.citations == result.job.citations,
                  report?.meetings.first?.citations?.count == 1,
                  report?.meetings.first?.markers == result.recording.markers,
                  store.sourceAudio(result.recording.id) == .cleaned,
                  await AnalysisFixture.shared.requests == 0 else { throw JournalError.invalidTransfer }
            try store.receiveResult(result)
            guard try store.recording(result.recording.id).rawDeletedAt != nil else { throw JournalError.invalidTransfer }
            stage = "metadata"
            let data = try Export.metadata(store)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["formatVersion"] as? Int == 1,
                  let rows = object["recordings"] as? [[String: Any]], rows.count == 2,
                  String(data: data, encoding: .utf8)?.contains("fixture-key") == false else {
                throw JournalError.invalidTransfer
            }
            message = nil // The earlier "none" probe intentionally raised an alert.
            evidence = ["passed": true, "noneRetainsRaw": true, "phoneModelRequests": 0,
                        "nonePausesPreviouslyCommittedCleanup": true, "noneBlocksRequestBoundary": true,
                        "watchResultArchived": true, "duplicateResultIgnored": true,
                        "metadataOnlyRecordingSupported": true, "metadataExported": true,
                        "citationsAndMarkersSurviveCleanup": true, "cleanedAudioExplicit": true,
                        "retentionSettingAppliedAndReversible": true]
        } catch { evidence = ["passed": false, "stage": stage, "error": error.localizedDescription] }
        try? JSONSerialization.data(withJSONObject: evidence, options: .prettyPrinted)
            .write(to: store.localStateURL("simulation-result.json"), options: .atomic)
    }
}
#endif
