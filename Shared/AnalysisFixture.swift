#if DEBUG
import AVFoundation

/// Only selected by a Debug launch argument; no live credential or service is used.
actor AnalysisFixture {
    static let shared = AnalysisFixture()
    private(set) var requests = 0
    private(set) var audioBytes = 0
    private var failNext = false
    func failOnce() { failNext = true }
    func respond(_ request: URLRequest) throws -> (Data, URLResponse) {
        guard request.url?.absoluteString == "https://ark.cn-beijing.volces.com/api/v3/chat/completions",
              request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key",
              let body = request.httpBody,
              let object = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let messages = object["messages"] as? [[String: Any]],
              let content = messages.last?["content"] as? [[String: Any]] else { throw JournalError.invalidTransfer }
        requests += 1
        if failNext {
            failNext = false
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!)
        }
        let audio = content.first?["input_audio"] as? [String: Any]
        if let audio {
            guard audio["format"] as? String == "m4a", let raw = audio["data"] as? String,
                  let bytes = Data(base64Encoded: raw), !bytes.isEmpty else { throw JournalError.invalidTransfer }
            audioBytes += bytes.count
        }
        let text: String
        if ProcessInfo.processInfo.arguments.contains("-journal-report-edition-simulation") {
            guard audio == nil, content.count == 1, let prompt = content.first?["text"] as? String,
                  prompt.contains("会议 1"), prompt.contains("会议 2"), !prompt.contains("私有图片说明"),
                  !prompt.contains("编辑版：差旅与项目交接") else { throw JournalError.invalidTransfer }
            text = "# 差旅与项目交接\n\n## 当日进展\n- 团队确认出行计划。\n\n## 待办\n- **下周跟进**交接事项。"
        } else {
            text = audio == nil ? "Watch 纪要：确认行动项，下周跟进。" :
                #"{"minutes":"已讨论行动项","energeticSpeech":[{"startSeconds":1,"endSeconds":2,"evidence":"语速加快"}],"transcript":[{"startSeconds":1,"endSeconds":2,"text":"我们下周再跟进行动项。"}],"highlights":[{"statement":"下周跟进行动项","transcriptIndex":0}]}"#
        }
        return (try JSONSerialization.data(withJSONObject: [
            "choices": [["finish_reason": "stop", "message": ["content": text]]]
        ]), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    static func makeAudio(_ url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64_000)!
        buffer.frameLength = buffer.frameCapacity
        for frame in 0..<Int(buffer.frameLength) {
            buffer.floatChannelData![0][frame] = Float(0.1 * sin(2 * Double.pi * 440 * Double(frame) / 16_000))
        }
        let audio = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32_000
        ])
        try audio.write(from: buffer)
    }
}
#endif
