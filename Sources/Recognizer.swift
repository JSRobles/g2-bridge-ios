import AVFoundation
import Foundation
import Speech

/// Apple's on-device speech recognition (SpeechAnalyzer + SpeechTranscriber, iOS 26+) for one stream
/// of 16 kHz mono 16-bit PCM from the glasses. Volatile results are the sentence in progress;
/// final results are the committed text.
final class Recognizer {
    static let locale = Locale(identifier: "ja-JP")

    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    var onError: ((String) -> Void)?

    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private let sourceFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!

    /// Downloads Apple's Japanese speech model the first time (it may take a minute).
    static func prepareAssets() async {
        do {
            let transcriber = makeTranscriber()
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                appLog("speech: downloading the Japanese model…")
                try await request.downloadAndInstall()
            }
            appLog("speech: Japanese model ready")
        } catch {
            appLog("speech: model setup failed: \(error)")
        }
    }

    private static func makeTranscriber() -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])
    }

    func start() async throws {
        let transcriber = Self.makeTranscriber()
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        if let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) {
            targetFormat = format
            if format != sourceFormat { converter = AVAudioConverter(from: sourceFormat, to: format) }
        }
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        input = continuation
        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    if text.isEmpty { continue }
                    if result.isFinal { self?.onFinal?(text) } else { self?.onPartial?(text) }
                }
            } catch {
                self?.onError?("recognition stopped: \(error)")
            }
        }
        try await analyzer.start(inputSequence: stream)
    }

    /// Raw s16le mono 16 kHz bytes, as the glasses app sends them.
    func push(pcm16 data: Data) {
        guard let input, data.count >= 2 else { return }
        let frames = AVAudioFrameCount(data.count / 2)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frames),
              let channel = buffer.int16ChannelData else { return }
        buffer.frameLength = frames
        data.withUnsafeBytes { raw in
            if let base = raw.baseAddress { memcpy(channel[0], base, Int(frames) * 2) }
        }
        var output = buffer
        if let converter, let targetFormat {
            let capacity = AVAudioFrameCount(Double(frames) * targetFormat.sampleRate / sourceFormat.sampleRate) + 16
            guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
            var supplied = false
            var error: NSError?
            converter.convert(to: converted, error: &error) { _, status in
                if supplied {
                    status.pointee = .noDataNow
                    return nil
                }
                supplied = true
                status.pointee = .haveData
                return buffer
            }
            if error != nil { return }
            output = converted
        }
        input.yield(AnalyzerInput(buffer: output))
    }

    func stop() {
        input?.finish()
        input = nil
        resultsTask?.cancel()
        let analyzer = self.analyzer
        self.analyzer = nil
        Task { try? await analyzer?.finalizeAndFinishThroughEndOfInput() }
    }
}
