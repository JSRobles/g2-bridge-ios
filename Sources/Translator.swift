import Foundation
import Translation

/// Apple's on-device Japanese → English translation. The languages have to be installed first
/// (the "Download" button in the app); this runs without any screen of its own.
final class Translator {
    private let session = TranslationSession(
        installedSource: Locale.Language(identifier: "ja"),
        target: Locale.Language(identifier: "en"))

    func translate(_ japanese: String) async throws -> String {
        let response = try await session.translate(japanese)
        return response.targetText
    }
}
