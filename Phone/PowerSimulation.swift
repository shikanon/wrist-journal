#if DEBUG
import AVFoundation

@MainActor
extension PhoneJournal {
    func runPowerSimulation() async {
        let resultURL = URL.applicationSupportDirectory.appendingPathComponent("WristJournalUITests/simulation-result.json")
        var evidence: [String: Any] = [:]
        var stage = "audio fixture"
        do {
            func require(_ condition: Bool, _ description: String) throws {
                if !condition { throw NSError(domain: "PowerSimulation", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: description]) }
            }
            let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let source = directory.appendingPathComponent("speech-silence.wav")
            try makeAudioFixture(source, seconds: 25, audible: true)
            let audio = try AVAudioFile(forReading: source)
            stage = "silence plan"
            let plan = try AudioPreparation.plan(audio, skipSilence: true)
            try require(plan.segments.count == 2 && plan.skippedSeconds >= 19, "long silence plan")
            try require(plan.segments[1].startFrame == 344_000, "source time mapping")
            stage = "compressed encoding"
            let compressed = try AudioPreparation.encode(plan.segments[1], audio: audio, source: source, format: .m4a)
            let wav = try AudioPreparation.encode(plan.segments[1], audio: audio, source: source, format: .wav)
            stage = "compressed playback"
            try require(compressed.count < wav.count / 2, "compressed payload reduction")
            let encodedURL = directory.appendingPathComponent("segment.m4a")
            try compressed.write(to: encodedURL)
            let encodedAudio = try AVAudioFile(forReading: encodedURL)
            let encodedDuration = Double(encodedAudio.length) / encodedAudio.processingFormat.sampleRate
            try require(abs(encodedDuration - 3.5) < 0.15, "encoded duration keeps timestamp tolerance")
            let direct = try AudioPreparation.encode(AudioSegment(startFrame: 0, frameCount: encodedAudio.length),
                audio: encodedAudio, source: encodedURL, format: .m4a)
            try require(direct == compressed, "whole M4A bypasses reencoding")
            let silence = directory.appendingPathComponent("silence.wav")
            stage = "all silent analysis"
            try makeAudioFixture(silence, seconds: 12, audible: false)
            let silentRecording = Recording(id: UUID(), startedAt: .now, duration: 12, state: .saved)
            let silentJob = try await analyzer.run(recording: silentRecording, url: silence,
                job: MeetingAnalysisJob(model: MeetingAnalyzer.defaultModel, credential: "personal", includeContext: false),
                key: "", beforeRequest: { throw JournalError.invalidTransfer }, checkpoint: { _ in })
            try require(silentJob.state == .complete && silentJob.totalChunks == 0, "silence completes without network")

            guard let entry = recordings.first else { throw JournalError.invalidTransfer }
            stage = "daily reuse"
            try require(await processDays(automatic: false), "initial daily completion")
            let counts = await dailyHealth.simulationReads()
            let dailyFiles = try FileManager.default.contentsOfDirectory(
                at: store.localStateURL("Daily"), includingPropertiesForKeys: nil)
            let oldReports = try dailyFiles.map { try Data(contentsOf: $0) }
            try require(await processDays(automatic: false), "repeat daily completion")
            try require(counts == (await dailyHealth.simulationReads()), "unchanged days do not reread health")
            try require(oldReports == dailyFiles.map { try Data(contentsOf: $0) },
                        "completed daily files are not rewritten")
            await dailyHealth.simulateChanges([DateInterval(start: entry.startedAt.addingTimeInterval(60), duration: 1)], peak: 145)
            stage = "late health"
            try require(await processDays(automatic: false), "late health refresh")
            let updated = try store.daily(JournalDayKey(recording: entry))
            try require(updated?.meetings.first?.events.first?.peakBPM == 145, "late heart sample updates archived event")
            try require(updated?.cleanupCompletedAt != nil &&
                !FileManager.default.fileExists(atPath: store.audio(entry.id).path), "late health never restores raw audio")
            let afterLate = await dailyHealth.simulationReads()
            try require(afterLate[0] == counts[0] + 1 && afterLate[1] == counts[1] + 1,
                        "only affected health date refreshed")
            // Cooling for speech must not stop an independent local health refresh.
            workState.uploadRetry.fail(configuration: analysisConfiguration, authentication: true)
            stage = "health during key block"
            try workState.save(store)
            await dailyHealth.simulateChanges([DateInterval(start: entry.startedAt.addingTimeInterval(60), duration: 1)], peak: 150)
            try require(await processDays(automatic: false), "health runs while API key blocked")
            try require(try store.daily(JournalDayKey(recording: entry))?.meetings.first?.events.first?.peakBPM == 150,
                        "health result independent of API credentials")
            stage = "removed health sample"
            await dailyHealth.simulateChanges([DateInterval(start: entry.startedAt.addingTimeInterval(60), duration: 1)], peak: 75)
            try require(await processDays(automatic: false), "removed sample refresh")
            let corrected = try store.daily(JournalDayKey(recording: entry))
            try require(corrected?.meetings.first?.events.isEmpty == true && corrected?.cleanupCompletedAt != nil,
                        "removed high sample clears archived event without reopening cleanup")
            stage = "legacy queue recovery"
            let legacyEntry = Recording(id: UUID(), startedAt: .now, duration: 12, state: .saved)
            try store.save(legacyEntry)
            try FileManager.default.copyItem(at: silence, to: store.audio(legacyEntry.id))
            try save(MeetingAnalysisJob(model: MeetingAnalyzer.defaultModel, credential: "personal",
                includeContext: false), for: legacyEntry.id)
            resumeAnalysis()
            try require(!hasAnalysisWorker, "legacy queue cannot bypass automatic network policy")
            evidence = ["passed": true, "scenario": "incremental-power",
                "silenceSkippedSeconds": plan.skippedSeconds, "sourceOffsetSeconds": 21.5,
                "m4aBytes": compressed.count, "wavBytes": wav.count, "encodedDuration": encodedDuration,
                "silentRequests": 0, "completedDayReused": true, "lateHealthUpdated": true,
                "healthWithoutAPIKey": true, "wholeM4AReused": true,
                "removedHealthCorrected": true, "legacyQueueDeferred": true]
        } catch { evidence = ["passed": false, "error": error.localizedDescription, "stage": stage] }
        try? JSONSerialization.data(withJSONObject: evidence, options: .prettyPrinted).write(to: resultURL, options: .atomic)
    }

    private func makeAudioFixture(_ url: URL, seconds: Int, audible: Bool) throws {
        let rate = 16_000.0
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(seconds * Int(rate)))!
        buffer.frameLength = buffer.frameCapacity
        for frame in 0..<Int(buffer.frameLength) {
            let time = Double(frame) / rate
            buffer.floatChannelData![0][frame] = audible && (time < 2 || time >= 22)
                ? Float(0.1 * sin(2 * Double.pi * 440 * time)) : 0
        }
        let output = try AVAudioFile(forWriting: url, settings: format.settings)
        try output.write(from: buffer)
    }
}
#endif
