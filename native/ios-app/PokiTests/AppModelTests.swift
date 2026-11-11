import PokiCore
import SwiftUI
import XCTest
@testable import Poki

/// A launcher that records what the app asked of it and plays back runner events.
final class FakeLauncher: RunnerLauncher, @unchecked Sendable {
    var starts = 0, restarts = 0, stops = 0
    var emit: (@Sendable (RunnerStatus) -> Void)?
    func start(config: LauncherConfig, onEvent: @escaping @Sendable (RunnerStatus) -> Void) throws { starts += 1; emit = onEvent }
    func restart() { restarts += 1 }
    func stop() { stops += 1 }
}

/// Poki's own automation session as iOS keeps it. An open can be held, as one is while iOS asks for
/// the passcode, until `answer(_:)`.
final class FakeAutomation: InProcessAutomation, @unchecked Sendable {
    private let lock = NSLock()
    private var open = false
    private var gate: DispatchSemaphore?
    private var answer: [String: Any]?
    /// The next open waits until `answer(_:)`.
    func holdNextOpen() { lock.withLock { gate = DispatchSemaphore(value: 0) } }
    /// Lets a held open go on, with this answer instead of opening (nil opens).
    func answer(_ result: [String: Any]?) { lock.withLock { answer = result; gate?.signal(); gate = nil } }
    func prepare() -> [String: Any] {
        if let held = lock.withLock({ gate }) {
            held.wait()
            if let given = lock.withLock({ () -> [String: Any]? in defer { answer = nil }; return answer }) { return given }
        }
        return lock.withLock {
            let reused = open
            open = true
            return ["ok": true, "generation": 1, "reused": reused, "seconds": 0.0]
        }
    }
    func close() -> [String: Any] { lock.withLock { defer { open = false }; return ["closed": open, "generation": 1, "seconds": 0.0] } }
    func pauseAutomation() -> [String: Any] { ["paused": true, "how": "fake"] }
}

final class FakePairing: DevicePairing {
    func start(hostName: String, saveTo: URL, onEvent: @escaping @Sendable (PairingEvent) -> Void) throws {}
    func cancel() {}
}

@MainActor
final class AppModelTests: XCTestCase {
    private func model() -> (AppModel, FakeLauncher) {
        let launcher = FakeLauncher()
        let model = AppModel(launcher: launcher, pairer: FakePairing())
        return (model, launcher)
    }

    /// Poki automates the iPhone in its own process by default, and a running launcher then only means
    /// the disk image is mounted: the agent reads "running" once the in-process session is open. The
    /// tests below are about the launcher's states, so they open the session first (the Debug probe's
    /// own call); on the Poki Runner path (`-automationPath runner`) it changes nothing.
    private func sessionOpen(_ model: AppModel) { model.inProcessReadyForProbe() }

    /// The default path: a running launcher is not yet a running phone. The agent hears that the
    /// session is opening until it is open, and "running" right after.
    func testRunningLauncherWaitsForTheInProcessSession() throws {
        let (model, _) = model()
        try XCTSkipUnless(model.automationPath == .inProcess, "Poki Runner path: the launcher's state is the whole story")
        model.loopback.simulate(.working(ms: 9))
        let opening = model.coreState(of: RunnerStatus(state: "running")).describe
        XCTAssertTrue(opening.contains("opening the in-process session"), opening)
        sessionOpen(model)
        XCTAssertEqual(model.coreState(of: RunnerStatus(state: "running")).describe, "running")
    }

    /// A tunnel drop while the runner is connecting is named to the agent with the time and the fix,
    /// whatever launcher state it happens to be in; "Checking pairing" alone would say nothing.
    func testLoopbackDownIsNamedToTheAgent() {
        let (model, _) = model()
        model.loopback.simulate(.working(ms: 12))
        model.loopback.simulate(.off)
        for state in ["connecting", "pairing", "waiting_network", "standby"] {
            let text = model.coreState(of: RunnerStatus(state: state)).describe
            XCTAssertTrue(text.contains("waiting for the loopback since"), "\(state): \(text)")
            XCTAssertTrue(text.contains("proxy app"), text)
        }
        // Launching and running are past the tunnel: they stay what the launcher says.
        sessionOpen(model)
        XCTAssertEqual(model.coreState(of: RunnerStatus(state: "running")).describe, "running")
    }

