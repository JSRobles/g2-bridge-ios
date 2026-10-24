import AVFoundation
import Foundation
import Speech

/// One language's recognizer: Apple's on-device SpeechAnalyzer + SpeechTranscriber (iOS 26+) fed
/// with 16 kHz mono 16-bit PCM. Volatile results are the phrase in progress; final results are
/// committed text. Each result carries Apple's confidence for its words.
final class RecognizerChannel {
    let locale: Locale
    /// text, mean confidence (0...1) if known, isFinal, where in the audio the result ends (seconds)
    var onResult: ((String, Double?, Bool, Double) -> Void)?
    var onError: ((String) -> Void)?

    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private let sourceFormat: AVAudioFormat

    init(locale: Locale, sourceFormat: AVAudioFormat) {
        self.locale = locale
        self.sourceFormat = sourceFormat
    }

    static func makeTranscriber(_ locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: [.transcriptionConfidence, .audioTimeRange])
    }

    /// Downloads Apple's speech model for a language the first time (it may take a minute).
    static func prepareAssets(_ locale: Locale) async {
        do {
            let transcriber = makeTranscriber(locale)
            if let request = try await AssetInstallationRequestHelper.request(for: transcriber) {
                appLog("speech: downloading the \(locale.identifier) model…")
                try await request.downloadAndInstall()
            }
            appLog("speech: \(locale.identifier) model ready")
        } catch {
            appLog("speech: \(locale.identifier) model setup failed: \(error)")
        }
    }

    func start() async throws {
        let transcriber = Self.makeTranscriber(locale)
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
                    self?.onResult?(text, Self.meanConfidence(result.text), result.isFinal, result.range.end.seconds)
                }
            } catch {
                self?.onError?("\(self?.locale.identifier ?? "?") recognition stopped: \(error)")
            }
        }
        try await analyzer.start(inputSequence: stream)
    }

    /// Mean of Apple's confidence over the characters of a result.
    private static func meanConfidence(_ text: AttributedString) -> Double? {
        var total = 0.0
        var count = 0.0
        for (confidence, range) in text.runs[\.transcriptionConfidence] {
            guard let confidence else { continue }
            let length = Double(text[range].characters.count)
            total += confidence * length
            count += length
        }
        return count > 0 ? total / count : nil
    }

    /// A buffer in the app's source format (16 kHz mono Int16).
    func push(_ buffer: AVAudioPCMBuffer) {
        guard let input else { return }
        var output = buffer
        if let converter, let targetFormat {
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * targetFormat.sampleRate / sourceFormat.sampleRate) + 16
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

enum AssetInstallationRequestHelper {
    static func request(for transcriber: SpeechTranscriber) async throws -> AssetInstallationRequest? {
        try await AssetInventory.assetInstallationRequest(supporting: [transcriber])
    }
}

/// Japanese and English recognizers listening to the same audio. Apple's Japanese model turns
/// English speech into katakana, so the English recognizer runs alongside it and, when it is clearly
/// the more confident of the two, the Japanese result is dropped (the glasses app shows nothing
/// for English, as the PC server does).
final class Recognizer {
    static let japanese = Locale(identifier: "ja-JP")
    static let english = Locale(identifier: "en-US")
    /// English must beat Japanese by this much confidence (0...1) to win. To be tuned from the log.
    static let englishMargin = 0.05

    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    var onIgnored: (() -> Void)?
    var onError: ((String) -> Void)?

    private let sourceFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
    private let ja: RecognizerChannel
    private let en: RecognizerChannel
    private var audioSeconds = 0.0
    private var lastEnglish: (text: String, confidence: Double, end: Double)?
    private var ignoringEnglish = false

    init() {
        ja = RecognizerChannel(locale: Self.japanese, sourceFormat: sourceFormat)
        en = RecognizerChannel(locale: Self.english, sourceFormat: sourceFormat)
        ja.onResult = { [weak self] text, confidence, isFinal, end in self?.japanese(text, confidence, isFinal, end) }
        en.onResult = { [weak self] text, confidence, _, end in self?.lastEnglish = (text, confidence ?? 0, end) }
        ja.onError = { [weak self] in self?.onError?($0) }
        en.onError = { [weak self] in self?.onError?($0) }
    }

    static func prepareAssets() async {
        await RecognizerChannel.prepareAssets(japanese)
        await RecognizerChannel.prepareAssets(english)
    }

    func start() async throws {
        try await ja.start()
        try await en.start()
    }

    private func japanese(_ text: String, _ confidence: Double?, _ isFinal: Bool, _ end: Double) {
        let lag = audioSeconds - end // how far recognition trails the audio received so far
        var englishWins = false
        var englishNote = ""
        if let english = lastEnglish, !english.text.isEmpty, abs(english.end - end) < 3 {
            englishWins = english.confidence > (confidence ?? 0) + Self.englishMargin
            englishNote = String(format: " | en \"%@\" %.2f", english.text, english.confidence)
        }
        if isFinal {
            appLog(String(format: "ja final: lag %.1f s, conf %.2f%@%@", lag, confidence ?? -1, englishNote, englishWins ? " → English, ignored" : ""))
        }
        if englishWins {
            if !ignoringEnglish || isFinal { onIgnored?() }
            ignoringEnglish = !isFinal
            return
        }
        ignoringEnglish = false
        if isFinal { onFinal?(text) } else { onPartial?(text) }
    }

    /// Raw s16le mono 16 kHz bytes, as the glasses app sends them.
    func push(pcm16 data: Data) {
        guard data.count >= 2 else { return }
        let frames = AVAudioFrameCount(data.count / 2)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frames),
              let channel = buffer.int16ChannelData else { return }
        buffer.frameLength = frames
        data.withUnsafeBytes { raw in
            if let base = raw.baseAddress { memcpy(channel[0], base, Int(frames) * 2) }
        }
        audioSeconds += Double(frames) / 16000
        ja.push(buffer)
        en.push(buffer)
    }

    func stop() {
        ja.stop()
        en.stop()
    }
}
