import Foundation
import Network

/// A WebSocket server on 127.0.0.1 that the glasses app (a web page inside the Even app) talks to.
/// Same protocol as the PC server in the main project:
///   client → server: binary frames of 16 kHz mono s16le PCM
///   server → client: JSON text frames: hello, partial {ja}, final {id, ja}, translation {id, en, ms}
final class BridgeServer {
    static let port: UInt16 = 5175

    /// For appLog: every log line is also sent to the glasses app, which forwards it to the PC log.
    static var shared: BridgeServer?

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "bridge.server")
    private var sessions: [ObjectIdentifier: Session] = [:]
    private var recentLogs: [String] = [] // replayed to a glasses app that connects later
    private var connections = 0

    func log(_ message: String) {
        queue.async {
            self.recentLogs.append(message)
            if self.recentLogs.count > 60 { self.recentLogs.removeFirst(self.recentLogs.count - 60) }
            for session in self.sessions.values { session.sendLog(message) }
        }
    }

    func start() throws {
        Self.shared = self
        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
        parameters.requiredInterfaceType = .loopback // only this phone can connect
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: Self.port)!)
        listener.stateUpdateHandler = { state in appLog("server: \(state)") }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        self.listener = listener
    }

    private func accept(_ connection: NWConnection) {
        connections += 1
        let session = Session(connection: connection, queue: queue, number: connections)
        let id = ObjectIdentifier(session)
        sessions[id] = session
        session.replay = recentLogs
        session.onClose = { [weak self] in self?.queue.async { self?.sessions[id] = nil } }
        session.start()
    }
}

/// One connection from the glasses app: its own recognizer, numbering and translator.
private final class Session {
    let connection: NWConnection
    let queue: DispatchQueue
    let number: Int // which connection this is, to tell sentence numbers apart on screen
    var onClose: (() -> Void)?
    var replay: [String] = []

    func sendLog(_ message: String) {
        send(["type": "log", "message": message])
    }

    private let recognizer = Recognizer()
    private let toEnglish = Translator(from: "ja", to: "en")
    private let toJapanese = Translator(from: "en", to: "ja")
    private var nextId = 1
    private var nextMineId = 1
    private var bytes = 0
    private var closed = false
    private var partialTask: Task<Void, Never>?
    private var lastTranslated: (ja: String, en: String)?

    init(connection: NWConnection, queue: DispatchQueue, number: Int) {
        self.connection = connection
        self.queue = queue
        self.number = number
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: appLog("glasses app connected")
            case .failed, .cancelled: self?.close()
            default: break
            }
        }
        connection.start(queue: queue)
        send(["type": "hello", "speech": "apple-speechanalyzer", "translator": "apple-translation"])
        for line in replay { sendLog(line) }

        recognizer.onPartial = { [weak self] text in self?.partial(text) }
        recognizer.onFinal = { [weak self] text in self?.sentence(text) }
        recognizer.onEnglishFinal = { [weak self] text in self?.mine(text) }
        recognizer.onIgnored = { [weak self] in
            self?.partialTask?.cancel()
            self?.send(["type": "ignored"])
        }
        recognizer.onError = { [weak self] message in
            appLog(message)
            self?.send(["type": "error", "message": message])
        }
        Task {
            do { try await recognizer.start() } catch {
                appLog("recognizer failed to start: \(error)")
                send(["type": "error", "message": "recognizer failed to start: \(error)"])
            }
        }
        receive()
    }

    /// The sentence in progress: shown at once, and translated shortly after it stops changing, so
    /// the English follows the speech instead of waiting for Apple to finalize the sentence.
    private func partial(_ japanese: String) {
        send(["type": "partial", "ja": japanese])
        partialTask?.cancel()
        partialTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let self, !Task.isCancelled else { return }
            guard let english = try? await self.toEnglish.translate(japanese), !Task.isCancelled else { return }
            self.lastTranslated = (japanese, english)
            self.send(["type": "partial", "ja": japanese, "en": english])
        }
    }

    private func sentence(_ japanese: String) {
        partialTask?.cancel()
        let id = nextId
        nextId += 1
        appLog("JA #\(id): \(japanese)")
        let key = "\(number)-\(id)"
        Task { @MainActor in AppModel.shared.heard(key: key, japanese: japanese) }
        send(["type": "final", "id": id, "ja": japanese])
        Task {
            let started = Date()
            do {
                // Often the same text was just translated as a partial.
                let english = try await (lastTranslated?.ja == japanese ? lastTranslated!.en : toEnglish.translate(japanese))
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                appLog("EN #\(id): \(english) (\(ms) ms)")
                Task { @MainActor in AppModel.shared.translated(key: key, english: english) }
                send(["type": "translation", "id": id, "en": english, "ms": ms])
            } catch {
                appLog("translation failed: \(error)")
                Task { @MainActor in AppModel.shared.translated(key: key, english: "(translation failed)") }
                send(["type": "translation", "id": id, "en": "", "error": "\(error)"])
            }
        }
    }

    /// English the glasses wearer said: translated to Japanese and shown on this phone for the other
    /// person to read. The glasses app is not told; it only shows what the other person says.
    private func mine(_ english: String) {
        let id = nextMineId
        nextMineId += 1
        let key = "\(number)-m\(id)"
        appLog("EN (you) #\(id): \(english)")
        Task { @MainActor in AppModel.shared.said(key: key, english: english) }
        Task {
            let started = Date()
            do {
                let japanese = try await toJapanese.translate(english)
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                appLog("JA (for them) #\(id): \(japanese) (\(ms) ms)")
                Task { @MainActor in AppModel.shared.translatedToJapanese(key: key, japanese: japanese) }
            } catch {
                appLog("translation to Japanese failed: \(error)")
                Task { @MainActor in AppModel.shared.translatedToJapanese(key: key, japanese: "(translation failed)") }
            }
        }
    }

    private func receive() {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty,
               let meta = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata,
               meta.opcode == .binary {
                self.bytes += data.count
                self.recognizer.push(pcm16: data)
            }
            if error == nil { self.receive() } else { self.close() }
        }
    }

    private func send(_ object: [String: Any]) {
        guard !closed, let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
    }

    private func close() {
        guard !closed else { return }
        closed = true
        appLog("glasses app disconnected after \(bytes / 32000) s of audio")
        recognizer.stop()
        connection.cancel()
        onClose?()
    }
}