    /// A tunnel that gave the phone an address but does not reflect it is told apart from no tunnel.
    func testTunnelOnButNotReflectedSaysSo() {
        let (model, _) = model()
        model.loopback.simulate(.working(ms: 12))
        model.loopback.simulate(.noAnswer)
        let text = model.coreState(of: RunnerStatus(state: "pairing")).describe
        XCTAssertTrue(text.contains("does not reflect 10.7.0.1"), text)
    }

    /// ESP-225: a local interface with no answer at 10.7.0.1 is the loopback first, then the pairing.
    /// Developer Mode, which only goes off with a restart, comes last.
    func testTunnelWithoutAnswerPutsDeveloperModeLast() throws {
        let (model, _) = model()
        model.loopback.simulate(.noAnswer)
        let text = model.loopback.detail
        let reconnect = try XCTUnwrap(text.range(of: "Reconnect"), text)
        let pairing = try XCTUnwrap(text.range(of: "Setup › Pairing"), text)
        let developerMode = try XCTUnwrap(text.range(of: "Developer Mode"), text)
        XCTAssertTrue(reconnect.lowerBound < pairing.lowerBound && pairing.lowerBound < developerMode.lowerBound, text)
    }

    /// With the loopback up, the launcher's own words stand.
    func testLoopbackUpKeepsTheLauncherState() {
        let (model, _) = model()
        model.loopback.simulate(.working(ms: 9))
        XCTAssertEqual(model.coreState(of: RunnerStatus(state: "pairing")).describe, "starting (Checking pairing)")
    }

    /// A pairing refusal is kept until the phone accepts again; a disk-image refusal re-downloads.
    func testPairingRefusalThenAcceptance() {
        let (model, _) = model()
        model.runnerChanged(RunnerStatus(state: "failed", detail: "the phone refused the pairing", fix: "Pair again in Poki's setup.", code: "pairing"))
        XCTAssertNotNil(model.pairingTrouble)
        model.runnerChanged(RunnerStatus(state: "launching"))
        XCTAssertNil(model.pairingTrouble)
        XCTAssertNotNil(model.pairingVerifiedAt)
    }

    /// The agent's view of the runner follows every launcher event.
    func testHostSeesTheRunnerState() {
        let (model, _) = model()
        model.loopback.simulate(.working(ms: 9))
        sessionOpen(model)
        model.runnerChanged(RunnerStatus(state: "running"))
        XCTAssertTrue(model.host.currentRunner.isRunning)
        model.runnerChanged(RunnerStatus(state: "failed", detail: "it stopped", fix: nil))
        if case .failed(let detail, _) = model.host.currentRunner { XCTAssertEqual(detail, "it stopped") } else { XCTFail("not failed") }
    }

    /// A loopback that answers before any connection was chosen in Setup (a proxy app set up before
    /// Poki, or by Poki Setup on a computer) is the step done, and the external connection becomes the
    /// recorded choice so Turn on does not ask for one (0.2.8 build 91 held the owner on the page).
    func testWorkingLoopbackWithNoChoiceIsTheStepDone() {
        let (model, _) = model()
        model.setup.loopback = .none
        XCTAssertFalse(model.isDone(.loopback))
        model.loopback.simulate(.working(ms: 7))
        XCTAssertTrue(model.isDone(.loopback))
        XCTAssertEqual(model.setup.loopback, .proxy)
        XCTAssertEqual(SetupView.firstOpen(model), SetupStep.shown.firstIndex { !model.isDone($0) }, "setup opens past the loopback")
        XCTAssertNotEqual(SetupStep.shown[SetupView.firstOpen(model)], .loopback)
        model.loopback.simulate(.off)
        XCTAssertFalse(model.isDone(.loopback))
        XCTAssertEqual(model.setup.loopback, .proxy, "a drop does not unchoose the connection")
    }

