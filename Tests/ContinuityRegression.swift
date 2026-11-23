import Foundation

@main
enum ContinuityRegression {
    static var checks = 0
    static func check(_ value: @autoclosure () throws -> Bool, _ name: String) throws {
        guard try value() else { fatalError("FAIL: \(name)") }
        checks += 1
    }
    static func main() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let id = UUID()
        var recovery = RecordingRecovery()
        recovery.begin(recordingID: id, enabled: false, now: now)
        try check(recovery.pending == nil, "resume defaults to explicit opt in")
        recovery.begin(recordingID: id, enabled: true, now: now)
        try check(recovery.nextAttempt(shouldResume: false, now: now) == nil && recovery.pending == nil,
                  "system refusal cancels intent")
        recovery.begin(recordingID: id, enabled: true, now: now)
        for expected in [0.0, 2, 5] {
            try check(recovery.nextAttempt(shouldResume: true, now: now) == expected, "bounded retry delay \(expected)")
        }
        try check(recovery.nextAttempt(shouldResume: true, now: now) == nil && recovery.pending == nil, "only three attempts")
        recovery.begin(recordingID: id, enabled: true, now: now)
        let token = recovery.pending?.token
        recovery.cancel()
        try check(recovery.nextAttempt(shouldResume: true, now: now) == nil, "stop cancels future retry")
        recovery.begin(recordingID: id, enabled: true, now: now)
        try check(recovery.pending?.token != token, "stale callback cannot authorize new recovery")
        recovery.expire(now: now.addingTimeInterval(119))
        try check(recovery.pending != nil, "waiting before deadline")
        try check(recovery.nextAttempt(shouldResume: true, now: now.addingTimeInterval(120)) == nil, "deadline blocks late recovery")
        recovery.begin(recordingID: id, enabled: true, now: now)
        recovery.expire(now: now.addingTimeInterval(120))
        try check(recovery.pending == nil, "timeout expires without ended notification")
        try check(RecordingRecovery().pending == nil, "cold start has no recovery intent")

        var entry = Recording(id: id, startedAt: now, duration: 600, state: .saved)
        try check(entry.addMarker(at: .nan) == nil && entry.addMarker(at: -1) == nil, "reject invalid marker offset")
        let marker = entry.addMarker(at: 302.25)!
        try check(entry.addMarker(at: 302.9) == nil, "accidental repeat tap coalesced")
        try check(entry.addMarker(at: 304) != nil && entry.markers?.count == 2, "distinct markers retained")
        let encoded = try JSONEncoder().encode(entry)
        try check(try JSONDecoder().decode(Recording.self, from: encoded).markers?.first == marker, "marker round trip")
        let legacy = #"{"id":"00000000-0000-0000-0000-000000000001","startedAt":0,"duration":10,"state":"saved","note":""}"#
        let old = try JSONDecoder().decode(Recording.self, from: Data(legacy.utf8))
        try check(old.markers == nil && old.continuation == nil && old.validTimeline, "legacy metadata remains readable")
        entry.continuation = RecordingContinuation(sessionID: UUID(), previousRecordingID: UUID(),
            gapStartedAt: now.addingTimeInterval(-20), resumedAt: now)
        try check(entry.continuation?.gapDuration == 20 && entry.validTimeline, "explicit twenty second recording gap")

