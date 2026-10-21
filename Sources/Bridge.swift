import Foundation
import Network

/// A WebSocket server on 127.0.0.1 that the glasses app (a web page inside the Even app) talks to.
/// Same protocol as the PC server in the main project:
///   client → server: binary frames of 16 kHz mono s16le PCM
///   server → client: JSON text frames: hello, partial {ja}, final {id, ja}, translation {id, en, ms}
final class BridgeServer {
    static let port: UInt16 = 5175

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "bridge.server")
    private var sessions: [ObjectIdentifier: Session] = [:]

    func start() throws {
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
        let session = Session(connection: connection, queue: queue)
        let id = ObjectIdentifier(session)
        sessions[id] = session
        session.onClose = { [weak self] in self?.queue.async { self?.sessions[id] = nil } }
        session.start()
    }
}

/// One connection from the glasses app: its own recognizer, numbering and translator.
private final class Session {
    let connection: NWConnection
    let queue: DispatchQueue
    var onClose: (() -> Void)?

    private let recognizer = Recognizer()
    private let translator = Translator()
    private var nextId = 1
    private var bytes = 0
    private var closed = false

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
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

        recognizer.onPartial = { [weak self] text in self?.send(["type": "partial", "ja": text]) }
        recognizer.onFinal = { [weak self] text in self?.sentence(text) }
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

    private func sentence(_ japanese: String) {
        let id = nextId
        nextId += 1
        appLog("JA #\(id): \(japanese)")
        send(["type": "final", "id": id, "ja": japanese])
        Task {
            let started = Date()
            do {
                let english = try await translator.translate(japanese)
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                appLog("EN #\(id): \(english) (\(ms) ms)")
                send(["type": "translation", "id": id, "en": english, "ms": ms])
            } catch {
                appLog("translation failed: \(error)")
                send(["type": "translation", "id": id, "en": "", "error": "\(error)"])
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
