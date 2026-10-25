import Foundation
import UIKit
import os
import llama

/// Translation by a small model run with llama.cpp (Metal GPU, or CPU). One sentence at a time:
/// a call made while another is running is refused, and the caller keeps Apple's quick translation.
/// Greedy decoding, the prompts the PC screen used (server/screen in the main project).
final class LocalTranslator {
    static let shared = LocalTranslator()
    static let gpuKey = "localModelGPU"

    enum Failure: LocalizedError {
        case notDownloaded, busy, inBackground, loadFailed, promptTooLong, decodeFailed, rejected(String)

        var errorDescription: String? {
            switch self {
            case .notDownloaded: return "model not downloaded"
            case .busy: return "busy with another sentence"
            case .inBackground: return "app is not in the foreground"
            case .loadFailed: return "model failed to load"
            case .promptTooLong: return "prompt too long"
            case .decodeFailed: return "decoding failed"
            case .rejected(let why): return "output rejected (\(why))"
            }
        }
    }

    struct Output {
        let text: String
        let ms: Int
        let loadMs: Int?
        let promptTokens: Int
        let newTokens: Int

        var details: String {
            let thermal = ["nominal", "fair", "serious", "critical"][min(3, ProcessInfo.processInfo.thermalState.rawValue)]
            var parts = ["\(promptTokens)+\(newTokens) tokens"]
            if let loadMs { parts.append("load \(loadMs) ms") }
            parts.append("thermal \(thermal)")
            parts.append("free \(os_proc_available_memory() / 1_048_576) MB")
            return parts.joined(separator: ", ")
        }
    }

    // llama.cpp must not be driven while the app is in the background (the GPU work is aborted by iOS).
    private static let activeLock = NSLock()
    private static var active = true

    static func setActive(_ value: Bool) {
        activeLock.lock()
        active = value
        activeLock.unlock()
    }

    private static var isActive: Bool {
        activeLock.lock()
        defer { activeLock.unlock() }
        return active
    }

    private let queue = DispatchQueue(label: "local.translator", qos: .userInitiated)
    private let busyLock = NSLock()
    private var busy = false

    // Only touched on `queue`.
    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var loaded: LocalModel?
    private var loadedGPU = false
    private var backendStarted = false

    // MARK: public

    /// Loads the model ahead of the first sentence, so that sentence doesn't pay for it.
    func preload(_ which: LocalModel) {
        queue.async {
            guard ModelStore.isReady(which) else { return }
            do {
                let ms = try self.ensureLoaded(which)
                if let ms { appLog("\(which.name) loaded in \(ms) ms, free memory \(os_proc_available_memory() / 1_048_576) MB") }
            } catch {
                appLog("\(which.name) failed to load: \(error.localizedDescription)")
            }
        }
    }

    /// Frees the model (another engine was chosen, a file was deleted, or the system is short of memory).
    func unload() {
        queue.async {
            guard self.model != nil else { return }
            self.free()
            appLog("local model unloaded, free memory \(os_proc_available_memory() / 1_048_576) MB")
        }
    }

