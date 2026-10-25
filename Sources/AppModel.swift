import Foundation
import SwiftUI
import UIKit

/// Who said a sentence. The glasses wearer speaks English; the other person speaks Japanese.
enum Speaker {
    case them // Japanese heard through the glasses, translated to English
    case me // English the wearer spoke, translated to Japanese for the other person to read here
}

/// One finished sentence in both languages: the one that was spoken, and its translation once that
/// has arrived.
struct Sentence: Identifiable, Equatable {
    let id: String // "<connection>-<number>", unique across glasses-app connections
    let speaker: Speaker
    var japanese: String?
    var english: String?
    let time: Date
}

/// What the screens show, and the one place the pieces are started from.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    private enum Keys {
        static let audioKeepAlive = "audioKeepAlive"
        static let locationKeepAlive = "locationKeepAlive"
        static let keepScreenOn = "keepScreenOn"
        static let oldUseLanguageModel = ContextTranslator.defaultsKey // before the engine choice existed
    }

    @Published var lines: [String] = []
    @Published var sentences: [Sentence] = []
    @Published var status = "starting…"

    // Remembered between launches.
    @Published var audioKeepAlive: Bool {
        didSet {
            UserDefaults.standard.set(audioKeepAlive, forKey: Keys.audioKeepAlive)
            applyKeepAlive()
        }
    }
    @Published var locationKeepAlive: Bool {
        didSet {
            UserDefaults.standard.set(locationKeepAlive, forKey: Keys.locationKeepAlive)
            applyKeepAlive()
        }
    }
    /// Keeps the phone's screen from dimming, since the other person reads it during the conversation.
    @Published var keepScreenOn: Bool {
        didSet {
            UserDefaults.standard.set(keepScreenOn, forKey: Keys.keepScreenOn)
            UIApplication.shared.isIdleTimerDisabled = keepScreenOn
        }
    }

    /// What improves on Apple Translation's quick result (see TranslationEngine).
    @Published var engine: TranslationEngine {
        didSet {
            UserDefaults.standard.set(engine.rawValue, forKey: TranslationEngine.defaultsKey)
            applyEngine()
        }
    }

    /// Run the local models on the GPU (Metal) instead of the CPU.
    @Published var localModelGPU: Bool {
        didSet {
            UserDefaults.standard.set(localModelGPU, forKey: LocalTranslator.gpuKey)
            applyEngine()
        }
    }

    private let server = BridgeServer()
    private let keepAlive = KeepAlive()
    private var started = false

    private init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [Keys.audioKeepAlive: true, Keys.locationKeepAlive: false, Keys.keepScreenOn: true, LocalTranslator.gpuKey: true])
        audioKeepAlive = defaults.bool(forKey: Keys.audioKeepAlive)
        locationKeepAlive = defaults.bool(forKey: Keys.locationKeepAlive)
        keepScreenOn = defaults.bool(forKey: Keys.keepScreenOn)
        localModelGPU = defaults.bool(forKey: LocalTranslator.gpuKey)
        if let saved = defaults.string(forKey: TranslationEngine.defaultsKey), let known = TranslationEngine(rawValue: saved) {
            engine = known
        } else {
            // Carry over the old "language model" switch.
            engine = defaults.bool(forKey: Keys.oldUseLanguageModel) ? .appleLanguageModel : .appleTranslation
        }
    }

    func log(_ message: String) {
        let stamp = Self.formatter.string(from: Date())
        lines.insert("\(stamp) \(message)", at: 0)
        if lines.count > 200 { lines.removeLast(lines.count - 200) }
    }

    private func add(_ sentence: Sentence) {
        sentences.append(sentence)
        if sentences.count > 500 { sentences.removeFirst(sentences.count - 500) }
    }

    /// Japanese the other person said (before its English translation).
    func heard(key: String, japanese: String) {
        add(Sentence(id: key, speaker: .them, japanese: japanese, english: nil, time: Date()))
    }

    func translated(key: String, english: String) {
        if let index = sentences.lastIndex(where: { $0.id == key }) { sentences[index].english = english }
    }

    /// English the wearer said (before its Japanese translation).
    func said(key: String, english: String) {
        add(Sentence(id: key, speaker: .me, japanese: nil, english: english, time: Date()))
    }

    func translatedToJapanese(key: String, japanese: String) {
        if let index = sentences.lastIndex(where: { $0.id == key }) { sentences[index].japanese = japanese }
    }

    func clearSentences() {
        sentences.removeAll()
    }

    func start() {
        guard !started else { return }
        started = true
        UIApplication.shared.isIdleTimerDisabled = keepScreenOn
        do {
            try server.start()
            status = "listening on 127.0.0.1:\(BridgeServer.port)"
        } catch {
            status = "server failed: \(error.localizedDescription)"
            log("server failed: \(error)")
        }
        applyKeepAlive()
        applyEngine()
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { _ in
            appLog("memory warning: unloading the local model")
            LocalTranslator.shared.unload()
        }
        Task { await Recognizer.prepareAssets() }
    }

    /// A model file finished downloading: load it now if it is the chosen engine.
    func modelDownloaded(_ model: LocalModel) {
        if engine.localModel == model { applyEngine() }
    }

    /// Loads the chosen local model ahead of the first sentence, or frees the memory if none is chosen.
    private func applyEngine() {
        guard started else { return }
        if let model = engine.localModel {
            LocalTranslator.shared.preload(model)
        } else {
            LocalTranslator.shared.unload()
        }
    }

    private func applyKeepAlive() {
        guard started else { return }
        keepAlive.setAudio(audioKeepAlive)
        keepAlive.setLocation(locationKeepAlive)
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

/// Logging from any thread.
func appLog(_ message: String) {
    BridgeServer.shared?.log(message)
    Task { @MainActor in AppModel.shared.log(message) }
}
