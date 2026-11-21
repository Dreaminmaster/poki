import PokiCore
import SwiftUI
import UIKit
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
    var isOpen: Bool { lock.withLock { open } }
    private var gate: DispatchSemaphore?
    private var heldOpenStarted = false
    private var answer: [String: Any]?
    var onPrepare: (@Sendable () -> Void)?
    var openingDelay: TimeInterval = 0
    private var requested: TimeInterval = 0
    private var ready: TimeInterval = 0
    var openingTimes: (requested: TimeInterval, ready: TimeInterval) { lock.withLock { (requested, ready) } }
    /// The next open waits until `answer(_:)`.
    func holdNextOpen() { lock.withLock { gate = DispatchSemaphore(value: 0); heldOpenStarted = false } }
    var isHoldingOpen: Bool { lock.withLock { gate != nil && heldOpenStarted } }
    /// Lets a held open go on, with this answer instead of opening (nil opens).
    func answer(_ result: [String: Any]?) { lock.withLock { answer = result; gate?.signal(); gate = nil } }
    func prepare() -> [String: Any] {
        lock.withLock { requested = ProcessInfo.processInfo.systemUptime }
        onPrepare?()
        if openingDelay > 0 { Thread.sleep(forTimeInterval: openingDelay) }
        if let held = lock.withLock({ () -> DispatchSemaphore? in heldOpenStarted = gate != nil; return gate }) {
            held.wait()
            if let given = lock.withLock({ () -> [String: Any]? in defer { answer = nil }; return answer }) { return given }
        }
        return lock.withLock {
            prepareCalls += 1
            if open, paused, failResume {
                open = false; paused = false; failResume = false
                return ["ok": false, "code": "session_unreadable", "detail": "no element tree after resuming", "generation": 1, "seconds": 0.0]
            }
            let reused = open
            open = true
            paused = false
            ready = ProcessInfo.processInfo.systemUptime
            return ["ok": true, "generation": 1, "reused": reused, "seconds": 0.0]
        }
    }
    func close() -> [String: Any] {
        lock.withLock { defer { if open { closeCalls += 1 }; open = false; paused = false }; return ["closed": open, "generation": 1, "seconds": 0.0] }
    }
    /// Automation Mode off with the session kept, as iOS does it: the session stays open until the next prepare turns it on.
    func pauseAutomation() -> [String: Any] {
        let (held, started) = lock.withLock { (pauseGate, onPause) }
        started?()
        held?.wait()
        return lock.withLock {
            guard open else { return ["paused": false, "how": "no session"] }
            if failPause { failPause = false; return ["paused": false, "how": "none offered"] }
            paused = true
            pauseCalls += 1
            return ["paused": true, "how": "fake"]
        }
    }
    private var pauseGate: DispatchSemaphore?
    private var onPause: (@Sendable () -> Void)?
    func holdNextPause(started: @escaping @Sendable () -> Void) {
        lock.withLock { pauseGate = DispatchSemaphore(value: 0); onPause = started }
    }
    func releasePause() {
        lock.withLock { pauseGate?.signal(); pauseGate = nil; onPause = nil }
    }
    private var paused = false
    /// Sessions that were open when closed, and pauses of an open session.
    private var closeCalls = 0, pauseCalls = 0, prepareCalls = 0
    private var failResume = false
    private var failPause = false
    func failNextPause() { lock.withLock { failPause = true } }
    var closes: Int { lock.withLock { closeCalls } }
    var pauses: Int { lock.withLock { pauseCalls } }
    var prepares: Int { lock.withLock { prepareCalls } }
    /// The next prepare of a session that was paused cannot read again: the session ends, as a native session that fails its read check does.
    func failNextResume() { lock.withLock { failResume = true } }
    /// How long iOS has held its "allow automation" call in the open under way.
    func setAuthorizationWait(_ seconds: Double) { lock.withLock { authorizationWait = seconds } }
    private var authorizationWait = 0.0
    func authorizationWaitSeconds() -> Double { lock.withLock { authorizationWait } }
}

final class FakePairing: DevicePairing {
    func start(hostName: String, saveTo: URL, onEvent: @escaping @Sendable (PairingEvent) -> Void) throws {}
    func cancel() {}
}

@MainActor
final class AppModelTests: XCTestCase {
    private var language = AppLocalization.system

    /// The loopback's words follow Poki's language; these tests read the English ones.
    override func setUp() async throws {
        language = AppLocalization.shared.preference
        AppLocalization.shared.preference = "en"
    }

    override func tearDown() async throws { AppLocalization.shared.preference = language }

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
        let preparing = model.coreState(of: RunnerStatus(state: "running"))
        XCTAssertFalse(preparing.isRunning, preparing.describe)
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

    /// iOS moved the remote pairing service off 49152: the port Bonjour lists that answers at
    /// 10.7.0.1 is the one, the refused port is not tried again, and another iPhone's port that
    /// does not answer here is passed over.
    @MainActor func testTheMovedPairingPortIsTheListedOneThatAnswers() async {
        var tried: [UInt16] = []
        let search = await RemotePairingPort.search(besides: 49152, browse: { ([49152, 51000, 53900, 60000], nil) }) { port in
            tried.append(port)
            return port == 53900
        }
        XCTAssertEqual(search.found, 53900)
        XCTAssertEqual(tried, [51000, 53900])
        XCTAssertTrue(search.said(besides: 49152).contains("answers on port 53900"))
    }

    /// Nothing listed, or nothing listed answers: no port is made up, and the log says which it was.
    @MainActor func testNoPairingPortIsInventedWhenBonjourHasNone() async {
        let empty = await RemotePairingPort.search(besides: 49152, browse: { ([], nil) }) { _ in true }
        XCTAssertNil(empty.found)
        XCTAssertTrue(empty.said(besides: 49152).contains("lists no remote pairing service"))
        let same = await RemotePairingPort.search(besides: 49152, browse: { ([49152], nil) }) { _ in true }
        XCTAssertNil(same.found)
        let denied = await RemotePairingPort.search(besides: 49152, browse: { ([], "Bonjour error -72008") }) { _ in true }
        XCTAssertTrue(denied.said(besides: 49152).contains("could not be searched"))
    }

    /// On cellular alone a refused port is iOS refusing the loopback (GitHub issue 35), and a mounted
    /// disk image goes to Poki's own session: Poki does not look for a moved port there. Elsewhere it
    /// looks at once, after 10 s and after 30 s more, and then no more.
    func testNoPortIsLookedUpOnCellularAloneAndThreeLooksAtMostElsewhere() {
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertFalse(RemotePairingPort.lookDue(cellularOnly: true, looks: 0, lastAt: .distantPast, now: start))
        XCTAssertTrue(RemotePairingPort.lookDue(cellularOnly: false, looks: 0, lastAt: .distantPast, now: start))
        XCTAssertFalse(RemotePairingPort.lookDue(cellularOnly: false, looks: 1, lastAt: start, now: start.addingTimeInterval(9)))
        XCTAssertTrue(RemotePairingPort.lookDue(cellularOnly: false, looks: 1, lastAt: start, now: start.addingTimeInterval(10)))
        XCTAssertTrue(RemotePairingPort.lookDue(cellularOnly: false, looks: 2, lastAt: start, now: start.addingTimeInterval(30)))
        XCTAssertFalse(RemotePairingPort.lookDue(cellularOnly: false, looks: 3, lastAt: start, now: start.addingTimeInterval(3_600)))
    }

    /// The phone refused the pairing port while the loopback works: the agent is not told to turn
    /// the loopback on.
    func testARefusedPairingPortIsNotCalledNeedsLoopback() {
        let refused = RunnerStatus(state: "waiting_network", detail: "remote pairing connect failed", code: "pairing_port")
        XCTAssertEqual(refused.title, "Finding the pairing port")
        XCTAssertEqual(RunnerStatus(state: "waiting_network", code: "loopback").title, "Needs loopback")
        XCTAssertEqual(AppModel.problemText(code: "pairing_port", fix: "x"), "Finding Pairing Port")
    }

    /// With the loopback up, the launcher's own words stand.
    func testLoopbackUpKeepsTheLauncherState() {
        let (model, _) = model()
        model.loopback.simulate(.working(ms: 9))
        XCTAssertEqual(model.coreState(of: RunnerStatus(state: "pairing")).describe, "starting (Checking pairing)")
    }