    /// `previous`: the line this speaker said just before (same language as `text`), or nil.
    func translate(_ text: String, from source: String, to target: String, previous: String?, using which: LocalModel) async throws -> Output {
        guard Self.isActive else { throw Failure.inBackground }
        guard ModelStore.isReady(which) else { throw Failure.notDownloaded }
        busyLock.lock()
        if busy {
            busyLock.unlock()
            throw Failure.busy
        }
        busy = true
        busyLock.unlock()
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                defer {
                    self.busyLock.lock()
                    self.busy = false
                    self.busyLock.unlock()
                }
                do {
                    continuation.resume(returning: try self.run(text, target: target, previous: previous, which: which))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: model

    private func free() {
        if let context { llama_free(context) }
        if let model { llama_model_free(model) }
        context = nil
        model = nil
        loaded = nil
    }

    /// Returns the load time in ms, or nil if it was loaded already.
    private func ensureLoaded(_ which: LocalModel) throws -> Int? {
        let gpu = UserDefaults.standard.bool(forKey: Self.gpuKey)
        if model != nil, loaded == which, loadedGPU == gpu { return nil }
        free()
        if !backendStarted {
            llama_backend_init()
            backendStarted = true
        }
        let started = Date()
        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = gpu ? 99 : 0
        guard let loadedModel = llama_model_load_from_file(ModelStore.fileURL(which).path, modelParams) else { throw Failure.loadFailed }
        var contextParams = llama_context_default_params()
        contextParams.n_ctx = 1024
        contextParams.n_batch = 512
        contextParams.n_ubatch = 512
        contextParams.n_threads = 4
        contextParams.n_threads_batch = 4
        guard let loadedContext = llama_init_from_model(loadedModel, contextParams) else {
            llama_model_free(loadedModel)
            throw Failure.loadFailed
        }
        model = loadedModel
        context = loadedContext
        loaded = which
        loadedGPU = gpu
        return Int(Date().timeIntervalSince(started) * 1000)
    }

    // MARK: prompts

    private static func prompt(_ which: LocalModel, text: String, target: String, previous: String?) -> String {
        switch which {
        case .lfm2:
            // Liquid's documented use: the direction is the system prompt; one line, no conversation.
            return "<|startoftext|><|im_start|>system\nTranslate to \(target).<|im_end|>\n<|im_start|>user\n\(text)<|im_end|>\n<|im_start|>assistant\n"
        case .hymt2:
            // Tencent's templates, with the background text reworded so the model doesn't translate it.
            let content: String
            if let previous {
                content = "[Background Information]\nEarlier in the conversation (for reference only; do not translate these lines):\n- \(previous)\n\n"
                    + "Please translate the following text into \(target), taking the provided background information into consideration.\n\n[Source Text]\n\(text)"
            } else {
                content = "Translate the following text into \(target). Note that you should only output the translated result without any additional explanation:\n\n\(text)"
            }
            return "<｜hy_begin▁of▁sentence｜><｜hy_User｜>\(content)<｜hy_Assistant｜>"
        }
    }

    // MARK: running

    private func run(_ text: String, target: String, previous: String?, which: LocalModel) throws -> Output {
        let started = Date()
        let loadMs = try ensureLoaded(which)
        guard let model, let context else { throw Failure.loadFailed }
        guard let vocab = llama_model_get_vocab(model) else { throw Failure.loadFailed }

        var tokens = tokenize(vocab, Self.prompt(which, text: text, target: target, previous: previous))
        guard !tokens.isEmpty, tokens.count < 480 else { throw Failure.promptTooLong }
        if tokens[0] != llama_vocab_bos(vocab) {
            appLog("warning: the prompt did not start with the BOS token (\(which.name))")
        }
        let promptTokens = tokens.count
        let limit = min(200, text.count * 3 + 32)

        llama_memory_clear(llama_get_memory(context), true)
        let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())
        llama_sampler_chain_add(sampler, llama_sampler_init_greedy())
        defer { llama_sampler_free(sampler) }

        var bytes: [UInt8] = []
        var produced = 0
        while produced < limit {
            let status = tokens.withUnsafeMutableBufferPointer { buffer in
                llama_decode(context, llama_batch_get_one(buffer.baseAddress, Int32(buffer.count)))
            }
            guard status == 0 else { throw Failure.decodeFailed }
            let token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, token) { break }
            bytes += piece(vocab, token)
            produced += 1
            tokens = [token]
        }

        let raw = String(decoding: bytes, as: UTF8.self)
        let cleaned = try Self.clean(raw, which: which, target: target)
        return Output(text: cleaned, ms: Int(Date().timeIntervalSince(started) * 1000), loadMs: loadMs,
                      promptTokens: promptTokens, newTokens: produced)
    }

    private func tokenize(_ vocab: OpaquePointer, _ text: String) -> [llama_token] {
        let length = Int32(text.utf8.count)
        var capacity = Int(length) + 16
        var tokens = [llama_token](repeating: 0, count: capacity)
        var count = llama_tokenize(vocab, text, length, &tokens, Int32(capacity), false, true) // special tokens in the text are parsed
        if count < 0 {
            capacity = Int(-count)
            tokens = [llama_token](repeating: 0, count: capacity)
            count = llama_tokenize(vocab, text, length, &tokens, Int32(capacity), false, true)
        }
        return count > 0 ? Array(tokens.prefix(Int(count))) : []
    }

    private func piece(_ vocab: OpaquePointer, _ token: llama_token) -> [UInt8] {
        var buffer = [CChar](repeating: 0, count: 64)
        var count = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        if count < 0 {
            buffer = [CChar](repeating: 0, count: Int(-count))
            count = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        }
        return buffer.prefix(max(0, Int(count))).map { UInt8(bitPattern: $0) }
    }

    // MARK: output

    private static func clean(_ raw: String, which: LocalModel, target: String) throws -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("- ") { text = String(text.dropFirst(2)) }
        if text.count >= 2, let first = text.first, let last = text.last,
           (first == "\"" && last == "\"") || (first == "「" && last == "」") || (first == "“" && last == "”") {
            text = String(text.dropFirst().dropLast())
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { throw Failure.rejected("empty") }
        // The model echoed the prompt, or translated the background line instead of the sentence.
        if text.contains("[Background") || text.contains("Source Text") || text.contains("[Source") { throw Failure.rejected("echoed the prompt") }
        if target == "English", text.unicodeScalars.contains(where: { (0x3040...0x30FF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value) }) {
            throw Failure.rejected("Japanese left in the English")
        }
        if which == .lfm2, target == "English" { text = recase(text) }
        return text
    }

    /// LFM2 writes everything in lower case, even "I". Capital letters back at the start of sentences and for "I".
    private static func recase(_ text: String) -> String {
        var result = text.replacingOccurrences(of: "\\bi\\b", with: "I", options: .regularExpression)
        var capitalize = true
        var out = ""
        for character in result {
            if capitalize, character.isLetter {
                out += character.uppercased()
                capitalize = false
            } else {
                out.append(character)
                if ".!?".contains(character) { capitalize = true }
            }
        }
        result = out
        return result
    }
}
