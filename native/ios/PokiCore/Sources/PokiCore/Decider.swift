import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// A decision model answers a question that has fixed answers, in one short call: state in, one of the
// listed options out, with a probability for each. It writes no text, so it cannot name an element
// that is not on the screen. Poki uses one where a skill or a path would otherwise stop and hand
// the whole task back to the agent's model: a popup in the way, a button that was renamed or moved.
//
// The wire format is the "System One" API that TypeSafe's Jev introduced and Cloudflare's Clef
// models accept as it is:
//
//   POST { model, state, questions: { id: { type: "choice", instructions, criteria: { option: what it means } } } }
//   200  { answers: { id: { type: "choice", choice, confidence, probabilities: { option: p } } } }
//
// Nothing here is on unless the owner turned it on and gave their own key: the call goes from the
// phone straight to the provider they chose. No screenshot goes with it, only the task's goal and the
// screen's elements as text, and what a secure field holds is never in it.

/// One question with fixed answers.
public struct DecisionQuestion: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// One of `options`: each an id and what choosing it means.
        case choice([(id: String, means: String)])
        /// Yes or no, answered as the probability of yes.
        case yesNo

        public static func == (a: Kind, b: Kind) -> Bool {
            switch (a, b) {
            case (.yesNo, .yesNo): return true
            case (.choice(let x), .choice(let y)): return x.map(\.id) == y.map(\.id) && x.map(\.means) == y.map(\.means)
            default: return false
            }
        }
    }
    public var id: String
    public var instructions: String
    public var kind: Kind
    public init(id: String, instructions: String, kind: Kind) {
        self.id = id
        self.instructions = instructions
        self.kind = kind
    }
}

public struct DecisionAnswer: Sendable, Equatable {
    /// The option picked (a choice), nil for a yes or no.
    public var choice: String?
    /// How sure the model says it is of the pick, 0 to 1. For a yes or no, the probability of yes.
    public var confidence: Double
    public var probabilities: [String: Double]
    public init(choice: String?, confidence: Double, probabilities: [String: Double] = [:]) {
        self.choice = choice
        self.confidence = confidence
        self.probabilities = probabilities
    }
    /// The gap between the pick and the runner-up: a pick that barely leads is not a decision.
    public var margin: Double {
        guard let choice, let top = probabilities[choice] else { return confidence }
        let second = probabilities.filter { $0.key != choice }.values.max() ?? 0
        return top - second
    }
}

/// Why a decision did not come. `description` is one of Poki's own fixed sentences (with at most a
/// status code or a question's id in it) and is what a run's answer and its saved log hold. What the
/// provider or the system said in its own words is in `detail`: for the owner's settings page and the
/// app's log, never for a result an agent reads or a file that is kept.
public struct DeciderError: Error, CustomStringConvertible, Equatable {
    public var description: String
    public var detail: String?
    public init(_ description: String, detail: String? = nil) {
        self.description = description
        self.detail = detail.flatMap { $0.isEmpty ? nil : String($0.prefix(160)) }
    }
    /// Any failure of a decision as a safe one: a deadline, a `DeciderError` as it is, and anything
    /// else (a network error, an error thrown by the host's model call) by a fixed sentence.
    public static func safe(_ error: Error, timeout: Double? = nil) -> DeciderError {
        if let known = error as? DeciderError { return known }
        if error is DeadlineExceeded { return DeciderError(timeout.map { "no answer within \(Int($0)) s" } ?? "no answer in time") }
        return DeciderError("the request did not go through", detail: error.localizedDescription)
    }
}

/// Something that answers decision questions. The app gives PokiCore one made from the owner's
/// settings; tests give a scripted one.
public protocol Decider: Sendable {
    /// A short name for the answer and the log ("clef-flash").
    var name: String { get }
    /// The answers by question id. Throws when the call fails, takes longer than `timeout`, or the
    /// answer is not one of the options asked for.
    func decide(state: JSON, questions: [DecisionQuestion], timeout: Double) async throws -> [String: DecisionAnswer]
    /// How long this decider may take over one decision, where that is not the policy's time: a
    /// model on the phone is slower than a decision model's API. nil keeps the policy's.
    var patience: Double? { get }
}

public extension Decider {
    var patience: Double? { nil }
}

