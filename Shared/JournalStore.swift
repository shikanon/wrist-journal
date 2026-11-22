import Foundation

private struct RecordingIndex: Codable {
    let id: UUID
    let start: Date
    let day: JournalDayKey
    let rawDeleted: Bool
    init(_ entry: Recording) {
        id = entry.id; start = entry.startedAt
        day = JournalDayKey(recording: entry); rawDeleted = entry.rawDeletedAt != nil
    }
}

private struct DailyIndex: Codable {
    let day: JournalDayKey
    let cleanupPending: Bool
    let healthRange: DateInterval?
    let meetingRanges: [DateInterval]
    init(_ report: DailyJournalReport) {
        day = report.day
        cleanupPending = !report.meetings.isEmpty && report.cleanupCompletedAt == nil
        healthRange = JournalDayKey(localDate: report.day.localDate,
            timeZoneIdentifier: report.healthTimeZoneIdentifier ?? report.day.timeZoneIdentifier).interval
        meetingRanges = report.meetings.map {
            DateInterval(start: $0.startedAt.addingTimeInterval(-300),
                         end: $0.startedAt.addingTimeInterval(max(0, $0.duration)))
        }
    }
}

private struct JournalCatalog: Codable {
    var version = 2
    var recordings: [String: RecordingIndex] = [:]
    var days: [String: DailyIndex] = [:]
    var unfinishedAnalysis: Set<UUID> = []
    var pendingRecordings: Set<UUID> = []
    var pendingCleanup: Set<JournalDayKey> = []
}

private final class StoreState {
    let lock = NSRecursiveLock()
    var catalog: JournalCatalog?
    var root: URL?
}

/// Atomic files are the source of truth. A dirty marker makes index updates recoverable.
struct JournalStore {
    private let files = FileManager.default
    private let customRoot: URL?
    private let state = StoreState()
    init(root: URL? = nil) { customRoot = root }

    private func root() throws -> URL {
        try state.lock.withLock {
            if let root = state.root { return root }
            var location = customRoot ?? URL.applicationSupportDirectory.appendingPathComponent("WristJournal")
            #if os(iOS)
            let attributes: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
            #else
            let attributes: [FileAttributeKey: Any] = [:]
            #endif
            try files.createDirectory(at: location, withIntermediateDirectories: true, attributes: attributes)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try location.setResourceValues(values)
            state.root = location
            return location
        }
    }

    func localStateURL(_ name: String) throws -> URL { try root().appendingPathComponent(name) }
    private func folder(_ id: UUID) throws -> URL { try root().appendingPathComponent(id.uuidString, isDirectory: true) }
    func audio(_ id: UUID) throws -> URL { try folder(id).appendingPathComponent("WristJournal-\(id.uuidString).m4a") }