    func testWorkingLoopbackDoesNotAskForWiFi() {
        let (model, _) = model()
        model.loopback.simulate(.working(ms: 9))
        XCTAssertFalse(model.loopback.onWiFi)
        XCTAssertFalse(model.loopback.cellularOnly)
        XCTAssertEqual(model.loopback.detail, "This iPhone answers at 10.7.0.1 (9 ms).")
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

    /// Without an Apple Account Poki still looks up the channel's newest build when it starts (ESP-387),
    /// so Home and Signing can say an update is out. On a simulator `-pokiLatest newer` answers for GitHub.
    func testLooksUpTheNewestBuildWithoutAnAppleAccount() async {
        UserDefaults.standard.set("newer", forKey: "pokiLatest")
        defer { UserDefaults.standard.removeObject(forKey: "pokiLatest") }
        let (model, _) = model()
        model.startSigner()
        let found = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in MainActor.assumeIsolated { model.signer.latest != nil } }, object: nil)
        found.expectationDescription = "the newest build is known"
        await fulfillment(of: [found], timeout: 10)
        XCTAssertFalse(model.signer.signedIn)
        XCTAssertTrue(model.signer.updateAvailable)
    }

    /// The Signing page's next step under Status (ESP-387): signed in it is one tap, without an Apple
    /// Account the way to sign in or to Poki Setup, a signed copy is installed, and up to date it is nothing.
    func testSigningPageOffersTheWayToTheUpdate() {
        XCTAssertEqual(UpdateStep(updateAvailable: true, copyReady: false, signedIn: false), .signIn)
        XCTAssertEqual(UpdateStep(updateAvailable: true, copyReady: false, signedIn: true), .download)
        XCTAssertEqual(UpdateStep(updateAvailable: true, copyReady: true, signedIn: false), .install)
        XCTAssertNil(UpdateStep(updateAvailable: false, copyReady: false, signedIn: true), "up to date")
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
    private let keys = [LiveCore.askKey, ApprovalClassifier.modeKey, ApprovalChoice.earlierModeKey, ApprovalClassifier.onKey, ApprovalClassifier.levelKey]
    private var saved: [String: Any] = [:]
    override func setUp() {
        for key in keys { saved[key] = UserDefaults.standard.object(forKey: key) }
        UserDefaults.standard.removeObject(forKey: ApprovalClassifier.modeKey)
        UserDefaults.standard.removeObject(forKey: ApprovalChoice.earlierModeKey)
        UserDefaults.standard.removeObject(forKey: ApprovalClassifier.levelKey)
        UserDefaults.standard.removeObject(forKey: LiveCore.askKey)
        UserDefaults.standard.removeObject(forKey: ApprovalClassifier.onKey)
    }
    override func tearDown() {
        for key in keys { UserDefaults.standard.set(saved[key], forKey: key) }
    }

    /// Where each owner lands after installing over 752 is `ApprovalChoiceTests` in PokiCore. Here: a
    /// sensitivity picked on its own, with no way of asking chosen yet, is kept after a restart.
    func testASensitivityPickedAloneIsKept() {
        UserDefaults.standard.removeObject(forKey: LiveCore.askKey)
        UserDefaults.standard.removeObject(forKey: ApprovalClassifier.onKey)
        let model = AppModel(launcher: FakeLauncher(), pairer: FakePairing())
        model.classifierLevel = .strict
        XCTAssertEqual(ApprovalClassifier.Level.saved, .strict, "what route() reads")
        XCTAssertEqual(AppModel(launcher: FakeLauncher(), pairer: FakePairing()).classifierLevel, .strict, "after a restart")
    }

    /// An owner who never chose, then picks how to be asked in Approvals, keeps the sensitivity Approvals shows:
    /// Ask All. Saving the way of asking must not move the sensitivity to Balanced, where the
    /// chat model's yes lets a step through, behind a slider that still reads Ask All.
    func testChoosingHowToBeAskedKeepsTheSensitivityRulesShows() {
        UserDefaults.standard.removeObject(forKey: LiveCore.askKey)
        UserDefaults.standard.removeObject(forKey: ApprovalClassifier.onKey)
        let model = AppModel(launcher: FakeLauncher(), pairer: FakePairing())
        XCTAssertEqual(model.classifierLevel, .everything)
        model.approvalMode = .off
        model.approvalMode = .reply
        XCTAssertEqual(ApprovalClassifier.Level.saved, .everything, "what route() reads")
        XCTAssertEqual(AppModel(launcher: FakeLauncher(), pairer: FakePairing()).classifierLevel, .everything, "after a restart")
    }

    /// A phone that never chose (a new install, or an owner of an earlier version who never opened
    /// Approvals) is not asked: the Send tap in Messages goes through, and the page reads Never Ask.
    func testAPhoneThatNeverChoseIsNotAsked() async {
        let core = LiveCore(host: AppCoreHost(), transport: URLSessionTransport())
        let tap = await core.clearTap(on: "Send", inApp: "com.apple.MobileSMS", named: "Messages", waiting: 0.2)
        XCTAssertEqual(tap, .clear)
        XCTAssertEqual(AppModel(launcher: FakeLauncher(), pairer: FakePairing()).approvalMode, .off)
    }

    /// An owner who chose a way of asking, here or on 0.3.1, is still asked after updating.
    func testAnOwnerWhoChoseKeepsTheirChoice() async {
        UserDefaults.standard.set(ApprovalClassifier.Mode.reply.rawValue, forKey: ApprovalClassifier.modeKey)
        XCTAssertEqual(AppModel(launcher: FakeLauncher(), pairer: FakePairing()).approvalMode, .reply)
        UserDefaults.standard.removeObject(forKey: ApprovalClassifier.modeKey)
        UserDefaults.standard.set(true, forKey: LiveCore.askKey)
        let core = LiveCore(host: AppCoreHost(), transport: URLSessionTransport())
        let tap = await core.clearTap(on: "Send", inApp: "com.apple.MobileSMS", named: "Messages", waiting: 0.2)
        XCTAssertFalse(tap.mayTap, "\(tap)")
        XCTAssertEqual(AppModel(launcher: FakeLauncher(), pairer: FakePairing()).approvalMode, .confirm)
    }

    /// Don’t Ask Again, from the Live Activity or a notification (the intent) or from the card in Poki:
    /// approvals are off from then on, after a restart too, and the chat says how to turn them back on.
    func testDontAskAgainTurnsApprovalsOff() async throws {
        let language = AppLocalization.shared.preference
        AppLocalization.shared.preference = "en"
        defer { AppLocalization.shared.preference = language }
        UserDefaults.standard.set(ApprovalClassifier.Mode.confirm.rawValue, forKey: ApprovalClassifier.modeKey)
        let model = AppModel(launcher: FakeLauncher(), pairer: FakePairing())
        let chat = ChatModel(app: model)
        XCTAssertEqual(model.approvalMode, .confirm)
        _ = try await StopAskingIntent(approvalID: "answered-elsewhere").perform()
        XCTAssertEqual(model.approvalMode, .off)
        XCTAssertEqual(AppModel(launcher: FakeLauncher(), pairer: FakePairing()).approvalMode, .off, "after a restart")
        let said = chat.entries.compactMap { entry -> String? in if case .poki(let text) = entry.kind { text } else { nil } }
        XCTAssertTrue(said.contains { $0.contains("Approvals are off") && $0.contains("poki://approvals") }, "\(said)")

        model.approvalMode = .confirm
        model.stopAsking(PendingApproval(id: "card", app: "Messages", summary: "Tap Send", reason: "sending a message (\"send\")", expires: Date().addingTimeInterval(60)))
        XCTAssertEqual(model.approvalMode, .off)
    }

    /// The card offers Don’t Ask Again where Never Ask would stop the asking, as PokiCore judges the steps
    /// (a message, not a payment or a deletion), so a payment cannot be allowed by a tap on it.
    func testTheCardOffersDontAskAgainOnlyWhereNeverAskStopsAsking() async throws {
        UserDefaults.standard.set(ApprovalClassifier.Mode.confirm.rawValue, forKey: ApprovalClassifier.modeKey)
        let core = LiveCore(host: AppCoreHost(), transport: URLSessionTransport())
        var pending: [PendingApproval] = []
        let eventsTask = Task { @MainActor in
            for await event in core.events { if case .approvalRequested(let approval) = event { pending.append(approval) } }
        }
        defer { eventsTask.cancel() }
        for (label, offered) in [("Send", true), ("Pay", false), ("Delete", false)] {
            pending.removeAll()
            _ = await core.clearTap(on: label, inApp: "com.apple.MobileSMS", named: "Messages", waiting: 0.3)
            let approval = try XCTUnwrap(pending.first, "\(label) raised no approval")
            XCTAssertEqual(approval.offersStopAsking, offered, "\(label): \(approval.reason)")
            var card = PokiState(phase: .approval, headline: "Allow this step?", thumbnailVersion: 0)
            card.approval = approval
            XCTAssertEqual(card.face.offersStopAsking, offered, label)
        }
    }

    /// An owner who turned asking off keeps that choice.
    func testAnOwnerWhoTurnedAskingOffIsNotAsked() async {
        UserDefaults.standard.set(false, forKey: LiveCore.askKey)
        let core = LiveCore(host: AppCoreHost(), transport: URLSessionTransport())
        let tap = await core.clearTap(on: "Send", inApp: "com.apple.MobileSMS", named: "Messages", waiting: 0.2)
        XCTAssertEqual(tap, .clear)
    }

    func testPaymentsAndDeletionsAlwaysRequireTheOwner() async {
        UserDefaults.standard.set(ApprovalClassifier.Mode.off.rawValue, forKey: ApprovalClassifier.modeKey)
        let core = LiveCore(host: AppCoreHost(), transport: URLSessionTransport())
        for (label, reason) in [("Pay", "a payment (\"pay\")"), ("Delete", "deleting (\"delete\")")] {
            let tap = await core.clearTap(on: label, inApp: "com.apple.MobileSMS", named: "Messages", waiting: 0.01)
            XCTAssertFalse(tap.mayTap, "Never must not bypass \(label)")
            for mode in ApprovalClassifier.Mode.allCases {
                UserDefaults.standard.set(mode.rawValue, forKey: ApprovalClassifier.modeKey)
                let approval = PendingApproval(id: UUID().uuidString, app: "Messages", summary: label,
                                               reason: reason, expires: Date().addingTimeInterval(60))
                XCTAssertEqual(ApprovalClassifier.route(approval, voiceOn: true), .owner)
            }
        }
    }

    /// Allow and Don’t Allow on the Live Activity: the card for a waiting approval carries the buttons
    /// for that approval, and each button's intent reaches PokiCore, which lets the held tap through
    /// or refuses it. The bridge handler is AppModel's forwarding without its pause for the island to
    /// fold (AppModel.decide), which this does not cover.
    func testLiveActivityAllowAndDenyAnswerTheWaitingTap() async throws {
        UserDefaults.standard.set(ApprovalClassifier.Mode.confirm.rawValue, forKey: ApprovalClassifier.modeKey)
        let core = LiveCore(host: AppCoreHost(), transport: URLSessionTransport())
        var pending: [PendingApproval] = []
        let eventsTask = Task { @MainActor in
            for await event in core.events {
                switch event {
                case .approvalRequested(let approval): pending.append(approval)
                case .approvalEnded(let id, _): pending.removeAll { $0.id == id }
                default: break
                }
            }
        }
        defer { eventsTask.cancel() }
        ApprovalIntentBridge.install { decision in
            core.resolveApproval(id: decision.approvalID, approved: decision.approved)
            return true
        }
        defer { ApprovalIntentBridge.install { _ in false } }

        async let allowTap = core.clearTap(on: "Send", inApp: "com.apple.MobileSMS", named: "Messages", waiting: 5.0)
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !pending.isEmpty }, object: nil)], timeout: 2.0)
        let first = try XCTUnwrap(pending.first)
        var card = PokiState(phase: .approval, headline: "Allow this step?", thumbnailVersion: 0)
        card.approval = first
        XCTAssertEqual(card.face.bottom, .approval(id: first.id))
        _ = try await ApproveActionIntent(approvalID: first.id).perform()
        let allowVerdict = await allowTap
        XCTAssertEqual(allowVerdict, .approved("sending a message (\"send\")"))

        async let denyTap = core.clearTap(on: "Delete", inApp: "com.apple.MobileSMS", named: "Messages", waiting: 5.0)
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !pending.isEmpty }, object: nil)], timeout: 2.0)
        let second = try XCTUnwrap(pending.first)
        _ = try await DenyActionIntent(approvalID: second.id).perform()
        let denyVerdict = await denyTap
        XCTAssertFalse(denyVerdict.mayTap, "\(denyVerdict)")
    }
}

@MainActor
final class PasscodeTests: XCTestCase {
    /// After a restart iOS asks for the passcode before the first automation. The launcher says so
    /// (code "passcode"); the tool waits for the owner, and the Live Activity asks them.
    func testRunnerPasscodePromptReportsAuthorizationWaitUntilReady() {
        let model = AppModel(launcher: FakeLauncher(), pairer: FakePairing())
        model.loopback.simulate(.working(ms: 9))
        model.inProcessReadyForProbe()
        model.runnerChanged(RunnerStatus(state: "launching"))
        model.runnerChanged(RunnerStatus(state: "launching", detail: "no answer for 12 s", code: "passcode"))
        XCTAssertTrue(model.passcodeHint)
        let text = model.host.currentRunner.describe
        XCTAssertTrue(text.contains("passcode"), text)
        guard case .awaitingAutomationAuthorization = model.host.currentRunner else {
            return XCTFail("The original tool cannot wait for the owner in state: \(text)")
        }
        model.runnerChanged(RunnerStatus(state: "running"))
        XCTAssertFalse(model.passcodeHint)
        XCTAssertTrue(model.host.currentRunner.isRunning)
    }

    /// ESP-451: in 0.3.1 the passcode note's title was Chinese and its body English, because the
    /// catalog had no entry for the body's exact text. Looked up in the built app's own tables.
    func testPasscodeNoteBodyIsTranslated() throws {
        let key = AppModel.passcodeHeadsUpMessage.key
        for language in ["zh-Hans", "zh-Hant"] {
            let path = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj"), language)
            let table = try XCTUnwrap(Bundle(path: path), language)
            let text = table.localizedString(forKey: key, value: "untranslated", table: nil)
            XCTAssertNotEqual(text, "untranslated", "\(language) has no entry for the passcode note's body")
        }
    }
}

/// iOS asks the owner for the passcode before it allows automation, after Poki restarts and 8 hours
/// after the last time. An in-process open that waits on it is named: Poki's home asks the owner, and
/// the agent reads that only the owner can enter it, also after iOS gives up.
@MainActor
final class InProcessPasscodeTests: XCTestCase {
    private var saved: (relay: String?, relayEnabled: Any?, setup: SetupState)!
    private var savedAllowance: Any?
    private var model: AppModel!
    private var session: FakeAutomation!
    private var launcher: FakeLauncher!

    override func setUp() async throws {
        try XCTSkipUnless(AutomationPath.current == .inProcess, "Poki Runner path")
        // The open gate is process-wide: a suite that sent Poki to the background before this one
        // must not leave each open here refused as "open Poki first".
        InProcessWDA.gate.withLock { $0 = InProcessWDA.OpenGate() }
        savedAllowance = UserDefaults.standard.object(forKey: AutomationAllowance.key)
        UserDefaults.standard.removeObject(forKey: AutomationAllowance.key)
        saved = (UserDefaults.standard.string(forKey: "relayAddress"), UserDefaults.standard.object(forKey: "relayEnabled"), SetupState.load())
        session = FakeAutomation()
        launcher = FakeLauncher()
        useSystem(27)
        XCTAssertTrue(model.sessionOn)
    }

    /// A fresh model on an iPhone running this iOS major version, with Poki on.
    private func useSystem(_ major: Int, transport: HTTPTransport? = nil) {
        model?.stopSession()
        model = AppModel(launcher: launcher, pairer: FakePairing(), automation: session, transport: transport,
                         systemVersion: OperatingSystemVersion(majorVersion: major, minorVersion: 6, patchVersion: 1))
        model.loopback.simulate(.working(ms: 9))
        model.setup.loopback = .proxy
        XCTAssertTrue(model.setRelay("https://relay.invalid"))
        model.startSession()
    }