/// How far a decider is trusted. The defaults are deliberately strict: a fix that is not clearly
/// right is not made, and the run stops for the agent as it always did.
public struct DeciderPolicy: Sendable, Equatable {
    /// Below this confidence nothing is done on the decider's word.
    public var minConfidence: Double
    /// The pick must lead the runner-up by this much.
    public var minMargin: Double
    /// Fixes tried for one step, and in one run.
    public var maxFixesPerStep: Int
    public var maxFixesPerRun: Int
    /// The elements offered as options (the likeliest first).
    public var maxCandidates: Int
    /// How long one decision may take before the run goes on without it.
    public var timeout: Double
    /// With a decider (or a remembered fix) at hand, a step whose target is missing asks once the
    /// screen has held still this long, rather than wait out the step's whole time.
    public var askAfterStill: Double

    public init(minConfidence: Double = 0.6, minMargin: Double = 0.15, maxFixesPerStep: Int = 2, maxFixesPerRun: Int = 5, maxCandidates: Int = 40, timeout: Double = 2.5, askAfterStill: Double = 0.7) {
        self.minConfidence = minConfidence
        self.minMargin = minMargin
        self.maxFixesPerStep = maxFixesPerStep
        self.maxFixesPerRun = maxFixesPerRun
        self.maxCandidates = maxCandidates
        self.timeout = timeout
        self.askAfterStill = askAfterStill
    }
}

/// Where the owner's decision model is: the settings the app keeps (the token in the keychain).
public struct DeciderSettings: Sendable, Equatable, Codable {
    public enum Provider: String, Sendable, Codable, CaseIterable {
        /// Cloudflare Workers AI: Clef and Clef-flash. Needs the account id.
        case cloudflare
        /// TypeSafe AI: Jev.
        case typesafe
        /// OpenAI's Decisions API (POST /v1/decisions), which has its own request and answer format.
        case openai
        /// Any other endpoint that speaks the same API (a self-hosted Clef): the whole address.
        case custom
    }
    public var provider: Provider
    /// The model as the provider names it ("clef-flash", "clef", "jev-latest").
    public var model: String
    /// Cloudflare's account id.
    public var account: String
    /// A custom endpoint's address.
    public var address: String

    public init(provider: Provider = .cloudflare, model: String = "", account: String = "", address: String = "") {
        self.provider = provider
        self.model = model
        self.account = account
        self.address = address
    }

    public static func defaultModel(_ provider: Provider) -> String {
        switch provider {
        case .cloudflare: "clef-flash"
        case .typesafe: "jev-latest"
        case .openai: "gpt-6-luna"
        case .custom: "clef-flash"
        }
    }

    /// The decision models a provider serves that Poki knows by name, the fastest first; a custom
    /// address serves whatever its owner names.
    public static func models(_ provider: Provider) -> [String] {
        switch provider {
        case .cloudflare: ["clef-flash", "clef"]
        case .typesafe: ["jev-latest"]
        case .openai: ["gpt-6-luna"]
        case .custom: []
        }
    }

    /// Whether a model has been picked: fast decisions are on from then, with no other switch.
    public var hasModel: Bool { !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    public var modelInUse: String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Self.defaultModel(provider) : trimmed
    }

    /// The address a decision is posted to; nil while the settings are incomplete. Only https, or
    /// plain http to this device or a private network address (a model the owner runs at home).
    public var url: URL? {
        switch provider {
        case .cloudflare:
            let id = account.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, id.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
            return URL(string: "https://api.cloudflare.com/client/v4/accounts/\(id)/ai/run/@cf/cloudflare/\(modelInUse)")
        case .typesafe:
            return URL(string: "https://api.typesafe.ai/v1/systemone")
        case .openai:
            return URL(string: "https://api.openai.com/v1/decisions")
        case .custom:
            guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)), let host = url.host, !host.isEmpty else { return nil }
            if url.scheme == "https" { return url }
            let local = host == "localhost" || host == "127.0.0.1" || host.hasSuffix(".local") || host.hasPrefix("10.") || host.hasPrefix("192.168.")
                || host.hasPrefix("100.") || (host.hasPrefix("172.") && (16...31).contains(Int(host.split(separator: ".").dropFirst().first ?? "") ?? 0))
            return url.scheme == "http" && local ? url : nil
        }
    }

    /// A decider for these settings and this token; nil while they are incomplete. With a
    /// `tokenSource` the token is asked for at each call (a sign-in whose token is refreshed), and
    /// none need be given here.
    public func decider(token: String, tokenSource: SystemOneDecider.TokenSource? = nil, send: SystemOneDecider.Send? = nil) -> SystemOneDecider? {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url, !token.isEmpty || provider == .custom || tokenSource != nil else { return nil }
        return SystemOneDecider(url: url, model: modelInUse, token: token, format: provider == .openai ? .openai : .systemOne, tokenSource: tokenSource, send: send ?? SystemOneDecider.urlSession)
    }
}

