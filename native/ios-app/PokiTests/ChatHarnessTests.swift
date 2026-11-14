import Foundation
import Network
import PokiCore
import SwiftUI
import UIKit
import XCTest
@testable import Poki

/// The chat's agent as the model sees it: a task handed to Poki runs on a custom endpoint (an OpenAI
/// chat completions server on 127.0.0.1 that answers with scripted turns), so each request the model
/// gets and each answer Poki gives back are the real ones.
@MainActor
final class ChatHarnessTests: XCTestCase {
    private var saved: [String: Any?] = [:]
    private var app: AppModel?
    private var notes: [String] = []
    private static let settings = ["chat.provider", "chat.customURL", "chat.customModel"]

    override func setUp() async throws {
        for key in Self.settings { saved[key] = UserDefaults.standard.object(forKey: key) }
    }

    override func tearDown() async throws {
        for key in Self.settings { UserDefaults.standard.set(saved[key] ?? nil, forKey: key) }
        for text in notes { _ = await app?.runTool("routines", arguments: Self.json(["action": "forget_note", "id": text])) }
        ChatModel.afterTask = nil
    }

    /// A conversation handed over by an outside agent, on the fake endpoint. The phone's tools answer
    /// without a session (the Debug probe's call), so routines reaches the app's own memory.
    private func chat(on server: FakeCompletions) -> ChatModel {
        ModelKeys.customURL = "http://127.0.0.1:\(server.port)/v1"
        ModelKeys.customModel = "fake-model"
        ModelKeys.selectedProvider = .custom
        let app = AppModel(launcher: FakeLauncher(), pairer: FakePairing())
        app.inProcessReadyForProbe()
        self.app = app
        return ChatModel(app: app, kind: .handoff, requester: "Test agent")
    }