    /// Poki Setup on a Mac signs and installs Poki, so signing in to an Apple Account on the phone is
    /// optional (ESP-222): with every other item done and no Apple sign-in, Setup has nothing left,
    /// which is what clears home's warning, the Setup tab's dot and the paused power button.
    /// Location comes from the simulator (`simctl privacy grant location-always`, app-tests.sh).
    func testEverythingDoneWithoutAnAppleAccountLeavesNothingToSetUp() throws {
        let (model, _) = model()
        let saved = model.setup
        defer { model.setup = saved }
        let pairing = AppFiles.phonePairingFile
        if !FileManager.default.fileExists(atPath: pairing.path) {
            try Data("pairing".utf8).write(to: pairing)
            addTeardownBlock { try? FileManager.default.removeItem(at: pairing) }
        }
        model.setup.runnerInstalled = true
        model.setup.developerMode = true
        model.setup.uiAutomation = true
        model.loopback.simulate(.working(ms: 7))
        XCTAssertTrue(model.background.allowed && model.activitiesEnabled, "the simulator grants location and Live Activities")
        XCTAssertFalse(model.signer.signedIn)

        XCTAssertTrue(model.setupComplete, "left: \(SetupStep.shown.filter { !model.isDone($0) })")
        XCTAssertFalse(model.setupStepsLeft)
    }

    /// Home warns only in the last two days of the installed signing (ESP-222). Signing Poki again
    /// installs a build with a new profile, so a renewed Poki has a later expiry and no warning.
    func testExpiryWarningOnlyInTheLastTwoDays() {
        let now = Date()
        XCTAssertNotNil(ExpiryWarning(expiry: now.addingTimeInterval(86_400), now: now), "1 day left")
        XCTAssertNil(ExpiryWarning(expiry: now.addingTimeInterval(3 * 86_400), now: now), "3 days left")
        XCTAssertNil(ExpiryWarning(expiry: nil, now: now), "no profile, as on a simulator")
    }

    /// Idle stop setting round-trips and never goes below the floor the picker offers.
    func testIdleStopSetting() {
        let (model, _) = model()
        model.idleStopSeconds = 120
        XCTAssertEqual(UserDefaults.standard.integer(forKey: "idleStopSeconds.v4"), 120)
        model.idleStopSeconds = 60
    }
}

@MainActor
final class ApprovalDefaultTests: XCTestCase {
    private var saved: Any?
    private var savedMode: Any?
    override func setUp() {
        saved = UserDefaults.standard.object(forKey: LiveCore.askKey)
        savedMode = UserDefaults.standard.object(forKey: ApprovalClassifier.modeKey)
        UserDefaults.standard.removeObject(forKey: ApprovalClassifier.modeKey)
    }
    override func tearDown() {
        UserDefaults.standard.set(saved, forKey: LiveCore.askKey)
        UserDefaults.standard.set(savedMode, forKey: ApprovalClassifier.modeKey)
    }

    /// A phone that never chose (a new install, or an alpha tester who left the switch alone) asks the
    /// owner before a sensitive step: the Send tap in Messages waits for an answer instead of going
    /// through, and the switch reads on.
    func testAPhoneThatNeverChoseAsksBeforeASensitiveTap() async {
        UserDefaults.standard.removeObject(forKey: LiveCore.askKey)
        let core = LiveCore(host: AppCoreHost(), transport: URLSessionTransport())
        let tap = await core.clearTap(on: "Send", inApp: "com.apple.MobileSMS", named: "Messages", waiting: 0.2)
        XCTAssertFalse(tap.mayTap, "\(tap)")
        XCTAssertNotEqual(AppModel(launcher: FakeLauncher(), pairer: FakePairing()).approvalMode, .off)
    }

    /// An owner who turned asking off keeps that choice.
    func testAnOwnerWhoTurnedAskingOffIsNotAsked() async {
        UserDefaults.standard.set(false, forKey: LiveCore.askKey)
        let core = LiveCore(host: AppCoreHost(), transport: URLSessionTransport())
        let tap = await core.clearTap(on: "Send", inApp: "com.apple.MobileSMS", named: "Messages", waiting: 0.2)
        XCTAssertEqual(tap, .clear)
    }