    override func tearDown() async throws {
        session?.answer(nil)
        session?.releasePause()
        UserDefaults.standard.set(savedAllowance, forKey: AutomationAllowance.key)
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

    func testForegroundAndPrerequisitesDoNotEnableAutomation() async {
        let opened = expectation(description: "Automation Mode stays off without a phone task")
        opened.isInverted = true
        session.onPrepare = { opened.fulfill() }

        await prepareWithoutPhoneTask()
        model.becameActive()

        await fulfillment(of: [opened], timeout: 0.5)
        XCTAssertFalse(model.hasOpenInProcessSession)
    }

    func testCellularPreparationWaitsForTheImageWithoutOpeningAutomation() async {
        let opened = expectation(description: "Cellular preparation only mounts the developer image")
        opened.isInverted = true
        session.onPrepare = { opened.fulfill() }

        XCTAssertEqual(model.cellularPreparation(imageMounted: false), .ready)
        model.prepareForCellular()
        XCTAssertFalse(model.runnerPaused)
        XCTAssertEqual(model.cellularPreparation(imageMounted: false), .preparing)

        model.checkIdle(now: Date().addingTimeInterval(600))
        XCTAssertFalse(model.runnerPaused, "mounting can take longer than the idle interval")
        await finishPreparing()
        XCTAssertEqual(model.cellularPreparation(imageMounted: false), .retry, "a running launcher is not evidence of a mounted image")
        XCTAssertEqual(model.cellularPreparation(imageMounted: true), .mounted)

        model.prepareForCellular()
        XCTAssertEqual(model.cellularPreparation(imageMounted: false), .preparing)
        await finishPreparing()
        await fulfillment(of: [opened], timeout: 0.5)
        XCTAssertFalse(model.hasOpenInProcessSession)
    }

    func testCellularPreparationRequiresLocalConnectionAndRespectsOwnerPause() {
        model.loopback.simulate(.noAnswer)
        XCTAssertEqual(model.cellularPreparation(imageMounted: false), .needsLocalConnection)
        model.prepareForCellular()
        XCTAssertTrue(model.runnerPaused)

        model.loopback.simulate(.working(ms: 9))
        model.pauseByOwner()
        XCTAssertEqual(model.cellularPreparation(imageMounted: false), .automationOff)
        model.prepareForCellular()
        XCTAssertTrue(model.runnerPaused)
        XCTAssertTrue(model.ownerPaused)
        XCTAssertEqual(session.prepares, 0)
    }

    func testRemoteInitializationAndStatusWaitForPhoneReadToEnableAutomation() async {
        let opened = expectation(description: "Connecting an agent does not enable Automation Mode")
        opened.isInverted = true
        session.onPrepare = { opened.fulfill() }
        let transport = SessionScreenTransport(session: session)
        let core = PokiCore(config: CoreConfig(), host: model.host, transport: transport)

        let reply = await core.handle(RelayRequest(id: "initialize", method: "POST", headers: [:], body:
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"Test agent","version":"1"}}}"#))

        XCTAssertEqual(reply.status, 200)
        XCTAssertNotNil(reply.headers["mcp-session-id"])
        await finishPreparing()
        for _ in 0..<2 {
            let status = await core.handle(RelayRequest(id: "status", method: "POST", headers: [:], body:
                #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"status","arguments":{}}}"#))
            XCTAssertEqual(status.status, 200)
            XCTAssertTrue(status.body.contains("runner:"), status.body)
            XCTAssertFalse(status.body.contains("\"isError\":true"), status.body)
        }
        await fulfillment(of: [opened], timeout: 0.5)
        XCTAssertFalse(session.isOpen, "readonly status must not enable Automation Mode")
        XCTAssertFalse(model.hasOpenInProcessSession)

        session.onPrepare = nil
        let screen = await core.handle(RelayRequest(id: "phone-step", method: "POST", headers: [:], body:
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"look","arguments":{}}}"#))
        XCTAssertEqual(screen.status, 200)
        XCTAssertTrue(screen.body.contains("General"), screen.body)
        XCTAssertFalse(screen.body.contains("\"isError\":true"), screen.body)
        XCTAssertEqual(transport.screenReads, 1)
        XCTAssertTrue(session.isOpen)
    }

    func testPureChatCompletesWithoutAutomation() async throws {
        try await exerciseChatEntry(.send)
    }

    func testInputFocusPreparesWithoutOpeningAutomation() async throws {
        try await exerciseChatEntry(.focus)
    }

    func testDictationButtonPreparesWithoutOpeningAutomation() async throws {
        try await exerciseChatEntry(.dictation)
    }

    func testHomeShortcutPreparesWithoutOpeningAutomation() async throws {
        try await exerciseChatEntry(.shortcut)
    }

    private enum ChatEntryPoint: String { case focus, dictation, shortcut, send }

    private func exerciseChatEntry(_ entry: ChatEntryPoint) async throws {
        let keys = ["chat.provider", "chat.customURL", "chat.customModel", "custom.providers", "chat.customProvider", "chat.model.custom", "pokiDraft", "pokiDictationButton"]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { UserDefaults.standard.set(value, forKey: key) } }
        let server = try FakeCompletions(replies: Array(repeating: FakeCompletions.text("The answer is four."), count: 3))
        ModelKeys.customURL = "http://127.0.0.1:\(server.port)/v1"
        ModelKeys.customModel = "fake-model"
        ModelKeys.selectedProvider = .custom
        UserDefaults.standard.set(entry == .send ? "What is two plus two?" : "", forKey: "pokiDraft")
        UserDefaults.standard.set(true, forKey: "pokiDictationButton")
        await prepareWithoutPhoneTask()
        model.pauseRunner(byOwner: false)
        await withCheckedContinuation { done in model.closeInProcess("entry fixture") { done.resume() } }
        XCTAssertTrue(model.runnerPaused)
        let chat = ChatModel(app: model, kind: .handoff, requester: "Test agent")
        let accessibility = try XCTUnwrap(dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW))
        defer { dlclose(accessibility) }
        let isEnabled = unsafeBitCast(try XCTUnwrap(dlsym(accessibility, "_AXSAutomationEnabled")), to: (@convention(c) () -> Int32).self)
        let setEnabled = unsafeBitCast(try XCTUnwrap(dlsym(accessibility, "_AXSSetAutomationEnabled")), to: (@convention(c) (Int32) -> Void).self)
        let previous = isEnabled()
        setEnabled(1)
        defer { setEnabled(previous) }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        window.rootViewController = UIHostingController(rootView: NavigationStack {
            ChatView(openVoice: {}, openSetup: {}, openModel: {}, openThreads: {})
        }.environment(model).environment(chat).environment(\.accessibilityEnabled, true))
        window.makeKeyAndVisible()
        UIAccessibility.post(notification: .screenChanged, argument: window.rootViewController?.view)
        defer { window.endEditing(true); window.isHidden = true }
        await drawEntry(window)
        _ = try XCTUnwrap(Self.entryField(in: window))
        let opened = expectation(description: "\(entry.rawValue) prepares dependencies without enabling Automation Mode")
        opened.isInverted = true
        session.onPrepare = { opened.fulfill() }

        try await activateEntry(entry, window: window, chat: chat)
        if entry == .send {
            // The chat has already ended without touching the phone: like any task, it stood by
            // again at its end, and it never opened automation.
            await fulfillment(of: [opened], timeout: 0.2)
            XCTAssertTrue(model.runnerPaused, "a chat that never touched the phone stands by again when it ends")
            XCTAssertFalse(session.isOpen)
            XCTAssertFalse(model.hasOpenInProcessSession)
            return
        }
        await waitFor("the UI entry resumes prerequisites") { !self.model.runnerPaused }
        guard !model.runnerPaused else {
            await fulfillment(of: [opened], timeout: 0.2)
            return
        }
        await finishPreparing()
        try await activateEntry(entry, window: window, chat: chat)
        await fulfillment(of: [opened], timeout: 0.2)
        XCTAssertFalse(session.isOpen)
        XCTAssertFalse(model.hasOpenInProcessSession)

        session.onPrepare = nil
        let transport = SessionScreenTransport(session: session)
        let core = PokiCore(config: CoreConfig(), host: model.host, transport: transport)
        let read = await core.callTool("look", arguments: "{}")
        XCTAssertFalse(read.isError, read.text)
        XCTAssertTrue(read.text.contains("General"), read.text)
        XCTAssertEqual(transport.screenReads, 1)
        let reopened = expectation(description: "repeated UI entry keeps the existing session")
        reopened.isInverted = true
        session.onPrepare = { reopened.fulfill() }
        try await activateEntry(entry, window: window, chat: chat)
        await fulfillment(of: [reopened], timeout: 0.2)
        XCTAssertTrue(session.isOpen)
    }

