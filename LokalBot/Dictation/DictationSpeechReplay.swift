import AVFoundation
import Foundation

enum DictationSpeechReplay {
    struct Request: Equatable {
        var input: URL
        var model: TranscriptionModelChoice
        var language: TranscriptionLanguage
        var passes: Int
        var preview = false
        var prefixEvery: Double?
    }

    struct Input: Decodable {
        var cases: [Case]
    }

    struct Case: Decodable {
        var id: String
        var audio: String
    }

    struct Observation: Encodable {
        var id: String
        var pass: Int
        var seconds: Double
        var text: String
        var ticks: [DictationCoordinator.PreviewTick]?
        var prefixes: [Prefix]?
    }

    struct Prefix: Encodable, Equatable {
        var audioSeconds: Double
        var seconds: Double
        var text: String
    }

    static func parse(_ args: [String]) -> Request? {
        guard let flag = args.firstIndex(of: "--dictation-speech-replay"), args.count > flag + 1,
              let modelFlag = args.firstIndex(of: "--model"), args.count > modelFlag + 1,
              let model = TranscriptionModelChoice(rawValue: args[modelFlag + 1]), !model.isRemote,
              model != .appleSpeech else { return nil }
        let language = args.firstIndex(of: "--language")
            .flatMap { args.count > $0 + 1 ? TranscriptionLanguage(rawValue: args[$0 + 1]) : nil } ?? .auto
        let passes = args.firstIndex(of: "--passes")
            .flatMap { args.count > $0 + 1 ? Int(args[$0 + 1]) : nil } ?? 3
        return Request(input: URL(fileURLWithPath: args[flag + 1]), model: model, language: language,
                       passes: min(max(passes, 1), 10), preview: args.contains("--preview"),
                       prefixEvery: args.firstIndex(of: "--prefix-every")
                           .flatMap { args.count > $0 + 1 ? Double(args[$0 + 1]) : nil }.map { min(max($0, 1), 60) })
    }

    static func order(count: Int, pass: Int) -> [Int] {
        pass % 2 == 1 ? Array((0..<count).reversed()) : Array(0..<count)
    }

    static func settings(for request: Request) -> AppSettings {
        var settings = AppSettings()
        settings.transcriptionModel = request.model
        settings.transcriptionLanguage = request.language
        settings.transcriptionPrompt = ""
        return settings
    }

    @MainActor
    static func run(_ request: Request) async -> Int32 {
        do {
            let data = try Data(contentsOf: request.input)
            let input = try JSONDecoder().decode(Input.self, from: data)
            guard !input.cases.isEmpty, input.cases.count <= 500,
                  Set(input.cases.map(\.id)).count == input.cases.count else { throw ReplayError.invalidInput }
            let folder = request.input.deletingLastPathComponent()
            let config = settings(for: request)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let warmup = ContinuousClock.now
            _ = try await DictationCoordinator.transcribe(
                folder.appendingPathComponent(input.cases[0].audio), config: config, retriesWithoutVocabulary: false)
            try write(["warmupSeconds": seconds(ContinuousClock.now - warmup)])
            let scratch = FileManager.default.temporaryDirectory
                .appendingPathComponent("lokalbot-speech-replay-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: scratch) }
            for pass in 0..<request.passes {
                for index in order(count: input.cases.count, pass: pass) {
                    let item = input.cases[index]
                    let ticks = request.preview && pass == 0
                        ? try await DictationCoordinator.replayedPreview(
                            of: folder.appendingPathComponent(item.audio), config: config, storageRoot: scratch)
                        : nil
                    let prefixes = pass == 0
                        ? try await request.prefixEvery.asyncMap {
                            try await Self.prefixes(of: folder.appendingPathComponent(item.audio), every: $0,
                                                    config: config, scratch: scratch)
                        }
                        : nil
                    let start = ContinuousClock.now
                    let transcript = try await DictationCoordinator.transcribe(
                        folder.appendingPathComponent(item.audio), config: config, retriesWithoutVocabulary: false)
                    let observation = Observation(
                        id: item.id, pass: pass, seconds: seconds(ContinuousClock.now - start),
                        text: transcript.segments.map(\.displayText).joined(separator: " "), ticks: ticks, prefixes: prefixes)
                    try FileHandle.standardOutput.write(contentsOf: encoder.encode(observation) + Data([10]))
                }
            }
            return 0
        } catch {
            try? FileHandle.standardError.write(contentsOf: Data("Dictation speech replay failed: \(error)\n".utf8))
            return 1
        }
    }

    @MainActor
    static func prefixes(of audio: URL, every step: Double, config: AppSettings, scratch: URL) async throws -> [Prefix] {
        let reader = try AVAudioFile(forReading: audio)
        let format = reader.processingFormat
        let total = Double(reader.length) / max(format.sampleRate, 1)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        var result: [Prefix] = []
        var end = step
        while end < total {
            let url = scratch.appendingPathComponent("prefix-\(UUID().uuidString).\(audio.pathExtension)")
            defer { try? FileManager.default.removeItem(at: url) }
            try copy(reader, frames: AVAudioFramePosition(end * format.sampleRate), to: url)
            let start = ContinuousClock.now
            let text = (try? await DictationCoordinator.transcribe(url, config: config, retriesWithoutVocabulary: false))
                .map { $0.segments.map(\.displayText).joined(separator: " ") } ?? ""
            result.append(Prefix(audioSeconds: end, seconds: seconds(ContinuousClock.now - start), text: text))
            end += step
        }
        return result
    }

    private static func copy(_ reader: AVAudioFile, frames: AVAudioFramePosition, to url: URL) throws {
        let format = reader.processingFormat
        let writer = try AVAudioFile(forWriting: url, settings: reader.fileFormat.settings,
                                     commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_384) else { throw ReplayError.invalidInput }
        reader.framePosition = 0
        var remaining = min(frames, reader.length)
        while remaining > 0 {
            try reader.read(into: buffer, frameCount: AVAudioFrameCount(min(remaining, 16_384)))
            guard buffer.frameLength > 0 else { break }
            try writer.write(from: buffer)
            remaining -= AVAudioFramePosition(buffer.frameLength)
        }
    }

    private enum ReplayError: Error { case invalidInput }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    private static func write(_ value: [String: Double]) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        try FileHandle.standardOutput.write(contentsOf: data + Data([10]))
    }
}

private extension Optional {
    func asyncMap<T>(_ transform: (Wrapped) async throws -> T) async rethrows -> T? {
        guard let self else { return nil }
        return try await transform(self)
    }
}
