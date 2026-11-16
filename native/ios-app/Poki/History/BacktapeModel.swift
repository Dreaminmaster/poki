import Foundation
import Observation
import UIKit
#if canImport(MLXLLM)
import MLXLLM
import MLXLMCommon
import Tokenizers
#endif

/// The downloaded model that writes Backtape's notes on an iPhone without Apple Intelligence (the
/// owner, 2026-11-15). The weights come from Hugging Face at one pinned revision, are kept in the
/// app's own folder, and run on the phone with MLX. Nothing of the tape leaves the phone.
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
            release()
            try? FileManager.default.removeItem(at: Self.base)
            state = .missing
        }
    }

    /// MLX needs a real GPU and room for about 1 GB of weights beside the app.
    static var supported: Bool {
        #if canImport(MLXLLM) && !targetEnvironment(simulator)
        return ProcessInfo.processInfo.physicalMemory >= 5_500_000_000
        #else
        return false
        #endif
    }

    private(set) var state: State = .missing
    private var job: Task<Void, Never>?
    private var last: Task<String?, Never>?
    #if canImport(MLXLLM)
    private var container: ModelContainer?
    #endif

    private init() {
        let kept = UserDefaults.standard.string(forKey: "history.summaryModel")
        choice = Self.choices.first { $0.id == kept } ?? Self.choices[0]
        if FileManager.default.fileExists(atPath: folder.appendingPathComponent(".complete").path) { state = .ready }
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

    func download() {
        guard Self.supported, job == nil, state != .ready else { return }
        let picked = choice
        state = .downloading(0)
        job = Task { [weak self] in
            guard let self else { return }
            var failed = false
            do {
                try await self.fetch()
            } catch {
                failed = true
                if !Task.isCancelled {
                    AppLog.shared.add("history", "summary model download failed: \(error.localizedDescription)")
                }
            }
            // Another model was picked meanwhile: that pick already reset everything.
            guard self.choice == picked else { return }
            self.state = failed ? (Task.isCancelled ? .missing : .failed) : .ready
            self.job = nil
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
        job?.cancel()
        release()
        try? FileManager.default.removeItem(at: Self.base)
        state = .missing
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
                let meter = Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(400))
                        let now = before + watch.received
                        guard let self, self.choice == picked else { return }
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
        container = nil
        #endif
    }

    /// One answer at a time: the phone has room for one run of the model.
    func respond(to text: String, instructions: String) async -> String? {
        let previous = last
        let task = Task<String?, Never> { [weak self] in
            _ = await previous?.value
            return await self?.run(text, instructions: instructions)
        }
        last = task
        return await task.value
    }

    private func run(_ text: String, instructions: String) async -> String? {
        #if canImport(MLXLLM)
        guard ready, Self.supported else { return nil }
        do {
            let model: ModelContainer
            if let container {
                model = container
            } else {
                model = try await LLMModelFactory.shared.loadContainer(from: folder, using: BacktapeTokenizerLoader())
                container = model
            }
            let answer = try await Task.detached(priority: .utility) {
                let session = ChatSession(
                    model,
                    instructions: instructions,
                    generateParameters: GenerateParameters(maxTokens: 240, temperature: 0.3),
                    additionalContext: ["enable_thinking": false]
                )
                return try await session.respond(to: text)
            }.value
            // Qwen3 can still open with its thinking block.
            if let end = answer.range(of: "</think>") { return String(answer[end.upperBound...]) }
            return answer
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
