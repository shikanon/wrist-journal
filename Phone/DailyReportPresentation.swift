import Charts
import ImageIO
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct DailyReportHome: View {
    @ObservedObject var journal: PhoneJournal
    let openRecordings: () -> Void
    @State private var analysisPreview: DailyAnalysisPreview?
    private var latest: DailyJournalReport? { DailyJournalReport.preferred(in: journal.days) }

    var body: some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-journal-sources-preview") ||
            ProcessInfo.processInfo.arguments.contains("-journal-map-preview-report") {
            JournalReviewView(journal: journal)
        } else {
            home
        }
        #else
        home
        #endif
    }

    private var home: some View {
        List {
            if let report = latest {
                DailyReportSections(journal: journal, report: report)
                    .id(report.id)
            } else {
                ContentUnavailableView {
                    Label("还没有日报", systemImage: "doc.text")
                } description: {
                    Text("同步手表录音，再分析已结束的日期。会议要点会汇总到这里。")
                } actions: {
                    Button("前往录音") { openRecordings() }
                }
                .listRowBackground(Color.clear)
            }
            ReportAnalysisSection(journal: journal, onRequest: showAnalysis)
        }
        .navigationTitle("日报")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink("历史日报") { JournalReviewView(journal: journal) }
            }
            if latest != nil, journal.processingMode != .none {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: showAnalysis) {
                        Label("生成日报", systemImage: "sparkles")
                    }
                    .disabled(journal.processingDays || journal.hasAnalysisWorker || journal.readingHealth)
                }
            }
        }
        .sheet(item: $analysisPreview) { scope in
            DailyAnalysisConfirmation(scope: scope) {
                analysisPreview = nil
                Task { _ = await journal.processDays(automatic: false, preview: scope) }
            }
        }
    }

    private func showAnalysis() {
        do { analysisPreview = try journal.analysisPreview() }
        catch { journal.message = "无法读取待分析录音：\(error.localizedDescription)" }
    }
}

struct ArchivedDailyReportView: View {
    @ObservedObject var journal: PhoneJournal
    let original: DailyJournalReport

    var body: some View {
        let report = journal.days.first { $0.id == original.id } ?? original
        List { DailyReportSections(journal: journal, report: report) }
            .navigationTitle("日报")
            .navigationBarTitleDisplayMode(.inline)
    }
}

private struct DailyReportSections: View {
    @ObservedObject var journal: PhoneJournal
    let report: DailyJournalReport
    @State private var edition: DailyReportEdition?
    @State private var loadError: String?
    @State private var reportBeingEdited: DailyJournalReport?
    @State private var loaded = false
    private var narrative: DailyReportNarrative { edition?.narrative ?? report.narrative }
    private var photos: [DailyReportEdition.Photo] { edition?.photos ?? [] }
    private var newMeetingCount: Int { edition.map { report.meetingIDs.subtracting($0.meetingIDs).count } ?? 0 }

