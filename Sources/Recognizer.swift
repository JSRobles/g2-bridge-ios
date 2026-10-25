import AVFoundation
import Foundation
import Speech

/// A word or phrase of a result with the stretch of audio it was heard in (seconds; -1 if Apple gave no time).
struct Piece {
    let text: String
    let start: Double
    let end: Double
    let confidence: Double?

    var hasTime: Bool { start >= 0 && end > start }
    var duration: Double { max(0, end - start) }
    var letters: [Unicode.Scalar] { text.unicodeScalars.filter { $0.properties.isAlphabetic } }

    /// Kana or kanji: the script a Japanese result is written in. English speech comes out as Latin letters.
    var isJapaneseScript: Bool {
        letters.contains { (0x3040...0x30FF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value) }
    }

    var isLatin: Bool { letters.filter { $0.value < 0x250 }.count >= 2 }

    func overlap(_ other: Piece) -> Double {
        guard hasTime, other.hasTime else { return 0 }
        return max(0, min(end, other.end) - max(start, other.start))
    }
}

/// One language's recognizer: Apple's on-device SpeechAnalyzer + SpeechTranscriber (iOS 26+) fed
/// with 16 kHz mono 16-bit PCM. Volatile results are the phrase in progress; final results are
/// committed text. Each result carries Apple's confidence for its words.
final class RecognizerChannel {
    let locale: Locale
    /// text, mean confidence (0...1) if known, isFinal, where in the audio the result ends (seconds), its words with their times
    var onResult: ((String, Double?, Bool, Double, [Piece]) -> Void)?
    var onError: ((String) -> Void)?

    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private let sourceFormat: AVAudioFormat