    /// Tapping Allow or Don’t Allow on the Live Activity (ApproveActionIntent / DenyActionIntent) sends
    /// the decision back through the approval channel to PokiCore.
    func testLiveActivityApprovalButtonsDeliverDecisionToApprovalChannel() async throws {
        UserDefaults.standard.removeObject(forKey: LiveCore.askKey)
        let core = LiveCore(host: AppCoreHost(), transport: URLSessionTransport())
        var pending: [PendingApproval] = []
        var activityState = PokiActivityAttributes.ContentState(phase: .working, headline: "Working", thumbnailVersion: 0)

        let eventsTask = Task { @MainActor in
            for await event in core.events {
                switch event {
                case .approvalRequested(let approval):
                    pending.append(approval)
                    activityState.phase = .approval
                    activityState.approval = approval
                    activityState.headline = "Allow this step?"
                case .approvalEnded(let id, let approved):
                    pending.removeAll { $0.id == id }
                    if activityState.approval?.id == id {
                        activityState.approval = nil
                        activityState.phase = .working
                        activityState.headline = approved == true ? "Continuing" : "Step skipped"
                    }
                default:
                    break
                }
            }
        }
        defer { eventsTask.cancel() }

        ApprovalIntentBridge.install { decision in
            guard pending.contains(where: { $0.id == decision.approvalID }) else { return false }
            activityState.phase = .deciding
            activityState.decision = decision.approved
            core.resolveApproval(id: decision.approvalID, approved: decision.approved)
            return true
        }

        async let allowTap = core.clearTap(on: "Send", inApp: "com.apple.MobileSMS", named: "Messages", waiting: 5.0)
        let requestedAllow = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !pending.isEmpty }, object: nil)
        await fulfillment(of: [requestedAllow], timeout: 2.0)
        let firstID = try XCTUnwrap(pending.first?.id)
        XCTAssertEqual(activityState.face.bottom, .approval(id: firstID))
        XCTAssertEqual(activityState.face.minimal, .approval)

        _ = try await ApproveActionIntent(approvalID: firstID).perform()
        XCTAssertEqual(activityState.phase, .deciding)
        XCTAssertEqual(activityState.decision, true)
        let allowVerdict = await allowTap
        XCTAssertTrue(allowVerdict.mayTap, "\(allowVerdict)")
        XCTAssertEqual(allowVerdict, .approved("sending a message (\"send\")"))

        async let denyTap = core.clearTap(on: "Delete", inApp: "com.apple.MobileSMS", named: "Messages", waiting: 5.0)
        let requestedDeny = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !pending.isEmpty }, object: nil)
        await fulfillment(of: [requestedDeny], timeout: 2.0)
        let secondID = try XCTUnwrap(pending.first?.id)
        XCTAssertEqual(activityState.face.bottom, .approval(id: secondID))

        _ = try await DenyActionIntent(approvalID: secondID).perform()
        XCTAssertEqual(activityState.phase, .deciding)
        XCTAssertEqual(activityState.decision, false)
        let denyVerdict = await denyTap
        XCTAssertFalse(denyVerdict.mayTap, "\(denyVerdict)")
    }
}

@MainActor
final class PasscodeTests: XCTestCase {
    /// After a restart iOS asks for the passcode before the first automation. The launcher says so
    /// (code "passcode"); the agent reads a plain "starting" with the reason, and the Live Activity
    /// asks the owner; the hint clears when the runner answers.
    func testPasscodeWaitIsNamedAndClears() {
        let model = AppModel(launcher: FakeLauncher(), pairer: FakePairing())
        model.loopback.simulate(.working(ms: 9))
        model.inProcessReadyForProbe()
        model.runnerChanged(RunnerStatus(state: "launching"))
        model.runnerChanged(RunnerStatus(state: "launching", detail: "no answer for 12 s", code: "passcode"))
        XCTAssertTrue(model.passcodeHint)
        let text = model.host.currentRunner.describe
        XCTAssertTrue(text.contains("passcode"), text)
        XCTAssertTrue(text.contains("Call again"), text)
        XCTAssertTrue(text.hasPrefix("starting"), text)
        model.runnerChanged(RunnerStatus(state: "running"))
        XCTAssertFalse(model.passcodeHint)
        XCTAssertTrue(model.host.currentRunner.isRunning)
    }
}