    var body: some View {
        Section {
            hero
                .listRowInsets(.init(top: 0, leading: 0, bottom: 0, trailing: 0))
                .listRowBackground(Color.clear)
                .sheet(item: $reportBeingEdited) { snapshot in
                    DailyReportEditor(journal: journal, report: snapshot, edition: edition) { saved in
                        edition = saved
                    }
                }
        }
        Section {
            ReportMarkdown(markdown: narrative.markdown)
                .padding(.vertical, 6)
            if newMeetingCount > 0 {
                Label("新增 \(newMeetingCount) 段会议。已编辑的正文保留，可在来源中查看新内容。", systemImage: "doc.badge.plus")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if loadError != nil {
                Text("暂时无法读取你的编辑版，下方操作可重新读取。").font(.footnote).foregroundStyle(.secondary)
                Button("重新读取编辑版") { loadEdition() }
            }
        } header: {
            HStack {
                Text(edition == nil ? (report.meetings.isEmpty ? "概览" : "AI 纪要要点") : "编辑版正文")
                Spacer()
                Button("编辑日报", systemImage: "square.and.pencil") { reportBeingEdited = report }
                    .textCase(nil)
                    .disabled(!loaded || loadError != nil)
            }
        }
        if !photos.isEmpty {
            Section("图片") {
                ForEach(photos) { photo in ReportPhotoView(photo: photo) }
            }
        }
        if !report.meetingHours.isEmpty {
            Section("会议时间分布") { ReportMeetingChart(hours: report.meetingHours) }
        }
        Section("来源与分享") {
            if !report.meetings.isEmpty {
                NavigationLink {
                    DailyReportView(journal: journal, report: report)
                } label: {
                    Label("会议与来源 · \(report.meetings.count) 段", systemImage: "text.quote")
                }
                .accessibilityIdentifier("daily-report.sources")
            }
            if !report.health.metrics.isEmpty {
                DisclosureGroup {
                    ForEach(HealthMetric.allCases) { metric in
                        if let measurement = report.health.metrics[metric] {
                            LabeledContent(metric.title, value: "\(metric.display(measurement.value)) \(metric.unit)")
                        }
                    }
                } label: {
                    Label("当日健康", systemImage: "heart.text.clipboard")
                }
            }
            ShareLink(item: "\(narrative.title) · \(report.day.localDate)\n\n\(narrative.markdown)") {
                Label("分享日报文字", systemImage: "square.and.arrow.up")
            }
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 13) {
            Label(report.day.localDate, systemImage: "calendar")
                .font(.subheadline.monospacedDigit().weight(.medium))
                .foregroundStyle(.secondary)
            Text(narrative.title)
                .font(.system(.largeTitle, design: .serif).weight(.bold))
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("daily-report.title")
                .fixedSize(horizontal: false, vertical: true)
            if !report.meetings.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 22) { reportStats }
                    VStack(alignment: .leading, spacing: 8) { reportStats }
                }
                .font(.subheadline.weight(.medium))
            }
            if edition != nil {
                Label("已编辑", systemImage: "checkmark.circle.fill").font(.caption.weight(.medium))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background {
            RoundedRectangle(cornerRadius: 20)
                .fill(.teal.opacity(0.12).gradient)
                .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(.teal.opacity(0.2)) }
        }
        .task(id: report.id) {
            loadEdition()
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-journal-report-editor-preview"), edition != nil {
                reportBeingEdited = report
            }
            #endif
        }
        .onChange(of: journal.dailyEditionRevision) { _, _ in loadEdition() }
    }

    @ViewBuilder private var reportStats: some View {
        Label("\(report.meetings.count) 段会议", systemImage: "bubble.left.and.bubble.right")
        Label("总时长 \(durationText(report.meetings.reduce(0) { $0 + $1.duration }))", systemImage: "clock")
    }

    private func loadEdition() {
        do {
            edition = try journal.store.dailyEdition(report.day)
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
        loaded = true
    }
}

private struct ReportMeetingChart: View {
    let hours: [DailyJournalReport.MeetingHour]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Chart(hours) { item in
                BarMark(x: .value("录制开始小时", item.hour),
                        y: .value("分钟", item.duration / 60), width: .ratio(0.64))
                    .foregroundStyle(.teal.gradient)
                    .cornerRadius(3)
                    .accessibilityLabel("\(item.hour) 点开始")
                    .accessibilityValue(durationText(item.duration))
            }
            .chartXScale(domain: -0.8...23.8)
            .chartXAxis {
                AxisMarks(values: [0, 6, 12, 18, 23]) { value in
                    AxisValueLabel {
                        if let hour = value.as(Int.self) { Text("\(hour)时") }
                    }
                }
            }
            .chartYAxisLabel("分钟")
            .frame(height: 148)
            Text("按录制地的开始小时计入；跨小时的录音不拆分。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }
}

private struct ReportMarkdown: View {
    let markdown: String

