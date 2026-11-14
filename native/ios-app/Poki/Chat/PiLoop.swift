import Foundation
import PiSwiftAgent
import PiSwiftAI
import PokiCore

/// The chat's model loop: pi's agent loop (PiSwiftAgent from xibbon/PiSwift, MIT, a Swift port of
/// pi-mono's pi-agent-core) with the providers of PiSwiftAI, on this iPhone. The prompt and the tools
/// are the chat's `Harness` (the Mac Poki Agent's); each tool call goes back to `ChatModel.perform`, so
/// look, do and status run through PokiCore with its approval rules and report_plan and finish_task
/// drive the plan bubble as before.
///
/// One loop holds one conversation, on one provider and model. Another model starts a new loop that
/// carries the messages over; pi converts them between providers.
@MainActor
final class PiLoop {
    enum Outcome: Equatable { case done, stopped, overTurns, failed(String) }

    let provider: ModelProvider
    let model: Model
    private let agent: Agent
    private let gate = StopGate()

    var signature: String { "pi:\(provider.rawValue)/\(model.id)" }
    var messages: [AgentMessage] { agent.state.messages }

    init(provider: ModelProvider, model: Model, tools: [ToolSpec], carrying messages: [AgentMessage] = [],
         perform: @escaping @MainActor (ToolCall) async -> PokiCore.ToolAnswer) {
        self.provider = provider
        self.model = model
        let gate = self.gate
        let agentTools = tools.map { spec in
            AgentTool(label: spec.name, name: spec.name, description: spec.description, parameters: spec.schema.mapValues { AnyCodable($0) }) { id, params, signal, _ in
                if gate.stopped { return Self.result(PokiCore.ToolAnswer(text: "Task stopped. Action not executed.", jpeg: nil, isError: true)) }
                let arguments = (try? JSONEncoder().encode(params)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
                // pi runs its loop in tasks of its own, so stop() reaches the call under way only through
                // `signal`: cancelling the call stops a `do` before its next action.
                let call = Task { @MainActor in await perform(ToolCall(id: id, name: spec.name, arguments: arguments)) }
                let forget = signal?.onCancel { call.cancel() }
                defer { forget?() }
                return Self.result(await call.value)
            }
        }
        // agent/pi-session.mjs: low thinking, one tool call at a time.
        agent = Agent(AgentOptions(
            initialState: AgentState(model: model, thinkingLevel: .low, tools: agentTools, messages: messages),
            getApiKey: { _ in await ModelCredential.apiKey(for: provider) },
            toolExecution: .sequential
        ))
    }

    /// The owner's message (with the JPEGs of its photos and PDFs) under this task's instructions, then
    /// pi's loop until the model answers without tools, `stop()` or `maxTurns` model turns. `onText`
    /// gets each finished text block.
    func run(_ text: String, images: [Data] = [], instructions: String, maxTurns: Int, onText: @escaping @MainActor (String) -> Void) async -> Outcome {
        gate.reset()
        use(instructions)
        let turns = Counter()
        let failure = Box()
        let agent = self.agent
        let gate = self.gate
        let unsubscribe = agent.subscribe { event, _ in
            switch event {
            case .turnStart:
                if turns.increment() > maxTurns { gate.overTurns(); agent.abort() }
            case .messageEnd(.assistant(let reply)):
                if reply.stopReason == .error { failure.set(reply.errorMessage ?? "") }
                let texts = reply.content.compactMap { block -> String? in
                    guard case .text(let content) = block else { return nil }
                    let text = content.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    return text.isEmpty ? nil : text
                }
                if !texts.isEmpty { await MainActor.run { texts.forEach(onText) } }
            default: break
            }
        }
        defer { unsubscribe() }
        do {
            try await agent.prompt(text, images: images.map { ImageContent(data: $0.base64EncodedString(), mimeType: "image/jpeg") })
        } catch {
            failure.set(error.localizedDescription)
        }
        if gate.stopped { return gate.wasOverTurns ? .overTurns : .stopped }
        if let message = failure.value {
            // The owner's message goes again with the next one, as with the direct clients.
            _ = agent.dropTrailingErroredAssistant()
            return .failed(Self.words(message, provider: provider))
        }
        return .done
    }

    /// Ends the task after the step under way: nothing more is sent to the phone or the model.
    func stop() {
        gate.stop()
        agent.abort()
    }

    /// The leading system message holds the instructions and declares the tools. pi keeps it when a loop
    /// carries messages over, so each task puts its own text in it and leaves the tools as they are.
    private func use(_ instructions: String) {
        var messages = agent.messages
        if case .system(var system)? = messages.first {
            system.content = .text(instructions)
            messages[0] = .system(system)
        } else if let system = createInitialSystemMessage(instructions, nil) {
            messages.insert(.system(system), at: 0)
        }
        agent.messages = messages
    }

    private nonisolated static func result(_ answer: PokiCore.ToolAnswer) -> AgentToolResult {
        var content: [ContentBlock] = [.text(TextContent(text: answer.text))]
        if let jpeg = answer.jpeg { content.append(.image(ImageContent(data: jpeg.base64EncodedString(), mimeType: "image/jpeg"))) }
        return AgentToolResult(content: content, isError: answer.isError)
    }

    /// The provider's message for the owner. pi never puts the key in it; a sign-in that ran out says so.
    private static func words(_ message: String, provider: ModelProvider) -> String {
        if message.contains("No API key") || message.contains("missingApiKey") || message.isEmpty && !ModelKeys.hasKey(provider) {
            return provider.signsIn ? AppLocalization.text(LocalizedStringResource("Sign in to ChatGPT again. Open Settings, then Models."))
                                    : AppLocalization.text(LocalizedStringResource("Add your \(provider.name) key. Open Settings, then Models."))
        }
        // The provider's stream ended on an error event with nothing in it (the library prints the
        // missing fields as "undefined"): said plainly, with what is left of it when there is any.
        if message.contains("Error Code undefined") || message.hasSuffix(": undefined") {
            let rest = message.replacingOccurrences(of: "Error Code undefined:", with: "").replacingOccurrences(of: "undefined", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: " :"))
            let said = AppLocalization.text(LocalizedStringResource("\(provider.name) ended the answer with an error and gave no reason. This is usually brief on their side. Tap Try Again."))
            return rest.isEmpty ? said : said + " (" + rest + ")"
        }
        return AppLocalization.text(LocalizedStringResource("\(provider.name), \(message.isEmpty ? AppLocalization.text("the request failed.") : message)"))
    }
}

/// Set by stop() or the turn limit, read by the tools on pi's tasks.
private final class StopGate: @unchecked Sendable {
    private let lock = NSLock()
    private var stop_ = false, over = false
    func reset() { lock.withLock { stop_ = false; over = false } }
    func stop() { lock.withLock { stop_ = true } }
    func overTurns() { lock.withLock { stop_ = true; over = true } }
    var stopped: Bool { lock.withLock { stop_ } }
    var wasOverTurns: Bool { lock.withLock { over } }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func increment() -> Int { lock.withLock { n += 1; return n } }
}

private final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var text: String?
    func set(_ value: String) { lock.withLock { if text == nil { text = value } } }
    var value: String? { lock.withLock { text } }
}