    private static func json(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    /// A note the agent saved during one task reaches the model with the next task of the same
    /// conversation.
    func testEachTaskTellsTheModelWhatMemoryHolds() async throws {
        let note = "The owner's gym is Fitness First on Queen Street \(UUID().uuidString.prefix(6))"
        notes.append(note)
        let done = FakeCompletions.tool("finish_task", ["success": true, "summary": "Done.", "details": [], "answer": ["kind": "action"]])
        let server = try FakeCompletions(replies: [
            FakeCompletions.tool("routines", ["action": "remember", "text": note]), done, FakeCompletions.text("Noted."),
            done, FakeCompletions.text("Booked."),
        ])
        let chat = chat(on: server)

        _ = await chat.runDelegated("Remember that my gym is Fitness First on Queen Street")
        _ = await chat.runDelegated("Book a class at my gym")

        let requests = server.requests
        XCTAssertEqual(requests.count, 5)
        XCTAssertFalse(FakeCompletions.system(requests[0]).contains(note))
        XCTAssertTrue(FakeCompletions.system(requests[3]).contains(note), "the second task's prompt has the note the first saved")
    }

    /// finish_task's requested facts and the kind of answer go back to the agent that handed the task
    /// over, and the task's record keeps the answer with the element it was read from.
    func testTheFinishedTaskAnswersWithTheRequestedFacts() async throws {
        let server = try FakeCompletions(replies: [
            FakeCompletions.tool("finish_task", [
                "success": true, "summary": "Read the battery level in Settings.",
                "details": [["label": "Battery", "value": "81%"]],
                "answer": ["kind": "field", "items": [["ref": "7", "field": "value"]]],
            ]),
            FakeCompletions.text("Done."),
        ])
        let chat = chat(on: server)
        var records: [TaskRecord] = []
        ChatModel.afterTask = { records.append($0) }

        let reply = await chat.runDelegated("What is the battery level?")

        XCTAssertEqual(reply.success, true)
        XCTAssertTrue(reply.text.contains("answer (field): Battery: 81%"), reply.text)
        let result = try XCTUnwrap(records.last?.result)
        XCTAssertEqual(result.answer?.kind, .field)
        XCTAssertEqual(result.answer?.items?.map(\.ref), ["7"])
        XCTAssertEqual(result.details, [TaskResult.Detail(label: "Battery", value: "81%")])
    }

    /// The model's name for the task comes with its plan and is kept on the task's plan entry, where
    /// the task card reads its title ("Book a class", not the whole sentence that was asked). A
    /// sentence sent as the title is not taken. When the task ends, its entry also keeps how it ended.
    func testThePlansTitleNamesTheTask() async throws {
        let done = FakeCompletions.tool("finish_task", ["success": true, "summary": "Done.", "details": [], "answer": ["kind": "action"]])
        let server = try FakeCompletions(replies: [
            FakeCompletions.tool("report_plan", ["steps": ["Open the gym app", "Book the class"], "currentStep": 1, "title": "Book a class"]),
            done, FakeCompletions.text("Booked."),
            FakeCompletions.tool("report_plan", ["steps": ["Open Settings"], "currentStep": 1, "title": "Open the Settings app and read out what the battery page says first"]),
            done, FakeCompletions.text("81%."),
        ])
        let chat = chat(on: server)

        _ = await chat.runDelegated("Book a class at my gym for tomorrow morning, the early one")
        _ = await chat.runDelegated("What is the battery level?")

        let plans = chat.entries.filter { if case .plan = $0.kind { true } else { false } }
        XCTAssertEqual(plans.map(\.title), ["Book a class", nil])
        // How each task ended stays with it, for the folded card: when, and out of how many planned steps.
        XCTAssertEqual(plans.map(\.total), [2, 1])
        XCTAssertTrue(plans.allSatisfy { $0.ended != nil })
    }

    /// Each task's browser card sits where that task began browsing: above the answer it led to, in
    /// every task of the conversation, and in the conversation as it is saved and opened again.
    func testEachBrowserCardSitsAboveTheAnswerItsTaskGave() async throws {
        // A closed port: the page fails at once, and the browser has been opened for the task.
        let open = FakeCompletions.tool("web_open", ["url": "http://127.0.0.1:9/prices"])
        let done = FakeCompletions.tool("finish_task", ["success": true, "summary": "Done.", "details": [], "answer": ["kind": "action"]])
        let server = try FakeCompletions(replies: [open, done, FakeCompletions.text("First answer."),
                                                   open, done, FakeCompletions.text("Second answer.")])
        let chat = chat(on: server)
        defer { PokiBrowser.shared.close() }

        _ = await chat.runDelegated("Look up the prices")
        _ = await chat.runDelegated("Look up the show times")

        func order(_ entries: [ChatEntry]) -> [String] {
            entries.compactMap { entry in
                switch entry.kind {
                case .request(let text, _): return text
                case .poki(let text) where text.hasSuffix("answer."): return text
                default: return String(describing: entry.kind).hasPrefix("browser") ? "browser card" : nil
                }
            }
        }
        let expected = ["Look up the prices", "browser card", "First answer.", "Look up the show times", "browser card", "Second answer."]
        XCTAssertEqual(order(chat.entries), expected)
        let saved = try JSONDecoder().decode([ChatEntry].self, from: JSONEncoder().encode(chat.entries))
        XCTAssertEqual(order(saved), expected, "the conversation opened again keeps the order")
        if UserDefaults.standard.bool(forKey: "markdownEvidence") { try await capture(chat, "browser-card-order") }
    }

    /// The conversation as the chat page draws it, saved as a picture in Documents/MarkdownEvidence.
    private func capture(_ chat: ChatModel, _ name: String) async throws {
        let app = try XCTUnwrap(self.app)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        window.rootViewController = UIHostingController(rootView: NavigationStack {
            ChatView(openDetails: { _ in }, openVoice: {}, openSetup: {}, openModel: {}, openThreads: {})
        }.environment(app).environment(chat))
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .seconds(2))
        let data = await Task.detached { var code: NSString?; return PKInProcess.shared().screenshot(&code) }.value
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("MarkdownEvidence", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try XCTUnwrap(UIImage(data: try XCTUnwrap(data))?.pngData()).write(to: folder.appendingPathComponent("\(name).png"))
    }

    /// Stop ends the phone step under way at its next action, instead of letting the rest of a long
    /// `do` run on the phone (seen on the owner's phone: 16 to 22 s of typing after Stop), and the chat
    /// says Stopping until that step has ended.
    func testStopEndsTheStepUnderWayAtItsNextAction() async throws {
        let waits = Array(repeating: ["wait": 1000], count: 15)
        let server = try FakeCompletions(replies: [FakeCompletions.tool("do", ["actions": waits]), FakeCompletions.text("Done.")])
        let chat = chat(on: server)
        func said() -> [String] { chat.entries.compactMap { if case .poki(let text) = $0.kind { text } else { nil } } }

        chat.send("Wait on the phone")
        while chat.awaitingModel { try await Task.sleep(for: .milliseconds(50)) }
        let stopped = ContinuousClock.now
        chat.stop()
        XCTAssertEqual(said().last, "Stopping…")
        while chat.savedCalls.isEmpty, ContinuousClock.now - stopped < .seconds(20) { try await Task.sleep(for: .milliseconds(100)) }
        let after = ContinuousClock.now - stopped
        XCTAssertLessThan(after, .seconds(3), "the do call ended \(after) after Stop")
        while said().last != "Stopped.", ContinuousClock.now - stopped < .seconds(10) { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertEqual(said().last, "Stopped.")
        XCTAssertFalse(said().contains("Stopping…"))
    }

    /// The system prompt names no tool the model does not have (the app has no unlock_device or
    /// handle_alert).
    func testThePromptNamesOnlyToolsTheModelHas() throws {
        let tools = Set(Harness.tools.map(\.name))
        let regex = try NSRegularExpression(pattern: "\\b[a-z]+(?:_[a-z]+)+\\b")
        let text = Harness.system
        XCTAssertFalse(text.isEmpty, "agent-system.md is in the app")
        let named = Set(regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text).map { String(text[$0]) } })
        XCTAssertEqual(named.subtracting(tools), [], "named in agent-system.md but not offered to the model")
    }
}

