import Foundation
import Translation

/// Apple's on-device translation between two languages (for example "ja" → "en" for what the other
/// person says, "en" → "ja" for what the wearer says). The languages have to be installed first
/// (the "Download" button in Settings); this runs without any screen of its own.
final class Translator {
    private let session: TranslationSession

    init(from source: String, to target: String) {
        session = TranslationSession(
            installedSource: Locale.Language(identifier: source),
            target: Locale.Language(identifier: target))
    }

    func translate(_ text: String) async throws -> String {
        let response = try await session.translate(text)
        return response.targetText
    }
}
