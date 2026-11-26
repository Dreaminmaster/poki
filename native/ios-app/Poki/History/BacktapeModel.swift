import Foundation
import Observation
import UIKit
#if canImport(MLXLLM)
import MLXLLM
import MLXLMCommon
import Tokenizers
#endif

/// The model the owner downloads to this iPhone (the owner, 2026-11-15 and 2026-11-18). It can be the
/// decision model of skills and paths, and it writes Screen History's notes on an iPhone without
/// Apple Intelligence. It can be downloaded whether or not the iPhone has Apple Intelligence. The
/// weights come from Hugging Face at one pinned revision, are kept in the app's own folder, and run
/// on the phone with MLX. Nothing it is given leaves the phone.
@MainActor
@Observable
final class BacktapeModel {
    static let shared = BacktapeModel()

    enum State: Equatable {
        case missing
        case downloading(Double)
        case ready
        case failed
    }

    /// Why a download stopped, for the model's page: each has its own words and the same way on.
    enum Stop: Equatable {
        /// The connection was lost or there was none.
        case connection
        /// The server did not send the file, or sent another one.
        case server
        /// The phone has no room for the files still to come.
        case space
        case other
    }

    /// A model the owner can pick. Each is pinned to one revision so every phone gets the same files.
    struct Choice: Identifiable, Equatable {
        let id: String
        let name: String
        let repo: String
        let revision: String
        let files: [String]
        let sizes: [Int64]
        var bytes: Int64 { sizes.reduce(0, +) }
    }

    /// Both Apache 2.0, 4-bit, from mlx-community on Hugging Face (the owner, 2026-11-15: let people
    /// choose between Qwen 3 and Qwen 3.5).
    static let choices: [Choice] = [
        Choice(
            id: "qwen3", name: "Qwen 3 1.7B", repo: "mlx-community/Qwen3-1.7B-4bit",
            revision: "3b1b1768f8f8cf8351c712464f906e86c2b8269e",
            files: ["config.json", "added_tokens.json", "special_tokens_map.json", "tokenizer_config.json",
                    "model.safetensors.index.json", "merges.txt", "vocab.json", "tokenizer.json", "model.safetensors"],
            sizes: [937, 707, 613, 9_706, 49_731, 1_671_853, 2_776_833, 11_422_654, 968_080_210]
        ),
        Choice(
            id: "qwen35", name: "Qwen 3.5 2B", repo: "mlx-community/Qwen3.5-2B-4bit",
            revision: "674aaa7240b91e8012fcad5d791b7dfe5ba90207",
            files: ["config.json", "tokenizer_config.json", "chat_template.jinja", "model.safetensors.index.json",
                    "vocab.json", "tokenizer.json", "model.safetensors"],
            sizes: [3_113, 1_139, 7_755, 81_722, 6_722_759, 19_989_343, 1_722_271_785]
        ),
    ]

    /// The picked model. Picking another removes the files of the one before, so only one is kept.
    var choice: Choice {
        didSet {
            guard choice != oldValue else { return }
            UserDefaults.standard.set(choice.id, forKey: "history.summaryModel")
            dropJob()
            // Answers asked of the model before are no longer wanted: they are dropped, not returned.
            epoch += 1
            release()
            try? FileManager.default.removeItem(at: Self.base)
            state = .missing
            stopped = nil
            kept = 0
        }
    }

    /// MLX needs a real GPU and room for about 1 GB of weights beside the app: an iPhone with 6 GB
    /// of memory or more (the page says so, see `requirement`).
    nonisolated static var supported: Bool {
        #if canImport(MLXLLM) && !targetEnvironment(simulator)
        return ProcessInfo.processInfo.physicalMemory >= 5_500_000_000
        #else
        return false
        #endif
    }