/// An OpenAI chat completions endpoint on 127.0.0.1: each request is kept and answered with the next
/// scripted turn as one server-sent event.
final class FakeCompletions: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "fake-completions")
    private let lock = NSLock()
    private var replies: [String]
    private var responseStatuses: [Int]
    private var bodies: [[String: Any]] = []
    /// Only harmless routing/identity fields are recorded. Never capture Authorization or cookies.
    private var routingHeaders: [[String: String]] = []

    var port: UInt16 { listener.port?.rawValue ?? 0 }
    var requests: [[String: Any]] { lock.withLock { bodies } }
    var requestHeaders: [[String: String]] { lock.withLock { routingHeaders } }

    init(replies: [String], responseStatuses: [Int] = []) throws {
        self.replies = replies
        self.responseStatuses = responseStatuses
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success else { throw URLError(.cannotConnectToHost) }
    }

    deinit { listener.cancel() }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        read(connection, Data())
    }

    private func read(_ connection: NWConnection, _ received: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            guard let self else { return }
            let received = received + (data ?? Data())
            if let request = Self.decodedRequest(received) {
                return self.answer(connection, request.body, headers: request.headers)
            }
            if done || error != nil { return connection.cancel() }
            self.read(connection, received)
        }
    }

    /// The request's body once all of it is in.
    private static func decodedRequest(_ data: Data) -> (body: Data, headers: [String: String])? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[..<end.lowerBound], as: UTF8.self).lowercased()
        let length = head.split(separator: "\r\n").first { $0.hasPrefix("content-length:") }
            .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
        let body = data[end.upperBound...]
        guard body.count >= length else { return nil }
        let allowed: Set<String> = ["x-opencode-session", "x-opencode-client", "user-agent"]
        var headers: [String: String] = [:]
        for line in head.split(separator: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon])
            if allowed.contains(name) {
                headers[name] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return (Data(body.prefix(length)), headers)
    }

    private func answer(_ connection: NWConnection, _ body: Data, headers: [String: String]) {
        let (code, payload) = lock.withLock { () -> (Int, String) in
            routingHeaders.append(headers)
            if let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] { bodies.append(json) }
            let code = responseStatuses.isEmpty ? 200 : responseStatuses.removeFirst()
            let scripted = replies.isEmpty ? Self.text("No more scripted turns.") : replies.removeFirst()
            return (code, code == 200 ? scripted : #"{"error":{"message":"synthetic rejection"}}"#)
        }
        let status = code == 200 ? "200 OK" : "\(code) Bad Request"
        let type = code == 200 ? "text/event-stream" : "application/json"
        let head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(payload.utf8.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data((head + payload).utf8), completion: .contentProcessed { _ in connection.cancel() })
    }

    private static func event(_ delta: [String: Any], finish: String) -> String {
        let chunk: [String: Any] = ["id": "chatcmpl-fake", "object": "chat.completion.chunk", "created": 0, "model": "fake-model",
                                    "choices": [["index": 0, "delta": delta, "finish_reason": finish]]]
        let json = String(decoding: try! JSONSerialization.data(withJSONObject: chunk), as: UTF8.self)
        return "data: \(json)\n\ndata: [DONE]\n\n"
    }

    static func tool(_ name: String, _ arguments: [String: Any]) -> String {
        let args = String(decoding: try! JSONSerialization.data(withJSONObject: arguments), as: UTF8.self)
        return event(["role": "assistant", "tool_calls": [["index": 0, "id": "call_\(UUID().uuidString.prefix(8))", "type": "function",
                                                          "function": ["name": name, "arguments": args]]]], finish: "tool_calls")
    }

    static func text(_ words: String) -> String { event(["role": "assistant", "content": words], finish: "stop") }

    /// A request's system (or developer) messages, as text.
    static func system(_ request: [String: Any]) -> String {
        let messages = request["messages"] as? [[String: Any]] ?? []
        return messages.filter { ["system", "developer"].contains($0["role"] as? String ?? "") }.map { message in
            (message["content"] as? String) ?? ((message["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined(separator: "\n") ?? "")
        }.joined(separator: "\n")
    }
}