        let json = """
        {"minutes":"纪要改写，不是原话","energeticSpeech":[],
         "transcript":[{"startSeconds":4,"endSeconds":8,"text":"我们下周再讨论。"},
                       {"startSeconds":-1,"endSeconds":3,"text":"越界"},
                       {"startSeconds":3,"endSeconds":61,"text":"越界"},
                       {"startSeconds":8,"endSeconds":4,"text":"倒序"},
                       {"startSeconds":2,"endSeconds":3,"text":" "}],
         "highlights":[{"statement":"下周讨论","transcriptIndex":0},
                       {"statement":"下周讨论","transcriptIndex":0},
                       {"statement":"无来源","transcriptIndex":99},
                       {"statement":"负数","transcriptIndex":-1},
                       {"statement":"越界","transcriptIndex":1},
                       {"statement":"越界","transcriptIndex":2},
                       {"statement":"倒序","transcriptIndex":3},
                       {"statement":"空白","transcriptIndex":4},
                       {"statement":" ","transcriptIndex":0}]}
        """
        let parsed = try SpeechChunk.parse(json, start: now.addingTimeInterval(300), duration: 60,
                                          recordingID: id, sourceOffset: 300)
        try check(parsed.2.count == 1, "invalid transcript references rejected and duplicates coalesced")
        let citation = parsed.2[0]
        try check(citation.startSeconds == 304 && citation.endSeconds == 308, "silence-skipping retains original file offset")
        try check(citation.quote == "我们下周再讨论。" && citation.quote != parsed.0, "quote comes from transcript not summary")
        try check(citation.isValid(for: entry), "citation validated against recording identity and duration")
        var other = entry
        other.duration = 307 - 1
        try check(!citation.isValid(for: other), "past-end quote rejected")
        try check(try SpeechChunk.parse("旧纪要", start: now, duration: 60, recordingID: id).2.isEmpty, "legacy prose cannot invent sources")
        try check(try SpeechChunk.parse(json, start: now, duration: 60).2.isEmpty, "no source recording means no citation")

        let root = URL.temporaryDirectory.appendingPathComponent("ContinuityRegression-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JournalStore(root: root)
        try store.save(entry)
        let source = root.appendingPathComponent("source.m4a")
        try Data([1, 2, 3]).write(to: source)
        try store.receive(source, recording: entry)
        try check(store.sourceAudio(id).url != nil, "existing local source can play")
        try check(try store.recording(id).markers == entry.markers, "markers survive file transfer")
        var stale = entry
        stale.markers = nil
        stale.continuation = nil
        try store.receive(source, recording: stale)
        try check(try store.recording(id).markers == entry.markers && store.recording(id).continuation != nil,
                  "old duplicate metadata does not erase timeline")
        var job = MeetingAnalysisJob(model: "fixture", credential: "personal", includeContext: false)
        job.state = .complete
        job.minutes = "纪要"
        job.processor = .watch
        job.resultID = UUID()
        job.citations = [citation]
        let result = ProcessingResult(id: job.resultID!, recording: entry, job: job)
        try JSONDecoder().decode(ProcessingResult.self, from: JSONEncoder().encode(result)).validate()
        checks += 1
        let remote = JournalStore(root: root.appendingPathComponent("remote"))
        try remote.receiveResult(result)
        try check(try remote.analysis(id)?.citations == [citation] && remote.recording(id).markers == entry.markers,
                  "citations and markers survive result-only transfer")
        try check(remote.sourceAudio(id) == .unavailable, "metadata-only source never advertises playback")
        let day = JournalDayKey(recording: entry)
        let digest = MeetingDigest(id: id, startedAt: now, duration: 600, title: "会话", location: nil,
            minutes: "纪要", events: [], healthNote: nil, citations: [citation],
            markers: entry.markers, continuation: entry.continuation)
        var report = DailyJournalReport(day: day, generatedAt: now, meetings: [digest],
            health: HealthDay(start: now, localDate: day.localDate), healthNote: nil,
            thresholds: HeartRateSettings(), cloudBackupRequired: false, retainsAudio: true)
        try store.saveDaily(report)
        try check(try store.purgeDaily(day).isEmpty && store.sourceAudio(id).url != nil, "retained review audio resists cleanup")
        report.retainsAudio = false
        try store.saveDaily(report)
        _ = try store.purgeDaily(day)
        try check(store.sourceAudio(id) == .cleaned, "deleted original explicitly unavailable")
        let persisted = try JournalStore(root: root).daily(day)?.meetings.first
        try check(persisted?.citations == [citation] && persisted?.markers == entry.markers,
                  "daily sources and markers survive cleanup and restart")
        try check(persisted?.continuation?.gapDuration == 20, "gap survives cleanup")
        try check(digest.shareText.contains(citation.quote) && digest.shareText.contains(id.uuidString),
                  "shared review preserves quote and stable recording reference")
        try check(JournalReview.grouped([report], monthly: true).first?.days.first?.meetings.first?.citations == [citation],
                  "monthly review retains daily source trail")
        print("PASS: \(checks) continuity and source checks")
    }
}