    private func activateEntry(_ entry: ChatEntryPoint, window: UIWindow, chat: ChatModel) async throws {
        window.makeKeyAndVisible()
        await drawEntry(window)
        let field = try XCTUnwrap(Self.entryField(in: window))
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("OnDemandEvidence")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        try XCTUnwrap(image.pngData()).write(to: folder.appendingPathComponent("entry-\(entry.rawValue).png"))
        switch entry {
        case .focus:
            field.resignFirstResponder()
            await drawEntry(window)
            XCTAssertTrue(field.becomeFirstResponder())
            await drawEntry(window)
        case .dictation:
            // Repeating the entry first ends the dictation started by the previous activation.
            if let stop = Self.entryElement(in: window, matching: { $0 == "Stop Dictation" }) {
                XCTAssertTrue(stop.accessibilityActivate())
                await drawEntry(window)
            }
            let button = try XCTUnwrap(Self.entryElement(in: window, matching: { $0 == "composer.dictate" }))
            XCTAssertTrue(button.accessibilityActivate(), "activate the actual dictation button")
            await drawEntry(window)
        case .shortcut:
            field.resignFirstResponder()
            await drawEntry(window)
            let button = try XCTUnwrap(Self.entryElement(in: window, matching: { $0.hasPrefix("home.idea.") }))
            XCTAssertTrue(button.accessibilityActivate(), "activate an actual home shortcut")
            await drawEntry(window)
            XCTAssertFalse(field.plainText.isEmpty, "the shortcut fills the composer")
        case .send:
            if field.plainText.isEmpty {
                field.insertText("What is two plus two?")
                field.delegate?.textViewDidChange?(field)
                await drawEntry(window)
            }
            let button = try XCTUnwrap(Self.entryElement(in: window, matching: { $0 == "composer.main" }))
            XCTAssertTrue(button.accessibilityActivate(), "activate the actual send button")
            let completed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                !chat.running && chat.entries.contains { if case .poki(let text) = $0.kind { text == "The answer is four." } else { false } }
            }, object: nil)
            await fulfillment(of: [completed], timeout: 20)
            XCTAssertTrue(chat.savedCalls.isEmpty)
        }
    }

    private func drawEntry(_ window: UIWindow) async {
        window.layoutIfNeeded()
        let drawn = expectation(description: "the entry UI rendered")
        let frames = SessionEvidenceFrames { drawn.fulfill() }
        let display = CADisplayLink(target: frames, selector: #selector(SessionEvidenceFrames.tick))
        display.add(to: .main, forMode: .common)
        await fulfillment(of: [drawn], timeout: 5)
        display.invalidate()
    }

    private static func entryField(in view: UIView) -> CapsuleTextView? {
        if let field = view as? CapsuleTextView { return field }
        return view.subviews.lazy.compactMap { entryField(in: $0) }.first
    }

    private static func entryElement(in root: NSObject, matching matches: (String) -> Bool) -> NSObject? {
        var pending = [root]
        var visited = Set<ObjectIdentifier>()
        while let item = pending.popLast() {
            guard visited.insert(ObjectIdentifier(item)).inserted else { continue }
            let selector = NSSelectorFromString("accessibilityIdentifier")
            let identifier = item.responds(to: selector) ? item.perform(selector)?.takeUnretainedValue() as? String : nil
            if identifier.map(matches) == true || item.accessibilityLabel.map(matches) == true {
                let frame = item.accessibilityFrame
                let visible = (root as? UIView).map { $0.convert($0.bounds, to: nil) } ?? .zero
                let button = item.accessibilityTraits.contains(.button)
                if button && visible.contains(CGPoint(x: frame.midX, y: frame.midY)) && !frame.isEmpty { return item }
            }
            if let view = item as? UIView { pending.append(contentsOf: view.subviews) }
            if let children = item.accessibilityElements { pending.append(contentsOf: children.compactMap { $0 as? NSObject }) }
            let count = item.accessibilityElementCount()
            if count > 0 && count < 1000 {
                for index in 0..<count {
                    if let child = item.accessibilityElement(at: index) as? NSObject { pending.append(child) }
                }
            }
        }
        return nil
    }

    func testBrowserOnlyChatCompletesWithoutAutomation() async throws {
        let page = try PageServer(pages: ["/": "<html><head><title>Local fixture</title></head><body><p>Test capacity: 81 percent</p></body></html>"])
        defer { PokiBrowser.shared.close() }
        let server = try FakeCompletions(replies: [
            FakeCompletions.tool("web_open", ["url": "http://127.0.0.1:\(page.port)/"]),
            FakeCompletions.text("The page says 81 percent."),
        ])
        let chat = try await chatWithoutAutomation(on: server, request: "Read the capacity on this webpage.")

        XCTAssertTrue(chat.entries.contains { if case .poki(let text) = $0.kind { text == "The page says 81 percent." } else { false } })
        let call = try XCTUnwrap(chat.savedCalls.first)
        XCTAssertEqual(call.name, "web_open")
        XCTAssertTrue(call.ok)
        XCTAssertTrue(call.answer.contains("81 percent"))
        let modelInput = try JSONSerialization.data(withJSONObject: server.requests)
        XCTAssertTrue(String(decoding: modelInput, as: UTF8.self).contains("81 percent"), "the real page observation reached the model")
    }

    /// #468 review: the owner sends a message, then deletes that conversation before the model's first
    /// reply comes in, staying on the chat. The late reply must not bring it back, and the chat moves on
    /// to a new conversation. (Archiving waits: a conversation whose task runs is not archived.)
    func testAConversationDeletedBeforeItsFirstReplyStaysDeleted() async throws {
        let keys = ["chat.provider", "chat.customURL", "chat.customModel", "custom.providers", "chat.customProvider", "chat.model.custom"]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { UserDefaults.standard.set(value, forKey: key) } }
        let server = try FakeCompletions(replies: [FakeCompletions.text("Four.")], holdAfter: 0)
        ModelKeys.customURL = "http://127.0.0.1:\(server.port)/v1"
        ModelKeys.customModel = "fake-model"
        ModelKeys.selectedProvider = .custom
        await prepareWithoutPhoneTask()
        model.becameActive()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DeletedWhileWaiting-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let suite = "DeletedWhileWaiting-\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let store = SessionStore(folder: folder, defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        let chat = ChatModel(app: model, store: store)

        chat.send("What is two plus two?")
        let id = chat.sessionID
        await waitFor("the message reached the model") { !server.requests.isEmpty }
        XCTAssertTrue(chat.running)
        XCTAssertNotNil(store.session(id), "the owner's message saved the conversation")
        store.archive(id)
        XCTAssertNil(store.session(id)?.archived, "a conversation whose task runs is not archived")

        store.delete(id)
        XCTAssertEqual(store.removed?.id, id)
        chat.conversationLeft(id)
        XCTAssertFalse(chat.running, "the deleted conversation's task stops")
        XCTAssertNotEqual(chat.sessionID, id, "the chat moves on to a new conversation")

        server.release()
        try await Task.sleep(for: .seconds(1))
        XCTAssertNil(store.session(id), "the late reply does not bring the deleted conversation back")
        XCTAssertFalse(chat.entries.contains { $0.kind == .poki("Four.") }, "the new conversation does not show the late reply")
    }

    private func chatWithoutAutomation(on server: FakeCompletions, request: String) async throws -> ChatModel {
        let keys = ["chat.provider", "chat.customURL", "chat.customModel", "custom.providers", "chat.customProvider", "chat.model.custom"]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { UserDefaults.standard.set(value, forKey: key) } }
        ModelKeys.customURL = "http://127.0.0.1:\(server.port)/v1"
        ModelKeys.customModel = "fake-model"
        ModelKeys.selectedProvider = .custom
        let opened = expectation(description: "A task without phone tools leaves Automation Mode off")
        opened.isInverted = true
        session.onPrepare = { opened.fulfill() }
        await prepareWithoutPhoneTask()
        model.becameActive()
        let chat = ChatModel(app: model, kind: .handoff, requester: "Test agent")

        chat.send(request)
        let completed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !chat.running }, object: nil)
        await fulfillment(of: [completed], timeout: 20)
        await fulfillment(of: [opened], timeout: 0.1)
        XCTAssertFalse(model.hasOpenInProcessSession)
        return chat
    }

    private func prepareWithoutPhoneTask() async {
        let core = PokiCore(config: CoreConfig(), host: model.host)
        _ = await core.handle(RelayRequest(id: "prepare", method: "POST", headers: [:], body:
            #"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#))
        await finishPreparing()
    }

    private func finishPreparing() async {
        await waitFor("the simulator's prerequisite check finished") { ["failed", "running"].contains(self.model.runner.state) }
        model.runnerChanged(RunnerStatus(state: "running", code: "local_ddi"))
    }

    /// On cellular the launcher reports `local_ddi`: the image is mounted, and nothing reached the
    /// phone's developer services. Holds the session's open that this starts.
    private func handOverToTheMountedImage() async {
        model.wakeRunner()
        // On the simulator the launcher is WebDriverAgent on the Mac; its answer comes first.
        await waitFor("the simulator's runner check answered") { ["failed", "running"].contains(self.model.runner.state) }
        await withCheckedContinuation { done in model.closeInProcess("a new task on cellular") { done.resume() } }
        model.loopback.simulate(.noAnswer)
        model.setup.developerMode = false
        model.setup.uiAutomation = false
        session.holdNextOpen()
        model.wakeRunner()
        model.runnerChanged(RunnerStatus(state: "running", code: "local_ddi"))
        await waitFor("the local open is under way") { self.session.isHoldingOpen }
    }

    /// What Home lists about the runner and the loopback (the simulator's relay and location aside).
    private func homeIssues() -> [String] {
        Issue.current(model).map(\.id).filter { ["runner", "cellular", "loopback", "local"].contains($0) }
    }

    /// ESP-448: set up on Wi-Fi, then a new task on cellular. Automation is ready only once the
    /// session really opens, and the launcher's hand-over does not count as a pairing check.
    func testOnCellularTheMountedImageCountsOnceTheSessionOpens() async {
        let lastPairingCheck = model.pairingVerifiedAt
        await handOverToTheMountedImage()
        XCTAssertEqual(model.pairingVerifiedAt, lastPairingCheck, "nothing reached the phone's pairing service")
        XCTAssertFalse(model.isDone(.loopback))
        XCTAssertFalse(model.setup.developerMode)
        XCTAssertEqual(homeIssues(), [], "the session is opening")
        session.answer(nil)
        await waitFor("the local session opens") { self.model.isDone(.loopback) }
        XCTAssertFalse(model.loopback.isWorking)
        XCTAssertEqual(model.host.currentRunner.describe, "running")
        XCTAssertTrue(model.setup.developerMode)
        XCTAssertTrue(model.setup.uiAutomation)
        XCTAssertEqual(model.pairingVerifiedAt, lastPairingCheck)
        XCTAssertEqual(homeIssues(), [], "the session is open")
    }

    /// An open that waits its turn (another is asking for the passcode, or Poki is not in front) has
    /// not failed: Home says nothing of it.
    func testALocalOpenWaitingItsTurnIsNoTrouble() async {
        await handOverToTheMountedImage()
        session.answer(["ok": false, "code": "open_under_way"])
        await waitFor("the answer is in") { self.model.host.currentRunner.describe.contains("open_under_way") }
        XCTAssertEqual(homeIssues(), [])
    }

    /// ESP-448 on the redesigned home: once the launcher hands a task to the mounted image, the chat,
    /// Home's line and the bear stop saying Local Connection is off. If the session then fails to open,
    /// the chat says that instead and links to Setup.
    func testOnCellularTheChatTalksAboutTheLocalSessionNotTheLoopback() async {
        await handOverToTheMountedImage()
        // Set up on Wi-Fi before: only the loopback is missing now.
        model.setup.developerMode = true
        model.setup.uiAutomation = true
        let chat = ChatModel(app: model)
        XCTAssertNotEqual(SetupIssueHint.first(model: model)?.target, .step(.loopback), "the chat while the session opens")
        XCTAssertNotEqual(SetupIssueHint.home(model: model)?.target, .step(.loopback), "Home while the session opens")
        XCTAssertNotEqual(PokiStatus.current(model: model, chat: chat).mood, .hello, "the bear while the session opens")

        session.answer(["ok": false, "code": "missing_framework"])
        await waitFor("the local failure is reported") { self.model.host.currentRunner.describe.contains("missing_framework") }
        XCTAssertNotNil(model.localSessionTrouble)
        let hint = SetupIssueHint.first(model: model)
        XCTAssertEqual(hint?.message, model.localSessionTrouble?.text)
        XCTAssertEqual(hint?.target, .setup)
    }

    /// A local open that fails waits for the loopback; when it answers again the launcher goes the
    /// normal way once, as before the hand-over.
    func testAFailedLocalOpenRetriesOverTheLoopbackOnce() async {
        await handOverToTheMountedImage()
        let restarts = launcher.restarts
        session.answer(["ok": false, "code": "missing_framework"])
        await waitFor("the local failure is reported") { self.model.host.currentRunner.describe.contains("missing_framework") }
        XCTAssertEqual(launcher.restarts, restarts)
        XCTAssertEqual(homeIssues(), ["local"], "Home says the session did not open, as it said the loopback was off before")
        model.loopback.simulate(.working(ms: 9))
        XCTAssertEqual(launcher.restarts, restarts + 1)

        session.holdNextOpen()
        model.runnerChanged(RunnerStatus(state: "running", code: "local_ddi"))
        await waitFor("the next local open is under way") { self.session.isHoldingOpen }
        session.answer(["ok": false, "code": "missing_framework"])
        await waitFor("the second local failure is reported") { self.model.host.currentRunner.describe.contains("missing_framework") }
        XCTAssertEqual(launcher.restarts, restarts + 1, "one retry while the loopback stays up")
    }

    func testLocalPhoneReadContinuesAfterTheOwnerAllowsAutomation() async throws {
        let transport = SessionScreenTransport(session: session)
        useSystem(27, transport: transport)
        await prepareWithoutPhoneTask()
        session.holdNextOpen()

        let reading = Task { await model.runTool("look", arguments: "{}") }
        await waitFor("the local phone step is opening automation") { self.session.isHoldingOpen }
        session.setAuthorizationWait(4)
        model.checkIdle()

        XCTAssertTrue(model.passcodeHint)
        XCTAssertEqual(transport.screenReads, 0)
        try await captureSessionState("owner-authorization-waiting")

        session.answer(nil)
        let screen = await reading.value

        XCTAssertFalse(model.passcodeHint)
        XCTAssertFalse(screen.isError, screen.text)
        XCTAssertTrue(screen.text.contains("General"), screen.text)
        XCTAssertEqual(transport.screenReads, 1, "the original read gets the screen after authorization")
        try await captureSessionState("owner-authorization-ready")
    }

    func testOwnerCancellationEndsTheChatBeforeTheModelCanRequestAnotherTool() async throws {
        let keys = ["chat.provider", "chat.customURL", "chat.customModel"]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { UserDefaults.standard.set(value, forKey: key) } }
        let server = try FakeCompletions(replies: [
            FakeCompletions.tool("look", [:]),
            FakeCompletions.tool("look", [:]),
            FakeCompletions.text("The model continued after cancellation."),
        ])
        ModelKeys.customURL = "http://127.0.0.1:\(server.port)/v1"
        ModelKeys.customModel = "fake-model"
        ModelKeys.selectedProvider = .custom
        let transport = SessionScreenTransport(session: session)
        useSystem(27, transport: transport)
        await prepareWithoutPhoneTask()
        session.holdNextOpen()

        let chat = ChatModel(app: model)
        chat.restore(SavedSession(id: UUID().uuidString, kind: .poki, title: "Settings", started: .now,
                                  updated: .now, live: false,
                                  entries: [ChatEntry(.you("Earlier conversation", delivered: true))], calls: []))
        defer { if chat.running { chat.stop() } }
        chat.send("Read the General settings page.", attachments: [])
        await waitFor("the chat is opening automation") { self.session.isHoldingOpen }
        session.setAuthorizationWait(4)
        model.checkIdle()
        XCTAssertTrue(model.passcodeHint)
        session.answer(["ok": false, "code": "automation_cancelled", "detail": "Timed out while enabling automation mode."])
        await waitFor("the original chat task ended") { !chat.running }

        XCTAssertTrue(chat.entries.contains { if case .poki("Stopped.") = $0.kind { return true }; return false })
        XCTAssertEqual(server.requests.count, 1, "After the owner cancels, the original chat sends no more model requests")
        XCTAssertEqual(transport.screenReads, 0)
    }

    func testAPasscodeWaitAsksTheOwnerAndTellsTheAgentWhoMustEnterIt() async throws {
        session.holdNextOpen()
        model.wakeRunner()
        // On the simulator the launcher is WebDriverAgent on the Mac; its answer comes first.
        await waitFor("the simulator's runner check answered") { ["failed", "running"].contains(self.model.runner.state) }
        model.runnerChanged(RunnerStatus(state: "running"))
        session.setAuthorizationWait(4)
        model.checkIdle(now: Date().addingTimeInterval(6))
        XCTAssertTrue(model.passcodeHint, "Poki's home asks the owner for the passcode")
        let waiting = model.host.currentRunner.describe
        XCTAssertTrue(waiting.contains("owner to enter the iPhone passcode"), waiting)
        try await captureSessionState("passcode")
        session.answer(["ok": false, "code": "com.apple.dt.XCTest.XCTFuture 1000", "detail": "Timed out while enabling automation mode.", "seconds": 60.0])
        await waitFor("iOS gave up on the passcode") { !self.model.passcodeHint && !self.model.host.currentRunner.describe.hasPrefix("starting") }
        let failed = model.host.currentRunner.describe
        XCTAssertTrue(failed.contains("owner did not enter the iPhone passcode"), failed)
        XCTAssertTrue(failed.contains("the owner turns Poki off and on"), failed)

        // Poki does not ask again by itself, so the next call hears it at once instead of waiting.
        let core = PokiCore(config: CoreConfig(), host: model.host, transport: SessionScreenTransport(session: session))
        let started = Date()
        let look = await core.callTool("look", arguments: "{}")
        XCTAssertTrue(look.isError, look.text)
        XCTAssertTrue(look.text.contains("owner did not enter the iPhone passcode"), look.text)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }

    /// Issue 347: an open that is only slow (the session, or its first read) is not iOS asking for
    /// the passcode. Nobody is asked for it until iOS has held its own "allow automation" call.
    func testASlowOpenAloneAsksForNoPasscode() async {
        session.holdNextOpen()
        model.wakeRunner()
        await waitFor("the simulator's runner check answered") { ["failed", "running"].contains(self.model.runner.state) }
        model.runnerChanged(RunnerStatus(state: "running"))
        await waitFor("the open is under way") { self.session.isHoldingOpen }
        model.checkIdle(now: Date().addingTimeInterval(12))
        XCTAssertFalse(model.passcodeHint, "a slow open is not a passcode request")
        XCTAssertFalse(model.host.currentRunner.describe.contains("passcode"), model.host.currentRunner.describe)
        session.answer(nil)
        await waitFor("the session opened") { self.model.hasOpenInProcessSession }
        XCTAssertFalse(model.passcodeHint)
    }

    /// A session that opened but answers no element tree is a failure the agent reads as such, with
    /// the reason, and not a ready session.
    func testAnUnreadableSessionIsReportedAndNotTakenAsOpen() async {
        session.holdNextOpen()
        model.wakeRunner()
        await waitFor("the simulator's runner check answered") { ["failed", "running"].contains(self.model.runner.state) }
        model.runnerChanged(RunnerStatus(state: "running"))
        await waitFor("the open is under way") { self.session.isHoldingOpen }
        session.answer(["ok": false, "code": "session_unreadable", "detail": "accessibility did not load for this session", "seconds": 1.0])
        await waitFor("the failure is reported") { self.model.host.currentRunner.describe.contains("could not read the screen") }
        XCTAssertFalse(model.hasOpenInProcessSession)
        XCTAssertTrue(model.host.currentRunner.describe.contains("accessibility did not load"), model.host.currentRunner.describe)
    }

    /// A look that waits for the session and hears it cannot read ends there: nothing opens another
    /// session (and brings the banner back) until the agent calls again. That next call opens a new
    /// session and reads the screen.
    func testAFailedOpenEndsTheCallThatWaitedAndTheNextCallReads() async {
        await prepareWithoutPhoneTask()
        model.runnerChanged(RunnerStatus(state: "running"))
        session.holdNextOpen()
        async let first = model.runTool("look", arguments: "{}")
        await waitFor("the look's open is under way") { self.session.isHoldingOpen }
        let reopened = expectation(description: "no session opens after the failed look")
        reopened.isInverted = true
        session.onPrepare = { reopened.fulfill() }
        session.answer(["ok": false, "code": "session_unreadable", "detail": "accessibility did not load for this session", "seconds": 1.0])

        let failed = await first
        XCTAssertTrue(failed.isError, failed.text)
        XCTAssertTrue(failed.text.contains("could not read the screen"), failed.text)
        await fulfillment(of: [reopened], timeout: 1.5)
        XCTAssertFalse(session.isOpen)
        XCTAssertFalse(model.hasOpenInProcessSession)

        session.onPrepare = nil
        let core = PokiCore(config: CoreConfig(), host: model.host, transport: SessionScreenTransport(session: session))
        let next = await core.callTool("look", arguments: "{}")
        XCTAssertFalse(next.isError, next.text)
        XCTAssertTrue(next.text.contains("General"), next.text)
        XCTAssertTrue(model.hasOpenInProcessSession)
    }

    func testSessionStaysOpenDuringTaskAndClosesAfterIdle() async {
        let saved = model.idleStopSeconds
        model.idleStopSeconds = 60
        defer { model.idleStopSeconds = saved }
        await prepareWithoutPhoneTask()
        model.wakeRunner()
        await waitFor("automation is open") { self.session.isOpen && self.model.hasOpenInProcessSession }
        await model.chatTaskBegan()

        model.checkIdle(now: Date().addingTimeInterval(120))
        XCTAssertTrue(session.isOpen, "thinking between phone steps must keep the same session")
        XCTAssertFalse(model.runnerPaused)

        // No idle time is waited for: the end of the task closes the session.
        model.chatTaskEnded(reply: nil, session: "test", acted: true)
        await waitFor("the completed task closes automation at once, even while Poki is in front") {
            !self.session.isOpen && self.model.runnerPaused
        }
        XCTAssertFalse(model.hasOpenInProcessSession)

        model.prepareForTask()
        await finishPreparing()
        let core = PokiCore(config: CoreConfig(), host: model.host, transport: SessionScreenTransport(session: session))
        let next = await core.callTool("look", arguments: "{}")
        XCTAssertFalse(next.isError, next.text)
        XCTAssertTrue(next.text.contains("General"), next.text)
        XCTAssertTrue(model.hasOpenInProcessSession)
    }

    /// Talk Here starts a relaunched Poki in the background. On iOS 27 its first open asks for no
    /// passcode while the boot's allowance lasts, so it opens there instead of telling the owner to open
    /// Poki; an allowance from another boot, or older than 8 hours, still waits for Poki in front.
    func testARelaunchedPokiOpensAutomationInTheBackgroundWhileTheAllowanceLasts() async {
        let now = Date()
        let cases: [(String, AutomationAllowance, opens: Bool)] = [
            ("2 hours ago in this boot", AutomationAllowance(boot: BootClock.current, at: now.addingTimeInterval(-2 * 3600)), true),
            ("9 hours ago in this boot", AutomationAllowance(boot: BootClock.current, at: now.addingTimeInterval(-9 * 3600)), false),
            ("in an earlier boot", AutomationAllowance(boot: BootClock.current - 600, at: now), false),
        ]
        for (when, allowance, opens) in cases {
            InProcessWDA.gate.withLock { $0 = InProcessWDA.OpenGate() }
            allowance.save()
            session = FakeAutomation()
            useSystem(27)
            model.wentToBackground()
            await prepareWithoutPhoneTask()
            model.wakeRunner()
            if opens {
                await waitFor("allowance \(when): the open runs with Poki in the background") { self.session.isOpen && self.model.hasOpenInProcessSession }
            } else {
                await waitFor("allowance \(when): the open waits for Poki in front") { self.model.host.currentRunner.describe.contains("open_poki_first") }
                XCTAssertFalse(session.isOpen, when)
            }
        }
    }

    /// Poki updated in the middle of a boot: automation already started in this boot under the earlier
    /// version, so the start with Poki in front is not the boot's first. It still counts, and the next
    /// relaunch opens automation from the background.
    func testAStartLaterInTheBootLetsTheNextRelaunchOpenInTheBackground() async {
        let bootKey = "automationStartedBoot"
        let savedBoot = UserDefaults.standard.object(forKey: bootKey)
        defer { UserDefaults.standard.set(savedBoot, forKey: bootKey) }
        UserDefaults.standard.set(BootClock.current, forKey: bootKey)
        await openSessionForATask()

        InProcessWDA.gate.withLock { $0 = InProcessWDA.OpenGate() }
        session = FakeAutomation()
        useSystem(27)
        model.wentToBackground()
        await prepareWithoutPhoneTask()
        model.wakeRunner()
        await waitFor("the relaunched Poki opens with Poki in the background") { self.session.isOpen && self.model.hasOpenInProcessSession }
    }

    /// A talk that ends (End, the Action Button again, or silence) with nothing under way closes the
    /// automation its steps used at once, as at the end of a task: on iOS 27 iOS's banner goes while the
    /// owner stays in the app they talked over; on iOS 26 the session is kept, so the next talk needs no
    /// passcode.
    func testTheEndOfATalkClosesTheAutomationAtOnce() async {
        UserDefaults.standard.set("1", forKey: "pokiTalkRehearsal")
        defer { UserDefaults.standard.removeObject(forKey: "pokiTalkRehearsal") }
        for system in [27, 26] {
            useSystem(system)
            await openSessionForATask()
            model.wentToBackground()
            await model.voice.start(microphone: false)
            XCTAssertTrue(model.voice.isOn)
            XCTAssertTrue(session.isOpen)
            let closes = session.closes

            model.stopFromOutside(AppModel.liveActivityEnd)
            XCTAssertFalse(model.voice.isOn, "iOS \(system): the talk ends at once")
            if system == 27 {
                await waitFor("iOS 27: the end of the talk closes automation") { !self.session.isOpen && self.model.runnerPaused }
            } else {
                await waitFor("iOS 26: the end of the talk stands by") { self.model.runnerPaused && self.model.lastInProcessClose != nil }
                XCTAssertTrue(session.isOpen, "iOS 26: the session is kept for the next talk")
                XCTAssertEqual(session.closes, closes)
            }
        }
    }

    /// Stop on the Live Activity during a talk: the talk stops with the steps, not only the steps, and
    /// the automation session closes. Poki stays on, and the next agent's look opens automation again
    /// from the background.
    func testAStopFromOutsidePokiEndsTheTalkAndTheSteps() async {
        UserDefaults.standard.set("1", forKey: "pokiTalkRehearsal")
        defer { UserDefaults.standard.removeObject(forKey: "pokiTalkRehearsal") }
        await openSessionForATask()
        model.wentToBackground()
        await model.voice.start(microphone: false)
        XCTAssertTrue(model.voice.isOn)

        model.stopFromOutside(AppModel.liveActivityStop)
        XCTAssertFalse(model.voice.isOn, "the talk stops at once")
        await waitFor("the steps stop and automation closes") { self.model.runnerPaused && !self.session.isOpen }
        XCTAssertTrue(model.sessionOn, "Poki stays on")

        await lookForTheNextTask()
        XCTAssertTrue(session.isOpen, "the next agent's look opens automation from the background")
    }

    func testRemotePhoneReadWaitsForSessionWithoutInputPreparation() async throws {
        session.holdNextOpen()
        let transport = SessionScreenTransport(session: session)
        let core = PokiCore(config: CoreConfig(), host: model.host, transport: transport)
        _ = await core.handle(RelayRequest(id: "connect", method: "POST", headers: [:], body:
            #"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#))
        await finishPreparing()
        let reading = Task {
            await core.handle(RelayRequest(id: "phone-step", method: "POST", headers: [:], body:
                #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"look","arguments":{}}}"#))
        }
        await waitFor("the remote phone step requests automation") { self.session.isHoldingOpen }
        XCTAssertEqual(transport.screenReads, 0, "no screen request may reach native automation before it is ready")
        let chat = ChatModel(app: model)
        XCTAssertEqual(PokiStatus.current(model: model, chat: chat).word, "Preparing")
        try await captureSessionState("waiting", chat: chat)
        session.answer(nil)
        let reply = await reading.value
        XCTAssertEqual(reply.status, 200)
        XCTAssertTrue(reply.body.contains("General"), reply.body)
        XCTAssertFalse(reply.body.contains("\"isError\":true"), reply.body)
        XCTAssertEqual(transport.screenReads, 1, "the first phone read succeeds without a model retry")
        XCTAssertNotEqual(PokiStatus.current(model: model, chat: chat).word, "Preparing")
        try await captureSessionState("ready", chat: chat)
    }

    /// Opens the session for a phone task and waits until it is open.
    private func openSessionForATask() async {
        await prepareWithoutPhoneTask()
        model.wakeRunner()
        await waitFor("automation is open") { self.session.isOpen && self.model.hasOpenInProcessSession }
    }

    /// The next agent's first look after standing by.
    private func lookForTheNextTask() async {
        model.prepareForTask()
        await finishPreparing()
        let core = PokiCore(config: CoreConfig(), host: model.host, transport: SessionScreenTransport(session: session))
        let look = await core.callTool("look", arguments: "{}")
        XCTAssertFalse(look.isError, look.text)
    }

    private func standByWhenIdle() async {
        model.checkIdle(now: Date().addingTimeInterval(Double(model.idleStopSeconds) + 60))
        await waitFor("Poki stood by") { self.model.runnerPaused && !self.model.hasOpenInProcessSession && self.model.lastInProcessClose != nil }
    }

    /// On iOS 18 to 26 a session that ends asks for the passcode again at the next task: standing by
    /// keeps the session and only turns Automation Mode off.
    func testOnIOS26StandingByKeepsTheSession() async {
        useSystem(26)
        await openSessionForATask()
        await standByWhenIdle()
        XCTAssertTrue(session.isOpen, "the session that iOS already allowed stays open")
        XCTAssertEqual(session.pauses, 1)
        XCTAssertEqual(session.closes, 0)
    }

    func testOnIOS26AFailedPauseClosesTheSession() async {
        useSystem(26)
        await openSessionForATask()
        session.failNextPause()
        await standByWhenIdle()
        XCTAssertFalse(session.isOpen, "an unavailable pause must close the session instead of leaving Automation Mode on")
        XCTAssertEqual(model.lastInProcessClose?.closed, true)
        await lookForTheNextTask()
        XCTAssertTrue(session.isOpen && model.hasOpenInProcessSession)
    }

    /// iOS 27 does not use the session this way: standing by ends it, as before.
    func testOnIOS27StandingByStillClosesTheSession() async {
        useSystem(27)
        await openSessionForATask()
        await standByWhenIdle()
        XCTAssertFalse(session.isOpen)
        XCTAssertEqual(session.closes, 1)
        XCTAssertEqual(session.pauses, 0)
    }

    /// The end of a task is the same stand-by as the idle minute: a task a minute is not enough to ask the passcode for.
    func testOnIOS26TheEndOfATaskKeepsTheSession() async {
        useSystem(26)
        await openSessionForATask()
        await model.chatTaskBegan()
        model.chatTaskEnded(reply: nil, session: "test", acted: true)
        await waitFor("the end of the task stood by") { self.model.runnerPaused && self.model.lastInProcessClose != nil }
        XCTAssertTrue(session.isOpen)
        XCTAssertEqual(session.pauses, 1)
        XCTAssertEqual(session.closes, 0)
    }

    /// The owner's own Stop still ends the session and the banner, on every iOS.
    func testOnIOS26TheOwnersStopStillClosesTheSession() async {
        useSystem(26)
        await openSessionForATask()
        model.pauseRunner(byOwner: true)
        await waitFor("the owner's stop closed the session") { self.model.lastInProcessClose != nil }
        XCTAssertFalse(session.isOpen)
        XCTAssertEqual(session.closes, 1)
        XCTAssertEqual(session.pauses, 0)
    }

    func testOnIOS26ClosingDuringAPauseDoesNotKeepTheSession() async {
        for action in ["owner stop", "Live Activity stop", "turn off", "update"] {
            useSystem(26)
            await openSessionForATask()
            let pausing = expectation(description: "pause started before \(action)")
            session.holdNextPause { pausing.fulfill() }
            model.checkIdle(now: Date().addingTimeInterval(Double(model.idleStopSeconds) + 60))
            await fulfillment(of: [pausing], timeout: 5)

            var update: Task<Void, Never>?
            switch action {
            case "owner stop": model.pauseByOwner()
            case "Live Activity stop": model.stopFromOutside(AppModel.liveActivityStop)
            case "turn off": model.stopSession()
            default:
                let updating = expectation(description: "update requested during the pause")
                update = Task { @MainActor in
                    updating.fulfill()
                    await self.model.windDownForUpdate()
                    XCTAssertFalse(self.session.isOpen, "the update must wait for a full close")
                }
                await fulfillment(of: [updating], timeout: 5)
            }
            session.releasePause()
            await update?.value
            await waitFor("\(action) finished closing") { self.model.lastInProcessClose != nil }
            XCTAssertFalse(session.isOpen, "\(action) must not be lost while a pause is in progress")
            XCTAssertEqual(model.lastInProcessClose?.closed, true, action)
        }
    }

    /// The kept session is the next task's session. When it cannot read again, Poki closes it and opens a
    /// new one in the same call, so the agent's step is not lost to a dead session.
    func testOnIOS26AKeptSessionThatCannotResumeIsClosedAndOpenedAgain() async {
        useSystem(26)
        await openSessionForATask()
        await standByWhenIdle()
        session.failNextResume()
        let opened = session.prepares
        await lookForTheNextTask()
        XCTAssertTrue(session.isOpen && model.hasOpenInProcessSession)
        XCTAssertEqual(session.prepares - opened, 2, "the resume that failed, then the new session")
        XCTAssertTrue(AppLog.shared.lines.contains { $0.contains("could not resume") }, "the log says why a new session was opened")
    }

    /// A kept session that resumes is the one used, with nothing opened beside it.
    func testOnIOS26AKeptSessionThatResumesIsReused() async {
        useSystem(26)
        await openSessionForATask()
        await standByWhenIdle()
        let opened = session.prepares
        await lookForTheNextTask()
        XCTAssertTrue(session.isOpen && model.hasOpenInProcessSession)
        XCTAssertEqual(session.prepares - opened, 1)
        XCTAssertEqual(session.closes, 0)
    }

    func testSimulatedFirstScreenTimings() async throws {
        try XCTSkipUnless(UserDefaults.standard.bool(forKey: "sessionTiming"), "explicit simulator timing run only")
        let entry = try XCTUnwrap(ChatEntryPoint(rawValue: UserDefaults.standard.string(forKey: "sessionTimingEntry") ?? "focus"))
        let baseline = UserDefaults.standard.bool(forKey: "sessionTimingBaseline")
        let keys = ["chat.provider", "chat.customURL", "chat.customModel", "custom.providers", "chat.customProvider", "chat.model.custom", "pokiDraft", "pokiDictationButton"]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { UserDefaults.standard.set(value, forKey: key) } }
        let server = try FakeCompletions(replies: [FakeCompletions.tool("look", [:]), FakeCompletions.text("The screen was read.")])
        ModelKeys.customURL = "http://127.0.0.1:\(server.port)/v1"
        ModelKeys.customModel = "fake-model"
        ModelKeys.selectedProvider = .custom
        UserDefaults.standard.set("", forKey: "pokiDraft")
        UserDefaults.standard.set(true, forKey: "pokiDictationButton")
        model.stopSession()
        let native = DelayedSimulatorAutomation()
        model = AppModel(launcher: launcher, pairer: FakePairing(), automation: native)
        model.loopback.simulate(.working(ms: 9))
        model.setup.loopback = .proxy
        XCTAssertTrue(model.setRelay("https://relay.invalid"))
        model.startSession()
        await prepareWithoutPhoneTask()
        if baseline {
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in self.model.hasOpenInProcessSession }, object: nil)
            await fulfillment(of: [ready], timeout: 60)
            XCTAssertTrue(model.hasOpenInProcessSession, "the old foreground path opens before input")
        }
        let chat = ChatModel(app: model, kind: .handoff, requester: "Test agent")
        let accessibility = try XCTUnwrap(dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW))
        defer { dlclose(accessibility) }
        let isEnabled = unsafeBitCast(try XCTUnwrap(dlsym(accessibility, "_AXSAutomationEnabled")), to: (@convention(c) () -> Int32).self)
        let setEnabled = unsafeBitCast(try XCTUnwrap(dlsym(accessibility, "_AXSSetAutomationEnabled")), to: (@convention(c) (Int32) -> Void).self)
        let previous = isEnabled()
        setEnabled(1)
        defer { setEnabled(previous) }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        window.rootViewController = UIHostingController(rootView: NavigationStack {
            ChatView(openVoice: {}, openSetup: {}, openModel: {}, openThreads: {})
        }.environment(model).environment(chat).environment(\.accessibilityEnabled, true))
        window.makeKeyAndVisible()
        defer { window.endEditing(true); window.isHidden = true }
        await drawEntry(window)
        try await activateEntry(entry, window: window, chat: chat)
        if entry != .shortcut {
            let field = try XCTUnwrap(Self.entryField(in: window))
            field.insertText("Read the screen")
            field.delegate?.textViewDidChange?(field)
            await drawEntry(window)
        }
        let submitted = ProcessInfo.processInfo.systemUptime
        let button = try XCTUnwrap(Self.entryElement(in: window, matching: { $0 == "composer.main" }))
        XCTAssertTrue(button.accessibilityActivate())
        let completed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !chat.running && chat.entries.contains { if case .poki(let text) = $0.kind { text == "The screen was read." } else { false } }
        }, object: nil)
        await fulfillment(of: [completed], timeout: 60)
        let read = try XCTUnwrap(chat.savedCalls.first { $0.name == "look" })
        XCTAssertTrue(read.ok, "the actual simulator screen must reach the chat model")
        XCTAssertEqual(chat.savedCalls.filter { $0.name == "look" }.count, 1)
        let events = AppLog.shared.lines.filter { $0.contains("[session-timing]") }
        let firstRead = try XCTUnwrap(events.compactMap { line -> Double? in
            guard let range = line.range(of: "screen_read_succeeded uptime="), let value = Double(line[range.upperBound...]), value >= submitted else { return nil }
            return value
        }.first)
        XCTAssertGreaterThan(firstRead, submitted)
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("OnDemandEvidence")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let times = native.times
        let output: [String: Any] = ["entry": entry.rawValue, "baseline": baseline, "simulator_native": true,
                                  "artificial_open_delay_seconds": 1.92, "submitted": submitted,
                                  "session_requested": times.requested, "session_ready": times.ready,
                                  "first_screen_read": firstRead, "elapsed_seconds": firstRead - submitted,
                                  "speech_text_is_fixture": entry == .dictation,
                                  "events": events, "ok": read.ok, "look_calls": chat.savedCalls.filter { $0.name == "look" }.count]
        await drawEntry(window)
        let screenshot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        try XCTUnwrap(screenshot.pngData()).write(to: folder.appendingPathComponent("entry-\(entry.rawValue)-complete.png"))
        try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]).write(to: folder.appendingPathComponent("timings.json"))
    }

    private func captureSessionState(_ name: String, chat: ChatModel? = nil) async throws {
        guard UserDefaults.standard.bool(forKey: "sessionEvidence") else { return }
        let language = AppLocalization.shared.preference
        AppLocalization.shared.preference = "zh-Hans"
        defer { AppLocalization.shared.preference = language }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        let chat = chat ?? ChatModel(app: model)
        window.rootViewController = UIHostingController(rootView: NavigationStack {
            ChatView(openVoice: {}, openSetup: {}, openModel: {}, openThreads: {})
        }.environment(model).environment(chat).environment(\.locale, AppLocalization.locale))
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        window.layoutIfNeeded()
        let drawn = expectation(description: "ChatView rendered its geometry and state")
        let frames = SessionEvidenceFrames { drawn.fulfill() }
        let display = CADisplayLink(target: frames, selector: #selector(SessionEvidenceFrames.tick))
        display.add(to: .main, forMode: .common)
        await fulfillment(of: [drawn], timeout: 5)
        display.invalidate()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("OnDemandEvidence")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try XCTUnwrap(image.pngData()).write(to: folder.appendingPathComponent("\(name).png"))
    }

}

