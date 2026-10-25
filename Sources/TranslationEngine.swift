import Foundation

/// A translation model that runs inside this app with llama.cpp. The file is downloaded once (from
/// Hugging Face) and used offline after that.
enum LocalModel: String, CaseIterable, Identifiable {
    case lfm2
    case hymt2

    var id: String { rawValue }

    var fileName: String {
        switch self {
        case .lfm2: return "LFM2-350M-ENJP-MT-Q8_0.gguf"
        case .hymt2: return "Hy-MT2-1.8B-Q4_K_M.gguf"
        }
    }

    var downloadURL: URL {
        switch self {
        case .lfm2: return URL(string: "https://huggingface.co/LiquidAI/LFM2-350M-ENJP-MT-GGUF/resolve/main/LFM2-350M-ENJP-MT-Q8_0.gguf")!
        case .hymt2: return URL(string: "https://huggingface.co/tencent/Hy-MT2-1.8B-GGUF/resolve/main/Hy-MT2-1.8B-Q4_K_M.gguf")!
        }
    }

    /// Exact size of the file on Hugging Face, to catch a download that stopped halfway.
    var bytes: Int64 {
        switch self {
        case .lfm2: return 379_215_648
        case .hymt2: return 1_133_080_448
        }
    }

    var name: String {
        switch self {
        case .lfm2: return "LFM2-350M-ENJP-MT"
        case .hymt2: return "Hy-MT2-1.8B"
        }
    }

    var sizeText: String { String(format: "%.2f GB", Double(bytes) / 1e9) }
}

/// What translates the sentences. Apple Translation always answers first (it is fast); the other
/// engines then replace its result when theirs arrives, so every sentence has both in the log.
enum TranslationEngine: String, CaseIterable, Identifiable {
    case appleTranslation
    case appleLanguageModel
    case lfm2
    case hymt2

    static let defaultsKey = "translationEngine"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appleTranslation: return "Apple Translation"
        case .appleLanguageModel: return "Apple language model (experimental)"
        case .lfm2: return "LFM2-350M (on this phone)"
        case .hymt2: return "Hy-MT2-1.8B (on this phone)"
        }
    }

    var localModel: LocalModel? {
        switch self {
        case .lfm2: return .lfm2
        case .hymt2: return .hymt2
        default: return nil
        }
    }

    /// The saved choice, readable from any thread.
    static var current: TranslationEngine {
        TranslationEngine(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .appleTranslation
    }
}
