import Foundation

/// The translation model files on this phone: where they are, whether they are complete, and
/// downloading them.
@MainActor
final class ModelStore: ObservableObject {
    static let shared = ModelStore()

    enum State: Equatable {
        case missing
        case downloading(Double) // 0...1
        case ready
        case failed(String)
    }

    @Published private(set) var states: [LocalModel: State] = [:]
    private var downloads: [LocalModel: FileDownloader] = [:]

    private init() { refresh() }

    nonisolated static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Models", isDirectory: true)
    }

    nonisolated static func fileURL(_ model: LocalModel) -> URL {
        directory.appendingPathComponent(model.fileName)
    }

    /// True if the whole file is there.
    nonisolated static func isReady(_ model: LocalModel) -> Bool {
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL(model).path)
        return (attributes?[.size] as? Int64) == model.bytes
    }

    func state(_ model: LocalModel) -> State { states[model] ?? .missing }

    func refresh() {
        for model in LocalModel.allCases {
            if case .downloading = state(model) { continue }
            states[model] = Self.isReady(model) ? .ready : .missing
        }
    }

    func download(_ model: LocalModel) {
        if case .downloading = state(model) { return }
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        states[model] = .downloading(0)
        appLog("downloading \(model.name) (\(model.sizeText))")
        let downloader = FileDownloader(url: model.downloadURL, destination: Self.fileURL(model), expectedBytes: model.bytes,
            progress: { [weak self] fraction in
                Task { @MainActor in self?.states[model] = .downloading(fraction) }
            },
            done: { [weak self] error in
                Task { @MainActor in
                    guard let self else { return }
                    self.downloads[model] = nil
                    if let error {
                        self.states[model] = .failed(error.localizedDescription)
                        appLog("download of \(model.name) failed: \(error.localizedDescription)")
                    } else {
                        self.states[model] = .ready
                        appLog("\(model.name) downloaded")
                        AppModel.shared.modelDownloaded(model)
                    }
                }
            })
        downloads[model] = downloader
        downloader.start()
    }

    func cancel(_ model: LocalModel) {
        downloads[model]?.cancel()
        downloads[model] = nil
        states[model] = .missing
    }

    func delete(_ model: LocalModel) {
        LocalTranslator.shared.unload()
        try? FileManager.default.removeItem(at: Self.fileURL(model))
        states[model] = .missing
        appLog("\(model.name) deleted")
    }
}

/// One download to a file, with progress; the file only appears at its final name once it is complete.
private final class FileDownloader: NSObject, URLSessionDownloadDelegate {
    private let url: URL
    private let destination: URL
    private let expectedBytes: Int64
    private let progress: (Double) -> Void
    private let done: (Error?) -> Void
    private var session: URLSession?
    private var finished = false

    struct Failure: LocalizedError {
        let errorDescription: String?
    }

    init(url: URL, destination: URL, expectedBytes: Int64, progress: @escaping (Double) -> Void, done: @escaping (Error?) -> Void) {
        self.url = url
        self.destination = destination
        self.expectedBytes = expectedBytes
        self.progress = progress
        self.done = done
        super.init()
    }

    func start() {
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        self.session = session
        session.downloadTask(with: url).resume()
    }

    func cancel() {
        finished = true
        session?.invalidateAndCancel()
    }

    private func finish(_ error: Error?) {
        guard !finished else { return }
        finished = true
        session?.finishTasksAndInvalidate()
        done(error)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress(min(1, Double(totalBytesWritten) / Double(expectedBytes)))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temporary file is deleted when this returns, so it is moved here.
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            return finish(Failure(errorDescription: "server answered \(http.statusCode)"))
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: location.path)
        let size = attributes?[.size] as? Int64
        guard size == expectedBytes else {
            return finish(Failure(errorDescription: "incomplete file (\(size ?? 0) of \(expectedBytes) bytes)"))
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var target = destination
            try? target.setResourceValues(values)
            finish(nil)
        } catch {
            finish(error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(error) }
    }
}