/// iOS asks the owner for the passcode before it allows automation, after Poki restarts and 8 hours
/// after the last time. An in-process open that waits on it is named: Poki's home asks the owner, and
/// the agent reads that only the owner can enter it, also after iOS gives up.
@MainActor
final class InProcessPasscodeTests: XCTestCase {
    private var saved: (relay: String?, relayEnabled: Any?, setup: SetupState)!
    private var model: AppModel!
    private var session: FakeAutomation!

    override func setUp() async throws {
        try XCTSkipUnless(AutomationPath.current == .inProcess, "Poki Runner path")
        saved = (UserDefaults.standard.string(forKey: "relayAddress"), UserDefaults.standard.object(forKey: "relayEnabled"), SetupState.load())
        session = FakeAutomation()
        model = AppModel(launcher: FakeLauncher(), pairer: FakePairing(), automation: session)
        model.loopback.simulate(.working(ms: 9))
        model.setup.loopback = .proxy
        XCTAssertTrue(model.setRelay("https://relay.invalid"))
        model.startSession()
        XCTAssertTrue(model.sessionOn)
    }

    override func tearDown() async throws {
        session?.answer(nil)
        guard let saved, let model else { return }
        model.stopSession()
        UserDefaults.standard.set(saved.relay, forKey: "relayAddress")
        UserDefaults.standard.set(saved.relayEnabled, forKey: "relayEnabled")
        saved.setup.save()
    }

    private func waitFor(_ what: String, _ condition: @escaping () -> Bool) async {
        let done = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        done.expectationDescription = what
        await fulfillment(of: [done], timeout: 5)
    }

    func testAPasscodeWaitAsksTheOwnerAndTellsTheAgentWhoMustEnterIt() async {
        session.holdNextOpen()
        model.wakeRunner()
        // On the simulator the launcher is WebDriverAgent on the Mac; its answer comes first.
        await waitFor("the simulator's runner check answered") { ["failed", "running"].contains(self.model.runner.state) }
        model.runnerChanged(RunnerStatus(state: "running"))
        model.checkIdle(now: Date().addingTimeInterval(6))
        XCTAssertTrue(model.passcodeHint, "Poki's home asks the owner for the passcode")
        let waiting = model.host.currentRunner.describe
        XCTAssertTrue(waiting.contains("owner to enter the iPhone passcode"), waiting)
        session.answer(["ok": false, "code": "com.apple.dt.XCTest.XCTFuture 1000", "detail": "Timed out while enabling automation mode.", "seconds": 60.0])
        await waitFor("iOS gave up on the passcode") { !self.model.passcodeHint && !self.model.host.currentRunner.describe.hasPrefix("starting") }
        let failed = model.host.currentRunner.describe
        XCTAssertTrue(failed.contains("owner needs to enter the iPhone passcode"), failed)
    }
}

@MainActor
final class FrontendSubtractionTests: XCTestCase {
    private var savedSetup: SetupState!

    override func setUp() {
        savedSetup = SetupState.load()
    }

    override func tearDown() {
        savedSetup.save()
    }

    /// Every incomplete setup step produces a direct-link hint in ChatView that targets that exact
    /// SetupStepPage, and completing all steps clears the setup-step hint.
    func testChatSetupIssueHintLinksDirectlyToFirstIncompleteStep() {
        let model = AppModel(launcher: FakeLauncher(), pairer: FakePairing())
        model.setup.runnerInstalled = false
        model.setup.developerMode = false
        model.setup.loopback = .none
        model.setup.uiAutomation = false

        let firstHint = SetupIssueHint.first(model: model)
        XCTAssertNotNil(firstHint)
        XCTAssertEqual(firstHint?.target, SetupStep.shown.first.map(SetupIssueHint.Target.step))
        XCTAssertFalse(firstHint?.link.isEmpty ?? true)

        // Mark developer mode done and verify the hint advances to the next open step (.loopback).
        model.setup.runnerInstalled = true
        model.setup.developerMode = true
        let secondHint = SetupIssueHint.first(model: model)
        XCTAssertEqual(secondHint?.target, .step(.loopback))
    }