    var body: some View {
        let lines = markdown.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(lines.indices, id: \.self) { index in
                let line = lines[index].trimmingCharacters(in: .whitespaces)
                if line.isEmpty {
                    Spacer().frame(height: 2).accessibilityHidden(true)
                } else if line.hasPrefix("## ") || line.hasPrefix("# ") || line.hasPrefix("### ") {
                    inline(String(line.drop { $0 == "#" || $0 == " " }))
                        .font(.headline).padding(.top, 6).accessibilityAddTraits(.isHeader)
                } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(.teal).accessibilityHidden(true)
                        inline(String(line.dropFirst(2)))
                    }
                } else {
                    inline(line)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    private func inline(_ line: String) -> Text {
        guard var styled = try? AttributedString(markdown: line, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        else { return Text(line) }
        let links = styled.runs.filter { $0.link != nil }.map(\.range)
        for range in links { styled[range].link = nil }
        return Text(styled)
    }
}

private struct ReportPhotoView: View {
    let photo: DailyReportEdition.Photo

    var body: some View {
        if let image = UIImage(data: photo.jpeg) {
            VStack(alignment: .leading, spacing: 6) {
                Image(uiImage: image)
                    .resizable().scaledToFit()
                    .clipShape(.rect(cornerRadius: 10))
                    .accessibilityLabel(photo.caption.isEmpty ? "日报照片" : photo.caption)
                if !photo.caption.isEmpty {
                    Text(photo.caption).font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
                }
            }
            .padding(.vertical, 4)
        }
    }
}

/// Downsample before decoding the original at its full size, and export without library metadata.
private struct ReportImageImport: Transferable {
    let jpeg: Data

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            ReportImageImport(jpeg: try compressedJPEG(from: received.file))
        }
    }

    static func compressedJPEG(from file: URL) throws -> Data {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1440
              ] as CFDictionary) else { throw CocoaError(.fileReadCorruptFile) }
        for quality in [0.8, 0.6, 0.4] {
            let buffer = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(buffer, UTType.jpeg.identifier as CFString, 1, nil)
            else { break }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            if CGImageDestinationFinalize(destination), buffer.length <= 1_048_576 {
                return buffer as Data
            }
        }
        throw CocoaError(.fileReadTooLarge)
    }
}

#if DEBUG
@MainActor
extension PhoneJournal {
    func runDailyReportEditionSimulation() async {
        let evidence: [String: Any]
        do {
            guard await processDays(automatic: false),
                  var report = DailyJournalReport.preferred(in: days), report.meetings.count == 1 else {
                throw AnalysisError.invalidResponse
            }
            let next = report.meetings[0].startedAt.addingTimeInterval(3 * 3600)
            report.meetings.append(MeetingDigest(id: UUID(), startedAt: next, duration: 840,
                title: "项目交接", location: nil, minutes: "团队确认在下周跟进交接事项。", events: [], healthNote: nil))
            try store.saveDaily(report)
            let generated = try await draftDailyReport(report)
            guard generated.title == "差旅与项目交接", generated.markdown.contains("## 待办"),
                  await AnalysisFixture.shared.audioBytes == 0 else { throw AnalysisError.invalidResponse }

            let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
            defer { try? FileManager.default.removeItem(at: source) }
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let image = UIGraphicsImageRenderer(size: CGSize(width: 1900, height: 560), format: format).image { context in
                UIColor(red: 0.05, green: 0.26, blue: 0.30, alpha: 1).setFill()
                context.fill(CGRect(x: 0, y: 0, width: 1900, height: 560))
                UIColor(red: 0.31, green: 0.75, blue: 0.68, alpha: 1).setStroke()
                let path = UIBezierPath()
                path.move(to: CGPoint(x: 110, y: 375))
                path.addLine(to: CGPoint(x: 530, y: 280))
                path.addLine(to: CGPoint(x: 870, y: 350))
                path.addLine(to: CGPoint(x: 1260, y: 175))
                path.addLine(to: CGPoint(x: 1730, y: 220))
                path.lineWidth = 12
                path.stroke()
            }
            guard let png = image.pngData() else { throw CocoaError(.fileWriteUnknown) }
            try png.write(to: source)
            let jpeg = try ReportImageImport.compressedJPEG(from: source)
            guard let decoded = UIImage(data: jpeg), decoded.size.width == 1440 else { throw CocoaError(.fileReadCorruptFile) }
            var edited = generated
            edited.title = "编辑版：差旅与项目交接"
            edited.markdown += "\n\n## 补记\n- 出发前再核对行程。"
            let edition = DailyReportEdition(narrative: edited, photos: [.init(jpeg: jpeg, caption: "私有图片说明")],
                                             meetingIDs: report.meetingIDs)
            try saveDailyEdition(edition, for: report.day)
            // A subsequent archive write must update facts without overwriting the edition.
            report.meetings.append(MeetingDigest(id: UUID(), startedAt: next, duration: 180,
                title: "迟到会议", location: nil, minutes: "这是稍后同步的会议。", events: [], healthNote: nil))
            try store.saveDaily(report)
            reload()
            guard try store.dailyEdition(report.day) == edition, report.meetingHours.count == 2,
                  report.meetings.count - edition.meetingIDs.count == 1 else { throw AnalysisError.invalidResponse }
            evidence = ["passed": true, "textOnlyAIDraft": true, "downsampledWidth": Int(decoded.size.width),
                        "photoBytes": jpeg.count, "laterMeetingPreservesEdits": true]
        } catch {
            evidence = ["passed": false, "error": error.localizedDescription]
        }
        writeReportEvidence(evidence, named: "report-edition-result.json")
    }

