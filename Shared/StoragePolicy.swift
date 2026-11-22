import Foundation

enum StoragePolicy {
    static func batchMinutes(_ value: Int?) -> Int { min(360, max(15, value ?? 60)) }
    static func idleMinutes(_ value: Int?) -> Int { min(60, max(1, value ?? 10)) }
    static func batchDue(last: Date?, minutes: Int?, now: Date = .now) -> Bool {
        guard let last else { return true }
        return now.timeIntervalSince(last) >= Double(batchMinutes(minutes)) * 60
    }
    static func shouldSend(_ entry: Recording, requested: Bool, endedOnly: Bool,
                           batchDue: Bool, recording: Bool) -> Bool {
        guard !recording, entry.isPlayable else { return false }
        if requested { return !endedOnly || JournalDayKey(recording: entry).hasEnded() }
        return entry.storage == .phone && batchDue
    }
}

struct StorageSyncRequest: Codable {
    var known: Set<UUID>
    var endedOnly: Bool
}

struct StorageWorkState: Codable {
    var lastBatch: Date?
    var request: StorageSyncRequest?
    var cloudRetry = RetryState()
    var nextSourceSync: Date?
    var lastCloudNoticeAt: Date?

    static func load(_ store: JournalStore) -> Self {
        guard let url = try? store.localStateURL("storage-work.json"),
              let data = try? Data(contentsOf: url),
              let saved = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return saved
    }
    func save(_ store: JournalStore) throws {
        try JSONEncoder().encode(self).write(to: store.localStateURL("storage-work.json"), options: .atomic)
    }
}

struct LocalAccessLease {
    let timeout: TimeInterval
    private(set) var deadline: TimeInterval
    init(timeout: TimeInterval, now: TimeInterval) {
        self.timeout = timeout
        deadline = now + timeout
    }
    mutating func touch(at now: TimeInterval) -> Bool {
        guard now < deadline else { return false }
        deadline = now + timeout
        return true
    }
    func expired(at now: TimeInterval) -> Bool { now >= deadline }
}

struct LocalHTTPRequest {
    let path: String
    let headers: [String: String]
    init?(_ data: Data, host: String) {
        guard data.count <= 16_384, let text = String(data: data, encoding: .utf8),
              text.hasSuffix("\r\n\r\n") else { return nil }
        let lines = text.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        guard parts.count == 3, parts[0] == "GET", parts[2] == "HTTP/1.1",
              parts[1].hasPrefix("/"), !parts[1].contains("#") else { return nil }
        var fields: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":"), line.first != " ", line.first != "\t" else { return nil }
            let key = line[..<colon].lowercased()
            guard fields[key] == nil else { return nil }
            fields[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard fields["host"] == host, fields["transfer-encoding"] == nil,
              fields["content-length"] == nil || fields["content-length"] == "0" else { return nil }
        path = String(parts[1]); headers = fields
    }
    func authorized(token: String) -> Bool {
        let expected = Array("Bearer \(token)".utf8)
        let supplied = Array((headers["authorization"] ?? "").utf8)
        guard !token.isEmpty, expected.count == supplied.count else { return false }
        return zip(expected, supplied).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
