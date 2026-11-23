import AVFoundation
import Foundation

enum DictationWarmCleanup {
    static let defaultsKey = "dictationWarmCleanup"
    static let interval: Duration = .seconds(5)
    static let minimumWords = 12
    static let speculationArguments = ["--spec-type", "ngram-cache"]

    static var isEnabled: Bool {
        let suite = UITestRuntime.defaultsSuiteName.flatMap { UserDefaults(suiteName: $0) }
        return (suite ?? .standard).bool(forKey: defaultsKey)
    }

    static func applies(_ settings: AppSettings, enabled: Bool = isEnabled) -> Bool {
        enabled && settings.dictationIntent == .compose && settings.summarizerBackend == .builtIn
            && [.parakeetUltra, .parakeetV3, .parakeetV2].contains(settings.transcriptionModel)
    }

    static func shouldClean(_ text: String, after previous: String) -> Bool {
        text != previous && text.split(whereSeparator: \.isWhitespace).count >= minimumWords
            && !DictationGrounding.requestsContext(text)
    }

    /// What the loop was doing when the dictation ended.
    enum Stage: String { case waiting, speech, cleanup }

    /// The log line for a dictation that ended while a warm-up pass was running; nil between passes.
    static func releaseLogLine(stage: Stage, passes: Int, elapsed: Double) -> String? {
        guard stage != .waiting else { return nil }
        return "dictation warm cleanup released in flight stage=\(stage.rawValue) after="
            + String(format: "%.2f", elapsed) + " completed=\(passes)"
    }

    enum CopyError: Error { case unreadable }

    static func copy(of audio: URL, frames limit: AVAudioFramePosition? = nil, to url: URL) throws {
        let reader = try AVAudioFile(forReading: audio)
        let format = reader.processingFormat
        let writer = try AVAudioFile(forWriting: url, settings: reader.fileFormat.settings,
                                     commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_384) else { throw CopyError.unreadable }
        var remaining = min(limit ?? reader.length, reader.length)
        guard remaining > 0 else { throw CopyError.unreadable }
        while remaining > 0 {
            try reader.read(into: buffer, frameCount: AVAudioFrameCount(min(remaining, 16_384)))
            guard buffer.frameLength > 0 else { break }
            try writer.write(from: buffer)
            remaining -= AVAudioFramePosition(buffer.frameLength)
        }
    }
}