@MainActor
final class FrontendSubtractionTests: XCTestCase {
    private var savedSetup: SetupState!
    private var savedLanguage = AppLocalization.system

    override func setUp() {
        savedSetup = SetupState.load()
        savedLanguage = AppLocalization.shared.preference
        AppLocalization.shared.preference = "en"
    }

    override func tearDown() {
        AppLocalization.shared.preference = savedLanguage
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

    /// ESP-340: the bear sleeps and the Hands switch reads "Paused" only after the owner's own pause.
    /// Standing by right after Turn On, or after the idle time, is not a pause: read from `runnerPaused`
    /// (what Pause and Resume go by), Poki looked asleep the moment it was turned on.
    func testOnlyTheOwnersPauseCountsAsResting() {
        UserDefaults.standard.removeObject(forKey: "wantsOn")
        let model = AppModel(launcher: FakeLauncher(), pairer: FakePairing())
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
        XCTAssertTrue(model.runnerPaused)
        XCTAssertFalse(model.ownerPaused, "Turn On stands by; nobody paused it")

        // What the idle check does once the idle time has passed.
        model.wakeRunner()
        model.pauseRunner(reason: "Stopped after 1 min without agent activity", byOwner: false)
        XCTAssertTrue(model.runnerPaused)
        XCTAssertFalse(model.ownerPaused, "standing by after the idle time is not the owner's pause")

        // The Hands switch, turned off while Poki stands by: now it rests.
        model.pauseByOwner()
        XCTAssertTrue(model.ownerPaused)
        model.wakeRunner()
        XCTAssertFalse(model.ownerPaused, "a task, an agent's request or Resume ends the rest")

        model.pauseByOwner()
        XCTAssertTrue(model.ownerPaused && model.runnerPaused, "from awake, the owner's pause stands by and rests")
        model.stopSession()
        XCTAssertFalse(model.ownerPaused, "off is off, not resting")
    }

    /// The owner (2026-11-13): standing by, after Turn On or after the owner's pause, takes the next
    /// task by itself, so Poki's picture and word (home, chat, card) and the Live Activity say Ready.
    /// Before, the owner's pause said Paused under a sleeping bear, and the island said it while
    /// standing by.
    func testStandingByAndTheOwnersPauseSayReady() throws {
        UserDefaults.standard.removeObject(forKey: "wantsOn")
        let model = AppModel(launcher: FakeLauncher(), pairer: FakePairing())
        let pairing = AppFiles.phonePairingFile
        if !FileManager.default.fileExists(atPath: pairing.path) {
            try Data("pairing".utf8).write(to: pairing)
            addTeardownBlock { try? FileManager.default.removeItem(at: pairing) }
        }
        model.setup.runnerInstalled = true
        model.setup.developerMode = true
        model.setup.uiAutomation = true
        model.loopback.simulate(.working(ms: 9))
        model.setup.loopback = .proxy
        _ = model.setRelay("https://relay.invalid")
        defer {
            model.stopSession()
            UserDefaults.standard.removeObject(forKey: "relayAddress")
            UserDefaults.standard.set(nil as Any?, forKey: "relayEnabled")
            UserDefaults.standard.removeObject(forKey: "wantsOn")
        }
        let chat = ChatModel(app: model)
        model.startSession()
        XCTAssertTrue(model.runnerPaused)
        XCTAssertEqual(PokiStatus.current(model: model, chat: chat).word, "Ready", "standing by after Turn On")

        model.wakeRunner()
        model.pauseByOwner()
        XCTAssertTrue(model.ownerPaused && model.runnerPaused)
        let status = PokiStatus.current(model: model, chat: chat)
        XCTAssertEqual(status.word, "Ready", "the owner's pause")
        XCTAssertEqual(status.mood, .ready, "the bear is awake")

        var island = PokiState(phase: .idle, headline: "Runner asleep", thumbnailVersion: 0)
        island.runnerPaused = true
        XCTAssertEqual(island.face.content, "Ready", "the Live Activity while standing by")
    }

    /// 752's home warned in the last two days of signing (ESP-222); the redesigned home only notifies.
    /// The home line says it again, under 752's headline and ahead of an open setup step, and links to
    /// Updates. The drawer's reminder row says the same.
    func testHomeLineAndDrawerWarnInTheLastTwoDaysOfSigning() {
        defer { UserDefaults.standard.removeObject(forKey: "pokiSigningDays") }
        UserDefaults.standard.set(1.0, forKey: "pokiSigningDays")
        let ending = AppModel(launcher: FakeLauncher(), pairer: FakePairing())
        ending.setup.loopback = .none
        let hint = SetupIssueHint.homeLine(model: ending)
        XCTAssertEqual(hint?.target, .updates)
        let warning = ExpiryWarning(expiry: ending.signer.expiry)?.message ?? "no warning"
        XCTAssertEqual(hint?.message, "Poki’s signing ends soon\n" + warning)
        XCTAssertEqual(SetupIssueHint.home(model: ending), hint, "the drawer's reminder")

        UserDefaults.standard.set(3.0, forKey: "pokiSigningDays")
        let later = AppModel(launcher: FakeLauncher(), pairer: FakePairing())
        later.setup.loopback = .none
        XCTAssertEqual(SetupIssueHint.homeLine(model: later)?.target, SetupIssueHint.first(model: later)?.target, "3 days left")
    }

    /// ESP-321: Home has no tab bar, so main's Setup dot is Home's hint line. An open setup step shows
    /// there and links to that step; before, Home showed only runner failures and said nothing.
    func testHomeHintShowsOpenSetupStepWithoutTabBar() {
        let model = AppModel(launcher: FakeLauncher(), pairer: FakePairing())
        model.setup.runnerInstalled = false
        model.setup.developerMode = false
        model.setup.loopback = .none
        model.setup.uiAutomation = false

        model.setup.runnerInstalled = true
        model.setup.developerMode = true

        let hint = SetupIssueHint.home(model: model)
        XCTAssertEqual(hint?.target, .step(.loopback), "the first open step, Local Connection, shows on Home")
    }
    /// #78 ("Can't Reach iPhone" by failure code) and #79 (Poki Setup's install turns Poki on) still
    /// reach the new screens: the failure is the hint line on Home and in the chat, and an issue row
    /// on Poki's details.
    func testUnreachableRunnerFailureAndAutoTurnOnSurfaceInNewHomeAndDetails() async throws {
        defer { try? FileManager.default.removeItem(at: SelfSigner.handedIdentity) }
        try FileManager.default.createDirectory(at: SelfSigner.handedIdentity.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: SelfSigner.handedIdentity)
        UserDefaults.standard.removeObject(forKey: "wantsOn")

        let model = AppModel(launcher: FakeLauncher(), pairer: FakePairing())
        XCTAssertTrue(model.wantsOn, "#79: Poki Setup install turns wantsOn on automatically")

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
    }

    /// Any web page, message or app can open a `poki://` link. One that names a relay only asks: the
    /// relay could see the screen and act on the phone, so nothing changes until the owner allows it.
    func testARelayLinkAsksAndDoesNotSetTheRelay() throws {
        let model = AppModel(launcher: FakeLauncher(), pairer: FakePairing())
        let before = model.relayAddress
        XCTAssertEqual(model.open(link: try XCTUnwrap(URL(string: "poki://setup?relay=https%3A%2F%2Fevil.example"))), .continueRouting)
        XCTAssertEqual(model.relayAddress, before, "not set by the link alone")
        XCTAssertEqual(model.linkAsk?.host, "https://evil.example")
        model.answerLink(false, to: try XCTUnwrap(model.linkAsk).id)
        XCTAssertNil(model.linkAsk)
        XCTAssertEqual(model.relayAddress, before, "declined")
    }

    /// #350 review: a second link while the first one's alert is on screen. Allow and Don't Allow apply
    /// to the request the alert shows, and the second link changes nothing.
    func testASecondLinkWhileOneAsksChangesNothing() throws {
        for allow in [true, false] {
            let model = AppModel(launcher: FakeLauncher(), pairer: FakePairing())
            let keys = ["relayAddress", "relayEnabled"]
            let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
            defer { for (key, value) in zip(keys, saved) { UserDefaults.standard.set(value, forKey: key) } }
            let before = model.relayAddress
            let missingChecksum = try XCTUnwrap(URL(string: "poki://pairing?url=http%3A%2F%2F127.0.0.1%2Fpairing.plist"))
            _ = model.open(link: missingChecksum)
            let previousNote = try XCTUnwrap(model.pairingNote)
            XCTAssertEqual(model.open(link: try XCTUnwrap(URL(string: "poki://setup?relay=https%3A%2F%2Fmine.example"))), .continueRouting)
            let shown = try XCTUnwrap(model.linkAsk)
            XCTAssertEqual(shown.host, "https://mine.example")
            XCTAssertEqual(model.open(link: try XCTUnwrap(URL(string: "poki://setup?relay=https%3A%2F%2Fevil.example"))), .ignored)
            XCTAssertEqual(model.linkAsk?.id, shown.id, "the second link does not replace the one on screen")
            let sum = String(repeating: "ab", count: 32)
            let download = try XCTUnwrap(URL(string: "poki://pairing?url=http%3A%2F%2F127.0.0.1%2Fpairing.plist&sha256=\(sum)"))
            let inline = try XCTUnwrap(URL(string: "poki://pairing?data=AP8"))
            for link in [download, inline, missingChecksum] {
                XCTAssertEqual(model.open(link: link), .ignored, "discarded pairing links do not open the pairing page")
                XCTAssertEqual(model.pairingNote, previousNote, "discarded pairing links leave the previous message alone")
                XCTAssertEqual(model.linkAsk?.id, shown.id, "discarded pairing links do not replace the request")
            }

            model.answerLink(allow, to: UUID())
            XCTAssertEqual(model.linkAsk?.id, shown.id, "an answer to another request does nothing")
            model.answerLink(allow, to: shown.id)
            XCTAssertNil(model.linkAsk, "nothing else waits: the second link was turned away")
            XCTAssertNotEqual(model.relayAddress?.origin.host(), "evil.example")
            if allow {
                XCTAssertEqual(model.relayAddress?.origin.host(), "mine.example", "Allow sets the relay the alert showed")
            } else {
                XCTAssertEqual(model.relayAddress, before, "Don't Allow leaves the relay as it was")
            }
        }
    }

    func testInvalidInlinePairingDataShowsAnErrorWithoutAsking() throws {
        let model = AppModel(launcher: FakeLauncher(), pairer: FakePairing())
        let invalid = try XCTUnwrap(URL(string: "poki://pairing?data=AP8"))
        XCTAssertEqual(model.open(link: invalid), .showSetup(.pairing))
        XCTAssertNil(model.linkAsk, "invalid property-list bytes cannot be approved")
        XCTAssertNotNil(model.pairingNote, "the pairing page explains why the link was refused")
    }

    func testIncompleteInlinePairingRecordsShowAnErrorWithoutAsking() throws {
        let records: [[String: Any]] = [["identifier": "example"], ["HostID": "example"]]
        for record in records {
            let model = AppModel(launcher: FakeLauncher(), pairer: FakePairing())
            let data = try PropertyListSerialization.data(fromPropertyList: record, format: .binary, options: 0)
            var link = URLComponents()
            link.scheme = "poki"
            link.host = "pairing"
            link.queryItems = [URLQueryItem(name: "data", value: data.base64URL)]
            XCTAssertEqual(model.open(link: try XCTUnwrap(link.url)), .showSetup(.pairing))
            XCTAssertNil(model.linkAsk, "an incomplete pairing record cannot be approved")
            XCTAssertNotNil(model.pairingNote, "the pairing page explains why the link was refused")
        }
    }

    /// A pairing link from outside asks before it replaces the pairing file, and one that fetches a
    /// file must say which file (its checksum), or Poki would fetch and keep whatever the address serves.
    func testAPairingLinkAsksAndNeedsItsChecksum() throws {
        let model = AppModel(launcher: FakeLauncher(), pairer: FakePairing())
        XCTAssertEqual(model.open(link: try XCTUnwrap(URL(string: "poki://pairing?url=http%3A%2F%2F192.168.1.5%3A4000%2Fp.plist"))), .showSetup(.pairing))
        XCTAssertNil(model.linkAsk, "no checksum, nothing to ask")
        let sum = String(repeating: "ab", count: 32)
        XCTAssertEqual(model.open(link: try XCTUnwrap(URL(string: "poki://pairing?url=http%3A%2F%2F192.168.1.5%3A4000%2Fp.plist&sha256=\(sum)"))), .showSetup(.pairing))
        XCTAssertEqual(model.linkAsk?.host, "192.168.1.5")
        model.answerLink(false, to: try XCTUnwrap(model.linkAsk).id)
        XCTAssertNil(model.linkAsk)
    }

    /// Every setup step done and a connection chosen, with the loopback not yet checked.
    private func modelWithLoopbackChosen(launcher: FakeLauncher, imageMounted: @escaping () -> Bool = { AppModel.localDDIMounted }) throws -> (model: AppModel, restore: () -> Void) {
        let keys = ["chat.provider", "chat.customURL", "chat.customModel", "custom.providers", "chat.customProvider", "chat.model.custom", "relayAddress", "relayEnabled", "wantsOn"]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }

        let pairing = AppFiles.phonePairingFile
        if !FileManager.default.fileExists(atPath: pairing.path) {
            try Data("pairing".utf8).write(to: pairing)
            addTeardownBlock { try? FileManager.default.removeItem(at: pairing) }
        }
        UserDefaults.standard.removeObject(forKey: "relayAddress")
        UserDefaults.standard.set(false, forKey: "relayEnabled")
        ModelKeys.customURL = "http://127.0.0.1:9/v1"
        ModelKeys.customModel = "fake-model"
        ModelKeys.selectedProvider = .custom

        let model = AppModel(launcher: launcher, pairer: FakePairing(), automation: FakeAutomation(), imageMounted: imageMounted)
        model.setup.runnerInstalled = true
        model.setup.developerMode = true
        model.setup.uiAutomation = true
        model.setup.loopback = .proxy
        return (model, {
            model.stopSession()
            for (key, value) in zip(keys, saved) { UserDefaults.standard.set(value, forKey: key) }
        })
    }