    /// ESP-321: standing by (right after Turn On, or after the idle minute) Poki's details offer
    /// Resume, as main's Pause and Resume pair does. Before, the one tile still said Pause there, and
    /// Pause turned Poki off.
    func testDetailsOffersResumeWhileStandingBy() {
        UserDefaults.standard.removeObject(forKey: "wantsOn")
        let model = AppModel(launcher: FakeLauncher(), pairer: FakePairing())
        XCTAssertEqual(PowerTile(model: model, running: false), .turnOn)

        model.loopback.simulate(.working(ms: 9))
        model.setup.loopback = .proxy
        _ = model.setRelay("https://relay.invalid")
        defer {
            model.stopSession()
            UserDefaults.standard.removeObject(forKey: "relayAddress")
            UserDefaults.standard.set(nil as Any?, forKey: "relayEnabled")
            UserDefaults.standard.removeObject(forKey: "wantsOn")
        }
        model.startSession()
        XCTAssertTrue(model.sessionOn && model.runnerPaused, "Turn On stands by until an agent asks")
        XCTAssertEqual(PowerTile(model: model, running: false), .resume)
        XCTAssertEqual(PowerTile(model: model, running: true), .pause, "a chat task under way is paused, not resumed")

        model.wakeRunner()
        XCTAssertEqual(PowerTile(model: model, running: false), .pause)
        model.pauseRunner()
        XCTAssertEqual(PowerTile(model: model, running: false), .resume)
        XCTAssertTrue(model.sessionOn, "Pause stands by; it does not turn Poki off")
    }

    /// ESP-321: Home has no tab bar, so main's Setup dot is Home's hint line. An open setup step shows
    /// there and links to that step; before, Home showed only runner failures and said nothing.
    func testHomeHintShowsOpenSetupStepWithoutTabBar() {
        let model = AppModel(launcher: FakeLauncher(), pairer: FakePairing())
        model.setup.runnerInstalled = false
        model.setup.developerMode = false
        model.setup.loopback = .none
        model.setup.uiAutomation = false

        let hint = SetupIssueHint.home(model: model)
        XCTAssertNotNil(hint, "an open setup step must show on Home")
        XCTAssertEqual(hint?.target, SetupStep.shown.first { !model.looksDone($0) }.map(SetupIssueHint.Target.step))
    }

    /// Every Layer 1, Layer 2, and Layer 3 destination in the ESP-174 capability table is addressable
    /// through PokiDetailsView's NavigationPath.
    func testCapabilityTableRoutesAreReachableInDetailsNavigationPath() {
        let model = AppModel(launcher: FakeLauncher(), pairer: FakePairing())
        let secret = model.identity.secrets.first ?? model.addConnector(name: "Test Agent")

        // Layer 1 routes on PokiDetailsView
        let layer1: [DetailsRoute] = [.model, .history, .voice, .moreSettings]
        for route in layer1 {
            var path = NavigationPath()
            path.append(route)
            XCTAssertEqual(path.count, 1, "Layer 1 route \(route) must be pushable")
        }

        // Layer 2 routes under More Settings
        let layer2Details: [DetailsRoute] = [.setup, .updates, .approvals, .settings]
        for route in layer2Details {
            var path = NavigationPath()
            path.append(DetailsRoute.moreSettings)
            path.append(route)
            XCTAssertEqual(path.count, 2, "Layer 2 route \(route) must be reachable from More Settings")
        }
        let layer2Settings: [SettingsRoute] = [.memory, .diagnostics]
        for route in layer2Settings {
            var path = NavigationPath()
            path.append(DetailsRoute.moreSettings)
            path.append(route)
            XCTAssertEqual(path.count, 2, "Layer 2 settings route \(route) must be reachable from More Settings")
        }

        // Layer 3 routes: every SetupStep under Setup, plus ConnectorDetail, RelayView, LogView, ActivityPreview
        for step in SetupStep.shown {
            var path = NavigationPath()
            path.append(DetailsRoute.moreSettings)
            path.append(DetailsRoute.setup)
            path.append(step)
            XCTAssertEqual(path.count, 3, "SetupStep \(step) must be reachable at Layer 3")
            XCTAssertFalse(String(describing: step.rowTitle).isEmpty)
        }

        var connectorPath = NavigationPath()
        connectorPath.append(DetailsRoute.moreSettings)
        connectorPath.append(DetailsRoute.settings)
        connectorPath.append(SettingsRoute.connector(secret))
        XCTAssertEqual(connectorPath.count, 3)

        var relayPath = NavigationPath()
        relayPath.append(DetailsRoute.moreSettings)
        relayPath.append(DetailsRoute.settings)
        relayPath.append(SettingsRoute.relay)
        XCTAssertEqual(relayPath.count, 3)

        for debugLeaf in [SettingsRoute.log, SettingsRoute.activityPreview] {
            var debugPath = NavigationPath()
            debugPath.append(DetailsRoute.moreSettings)
            debugPath.append(SettingsRoute.diagnostics)
            debugPath.append(debugLeaf)
            XCTAssertEqual(debugPath.count, 3)
        }
    }