/// A decision model over HTTPS: one POST per decision, in the System One format (Jev, Clef) or in
/// the format of OpenAI's Decisions API.
public struct SystemOneDecider: Decider {
    public typealias Send = @Sendable (URLRequest) async throws -> (status: Int, body: Data)
    /// A token read at each call; nil when there is none to give (signed out).
    public typealias TokenSource = @Sendable () async -> String?

    /// The two request and answer formats. They ask the same things: a choice among options with a
    /// confidence, or the probability that something is true.
    public enum Format: Sendable {
        /// `{model, state, questions: {id: {type: "choice"|"noul", instructions, criteria}}}`.
        case systemOne
        /// `{model, input, questions: [{type: "choice"|"predicate", name, instructions, choices}]}`.
        case openai
    }

    public let url: URL
    public let model: String
    public let format: Format
    let token: String
    let tokenSource: TokenSource?
    let send: Send
    public var name: String { model }

    public init(url: URL, model: String, token: String, format: Format = .systemOne, tokenSource: TokenSource? = nil, send: @escaping Send = SystemOneDecider.urlSession) {
        self.url = url
        self.model = model
        self.token = token
        self.format = format
        self.tokenSource = tokenSource
        self.send = send
    }

    /// The same questions for OpenAI's Decisions API. The state goes as text when it is text, else
    /// as one `input_json` part of a user message (which takes an object or an array).
    static func openAIBody(model: String, state: JSON, questions: [DecisionQuestion]) -> JSON {
        let input: JSON
        if case .string = state {
            input = state
        } else {
            let data: JSON
            switch state {
            case .object, .array: data = state
            default: data = ["state": state]
            }
            input = [["role": "user", "content": [["type": "input_json", "data": data]]]]
        }
        let asked: [JSON] = questions.map { q in
            switch q.kind {
            case .yesNo:
                return ["type": "predicate", "name": .string(q.id), "instructions": .string(q.instructions)]
            case .choice(let options):
                return ["type": "choice", "name": .string(q.id), "instructions": .string(q.instructions),
                        "choices": .array(options.map { ["value": .string($0.id), "description": .string($0.means)] })]
            }
        }
        return ["model": .string(model), "input": input, "questions": .array(asked)]
    }

    /// The answers of an OpenAI Decisions reply: an array, each named after its question. A refusal,
    /// or an answer that is not one of the options, is an error, never a guess.
    static func openAIAnswers(in data: Data, to questions: [DecisionQuestion]) throws -> [String: DecisionAnswer] {
        guard let reply = try? JSON.parse(String(decoding: data, as: UTF8.self)) else { throw DeciderError("the answer was not JSON") }
        guard let given = reply["answers"]?.array else {
            let said = reply["error"]?["message"]?.string ?? reply["error"]?.string
            throw DeciderError(said == nil ? "the answer held no answers" : "the provider reported an error", detail: said)
        }
        var out: [String: DecisionAnswer] = [:]
        for q in questions {
            guard let a = given.first(where: { $0["name"]?.string == q.id }) else { throw DeciderError("no answer to \"\(q.id)\"") }
            if a["type"]?.string == "refusal" { throw DeciderError("the model refused to answer \"\(q.id)\"") }
            switch q.kind {
            case .yesNo:
                guard let p = a["probability"]?.double, (0...1).contains(p) else { throw DeciderError("\"\(q.id)\" was not answered as a probability") }
                out[q.id] = DecisionAnswer(choice: nil, confidence: p)
            case .choice(let options):
                guard let choice = a["choice"]?.string, options.contains(where: { $0.id == choice }) else {
                    throw DeciderError("\"\(q.id)\" was answered with something that was not an option")
                }
                var probabilities: [String: Double] = [:]
                for entry in a["probabilities"]?.array ?? [] {
                    if let value = entry["value"]?.string, let p = entry["probability"]?.double { probabilities[value] = p }
                }
                guard let confidence = a["confidence"]?.double ?? probabilities[choice] else { throw DeciderError("\"\(q.id)\" came without a confidence") }
                out[q.id] = DecisionAnswer(choice: choice, confidence: min(1, max(0, confidence)), probabilities: probabilities)
            }
        }
        return out
    }

    /// No cache, no cookies, nothing kept on disk.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }()