    func testSwitchingNetworksWithWorkingLoopbackClearsLoopbackPrompts() async throws {
        let launcher = FakeLauncher()
        let (model, restore) = try modelWithLoopbackChosen(launcher: launcher)
        defer { restore() }

        XCTAssertEqual(model.loopback.state, .checking)
        model.setup.uiAutomation = false
        XCTAssertEqual(SetupIssueHint.homeLine(model: model)?.target, .step(.automation), "Home chat must not treat an unfinished loopback check as off")
        XCTAssertEqual(SetupIssueHint.first(model: model)?.target, .step(.automation), "Conversation chat must not treat an unfinished loopback check as off")
        model.setup.uiAutomation = true
        let checkingLabels = try await renderedLabels(of: NavigationStack { SetupSettingsPage(path: .constant(NavigationPath())) }, model: model)
        XCTAssertFalse(checkingLabels.contains { $0.contains("Turn On") || $0.contains("Continue Setup") },
                       "Connection must not ask to turn on a configured loopback while checking: \(checkingLabels)")

        model.loopback.simulate(.working(ms: 6))
        model.startSession()
        model.wakeRunner()
        await waitOnMain { ["failed", "running"].contains(model.runner.state) }
        model.runnerChanged(RunnerStatus(state: "running"))

        model.loopback.simulate(.noAnswer)
        model.runnerChanged(RunnerStatus(
            state: "failed",
            detail: "remote pairing handshake failed",
            fix: "Open Setup › Loopback and check the loopback, then pair this iPhone again in Setup › Pairing with the loopback on.",
            code: "handshake"
        ))
        XCTAssertEqual(SetupIssueHint.homeLine(model: model)?.target, .step(.loopback))

        let restartsBefore = launcher.restarts
        model.loopback.simulate(.checking)
        model.loopback.simulate(.working(ms: 11))
        XCTAssertEqual(launcher.restarts, restartsBefore + 1, "working loopback after re-checking must restart the runner")
        XCTAssertNil(SetupIssueHint.homeLine(model: model), "Home chat must clear the loopback prompt once 10.7.0.1 answers")
        XCTAssertNil(SetupIssueHint.first(model: model), "Conversation chat must clear the loopback prompt once 10.7.0.1 answers")
        XCTAssertFalse(Issue.current(model).contains { $0.id == "loopback" || $0.id == "runner" },
                       "Settings must clear stale loopback and runner issues once 10.7.0.1 answers")

        model.loopback.simulate(.off)
        model.runnerChanged(RunnerStatus(
            state: "waiting_network",
            detail: "remote pairing connect failed",
            fix: "Turn on the loopback in your proxy app.",
            code: "loopback"
        ))
        XCTAssertTrue(Issue.current(model).contains { $0.id == "loopback" })
        model.loopback.simulate(.checking)
        model.loopback.simulate(.working(ms: 9))
        XCTAssertFalse(Issue.current(model).contains { $0.id == "loopback" || $0.id == "runner" },
                       "Settings must clear waiting_network loopback issues once 10.7.0.1 answers")

        let chatLabels = try await renderedLabels(
            of: NavigationStack { ChatView(openVoice: {}, openSetup: {}, openModel: {}, openThreads: {}) },
            model: model
        )
        XCTAssertFalse(chatLabels.contains { $0.contains("Turn On Local Connection") || $0.contains("Local Connection is off") },
                       "Chat screen must not prompt for Local Connection when 10.7.0.1 answers: \(chatLabels)")
        let connectionLabels = try await renderedLabels(of: NavigationStack { SetupSettingsPage(path: .constant(NavigationPath())) }, model: model)
        XCTAssertFalse(connectionLabels.contains { $0.contains("Turn On") || $0.contains("Continue Setup") },
                       "Connection screen must not prompt to turn on Local Connection when 10.7.0.1 answers: \(connectionLabels)")
        XCTAssertTrue(connectionLabels.contains { $0.contains("Set Up Again") },
                      "Connection screen must report setup complete when 10.7.0.1 answers: \(connectionLabels)")
    }