    /// Built with MLX and on a real iPhone: the models are listed, and one that `supported` rules
    /// out says why on its page.
    nonisolated static var offered: Bool {
        #if canImport(MLXLLM) && !targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    private(set) var state: State = .missing
    /// Why the last download stopped, while `state` is `.failed`.
    private(set) var stopped: Stop?
    /// Bytes of the picked model already on the phone as whole files: a download that was stopped
    /// goes on after them.
    private(set) var kept: Int64 = 0
    private var job: Task<Void, Never>?
    private var last: Task<String?, Never>?
    /// Counts every switch and removal of the model. An answer asked under an earlier count is stale
    /// and is dropped.
    private var epoch = 0
    #if canImport(MLXLLM)
    /// The loaded weights and the revision they are of: never used for another revision.
    private var loaded: (revision: String, container: ModelContainer)?
    #endif

    private init() {
        let keptID = UserDefaults.standard.string(forKey: "history.summaryModel")
        choice = Self.choices.first { $0.id == keptID } ?? Self.choices[0]
        if FileManager.default.fileExists(atPath: folder.appendingPathComponent(".complete").path) { state = .ready }
        // A download the app was closed in the middle of: its whole files are still there.
        kept = state == .ready ? choice.bytes : wholeBytes()
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.release() }
        }
    }

    var ready: Bool { state == .ready }

    private static var base: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Poki/BacktapeModel", isDirectory: true)
    }

    private var folder: URL { Self.base.appendingPathComponent(String(choice.revision.prefix(12)), isDirectory: true) }

    // MARK: Download

    /// Starts the download, or goes on with one that stopped (Try Again and Resume Download are
    /// this same call: files that are whole are kept).
    func download() {
        guard Self.supported, job == nil, state != .ready else { return }
        let picked = choice
        stopped = nil
        // No room for what is still to come: said at once, before anything is fetched.
        let needed = picked.bytes - wholeBytes() + 200_000_000
        if let free = Self.freeBytes, free < needed {
            kept = wholeBytes()
            stopped = .space
            state = .failed
            return
        }
        state = .downloading(min(0.999, Double(wholeBytes()) / Double(max(1, picked.bytes))))
        job = Task { [weak self] in
            guard let self else { return }
            var stop: Stop?
            var cancelled = false
            do {
                try await self.fetch()
            } catch {
                cancelled = Task.isCancelled || error is CancellationError
                stop = Self.stop(for: error)
                if !cancelled {
                    AppLog.shared.add("history", "summary model download failed: \(error.localizedDescription)")
                }
            }
            // Another model was picked meanwhile: that pick already reset everything.
            guard self.choice == picked else { return }
            self.job = nil
            self.kept = stop == nil ? picked.bytes : self.wholeBytes()
            if stop == nil {
                self.state = .ready
                LocalModels.downloadFinished()
            } else if cancelled {
                // Stopped by the owner: not a failure, and the files so far wait for Resume Download.
                self.state = .missing
            } else {
                self.stopped = stop
                self.state = .failed
            }
        }
    }

    /// The whole files of the picked model on the phone, in bytes.
    private func wholeBytes() -> Int64 {
        let manager = FileManager.default
        var sum: Int64 = 0
        for (name, bytes) in zip(choice.files, choice.sizes) {
            let size = (try? manager.attributesOfItem(atPath: folder.appendingPathComponent(name).path)[.size] as? NSNumber)?.int64Value
            if size == bytes { sum += bytes }
        }
        return sum
    }

    private static var freeBytes: Int64? {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        return (try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
    }

    private static func stop(for error: Error) -> Stop {
        let cocoa = error as NSError
        if cocoa.domain == NSCocoaErrorDomain, cocoa.code == NSFileWriteOutOfSpaceError { return .space }
        if cocoa.domain == NSPOSIXErrorDomain, cocoa.code == Int(ENOSPC) { return .space }
        guard let url = error as? URLError else { return .other }
        switch url.code {
        case .badServerResponse, .cannotParseResponse, .fileDoesNotExist, .resourceUnavailable: return .server
        case .cannotWriteToFile, .cannotCreateFile, .cannotMoveFile: return .other
        default: return .connection
        }
    }

    func cancel() {
        job?.cancel()
    }

    private func dropJob() {
        job?.cancel()
        job = nil
    }

    func remove() {
        dropJob()
        // What is being written with the removed model is dropped, not returned.
        epoch += 1
        release()
        try? FileManager.default.removeItem(at: Self.base)
        state = .missing
        stopped = nil
        kept = 0
    }

    /// Files that are already whole are kept, so a broken download goes on where it stopped.
    private func fetch() async throws {
        let manager = FileManager.default
        let picked = choice, folder = self.folder, total = picked.bytes
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var kept = Self.base
        try? kept.setResourceValues(values)

        var done: Int64 = 0
        for (name, bytes) in zip(picked.files, picked.sizes) {
            try Task.checkCancellation()
            let file = (name: name, bytes: bytes)
            let target = folder.appendingPathComponent(file.name)
            let size = (try? manager.attributesOfItem(atPath: target.path)[.size] as? NSNumber)?.int64Value
            if size != file.bytes {
                try? manager.removeItem(at: target)
                let url = URL(string: "https://huggingface.co/\(picked.repo)/resolve/\(picked.revision)/\(file.name)")!
                let watch = BacktapeDownloadWatch()
                let before = done
                // The meter wakes from its sleep when it is cancelled and only runs again after the
                // download has gone on, sometimes past its end: it then writes nothing, or it would
                // put the bar back at 99 % over Ready, where it stayed until the app was opened again.
                let meter = Task { [weak self] in
                    while true {
                        do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
                        guard !Task.isCancelled, let self, self.choice == picked,
                              case .downloading = self.state else { return }
                        let now = before + watch.received
                        self.state = .downloading(min(0.999, Double(now) / Double(total)))
                    }
                }
                defer { meter.cancel() }
                let (temporary, response) = try await URLSession.shared.download(from: url, delegate: watch)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                let got = (try? manager.attributesOfItem(atPath: temporary.path)[.size] as? NSNumber)?.int64Value
                guard got == file.bytes else { throw URLError(.cannotParseResponse) }
                try manager.moveItem(at: temporary, to: target)
            }
            done += file.bytes
            guard choice == picked else { throw CancellationError() }
            state = .downloading(min(0.999, Double(done) / Double(total)))
        }
        manager.createFile(atPath: folder.appendingPathComponent(".complete").path, contents: Data())
    }

    // MARK: Writing

    /// Frees the weights. They load again with the next note.
    func release() {
        #if canImport(MLXLLM)
        loaded = nil
        #endif
    }

    /// One answer at a time: the phone has room for one run of the model. The answer belongs to the
    /// model that was picked when it was asked: after a switch or a removal it is dropped. When the
    /// caller stops waiting (a decision's deadline cancels its task), the run is stopped too, so the
    /// next one does not wait behind an answer nobody reads.
    func respond(to text: String, instructions: String, maxTokens: Int = 240, temperature: Float = 0.3) async -> String? {
        let previous = last
        let asked = epoch
        let task = Task<String?, Never> { [weak self] in
            _ = await previous?.value
            guard !Task.isCancelled, let self, self.epoch == asked else { return nil }
            let answer = await self.run(text, instructions: instructions, maxTokens: maxTokens, temperature: temperature)
            guard !Task.isCancelled, self.epoch == asked else { return nil }
            return answer
        }
        last = task
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    private func run(_ text: String, instructions: String, maxTokens: Int, temperature: Float) async -> String? {
        #if canImport(MLXLLM)
        guard ready, Self.supported else { return nil }
        let revision = choice.revision, asked = epoch
        do {
            let model: ModelContainer
            if let loaded, loaded.revision == revision {
                model = loaded.container
            } else {
                loaded = nil
                model = try await LLMModelFactory.shared.loadContainer(from: folder, using: BacktapeTokenizerLoader())
                // Switched or removed while it loaded: these weights are not the picked model's.
                guard epoch == asked, choice.revision == revision, ready else { return nil }
                loaded = (revision, model)
            }
            // The words come as they are written, so a cancelled run ends at the next one: ending the
            // stream stops the model.
            let generation = Task.detached(priority: .utility) { () throws -> String in
                let session = ChatSession(
                    model,
                    instructions: instructions,
                    generateParameters: GenerateParameters(maxTokens: maxTokens, temperature: temperature),
                    additionalContext: ["enable_thinking": false]
                )
                var words = ""
                for try await piece in session.streamResponse(to: text) {
                    try Task.checkCancellation()
                    words += piece
                }
                try Task.checkCancellation()
                return words
            }
            let answer = try await withTaskCancellationHandler { try await generation.value } onCancel: { generation.cancel() }
            // Qwen3 can still open with its thinking block.
            if let end = answer.range(of: "</think>") { return String(answer[end.upperBound...]) }
            return answer
        } catch is CancellationError {
            return nil
        } catch {
            AppLog.shared.add("history", "summary model failed: \(error.localizedDescription)")
            return nil
        }
        #else
        return nil
        #endif
    }
}

/// Counts the bytes of the download in flight. The session hands over the task as it starts, and
/// the task itself knows how much has arrived.
final class BacktapeDownloadWatch: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?

    var received: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return task?.countOfBytesReceived ?? 0
    }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        lock.lock()
        self.task = task
        lock.unlock()
    }
}

#if canImport(MLXLLM)
/// swift-transformers' tokenizer behind MLX's protocol, written out by hand so the build needs no
/// macro plugin (it is what MLXHuggingFace's #huggingFaceTokenizerLoader expands to).
struct BacktapeTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        BacktapeTokenizer(try await Tokenizers.AutoTokenizer.from(modelFolder: directory))
    }
}

struct BacktapeTokenizer: MLXLMCommon.Tokenizer, @unchecked Sendable {
    private let upstream: any Tokenizers.Tokenizer

    init(_ upstream: any Tokenizers.Tokenizer) {
        self.upstream = upstream
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? {
        upstream.convertTokenToId(token)
    }

    func convertIdToToken(_ id: Int) -> String? {
        upstream.convertIdToToken(id)
    }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}
#endif