    public static let urlSession: Send = { request in
        let (data, response) = try await session.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    static func body(model: String, state: JSON, questions: [DecisionQuestion]) -> JSON {
        var asked: [String: JSON] = [:]
        for q in questions {
            switch q.kind {
            case .yesNo:
                asked[q.id] = ["type": "noul", "instructions": .string(q.instructions)]
            case .choice(let options):
                asked[q.id] = ["type": "choice", "instructions": .string(q.instructions),
                               "criteria": .object(Dictionary(options.map { ($0.id, JSON.string($0.means)) }, uniquingKeysWith: { a, _ in a }))]
            }
        }
        return ["model": .string(model), "state": state, "questions": .object(asked)]
    }

    /// The answers of a reply. Cloudflare's REST API wraps a model's output in `result`; the others
    /// answer it bare. An answer that is not one of the options asked for is an error, never a guess.
    static func answers(in data: Data, to questions: [DecisionQuestion]) throws -> [String: DecisionAnswer] {
        guard let reply = try? JSON.parse(String(decoding: data, as: UTF8.self)) else { throw DeciderError("the answer was not JSON") }
        guard let given = (reply["answers"] ?? reply["result"]?["answers"])?.object else {
            let said = reply["errors"]?[0]?["message"]?.string ?? reply["detail"]?.string ?? reply["error"]?.string ?? reply["error"]?["message"]?.string
            throw DeciderError(said == nil ? "the answer held no answers" : "the provider reported an error", detail: said)
        }
        var out: [String: DecisionAnswer] = [:]
        for q in questions {
            guard let a = given[q.id] else { throw DeciderError("no answer to \"\(q.id)\"") }
            switch q.kind {
            case .yesNo:
                guard let p = a["noul"]?.double, (0...1).contains(p) else { throw DeciderError("\"\(q.id)\" was not answered as a probability") }
                out[q.id] = DecisionAnswer(choice: nil, confidence: p)
            case .choice(let options):
                guard let choice = a["choice"]?.string, options.contains(where: { $0.id == choice }) else {
                    throw DeciderError("\"\(q.id)\" was answered with something that was not an option")
                }
                var probabilities: [String: Double] = [:]
                for (k, v) in a["probabilities"]?.object ?? [:] { if let p = v.double { probabilities[k] = p } }
                // Confidence when the provider gives it, else the pick's own probability.
                guard let confidence = a["confidence"]?.double ?? probabilities[choice] else { throw DeciderError("\"\(q.id)\" came without a confidence") }
                out[q.id] = DecisionAnswer(choice: choice, confidence: min(1, max(0, confidence)), probabilities: probabilities)
            }
        }
        return out
    }

    public func decide(state: JSON, questions: [DecisionQuestion], timeout: Double) async throws -> [String: DecisionAnswer] {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: max(0.3, timeout))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var token = token
        if let tokenSource {
            guard let fresh = await tokenSource(), !fresh.isEmpty else { throw DeciderError("the sign-in gave no token; sign in again") }
            token = fresh
        }
        if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let body = format == .openai ? Self.openAIBody(model: model, state: state, questions: questions) : Self.body(model: model, state: state, questions: questions)
        request.httpBody = Data(body.serialized().utf8)
        let send = self.send, posted = request
        let (status, data) = try await withDeadline(max(0.3, timeout), "the decision") { try await send(posted) }
        guard (200..<300).contains(status) else {
            // The provider's own words go to `detail` only; never the request, which holds the screen.
            let reply = try? JSON.parse(String(decoding: data, as: UTF8.self))
            let said = reply?["errors"]?[0]?["message"]?.string ?? reply?["detail"]?.string ?? reply?["error"]?.string ?? reply?["error"]?["message"]?.string ?? ""
            throw DeciderError("the provider answered \(status)", detail: said)
        }
        return try format == .openai ? Self.openAIAnswers(in: data, to: questions) : Self.answers(in: data, to: questions)
    }

    /// One tiny decision, to tell the owner whether their settings work, and how fast.
    public func check(timeout: Double = 6) async -> Result<Int, DeciderError> {
        let began = now()
        let question = DecisionQuestion(id: "ready", instructions: "Does the state say the check is running?", kind: .choice([("yes", "It says so"), ("no", "It does not")]))
        do {
            _ = try await decide(state: "A connection check from Poki is running.", questions: [question], timeout: timeout)
            return .success(Int(((now() - began) * 1000).rounded()))
        } catch {
            return .failure(DeciderError.safe(error, timeout: timeout))
        }
    }
}

