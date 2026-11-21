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
    enum Outcome: Equatable { case done, waitingForReply, stopped, authorizationDeclined, overTurns, stuck, failed(String) }

    /// This many steps in a row with the same call and the same screen end the task as stuck.
    nonisolated static let stallSteps = 6
    nonisolated static let stallPairs = 4

    let provider: ModelProvider
    let model: Model
    let inSplitView: Bool
    private let agent: Agent
    private let toolVariants: [ToolVariant]
    private let toolPolicy = ToolPolicy()
    private let gate = StopGate()
    /// A custom address's HTTP client, which repairs a doubled `data:` stream and keeps what the address
    /// answered for the log.
    private let endpoint: CustomEndpointClient?
    private let stall = StallWatch()

    private struct FinishToolCache: @unchecked Sendable {
        private final class Store: @unchecked Sendable {
            let lock = NSLock()
            var tools: [Harness.ResultCardMode: AgentTool] = [:]
        }
        private let store = Store()
        private let execute: AgentToolExecute

        init(execute: @escaping AgentToolExecute) { self.execute = execute }

        func tool(resultCardMode: Harness.ResultCardMode) -> AgentTool {
            if let cached = store.lock.withLock({ store.tools[resultCardMode] }) { return cached }
            let spec = Harness.finishTask(resultCardMode: resultCardMode)
            let built = AgentTool(label: spec.name, name: spec.name, description: spec.description,
                                  parameters: spec.schema.mapValues { AnyCodable($0) }, execute: execute)
            return store.lock.withLock {
                if let existing = store.tools[resultCardMode] { return existing }
                store.tools[resultCardMode] = built
                return built
            }
        }
    }

    private enum ToolVariant: Sendable {
        case standard(withMemory: AgentTool, withoutMemory: AgentTool)
        case finish(FinishToolCache)
    }

    private final class ToolPolicy: @unchecked Sendable {
        private let lock = NSLock()
        private var includeMemoryAttribution = true
        private var includeCountedScroll = true
        private var includeCountedScrollReply = true
        private var rendersCards = true
        private var resultCardMode: Harness.ResultCardMode = .all

        func set(includeMemoryAttribution: Bool,
                 includeCountedScroll: Bool,
                 includeCountedScrollReply: Bool,
                 rendersCards: Bool,
                 resultCardMode: Harness.ResultCardMode) {
            lock.withLock {
                self.includeMemoryAttribution = includeMemoryAttribution
                self.includeCountedScroll = includeCountedScroll
                self.includeCountedScrollReply = includeCountedScrollReply
                self.rendersCards = rendersCards
                self.resultCardMode = resultCardMode
            }
        }

        func observeApp(_ bundleID: String) {
            lock.withLock {
                guard rendersCards else { return }
                resultCardMode = resultCardMode.including(app: bundleID)
            }
        }

        func current() -> (memoryAttribution: Bool, countedScroll: Bool, countedScrollReply: Bool, resultCardMode: Harness.ResultCardMode) {
            lock.withLock { (includeMemoryAttribution, includeCountedScroll, includeCountedScrollReply, resultCardMode) }
        }
    }

    var signature: String { "pi:\(provider.rawValue)/\(model.id)" }
    var messages: [AgentMessage] { agent.state.messages }
    var hasCurrentCustomBackups: Bool {
        guard let endpoint else { return true }
        return endpoint.backups == CustomEndpointClient.backupAddresses(for: model)
    }

    /// Only forward `sessionId` to providers confirmed to accept OpenAI's `prompt_cache_key`
    /// and session-routing headers. Arbitrary custom gateways frequently reject unknown Responses
    /// parameters with HTTP 400 (`unsupported_parameter`), so custom endpoints receive `sessionId`
    /// only when targeting official `api.openai.com`.
    nonisolated static func sessionCacheKey(for provider: ModelProvider, model: Model, sessionID: String?) -> String? {
        guard let sessionID, !sessionID.isEmpty else { return nil }
        switch provider {
        case .openai, .chatgpt:
            return sessionID
        case .custom:
            return URL(string: model.baseUrl)?.host?.lowercased() == "api.openai.com" ? sessionID : nil
        case .anthropic, .deepseek, .gemini, .openrouter:
            return nil
        }
    }

    init(provider: ModelProvider, model: Model, tools: [ToolSpec], inSplitView: Bool = false, sessionId: String? = nil,
         carrying messages: [AgentMessage] = [],
         perform: @escaping @MainActor (ToolCall) async -> PokiCore.ToolAnswer) {
        self.provider = provider
        self.model = model
        self.inSplitView = inSplitView
        let gate = self.gate
        let endpoint = provider == .custom ? CustomEndpointClient(for: model) : nil
        self.endpoint = endpoint
        let stall = self.stall
        let grants = HistoryDeliveryGrants()
        let policy = self.toolPolicy
        let variants = tools.map { spec -> ToolVariant in
            let execute: AgentToolExecute = { id, params, signal, _ in
                if gate.stopped { return Self.result(PokiCore.ToolAnswer(text: "Task stopped. Action not executed.", jpeg: nil, isError: true)) }
                let encoder = JSONEncoder()
                encoder.outputFormatting = .sortedKeys
                let arguments = (try? encoder.encode(params)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
                // pi runs its loop in tasks of its own, so stop() reaches the call under way only through
                // `signal`: cancelling the call stops a `do` before its next action.
                let revision = spec.name == "screen_history" ? HistoryCapture.agentQueryRevision : nil
                if spec.name == "screen_history" { grants.record(id, revision: revision) }
                let trace = ChatStepTiming.current
                let action = trace.map { "action=\($0.nextAction()) tool=\(spec.name)" } ?? ""
                trace?.record("action_start", action)
                let call = Task { @MainActor in await perform(ToolCall(id: id, name: spec.name, arguments: arguments)) }
                let forget = signal?.onCancel { call.cancel() }
                defer { forget?() }
                let rawAnswer = await call.value
                let answer = spec.name == "screen_history"
                    ? HistoryCapture.validateAgentAnswer(rawAnswer, revision: revision) : rawAnswer
                trace?.record("action_end", "\(action) ok=\(!answer.isError)")
                // The call and what it left on the screen, so a task that keeps working is told from a
                // loop: the arguments have sorted keys, and the screen has no clock or read time in it.
                if spec.name == Harness.countedScrollReplyTool, !answer.isError {
                    gate.end(.waitingForReply)
                } else if answer.automationAuthorizationDeclined {
                    gate.end(.authorizationDeclined)
                } else if answer.waitingForOwner {
                    stall.reset()
                } else if stall.record(call: "\(spec.name)\n\(arguments)", screen: answer.screen ?? answer.text) {
                    gate.end(.stuck)
                }
                return Self.result(answer)
            }
            if spec.name == "finish_task" {
                return .finish(FinishToolCache(execute: execute))
            }
            let stripped = Harness.withoutActionMemoryIDs(spec)
            let withMemory = AgentTool(label: spec.name, name: spec.name, description: spec.description,
                                       parameters: spec.schema.mapValues { AnyCodable($0) }, execute: execute)
            let withoutMemory = AgentTool(label: stripped.name, name: stripped.name, description: stripped.description,
                                          parameters: stripped.schema.mapValues { AnyCodable($0) }, execute: execute)
            return .standard(withMemory: withMemory, withoutMemory: withoutMemory)
        }
        toolVariants = variants
        // agent/pi-session.mjs: low thinking, one tool call at a time. Pi copies the
        // tool list at prompt start; prepareRequest updates its *live* context each turn.
        agent = Agent(AgentOptions(
            initialState: AgentState(model: model, thinkingLevel: .low,
                                     tools: Self.availableTools(variants, allowed: HistoryCapture.agentQueryAllowed,
                                                                includeMemoryAttribution: true,
                                                                includeCountedScroll: true,
                                                                includeCountedScrollReply: true,
                                                                resultCardMode: .all),
                                     messages: messages),
            streamFn: { model, transcript, options in
                // API credentials may have suspended after prepareRequest. Recheck at
                // the last request boundary too; never add a tool the live context lacks.
                let revision = HistoryCapture.agentQueryRevision
                let allowed = revision != nil && getCurrentTools(transcript.messages).contains { $0.name == "screen_history" }
                var messages = transcript.messages.map { message -> PiSwiftAI.Message in
                    guard case .toolResult(let result) = message else { return message }
                    return .toolResult(grants.validated(result, revision: revision))
                }
                if let index = messages.indices.first, case .system(var system) = messages[index],
                   case .text(let text) = system.content {
                    system.content = .text(Harness.historyInstructions(text, allowed: allowed))
                    messages[index] = .system(system)
                }
                if !allowed, getCurrentTools(messages).contains(where: { $0.name == "screen_history" }) {
                    messages.append(.system(SystemMessage(content: .text(""), toolsRemoved: [ToolReference(name: "screen_history")])))
                }
                var options = options
                if let endpoint { options.httpClient = endpoint }
                if let trace = ChatStepTiming.current {
                    if model.api == .openAIResponses {
                        let onPayload = options.onPayload
                        options.onPayload = { payload in
                            let updated = try await onPayload?(payload)
                            trace.record("model_request", "boundary=payload_ready bytes=\((updated ?? payload).json.utf8.count)")
                            return updated
                        }
                    } else {
                        trace.record("model_request", "boundary=provider_handoff")
                    }
                }
                return try streamSimple(model: model, context: Context(messages: messages), options: options)
            },
            sessionId: Self.sessionCacheKey(for: provider, model: model, sessionID: sessionId),
            getApiKey: { _ in await ModelCredential.apiKey(for: provider, piProvider: model.provider) },
            toolExecution: .sequential,
            prepareToolResultMessage: { result in
                grants.validated(result, revision: HistoryCapture.agentQueryRevision)
            },
            prepareRequest: { request, _ in
                let revision = HistoryCapture.agentQueryRevision
                let currentPolicy = policy.current()
                let tools = Self.availableTools(variants, allowed: revision != nil,
                                                includeMemoryAttribution: currentPolicy.memoryAttribution,
                                                includeCountedScroll: currentPolicy.countedScroll,
                                                includeCountedScrollReply: currentPolicy.countedScrollReply,
                                                resultCardMode: currentPolicy.resultCardMode)
                var context = request.context
                context.tools = tools
                context.messages = context.messages.map { message in
                    guard case .toolResult(let result) = message else { return message }
                    return .toolResult(grants.validated(result, revision: revision))
                }
                if let index = context.messages.indices.first, case .system(var system) = context.messages[index],
                   case .text(let text) = system.content {
                    system.content = .text(Harness.historyInstructions(text, allowed: revision != nil))
                    context.messages[index] = .system(system)
                }
                let changes = getToolStateChanges(getCurrentTools(context.messages), tools.map(\.aiTool))
                if !changes.toolsAdded.isEmpty || !changes.toolsRemoved.isEmpty {
                    context.messages.append(.system(SystemMessage(
                        content: .text(""),
                        toolsAdded: changes.toolsAdded.isEmpty ? nil : changes.toolsAdded,
                        toolsRemoved: changes.toolsRemoved.isEmpty ? nil : changes.toolsRemoved
                    )))
                }
                return AgentRequestUpdate(context: context)
            }
        ))
    }

    /// Widens the active task's result-card schema when a card-capable app is launched or read.
    func observeApp(_ bundleID: String) {
        toolPolicy.observeApp(bundleID)
    }

    /// The owner's message (with the JPEGs of its photos and PDFs) under this task's instructions, then
    /// pi's loop until the model answers without tools, `stop()`, a repeated call or pair on the same
    /// screen, or `maxTurns` model turns (a ceiling for a model that runs away). Owner waits reset the
    /// stall history. `onText` gets each finished text block.
    func run(_ text: String, images: [Data] = [], instructions: String, maxTurns: Int,
             includeMemoryAttribution: Bool = true,
             includeCountedScroll: Bool = true,
             includeCountedScrollReply: Bool = true,
             rendersCards: Bool = true,
             resultCardMode: Harness.ResultCardMode = .all,
             timing: ChatStepTiming? = nil, onText: @escaping @MainActor (String) -> Void) async -> Outcome {
        gate.reset()
        stall.reset()
        toolPolicy.set(includeMemoryAttribution: includeMemoryAttribution,
                       includeCountedScroll: includeCountedScroll,
                       includeCountedScrollReply: includeCountedScrollReply,
                       rendersCards: rendersCards,
                       resultCardMode: resultCardMode)
        agent.tools = Self.availableTools(toolVariants, allowed: HistoryCapture.agentQueryAllowed,
                                          includeMemoryAttribution: includeMemoryAttribution,
                                          includeCountedScroll: includeCountedScroll,
                                          includeCountedScrollReply: includeCountedScrollReply,
                                          resultCardMode: resultCardMode)
        use(instructions)
        let turns = Counter()
        let failure = Box()
        let agent = self.agent
        let gate = self.gate
        let unsubscribe = agent.subscribe { event, _ in
            switch event {
            case .turnStart:
                timing?.beginTurn()
                if turns.increment() > maxTurns { gate.end(.overTurns) }
                if gate.stopped { agent.abort() }
            case .messageUpdate(_, let event):
                switch event {
                case .textDelta(_, let delta, _) where !delta.isEmpty: timing?.firstOutput(.text)
                case .thinkingDelta(_, let delta, _) where !delta.isEmpty: timing?.firstOutput(.reasoning)
                case .toolCallStart: timing?.firstOutput(.tool)
                default: break
                }
            case .messageEnd(.assistant(let reply)):
                if reply.stopReason == .error { failure.set(reply.errorMessage ?? "") }
                let texts = reply.content.compactMap { block -> String? in
                    guard case .text(let content) = block else { return nil }
                    let text = content.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    return text.isEmpty ? nil : text
                }
                if !texts.isEmpty { timing?.firstOutput(.text, boundary: "message_end") }
                timing?.record("model_complete", "stop=\(reply.stopReason.rawValue)")
                if !texts.isEmpty { await MainActor.run { texts.forEach(onText) } }
            default: break
            }
        }
        defer { unsubscribe() }
        do {
            try await ChatStepTiming.$current.withValue(timing) {
                try await agent.prompt(text, images: images.map { ImageContent(data: $0.base64EncodedString(), mimeType: "image/jpeg") })
            }
        } catch {
            failure.set(error.localizedDescription)
        }
        if gate.stopped {
            switch gate.ending {
            case .waitingForReply: return .waitingForReply
            case .authorizationDeclined: return .authorizationDeclined
            case .overTurns: return .overTurns
            case .stuck: return .stuck
            default: return .stopped
            }
        }
        if let message = failure.value {
            if let seen = endpoint?.seen {
                let key = provider == .custom ? CustomProviders.provider(piProvider: model.provider).flatMap { CustomProviders.key($0.id) } : ModelKeys.key(provider)
                AppLog.shared.add("model", seen.summary(key: key) + ", failed: " + CustomEndpointClient.redacted(message, key: key))
            }
            // The owner's message goes again with the next one, as with the direct clients.
            _ = agent.dropTrailingErroredAssistant()
            return .failed(Self.words(message, provider: provider))
        }
        return .done
    }

    /// Ends the task after the step under way: nothing more is sent to the phone or the model.
    func stop() {
        gate.end(.stopped)
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

    private nonisolated static func availableTools(_ variants: [ToolVariant], allowed: Bool,
                                                   includeMemoryAttribution: Bool,
                                                   includeCountedScroll: Bool,
                                                   includeCountedScrollReply: Bool,
                                                   resultCardMode: Harness.ResultCardMode) -> [AgentTool] {
        variants.compactMap { variant in
            let tool: AgentTool
            switch variant {
            case .standard(let withMemory, let withoutMemory):
                tool = includeMemoryAttribution ? withMemory : withoutMemory
            case .finish(let cache):
                tool = cache.tool(resultCardMode: resultCardMode)
            }
            if tool.name == "screen_history", !allowed { return nil }
            if tool.name == "count_messages", !includeCountedScroll { return nil }
            if tool.name == Harness.countedScrollReplyTool, !(includeCountedScroll && includeCountedScrollReply) { return nil }
            return tool
        }
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

/// Associates an actual history result with the grant under which it was requested.
/// Missing grants (including results carried from another loop) are never trusted.
final class HistoryDeliveryGrants: @unchecked Sendable {
    private let lock = NSLock()
    private var revisions: [String: UInt64] = [:]

    func record(_ id: String, revision: UInt64?) {
        lock.withLock { revisions[id] = revision }
    }

    func validated(_ result: ToolResultMessage, revision: UInt64?) -> ToolResultMessage {
        guard result.toolName == "screen_history", !result.isError else { return result }
        let granted = lock.withLock { revisions[result.toolCallId] }
        guard let revision, granted == revision else {
            var safe = result
            safe.content = [.text(TextContent(text: PokiCore.screenHistoryRevokedMessage))]
            safe.details = nil
            safe.isError = true
            return safe
        }
        return result
    }
}

/// Set by stop(), the turn limit or the stall watch, read by the tools on pi's tasks.
private final class StopGate: @unchecked Sendable {
    enum Ending { case stopped, waitingForReply, authorizationDeclined, overTurns, stuck }
    private let lock = NSLock()
    private var first: Ending?
    func reset() { lock.withLock { first = nil } }
    /// The owner's stop wins over the ending that was already there.
    func end(_ ending: Ending) { lock.withLock { if first == nil || ending == .stopped { first = ending } } }
    var stopped: Bool { lock.withLock { first != nil } }
    var ending: Ending? { lock.withLock { first } }
}

private final class StallWatch: @unchecked Sendable {
    private let lock = NSLock()
    private var steps: [(call: String, screen: String)] = []
    func reset() { lock.withLock { steps.removeAll() } }
    func record(call: String, screen: String) -> Bool {
        lock.withLock {
            steps.append((call, screen))
            let pairSteps = PiLoop.stallPairs * 2
            let capacity = max(PiLoop.stallSteps, pairSteps)
            if steps.count > capacity { steps.removeFirst(steps.count - capacity) }
            let repeated = steps.suffix(PiLoop.stallSteps)
            if repeated.count == PiLoop.stallSteps,
               repeated.allSatisfy({ $0.call == call && $0.screen == screen }) { return true }
            let alternating = steps.suffix(pairSteps)
            return alternating.count == pairSteps && alternating.allSatisfy { $0.screen == screen }
                && zip(alternating.dropFirst(2), alternating).allSatisfy { $0.0.call == $0.1.call }
        }
    }
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
