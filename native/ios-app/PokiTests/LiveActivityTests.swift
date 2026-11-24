import ActivityKit
import Darwin
import SwiftUI
import UIKit
import UserNotifications
import XCTest
@testable import Poki

@MainActor
final class LiveActivityTests: XCTestCase {
    func testSplitViewChatKeepsStopAvailableWhileWaitingForTheModel() async throws {
        let activity = ActivityController()
        activity.finishAfter = .milliseconds(20)
        activity.setChatOwnsCompletion(true)
        activity.update { $0.phase = .working; $0.headline = "Read Notes" }
        activity.record(step: "Read Notes", ok: true)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(activity.state.phase, .working)
        guard case .progress(_, true) = activity.state.face.bottom else {
            return XCTFail("An active Split View task must offer Stop")
        }
        activity.setChatOwnsCompletion(false)
        activity.finishNow(alert: false)
        XCTAssertEqual(activity.state.phase, .done)
    }

    func testStoppedRunShowsItsOutcomeBeforeReturningToIdle() async throws {
        let activity = ActivityController()
        activity.foldAfter = .milliseconds(20)
        activity.update { $0.phase = .working; $0.headline = "Read Notes" }
        XCTAssertEqual(activity.state.phase, .working)
        activity.stopRun()
        XCTAssertEqual(activity.state.face.content, "Stopped")
        let foldedBy = ContinuousClock.now + .seconds(1)
        while activity.state.phase != .idle, ContinuousClock.now < foldedBy {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(activity.state.phase, .idle)
    }

    func testNewRunAndNilThumbnailClearPreviousTaskThumbnail() {
        let activity = ActivityController()
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20))
        let jpeg = renderer.jpegData(withCompressionQuality: 0.7) { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        }

        activity.update { $0.phase = .working; $0.headline = "Open Calculator" }
        activity.setThumbnail(jpeg)
        XCTAssertTrue(activity.state.hasThumbnail)
        activity.finishNow(alert: false)
        XCTAssertEqual(activity.state.phase, .done)
        XCTAssertTrue(activity.state.hasThumbnail, "finished task keeps its final thumbnail on Done")

        activity.update { $0.phase = .working; $0.headline = "Thinking" }
        XCTAssertFalse(activity.state.hasThumbnail, "a new run must not inherit the previous task's thumbnail")
        if let url = SharedContainer.thumbnailURL {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }

