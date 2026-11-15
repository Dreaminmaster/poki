import ActivityKit
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
    private func chat(on server: FakeCompletions, transport: HTTPTransport? = nil,
                      automation: InProcessAutomation = PKInProcess.shared(), kind: SavedSession.Kind = .handoff) -> ChatModel {
        ModelKeys.customURL = "http://127.0.0.1:\(server.port)/v1"
        ModelKeys.customModel = "fake-model"
        ModelKeys.selectedProvider = .custom
        let app = AppModel(launcher: FakeLauncher(), pairer: FakePairing(), automation: automation, transport: transport)
        app.inProcessReadyForProbe()
        self.app = app
        return ChatModel(app: app, kind: kind, requester: kind == .handoff ? "Test agent" : nil)
    }

    private static func json(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    func testSplitViewTaskWaitsForOriginalPairAndResumesFromFreshReads() async throws {
        let transport = RotatingWorkspace()
        let server = try FakeCompletions(replies: [
            FakeCompletions.tool("look", ["pane": "left", "full": true]),
            FakeCompletions.tool("look", ["pane": "right", "full": true]),
            FakeCompletions.tool("do", ["actions": [["tap": [180, 200]]]]),
            FakeCompletions.tool("finish_task", ["success": true, "summary": "Focused the draft field."]),
            FakeCompletions.text("Focused the field."),
        ])
        let chat = chat(on: server, transport: transport)
        defer { if chat.running { chat.stop() } }
        chat.send("Find the draft and focus its field in the right pane", inSplitView: true)

        for _ in 0..<100 where !chat.waitingForSplitView { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(chat.waitingForSplitView, chat.savedCalls.map(\.answer).joined(separator: "\n"))
        XCTAssertEqual(server.requests.count, 2)
        XCTAssertEqual(transport.taps, 0)

        transport.change(to: .otherPair)
        for _ in 0..<80 where !transport.rejectedPairWasSeen { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(transport.rejectedPairWasSeen)
        XCTAssertTrue(chat.waitingForSplitView)
        XCTAssertEqual(transport.taps, 0)

        transport.change(to: .rightPaneOnly)
        let partialDeadline = ContinuousClock.now + .seconds(5)
        while !transport.unreadablePaneWasSeen, ContinuousClock.now < partialDeadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(transport.unreadablePaneWasSeen)
        XCTAssertTrue(chat.waitingForSplitView)
        XCTAssertEqual(server.requests.count, 2, "One readable pane is insufficient to resume")
        XCTAssertEqual(transport.taps, 0)

        transport.change(to: .restored)
        for _ in 0..<160 where chat.running { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertFalse(chat.running)
        XCTAssertFalse(chat.waitingForSplitView)
        XCTAssertTrue(chat.entries.contains { if case .poki("Focused the field.") = $0.kind { true } else { false } })
        XCTAssertEqual(transport.taps, 1)
        XCTAssertEqual(transport.restoredSides, ["left", "right"])
        XCTAssertTrue(server.requests.contains { Self.json($0).contains("Split View was restored") })
    }

    func testSplitViewResumesWhenRotationReturnsThePairBetweenToolCalls() async throws {
        let transport = RotatingWorkspace(rotateAt: .quickPaneRead)
        let server = try FakeCompletions(replies: [
            FakeCompletions.tool("look", ["pane": "left"]),
            FakeCompletions.tool("look", ["pane": "right"]),
            FakeCompletions.text("Read both sides."),
        ])
        let chat = chat(on: server, transport: transport)
        defer { if chat.running { chat.stop() } }
        chat.send("Read the title in Safari and compare it with Notes", inSplitView: true)
        let deadline = ContinuousClock.now + .seconds(12)
        while chat.running, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertFalse(chat.running)
        XCTAssertEqual(transport.restoredSides, ["right", "left", "right"])
        XCTAssertEqual(transport.taps, 0)
        XCTAssertTrue(server.requests.contains { Self.json($0).contains("Split View was restored") })
    }

    func testSplitViewStopWhileWaitingDoesNotResumeWhenThePairReturns() async throws {
        let transport = RotatingWorkspace()
        let server = try FakeCompletions(replies: [
            FakeCompletions.tool("look", ["pane": "left"]),
            FakeCompletions.tool("look", ["pane": "right"]),
            FakeCompletions.tool("do", ["actions": [["tap": [180, 200]]]]),
        ])
        let existingActivities = Set(Activity<PokiActivityAttributes>.activities.map(\.id))
        let savedSetup = SetupState.load()
        let defaults = UserDefaults.standard
        let savedWantsOn = defaults.object(forKey: "wantsOn")
        let savedRelayEnabled = defaults.object(forKey: "relayEnabled")
        let chat = chat(on: server, transport: transport, automation: FakeAutomation())
        let app = try XCTUnwrap(self.app)
        defer {
            if chat.running { chat.stop() }
            app.stopSession()
            savedSetup.save()
            defaults.set(savedWantsOn, forKey: "wantsOn")
            defaults.set(savedRelayEnabled, forKey: "relayEnabled")
        }
        app.loopback.simulate(.working(ms: 9))
        app.setup.loopback = .proxy
        app.setRelayEnabled(false)
        app.startSession()
        XCTAssertTrue(app.sessionOn)
        // The in-process probe supplies the test transport, so no external runner needs to wake.
        app.inProcessReadyForProbe()
        app.host.setPaused(false)
        let activity = try XCTUnwrap(Activity<PokiActivityAttributes>.activities.first {
            !existingActivities.contains($0.id) && $0.activityState == .active
        }, "Starting a Poki session must create an active Live Activity")
        XCTAssertEqual(activity.content.state.phase, .idle)
        chat.send("Focus the test field in Notes after reading Safari", inSplitView: true)

        let pausedBy = ContinuousClock.now + .seconds(8)
        while !chat.waitingForSplitView, ContinuousClock.now < pausedBy { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(chat.waitingForSplitView)
        XCTAssertEqual(server.requests.count, 2)

        let workingBy = ContinuousClock.now + .seconds(5)
        while activity.content.state.phase != .working, ContinuousClock.now < workingBy {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(activity.content.state.phase, .working)
        XCTAssertEqual(activity.activityState, .active)
        chat.stop()
        transport.change(to: .restored)
        let stoppedBy = ContinuousClock.now + .seconds(8)
        while !chat.entries.contains(where: { if case .poki("Stopped.") = $0.kind { true } else { false } }),
              ContinuousClock.now < stoppedBy {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(chat.entries.contains { if case .poki("Stopped.") = $0.kind { true } else { false } })
        XCTAssertFalse(chat.running)
        XCTAssertFalse(chat.waitingForSplitView)
        XCTAssertEqual(server.requests.count, 2, "A cancelled read must never return to the model")
        XCTAssertTrue(transport.restoredSides.isEmpty, "Stop must cancel the recovery polls")
        XCTAssertEqual(transport.taps, 0)
        while Activity<PokiActivityAttributes>.activities.contains(where: { $0.id == activity.id }),
              ContinuousClock.now < stoppedBy {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertFalse(Activity<PokiActivityAttributes>.activities.contains { $0.id == activity.id },
                       "Stop must end the Live Activity started by this session")
    }

    func testSplitViewStartupReplacesADifferentExistingPair() async throws {
        let transport = RotatingWorkspace(rotateAt: .drop, startingLayout: .otherPair)
        let server = try FakeCompletions(replies: [FakeCompletions.text("SPLIT 1 2"), FakeCompletions.text("Both apps are open.")])
        let chat = chat(on: server, transport: transport, kind: .poki)
        chat.restore(SavedSession(id: UUID().uuidString, kind: .poki, title: "Duo test", started: Date(),
                                  updated: Date(), live: false,
                                  entries: [ChatEntry(.you("Prior message", delivered: true))], calls: []))

        chat.send("Compare Safari and Notes in Split View.", attachments: [])
        let deadline = ContinuousClock.now + .seconds(20)
        while chat.running, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertFalse(chat.running)
        XCTAssertTrue(transport.rejectedPairWasSeen)
        XCTAssertEqual(transport.launchEvents, ["activate Notes", "clear pane", "activate Home", "open anchor menu", "choose Split View", "activate Safari", "clear pane"])
        XCTAssertTrue(server.requests.contains { FakeCompletions.system($0).contains("two visible iPhone Split View apps") })
        XCTAssertTrue(chat.entries.contains { if case .poki("Both apps are open.") = $0.kind { true } else { false } })
    }

    func testSplitViewChatInspectsTheDestinationAfterRotationDuringAnImageDrop() async throws {
        let transport = RotatingWorkspace(rotateAt: .drop)
        let drop = ["actions": [["drag": ["from": [150, 120], "to": [180, 220], "to_pane": "right"]]]]
        let server = try FakeCompletions(replies: [
            FakeCompletions.tool("look", ["pane": "right"]),
            FakeCompletions.tool("look", ["pane": "left"]),
            FakeCompletions.tool("do", drop),
            FakeCompletions.tool("look", ["pane": "right"]),
            FakeCompletions.tool("look", ["pane": "left"]),
            FakeCompletions.tool("do", drop),
            FakeCompletions.text("Verified one attachment."),
        ])
        let chat = chat(on: server, transport: transport)
        defer { if chat.running { chat.stop() } }
        chat.send("Drag the test photo from Safari into Notes and check the attachment count", inSplitView: true)

        let pausedBy = ContinuousClock.now + .seconds(8)
        while !chat.waitingForSplitView, ContinuousClock.now < pausedBy { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(chat.waitingForSplitView, chat.savedCalls.map(\.answer).joined(separator: "\n"))
        XCTAssertEqual(transport.drags, 1)
        XCTAssertEqual(server.requests.count, 3, "The model must wait while the panes are hidden")

        transport.change(to: .restored)
        // Four pane reads, each with a screenshot, can take longer on a busy simulator.
        let resumedBy = ContinuousClock.now + .seconds(30)
        while chat.running, ContinuousClock.now < resumedBy { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertFalse(chat.running)
        XCTAssertFalse(chat.waitingForSplitView)
        XCTAssertEqual(transport.restoredSides, ["right", "left", "right", "left"])
        XCTAssertEqual(transport.drags, 1)
        let requests = server.requests.map(Self.json)
        guard requests.count == 7 else { return XCTFail("Expected seven model requests, got \(requests.count)") }
        XCTAssertTrue(requests[3].contains("Split View was restored"))
        XCTAssertTrue(requests[3].contains("Check what actually happened"))
        XCTAssertTrue(requests[4].contains("Attachment count: 1"))
        XCTAssertTrue(requests[4].contains("Do not repeat the drag"))
        XCTAssertTrue(requests[6].contains("interrupted drags are not replayed"))
    }

    /// A note the agent saved during one task reaches the model with the next task of the same
    /// conversation.
    func testEachTaskTellsTheModelWhatMemoryHolds() async throws {
        let note = "The sample document identifier is \(UUID().uuidString.prefix(6))"
        notes.append(note)
        let done = FakeCompletions.tool("finish_task", ["success": true, "summary": "Done.", "details": [], "answer": ["kind": "action"]])
        let server = try FakeCompletions(replies: [
            FakeCompletions.tool("routines", ["action": "remember", "text": note]), done, FakeCompletions.text("Noted."),
            done, FakeCompletions.text("Read the identifier."),
        ])
        let chat = chat(on: server)

        _ = await chat.runDelegated("Remember the sample document's identifier")
        _ = await chat.runDelegated("What is the sample document identifier?")

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

        _ = await chat.runDelegated("What is the sample document identifier? for tomorrow morning, the early one")
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
        // The waits run in PokiCore. Keep the surrounding screen reads independent of XCTest's screenshot authorization.
        let chat = chat(on: server, transport: RotatingWorkspace())
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

    func testSplitViewRefusesInputBeforeAnExplicitPaneRead() async throws {
        let server = try FakeCompletions(replies: [
            FakeCompletions.tool("do", ["actions": [["launch": "com.apple.Preferences"]]]),
            FakeCompletions.tool("look", [:]),
            FakeCompletions.text("Please restore the workspace."),
        ])
        let chat = chat(on: server)

        chat.send("Read the left app and write in the right app", inSplitView: true)
        let deadline = ContinuousClock.now + .seconds(12)
        while chat.running, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }

        XCTAssertFalse(chat.running)
        XCTAssertEqual(chat.savedCalls.map(\.name), ["do", "look"])
        XCTAssertTrue(chat.savedCalls.allSatisfy { !$0.ok && $0.answer.hasPrefix("not_sent:") })
        let request = try XCTUnwrap(server.requests.first)
        let prompt = FakeCompletions.system(request)
        XCTAssertTrue(prompt.contains("two visible iPhone Split View apps"))
        XCTAssertFalse(prompt.contains("web_open"))
        let offered = (request["tools"] as? [[String: Any]] ?? []).compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        XCTAssertEqual(Set(offered), ["look", "do", "status", "report_plan", "finish_task"])
    }

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
    private var bodies: [[String: Any]] = []

    var port: UInt16 { listener.port?.rawValue ?? 0 }
    var requests: [[String: Any]] { lock.withLock { bodies } }

    init(replies: [String]) throws {
        self.replies = replies
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
            if let body = Self.body(received) { return self.answer(connection, body) }
            if done || error != nil { return connection.cancel() }
            self.read(connection, received)
        }
    }

    /// The request's body once all of it is in.
    private static func body(_ data: Data) -> Data? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[..<end.lowerBound], as: UTF8.self).lowercased()
        let length = head.split(separator: "\r\n").first { $0.hasPrefix("content-length:") }
            .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
        let body = data[end.upperBound...]
        return body.count >= length ? Data(body.prefix(length)) : nil
    }

    private func answer(_ connection: NWConnection, _ body: Data) {
        let events = lock.withLock { () -> String in
            if let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] { bodies.append(json) }
            return replies.isEmpty ? Self.text("No more scripted turns.") : replies.removeFirst()
        }
        let head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: \(events.utf8.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data((head + events).utf8), completion: .contentProcessed { _ in connection.cancel() })
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

/// Reports the same pane metadata and call sequence as the device transport, with controlled layout changes.
private final class RotatingWorkspace: HTTPTransport, @unchecked Sendable {
    enum Layout { case original, portrait, otherPair, rightPaneOnly, restored }
    enum RotateAt { case paneRead, quickPaneRead, drop }
    let usesDynamicScreenSize = true
    let supportsPaneSelection = true
    private let lock = NSLock()
    private let screenshot: String
    private let rotateAt: RotateAt
    private var layout: Layout
    private var side = "left"
    private var reads: [String] = []
    private var sawOther = false
    private var sawUnreadable = false
    private var inputs = 0
    private var drops = 0
    private var launchLog: [String] = []

    @MainActor init(rotateAt: RotateAt = .paneRead, startingLayout: Layout = .original) {
        self.rotateAt = rotateAt
        self.layout = startingLayout
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 390, height: 600))
        screenshot = renderer.pngData { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 390, height: 600))
        }.base64EncodedString()
    }

    func change(to layout: Layout) { lock.withLock { self.layout = layout } }
    var restoredSides: [String] { lock.withLock { reads } }
    var rejectedPairWasSeen: Bool { lock.withLock { sawOther } }
    var unreadablePaneWasSeen: Bool { lock.withLock { sawUnreadable } }
    var taps: Int { lock.withLock { inputs } }
    var drags: Int { lock.withLock { drops } }
    var launchEvents: [String] { lock.withLock { launchLog } }

    private var app: String { side == "left" ? "com.apple.mobilesafari" : "com.apple.mobilenotes" }
    private var other: String { side == "left" ? "com.apple.mobilenotes" : "com.apple.mobilesafari" }

    func send(method: String, url: URL, body: Data?, timeout: Double) async throws -> (status: Int, body: Data) {
        let raw = url.path.replacingOccurrences(of: #"^/session/[^/]+"#, with: "", options: .regularExpression)
        let path = raw.isEmpty ? "/session" : raw
        return try lock.withLock {
            func reply(_ value: JSON = .null, status: Int = 200) -> (Int, Data) {
                (status, (["value": value] as JSON).data())
            }
            switch (method, path) {
            case ("POST", "/session"): return reply(["sessionId": "rotation-test"])
            case ("GET", "/status"): return reply(["ready": true])
            case ("GET", "/wda/locked"): return reply(false)
            case ("GET", "/wda/activeAppInfo"): return reply(["bundleId": .string(app)])
            case ("GET", "/wda/screen"): return reply(["screenSize": ["width": 390, "height": 600]])
            case ("GET", "/screenshot"):
                if layout == .rightPaneOnly && side == "left" {
                    sawUnreadable = true
                    return reply(["error": "unable to capture screen"], status: 500)
                }
                return reply(.string(screenshot))
            case ("GET", "/source"):
                let contents = side == "right"
                    ? #"<XCUIElementTypeStaticText type="XCUIElementTypeStaticText" label="Attachment count: \#(drops)" x="80" y="80" width="210" height="44"/>"#
                    : #"<XCUIElementTypeImage type="XCUIElementTypeImage" label="Test photo" x="90" y="60" width="120" height="140"/>"#
                return reply(.string("""
                    <XCUIElementTypeApplication type="XCUIElementTypeApplication" x="0" y="0" width="390" height="600">
                    \(contents)
                    <XCUIElementTypeTextField type="XCUIElementTypeTextField" label="Draft field" x="100" y="180" width="160" height="44"/>
                    </XCUIElementTypeApplication>
                    """))
            case ("POST", "/poki/pane"):
                let requested = body.flatMap { try? JSON.parse($0)["side"]?.string } ?? "left"
                if requested == "auto" { launchLog.append("clear pane"); return reply() }
                if layout == .original && requested == "right" && rotateAt != .drop {
                    layout = rotateAt == .quickPaneRead ? .restored : .portrait
                }
                if layout == .portrait {
                    return reply(["error": "invalid argument", "message": "two visible apps could not be confirmed"], status: 400)
                }
                side = requested
                if layout == .otherPair { sawOther = true }
                if layout == .restored { reads.append(requested) }
                return reply(["identity": .string("\(side)/\(layout)"), "bundleId": .string(app),
                              "otherBundleId": .string(layout == .otherPair ? "local.weather" : other),
                              "x": side == "left" ? 0 : 390, "y": 0])
            case ("POST", "/wda/tap"), ("POST", "/actions"):
                inputs += 1
                return reply()
            case ("POST", "/poki/workspace-drag"):
                drops += 1
                layout = .portrait
                throw TransportError.other("sent, no confirmation: split_view_changed_after_dispatch")
            case ("POST", "/wda/apps/activate"):
                switch body.flatMap({ try? JSON.parse($0)["bundleId"]?.string }) {
                case "com.apple.mobilenotes": launchLog.append("activate Notes")
                case "com.apple.springboard": launchLog.append("activate Home")
                case "com.apple.mobilesafari": launchLog.append("activate Safari"); layout = .restored
                default: return reply(["error": "unexpected app"], status: 400)
                }
                return reply()
            case ("POST", "/poki/workspace-launcher"):
                let menu = body.flatMap { try? JSON.parse($0)["menu"]?.bool } ?? false
                launchLog.append(menu ? "choose Split View" : "open anchor menu")
                return reply(true)
            case ("POST", "/appium/settings"), ("DELETE", "/session"): return reply()
            default: return reply(["error": "unknown command", "message": .string(path)], status: 404)
            }
        }
    }
}
