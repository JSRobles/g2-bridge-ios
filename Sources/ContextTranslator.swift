import Foundation
import FoundationModels

/// Translation by Apple's on-device language model (iOS 26+, Apple Intelligence devices), which can be
/// given the conversation so far. Apple's Translation framework sees one sentence at a time, so it
/// can't tell who a dropped subject refers to; this can. It is slower, so the app shows Translation's
/// quick result first and replaces it when this one arrives.
final class ContextTranslator {
    static let defaultsKey = "useLanguageModel"

    static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    static var statusText: String {
        switch SystemLanguageModel.default.availability {
        case .available:
            return "available"
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return "this device isn't eligible"
            case .appleIntelligenceNotEnabled: return "Apple Intelligence is turned off"
            case .modelNotReady: return "the model is still downloading"
            @unknown default: return "unavailable"
            }
        }
    }

    private static let instructions = """
    You are a live interpreter for a face-to-face conversation between a Japanese speaker ("Them") and an English speaker ("You"). \
    Translate the last line faithfully and concisely. Keep every subject the speaker states. Japanese often drops the subject: \
    then use the conversation so far; if that does not settle it, assume the speaker means themselves ("I") in statements and \
    the listener ("you") in questions, and never guess "he" or "she" unless someone is named. The text comes from speech \
    recognition and may contain small errors (names especially): read it as the speaker most likely meant. \
    Reply with the translation only, no notes or quotation marks.
    """

    /// `context`: the earlier lines, oldest first, like "Them (Japanese): ..." / "You (English): ...".
    func translate(_ text: String, from source: String, to target: String, context: [String]) async throws -> String {
        let session = LanguageModelSession(instructions: Self.instructions)
        var prompt = ""
        if !context.isEmpty { prompt += "Conversation so far:\n" + context.joined(separator: "\n") + "\n\n" }
        prompt += "Translate this \(source) line into \(target)"
        prompt += target == "Japanese" ? " (natural, polite Japanese, です・ます form)" : ""
        prompt += " and reply with only the \(target) translation:\n\(text)"
        let response = try await session.respond(to: prompt, options: GenerationOptions(sampling: .greedy))
        return Self.clean(response.content)
    }

    private static func clean(_ reply: String) -> String {
        var text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["English:", "Japanese:", "EN:", "JA:"] where text.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if text.count >= 2, let first = text.first, let last = text.last,
           (first == "\"" && last == "\"") || (first == "「" && last == "」") || (first == "“" && last == "”") {
            text = String(text.dropFirst().dropLast())
        }
        return text
    }
}
