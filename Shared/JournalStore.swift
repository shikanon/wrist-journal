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
        let destination = try folder(recording.id)
        if try recordingWrites.withLock({
            guard files.fileExists(atPath: destination.path) else { return false }
            try save(recording)
            return true
        }) { return }

        let staging = try root().appendingPathComponent(".incoming-\(UUID().uuidString)")
        try files.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: staging) }
        let audioName = try audio(recording.id).lastPathComponent
        try files.copyItem(at: source, to: staging.appendingPathComponent(audioName))
        try JSONEncoder().encode(recording).write(to: staging.appendingPathComponent("recording.json"))
        try files.moveItem(at: staging, to: destination)
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