    func verifyDailyReportEditionSimulation() {
        var passed = false
        if let report = DailyJournalReport.preferred(in: days),
           let edition = try? store.dailyEdition(report.day) {
            passed = edition.narrative.title == "编辑版：差旅与项目交接" &&
                edition.narrative.markdown.contains("出发前再核对行程") &&
                edition.photos.first.flatMap { UIImage(data: $0.jpeg) } != nil &&
                report.meetingIDs.subtracting(edition.meetingIDs).count == 1
        }
        writeReportEvidence(["passed": passed], named: "report-edition-restart.json")
    }

    private func writeReportEvidence(_ evidence: [String: Any], named name: String) {
        try? JSONSerialization.data(withJSONObject: evidence, options: .prettyPrinted)
            .write(to: store.localStateURL(name), options: .atomic)
    }
}
#endif

private struct DailyReportEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var journal: PhoneJournal
    let report: DailyJournalReport
    let onSave: (DailyReportEdition) -> Void
    let initial: DailyReportEdition
    @State private var draft: DailyReportEdition
    @State private var preview = false
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var loadingPhotos = false
    @State private var aiRequest: UUID?
    @State private var confirmAI = false
    @State private var confirmDiscard = false
    @State private var failure: String?
    private var busy: Bool { loadingPhotos || aiRequest != nil }

    init(journal: PhoneJournal, report: DailyJournalReport, edition: DailyReportEdition?, onSave: @escaping (DailyReportEdition) -> Void) {
        self.journal = journal
        self.report = report
        self.onSave = onSave
        initial = edition ?? DailyReportEdition(narrative: report.narrative, meetingIDs: report.meetingIDs)
        _draft = State(initialValue: initial)
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("显示方式", selection: $preview) {
                    Text("编辑").tag(false)
                    Text("预览").tag(true)
                }
                .pickerStyle(.segmented)
                if let failure { Text(failure).foregroundStyle(.red).font(.footnote) }
                if busy { ProgressView(aiRequest == nil ? "正在读取图片" : "AI 正在整理纪要") }
                if preview {
                    Section {
                        Text(draft.narrative.title).font(.title.bold())
                        ReportMarkdown(markdown: draft.narrative.markdown)
                        ForEach(draft.photos) { ReportPhotoView(photo: $0) }
                    }
                } else {
                    editFields.disabled(busy)
                }
            }
            .navigationTitle("编辑日报")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        if draft != initial { confirmDiscard = true } else { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(!draft.isValid || busy)
                }
            }
            .alert("放弃未保存的更改？", isPresented: $confirmDiscard) {
                Button("继续编辑", role: .cancel) {}
                Button("放弃更改", role: .destructive) { dismiss() }
            }
            .confirmationDialog("用 AI 重新起草正文？", isPresented: $confirmAI, titleVisibility: .visible) {
                Button("生成草稿") { aiRequest = UUID() }
            } message: {
                Text("将最多 12 场已生成的会议纪要发送到火山方舟，可能包含此前附加到纪要中的心率汇总。不会发送原音、照片或编辑内容。生成会替换编辑器里的标题和正文，保存后才会应用。")
            }
            .task(id: aiRequest) {
                guard aiRequest != nil else { return }
                failure = nil
                do {
                    let narrative = try await journal.draftDailyReport(report)
                    try Task.checkCancellation()
                    draft.narrative = narrative
                    preview = true
                } catch is CancellationError {} catch {
                    failure = "无法生成草稿：\(error.localizedDescription)"
                }
                aiRequest = nil
            }
            .task(id: selectedPhotos) { await importPhotos() }
        }
        .interactiveDismissDisabled(draft != initial || busy)
    }

    @ViewBuilder private var editFields: some View {
        Section("标题") {
            TextField("日报标题", text: $draft.narrative.title)
                .accessibilityIdentifier("daily-report.editor.title")
            if draft.narrative.title.count > 120 { Text("标题最多 120 字。").foregroundStyle(.red) }
        }
        Section {
            TextEditor(text: $draft.narrative.markdown)
                .frame(minHeight: 210)
                .accessibilityLabel("日报正文")
                .accessibilityIdentifier("daily-report.editor.body")
            if draft.narrative.markdown.count > 16_000 { Text("正文最多 16,000 字。").foregroundStyle(.red) }
        } header: {
            Text("正文")
        } footer: {
            Text(verbatim: "可用「## 小标题」「- 列表」「**重点**」，切换到预览查看效果。")
        }
        Section {
            ForEach($draft.photos) { $photo in
                ReportPhotoView(photo: .init(jpeg: photo.jpeg))
                TextField("图片说明", text: $photo.caption)
                if photo.caption.count > 160 { Text("说明最多 160 字。").foregroundStyle(.red) }
                Button("移除图片", role: .destructive) {
                    let id = photo.id
                    draft.photos.removeAll { $0.id == id }
                }
            }
            if draft.photos.count < 3 {
                PhotosPicker(selection: $selectedPhotos, maxSelectionCount: 3 - draft.photos.count, matching: .images) {
                    Label("添加照片", systemImage: "photo.badge.plus")
                }
            }
        } header: {
            Text("图片 · \(draft.photos.count)/3")
        } footer: {
            Text("照片和手动编辑保存在这台 iPhone。")
        }
        Section {
            if journal.processingMode == .phone, report.meetings.count >= 2 {
                Button("用 AI 合并会议纪要", systemImage: "sparkles") { confirmAI = true }
            }
            Button("恢复自动正文") { draft.narrative = report.narrative }
                .disabled(draft.narrative == report.narrative)
        }
    }

    private func importPhotos() async {
        guard !selectedPhotos.isEmpty else { return }
        loadingPhotos = true
        failure = nil
        defer { loadingPhotos = false; selectedPhotos = [] }
        for item in selectedPhotos.prefix(3 - draft.photos.count) {
            do {
                guard let image = try await item.loadTransferable(type: ReportImageImport.self) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                try Task.checkCancellation()
                draft.photos.append(.init(jpeg: image.jpeg))
            } catch is CancellationError { return } catch {
                failure = "有照片无法读取，已保留其他图片。请重新选择。"
            }
        }
    }

    private func save() {
        draft.narrative.title = draft.narrative.title.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.meetingIDs = report.meetingIDs
        draft.editedAt = .now
        do {
            try journal.saveDailyEdition(draft, for: report.day)
            onSave(draft)
            dismiss()
        } catch {
            failure = "未能保存：\(error.localizedDescription)"
        }
    }
}
