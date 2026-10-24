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
    /// Real Japanese scored 0.96-0.98 in the first log; Japanese results made from English speech 0.35-0.57.
    /// A result below this isn't shown, even before the English recognizer has caught up.
    static let minConfidence = 0.6
    /// English the wearer spoke: in the logs the English recognizer scored 0.79-0.97 on real English and
    /// 0.17-0.52 on Japanese speech, and the Japanese recognizer 0.97+ on Japanese and 0.35-0.64 on English.
    static let minEnglishConfidence = 0.65

    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    var onIgnored: (() -> Void)?
    /// A finished English sentence that the wearer spoke (the other person speaks Japanese).
    var onEnglishFinal: ((String) -> Void)?
    var onError: ((String) -> Void)?

    private let sourceFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
    private let ja: RecognizerChannel
    private let en: RecognizerChannel
    private var audioSeconds = 0.0
    private var lastEnglish: (text: String, confidence: Double, end: Double)?
    private var lastJapaneseFinal: (confidence: Double, end: Double)?
    private var ignoringEnglish = false
    private var lastPartialLog = Date.distantPast

    init() {
        ja = RecognizerChannel(locale: Self.japanese, sourceFormat: sourceFormat)
        en = RecognizerChannel(locale: Self.english, sourceFormat: sourceFormat)
        ja.onResult = { [weak self] text, confidence, isFinal, end in self?.japanese(text, confidence, isFinal, end) }
        en.onResult = { [weak self] text, confidence, isFinal, end in self?.english(text, confidence, isFinal, end) }
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

    /// A result from the English recognizer. Finals count as the wearer's own speech when it is confident
    /// and the Japanese recognizer wasn't confidently hearing Japanese at the same moment.
    private func english(_ text: String, _ confidence: Double?, _ isFinal: Bool, _ end: Double) {
        lastEnglish = (text, confidence ?? 0, end)
        guard isFinal else { return }
        let confidence = confidence ?? 0
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var verdict = ""
        if !trimmed.contains(where: { $0.isLetter }) {
            verdict = "no words"
        } else if confidence < Self.minEnglishConfidence {
            verdict = "low confidence"
        } else if let japanese = lastJapaneseFinal, abs(japanese.end - end) < 3, japanese.confidence >= 0.8 {
            verdict = "Japanese heard confidently"
        }
        // Everything the English recognizer commits goes to the log, with what became of it.
        appLog(String(format: "en final \"%@\": conf %.2f%@", text, confidence, verdict.isEmpty ? " → you" : " → not yours (\(verdict))"))
        if verdict.isEmpty { onEnglishFinal?(trimmed) }
    }

    /// Apple's Japanese model writes English speech as Latin-letter gibberish ("Tstor Work Aps"), so a
    /// result that is mostly Latin letters isn't Japanese.
    static func mostlyLatin(_ text: String) -> Bool {
        var latin = 0
        var other = 0
        for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
            if scalar.value < 0x250 { latin += 1 } else { other += 1 }
        }
        return latin + other >= 3 && Double(latin) / Double(latin + other) >= 0.6
    }

    /// Volatile (partial) results carry no confidence, so a partial can't be judged by it. English
    /// speech heard as Japanese is mostly katakana ("アイムテスト…"), which real Japanese rarely is.
    static func mostlyKatakana(_ text: String) -> Bool {
        var katakana = 0
        var letters = 0
        for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
            letters += 1
            if (0x30A0...0x30FF).contains(scalar.value) { katakana += 1 }
        }
        return letters >= 3 && Double(katakana) / Double(letters) >= 0.8
    }

    private func japanese(_ text: String, _ confidence: Double?, _ isFinal: Bool, _ end: Double) {
        let lag = audioSeconds - end // how far recognition trails the audio received so far
        var reason = ""
        var englishNote = ""
        if !text.unicodeScalars.contains(where: { $0.properties.isAlphabetic }) { reason = "no words" }
        if reason.isEmpty, Self.mostlyLatin(text) { reason = "Latin letters" }
        if reason.isEmpty, let confidence, confidence < Self.minConfidence { reason = "low confidence" }
        if reason.isEmpty, !isFinal, Self.mostlyKatakana(text) { reason = "katakana only" }
        if let english = lastEnglish, !english.text.isEmpty, abs(english.end - end) < 3 {
            if reason.isEmpty, english.confidence > (confidence ?? 0) + Self.englishMargin { reason = "English more confident" }
            englishNote = String(format: " | en \"%@\" %.2f", english.text, english.confidence)
        }
        let englishWins = !reason.isEmpty
        if isFinal { lastJapaneseFinal = (confidence ?? 0, end) }
        if !isFinal, Date().timeIntervalSince(lastPartialLog) > 0.5 {
            lastPartialLog = Date()
            appLog(String(format: "ja partial conf %.2f%@%@", confidence ?? -1, englishNote, englishWins ? " → hidden (\(reason))" : ""))
        }
        if isFinal {
            appLog(String(format: "ja final \"%@\": lag %.1f s, conf %.2f%@%@", text, lag, confidence ?? -1, englishNote, englishWins ? " → ignored (\(reason))" : ""))
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
