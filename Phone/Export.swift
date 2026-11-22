import SwiftUI
import UniformTypeIdentifiers

struct Export: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText, .html, .json] }

    let data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        guard let contents = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        data = contents
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }

    static func recordings(_ recordings: [Recording], store: JournalStore) -> Self {
        let formatter = ISO8601DateFormatter()
        let available = Set(recordings.filter {
            guard $0.isPlayable, let url = try? store.audio($0.id) else { return false }
            return FileManager.default.fileExists(atPath: url.path)
        }.map(\.id))
        let rows = [["id", "started_at_utc", "duration_seconds", "state", "note", "audio_file",
                     "time_zone", "latitude", "longitude", "local_audio_available"]]
            + recordings.map { entry in
                [entry.id.uuidString, formatter.string(from: entry.startedAt), String(entry.duration),
                 entry.state.rawValue, spreadsheetSafe(entry.note), available.contains(entry.id) ? "WristJournal-\(entry.id.uuidString).m4a" : "",
                 spreadsheetSafe(entry.timeZoneIdentifier ?? ""), entry.location.map { String($0.latitude) } ?? "",
                 entry.location.map { String($0.longitude) } ?? "", available.contains(entry.id) ? "true" : "false"]
            }
        return csv(rows)
    }

    static func metadata(_ store: JournalStore) throws -> Data {
        struct Item: Encodable {
            let recording: Recording
            let endedAtUTC: Date
            let audioFile: String?
            let localAudioAvailable: Bool
        }
        struct Manifest: Encodable {
            let formatVersion = 1
            let exportedAt = Date.now
            let timeEncoding = "ISO-8601 UTC; recording.timeZoneIdentifier preserves capture timezone"
            let recordings: [Item]
            let healthReport: HealthReport?
            let dailyReports: [DailyJournalReport]
        }
        let items = try store.list().map { entry in
            let audioURL = try store.audio(entry.id)
            let available = entry.isPlayable && FileManager.default.fileExists(atPath: audioURL.path)
            return Item(recording: entry, endedAtUTC: entry.startedAt.addingTimeInterval(entry.duration),
                        audioFile: available ? "WristJournal-\(entry.id.uuidString).m4a" : nil,
                        localAudioAvailable: available)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(Manifest(recordings: items, healthReport: store.report(), dailyReports: store.dailyReports()))
    }

    static func healthCSV(_ report: HealthReport) -> Self {
        var rows = [["day", "time_zone", "metric", "unit", "statistic", "value", "min", "max", "samples"]]
        for day in report.days {
            for metric in HealthMetric.allCases {
                let measurement = day.metrics[metric]
                rows.append([
                    day.localDate, report.timeZone, metric.rawValue, metric.unit,
                    metric.isCumulative ? "sum" : "mean",
                    measurement.map { String($0.value) } ?? "",
                    measurement?.minimum.map { String($0) } ?? "",
                    measurement?.maximum.map { String($0) } ?? "",
                    measurement?.sampleCount.map { String($0) } ?? ""
                ])
            }
        }
        return csv(rows)
    }

    static func healthHTML(_ report: HealthReport) -> Self {
        let metrics = HealthMetric.allCases
        let summary = metrics.map { metric in
            let value = report.summary(metric).map { "\(metric.display($0)) \(metric.unit)" } ?? "无数据"
            return "<dt>\(metric.title)</dt><dd>\(value)</dd>"
        }.joined()
        let headers = metrics.map { "<th scope=\"col\">\($0.title)（\($0.unit)）</th>" }.joined()
        let rows = report.days.map { day in
            let cells = metrics.map { metric in
                "<td>\(day.metrics[metric].map { metric.display($0.value) } ?? "—")</td>"
            }.joined()
            return "<tr><th scope=\"row\">\(escapeHTML(day.localDate))</th>\(cells)</tr>"
        }.joined()
        let failed = report.unavailableMetrics.map(\.title).joined(separator: "、")
        let status = failed.isEmpty ? "" : "<p>未读取成功的指标：\(failed)。</p>"
        let generated = ISO8601DateFormatter().string(from: report.generatedAt)
        let html = """
        <!doctype html>
        <html lang="zh-CN">
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>手记 · 健康报告</title>
        <style>
        body { color: #17232c; background: #f3f7f8; font: 16px system-ui, sans-serif; margin: 2rem auto;
               max-width: 56rem; padding: 0 1rem; line-height: 1.6; }
        section { background: white; padding: 1.25rem; margin: 1rem 0; border: 1px solid #dce5ea;
                  border-radius: 1rem; }
        .scroll { overflow-x: auto; }
        dl { display: grid; grid-template-columns: 1fr auto; gap: .5rem 1.2rem; max-width: 28rem; }
        dd { margin: 0; font-variant-numeric: tabular-nums; } table { width: 100%; border-collapse: collapse; }
        th, td { text-align: start; padding: .65rem; border-bottom: 1px solid #dce5ea; }
        th[scope=row] { white-space: nowrap; } p { color: #415764; }
        </style>
        <h1>健康报告</h1>
        <p>生成时间 \(generated) · 日期时区 \(escapeHTML(report.timeZone))</p>
        <section><h2>近 7 天概况</h2><dl>\(summary)</dl></section>
        <section><h2>每日数据</h2><div class="scroll"><table>
        <thead><tr><th scope="col">日期</th>\(headers)</tr></thead><tbody>\(rows)</tbody>
        </table></div>
        <p>心率、静息心率和 SDNN 按日读取样本均值，跨日按有数据的日期求均值。步数和活动能量按日累计。当天数据截至手表报告生成时。空白表示无可用数据，可能与权限或采样有关。</p>
        \(status)</section>
        </html>
        """
        return Self(data: Data(html.utf8))
    }

    private static func csv(_ rows: [[String]]) -> Self {
        let content = rows.map { row in
            row.map { value in
                "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }.joined(separator: ",")
        }.joined(separator: "\r\n")
        return Self(data: Data(("\u{FEFF}" + content + "\r\n").utf8))
    }

    private static func spreadsheetSafe(_ value: String) -> String {
        let leading = value.trimmingCharacters(in: .whitespacesAndNewlines).first
        if let leading, "=+-@＝＋－＠".contains(leading) { return "'" + value }
        return value
    }

    private static func escapeHTML(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
