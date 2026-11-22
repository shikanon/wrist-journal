import AVFoundation

enum AudioPreparation {
    /// Only removes >=8 seconds below both conservative thresholds, with half-second edge padding.
    /// It never joins disjoint source ranges into one uploaded segment.
    static func plan(_ audio: AVAudioFile, skipSilence: Bool) throws -> AudioPlan {
        let rate = audio.processingFormat.sampleRate
        let channels = Int(audio.processingFormat.channelCount)
        guard rate.isFinite, rate > 0, channels > 0, audio.length > 0 else { throw AnalysisError.unreadableAudio }
        let maxFrames = Int64(min(rate * 120, Double(4 * 1024 * 1024 / (2 * channels))))
        guard maxFrames > 0 else { throw AnalysisError.unreadableAudio }
        var removed: [Range<Int64>] = []
        if skipSilence {
            let window = AVAudioFrameCount(max(1, rate / 4))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: window) else {
                throw AnalysisError.unreadableAudio
            }
            audio.framePosition = 0
            var quietStart: Int64?
            var everAudible = false
            func finishQuiet(_ end: Int64) {
                if let start = quietStart, Double(end - start) / rate >= 8 {
                    let padding = Int64(rate / 2)
                    let lower = start == 0 ? 0 : start + padding
                    let upper = end == audio.length ? end : end - padding
                    if upper > lower { removed.append(lower..<upper) }
                }
                quietStart = nil
            }
            while audio.framePosition < audio.length {
                try Task.checkCancellation()
                let start = audio.framePosition
                try audio.read(into: buffer, frameCount: AVAudioFrameCount(min(Int64(window), audio.length - start)))
                guard buffer.frameLength > 0, let floats = buffer.floatChannelData else {
                    throw AnalysisError.unreadableAudio
                }
                var quiet = true
                for channel in 0..<channels {
                    var sum = 0.0
                    var peak = 0.0
                    for frame in 0..<Int(buffer.frameLength) {
                        let value = Double(floats[channel][frame * Int(buffer.stride)])
                        if !value.isFinite { quiet = false; break }
                        sum += value * value
                        peak = max(peak, abs(value))
                    }
                    // -60 dBFS RMS, -50 dBFS peak. Noise/uncertain content stays.
                    if sum / Double(buffer.frameLength) > 0.000001 || peak > 0.00316227766 { quiet = false }
                }
                if quiet {
                    if quietStart == nil { quietStart = start }
                } else {
                    everAudible = true
                    finishQuiet(start)
                }
            }
            finishQuiet(audio.length)
            if !everAudible, Double(audio.length) / rate >= 8 { removed = [0..<audio.length] }
        }
        var retained: [Range<Int64>] = []
        var cursor: Int64 = 0
        for silence in removed {
            if silence.lowerBound > cursor { retained.append(cursor..<silence.lowerBound) }
            cursor = silence.upperBound
        }
        if cursor < audio.length { retained.append(cursor..<audio.length) }
        let segments = retained.flatMap { range -> [AudioSegment] in
            stride(from: range.lowerBound, to: range.upperBound, by: Int(maxFrames)).map {
                AudioSegment(startFrame: $0, frameCount: min(maxFrames, range.upperBound - $0))
            }
        }
        return AudioPlan(sampleRate: rate, sourceFrames: audio.length, segments: segments)
    }

    static func encode(_ segment: AudioSegment, audio: AVAudioFile, source: URL,
                       format: AudioUploadFormat) throws -> Data {
        if format == .m4a, source.pathExtension.lowercased() == "m4a",
           segment.startFrame == 0, segment.frameCount == audio.length,
           let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 25 * 1024 * 1024 {
            return try Data(contentsOf: source)
        }
        let input = audio.processingFormat
        guard segment.startFrame >= 0, segment.frameCount > 0, segment.frameCount <= Int64(UInt32.max),
              segment.startFrame + segment.frameCount <= audio.length,
              let buffer = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: AVAudioFrameCount(min(32768, segment.frameCount)))
        else { throw AnalysisError.unreadableAudio }
        audio.framePosition = segment.startFrame
        let url = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(format.rawValue)
        defer { try? FileManager.default.removeItem(at: url) }
        let settings: [String: Any] = format == .m4a ? [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: input.sampleRate,
            AVNumberOfChannelsKey: input.channelCount, AVEncoderBitRateKey: 32_000 * Int(input.channelCount)
        ] : [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: input.sampleRate,
            AVNumberOfChannelsKey: input.channelCount, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false
        ]
        do {
            let output = try AVAudioFile(forWriting: url, settings: settings,
                                        commonFormat: input.commonFormat, interleaved: input.isInterleaved)
            var remaining = segment.frameCount
            while remaining > 0 {
                try Task.checkCancellation()
                let requested = AVAudioFrameCount(min(Int64(buffer.frameCapacity), remaining))
                try audio.read(into: buffer, frameCount: requested)
                // AVAudioFile may return a short successful read before EOF (including PCM files).
                guard buffer.frameLength > 0, buffer.frameLength <= requested else { throw AnalysisError.unreadableAudio }
                try output.write(from: buffer)
                remaining -= Int64(buffer.frameLength)
            }
        }
        let data = try Data(contentsOf: url)
        guard data.count < 25 * 1024 * 1024 else { throw AnalysisError.unreadableAudio }
        return data
    }
}
