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
    // The last lines of the conversation, both speakers, for the language model.
    private let contextTranslator = ContextTranslator()
    private let contextLock = NSLock()
    private var conversation: [String] = []

    private func contextLines() -> [String] {
        contextLock.lock()
        defer { contextLock.unlock() }
        return conversation
    }

    private func remember(_ line: String) {
        contextLock.lock()
        conversation.append(line)
        if conversation.count > 6 { conversation.removeFirst(conversation.count - 6) }
        contextLock.unlock()
    }

    // The line each speaker said just before, for the local models (older than this, it is another topic).
    private var lastThem: (text: String, time: Date)?
    private var lastMine: (text: String, time: Date)?
    private static let previousLineMaxAge: TimeInterval = 30

    /// The line this speaker said before `new`, if recent; `new` becomes the previous line.
    private func swapPrevious(them: Bool, new: String) -> String? {
        contextLock.lock()
        defer { contextLock.unlock() }
        let old = them ? lastThem : lastMine
        if them { lastThem = (new, Date()) } else { lastMine = (new, Date()) }
        guard let old, Date().timeIntervalSince(old.time) <= Self.previousLineMaxAge else { return nil }
        return old.text
    }

    // The language model takes seconds per sentence. One at a time: a sentence that finishes while it
    // is busy keeps its quick translation instead of waiting in line (the line only ever grew).
    private var languageModelBusy = false

    private func claimLanguageModel() -> Bool {
        contextLock.lock()
        defer { contextLock.unlock() }
        if languageModelBusy { return false }
        languageModelBusy = true
        return true
    }

    private func releaseLanguageModel() {
        contextLock.lock()
        languageModelBusy = false
        contextLock.unlock()
    }

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
            self?.endPartial()
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
    /// the English follows the speech instead of waiting for Apple to finalize the sentence. One
    /// translation at a time, always of the newest text: the translator can't be hurried, and a queue
    /// of outdated partials delayed the sentences that mattered.
    private let partialLock = NSLock()
    private var latestPartial = ""
    private var partialRunning = false

    private func partial(_ japanese: String) {
        send(["type": "partial", "ja": japanese])
        partialLock.lock()
        latestPartial = japanese
        let start = !partialRunning
        partialRunning = true
        partialLock.unlock()
        guard start else { return } // the running one picks up the newest text when it is done
        partialTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000)
                self.partialLock.lock()
                let text = self.latestPartial
                self.partialLock.unlock()
                if let english = try? await self.toEnglish.translate(text), !Task.isCancelled {
                    self.lastTranslated = (text, english)
                    self.send(["type": "partial", "ja": text, "en": english])
                }
                self.partialLock.lock()
                let caughtUp = self.latestPartial == text
                if caughtUp { self.partialRunning = false }
                self.partialLock.unlock()
                if caughtUp { return }
            }
        }
    }

    /// The sentence ended (or was ignored): drop the partial translation in progress.
    private func endPartial() {
        partialTask?.cancel()
        partialLock.lock()
        latestPartial = ""
        partialRunning = false
        partialLock.unlock()
    }

    /// The chosen engine's translation, to replace Apple Translation's quick one; nil keeps the quick one.
    private func refine(_ text: String, from source: String, to target: String, context: [String], previous: String?, tag: String)
        async -> (text: String, how: String)? {
        switch TranslationEngine.current {
        case .appleTranslation:
            return nil
        case .appleLanguageModel:
            guard ContextTranslator.isAvailable else { return nil }
            guard claimLanguageModel() else {
                appLog("\(tag): language model busy, keeping the quick translation")
                return nil
            }
            defer { releaseLanguageModel() }
            do {
                return (try await contextTranslator.translate(text, from: source, to: target, context: context), "language model")
            } catch {
                appLog("\(tag): language model failed: \(error)")
                return nil
            }
        case .lfm2, .hymt2:
            guard let model = TranslationEngine.current.localModel else { return nil }
            do {
                let output = try await LocalTranslator.shared.translate(text, from: source, to: target, previous: previous, using: model)
                appLog("\(tag) \(model.name): \(output.ms) ms (\(output.details))")
                return (output.text, model.name)
            } catch {
                appLog("\(tag): \(model.name) not used, keeping the quick translation: \(error.localizedDescription)")
                return nil
            }
        }
    }

    private func sentence(_ japanese: String) {
        endPartial()
        let id = nextId
        nextId += 1
        appLog("JA #\(id): \(japanese)")
        let key = "\(number)-\(id)"
        Task { @MainActor in AppModel.shared.heard(key: key, japanese: japanese) }
        send(["type": "final", "id": id, "ja": japanese])
        let context = contextLines()
        let previous = swapPrevious(them: true, new: japanese)
        remember("Them (Japanese): \(japanese)")
        Task {
            let started = Date()
            func show(_ english: String, _ how: String) {
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                appLog("EN #\(id) (\(how)): \(english) (\(ms) ms)")
                Task { @MainActor in AppModel.shared.translated(key: key, english: english) }
                send(["type": "translation", "id": id, "en": english, "ms": ms])
            }
            var shown = false
            do {
                // The quick translation first (often the partial's is the same text) ...
                show(try await (lastTranslated?.ja == japanese ? lastTranslated!.en : toEnglish.translate(japanese)), "quick")
                shown = true
            } catch {
                appLog("translation failed: \(error)")
            }
            // ... then the chosen engine's, which can know the conversation, replaces it.
            if let better = await refine(japanese, from: "Japanese", to: "English", context: context, previous: previous, tag: "EN #\(id)") {
                show(better.text, better.how)
                shown = true
            }
            if !shown {
                Task { @MainActor in AppModel.shared.translated(key: key, english: "(translation failed)") }
                send(["type": "translation", "id": id, "en": "", "error": "translation failed"])
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
        let context = contextLines()
        let previous = swapPrevious(them: false, new: english)
        remember("You (English): \(english)")
        Task {
            let started = Date()
            func show(_ japanese: String, _ how: String) {
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                appLog("JA (for them) #\(id) (\(how)): \(japanese) (\(ms) ms)")
                Task { @MainActor in AppModel.shared.translatedToJapanese(key: key, japanese: japanese) }
            }
            var shown = false
            do {
                show(try await toJapanese.translate(english), "quick")
                shown = true
            } catch {
                appLog("translation to Japanese failed: \(error)")
            }
            if let better = await refine(english, from: "English", to: "Japanese", context: context, previous: previous, tag: "JA (for them) #\(id)") {
                show(better.text, better.how)
                shown = true
            }
            if !shown {
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
