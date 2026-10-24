import Foundation
import SwiftUI

/// One finished sentence: what was heard, and its translation once that has arrived.
struct Sentence: Identifiable, Equatable {
    let id: String // "<connection>-<number>", unique across glasses-app connections
    let japanese: String
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

    private let server = BridgeServer()
    private let keepAlive = KeepAlive()
    private var started = false

    private init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [Keys.audioKeepAlive: true, Keys.locationKeepAlive: false])
        audioKeepAlive = defaults.bool(forKey: Keys.audioKeepAlive)
        locationKeepAlive = defaults.bool(forKey: Keys.locationKeepAlive)
    }

    func log(_ message: String) {
        let stamp = Self.formatter.string(from: Date())
        lines.insert("\(stamp) \(message)", at: 0)
        if lines.count > 200 { lines.removeLast(lines.count - 200) }
    }

    /// A sentence the recognizer has finished (before its translation).
    func heard(key: String, japanese: String) {
        sentences.append(Sentence(id: key, japanese: japanese, english: nil, time: Date()))
        if sentences.count > 500 { sentences.removeFirst(sentences.count - 500) }
    }

    func translated(key: String, english: String) {
        if let index = sentences.lastIndex(where: { $0.id == key }) { sentences[index].english = english }
    }

    func clearSentences() {
        sentences.removeAll()
    }

    func start() {
        guard !started else { return }
        started = true
        do {
            try server.start()
            status = "listening on 127.0.0.1:\(BridgeServer.port)"
        } catch {
            status = "server failed: \(error.localizedDescription)"
            log("server failed: \(error)")
        }
        applyKeepAlive()
        Task { await Recognizer.prepareAssets() }
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