        activity.setThumbnail(jpeg)
        XCTAssertTrue(activity.state.hasThumbnail)
        activity.setThumbnail(nil)
        XCTAssertFalse(activity.state.hasThumbnail, "a step without a fresh screenshot clears the thumbnail")
    }

    private var language = AppLocalization.system

    override func setUp() async throws {
        language = AppLocalization.shared.preference
        AppLocalization.shared.preference = "en"
    }

    override func tearDown() async throws { AppLocalization.shared.preference = language }

    func testAppWiringResumesDeferredActivityOnceInForeground() async throws {
        try await withSessionApp { app, activities in
            app.wentToBackground()
            app.startSession()
            XCTAssertTrue(app.sessionOn)
            XCTAssertTrue(activities().isEmpty, "Starting the session in the background must defer the activity")
            await app.chatTaskBegan()
            XCTAssertTrue(activities().isEmpty, "Live Activity updates must also wait for the foreground")

            app.becameActive()
            XCTAssertEqual(UIApplication.shared.applicationState, .active)
            let activity = try XCTUnwrap(activities().first, "Returning to Poki must start the deferred activity")
            XCTAssertEqual(activity.activityState, .active)
            XCTAssertEqual(activity.content.state.phase, .working)
            XCTAssertEqual(activity.content.state.headline, "Thinking")

            app.becameActive()
            await app.chatTaskBegan()
            XCTAssertEqual(activities().map(\.id), [activity.id])

            app.stopSession()
            XCTAssertFalse(app.sessionOn)
            for _ in 0..<100 {
                if activities().isEmpty { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertTrue(activities().isEmpty, "Stopping the session must end its activity")
        }
    }

    func testEndingDeferredRequestPreventsCreationAfterForegroundReturn() async throws {
        try await withSessionApp { app, activities in
            app.wentToBackground()
            app.startSession()
            XCTAssertTrue(app.sessionOn)
            XCTAssertTrue(activities().isEmpty, "Starting the session in the background must defer the activity")
            app.stopSession()
            XCTAssertFalse(app.sessionOn)
            app.becameActive()
            XCTAssertTrue(activities().isEmpty, "Returning to Poki after stopping must not create an activity")
        }
    }

    private func withSessionApp(
        _ test: (AppModel, @escaping () -> [Activity<PokiActivityAttributes>]) async throws -> Void
    ) async throws {
        let defaults = UserDefaults.standard
        let keys = ["relayAddress", "relayEnabled", "wantsOn"]
        let saved = keys.map { defaults.object(forKey: $0) }
        let setup = SetupState.load()
        let existingIDs = Set(Activity<PokiActivityAttributes>.activities.map(\.id))
        let automation = FakeAutomation()
        let app = AppModel(launcher: FakeLauncher(), pairer: FakePairing(), automation: automation)
        defer {
            automation.answer(nil)
            if app.sessionOn { app.stopSession() }
            for (key, value) in zip(keys, saved) { defaults.set(value, forKey: key) }
            setup.save()
        }
        app.loopback.simulate(.working(ms: 9))
        app.setup.loopback = .proxy
        XCTAssertTrue(app.setRelay("https://relay.invalid"))
        try await test(app) {
            Activity<PokiActivityAttributes>.activities.filter {
                !existingIDs.contains($0.id) && ($0.activityState == .active || $0.activityState == .stale)
            }
        }
    }

    /// The Live Activity counts the chat's plan from the first step on the phone (the chat publishes it
    /// before that step, while the activity is idle or still shows the last run as finished), and a
    /// finished run's plan never carries into the next run.
    func testTheChatsPlanCountsFromItsFirstStepAndEndsWithItsRun() {
        let chat = ActivityController()
        chat.update { $0.plan = nil }
        chat.update { $0.plan = .init(steps: ["Open Notes", "Write the list"], current: 1) }
        chat.update { $0.phase = .working; $0.caller = nil; $0.headline = "Open Notes" }
        XCTAssertEqual(chat.state.plan, .init(steps: ["Open Notes", "Write the list"], current: 1))

        // The next chat task, while the last run still shows as finished.
        chat.finishNow(alert: false)
        XCTAssertEqual(chat.state.phase, .done)
        chat.update { $0.plan = nil }
        chat.update { $0.plan = .init(steps: ["Open Clock", "Open Alarms", "Add an alarm"], current: 1) }
        chat.update { $0.phase = .working; $0.headline = "Open Clock" }
        XCTAssertEqual(chat.state.plan, .init(steps: ["Open Clock", "Open Alarms", "Add an alarm"], current: 1))

        let agent = ActivityController()
        agent.update { $0.plan = .init(steps: ["Open Notes", "Write the list"], current: 2); $0.phase = .working; $0.caller = nil }
        agent.finishNow(alert: false)
        agent.update { $0.phase = .working; $0.caller = "Claude Code"; $0.headline = "Open Notes" }
        XCTAssertNil(agent.state.plan)
    }

    func testANewRunDoesNotKeepTheLastRunsApp() {
        let controller = ActivityController()
        controller.update { $0.phase = .working; $0.headline = "Open Notes" }
        controller.update { $0.app = "Notes" }
        controller.update { $0.phase = .done }
        controller.update { $0.phase = .working; $0.headline = "Open WeChat" }
        XCTAssertNil(controller.state.app)
        controller.update { $0.app = "WeChat" }
        XCTAssertEqual(controller.state.app, "WeChat")
    }

    /// No presentation of the Live Activity counts a run's steps: an agent changes its count as it
    /// goes, so "2/5", "Step 8" and "12 steps" read as broken promises. The line over the title names
    /// the app, the compact island shows the app or the time, the line under the title has no
    /// segments, and a finished run says how long, with or without a plan.
    func testNoPresentationCountsTheRunsSteps() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        var state = PokiState(phase: .working, headline: "Tap “Send”", thumbnailVersion: 0)
        state.app = "Messages"
        state.since = start
        state.stepCount = 7
        state.plan = .init(steps: ["Open Messages", "Open the chat", "Write it", "Check it", "Send it"], current: 2)
        for plan in [state.plan, nil] {
            state.plan = plan
            let face = state.face
            XCTAssertEqual(face.kicker, "Messages")
            XCTAssertEqual(face.compact, ActivityFace.workingTrailing == .icon ? .app("Messages", since: start) : .elapsed(start))
            XCTAssertEqual(face.bottom, .progress(line: true, stop: true))
        }

        state.phase = .done
        state.endedAt = start.addingTimeInterval(84)
        state.plan = .init(steps: ["Open Messages", "Send it"], current: 2, title: "Text Mom")
        XCTAssertEqual(state.face.content, "Text Mom")
        XCTAssertEqual(state.face.subtitle, "Took 1:24")
    }

    /// ESP-954: a finished run says Done once, over what the run came to. The island said it twice
    /// (the finish event's word over a title that fell back to Done), with the time cut off under it.
    func testAFinishedRunSaysDoneOnceOverWhatItCameTo() {
        func finished(result: String? = nil, task: String? = nil, _ set: (inout PokiState) -> Void = { _ in }) -> ActivityFace {
            let controller = ActivityController()
            controller.update { $0.phase = .working; $0.headline = "Open Notes"; set(&$0) }
            controller.finishNow(alert: false, result: result, task: task)
            return controller.state.face
        }
        // Nothing known about the run: Done is the title, said once.
        let bare = finished()
        XCTAssertEqual(bare.content, "Done")
        XCTAssertNil(bare.kicker)
        XCTAssertNil(bare.event)

        // Otherwise Done over finish_task's summary, else the plan's title, else the task as asked,
        // else the app.
        let inNotes: (inout PokiState) -> Void = { $0.app = "Notes" }
        let titled: (inout PokiState) -> Void = { $0.app = "Notes"; $0.plan = .init(steps: ["Open Notes"], current: 1, title: "Shopping list") }
        let lines = [
            finished(inNotes),
            finished(task: "Make me a shopping list\nwith milk", inNotes),
            finished(task: "Make me a shopping list", titled),
            finished(result: "Wrote the shopping list in Notes", task: "Make me a shopping list", titled),
        ]
        XCTAssertEqual(lines.map(\.content), ["Notes", "Make me a shopping list", "Shopping list", "Wrote the shopping list in Notes"])
        for face in lines {
            XCTAssertEqual(face.kicker, "Done")
            XCTAssertNil(face.event)
            XCTAssertEqual(face.subtitle, "Took 0:00")
        }
    }

    /// ESP-981: in every voice state on the expanded Dynamic Island (listening, thinking, speaking,
    /// working, approval, deciding, hand-off, done), both the bear and the words and controls stay
    /// above the 12.33-point bottom strip that iOS clips away.
    func testEveryVoiceStatesExpandedIslandKeepsTheBearAndControlsInsideTheSystemClip() throws {
        let samples = ActivityPreview.makeSamples().filter { $0.0.hasPrefix("voice") }
        XCTAssertEqual(samples.map(\.0), ["voice", "voicethinking", "voicespeaking", "voiceworking", "voiceapproval", "voicedeciding", "voicehandoff", "voicedone"])
        let width = 374
        let clip = Int(ActivityMetrics.islandClip)
        let space = CGColorSpaceCreateDeviceRGB()

        for locale in ["en", "zh-Hans"] {
            AppLocalization.shared.preference = locale
            for (name, sample) in samples {
                var variants = [(name, sample)]
                if sample.phase == .idle {
                    var withEvent = sample
                    withEvent.event = .init(kind: .started, text: "Started")
                    variants.append(("\(name)+event", withEvent))
                } else if sample.phase == .approval {
                    var withStopAsking = sample
                    withStopAsking.approval?.stopsWhenOff = true
                    variants.append(("\(name)+stopAsking", withStopAsking))
                }
                for (label, state) in variants {
                    let face = state.face
                    let sizes = ActivityMetrics.sizes(face)
                    let height = Int(sizes.island - ActivityMetrics.cameraRow)
                    let split = Int(sizes.islandLeft)
                    let view = IslandBottom(face: face)
                        .dynamicTypeSize(...ActivityMetrics.largestType)
                        .environment(\.isLuminanceReduced, true)
                        .frame(width: CGFloat(width), height: CGFloat(height))
                    let renderer = ImageRenderer(content: view)
                    renderer.scale = 1
                    let cgImage = try XCTUnwrap(renderer.cgImage, "\(locale) \(label)")
                    var pixels = [UInt8](repeating: 0, count: width * height * 4)
                    let context = try XCTUnwrap(CGContext(
                        data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    ))
                    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

                    var bearVisible = 0, bearClipped = 0
                    var wordsVisible = 0, wordsClipped = 0
                    for y in 0..<height {
                        let inBottomClip = y >= height - clip
                        for x in 0..<width {
                            let alpha = pixels[(y * width + x) * 4 + 3]
                            guard alpha > 16 else { continue }
                            if x < split {
                                if inBottomClip { bearClipped += 1 } else { bearVisible += 1 }
                            } else {
                                if inBottomClip { wordsClipped += 1 } else { wordsVisible += 1 }
                            }
                        }
                    }
                    XCTAssertGreaterThan(bearVisible, 0, "\(locale) \(label): bear must render above the bottom clip")
                    XCTAssertGreaterThan(wordsVisible, 0, "\(locale) \(label): words and controls must render above the bottom clip")
                    XCTAssertEqual(wordsClipped, 0, "\(locale) \(label): words or buttons extend into the bottom \(clip)pt clip")
                    XCTAssertEqual(bearClipped, 0, "\(locale) \(label): bear extends into the bottom \(clip)pt clip")
                }
            }
        }
    }

    /// ESP-467: the island and the Lock Screen say what the task is doing, never the single tap under
    /// it. With the chat's plan, the step under way in the plan's words; without a plan, a line of
    /// Poki's own. The compact island never shows a tap either.
    func testTheIslandSaysThePlansStepNotTheTap() {
        var state = PokiState(phase: .working, headline: "Tap “Send”", thumbnailVersion: 0)
        state.stepCount = 3
        state.plan = .init(steps: ["Open the chat with Mom", "Send “On my way”"], current: 2, title: "Text Mom", to: "Mom")
        var face = state.face
        XCTAssertEqual(face.content, "Send “On my way”")
        XCTAssertFalse(face.compact.says("Tap"))

        // An outside agent's run has no plan: no tap on any presentation.
        state.plan = nil
        state.caller = "Claude Code"
        face = state.face
        XCTAssertEqual(face.content, StatusWord.running.text)
        XCTAssertFalse(face.compact.says("Tap"))
    }

    /// The compact island's right side names where the run is without words: the icon of the app it
    /// is in, and the run's time while that app is not known. Before the run reaches an app there is
    /// no line under the title yet (the runner waking).
    func testTheCompactIslandShowsTheAppOrTheTime() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        var state = PokiState(phase: .working, headline: "Open WeChat", thumbnailVersion: 0)
        state.since = start
        XCTAssertEqual(state.face.compact, .elapsed(start))
        XCTAssertEqual(state.face.bottom, .progress(line: false, stop: true))

        state.app = "WeChat"
        XCTAssertEqual(state.face.compact, ActivityFace.workingTrailing == .icon ? .app("WeChat", since: start) : .elapsed(start))
    }

    /// ESP-467: while the runner starts, every stage says one main line (Poki waking up) and names the
    /// stage in the small line under it, instead of a new main line per stage.
    func testTheStartUpStagesShareOneLineAndNameTheStageBelow() {
        let stages = ["Connecting", "Checking pairing", "Opening tunnel", "Preparing", "Starting"]
        let faces = stages.map { PokiState(phase: .idle, headline: $0, thumbnailVersion: 0).face }
        XCTAssertEqual(Set(faces.map(\.content)).count, 1)
        XCTAssertEqual(faces.map(\.subtitle), stages.map { ActivityWords.local($0) })
    }

    /// ESP-467: when iOS folds an approval's island back, the compact island says Poki waits for your
    /// answer, beside the time left, not a bare countdown.
    func testTheFoldedIslandSaysItWaitsForYourAnswer() {
        var state = PokiState(phase: .approval, headline: "Allow this step?", thumbnailVersion: 0)
        state.approval = PendingApproval(id: "a", app: "Messages", summary: "Tap “Send”", reason: "sending a message (\"send\")", expires: .now.addingTimeInterval(60))
        XCTAssertTrue(state.face.compact.says("Allow?"))
    }

    func testAnsweringAnIslandApprovalReturnsToProgressWithoutConfirmation() {
        let controller = ActivityController()
        controller.update { $0.phase = .working; $0.headline = "Working"; $0.app = "Messages" }
        let normalProgress = controller.state.face

        let approval = PendingApproval(id: "approval", app: "Messages", summary: "Send message",
                                       reason: "sending a message", expires: .now.addingTimeInterval(60))
        controller.update { $0.phase = .approval; $0.approval = approval; $0.headline = "Allow this step?" }
        XCTAssertEqual(controller.state.face.bottom, .approval(id: approval.id))

        controller.update { $0.phase = .deciding; $0.decision = true }
        XCTAssertEqual(controller.state.face.compact, normalProgress.compact, "Answering shows normal progress")
        XCTAssertEqual(controller.state.face.bottom, normalProgress.bottom, "Answering shows no confirmation card")

        controller.update { $0.phase = .working; $0.approval = nil; $0.headline = "Continuing" }
        XCTAssertNotEqual(controller.state.face.event, "Allowed", "Continuing shows no approval confirmation")
    }

    private static var runningSession: RunningSession?

    private struct RunningSession {
        let app: AppModel
        let existingIDs: Set<String>
        let restore: @MainActor () -> Void

        @MainActor
        func activities() -> [Activity<PokiActivityAttributes>] {
            Activity<PokiActivityAttributes>.activities.filter {
                !existingIDs.contains($0.id) && ($0.activityState == .active || $0.activityState == .stale)
            }
        }

        @MainActor
        func stop() {
            if app.sessionOn { app.stopSession() }
            restore()
        }
    }

    override class func tearDown() {
        MainActor.assumeIsolated {
            runningSession?.stop()
            runningSession = nil
        }
        super.tearDown()
    }

    func testLiveActivityLeavesUpdateNotificationsIntact() async throws {
        try await withFinishWindow(dynamicIsland: true) {
            try await withSessionApp { app, activities in
                app.becameActive()
                app.startSession()
                await app.chatTaskBegan()
                let activity = try XCTUnwrap(activities().first)
                XCTAssertEqual(activity.activityState, .active)

                let updateID = "nz.zheha.poki.signing.reopen"
                clearNotice(updateID)
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let ipa = dir.appendingPathComponent("Poki.ipa")
                try Data("ipa".utf8).write(to: ipa)
                let pairing = dir.appendingPathComponent("pairing.plist")
                let pairingPlist: [String: Any] = [
                    "identifier": "test-host",
                    "public_key": Data(repeating: 1, count: 32),
                    "private_key": Data(repeating: 2, count: 32),
                ]
                try PropertyListSerialization.data(fromPropertyList: pairingPlist, format: .xml, options: 0).write(to: pairing)

                let readyDir = SelfSigner.home.appendingPathComponent("ready/update", isDirectory: true)
                let existingManifest = try? Data(contentsOf: readyDir.appendingPathComponent("manifest.json"))
                try FileManager.default.createDirectory(at: readyDir, withIntermediateDirectories: true)
                let manifest: [String: Any] = [
                    "kind": "update",
                    "ipa": ipa.path,
                    "bundle_id": Bundle.main.bundleIdentifier ?? "nz.zheha.poki",
                    "version": "99.0.0",
                    "build": "99999",
                    "tag": "v99.0.0",
                    "team_name": "Test Team",
                    "team_is_free": true,
                    "profile_expires_at": Int64(Date().addingTimeInterval(7 * 86_400).timeIntervalSince1970),
                    "prepared_at": Int64(Date().timeIntervalSince1970),
                ]
                try JSONSerialization.data(withJSONObject: manifest).write(to: readyDir.appendingPathComponent("manifest.json"))

                let hold = try LocalPortHold()
                poki_set_remote_pairing_port(hold.port)
                defer {
                    poki_set_remote_pairing_port(0)
                    hold.closeAll()
                    clearNotice(updateID)
                    if let existingManifest {
                        try? existingManifest.write(to: readyDir.appendingPathComponent("manifest.json"))
                    } else {
                        try? FileManager.default.removeItem(at: readyDir.appendingPathComponent("manifest.json"))
                    }
                    try? FileManager.default.removeItem(at: dir)
                }

                let signer = SelfSigner()
                signer.start()
                for _ in 0..<100 where signer.next == nil {
                    try await Task.sleep(for: .milliseconds(20))
                }
                XCTAssertEqual(signer.next?.kind, "update")
                signer.isIdle = { true }
                signer.phone = { ["device_address": "127.0.0.1", "pairing_file": pairing.path, "host_name": "Poki"] }

                let installing = Task { await signer.install() }
                try await hold.waitForConnection()
                let pending = await UNUserNotificationCenter.current().pendingNotificationRequests()
                let reopen = try XCTUnwrap(pending.first { $0.identifier == updateID },
                                           "Update reopen notification must remain scheduled while a Dynamic Island activity runs")
                XCTAssertEqual(reopen.content.title, "Poki Was Updated")
                hold.closeAll()
                await installing.value
            }
        }
    }

    func testTaskFinishOnDynamicIslandUpdatesActivityWithoutPostingBanner() async throws {
        try await withActiveActivityInBackground(dynamicIsland: true) { app, activity in
            await app.chatTaskBegan()
            try await waitForPhase(.working, on: activity)
            clearNotice("poki-reply")
            app.chatTaskEnded(reply: "Sent the note.", session: "finish-island", acted: true)

            try await waitForPhase(.done, on: activity)
            try await Task.sleep(for: .milliseconds(1800))
            let completionBanner = await deliveredNotice("poki-reply")
            XCTAssertNil(completionBanner, "Dynamic Island activity must not also post a task finish banner")
        }
    }

    func testTaskFinishWithoutDynamicIslandPostsBannerEvenWhenActivityRuns() async throws {
        try await withActiveActivityInBackground(dynamicIsland: false) { app, activity in
            XCTAssertEqual(activity.activityState, .active)
            await app.chatTaskBegan()
            try await waitForPhase(.working, on: activity)
            clearNotice("poki-reply")
            app.chatTaskEnded(reply: "Sent the note.", session: "finish-notch", acted: true)

            let banner = try await waitForDeliveredNotice("poki-reply")
            XCTAssertEqual(banner.request.content.body, "The task has ended. Open Poki to see the result.")
        }
    }

    func testTaskFinishWithoutRunningActivityPostsBannerOnDynamicIsland() async throws {
        if let existing = Self.runningSession {
            existing.stop()
            Self.runningSession = nil
            for _ in 0..<100 where !Activity<PokiActivityAttributes>.activities.filter({ $0.activityState == .active }).isEmpty {
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        try await withFinishWindow(dynamicIsland: true) {
            try await withSessionApp { app, activities in
                defer { clearNotice("poki-reply") }
                try await movePokiToBackground(app)
                app.startSession()
                await app.chatTaskBegan()
                XCTAssertTrue(activities().isEmpty)

                clearNotice("poki-reply")
                app.chatTaskEnded(reply: "Sent the note.", session: "finish-no-activity", acted: true)

                let banner = try await waitForDeliveredNotice("poki-reply")
                XCTAssertEqual(banner.request.content.body, "The task has ended. Open Poki to see the result.")
            }
        }
    }

    func testNonDynamicIslandApprovalIntentResolvesBeforeReturningAndSchedulesFallbackNotice() async throws {
        try await withFinishWindow(dynamicIsland: false) {
            InProcessWDA.gate.withLock { $0 = InProcessWDA.OpenGate() }
            let defaults = UserDefaults.standard
            let keys = ["relayAddress", "relayEnabled", "wantsOn", ApprovalClassifier.modeKey]
            let saved = keys.map { defaults.object(forKey: $0) }
            let setup = SetupState.load()
            let automation = FakeAutomation()
            // Ordinary-page Delete is allowed under ESP-1328; use a payment button so approval always triggers.
            let transport = SessionScreenTransport(session: automation, screenLabel: { "Pay" })
            let app = AppModel(launcher: FakeLauncher(), pairer: FakePairing(), automation: automation, transport: transport)
            defer {
                automation.answer(nil)
                if app.sessionOn { app.stopSession() }
                for (key, value) in zip(keys, saved) { defaults.set(value, forKey: key) }
                setup.save()
            }
            UserDefaults.standard.set(ApprovalClassifier.Mode.confirm.rawValue, forKey: ApprovalClassifier.modeKey)
            app.loopback.simulate(.working(ms: 9))
            app.setup.loopback = .proxy
            XCTAssertTrue(app.setRelay("https://relay.invalid"))
            app.becameActive()
            app.startSession()
            app.wakeRunner()
            for _ in 0..<150 where !["failed", "running"].contains(app.runner.state) {
                try await Task.sleep(for: .milliseconds(20))
            }
            app.runnerChanged(RunnerStatus(state: "running", code: "local_ddi"))
            for _ in 0..<150 where !app.hasOpenInProcessSession {
                try await Task.sleep(for: .milliseconds(20))
            }
            await app.chatTaskBegan()

            let look = await app.runTool("look", arguments: "{}")
            XCTAssertFalse(look.isError, look.text)

            let allowTask = Task { await app.runTool("do", arguments: #"{"actions":[{"tap":1}]}"#) }
            for _ in 0..<150 where app.approvals.isEmpty {
                try await Task.sleep(for: .milliseconds(20))
            }
            let first = try XCTUnwrap(app.approvals.first, "Sensitive tap must raise a pending approval")
            let firstNoticeID = "approval-\(first.id)"
            defer { clearNotice(firstNoticeID) }

            var scheduledFallback: UNNotificationRequest?
            for _ in 0..<50 {
                let pending = await UNUserNotificationCenter.current().pendingNotificationRequests()
                if let match = pending.first(where: { $0.identifier == firstNoticeID }) {
                    scheduledFallback = match
                    break
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertNotNil(scheduledFallback, "Without a Dynamic Island, a fallback approval notification must be scheduled after the Live Activity banner dismisses")

            let allowStarted = ContinuousClock.now
            _ = try await ApproveActionIntent(approvalID: first.id).perform()
            let allowResult = await allowTask.value
            let allowElapsed = ContinuousClock.now - allowStarted
            XCTAssertFalse(allowResult.isError, allowResult.text)
            XCTAssertLessThan(allowElapsed, .milliseconds(900), "On a device without a Dynamic Island, ApproveActionIntent must resolve before returning instead of waiting behind an unawaited collapse sleep")

            let pendingAfterAllow = await UNUserNotificationCenter.current().pendingNotificationRequests()
            XCTAssertFalse(pendingAfterAllow.contains { $0.identifier == firstNoticeID }, "Answering on the Live Activity must cancel the fallback approval notification")

            let denyTask = Task { await app.runTool("do", arguments: #"{"actions":[{"tap":1}]}"#) }
            for _ in 0..<150 where app.approvals.isEmpty {
                try await Task.sleep(for: .milliseconds(20))
            }
            let second = try XCTUnwrap(app.approvals.first, "Second sensitive tap must raise a pending approval")
            let secondNoticeID = "approval-\(second.id)"
            defer { clearNotice(secondNoticeID) }

            let denyStarted = ContinuousClock.now
            _ = try await DenyActionIntent(approvalID: second.id).perform()
            let denyResult = await denyTask.value
            let denyElapsed = ContinuousClock.now - denyStarted
            XCTAssertTrue(denyResult.isError || denyResult.text.lowercased().contains("denied") || denyResult.text.lowercased().contains("not"), denyResult.text)
            XCTAssertLessThan(denyElapsed, .milliseconds(900), "On a device without a Dynamic Island, DenyActionIntent must resolve before returning")
        }
    }

    private func ensureRunningSession() async throws -> RunningSession {
        if let session = Self.runningSession, session.activities().first != nil {
            return session
        }
        Self.runningSession?.stop()
        let defaults = UserDefaults.standard
        let keys = ["relayAddress", "relayEnabled", "wantsOn"]
        let saved = keys.map { defaults.object(forKey: $0) }
        let setup = SetupState.load()
        let existingIDs = Set(Activity<PokiActivityAttributes>.activities.map(\.id))
        let automation = FakeAutomation()
        let app = AppModel(launcher: FakeLauncher(), pairer: FakePairing(), automation: automation)
        app.loopback.simulate(.working(ms: 9))
        app.setup.loopback = .proxy
        XCTAssertTrue(app.setRelay("https://relay.invalid"))
        app.becameActive()
        app.startSession()
        await app.chatTaskBegan()
        let session = RunningSession(app: app, existingIDs: existingIDs) {
            automation.answer(nil)
            for (key, value) in zip(keys, saved) { defaults.set(value, forKey: key) }
            setup.save()
        }
        Self.runningSession = session
        return session
    }

    private func withActiveActivityInBackground(
        dynamicIsland: Bool,
        _ body: (AppModel, Activity<PokiActivityAttributes>) async throws -> Void
    ) async throws {
        try await withFinishWindow(dynamicIsland: dynamicIsland) {
            let session = try await ensureRunningSession()
            let activity = try XCTUnwrap(session.activities().first)
            XCTAssertEqual(activity.activityState, .active)
            defer { clearNotice("poki-reply") }
            try await movePokiToBackground(session.app)
            try await body(session.app, activity)
        }
    }

    private func withFinishWindow(dynamicIsland: Bool, _ body: () async throws -> Void) async throws {
        _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.provisional])
        var windowScene: UIWindowScene?
        for _ in 0..<1500 where windowScene == nil {
            windowScene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            if windowScene == nil { try await Task.sleep(for: .milliseconds(20)) }
        }
        let scene = try XCTUnwrap(windowScene, "The app never connected a window scene")
        let hidden = scene.windows.filter { !$0.isHidden }
        hidden.forEach { $0.isHidden = true }
        let nativeProbe = UIWindow(windowScene: scene)
        nativeProbe.frame = scene.screen.bounds
        nativeProbe.rootViewController = UIViewController()
        nativeProbe.makeKeyAndVisible()
        nativeProbe.layoutIfNeeded()
        let nativeTop = nativeProbe.safeAreaInsets.top
        nativeProbe.isHidden = true

        let window: UIWindow
        if (dynamicIsland && nativeTop >= 51) || (!dynamicIsland && nativeTop > 0 && nativeTop < 51) {
            window = UIWindow(windowScene: scene)
        } else {
            window = FixedSafeAreaWindow(windowScene: scene, topInset: dynamicIsland ? 62 : 47)
        }
        window.frame = scene.screen.bounds
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        defer {
            window.isHidden = true
            hidden.forEach { $0.isHidden = false }
            hidden.first?.makeKeyAndVisible()
        }
        try await body()
    }

    private func movePokiToBackground(_ app: AppModel) async throws {
        app.wentToBackground()
        if UIApplication.shared.applicationState == .active {
            UIApplication.shared.perform(NSSelectorFromString("suspend"))
            for _ in 0..<150 where UIApplication.shared.applicationState == .active {
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        XCTAssertNotEqual(UIApplication.shared.applicationState, .active, "Poki must leave the foreground to test finish notices")
    }

    private func waitForPhase(_ phase: PokiState.Phase, on activity: Activity<PokiActivityAttributes>) async throws {
        for _ in 0..<150 where activity.content.state.phase != phase {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(activity.content.state.phase, phase)
    }

    private func clearNotice(_ id: String) {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [id])
        center.removePendingNotificationRequests(withIdentifiers: [id])
    }

    private func deliveredNotice(_ id: String) async -> UNNotification? {
        await UNUserNotificationCenter.current().deliveredNotifications().first { $0.request.identifier == id }
    }

    private func waitForDeliveredNotice(_ id: String) async throws -> UNNotification {
        for _ in 0..<150 {
            if let found = await deliveredNotice(id) { return found }
            try await Task.sleep(for: .milliseconds(20))
        }
        let found = await deliveredNotice(id)
        return try XCTUnwrap(found, "Expected delivered notification \(id)")
    }
}

private final class FixedSafeAreaWindow: UIWindow {
    private let customInsets: UIEdgeInsets

    init(windowScene: UIWindowScene, topInset: CGFloat) {
        customInsets = UIEdgeInsets(top: topInset, left: 0, bottom: 34, right: 0)
        super.init(windowScene: windowScene)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var safeAreaInsets: UIEdgeInsets { customInsets }
}

private final class LocalPortHold {
    private var serverFD: Int32
    private var clientFD: Int32 = -1
    let port: UInt16

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 1) == 0 else {
            close(fd)
            throw POSIXError(.EADDRINUSE)
        }
        var actual = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
        serverFD = fd
        port = UInt16(bigEndian: actual.sin_port)
    }

    func waitForConnection() async throws {
        for _ in 0..<150 {
            let fd = accept(serverFD, nil, nil)
            if fd >= 0 {
                clientFD = fd
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for SelfSigner connection")
    }

    func closeAll() {
        if clientFD >= 0 {
            var buf = [UInt8](repeating: 0, count: 4096)
            _ = recv(clientFD, &buf, buf.count, MSG_DONTWAIT)
            let reply = Array("HTTP/1.1 500 Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
            _ = send(clientFD, reply, reply.count, 0)
            shutdown(clientFD, SHUT_WR)
            close(clientFD)
            clientFD = -1
        }
        if serverFD >= 0 { close(serverFD); serverFD = -1 }
    }
}

private extension ActivityFace.Compact {
    /// The compact island shows this text, in whichever form it draws it.
    func says(_ text: String) -> Bool {
        let words = Mirror(reflecting: self).children.first.map { String(describing: $0.value) } ?? ""
        return words.contains(text)
    }
}