    private func directory(_ name: String) throws -> URL {
        let url = try root().appendingPathComponent(name, isDirectory: true)
        try files.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func catalog() throws -> JournalCatalog {
        if let cached = state.catalog { return cached }
        let url = try localStateURL("catalog.json")
        let dirty = try localStateURL(".catalog-dirty")
        if !files.fileExists(atPath: dirty.path), let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode(JournalCatalog.self, from: data), saved.version == 2 {
            state.catalog = saved
            return saved
        }
        // One migration/recovery scan; normal reads only decode the requested page.
        var rebuilt = JournalCatalog()
        let migrated = files.fileExists(atPath: url.path)
        for child in try files.contentsOfDirectory(at: root(), includingPropertiesForKeys: nil) {
            guard let id = UUID(uuidString: child.lastPathComponent) else { continue }
            let entry = try recording(id)
            rebuilt.recordings[id.uuidString] = RecordingIndex(entry)
            if entry.needsLocalProcessing { rebuilt.pendingRecordings.insert(id) }
            if let data = try? Data(contentsOf: analysisURL(id)),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               object["state"] as? String != "complete" { rebuilt.unfinishedAnalysis.insert(id) }
            if !migrated, entry.rawDeletedAt != nil { try enqueuePurgeUnlocked(id) }
        }
        for url in try files.contentsOfDirectory(at: directory("Daily"), includingPropertiesForKeys: nil)
            where url.pathExtension == "json" {
            let report = try JSONDecoder().decode(DailyJournalReport.self, from: Data(contentsOf: url))
            rebuilt.days[report.id] = DailyIndex(report)
            if DailyIndex(report).cleanupPending { rebuilt.pendingCleanup.insert(report.day) }
        }
        try JSONEncoder().encode(rebuilt).write(to: url, options: .atomic)
        if files.fileExists(atPath: dirty.path) { try files.removeItem(at: dirty) }
        state.catalog = rebuilt
        return rebuilt
    }

    private func change<T>(_ body: (inout JournalCatalog) throws -> T) throws -> T {
        try state.lock.withLock {
            var index = try catalog()
            let dirty = try localStateURL(".catalog-dirty")
            try Data([1]).write(to: dirty, options: .atomic)
            do {
                let value = try body(&index)
                try JSONEncoder().encode(index).write(to: localStateURL("catalog.json"), options: .atomic)
                state.catalog = index
                try files.removeItem(at: dirty)
                return value
            } catch {
                state.catalog = nil
                throw error
            }
        }
    }

    func availableStorage() throws -> (free: Int64?, capacity: Int64?) {
        let space = try files.attributesOfFileSystem(forPath: root().path)
        return ((space[.systemFreeSize] as? NSNumber)?.int64Value, (space[.systemSize] as? NSNumber)?.int64Value)
    }
    func recording(_ id: UUID) throws -> Recording {
        try JSONDecoder().decode(Recording.self, from: Data(contentsOf: folder(id).appendingPathComponent("recording.json")))
    }
    func list(offset: Int = 0, limit: Int = .max) throws -> [Recording] {
        try state.lock.withLock {
            try catalog().recordings.values.sorted { $0.start > $1.start }
                .dropFirst(max(0, offset)).prefix(max(0, limit)).map { try recording($0.id) }
        }
    }
    func pendingRecordings(day: JournalDayKey? = nil) throws -> [Recording] {
        try state.lock.withLock {
            let index = try catalog()
            return try index.pendingRecordings.compactMap { index.recordings[$0.uuidString] }
                .filter { day == nil || $0.day == day }
                .sorted { $0.start < $1.start }.map { try recording($0.id) }
        }
    }
    func pendingDays() throws -> [JournalDayKey] {
        try state.lock.withLock {
            let index = try catalog()
            return Array(Set(index.pendingRecordings.compactMap { index.recordings[$0.uuidString]?.day })
                .union(index.pendingCleanup))
                .sorted { $0.id < $1.id }
        }
    }
    func unfinishedAnalysisIDs() throws -> Set<UUID> {
        try state.lock.withLock { try catalog().unfinishedAnalysis }
    }
    private func write(_ entry: Recording, index: inout JournalCatalog) throws {
        let url = try folder(entry.id)
        try files.createDirectory(at: url, withIntermediateDirectories: true)
        try JSONEncoder().encode(entry).write(to: url.appendingPathComponent("recording.json"), options: .atomic)
        index.recordings[entry.id.uuidString] = RecordingIndex(entry)
        if entry.needsLocalProcessing { index.pendingRecordings.insert(entry.id) }
        else { index.pendingRecordings.remove(entry.id) }
    }
    func save(_ recording: Recording) throws { try change { try write(recording, index: &$0) } }
    func delete(_ id: UUID) throws {
        try change {
            try files.removeItem(at: folder(id))
            $0.recordings.removeValue(forKey: id.uuidString)
            $0.unfinishedAnalysis.remove(id)
            $0.pendingRecordings.remove(id)
        }
    }
    func receive(_ source: URL, recording: Recording) throws {
        var recording = recording
        recording.localEvictedAt = nil
        guard recording.isPlayable, recording.duration.isFinite, recording.duration > 0,
              let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 else {
            throw JournalError.invalidTransfer
        }
        try change { index in
            if let previous = try? self.recording(recording.id) {
                if previous.rawDeletedAt != nil {
                    try enqueuePurgeUnlocked(recording.id)
                    return
                }
                recording.cloudUploadedAt = previous.cloudUploadedAt ?? recording.cloudUploadedAt
                recording.motionWindows = previous.motionWindows ?? recording.motionWindows
            }
            let destination = try folder(recording.id)
            let audioURL = try audio(recording.id)
            if !files.fileExists(atPath: audioURL.path) {
                let staging = try root().appendingPathComponent(".incoming-\(UUID().uuidString)")
                try files.createDirectory(at: staging, withIntermediateDirectories: false)
                defer { try? files.removeItem(at: staging) }
                let stagedAudio = staging.appendingPathComponent(audioURL.lastPathComponent)
                try files.copyItem(at: source, to: stagedAudio)
                if files.fileExists(atPath: destination.path) {
                    try files.moveItem(at: stagedAudio, to: audioURL)
                } else {
                    try JSONEncoder().encode(recording).write(to: staging.appendingPathComponent("recording.json"))
                    try files.moveItem(at: staging, to: destination)
                }
            }
            try write(recording, index: &index)
        }
    }

    /// Persist the remote acknowledgment and unlink intent before releasing the local copy.
    func evictLocal(_ id: UUID, cloudConfirmedAt: Date? = nil) throws {
        try state.lock.withLock {
            var entry = try recording(id)
            guard entry.rawDeletedAt == nil else { return }
            if let cloudConfirmedAt { entry.cloudUploadedAt = cloudConfirmedAt }
            guard entry.storage == .phone || entry.cloudUploadedAt != nil else { throw JournalError.invalidTransfer }
            let intent = try directory("PendingEviction").appendingPathComponent(id.uuidString)
            try Data().write(to: intent, options: .atomic)
            entry.localEvictedAt = .now
            try save(entry)
            try finishEviction(id)
        }
    }
    private func finishEviction(_ id: UUID) throws {
        let intent = try directory("PendingEviction").appendingPathComponent(id.uuidString)
        guard files.fileExists(atPath: try folder(id).path) else {
            try files.removeItem(at: intent)
            return
        }
        let entry = try recording(id)
        // An intent without a committed acknowledgment must never delete audio.
        if entry.localEvictedAt != nil {
            let url = try audio(id)
            if files.fileExists(atPath: url.path) { try files.removeItem(at: url) }
        }
        try files.removeItem(at: intent)
    }
    func recoverEvictions() throws {
        try state.lock.withLock {
            for url in try files.contentsOfDirectory(at: directory("PendingEviction"), includingPropertiesForKeys: nil) {
                if let id = UUID(uuidString: url.lastPathComponent) { try finishEviction(id) }
            }
        }
    }
    func pendingCloudCompletionIDs() throws -> [UUID] {
        try state.lock.withLock {
            try files.contentsOfDirectory(at: directory("PendingCloudCompletion"), includingPropertiesForKeys: nil)
                .compactMap { UUID(uuidString: $0.lastPathComponent) }
        }
    }
    func acknowledgeCloudCompletion(_ id: UUID) throws {
        try state.lock.withLock {
            let url = try directory("PendingCloudCompletion").appendingPathComponent(id.uuidString)
            if files.fileExists(atPath: url.path) { try files.removeItem(at: url) }
        }
    }
    func analysisURL(_ id: UUID) throws -> URL { try folder(id).appendingPathComponent("meeting-analysis.json") }
    func saveAnalysis(_ data: Data, id: UUID, complete: Bool) throws {
        try change {
            try data.write(to: analysisURL(id), options: .atomic)
            if complete { $0.unfinishedAnalysis.remove(id) } else { $0.unfinishedAnalysis.insert(id) }
        }
    }
    private func dailyURL(_ day: JournalDayKey) throws -> URL {
        let name = Data(day.id.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_")
        return try directory("Daily").appendingPathComponent(name).appendingPathExtension("json")
    }
    func daily(_ day: JournalDayKey) throws -> DailyJournalReport? {
        let url = try dailyURL(day)
        guard files.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(DailyJournalReport.self, from: Data(contentsOf: url))
    }
    func dailyReports(offset: Int = 0, limit: Int = .max) throws -> [DailyJournalReport] {
        try state.lock.withLock {
            try catalog().days.values.sorted { $0.day.id > $1.day.id }
                .dropFirst(max(0, offset)).prefix(max(0, limit)).compactMap { try daily($0.day) }
        }
    }
    func dailyKeys() throws -> [JournalDayKey] {
        try state.lock.withLock { try catalog().days.values.map(\.day) }
    }
    func affectedHealthDays(_ ranges: [DateInterval]) throws -> Set<JournalDayKey> {
        try state.lock.withLock {
            Set(try catalog().days.values.filter { row in
                let intervals = row.meetingRanges + [row.healthRange].compactMap { $0 }
                return intervals.contains { interval in ranges.contains { HealthQueryRanges.overlaps(interval, $0) } }
            }.map(\.day))
        }
    }
    func saveDaily(_ report: DailyJournalReport) throws {
        try change {
            try JSONEncoder().encode(report).write(to: dailyURL(report.day), options: .atomic)
            $0.days[report.id] = DailyIndex(report)
            if DailyIndex(report).cleanupPending { $0.pendingCleanup.insert(report.day) }
            else { $0.pendingCleanup.remove(report.day) }
        }
    }
    func completeCleanup(_ day: JournalDayKey) throws {
        guard var report = try daily(day), report.cleanupCompletedAt == nil, report.canPurge,
              try report.meetings.allSatisfy({ try recording($0.id).rawDeletedAt != nil }) else { return }
        report.cleanupCompletedAt = .now
        try saveDaily(report)
    }
    /// Read committed report. Completion is recorded only after analysis checkpoints are compacted.
    func purgeDaily(_ day: JournalDayKey) throws -> [UUID] {
        guard let report = try daily(day) else { throw JournalError.invalidTransfer }
        guard report.day == day, day.hasEnded(), report.canPurge, report.cleanupCompletedAt == nil else { return [] }
        var changed: [UUID] = []
        for meeting in report.meetings {
            if try purgeRaw(meeting.id) { changed.append(meeting.id) }
        }
        return changed
    }
    @discardableResult
    func purgeRaw(_ id: UUID) throws -> Bool {
        try state.lock.withLock {
            guard var entry = try? recording(id) else { return false }
            let url = try audio(id)
            let hasAudio = files.fileExists(atPath: url.path)
            guard entry.rawDeletedAt == nil || hasAudio else { return false }
            return try change { index in
                // Pending notification exists before deletion; a crash can only cause a duplicate, never a lost purge.
                try enqueuePurgeUnlocked(id)
                if entry.storage == .cloud {
                    try Data().write(to: directory("PendingCloudCompletion").appendingPathComponent(id.uuidString), options: .atomic)
                }
                if entry.rawDeletedAt == nil {
                    entry.rawDeletedAt = .now
                    try write(entry, index: &index)
                }
                if hasAudio { try files.removeItem(at: url) }
                return true
            }
        }
    }
    private func enqueuePurgeUnlocked(_ id: UUID) throws {
        let url = try directory("PendingPurge").appendingPathComponent(id.uuidString)
        if !files.fileExists(atPath: url.path) { try Data().write(to: url, options: .atomic) }
    }
    func pendingPurgeIDs() throws -> [UUID] {
        try state.lock.withLock {
            _ = try catalog()
            return try files.contentsOfDirectory(at: directory("PendingPurge"), includingPropertiesForKeys: nil)
                .compactMap { UUID(uuidString: $0.lastPathComponent) }.sorted { $0.uuidString < $1.uuidString }
        }
    }
    func acknowledgePurge(_ ids: [UUID]) throws {
        try state.lock.withLock {
            for id in ids {
                let url = try directory("PendingPurge").appendingPathComponent(id.uuidString)
                if files.fileExists(atPath: url.path) { try files.removeItem(at: url) }
            }
        }
    }
    func purgedIDs() throws -> [UUID] {
        try state.lock.withLock { try catalog().recordings.values.filter(\.rawDeleted).map(\.id) }
    }

    func report() throws -> HealthReport? {
        let url = try localStateURL("health.json")
        guard files.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(HealthReport.self, from: Data(contentsOf: url))
    }
    func saveReport(_ report: HealthReport) throws {
        try JSONEncoder().encode(report).write(to: localStateURL("health.json"), options: .atomic)
    }
    func deleteReport() throws { try files.removeItem(at: localStateURL("health.json")) }
    func outgoingReport(_ report: HealthReport) throws -> URL {
        let url = try directory("Outgoing").appendingPathComponent("\(UUID().uuidString).json")
        try JSONEncoder().encode(report).write(to: url, options: .atomic)
        return url
    }
    func cleanOutgoingReports(keeping active: Set<URL>) throws {
        for file in try files.contentsOfDirectory(at: directory("Outgoing"), includingPropertiesForKeys: nil)
            where !active.contains(file.standardizedFileURL) { try files.removeItem(at: file) }
    }
}