    /// A loopback that really is off or silent, with nothing wrong in the runner, still asks to be
    /// turned on on every screen, also right after a check that began as a network change.
    func testALoopbackThatIsOffOrSilentStillPromptsOnEveryScreen() async throws {
        let (model, restore) = try modelWithLoopbackChosen(launcher: FakeLauncher())
        defer { restore() }
        model.startSession()
        XCTAssertNotEqual(model.runner.state, "failed")
        XCTAssertFalse(model.servicesSilent)

        for answer in [LoopbackMonitor.State.off, .noAnswer] {
            model.loopback.simulate(.checking)
            model.loopback.simulate(answer)
            XCTAssertFalse(model.canStartTasks, "\(answer)")
            XCTAssertEqual(SetupIssueHint.first(model: model)?.target, .step(.loopback), "the chat, \(answer)")
            XCTAssertEqual(SetupIssueHint.homeLine(model: model)?.target, .step(.loopback), "Home, \(answer)")
            XCTAssertTrue(Issue.current(model).contains { $0.id == "loopback" }, "Settings issues, \(answer)")
            XCTAssertFalse(model.setupReadyForUse, "the Settings entry, \(answer)")
            let connection = try await renderedLabels(of: NavigationStack { SetupSettingsPage(path: .constant(NavigationPath())) }, model: model)
            XCTAssertTrue(connection.contains { $0.contains("Turn On") }, "Connection, \(answer): \(connection)")
            XCTAssertFalse(connection.contains { $0.contains("Set Up Again") }, "Connection, \(answer): \(connection)")
        }
    }