    // Apple commits (finalizes) a sentence when it decides to, which on continuous speech means one
    // block of 10-20 s: slow for the glasses and hard on the translator. So a sentence is finalized by
    // hand once it has run `minSegment` seconds and the speaker pauses, and at `maxSegment` regardless.
    static let minSegment = 5.0
    static let maxSegment = 10.0
    private var audioSeconds = 0.0
    private var pendingSince = 0.0 // when the first result of the sentence in progress came in
    private var hasPending = false // a result has come in since the last final
    private var finalizing = false

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
                    if result.isFinal {
                        self?.hasPending = false
                        self?.finalizing = false
                    } else if !text.isEmpty {
                        if self?.hasPending == false { self?.pendingSince = self?.audioSeconds ?? 0 }
                        self?.hasPending = true
                    }
                    if text.isEmpty { continue }
                    self?.onResult?(text, Self.meanConfidence(result.text), result.isFinal, result.range.end.seconds, Self.pieces(result.text))
                }
            } catch {
                self?.onError?("\(self?.locale.identifier ?? "?") recognition stopped: \(error)")
            }
        }
        try await analyzer.start(inputSequence: stream)
    }

    /// The words of a result with the audio time each was heard in.
    private static func pieces(_ text: AttributedString) -> [Piece] {
        var out: [Piece] = []
        for (time, confidence, range) in text.runs[\.audioTimeRange, \.transcriptionConfidence] {
            let piece = String(text[range].characters)
            if let time {
                out.append(Piece(text: piece, start: time.start.seconds, end: time.end.seconds, confidence: confidence))
            } else {
                out.append(Piece(text: piece, start: -1, end: -1, confidence: confidence))
            }
        }
        return out
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

    /// Called with each chunk of audio: the time it ends at, and how long it has been quiet.
    func noteAudio(seconds: Double, quietFor: Double) {
        audioSeconds = seconds
        guard hasPending, !finalizing, let analyzer else { return }
        let running = seconds - pendingSince
        let atPause = running >= Self.minSegment && quietFor >= Recognizer.pauseSeconds
        guard atPause || running >= Self.maxSegment else { return }
        finalizing = true
        let locale = self.locale.identifier
        appLog(String(format: "%@: finalizing after %.1f s (%@)", locale, running, atPause ? "pause" : "limit"))
        Task { [weak self] in
            do { try await analyzer.finalize(through: nil) } catch { self?.finalizing = false }
        }
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
    /// Quiet is below this level (RMS, 0...1) for at least `pauseSeconds`; speech through the glasses is 0.05+.
    static let silenceLevel = 0.012
    static let pauseSeconds = 0.2

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
    private var ignoringEnglish = false
    // Everything the two recognizers committed in the last minute, word by word, to decide who heard each stretch of
    // audio. All of this runs on `decide` (one thing at a time); a final waits `deferSeconds` for the other recognizer's.
    private let decide = DispatchQueue(label: "recognizer.decide")
    static let deferSeconds = 0.7
    private var englishPieces: [Piece] = []
    private var japanesePieces: [Piece] = []
    private var lastPartialLog = Date.distantPast
    private var quietFor = 0.0

    init() {
        ja = RecognizerChannel(locale: Self.japanese, sourceFormat: sourceFormat)
        en = RecognizerChannel(locale: Self.english, sourceFormat: sourceFormat)
        ja.onResult = { [weak self] text, confidence, isFinal, end, pieces in
            self?.decide.async { self?.japanese(text, confidence, isFinal, end, pieces) }
        }
        en.onResult = { [weak self] text, confidence, isFinal, end, pieces in
            self?.decide.async { self?.english(text, confidence, isFinal, end, pieces) }
        }
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

    /// A result from the English recognizer. A final counts as the wearer's own speech word by word: words spoken in a
    /// stretch where the Japanese recognizer heard Japanese at least as well are not English.
    private func english(_ text: String, _ confidence: Double?, _ isFinal: Bool, _ end: Double, _ pieces: [Piece]) {
        lastEnglish = (text, confidence ?? 0, end)
        guard isFinal else { return }
        remember(pieces, in: &englishPieces)
        decide.asyncAfter(deadline: .now() + Self.deferSeconds) { [weak self] in self?.judgeEnglish(text, confidence ?? 0, pieces) }
    }

    private func judgeEnglish(_ text: String, _ confidence: Double, _ pieces: [Piece]) {
        var kept: [Piece] = []
        var dropped: [String] = []
        if pieces.count > 1, pieces.contains(where: { $0.hasTime }) {
            for piece in pieces {
                if piece.isLatin, let japanese = japanesePieces.first(where: { Self.hearsJapanese($0, over: piece) }) {
                    dropped.append("\(piece.text.trimmingCharacters(in: .whitespaces)) [Japanese heard \(String(format: "%.2f", japanese.confidence ?? 0))]")
                } else {
                    kept.append(piece)
                }
            }
        } else {
            kept = pieces.isEmpty ? [Piece(text: text, start: -1, end: -1, confidence: confidence)] : pieces
        }
        let keptText = kept.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        let keptConfidence = Self.meanConfidence(kept) ?? confidence
        var verdict = ""
        if keptText.unicodeScalars.filter({ $0.properties.isAlphabetic }).count < 2 {
            verdict = "no words"
        } else if keptConfidence < Self.minEnglishConfidence {
            verdict = "low confidence"
        }
        // Everything the English recognizer commits goes to the log, with what became of it.
        appLog(String(format: "en final \"%@\": conf %.2f%@%@", keptText, keptConfidence, verdict.isEmpty ? " → you" : " → not yours (\(verdict))",
                      dropped.isEmpty ? "" : " | dropped: " + dropped.joined(separator: ", ")))
        if verdict.isEmpty { onEnglishFinal?(keptText) }
    }

    /// The Japanese piece `ja` holds this stretch against the English piece `en`: it is Japanese script that Apple is fairly
    /// sure of, and the English recognizer is not clearly more sure of the same audio.
    private static func hearsJapanese(_ ja: Piece, over en: Piece) -> Bool {
        guard ja.isJapaneseScript, (ja.confidence ?? 1) >= minConfidence, ja.overlap(en) >= 0.5 * en.duration else { return false }
        return !((en.confidence ?? 0) > (ja.confidence ?? 1) + englishMargin)
    }

    /// The English piece `en` holds this stretch against the Japanese piece `ja`.
    private static func hearsEnglish(_ en: Piece, over ja: Piece) -> Bool {
        guard en.isLatin, (en.confidence ?? 0) >= minEnglishConfidence, en.overlap(ja) >= 0.5 * ja.duration else { return false }
        return (en.confidence ?? 0) > (ja.confidence ?? 1) + englishMargin
    }

    private func remember(_ pieces: [Piece], in store: inout [Piece]) {
        store.append(contentsOf: pieces.filter { $0.hasTime && !$0.letters.isEmpty })
        store.removeAll { $0.end < audioSeconds - 60 }
    }

    private static func meanConfidence(_ pieces: [Piece]) -> Double? {
        var total = 0.0
        var weight = 0.0
        for piece in pieces {
            guard let confidence = piece.confidence else { continue }
            let length = Double(max(1, piece.letters.count))
            total += confidence * length
            weight += length
        }
        return weight > 0 ? total / weight : nil
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

    private func japanese(_ text: String, _ confidence: Double?, _ isFinal: Bool, _ end: Double, _ pieces: [Piece]) {
        if isFinal {
            remember(pieces, in: &japanesePieces)
            decide.asyncAfter(deadline: .now() + Self.deferSeconds) { [weak self] in self?.judgeJapaneseFinal(text, confidence, end, pieces) }
            return
        }
        // The sentence in progress (only the glasses app's "hearing speech" uses it): judged as a whole, as before.
        var reason = ""
        var englishNote = ""
        if !text.unicodeScalars.contains(where: { $0.properties.isAlphabetic }) { reason = "no words" }
        if reason.isEmpty, Self.mostlyLatin(text) { reason = "Latin letters" }
        if reason.isEmpty, let confidence, confidence < Self.minConfidence { reason = "low confidence" }
        if reason.isEmpty, Self.mostlyKatakana(text) { reason = "katakana only" }
        if let english = lastEnglish, !english.text.isEmpty, abs(english.end - end) < 3 {
            if reason.isEmpty, english.confidence > (confidence ?? 0) + Self.englishMargin { reason = "English more confident" }
            englishNote = String(format: " | en \"%@\" %.2f", english.text, english.confidence)
        }
        let hidden = !reason.isEmpty
        if Date().timeIntervalSince(lastPartialLog) > 0.5 {
            lastPartialLog = Date()
            appLog(String(format: "ja partial conf %.2f%@%@", confidence ?? -1, englishNote, hidden ? " → hidden (\(reason))" : ""))
        }
        if hidden {
            if !ignoringEnglish { onIgnored?() }
            ignoringEnglish = true
            return
        }
        ignoringEnglish = false
        onPartial?(text)
    }

    /// A committed Japanese result, word by word: a word stays if it is Japanese script that Apple is sure of and the
    /// English recognizer did not hear the same audio clearly better. What stays is the sentence.
    private func judgeJapaneseFinal(_ text: String, _ confidence: Double?, _ end: Double, _ pieces: [Piece]) {
        let lag = audioSeconds - end // how far recognition trails the audio received so far
        var kept: [Piece] = []
        var dropped: [String] = []
        if pieces.count > 1, pieces.contains(where: { $0.hasTime }) {
            for piece in pieces {
                guard !piece.letters.isEmpty else {
                    kept.append(piece) // punctuation and spaces go with their neighbours
                    continue
                }
                var reason = ""
                if !piece.isJapaneseScript {
                    reason = "not Japanese"
                } else if let c = piece.confidence, c < Self.minConfidence {
                    reason = "low confidence"
                } else if let english = englishPieces.first(where: { Self.hearsEnglish($0, over: piece) }) {
                    reason = String(format: "English heard %.2f", english.confidence ?? 0)
                }
                if reason.isEmpty { kept.append(piece) } else { dropped.append("\(piece.text.trimmingCharacters(in: .whitespaces)) [\(reason)]") }
            }
        } else {
            // No word times from Apple: the whole result, as before.
            var reason = ""
            if !text.unicodeScalars.contains(where: { $0.properties.isAlphabetic }) { reason = "no words" }
            if reason.isEmpty, Self.mostlyLatin(text) { reason = "Latin letters" }
            if reason.isEmpty, let confidence, confidence < Self.minConfidence { reason = "low confidence" }
            if let english = lastEnglish, reason.isEmpty, abs(english.end - end) < 3, english.confidence > (confidence ?? 0) + Self.englishMargin {
                reason = "English more confident"
            }
            if reason.isEmpty { kept = [Piece(text: text, start: -1, end: -1, confidence: confidence)] } else { dropped.append("[\(reason)]") }
        }
        let keptText = kept.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        let japaneseLetters = keptText.unicodeScalars.filter { (0x3040...0x30FF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value) }.count
        let accepted = japaneseLetters >= 2
        appLog(String(format: "ja final \"%@\": lag %.1f s, conf %.2f%@%@", keptText, lag, Self.meanConfidence(kept) ?? confidence ?? -1,
                      dropped.isEmpty ? "" : " | dropped: " + dropped.joined(separator: ", "), accepted ? "" : " → ignored"))
        ignoringEnglish = false
        if accepted { onFinal?(keptText) } else { onIgnored?() }
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
        var sum = 0.0
        for i in 0..<Int(frames) {
            let sample = Double(channel[0][i]) / 32768
            sum += sample * sample
        }
        let chunkSeconds = Double(frames) / 16000
        audioSeconds += chunkSeconds
        quietFor = (sum / Double(frames)).squareRoot() < Self.silenceLevel ? quietFor + chunkSeconds : 0
        ja.noteAudio(seconds: audioSeconds, quietFor: quietFor)
        en.noteAudio(seconds: audioSeconds, quietFor: quietFor)
        ja.push(buffer)
        en.push(buffer)
    }

    func stop() {
        ja.stop()
        en.stop()
    }
}