/// A decider over any model that answers text with text: a small model on the phone (Apple
/// Intelligence, a downloaded one). The questions go as one prompt and the answer comes back as one
/// JSON object, checked as strictly as a decision model's: an answer that is not an option, or that
/// comes without a confidence, is an error and never a guess. The confidence is the model's own word
/// for it, not a measured probability, so the same policy gates it and nothing more is read into it.
public struct PromptDecider: Decider {
    /// The model: the prompt and its standing instructions in, its words out; nil when it has none.
    public typealias Ask = @Sendable (_ prompt: String, _ instructions: String) async -> String?

    public let name: String
    /// A small model's window is small: the state is cut to this many characters.
    public let maxState: Int
    /// A model on the phone reads the whole prompt before its first word: it gets seconds, not the
    /// policy's 2.5.
    public let patience: Double?
    let ask: Ask

    public init(name: String, maxState: Int = 6000, patience: Double = 8, ask: @escaping Ask) {
        self.name = name
        self.maxState = maxState
        self.patience = patience
        self.ask = ask
    }

    public static let instructions = """
    You decide the next step of a task on a phone from what is on its screen. Answer with one JSON \
    object and nothing else, with one entry for each question id. For a question with options: \
    {"choice": "<the id of one option>", "confidence": <0 to 1>}. For a yes or no question: \
    {"yes": <the probability of yes, 0 to 1>}. Pick only from the options given. Give a low \
    confidence when the screen does not clearly show the answer.
    """

    static func prompt(state: JSON, questions: [DecisionQuestion], maxState: Int) -> String {
        var text: String
        if case .string(let plain) = state { text = plain } else { text = state.serialized() }
        if text.count > maxState { text = String(text.prefix(maxState)) + " … (cut)" }
        var out = "State:\n\(text)\n\nQuestions:\n"
        for q in questions {
            switch q.kind {
            case .yesNo:
                out += "- \"\(q.id)\" (yes or no): \(q.instructions)\n"
            case .choice(let options):
                out += "- \"\(q.id)\": \(q.instructions)\n"
                for option in options { out += "    option \"\(option.id)\": \(option.means)\n" }
            }
        }
        return out + "\nAnswer with the JSON object only."
    }

    /// The answers in a model's words: the first JSON object in them (a small model may wrap it in
    /// a code fence or a sentence).
    static func answers(in words: String, to questions: [DecisionQuestion]) throws -> [String: DecisionAnswer] {
        guard let open = words.firstIndex(of: "{"), let close = words.lastIndex(of: "}"), open < close,
              let reply = try? JSON.parse(String(words[open...close])), reply.object != nil else {
            throw DeciderError("the answer was not JSON")
        }
        var out: [String: DecisionAnswer] = [:]
        for q in questions {
            guard let a = reply[q.id] else { throw DeciderError("no answer to \"\(q.id)\"") }
            switch q.kind {
            case .yesNo:
                guard let p = a["yes"]?.double, (0...1).contains(p) else { throw DeciderError("\"\(q.id)\" was not answered as a probability") }
                out[q.id] = DecisionAnswer(choice: nil, confidence: p)
            case .choice(let options):
                guard let choice = a["choice"]?.string, options.contains(where: { $0.id == choice }) else {
                    throw DeciderError("\"\(q.id)\" was answered with something that was not an option")
                }
                guard let confidence = a["confidence"]?.double, (0...1).contains(confidence) else { throw DeciderError("\"\(q.id)\" came without a confidence") }
                out[q.id] = DecisionAnswer(choice: choice, confidence: confidence)
            }
        }
        return out
    }

    public func decide(state: JSON, questions: [DecisionQuestion], timeout: Double) async throws -> [String: DecisionAnswer] {
        let prompt = Self.prompt(state: state, questions: questions, maxState: maxState), ask = self.ask
        let words = try await withDeadline(max(0.3, timeout), "the decision") { await ask(prompt, Self.instructions) }
        guard let words, !words.isEmpty else { throw DeciderError("the model on this iPhone gave no answer") }
        return try Self.answers(in: words, to: questions)
    }

    /// One tiny decision, to tell the owner whether the model answers, and how fast.
    public func check(timeout: Double = 20) async -> Result<Int, DeciderError> {
        let began = now()
        let question = DecisionQuestion(id: "ready", instructions: "Does the state say the check is running?", kind: .choice([("yes", "It says so"), ("no", "It does not")]))
        do {
            _ = try await decide(state: "A connection check from Poki is running.", questions: [question], timeout: timeout)
            return .success(Int(((now() - began) * 1000).rounded()))
        } catch {
            return .failure(DeciderError.safe(error, timeout: timeout))
        }
    }
}
