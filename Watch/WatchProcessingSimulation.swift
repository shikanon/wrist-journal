#if DEBUG
import AVFoundation

@MainActor
extension WatchJournal {
    func runProcessingSimulation() async {
        var evidence: [String: Any]
        do {
            var markedEntry = Recording(id: UUID(), startedAt: .now.addingTimeInterval(-3 * 86400),
                                  duration: 4, state: .saved, storage: .phone, timeZoneIdentifier: "Asia/Shanghai")
            _ = markedEntry.addMarker(at: 1.5)
            let entry = markedEntry
            try store.save(entry)
            try AnalysisFixture.makeAudio(store.audio(entry.id))
            var job = MeetingAnalysisJob(model: MeetingAnalyzer.defaultModel, credential: "personal", includeContext: false)
            job.processor = .watch
            await AnalysisFixture.shared.failOnce()
            do {
                _ = try await watchAnalyzer.run(recording: entry, url: store.audio(entry.id), job: job, key: "fixture-key",
                    checkpoint: { [store] snapshot in
                        try store.saveAnalysis(JSONEncoder().encode(snapshot), id: entry.id, complete: false)
                    })
                throw JournalError.invalidTransfer
            } catch AnalysisError.http(401) {}
            guard let checkpoint = try store.analysis(entry.id), checkpoint.audioPlan != nil else {
                throw JournalError.invalidTransfer
            }
            var finished = try await watchAnalyzer.run(recording: entry, url: store.audio(entry.id), job: checkpoint,
                key: "fixture-key", checkpoint: { [store] snapshot in
                    try store.saveAnalysis(JSONEncoder().encode(snapshot), id: entry.id, complete: false)
                })
            finished.resultID = UUID()
            let result = ProcessingResult(id: finished.resultID!, recording: entry, job: finished)
            try store.saveWatchResult(result)
            let restarted = JournalStore(root: try store.localStateURL(""))
            guard try restarted.pendingResults().count == 1, finished.state == .complete,
                  finished.speechWindows?.first?.start == entry.startedAt.addingTimeInterval(1),
                  finished.citations?.count == 1, finished.citations?.first?.quote == "我们下周再跟进行动项。",
                  finished.citations?.first?.startSeconds == 1,
                  await AnalysisFixture.shared.requests == 3,
                  await AnalysisFixture.shared.audioBytes > 0 else { throw JournalError.invalidTransfer }
            try JSONEncoder().encode(result).write(to: store.localStateURL("watch-result.json"), options: .atomic)
            try restarted.acknowledgeResult(result.id)
            guard try restarted.pendingResults().isEmpty else { throw JournalError.invalidTransfer }
            evidence = ["passed": true, "requests": 3, "compressedBytes": await AnalysisFixture.shared.audioBytes,
                        "unauthorizedCheckpointResumed": true, "sourceTimePreserved": true,
                        "durableResultAcknowledged": true, "watchAnalyzerExecuted": true,
                        "transcriptCitationsGenerated": true, "markersInResult": true]
        } catch { evidence = ["passed": false, "error": error.localizedDescription] }
        try? JSONSerialization.data(withJSONObject: evidence, options: .prettyPrinted)
            .write(to: store.localStateURL("simulation-result.json"), options: .atomic)
    }
}
#endif