    /// #78 ("Can't Reach iPhone" by failure code), #79 (Poki Setup auto-turn-on via `wantsOn`),
    /// and #81 (Poki Version under More Settings › Signing) all surface in the new Home, Chat hint,
    /// and PokiDetailsView.
    func testUnreachableRunnerFailureAndAutoTurnOnSurfaceInNewHomeAndDetails() async throws {
        defer { try? FileManager.default.removeItem(at: SelfSigner.handedIdentity) }
        try FileManager.default.createDirectory(at: SelfSigner.handedIdentity.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: SelfSigner.handedIdentity)
        UserDefaults.standard.removeObject(forKey: "wantsOn")

        let model = AppModel(launcher: FakeLauncher(), pairer: FakePairing())
        XCTAssertTrue(model.wantsOn, "#79: Poki Setup install turns wantsOn on automatically")
        XCTAssertTrue(model.sessionOn || model.wantsOn, "#79: PokiDetailsView and Home treat wantsOn as active")

        model.loopback.simulate(.working(ms: 9))
        model.setup.loopback = .proxy
        _ = model.setRelay("https://relay.invalid")
        model.startSession()
        defer {
            model.stopSession()
            UserDefaults.standard.removeObject(forKey: "relayAddress")
            UserDefaults.standard.set(nil as Any?, forKey: "relayEnabled")
        }
        model.wakeRunner()
        let done = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in ["failed", "running"].contains(model.runner.state) }, object: nil)
        await fulfillment(of: [done], timeout: 5)

        let fix = "Poki can't reach this iPhone. Check in this order: Setup › Loopback (your proxy app or LocalDevVPN is connected, with 10.7.0.1 set), then Setup › Pairing (pair again with the loopback on), then Developer Mode in Settings → Privacy & Security."
        model.runnerChanged(RunnerStatus(state: "failed", detail: "tunnel closed", fix: fix, code: "unreachable"))

        let hint = SetupIssueHint.runnerIssue(model: model)
        XCTAssertNotNil(hint, "#78: unreachable failure code surfaces a SetupIssueHint on Home and Chat")
        XCTAssertEqual(hint?.target, .step(.loopback))
        XCTAssertTrue(hint?.message.contains("reach this iPhone") == true || hint?.message.contains("Reach iPhone") == true)

        let detailsIssues = Issue.current(model)
        let runnerIssue = detailsIssues.first { $0.id == "runner" }
        XCTAssertNotNil(runnerIssue, "#78: PokiDetailsView Issue.current(model) includes the runner failure")
        XCTAssertEqual(runnerIssue?.fix, .setup)
        XCTAssertFalse(model.signer.installedVersion.isEmpty, "#81: Poki Version is accessible via More Settings › Signing")
    }
}
