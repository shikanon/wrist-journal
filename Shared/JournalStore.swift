import Foundation

struct JournalStore {
    private let files = FileManager.default
    private let customRoot: URL?
    private let recordingWrites = NSLock()

    init(root: URL? = nil) {
        customRoot = root
    }

    private func root() throws -> URL {
        let location = customRoot ?? URL.applicationSupportDirectory.appendingPathComponent("WristJournal")
        #if os(iOS)
        let attributes: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        #else
        let attributes: [FileAttributeKey: Any] = [:]
        #endif
        try files.createDirectory(at: location, withIntermediateDirectories: true, attributes: attributes)
        var directory = location
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        return directory
    }

    private func folder(_ id: UUID) throws -> URL {
        try root().appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func audio(_ id: UUID) throws -> URL {
        try folder(id).appendingPathComponent("WristJournal-\(id.uuidString).m4a")
    }

    func availableStorage() throws -> (free: Int64?, capacity: Int64?) {
        let space = try files.attributesOfFileSystem(forPath: root().path)
        return ((space[.systemFreeSize] as? NSNumber)?.int64Value,
                (space[.systemSize] as? NSNumber)?.int64Value)
    }

    func recording(_ id: UUID) throws -> Recording {
        try JSONDecoder().decode(Recording.self, from: Data(contentsOf: folder(id).appendingPathComponent("recording.json")))
    }

    func list() throws -> [Recording] {
        let children = try files.contentsOfDirectory(at: root(), includingPropertiesForKeys: nil,
                                                     options: .skipsHiddenFiles)
        return children.compactMap { directory in
            guard let id = UUID(uuidString: directory.lastPathComponent),
                  let data = try? Data(contentsOf: directory.appendingPathComponent("recording.json")),
                  let recording = try? JSONDecoder().decode(Recording.self, from: data),
                  recording.id == id else { return nil }
            return recording
        }.sorted { $0.startedAt > $1.startedAt }
    }

    func save(_ recording: Recording) throws {
        let directory = try folder(recording.id)
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(recording).write(
            to: directory.appendingPathComponent("recording.json"), options: .atomic
        )
    }

    func delete(_ id: UUID) throws {
        try recordingWrites.withLock {
            try files.removeItem(at: folder(id))
        }
    }

    func receive(_ source: URL, recording: Recording) throws {
        guard recording.isPlayable, recording.duration.isFinite, recording.duration > 0,
              let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 else {
            throw JournalError.invalidTransfer
        }
        try recordingWrites.withLock {
            if let previous = try? self.recording(recording.id), previous.rawDeletedAt != nil { return }
            let destination = try folder(recording.id)
            let audioURL = try audio(recording.id)
            if files.fileExists(atPath: audioURL.path) {
                try save(recording)
                return
            }

            let staging = try root().appendingPathComponent(".incoming-\(UUID().uuidString)")
            try files.createDirectory(at: staging, withIntermediateDirectories: false)
            defer { try? files.removeItem(at: staging) }
            let stagedAudio = staging.appendingPathComponent(audioURL.lastPathComponent)
            try files.copyItem(at: source, to: stagedAudio)
            if files.fileExists(atPath: destination.path) {
                try files.moveItem(at: stagedAudio, to: audioURL)
                try save(recording)
            } else {
                try JSONEncoder().encode(recording).write(to: staging.appendingPathComponent("recording.json"))
                try files.moveItem(at: staging, to: destination)
            }
        }
    }

    func analysisURL(_ id: UUID) throws -> URL {
        try folder(id).appendingPathComponent("meeting-analysis.json")
    }

    private func dailyFolder() throws -> URL {
        let url = try root().appendingPathComponent("Daily", isDirectory: true)
        try files.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func dailyURL(_ day: JournalDayKey) throws -> URL {
        // Encode the full key so time zones containing "/" never create subdirectories.
        let name = Data(day.id.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_")
        return try dailyFolder().appendingPathComponent(name).appendingPathExtension("json")
    }

    func dailyReports() throws -> [DailyJournalReport] {
        try files.contentsOfDirectory(at: dailyFolder(), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .map { try JSONDecoder().decode(DailyJournalReport.self, from: Data(contentsOf: $0)) }
            .sorted { $0.day.localDate > $1.day.localDate }
    }

    func saveDaily(_ report: DailyJournalReport) throws {
        try JSONEncoder().encode(report).write(to: dailyURL(report.day), options: .atomic)
    }

    /// Must read the committed report, never trust a transient in-memory result.
    func purgeDaily(_ day: JournalDayKey) throws -> [UUID] {
        let report = try JSONDecoder().decode(DailyJournalReport.self, from: Data(contentsOf: dailyURL(day)))
        guard report.day == day, day.hasEnded(), report.canPurge else { return [] }
        var ids: [UUID] = []
        for meeting in report.meetings {
            try purgeRaw(meeting.id)
            ids.append(meeting.id)
        }
        return ids
    }

    func purgeRaw(_ id: UUID) throws {
        try recordingWrites.withLock {
            guard var entry = try? recording(id) else { return }
            entry.rawDeletedAt = entry.rawDeletedAt ?? .now
            // Write the tombstone first; retrying also removes an audio file left by a crash.
            try save(entry)
            let url = try audio(id)
            if files.fileExists(atPath: url.path) { try files.removeItem(at: url) }
        }
    }

    func purgedIDs() throws -> [UUID] {
        try list().filter { $0.rawDeletedAt != nil }.map(\.id)
    }

    func report() throws -> HealthReport? {
        let url = try root().appendingPathComponent("health.json")
        guard files.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(HealthReport.self, from: Data(contentsOf: url))
    }

    func saveReport(_ report: HealthReport) throws {
        let url = try root().appendingPathComponent("health.json")
        try JSONEncoder().encode(report).write(to: url, options: .atomic)
    }

    func deleteReport() throws {
        let url = try root().appendingPathComponent("health.json")
        try files.removeItem(at: url)
    }

    func outgoingReport(_ report: HealthReport) throws -> URL {
        let directory = try root().appendingPathComponent("Outgoing", isDirectory: true)
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(UUID().uuidString).json")
        try JSONEncoder().encode(report).write(to: url, options: .atomic)
        return url
    }

    func cleanOutgoingReports(keeping active: Set<URL>) throws {
        let directory = try root().appendingPathComponent("Outgoing", isDirectory: true)
        guard files.fileExists(atPath: directory.path) else { return }
        for file in try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            if !active.contains(file.standardizedFileURL) { try files.removeItem(at: file) }
        }
    }
}
