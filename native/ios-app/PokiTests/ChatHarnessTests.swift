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
    private static let settings = ["chat.provider", "chat.customURL", "chat.customModel", "custom.providers", "chat.customProvider", "chat.model.custom"]

    override func setUp() async throws {
        for key in Self.settings { saved[key] = UserDefaults.standard.object(forKey: key) }
        await SessionStore.shared.waitUntilLoaded()
    }

    override func tearDown() async throws {
        for key in Self.settings { UserDefaults.standard.set(saved[key] ?? nil, forKey: key) }
        for text in notes { _ = await app?.runTool("skills", arguments: Self.json(["action": "forget_note", "id": text])) }
        ChatModel.afterTask = nil
    }

    /// A conversation handed over by an outside agent, on the fake endpoint. The phone's tools answer
    /// without a session (the Debug probe's call), so routines reaches the app's own memory.
    private func chat(on server: FakeCompletions, transport: HTTPTransport? = nil,
                      automation: InProcessAutomation = PKInProcess.shared(), kind: SavedSession.Kind = .handoff, readyForProbe: Bool = true) -> ChatModel {
        ModelKeys.customURL = "http://127.0.0.1:\(server.port)/v1"
        ModelKeys.customModel = "fake-model"
        ModelKeys.selectedProvider = .custom
        let app = AppModel(launcher: FakeLauncher(), pairer: FakePairing(), automation: automation, transport: transport)
        if readyForProbe { app.inProcessReadyForProbe() }
        self.app = app
        return ChatModel(app: app, kind: kind, requester: kind == .handoff ? "Test agent" : nil)
    }

    private static func json(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    func testExistingConversationUsesTheNewCustomEndpointForTheSameModel() async throws {
        let done = FakeCompletions.tool("finish_task", ["success": true, "summary": "Done."])
        let first = try FakeCompletions(replies: [done, FakeCompletions.text("First endpoint.")])
        let second = try FakeCompletions(replies: [done, FakeCompletions.text("Second endpoint.")])
        let chat = chat(on: first)
        _ = await chat.runDelegated("First request")
        XCTAssertEqual(first.requests.count, 2)

        ModelKeys.customURL = "http://127.0.0.1:\(second.port)/v1"
        _ = await chat.runDelegated("Second request")
        XCTAssertEqual(first.requests.count, 2)
        XCTAssertEqual(second.requests.count, 2)
    }

    func testStoppingATaskShowsStoppedInChatAndLiveActivity() async throws {
        let plan = FakeCompletions.tool("report_plan", ["steps": ["Review the sample checklist"], "currentStep": 1])
        let server = try FakeCompletions(replies: [plan, FakeCompletions.text("The checklist is ready.")], holdAfter: 1)
        let chat = chat(on: server, automation: FakeAutomation(), kind: .poki)
        let app = try XCTUnwrap(app)
        let savedSetup = SetupState.load()
        let defaults = UserDefaults.standard
        let savedWantsOn = defaults.object(forKey: "wantsOn")
        let savedRelayEnabled = defaults.object(forKey: "relayEnabled")
        let existingActivities = Set(Activity<PokiActivityAttributes>.activities.map(\.id))
        defer {
            server.release()
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
        chat.newConversation()
        chat.send("Review the sample checklist")

        let runningBy = ContinuousClock.now + .seconds(8)
        while server.requests.count < 2, ContinuousClock.now < runningBy {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(server.requests.count, 2, "Stop must interrupt the task after it publishes the plan")
        XCTAssertTrue(chat.running)
        let activity = try XCTUnwrap(Activity<PokiActivityAttributes>.activities.first { !existingActivities.contains($0.id) })
        chat.stop()

        let stoppedBy = ContinuousClock.now + .seconds(4)
        while activity.content.state.face.content != "Stopped", ContinuousClock.now < stoppedBy {
            try await Task.sleep(for: .milliseconds(50))
        }
        let entry = try XCTUnwrap(chat.entries.last { if case .plan = $0.kind { true } else { false } })
        guard case .plan(let steps) = entry.kind else { return XCTFail("The task card disappeared") }
        XCTAssertFalse(steps.contains { $0.state == .done }, "Stopping must leave the unfinished step unchecked")
        XCTAssertTrue(chat.entries.contains { if case .poki("Stopped.") = $0.kind { true } else { false } })
        XCTAssertEqual(activity.content.state.face.content, "Stopped")
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
        while activity.content.state.phase != .stopped, ContinuousClock.now < stoppedBy {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(activity.content.state.phase, .stopped, "Stop must replace the active Split View task with its outcome")
    }

    func testSplitViewPreparationStopsWhenActivationReportsAuthorizationCancellation() async throws {
        try await assertSplitViewPreparationStops(cancelDuringConfirmation: false)
    }

    func testSplitViewPreparationStopsWhenConfirmationReportsAuthorizationCancellation() async throws {
        try await assertSplitViewPreparationStops(cancelDuringConfirmation: true)
    }

    private func assertSplitViewPreparationStops(cancelDuringConfirmation: Bool) async throws {
        let transport = RotatingWorkspace(startingLayout: .otherPair)
        let server = try FakeCompletions(replies: [FakeCompletions.text("SPLIT 1 2"), FakeCompletions.text("The task continued.")])
        let chat = chat(on: server, transport: transport, kind: .poki)
        let host = try XCTUnwrap(app).host
        let declined = RunnerState.automationAuthorizationDeclined("the owner cancelled automation authorization", fix: nil)
        if cancelDuringConfirmation {
            transport.onNotesActivated = { host.update(runner: declined) }
        } else {
            host.update(runner: declined)
        }
        chat.restore(SavedSession(id: UUID().uuidString, kind: .poki, title: "Duo test", started: .now,
                                  updated: .now, live: false,
                                  entries: [ChatEntry(.you("Earlier message", delivered: true))], calls: []))
        let marker = UUID().uuidString
        AppLog.shared.add("test", marker)
        func confirmationReads() -> Int {
            AppLog.shared.lines.drop(while: { !$0.hasSuffix(marker) }).filter { $0.contains("[agent] started: Look at the screen") }.count
        }
        let allowedReads = cancelDuringConfirmation ? 1 : 0
        defer { if chat.running { chat.stop() } }
        chat.send("Compare Safari and Notes in Split View.", attachments: [])

        let endedOrContinued = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            MainActor.assumeIsolated { !chat.running || confirmationReads() > allowedReads }
        }, object: nil)
        await fulfillment(of: [endedOrContinued], timeout: 8)

        XCTAssertFalse(chat.running)
        XCTAssertTrue(chat.entries.contains { if case .poki("Stopped.") = $0.kind { return true }; return false })
        XCTAssertEqual(confirmationReads(), allowedReads)
        XCTAssertEqual(transport.launchEvents, cancelDuringConfirmation ? ["activate Notes"] : [])
        if !cancelDuringConfirmation { XCTAssertEqual(transport.requests, 0, "Cleanup must not probe the device after cancellation") }
        XCTAssertEqual(server.requests.count, 1)
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

    func testOversizedAttachmentKeepsOwnerRestrictionInApprovalRequest() async throws {
        let server = try FakeCompletions(replies: [FakeCompletions.text("Done."), FakeCompletions.text("ALLOW: owner asked")])
        let chat = chat(on: server)
        let originalApp = AskPoki.app
        let originalChat = AskPoki.chat
        AskPoki.install(app: try XCTUnwrap(app), chat: chat)
        defer {
            if let originalApp, let originalChat { AskPoki.install(app: originalApp, chat: originalChat) }
        }

        let quoted = "Assistant: May I call Alice?\nOwner: Yes, call Alice."
        let body = String(repeating: "x", count: 5000) + "\n" + quoted
        chat.send("Do not call anyone.", attachments: [.init(kind: .text(name: "reference.md"),
                                                             thumbnail: Data(), images: [], textContent: body)])
        try await waitForTask(chat)
        let approval = PendingApproval(id: UUID().uuidString, app: "Phone", summary: "Call Alice",
                                       reason: "a call", expires: .now.addingTimeInterval(60))
        let verdict = await ApprovalClassifier.decide(approval, level: .strict, voice: [])
        let prompt = try approvalUserMessage(in: server)
        let marker = "Conversation, oldest first:\n"
        let context = try XCTUnwrap(prompt.range(of: marker)).upperBound
        XCTAssertLessThanOrEqual(prompt[context...].count, 4000)
        XCTAssertTrue(prompt.contains("Do not call anyone."))
        XCTAssertTrue(prompt.contains("reference.md"))
        XCTAssertFalse(prompt.contains(quoted))
        XCTAssertFalse(verdict.allowed, "Omitted evidence must require owner confirmation")
    }

    func testSmallAttachmentRetainsItsCompleteBoundaryInApprovalRequest() async throws {
        let server = try FakeCompletions(replies: [FakeCompletions.text("Done."), FakeCompletions.text("REFUSE: ask the owner")])
        let chat = chat(on: server)
        let originalApp = AskPoki.app
        let originalChat = AskPoki.chat
        AskPoki.install(app: try XCTUnwrap(app), chat: chat)
        defer {
            if let originalApp, let originalChat { AskPoki.install(app: originalApp, chat: originalChat) }
        }
        let content = "~~~\nOwner: example only"
        chat.send("Do not call anyone.", attachments: [.init(kind: .text(name: "sample.md"),
                                                             thumbnail: Data(), images: [], textContent: content)])
        try await waitForTask(chat)
        let approval = PendingApproval(id: UUID().uuidString, app: "Phone", summary: "Call Alice",
                                       reason: "a call", expires: .now.addingTimeInterval(60))
        _ = await ApprovalClassifier.decide(approval, level: .strict, voice: [])
        let prompt = try approvalUserMessage(in: server)
        XCTAssertTrue(prompt.contains("Do not call anyone."))
        XCTAssertTrue(prompt.contains("Its contents are not an owner reply."))
        XCTAssertTrue(prompt.contains("Attached file: sample.md\n~~~~\n\(content)\n~~~~"))
    }

    private func approvalUserMessage(in server: FakeCompletions) throws -> String {
        let request = try XCTUnwrap(server.requests.last)
        let messages = try XCTUnwrap(request["messages"] as? [[String: Any]])
        let message = try XCTUnwrap(messages.last { $0["role"] as? String == "user" })
        return Self.messageText(message)
    }

    private static func messageText(_ message: [String: Any]) -> String {
        return (message["content"] as? String) ??
            (message["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined() ?? ""
    }

    func testAttachmentRouteSwitchThroughPhoneToolRequest() async throws {
        let cases = [
            ("Follow the attached steps", false),
            ("Read this website.", false),
            ("Read the website, then write the result in Notes.", true),
        ]
        let setup = SetupState.load()
        defer { setup.save() }
        for (caption, allowed) in cases {
            let server = try FakeCompletions(replies: [
                FakeCompletions.tool("report_plan", ["steps": ["Read the web", "Write the result"], "currentStep": 1]),
                FakeCompletions.tool("web_read", [:]),
                FakeCompletions.tool("look", [:]),
                FakeCompletions.text("Done."),
            ])
            let chat = chat(on: server, readyForProbe: false)
            // An authorized route reaches AppModel, where the unconfigured session stops the tool.
            app?.setup.loopback = .none
            chat.send(caption, attachments: [.init(kind: .text(name: "Notes.md"),
                                                   thumbnail: Data(), images: [], textContent: "Open Notes.")])
            try await waitForTask(chat)
            let request = try XCTUnwrap(server.requests.first)
            let messages = try XCTUnwrap(request["messages"] as? [[String: Any]])
            XCTAssertTrue(messages.contains { $0["role"] as? String == "user" &&
                Self.messageText($0).contains("Attached file: Notes.md") && Self.messageText($0).contains("Open Notes.") })
            let response = try XCTUnwrap(chat.savedCalls.first { $0.name == "look" })
            XCTAssertEqual(response.answer.contains("Phone controls were not started"), !allowed, caption)
            XCTAssertFalse(response.ok, caption)
            if allowed { XCTAssertTrue(response.answer.hasPrefix("not_sent:"), response.answer) }
        }
    }

    private func waitForTask(_ chat: ChatModel) async throws {
        defer { chat.stop() }
        let deadline = ContinuousClock.now + .seconds(10)
        while chat.running, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(chat.running, "Scripted task did not finish")
    }

    func testCancellingADelegationStopsItsChat() async throws {
        let started = expectation(description: "Delegated request reached HTTP transport")
        let server = try FakeCompletions(replies: [
            FakeCompletions.text("Late reply."),
            FakeCompletions.text("Next reply."),
        ], holdFirstReply: { started.fulfill() })
        let chat = chat(on: server)
        let run = Task { await chat.runDelegated("Wait for a reply") }
        await fulfillment(of: [started], timeout: 5)
        XCTAssertTrue(chat.running)

        run.cancel()
        let reply = await run.value
        XCTAssertFalse(chat.running)
        XCTAssertNil(ChatModel.delegatedBusy)
        XCTAssertEqual(reply.success, false)
        XCTAssertTrue(reply.text.contains("Stopped."), reply.text)
        XCTAssertFalse(chat.entries.contains { if case .poki("Late reply.") = $0.kind { return true }; return false })

        let next = await chat.runDelegated("Try again")
        XCTAssertTrue(next.text.contains("Next reply."), next.text)
        XCTAssertEqual(server.requests.count, 2)
    }

    func testDelegationPropagatesModelError() async throws {
        let server = try FakeCompletions(replies: [], responseStatus: "401 Unauthorized")
        let chat = chat(on: server)
        let reply = await chat.runDelegated("Report a model error")

        XCTAssertTrue(reply.text.contains("error:"), reply.text)
        XCTAssertNotEqual(reply.success, true)
        XCTAssertFalse(chat.running)
        XCTAssertNil(ChatModel.delegatedBusy)
    }

    func testAlreadyCancelledDelegationDoesNotStartAChat() async throws {
        let server = try FakeCompletions(replies: [FakeCompletions.text("Should not run.")])
        let chat = chat(on: server)
        let run = Task { await chat.runDelegated("Do not start") }
        run.cancel()

        let reply = await run.value

        XCTAssertEqual(reply.success, false)
        XCTAssertFalse(chat.running)
        XCTAssertNil(ChatModel.delegatedBusy)
        XCTAssertTrue(chat.entries.isEmpty)
        XCTAssertTrue(server.requests.isEmpty)
    }

    /// A note the agent saved during one task reaches the model with the next task of the same
    /// conversation.
    func testEachTaskTellsTheModelWhatMemoryHolds() async throws {
        let note = "The sample document identifier is \(UUID().uuidString.prefix(6))"
        notes.append(note)
        let done = FakeCompletions.tool("finish_task", ["success": true, "summary": "Done.", "details": [], "answer": ["kind": "action"]])
        let server = try FakeCompletions(replies: [
            FakeCompletions.tool("skills", ["action": "remember", "text": note]), done, FakeCompletions.text("Noted."),
            done, FakeCompletions.text("Read the identifier."),
        ])
        let chat = chat(on: server)

        _ = await chat.runDelegated("Remember the sample document's identifier")
        _ = await chat.runDelegated("What is the sample document identifier?")

        let requests = server.requests
        XCTAssertEqual(requests.count, 5)
        XCTAssertFalse(FakeCompletions.system(requests[0]).contains(note))
        XCTAssertTrue(FakeCompletions.system(requests[3]).contains(note), "the second task's prompt has the note the first saved")
        // The note keeps the conversation it was heard in: the Memory page's source links back to it.
        XCTAssertEqual(RoutineStore.shared.note(note)?.heard?.session, chat.sessionID)
    }

    func testFailedTaskDoesNotSaveItsRecordedStepsOrMemory() async throws {
        let name = "Incomplete skill \(UUID().uuidString)"
        let note = "Unverified detail \(UUID().uuidString)"
        defer {
            SkillStore.shared.forget(name)
            SkillStore.shared.forgetNote(note)
        }
        let automation = FakeAutomation()
        _ = automation.prepare()
        let transport = SessionScreenTransport(session: automation, screenLabel: { "Settings" })
        let server = try FakeCompletions(replies: [
            FakeCompletions.tool("do", ["actions": [["wait": 0]]]),
            FakeCompletions.tool("skills", ["action": "save", "name": name]),
            FakeCompletions.tool("skills", ["action": "remember", "text": note]),
            FakeCompletions.tool("finish_task", ["success": false, "summary": "The requested screen could not be verified.", "details": [], "answer": ["kind": "field"]]),
            FakeCompletions.text("I could not verify the requested screen."),
        ])
        let chat = chat(on: server, transport: transport, automation: automation)

        let result = await chat.runDelegated("Verify a setting and keep the confirmed procedure.")
        let app = try XCTUnwrap(app)
        let saved = await app.runTool("skills", arguments: Self.json(["action": "list"]))

        XCTAssertEqual(result.success, false)
        XCTAssertFalse(saved.text.contains(name))
        XCTAssertFalse(saved.text.contains(note))
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

    /// A result card the app cannot draw costs only the card: the task's result stays, no card appears
    /// and the model is told to give the whole result in words. A card it can draw appears under the
    /// task with Poki's suggestion selected and the model adds only a conclusion; the item you select
    /// comes back with the conversation as it is saved.
    func testAResultCardTheAppCannotDrawLeavesTheWholeResultToTheReply() async throws {
        let train = Self.train, finish = Self.finishWithCard
        let server = try FakeCompletions(replies: [
            finish([train("G1", "07:00"), ["id": "G3", "title": "G3"]], "把 {title} 次发到公司差旅群"), FakeCompletions.text("G1 07:00, G3 08:00."),
            finish([train("G1", "07:00"), train("G3", "08:00")], "把 {title} 次发到公司差旅群"), FakeCompletions.text("G1 is the earliest."),
        ])
        let chat = newChat(on: server)
        var records: [TaskRecord] = []
        ChatModel.afterTask = { records.append($0) }
        let cards = { Self.cards(in: chat) }
        let ask = { (text: String) in try await Self.ask(chat, text) }

        try await ask("Find trains from Beijing to Shanghai")
        XCTAssertEqual(records.last?.result?.summary, "Found 2 trains.")
        XCTAssertEqual(cards(), [])
        guard server.requests.count == 2 else { return XCTFail("\(server.requests.count) model requests") }
        XCTAssertTrue(Self.toolAnswer(server.requests[1]).contains("give the whole result in words"), Self.toolAnswer(server.requests[1]))

        try await ask("Find trains from Beijing to Shanghai for tomorrow")
        let entry = try XCTUnwrap(cards().last)
        guard case .card(let card) = entry.kind, let next = card.next else { return XCTFail("no card") }
        guard server.requests.count == 4 else { return XCTFail("\(server.requests.count) model requests") }
        XCTAssertEqual(card.selected(entry.chosen).fill(next.say), "把 G1 次发到公司差旅群")
        XCTAssertTrue(Self.toolAnswer(server.requests[3]).contains("one plain sentence"), Self.toolAnswer(server.requests[3]))

        chat.choose("G3", on: entry.id)
        let saved = try JSONDecoder().decode([ChatEntry].self, from: JSONEncoder().encode(chat.entries))
        let reopened = try XCTUnwrap(saved.first { $0.id == entry.id })
        guard case .card(let again) = reopened.kind else { return XCTFail("the saved card") }
        XCTAssertEqual(again.selected(reopened.chosen).fill(next.say), "把 G3 次发到公司差旅群")
    }

    /// A button whose sentence names no field of the item would send the suggested train whichever
    /// train you select: such a card is not shown, and the model answers in words.
    func testAResultCardWhoseButtonIgnoresTheSelectionIsNotShown() async throws {
        let server = try FakeCompletions(replies: [
            Self.finishWithCard([Self.train("G1", "07:00"), Self.train("G3", "08:00")], "把 G1 次发到公司差旅群"),
            FakeCompletions.text("G1 07:00, G3 08:00."),
        ])
        let chat = newChat(on: server)

        try await Self.ask(chat, "Find trains from Beijing to Shanghai")
        XCTAssertEqual(Self.cards(in: chat), [])
        guard server.requests.count == 2 else { return XCTFail("\(server.requests.count) model requests") }
        XCTAssertTrue(Self.toolAnswer(server.requests[1]).contains("give the whole result in words"), Self.toolAnswer(server.requests[1]))
    }

    /// A query with a single train ("the first high-speed train tomorrow") still gets the train card, as
    /// on the test phone where the model answered it with fields and no card (ESP-997). The arguments are
    /// that session's own finish_task, with the card a one-train result now carries; the card tool the
    /// model sees must not demand two items either.
    func testASingleTrainResultShowsTheTrainCard() async throws {
        let finish = FakeCompletions.tool("finish_task", [
            "success": true,
            "summary": "明天11月20日最早的高铁是G532，上海虹桥06:31出发，北京南12:18到达，历时5小时47分，576元起；二等座有票。",
            "details": [
                ["label": "日期", "value": "11月20日 周五"],
                ["label": "车次", "value": "复兴号智能动车组G 5 3 2次列车6点31分从上海虹桥出发,12点18分到达北京南,历时5小时47分,,静音车厢，"],
                ["label": "票价", "value": "576元起"],
                ["label": "余票", "value": "G 5 3 2次列车二等席位有票"],
            ],
            "answer": ["kind": "field", "items": [["field": "label", "ref": "28"], ["field": "label", "ref": "30"], ["field": "label", "ref": "31"]]],
            "card": ["app": "cn.12306.rails12306", "kind": "12306.trains", "recommended": "G532",
                     "items": [["id": "G532", "title": "G532", "date": "11月20日 周五", "from": "上海虹桥", "to": "北京南", "depart": "06:31",
                                "arrive": "12:18", "duration": "5小时47分", "price": "¥576", "seats": [["name": "二等座", "left": "有"]]]],
                     "primary": ["label": "在 12306 查看", "say": "在 12306 打开 {date} {title} 次（{from} {depart} 开）"]],
        ])
        let server = try FakeCompletions(replies: [finish, FakeCompletions.text("这是明天最早的一班。")])
        let chat = newChat(on: server)

        try await Self.ask(chat, "打开12306看一下明天上海到北京的第一班高铁")
        let entry = try XCTUnwrap(Self.cards(in: chat).last)
        guard case .card(let card) = entry.kind else { return XCTFail("no card") }
        XCTAssertEqual(card.selected(entry.chosen).fill(card.primary.say), "在 12306 打开 11月20日 周五 G532 次（上海虹桥 06:31 开）")

        let items = try XCTUnwrap(((Harness.finishTask.schema["properties"] as? [String: Any])?["card"] as? [String: Any])
            .flatMap { ($0["properties"] as? [String: Any])?["items"] as? [String: Any] })
        XCTAssertLessThanOrEqual(items["minItems"] as? Int ?? 0, 1)
    }

    /// An in-app chat that starts empty: a new one opens on the last conversation saved by an earlier test.
    private func newChat(on server: FakeCompletions) -> ChatModel {
        let chat = chat(on: server, kind: .poki)
        chat.newConversation()
        return chat
    }

    private static func train(_ number: String, _ depart: String) -> [String: Any] {
        ["id": number, "title": number, "date": "11月20日 周四", "from": "北京南", "to": "上海虹桥", "depart": depart,
         "arrive": "12:28", "price": "¥626", "seats": [["name": "二等座", "left": "有"]]]
    }

    private static func finishWithCard(_ items: [[String: Any]], _ nextSay: String) -> String {
        FakeCompletions.tool("finish_task", [
            "success": true, "summary": "Found 2 trains.", "details": [["label": "G1", "value": "07:00"]], "answer": ["kind": "list"],
            "card": ["app": "cn.12306.rails12306", "kind": "12306.trains", "recommended": "G1", "items": items,
                     "primary": ["label": "在 12306 查看", "say": "在 12306 打开 {title} 次"],
                     "next": ["label": "发到公司差旅群", "say": nextSay]],
        ])
    }

    private static func cards(in chat: ChatModel) -> [ChatEntry] {
        chat.entries.filter { if case .card = $0.kind { true } else { false } }
    }

    /// Sends a message and waits for its task to end.
    private static func ask(_ chat: ChatModel, _ text: String) async throws {
        chat.send(text)
        for _ in 0..<200 where chat.running { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertFalse(chat.running)
    }

    /// The tool answer the model was given last in a request.
    private static func toolAnswer(_ request: [String: Any]) -> String {
        let messages = request["messages"] as? [[String: Any]] ?? []
        guard let tool = messages.last(where: { $0["role"] as? String == "tool" }) else { return "" }
        return (tool["content"] as? String) ?? json(tool)
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
        let gate = ChatTransportGate()
        let session = FakeAutomation()
        _ = session.prepare()
        let transport = SessionScreenTransport(session: session) { await gate.holdFirstRequest() }
        let chat = chat(on: server, transport: transport)
        defer { Task { await gate.release() } }
        func said() -> [String] { chat.entries.compactMap { if case .poki(let text) = $0.kind { text } else { nil } } }

        chat.send("Wait on the phone")
        try await waitForTransport(gate, chat: chat)
        let stopped = ContinuousClock.now
        chat.stop()
        XCTAssertEqual(said().last, AppLocalization.text(LocalizedStringResource("Stopping…")))
        await gate.release()
        while chat.savedCalls.isEmpty, ContinuousClock.now - stopped < .seconds(20) { try await Task.sleep(for: .milliseconds(100)) }
        let after = ContinuousClock.now - stopped
        XCTAssertLessThan(after, .seconds(3), "the do call ended \(after) after Stop")
        while said().last != AppLocalization.text(LocalizedStringResource("Stopped.")), ContinuousClock.now - stopped < .seconds(10) { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertEqual(said().last, AppLocalization.text(LocalizedStringResource("Stopped.")))
        XCTAssertFalse(said().contains(AppLocalization.text(LocalizedStringResource("Stopping…"))))
    }

    func testStoppedTaskKeepsItsReceiptWhenCreatingAConversation() async throws {
        try await checkStoppedTaskReceipt(switchToSavedChat: false)
    }

    func testStoppedTaskKeepsItsReceiptWhenSwitchingConversations() async throws {
        try await checkStoppedTaskReceipt(switchToSavedChat: true)
    }

    private func checkStoppedTaskReceipt(switchToSavedChat: Bool) async throws {
        let waits = Array(repeating: ["wait": 1000], count: 15)
        let server = try FakeCompletions(replies: [
            FakeCompletions.tool("do", ["actions": waits]),
            FakeCompletions.text("New reply."),
        ])
        let gate = ChatTransportGate()
        let session = FakeAutomation()
        _ = session.prepare()
        let transport = SessionScreenTransport(session: session) { await gate.holdFirstRequest() }
        let chat = chat(on: server, transport: transport)
        defer { Task { await gate.release() } }
        var records: [TaskRecord] = []
        ChatModel.afterTask = { records.append($0) }
        let store = SessionStore.shared
        let original = chat.sessionID
        defer { store.delete(original); store.delete(chat.sessionID) }

        chat.send("Old task")
        let deadline = ContinuousClock.now + .seconds(15)
        try await waitForTransport(gate, chat: chat)
        chat.stop()
        XCTAssertEqual(store.session(original)?.lastLine, AppLocalization.text(LocalizedStringResource("Stopping…")))

        if switchToSavedChat {
            let saved = SavedSession(id: UUID().uuidString, kind: .poki, client: nil, title: "Existing chat",
                                     started: Date(), updated: Date(), live: false, outcome: nil,
                                     entries: [ChatEntry(.you("Existing message", delivered: true))], calls: [])
            chat.restore(saved)
            XCTAssertEqual(chat.sessionID, saved.id)
        } else {
            chat.newConversation()
        }
        let destination = chat.sessionID
        XCTAssertNotEqual(destination, original)
        chat.send("New task")
        await gate.release()
        while ContinuousClock.now < deadline {
            if records.count == 2, store.session(original)?.lastLine == AppLocalization.text(LocalizedStringResource("Stopped.")) { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertEqual(records.map(\.session), [original, destination])
        XCTAssertEqual(records.map(\.task), ["Old task", "New task"])
        XCTAssertEqual(records.first?.calls.map(\.name), ["do"])
        XCTAssertEqual(records.last?.calls.count, 0)
        XCTAssertEqual(store.record(original).map(\.name), ["do"])
        XCTAssertTrue(store.record(destination).isEmpty)
        XCTAssertTrue(chat.savedCalls.isEmpty)
        XCTAssertEqual(store.session(original)?.outcome, .stopped)
        XCTAssertEqual(store.session(original)?.lastLine, AppLocalization.text(LocalizedStringResource("Stopped.")))
        XCTAssertEqual(store.session(destination)?.outcome, .done)
    }

    private func waitForTransport(_ gate: ChatTransportGate, chat: ChatModel) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while !(await gate.entered), chat.running, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let entered = await gate.entered
        _ = try XCTUnwrap(entered ? true : nil, "The tool must reach the runner transport. Replies: \(chat.savedCalls.map(\.answer))")
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

    func testStoppedConversationReachesModelAfterReload() async throws {
        let waiting = expectation(description: "model received the published plan")
        let ended = expectation(description: "stopped task ended")
        let firstEnded = expectation(description: "earlier task completed")
        let server = try FakeCompletions(replies: [
            FakeCompletions.text("Hello."),
            FakeCompletions.tool("report_plan", ["steps": ["Open Settings", "Inspect Wi-Fi", "Report the result"], "currentStep": 2]),
        ], holdAfter: 2) { request in
            if (request["messages"] as? [[String: Any]])?.contains(where: { $0["role"] as? String == "tool" }) == true {
                waiting.fulfill()
            }
        }
        _ = chat(on: server)
        let app = try XCTUnwrap(self.app)
        let original = ChatModel(app: app)
        original.newConversation()
        let request = "Open Settings and inspect Wi-Fi, then report what was found."
        ChatModel.afterTask = { _ in firstEnded.fulfill() }
        original.send("Say hello")
        await fulfillment(of: [firstEnded], timeout: 10)
        ChatModel.afterTask = { _ in ended.fulfill() }
        original.send(request)
        await fulfillment(of: [waiting], timeout: 10)
        SessionStore.shared.flush()
        let disk = SessionStore(folder: SessionStore.defaultFolder, defaults: .standard)
        let saved = try XCTUnwrap(disk.session(original.sessionID))
        original.stop()
        await fulfillment(of: [ended], timeout: 10)
        ChatModel.afterTask = nil
        SessionStore.shared.flush()

        XCTAssertEqual(saved.outcome, .stopped, "an interrupted live task must replace the earlier task's done outcome")
        XCTAssertTrue(saved.entries.contains { if case .you(let text, _) = $0.kind { text == request } else { false } })

        let received = expectation(description: "continuation reached model")
        let next = try FakeCompletions(replies: [FakeCompletions.text("Ready to continue.")]) { _ in received.fulfill() }
        ModelKeys.customURL = "http://127.0.0.1:\(next.port)/v1"
        let restored = ChatModel(app: app)
        restored.restore(saved)
        restored.send("继续")
        await fulfillment(of: [received], timeout: 10)
        let payload = try JSONSerialization.data(withJSONObject: try XCTUnwrap(next.requests.first))
        let sent = String(decoding: payload, as: UTF8.self)
        XCTAssertTrue(sent.contains(request), "the restored task must reach the model, not only the screen")
        XCTAssertTrue(sent.contains("Inspect Wi-Fi"), "the model needs the interrupted plan")
        restored.stop()
    }

    func testTimeQualifiedContinuationRequiresTheOwnersChoice() async throws {
        let store = SessionStore.shared
        let previous = store.sessions.filter { $0.archived == nil }.map(\.id)
        previous.forEach { store.archive($0) }
        var sessions: [String] = []
        defer {
            sessions.forEach { store.delete($0) }
            previous.forEach { store.unarchive($0) }
        }
        let tasks = ["Check the afternoon weather", "Draft the morning GitHub issue"]
        for text in tasks {
            let received = expectation(description: "original task received")
            let ended = expectation(description: "original task stopped")
            let server = try FakeCompletions(replies: [], holdAfter: 0) { _ in received.fulfill() }
            _ = chat(on: server)
            let original = ChatModel(app: try XCTUnwrap(app))
            original.newConversation()
            ChatModel.afterTask = { _ in ended.fulfill() }
            original.send(text)
            await fulfillment(of: [received], timeout: 10)
            original.stop()
            await fulfillment(of: [ended], timeout: 10)
            ChatModel.afterTask = nil
            sessions.append(original.sessionID)

            for current in [true, false] {
                for request in ["继续早晨的任务", "继续早上的任务", "繼續早上的任務", "continue this morning’s task"] {
                    let probe = ChatModel(app: try XCTUnwrap(app))
                    if current {
                        probe.restore(try XCTUnwrap(store.session(sessions[0])))
                    } else {
                        probe.newConversation()
                    }
                    probe.send(request)
                    XCTAssertFalse(probe.running, "\(request), current=\(current), candidates=\(sessions.count): ask before starting the model")
                    let question = probe.entries.compactMap { if case .poki(let text) = $0.kind { text } else { nil } }.last ?? ""
                    XCTAssertTrue(question.contains("Which task"), question)
                    for task in tasks.prefix(sessions.count) { XCTAssertTrue(question.contains(task), question) }
                    guard !probe.running else { probe.stop(); return }
                }
            }
        }
    }

    func testUnknownContinuationAsksBeforeStartingTheModel() throws {
        let server = try FakeCompletions(replies: [FakeCompletions.tool("do", ["launch": "com.apple.Preferences"])])
        _ = chat(on: server)
        let chat = ChatModel(app: try XCTUnwrap(app))
        chat.newConversation()
        chat.send("继续那个没有记录的任务")
        defer { chat.stop() }
        XCTAssertFalse(chat.running, "an unidentified task must not start a model turn")
        XCTAssertTrue(chat.entries.contains { if case .poki(let text) = $0.kind { text.contains("Which task") } else { false } },
                      "ask the owner instead of using a remembered routine")
        XCTAssertTrue(chat.savedCalls.isEmpty)
    }

    func testAmbiguousContinuationWaitsForTheOwnersChoice() async throws {
        let tasks = ["Draft the clipboard issue on GitHub", "Check tomorrow's weather in Settings"]
        var sessions: [String] = []
        for text in tasks {
            let received = expectation(description: "original task reached model")
            let ended = expectation(description: "original task stopped")
            let server = try FakeCompletions(replies: [], holdAfter: 0) { _ in received.fulfill() }
            _ = chat(on: server)
            let original = ChatModel(app: try XCTUnwrap(app))
            original.newConversation()
            ChatModel.afterTask = { _ in ended.fulfill() }
            original.send(text)
            await fulfillment(of: [received], timeout: 10)
            original.stop()
            await fulfillment(of: [ended], timeout: 10)
            ChatModel.afterTask = nil
            sessions.append(original.sessionID)
        }
        let selected = expectation(description: "chosen task reached model")
        let finished = expectation(description: "chosen task finished")
        let server = try FakeCompletions(replies: [FakeCompletions.text("Ready.")]) { _ in selected.fulfill() }
        _ = chat(on: server)
        let chat = ChatModel(app: try XCTUnwrap(app))
        chat.newConversation()
        chat.send("继续")
        XCTAssertFalse(chat.running, "multiple stopped tasks require a choice before model execution")
        let question = chat.entries.compactMap { if case .poki(let text) = $0.kind { text } else { nil } }.last ?? ""
        XCTAssertTrue(question.contains(tasks[0]) && question.contains(tasks[1]), question)
        guard !chat.running, let option = question.split(separator: "\n").first(where: { $0.contains(tasks[0]) }),
              let number = option.split(separator: ".").first else { chat.stop(); return }
        ChatModel.afterTask = { _ in finished.fulfill() }
        chat.send(String(number))
        await fulfillment(of: [selected, finished], timeout: 10)
        ChatModel.afterTask = nil
        XCTAssertEqual(chat.sessionID, sessions[0], "the owner's choice restores that conversation")
        let payload = try JSONSerialization.data(withJSONObject: try XCTUnwrap(server.requests.first))
        let sent = String(decoding: payload, as: UTF8.self)
        XCTAssertTrue(sent.contains(tasks[0]))
        XCTAssertFalse(sent.contains(tasks[1]), "the unrelated stopped task must not be sent as the selected task")
    }

    /// A task that keeps moving is never stopped for its length: 70 looks at one call, each at a screen
    /// that differs from the one before, run to the model's own answer.
    func testALongTaskThatKeepsMakingProgressRunsPastSixtyOneSteps() async throws {
        let steps = 70
        let server = try FakeCompletions(replies: (0..<steps).map { _ in FakeCompletions.tool("look", [:]) } + [FakeCompletions.text("Read every page.")])
        let session = FakeAutomation()
        _ = session.prepare()
        let chat = chat(on: server, transport: SessionScreenTransport(session: session, screenLabel: { "Page \(server.requests.count)" }))
        defer { if chat.running { chat.stop() } }

        try await run(chat, "Read the whole document page by page", within: .seconds(120))

        XCTAssertEqual(chat.savedCalls.count, steps)
        XCTAssertTrue(chat.entries.contains { if case .poki("Read every page.") = $0.kind { true } else { false } })
        XCTAssertFalse(said(chat).contains(stoppedAfter(500)) || said(chat).contains(stuckIn("Settings")), said(chat).joined(separator: "\n"))
    }

    /// The same call on the same screen six times in a row ends the task, with the app it is stuck in.
    func testTheSameCallOnTheSameScreenSixTimesEndsTheTaskAndSaysWhere() async throws {
        let launch = FakeCompletions.tool("do", ["actions": [["launch": "com.apple.Preferences"]]])
        let server = try FakeCompletions(replies: [launch] + (0..<10).map { _ in FakeCompletions.tool("look", [:]) } + [FakeCompletions.text("All done.")])
        let session = FakeAutomation()
        _ = session.prepare()
        let chat = chat(on: server, transport: SessionScreenTransport(session: session))
        defer { if chat.running { chat.stop() } }

        try await run(chat, "Open the second page of General", within: .seconds(60))

        XCTAssertEqual(chat.savedCalls.map(\.name), ["do"] + Array(repeating: "look", count: 6))
        XCTAssertEqual(said(chat).last, stuckIn("Settings"))
        XCTAssertFalse(said(chat).contains("All done."))
    }

    func testHandoffPollingTenTimesDoesNotEndTheTask() async throws {
        let handoff = FakeCompletions.tool("do", ["actions": [["handoff": ["kind": "verification", "text": "Complete verification."]]]])
        let takeBack = FakeCompletions.tool("do", ["actions": [["handoff": false]]])
        let server = try FakeCompletions(replies: [handoff] + (0..<10).map { _ in FakeCompletions.tool("look", [:]) } + [takeBack, FakeCompletions.text("Verification finished.")])
        let session = FakeAutomation()
        _ = session.prepare()
        let chat = chat(on: server, transport: SessionScreenTransport(session: session))
        defer { if chat.running { chat.stop() } }

        try await run(chat, "Wait while I complete verification", within: .seconds(60))

        XCTAssertEqual(chat.savedCalls.map(\.name), ["do"] + Array(repeating: "look", count: 10) + ["do"])
        XCTAssertEqual(said(chat).last, "Verification finished.")
        XCTAssertEqual(chat.savedCalls.filter { $0.name == "look" && $0.answer.contains("handoff: waiting") }.count, 10)
        XCTAssertTrue(chat.savedCalls.last?.answer.contains("handoff: taken back") == true)
    }

    func testAlternatingTapAndLookOnTheSameScreenEndsAfterEightSteps() async throws {
        let launch = FakeCompletions.tool("do", ["actions": [["launch": "com.apple.Preferences"]]])
        let pair = [FakeCompletions.tool("do", ["actions": [["tap": [180, 122]]]]), FakeCompletions.tool("look", [:])]
        let server = try FakeCompletions(replies: [launch] + (0..<5).flatMap { _ in pair } + [FakeCompletions.text("All done.")])
        let session = FakeAutomation()
        _ = session.prepare()
        let chat = chat(on: server, transport: SessionScreenTransport(session: session))
        defer { if chat.running { chat.stop() } }

        try await run(chat, "Open the next page in Settings", within: .seconds(60))

        XCTAssertEqual(chat.savedCalls.map(\.name), ["do"] + (0..<4).flatMap { _ in ["do", "look"] })
        XCTAssertTrue(chat.savedCalls.allSatisfy(\.ok))
        XCTAssertEqual(said(chat).last, stuckIn("Settings"))
        XCTAssertFalse(said(chat).contains("All done."))
    }

    func testAlternatingTapAndLookKeepsGoingWhenTheScreenChanges() async throws {
        let launch = FakeCompletions.tool("do", ["actions": [["launch": "com.apple.Preferences"]]])
        let pair = [FakeCompletions.tool("do", ["actions": [["tap": [180, 122]]]]), FakeCompletions.tool("look", [:])]
        let server = try FakeCompletions(replies: [launch] + (0..<5).flatMap { _ in pair } + [FakeCompletions.text("Read every page.")])
        let session = FakeAutomation()
        _ = session.prepare()
        let chat = chat(on: server, transport: SessionScreenTransport(session: session, screenLabel: { "Page \(server.requests.count)" }))
        defer { if chat.running { chat.stop() } }

        try await run(chat, "Read the next five pages in Settings", within: .seconds(60))

        XCTAssertEqual(chat.savedCalls.map(\.name), ["do"] + (0..<5).flatMap { _ in ["do", "look"] })
        XCTAssertTrue(chat.savedCalls.allSatisfy(\.ok))
        XCTAssertEqual(said(chat).last, "Read every page.")
    }

    /// The ceiling that only a runaway model reaches: 500 steps, each different, then the stop line.
    func testATaskStopsAtFiveHundredSteps() async throws {
        let server = try FakeCompletions(replies: (0..<520).map { _ in FakeCompletions.tool("look", [:]) } + [FakeCompletions.text("Never reached.")])
        let session = FakeAutomation()
        _ = session.prepare()
        let chat = chat(on: server, transport: SessionScreenTransport(session: session, screenLabel: { "Page \(server.requests.count)" }))
        defer { if chat.running { chat.stop() } }

        try await run(chat, "Keep reading forever", within: .seconds(600))

        XCTAssertEqual(chat.savedCalls.count, 500)
        XCTAssertEqual(said(chat).last, stoppedAfter(500))
    }

    private func stoppedAfter(_ steps: Int) -> String { AppLocalization.text(LocalizedStringResource("I stopped after \(steps) steps. Tell me how to go on.")) }

    private func stuckIn(_ app: String) -> String { AppLocalization.text(LocalizedStringResource("I’m stuck on the same screen in \(app). Tell me how to go on.")) }

    private func said(_ chat: ChatModel) -> [String] { chat.entries.compactMap { if case .poki(let text) = $0.kind { text } else { nil } } }

    private func run(_ chat: ChatModel, _ task: String, within limit: Duration) async throws {
        chat.send(task)
        let deadline = ContinuousClock.now + limit
        while chat.running, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertFalse(chat.running, "the task did not end within \(limit)")
    }

    /// When approvals are decided from the chat, the phone takes no tap from the owner inside Poki,
    /// so a declined step is asked about in words and sent again, never left for the owner to tap.
    func testDeclinedStepsAreAskedAboutInWordsWhenApprovalsComeFromTheChat() async throws {
        let mode = UserDefaults.standard.object(forKey: ApprovalClassifier.modeKey)
        defer { UserDefaults.standard.set(mode, forKey: ApprovalClassifier.modeKey) }
        UserDefaults.standard.set(ApprovalClassifier.Mode.reply.rawValue, forKey: ApprovalClassifier.modeKey)
        let server = try FakeCompletions(replies: [FakeCompletions.text("Which photo should I send?")])
        let chat = newChat(on: server)

        try await Self.ask(chat, "Send the latest photo to Alex")

        let prompt = FakeCompletions.system(try XCTUnwrap(server.requests.first))
        XCTAssertTrue(prompt.contains("When a step is declined, do not tell the owner to tap anything"), "the chat approval rule reaches the model")
    }

    func testThePromptNamesOnlyToolsTheModelHas() throws {
        let tools = Set(Harness.tools.map(\.name))
        let regex = try NSRegularExpression(pattern: "\\b[a-z]+(?:_[a-z]+)+\\b")
        let text = Harness.system
        XCTAssertFalse(text.isEmpty, "agent-system.md is in the app")
        let named = Set(regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text).map { String(text[$0]) } })
        XCTAssertEqual(named.subtracting(tools), [], "named in agent-system.md but not offered to the model")
    }

    func testChineseAppTaskOffersMatchingSkillInPromptAndOmitsUnrelatedSkills() async throws {
        let skillName = "查电池健康"
        let session = FakeAutomation()
        _ = session.prepare()
        let transport = SessionScreenTransport(session: session, screenLabel: { "最大容量 96%" })

        let replayStep = FakeCompletions.tool("do", ["actions": [["run": skillName]]])
        let batteryFinish = FakeCompletions.tool("finish_task", [
            "success": true,
            "summary": "电池最大容量为 96%。",
            "details": [["label": "最大容量", "value": "最大容量 96%"]],
            "answer": ["kind": "field", "items": [["ref": "1", "field": "label", "prefix": "最大容量 "]]],
        ])
        let calendarLaunch = FakeCompletions.tool("do", ["actions": [["launch": "com.apple.mobilecal"]]])
        let calendarLook = FakeCompletions.tool("look", [:])
        let calendarFinish = FakeCompletions.tool("finish_task", [
            "success": true,
            "summary": "今天没有日程安排。",
            "details": [],
            "answer": ["kind": "action"],
        ])

        let server = try FakeCompletions(replies: [
            replayStep,
            batteryFinish,
            FakeCompletions.text("电池最大容量目前是 96%。"),
            calendarLaunch,
            calendarLook,
            calendarFinish,
            FakeCompletions.text("今天没有日程安排。"),
        ])
        let chat = chat(on: server, transport: transport)
        let app = try XCTUnwrap(self.app)

        for old in ["查电池健康", "查看本机版本", "查看今日日程", "返回主屏幕"] {
            _ = await app.runTool("skills", arguments: Self.json(["action": "forget", "name": old]))
        }
        for noteID in ["n101", "n102"] {
            _ = await app.runTool("skills", arguments: Self.json(["action": "forget_note", "text": noteID]))
        }

        // Scenario (d): Legacy v1 (`poki.agent-backup/1`) routines migration & Settings > Memory UI rendering
        let legacyV1Backup = """
        {
          "schema": "poki.agent-backup/1",
          "exported": "2026-11-18T10:00:00Z",
          "routines": [
            {
              "name": "查电池健康",
              "description": "在设置里查看电池最大容量",
              "app": "com.apple.Preferences",
              "steps": [
                {
                  "action": {"tap": "@"},
                  "target": {"type": "Button", "label": "最大容量 96%", "x": 195, "y": 122},
                  "app": "com.apple.Preferences"
                }
              ],
              "params": {},
              "expect": ["最大容量 96%"],
              "read": ["最大容量"],
              "runs": 4,
              "ok": 4,
              "failuresInARow": 0,
              "lastMs": 1400,
              "savedBy": "Poki",
              "created": "2026-11-15T08:00:00Z",
              "updated": "2026-11-18T09:30:00Z"
            },
            {
              "name": "查看本机版本",
              "description": "无顶层 app，从控件步骤回填设置",
              "steps": [
                {
                  "action": {"tap": "@"},
                  "target": {"type": "Cell", "label": "关于本机", "x": 180, "y": 180},
                  "app": "com.apple.Preferences"
                }
              ],
              "params": {},
              "expect": ["iOS 版本"],
              "read": ["iOS 版本"],
              "runs": 2,
              "ok": 2,
              "failuresInARow": 0,
              "lastMs": 1100,
              "savedBy": "Poki",
              "created": "2026-11-14T08:00:00Z",
              "updated": "2026-11-18T08:30:00Z"
            },
            {
              "name": "查看今日日程",
              "description": "无顶层 app，从启动步骤回填日历",
              "steps": [
                {
                  "action": {"launch": "com.apple.mobilecal"}
                }
              ],
              "params": {},
              "expect": [],
              "read": [],
              "runs": 1,
              "ok": 1,
              "failuresInARow": 0,
              "lastMs": 800,
              "savedBy": "Claude Code",
              "created": "2026-11-13T08:00:00Z",
              "updated": "2026-11-18T07:30:00Z"
            },
            {
              "name": "返回主屏幕",
              "description": "无具体 App，归入其他",
              "steps": [
                {
                  "action": {"button": "home"},
                  "app": "com.apple.springboard"
                }
              ],
              "params": {},
              "expect": [],
              "read": [],
              "runs": 3,
              "ok": 3,
              "failuresInARow": 0,
              "lastMs": 300,
              "savedBy": "Poki",
              "created": "2026-11-12T08:00:00Z",
              "updated": "2026-11-18T06:30:00Z"
            }
          ],
          "notes": [
            {
              "id": "n101",
              "text": "美团外卖饮品默认少冰三分糖",
              "by": "owner",
              "at": "2026-11-16T12:00:00Z"
            },
            {
              "id": "n102",
              "text": "妈妈在通讯录里存的名字是 Mama",
              "by": "Poki",
              "at": "2026-11-17T15:20:00Z"
            }
          ],
          "runs": [
            {
              "routine": "查电池健康",
              "at": "2026-11-18T09:30:00Z",
              "ms": 1400,
              "outcome": "ok",
              "steps": ["1 tap"]
            }
          ]
        }
        """
        let importedLegacy = await app.runTool("skills", arguments: Self.json(["action": "import", "data": legacyV1Backup]))
        XCTAssertFalse(importedLegacy.isError, importedLegacy.text)
        XCTAssertTrue(importedLegacy.text.contains("4 skills added"), importedLegacy.text)

        let exportedV2 = await app.runTool("skills", arguments: Self.json(["action": "export"]))
        XCTAssertFalse(exportedV2.isError, exportedV2.text)
        XCTAssertTrue(exportedV2.text.contains("\"schema\" : \"poki.agent-backup/2\""), exportedV2.text)
        XCTAssertTrue(exportedV2.text.contains("\"skills\""), exportedV2.text)

        let evidenceDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MemoryMigrationEvidence")
        try FileManager.default.createDirectory(at: evidenceDir, withIntermediateDirectories: true)
        try Data(exportedV2.text.utf8).write(to: evidenceDir.appendingPathComponent("migrated-v2-poki-agent-backup.json"))

        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            let savedLang = AppLocalization.shared.preference
            let window = UIWindow(windowScene: scene)
            window.frame = scene.screen.bounds
            window.overrideUserInterfaceStyle = .light
            defer {
                window.isHidden = true
                AppLocalization.shared.preference = savedLang
            }
            for (pref, fileName) in [("zh-Hans", "memory-migrated-skills-zh.png"), ("en", "memory-migrated-skills-en.png")] {
                AppLocalization.shared.preference = pref
                let root = NavigationStack {
                    MemoryView(back: {})
                }
                .environment(\.locale, AppLocalization.locale)
                window.rootViewController = UIHostingController(rootView: root)
                window.makeKeyAndVisible()
                window.layoutIfNeeded()
                CATransaction.flush()
                try await Task.sleep(for: .milliseconds(600))
                window.layoutIfNeeded()
                CATransaction.flush()
                let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
                let png = renderer.pngData { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                try png.write(to: evidenceDir.appendingPathComponent(fileName))
            }
        }

        // Remove the 3 extra migrated skills so only "查电池健康" remains for scenarios (a) and (c)
        for extra in ["查看本机版本", "查看今日日程", "返回主屏幕"] {
            _ = await app.runTool("skills", arguments: Self.json(["action": "forget", "name": extra]))
        }
        defer {
            Task {
                for name in ["查电池健康", "查看本机版本", "查看今日日程", "返回主屏幕"] {
                    _ = await app.runTool("skills", arguments: Self.json(["action": "forget", "name": name]))
                }
                for noteText in ["美团外卖饮品默认少冰三分糖", "妈妈在通讯录里存的名字是 Mama"] {
                    _ = await app.runTool("skills", arguments: Self.json(["action": "forget_note", "text": noteText]))
                }
            }
        }

        // Scenario (a): Chinese skill selection & first-step replay
        let batteryReply = await chat.runDelegated("帮我看看手机电池现在健康度还有多少")
        XCTAssertEqual(batteryReply.success, true)
        XCTAssertTrue(batteryReply.text.contains("电池最大容量目前是 96%。"), batteryReply.text)
        XCTAssertEqual(server.requests.count, 3)

        let firstPrompt = FakeCompletions.system(server.requests[0])
        XCTAssertTrue(firstPrompt.contains("Saved skills:"), firstPrompt)
        XCTAssertTrue(firstPrompt.contains(skillName), firstPrompt)
        XCTAssertTrue(firstPrompt.contains("com.apple.Preferences"), firstPrompt)
        let offered = (server.requests[0]["tools"] as? [[String: Any]] ?? []).compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        XCTAssertTrue(offered.contains("skills"))
        XCTAssertFalse(offered.contains("routines"))
        XCTAssertEqual(chat.savedCalls.first?.name, "do")
        XCTAssertTrue(chat.savedCalls.first?.answer.contains("run \"\(skillName)\": 1 steps") == true, chat.savedCalls.first?.answer ?? "")
        XCTAssertTrue(chat.savedCalls.first?.answer.contains("read: 最大容量 = 96%") == true, chat.savedCalls.first?.answer ?? "")

        // Scenario (c): Unrelated request failure scenario (omits Saved skills, executes normal step-by-step actions)
        let callCountBeforeCalendar = chat.savedCalls.count
        let calendarReply = await chat.runDelegated("打开日历看看今天有什么安排")
        XCTAssertEqual(calendarReply.success, true)
        XCTAssertTrue(calendarReply.text.contains("今天没有日程安排。"), calendarReply.text)
        XCTAssertEqual(server.requests.count, 7)

        let unrelatedPrompt = FakeCompletions.system(server.requests[3])
        XCTAssertFalse(unrelatedPrompt.contains("Saved skills:"), unrelatedPrompt)
        XCTAssertFalse(unrelatedPrompt.contains(skillName), unrelatedPrompt)
        let calendarCalls = Array(chat.savedCalls.dropFirst(callCountBeforeCalendar))
        XCTAssertEqual(calendarCalls.map(\.name), ["do", "look", "finish_task"])
        XCTAssertTrue(calendarCalls.allSatisfy { !$0.answer.contains("run \"\(skillName)\"") })

        print("""
        MCP_ALIAS_VERIFY:
        [1] Scenario (a) Chinese phrasing: "帮我看看手机电池现在健康度还有多少"
            prompt includes Saved skills: \(firstPrompt.contains("Saved skills:"))
            step 1 do {run: "\(skillName)"} -> \(chat.savedCalls.first?.answer.split(separator: "\n").first ?? "")
        [2] Scenario (c) Unrelated request: "打开日历看看今天有什么安排"
            prompt includes Saved skills: \(unrelatedPrompt.contains("Saved skills:"))
            step-by-step calls: \(calendarCalls.map(\.name).joined(separator: " -> "))
        """)
    }
}

/// An OpenAI chat completions endpoint on 127.0.0.1: each request is kept and answered with the next
/// scripted turn as one server-sent event.
private actor ChatTransportGate {
    private(set) var entered = false
    private var released = false
    private var pending: CheckedContinuation<Void, Never>?

    func holdFirstRequest() async {
        guard !entered, !released else { return }
        entered = true
        await withCheckedContinuation { pending = $0 }
    }

    func release() {
        released = true
        pending?.resume()
        pending = nil
    }
}

final class FakeCompletions: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "fake-completions")
    private let lock = NSLock()
    private var replies: [String]
    private var bodies: [[String: Any]] = []
    private let responseStatus: String
    private let holdFirstReply: (@Sendable () -> Void)?
    private var held: [NWConnection] = []
    /// Replies held back by `holdAfter`, sent by `release()`.
    private var waiting: [(NWConnection, String)] = []
    private let holdAfter: Int?
    private let onRequest: (@Sendable ([String: Any]) -> Void)?

    var port: UInt16 { listener.port?.rawValue ?? 0 }
    var requests: [[String: Any]] { lock.withLock { bodies } }

    init(replies: [String], responseStatus: String = "200 OK", holdFirstReply: (@Sendable () -> Void)? = nil,
         holdAfter: Int? = nil, onRequest: (@Sendable ([String: Any]) -> Void)? = nil) throws {
        self.replies = replies
        self.responseStatus = responseStatus
        self.holdFirstReply = holdFirstReply
        self.holdAfter = holdAfter
        self.onRequest = onRequest
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success else { throw URLError(.cannotConnectToHost) }
    }

    deinit { listener.cancel(); held.forEach { $0.cancel() } }

    /// Sends the replies `holdAfter` held back: a model answer that comes in late.
    func release() {
        let due = lock.withLock { () -> [(NWConnection, String)] in defer { waiting = [] }; return waiting }
        queue.async {
            for (connection, events) in due {
                let head = "HTTP/1.1 \(self.responseStatus)\r\nContent-Type: text/event-stream\r\nContent-Length: \(events.utf8.count)\r\nConnection: close\r\n\r\n"
                connection.send(content: Data((head + events).utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }

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
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        // The chat's own title request: answered on the side, so it takes no scripted turn.
        if json["tools"] == nil, Self.system(json).hasPrefix("You name chat conversations") {
            let response = #"{"choices":[{"message":{"role":"assistant","content":"Test conversation"}}]}"#
            let head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(response.utf8.count)\r\nConnection: close\r\n\r\n"
            connection.send(content: Data((head + response).utf8), completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        let events = lock.withLock { () -> String in
            bodies.append(json)
            return replies.isEmpty ? Self.text("No more scripted turns.") : replies.removeFirst()
        }
        onRequest?(json)
        if let holdAfter, requests.count > holdAfter {
            lock.withLock { held.append(connection); waiting.append((connection, events)) }
            return
        }
        let head = "HTTP/1.1 \(responseStatus)\r\nContent-Type: text/event-stream\r\nContent-Length: \(events.utf8.count)\r\nConnection: close\r\n\r\n"
        if requests.count == 1, let holdFirstReply {
            holdFirstReply()
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, _, _ in connection.cancel() }
            return
        }
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
    private var requestCount = 0
    var onNotesActivated: (@Sendable () -> Void)?

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
    var requests: Int { lock.withLock { requestCount } }

    private var app: String { side == "left" ? "com.apple.mobilesafari" : "com.apple.mobilenotes" }
    private var other: String { side == "left" ? "com.apple.mobilenotes" : "com.apple.mobilesafari" }

    func send(method: String, url: URL, body: Data?, timeout: Double) async throws -> (status: Int, body: Data) {
        let raw = url.path.replacingOccurrences(of: #"^/session/[^/]+"#, with: "", options: .regularExpression)
        let path = raw.isEmpty ? "/session" : raw
        return try lock.withLock {
            requestCount += 1
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
                case "com.apple.mobilenotes":
                    launchLog.append("activate Notes")
                    onNotesActivated?()
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

final class SessionScreenTransport: HTTPTransport, @unchecked Sendable {
    private let session: FakeAutomation
    private let beforeRequest: (@Sendable () async -> Void)?
    private let screenLabel: @Sendable () -> String
    private let lock = NSLock()
    private var reads = 0
    private var firstRead: TimeInterval?
    var firstReadAt: TimeInterval? { lock.withLock { firstRead } }
    var screenReads: Int { lock.withLock { reads } }
    /// `screenLabel` is the one button the fake screen shows, read at each look.
    init(session: FakeAutomation, beforeRequest: (@Sendable () async -> Void)? = nil, screenLabel: @escaping @Sendable () -> String = { "General" }) {
        self.session = session
        self.screenLabel = screenLabel
        self.beforeRequest = beforeRequest
    }

    func send(method: String, url: URL, body: Data?, timeout: Double) async throws -> (status: Int, body: Data) {
        await beforeRequest?()
        guard session.isOpen else { throw URLError(.cannotConnectToHost) }
        let path = url.path.replacingOccurrences(of: #"^/session/[^/]+"#, with: "", options: .regularExpression)
        let value: JSON
        switch path {
        case "/session": value = ["sessionId": "fixture-session"]
        case "/status": value = ["ready": true]
        case "/wda/locked": value = false
        case "/wda/screen": value = ["screenSize": ["width": 390, "height": 844]]
        case "/wda/activeAppInfo":
            value = ["bundleId": "com.apple.Preferences", "name": "Settings"]
        case "/screenshot": value = .string("iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAADklEQVR4nGP4DwYMEAoAU7oL9ZisIGcAAAAASUVORK5CYII=")
        case "/source":
            lock.withLock {
                reads += 1
                if firstRead == nil { firstRead = ProcessInfo.processInfo.systemUptime }
            }
            value = .string(#"<AppiumAUT><XCUIElementTypeApplication name="Settings" label="Settings" x="0" y="0" width="390" height="844"><XCUIElementTypeButton name="\#(screenLabel())" label="\#(screenLabel())" x="16" y="100" width="358" height="44" /></XCUIElementTypeApplication></AppiumAUT>"#)
        default: value = .null
        }
        let response: JSON = ["value": value]
        return (200, response.data())
    }
}