    /// On cellular the launcher hands a task to the mounted disk image while the loopback stays silent:
    /// that counts as ready everywhere. Only the hand-over (`local_ddi`) tells the two apart, so the
    /// same silent loopback asks to be turned on before it.
    func testAHandOverToTheMountedImageCountsAsReadyWhileTheLoopbackIsSilent() async throws {
        let (model, restore) = try modelWithLoopbackChosen(launcher: FakeLauncher())
        defer { restore() }
        model.loopback.simulate(.noAnswer)
        XCTAssertEqual(SetupIssueHint.first(model: model)?.target, .step(.loopback), "before the hand-over")
        XCTAssertFalse(model.setupReadyForUse, "before the hand-over")

        model.runnerChanged(RunnerStatus(state: "running", code: "local_ddi"))
        XCTAssertTrue(model.canStartTasks)
        XCTAssertFalse(model.hasOpenInProcessSession, "the session is not open yet, so nothing else stands in for the loopback")
        XCTAssertNil(SetupIssueHint.first(model: model))
        XCTAssertTrue(model.setupReadyForUse)
        let labels = try await renderedLabels(of: NavigationStack { SetupSettingsPage(path: .constant(NavigationPath())) }, model: model)
        XCTAssertFalse(labels.contains { $0.contains("Turn On") || $0.contains("Continue Setup") }, "\(labels)")
        XCTAssertTrue(labels.contains { $0.contains("Set Up Again") }, "\(labels)")
    }

    /// A task on the mounted image ends and the runner stands by, as after every chat or agent task:
    /// `local_ddi` is gone from the runner, but the next task is handed to the image again, so no
    /// screen asks to turn the loopback on. Only a pairing the hand-over cannot use keeps the prompt.
    func testAfterATaskOnTheMountedImageNoScreenAsksForTheLoopback() async throws {
        let pairing = AppFiles.phonePairingFile
        let saved = try? Data(contentsOf: pairing)
        defer { if let saved { try? saved.write(to: pairing) } else { try? FileManager.default.removeItem(at: pairing) } }
        let phonePairing: [String: Any] = ["identifier": "test-host", "public_key": Data(repeating: 1, count: 32), "private_key": Data(repeating: 2, count: 32)]
        try PropertyListSerialization.data(fromPropertyList: phonePairing, format: .xml, options: 0).write(to: pairing)

        // The loopback page probes 10.7.0.1 when it appears, and this Mac may answer there: every probe says no answer.
        let forced = UserDefaults.standard.object(forKey: "pokiLoopback")
        UserDefaults.standard.set("noanswer", forKey: "pokiLoopback")
        defer { UserDefaults.standard.set(forced, forKey: "pokiLoopback") }
        let (model, restore) = try modelWithLoopbackChosen(launcher: FakeLauncher(), imageMounted: { true })
        defer { restore() }
        model.loopback.simulate(.noAnswer)
        model.startSession()
        model.wakeRunner()
        await waitOnMain { ["failed", "running"].contains(model.runner.state) }
        model.runnerChanged(RunnerStatus(state: "running", code: "local_ddi"))
        XCTAssertNil(SetupIssueHint.first(model: model), "during the task")

        model.pauseRunner(reason: "Stopped after 1 min without agent activity", byOwner: false)
        XCTAssertEqual(model.runner.state, "standby")
        XCTAssertNil(SetupIssueHint.first(model: model), "the chat after the task")
        XCTAssertNil(SetupIssueHint.homeLine(model: model), "Home after the task")
        XCTAssertFalse(Issue.current(model).contains { $0.id == "loopback" }, "Settings issues after the task")
        XCTAssertTrue(model.setupReadyForUse, "the Settings entry after the task")
        let connection = try await renderedLabels(of: NavigationStack { SetupSettingsPage(path: .constant(NavigationPath())) }, model: model)
        XCTAssertFalse(connection.contains { $0.contains("Turn On") || $0.contains("Continue Setup") }, "Connection after the task: \(connection)")
        model.setup.proxyApp = "localdevvpn"
        let page = try await renderedLabels(of: NavigationStack { SetupStepPage(step: .loopback) }, model: model)
        XCTAssertTrue(page.contains { $0.contains("Local automation ready") }, "the loopback page's status after the task: \(page)")
        XCTAssertFalse(page.contains { $0.contains("No Answer") || $0.contains("with the loopback on") }, "the loopback page after the task: \(page)")
        let chat = try await renderedLabels(
            of: NavigationStack { ChatView(openVoice: {}, openSetup: {}, openModel: {}, openThreads: {}) },
            model: model
        )
        XCTAssertFalse(chat.contains { $0.contains("Turn On Local Connection") || $0.contains("Local Connection is off") }, "Chat after the task: \(chat)")

        // Another open step is named as itself, not as the loopback.
        model.setup.uiAutomation = false
        XCTAssertEqual(SetupIssueHint.first(model: model)?.target, .step(.automation))
        model.setup.uiAutomation = true

        // A pairing file from a computer is never handed to the image: the loopback is still needed.
        let lockdown: [String: Any] = ["HostID": "test-host", "SystemBUID": "test"]
        try PropertyListSerialization.data(fromPropertyList: lockdown, format: .xml, options: 0).write(to: pairing)
        XCTAssertEqual(SetupIssueHint.first(model: model)?.target, .step(.loopback), "a computer's pairing file")
        XCTAssertTrue(Issue.current(model).contains { $0.id == "loopback" }, "Settings issues, a computer's pairing file")
        let refused = try await renderedLabels(of: NavigationStack { SetupStepPage(step: .loopback) }, model: model)
        XCTAssertTrue(refused.contains { $0.contains("with the loopback on") }, "the loopback page, a computer's pairing file: \(refused)")
    }

    private func waitOnMain(_ condition: @escaping () -> Bool) async {
        let done = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        await fulfillment(of: [done], timeout: 5)
    }

    private func renderedLabels<Content: View>(of view: Content, model: AppModel) async throws -> [String] {
        let chat = ChatModel(app: model)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        window.rootViewController = UIHostingController(
            rootView: view.environment(model).environment(chat).environment(\.accessibilityEnabled, true)
        )
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        window.layoutIfNeeded()
        let drawn = expectation(description: "rendered view")
        let frames = SessionEvidenceFrames { drawn.fulfill() }
        let display = CADisplayLink(target: frames, selector: #selector(SessionEvidenceFrames.tick))
        display.add(to: .main, forMode: .common)
        await fulfillment(of: [drawn], timeout: 5)
        display.invalidate()
        return Self.collectLabels(in: window)
    }

    private static func collectLabels(in root: NSObject) -> [String] {
        var labels: [String] = []
        var pending = [root]
        var visited = Set<ObjectIdentifier>()
        while let item = pending.popLast() {
            guard visited.insert(ObjectIdentifier(item)).inserted else { continue }
            if let label = item.accessibilityLabel, !label.isEmpty { labels.append(label) }
            if let value = item.accessibilityValue, !value.isEmpty { labels.append(value) }
            if let view = item as? UIView { pending.append(contentsOf: view.subviews) }
            if let children = item.accessibilityElements { pending.append(contentsOf: children.compactMap { $0 as? NSObject }) }
            let count = item.accessibilityElementCount()
            if count > 0 && count < 1000 {
                for index in 0..<count {
                    if let child = item.accessibilityElement(at: index) as? NSObject { pending.append(child) }
                }
            }
        }
        return labels
    }
}

@MainActor
private final class SessionEvidenceFrames: NSObject {
    private var remaining = 3
    private let drawn: () -> Void
    init(drawn: @escaping () -> Void) { self.drawn = drawn }
    @objc func tick() {
        guard remaining > 0 else { return }
        remaining -= 1
        if remaining == 0 { drawn() }
    }
}

private final class DelayedSimulatorAutomation: InProcessAutomation, @unchecked Sendable {
    private let lock = NSLock()
    private var requested: TimeInterval = 0
    private var ready: TimeInterval = 0
    var times: (requested: TimeInterval, ready: TimeInterval) { lock.withLock { (requested, ready) } }
    func prepare() -> [String: Any] {
        lock.withLock { requested = ProcessInfo.processInfo.systemUptime }
        Thread.sleep(forTimeInterval: 1.92)
        let result = PKInProcess.shared().prepare()
        lock.withLock { ready = ProcessInfo.processInfo.systemUptime }
        return result
    }
    func close() -> [String: Any] { PKInProcess.shared().close() }
    func pauseAutomation() -> [String: Any] { PKInProcess.shared().pauseAutomation() }
}
