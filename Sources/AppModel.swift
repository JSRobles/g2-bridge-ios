import Foundation
import SwiftUI

/// What the screen shows, and the one place the pieces are started from.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var lines: [String] = []
    @Published var status = "starting…"
    @Published var clients = 0
    @Published var audioKeepAlive = true {
        didSet { applyKeepAlive() }
    }
    @Published var locationKeepAlive = false {
        didSet { applyKeepAlive() }
    }

    private let server = BridgeServer()
    private let keepAlive = KeepAlive()
    private var started = false

    func log(_ message: String) {
        let stamp = Self.formatter.string(from: Date())
        lines.insert("\(stamp) \(message)", at: 0)
        if lines.count > 200 { lines.removeLast(lines.count - 200) }
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
    Task { @MainActor in AppModel.shared.log(message) }
}
