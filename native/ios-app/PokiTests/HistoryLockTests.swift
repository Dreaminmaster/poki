import XCTest
@testable import Poki

/// Screen History's lock since Nov 21 2026: only the system prompt opens it, Poki has no PIN, Face ID or
/// Touch ID is always used where the iPhone has it, the passcode only with it (or alone after the owner
/// accepted the warning on an iPhone without one), and the agents' grant never outlives the unlock.
@MainActor
final class HistoryLockTests: XCTestCase {
    func testOnlyTheSystemPromptOpensHistoryAndTheGrantFollowsIt() async {
        let phone = Phone()
        var grants: [Bool] = []
        let lock = phone.launch(agentGrantChanged: { grants.append($0) })
        XCTAssertEqual(lock.state, .locked)
        XCTAssertFalse(lock.usesPasscode, "With Face ID, the passcode is off until the owner allows it")

        phone.passes = false
        let refused = await lock.open()
        XCTAssertFalse(refused)
        XCTAssertFalse(lock.unlocked)
        XCTAssertEqual(phone.asked.last?.passcode, false)

        phone.passes = true
        let opened = await lock.open()
        XCTAssertTrue(opened)
        XCTAssertTrue(lock.unlocked)
        XCTAssertEqual(grants.last, true)

        lock.lock()
        XCTAssertFalse(lock.unlocked)
        XCTAssertEqual(grants.last, false)
    }

    func testLockingWhileThePromptIsUpMakesItsAnswerStale() async {
        let phone = Phone()
        var grants: [Bool] = []
        let lock = phone.launch(agentGrantChanged: { grants.append($0) })
        phone.evaluate = {
            await Task.yield()
            lock.lock()
            return true
        }
        let opened = await lock.open()
        XCTAssertFalse(opened)
        XCTAssertFalse(lock.unlocked)
        XCTAssertFalse(grants.contains(true), "The obsolete prompt must never grant access")
    }

    func testThePasscodeComesOnlyWithTheBiometricAndChangingItCloses() async {
        let phone = Phone()
        var grants: [Bool] = []
        let lock = phone.launch(agentGrantChanged: { grants.append($0) })
        _ = await lock.open()
        XCTAssertTrue(lock.unlocked)

        XCTAssertTrue(lock.changePasscode(true))
        XCTAssertTrue(lock.usesPasscode)
        XCTAssertFalse(lock.unlocked, "A changed way in closes what the old one opened")
        XCTAssertEqual(grants.last, false)
        _ = await lock.open()
        XCTAssertEqual(phone.asked.last?.passcode, true)

        phone.biometrics = .unavailable
        lock.refresh()
        XCTAssertFalse(lock.canTurnOffPasscode, "Without a biometric the passcode is the only way in")
        XCTAssertFalse(lock.changePasscode(false))
    }

    func testWithoutABiometricSensesWaitsForTheWarning() async {
        let phone = Phone()
        phone.biometrics = .unavailable
        let lock = phone.launch()
        XCTAssertTrue(lock.needsRiskAcknowledgement)
        let early = await lock.open()
        XCTAssertFalse(early)
        XCTAssertTrue(phone.asked.isEmpty, "No prompt before the owner read the warning")

        lock.acceptRisk()
        XCTAssertFalse(lock.needsRiskAcknowledgement)
        let opened = await lock.open()
        XCTAssertTrue(opened)
        XCTAssertEqual(phone.asked.last?.passcode, true)

        // Face ID set up later, then gone again: the warning is asked again.
        phone.biometrics = .usable
        lock.refresh()
        phone.biometrics = .unavailable
        lock.refresh()
        XCTAssertTrue(lock.needsRiskAcknowledgement)
    }

    func testAnIPhoneWithNoPasscodeAndNoBiometricCannotOpenHistory() async {
        let phone = Phone()
        phone.biometrics = .unavailable
        phone.passcodeSet = false
        let lock = phone.launch()
        XCTAssertEqual(lock.state, .unavailable)
        let opened = await lock.open()
        XCTAssertFalse(opened)
    }

    func testTheOldPokiPINIsRemovedOnce() {
        let phone = Phone()
        _ = phone.launch()
        _ = phone.launch()
        XCTAssertEqual(phone.forgotPIN, 1)
    }

    func testTheIPhoneLockingRevokesUntilAFreshPrompt() async {
        let phone = Phone()
        var grants: [Bool] = []
        let lock = phone.launch(agentGrantChanged: { grants.append($0) })
        _ = await lock.open()
        XCTAssertEqual(grants.last, true)
        NotificationCenter.default.post(name: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil)
        XCTAssertEqual(lock.state, .deviceLocked)
        XCTAssertEqual(grants.last, false)
        let locked = await lock.open()
        XCTAssertFalse(locked)
        NotificationCenter.default.post(name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)
        XCTAssertFalse(lock.unlocked)
        let opened = await lock.open()
        XCTAssertTrue(opened)
    }
}

/// An iPhone with its Face ID, passcode, system prompt and Poki's settings in memory.
@MainActor
private final class Phone {
    var biometrics = HistoryLock.Biometrics.usable
    var passcodeSet = true
    var passes = true
    var evaluate: (() async -> Bool)?
    var asked: [(reason: String, passcode: Bool)] = []
    var forgotPIN = 0
    private let defaults: UserDefaults = {
        let name = "HistoryLockTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }()

    func launch(agentGrantChanged: ((Bool) -> Void)? = nil) -> HistoryLock {
        HistoryLock(boundary: HistoryLock.Boundary(
            biometrics: { [self] in biometrics },
            passcodeSet: { [self] in passcodeSet },
            evaluate: { [self] reason, passcode in
                asked.append((reason, passcode))
                if let evaluate { return await evaluate() }
                return passes
            },
            forgetPIN: { [self] in forgotPIN += 1 },
            defaults: defaults
        ), agentGrantChanged: agentGrantChanged)
    }
}

private extension HistoryLock.Biometrics {
    static let usable = Self(ready: true, name: "Face ID", blockedOrDeniedOnHardware: false)
    static let unavailable = Self(ready: false, name: "Face ID", blockedOrDeniedOnHardware: false)
}
