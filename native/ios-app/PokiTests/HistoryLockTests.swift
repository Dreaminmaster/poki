import LocalAuthentication
import Security
import XCTest
import notify
@testable import Poki

/// Screen History's lock: once set up, losing Face ID or Touch ID never lets a new PIN in; an unreadable
/// PIN is not a missing one; the wait after wrong PINs holds; and a fresh install of Poki, whose old
/// history is gone, can always be set up again.
@MainActor
final class HistoryLockTests: XCTestCase {
    private let match: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "nz.zheha.poki.history-lock",
    ]
    private var savedDefaults: [String: Any] = [:]

    override func setUp() async throws {
        savedDefaults = lockDefaults()
        wipeLockDefaults()
        SecItemDelete(match as CFDictionary)
        setSimulatorBiometricsEnrolled(false)
        await HistoryStore.shared.deleteEverything()
        HistoryLock.shared.lock()
    }

    override func tearDown() async throws {
        setSimulatorBiometricsEnrolled(false)
        SecItemDelete(match as CFDictionary)
        wipeLockDefaults()
        for (key, value) in savedDefaults { UserDefaults.standard.set(value, forKey: key) }
        await HistoryStore.shared.deleteEverything()
        HistoryLock.shared.lock()
    }

    // MARK: On the simulator's own keychain and Face ID

    func testTurningOffBiometricsDoesNotLetANewPINOpenProtectedHistory() async {
        let lock = HistoryLock.shared
        XCTAssertTrue(lock.needsSetup)
        XCTAssertTrue(lock.setPIN("2468"))
        XCTAssertTrue(lock.unlocked)

        setSimulatorBiometricsEnrolled(true)
        lock.lock()
        XCTAssertFalse(lock.unlock(pin: "0000"))
        XCTAssertTrue(lock.unlock(pin: "2468"))
        XCTAssertTrue(lock.biometricsReady)
        XCTAssertTrue(lock.setBiometrics(true))
        XCTAssertTrue(lock.removePIN())
        XCTAssertFalse(lock.hasPIN)

        XCTAssertTrue(HistoryCapture().keep(read("com.apple.mobilenotes", ["Private medical note"])))
        lock.lock()
        XCTAssertFalse(lock.unlocked)

        setSimulatorBiometricsEnrolled(false)
        lock.lock()
        XCTAssertFalse(lock.biometricsReady)
        XCTAssertFalse(lock.usesBiometrics)
        XCTAssertFalse(lock.needsSetup, "Protected Screen History must not fall back to initial PIN setup when biometrics becomes unavailable")
        XCTAssertFalse(lock.setPIN("1234"), "A locked Screen History without biometrics must refuse a new PIN")
        XCTAssertFalse(lock.unlock(pin: "1234"))
        XCTAssertFalse(lock.unlocked)

        setSimulatorBiometricsEnrolled(true)
        lock.lock()
        XCTAssertTrue(lock.usesBiometrics)
        XCTAssertFalse(lock.needsSetup)
        XCTAssertFalse(lock.unlocked)
    }

    func testAReinstalledPokiWithoutBiometricsOrAPINCanMakeANewPIN() async {
        let lock = HistoryLock.shared
        XCTAssertTrue(lock.setPIN("2468"))
        setSimulatorBiometricsEnrolled(true)
        lock.lock()
        XCTAssertTrue(lock.unlock(pin: "2468"))
        XCTAssertTrue(lock.setBiometrics(true))
        XCTAssertTrue(lock.removePIN())
        XCTAssertTrue(HistoryCapture().keep(read("com.apple.mobilenotes", ["Private medical note"])))

        // Deleting Poki takes its settings and its Screen History. The keychain stays.
        await HistoryStore.shared.deleteEverything()
        wipeLockDefaults()
        setSimulatorBiometricsEnrolled(false)
        lock.lock()

        XCTAssertTrue(lock.needsSetup, "A fresh install with no history, no Face ID and no PIN must offer a new PIN")
        XCTAssertTrue(lock.setPIN("1357"))
        XCTAssertTrue(lock.unlocked)
        lock.lock()
        XCTAssertFalse(lock.unlock(pin: "2468"))
        XCTAssertTrue(lock.unlock(pin: "1357"))
    }

    // MARK: On a stand-in iPhone

    func testAPINThatCannotBeReadWhileTheIPhoneIsLockedIsNotAMissingPIN() {
        let phone = Phone()
        phone.biometrics = .unavailable
        XCTAssertTrue(phone.launch().setPIN("2468"))

        phone.deviceLocked = true
        let lock = phone.launch()
        XCTAssertFalse(lock.needsSetup, "An unreadable PIN must not offer setup")
        XCTAssertFalse(lock.biometricsUnavailable, "A locked iPhone is not a Face ID problem to fix in Settings")
        XCTAssertFalse(lock.setPIN("1111"))
        XCTAssertFalse(lock.unlock(pin: "2468"))
        XCTAssertFalse(lock.unlocked)

        phone.deviceLocked = false
        lock.refresh()
        XCTAssertTrue(lock.hasPIN)
        XCTAssertFalse(lock.unlock(pin: "1111"))
        XCTAssertTrue(lock.unlock(pin: "2468"))
    }

    func testTheWaitAfterFiveWrongPINsHoldsUntilItEnds() {
        let phone = Phone()
        phone.biometrics = .unavailable
        let lock = phone.launch()
        XCTAssertTrue(lock.setPIN("2468"))
        lock.lock()

        for _ in 0..<5 { XCTAssertFalse(lock.unlock(pin: "0000")) }
        let start = phone.now
        XCTAssertEqual(lock.blockedUntil, start.addingTimeInterval(30))
        XCTAssertFalse(lock.unlock(pin: "2468"), "The right PIN must wait too")

        lock.lock()
        lock.refresh()
        phone.now = start.addingTimeInterval(29)
        XCTAssertFalse(lock.unlock(pin: "2468"), "Leaving Poki must not end the wait")

        phone.now = start.addingTimeInterval(30)
        XCTAssertFalse(lock.unlock(pin: "0000"))
        XCTAssertEqual(lock.blockedUntil, start.addingTimeInterval(90), "The sixth wrong PIN doubles the wait")

        phone.now = start.addingTimeInterval(90)
        XCTAssertTrue(lock.unlock(pin: "2468"))
        lock.lock()
        XCTAssertEqual(lock.failures, 0)
        XCTAssertNil(lock.blockedUntil)
    }

    func testHistoryFromAnEarlierPokiStaysLockedWhenFaceIDIsOff() async {
        let store = HistoryStore.shared
        for keep in [Kept.read, .summaryOnly] {
            switch keep {
            case .read:
                XCTAssertTrue(HistoryCapture().keep(read("com.apple.mobilenotes", ["Private medical note"])))
            case .summaryOnly:
                let generation = await store.summaryGeneration()
                await store.keep(BacktapeNote(title: "Doctor", body: "A private visit."), start: Date(timeIntervalSince1970: 1_800_000_000), generation: generation)
                let reads = await store.recent()
                XCTAssertTrue(reads.isEmpty)
            }
            let phone = Phone(history: { store.holdsAnything() })
            phone.biometrics = .deniedForPoki
            let lock = phone.launch()
            XCTAssertTrue(lock.biometricsUnavailable, "\(keep)")
            XCTAssertFalse(lock.needsSetup, "\(keep)")
            XCTAssertFalse(lock.setPIN("1234"), "\(keep)")

            await HistoryCapture().clearEverything()
            phone.reinstall()
            XCTAssertTrue(phone.launch().needsSetup, "\(keep)")
        }
    }

    func testReadsKeptBeforeScreenHistoryWasOpenedStayLockedWhenFaceIDIsLockedOut() {
        var holds = false
        let phone = Phone(history: { holds })
        let lock = phone.launch()
        XCTAssertFalse(lock.needsSetup)

        // A read started in Testing Options is kept; nobody has opened Screen History yet. Then Face ID
        // fails five times, or is turned off for Poki in Settings.
        holds = true
        phone.biometrics = .deniedForPoki
        XCTAssertFalse(lock.setPIN("1234"), "A new PIN must not open reads nobody has unlocked")
        XCTAssertFalse(lock.unlocked)
        XCTAssertFalse(lock.needsSetup)
        XCTAssertTrue(lock.biometricsUnavailable)

        lock.lock()
        lock.refresh()
        XCTAssertFalse(lock.needsSetup)
        XCTAssertFalse(lock.setPIN("1234"))
    }

    func testAReadStartedWithFaceIDStaysLockedWhenFaceIDIsRemovedBeforePokiLooksAgain() {
        var holds = false
        let phone = Phone(history: { holds })
        let lock = phone.launch()
        lock.readStarting()

        // The read keeps text while Poki is in the background, and Face ID is removed in Settings
        // before Poki comes back.
        holds = true
        phone.biometrics = .unavailable
        lock.refresh()
        XCTAssertFalse(lock.needsSetup)
        XCTAssertTrue(lock.biometricsUnavailable)
        XCTAssertFalse(lock.setPIN("1234"))
        XCTAssertFalse(lock.unlocked)
    }

    func testAReinstalledPokiDropsAPINLeftByTheDeletedInstall() {
        let phone = Phone()
        phone.biometrics = .unavailable
        XCTAssertTrue(phone.launch().setPIN("2468"))

        phone.reinstall()
        let lock = phone.launch()
        XCTAssertTrue(lock.needsSetup, "A PIN from the deleted Poki guards nothing and may be forgotten")
        XCTAssertTrue(lock.setPIN("1357"))
        lock.lock()
        XCTAssertFalse(lock.unlock(pin: "2468"))
        XCTAssertTrue(lock.unlock(pin: "1357"))
    }

    func testLateBiometricSuccessCannotRestoreTheAgentGrant() async {
        let phone = Phone()
        var grants: [Bool] = []
        let lock = phone.launch(agentGrantChanged: { grants.append($0) })
        phone.evaluate = {
            await Task.yield()
            lock.lock()
            return true
        }
        await lock.unlockWithBiometrics()
        XCTAssertFalse(lock.unlocked)
        XCTAssertFalse(grants.contains(true), "The obsolete attempt must never grant access")
        phone.evaluate = nil
        await lock.unlockWithBiometrics()
        XCTAssertTrue(lock.unlocked)
        XCTAssertEqual(grants.last, true)
    }

    func testCredentialChangesSuspendTheGrantAndFailedPINSaveLeavesItClosed() {
        let phone = Phone()
        phone.biometrics = .unavailable
        var grants: [Bool] = []
        let lock = phone.launch(agentGrantChanged: { grants.append($0) })
        XCTAssertTrue(lock.setPIN("2468"))
        XCTAssertEqual(grants.last, true)
        phone.onPINWrite = { XCTAssertEqual(grants.last, false, "Revoke before replacing the PIN") }
        XCTAssertTrue(lock.setPIN("1357"))
        XCTAssertEqual(grants.last, false, "PIN replacement requires fresh authentication")
        XCTAssertTrue(lock.unlock(pin: "1357"))
        XCTAssertEqual(grants.last, true)

        phone.biometrics = .usable
        XCTAssertTrue(lock.setBiometrics(true))
        XCTAssertEqual(grants.last, false, "Changing authentication settings must revoke the grant")
        XCTAssertTrue(lock.unlock(pin: "1357"))
        phone.failPINWrite = true
        XCTAssertFalse(lock.setPIN("8642"))
        XCTAssertFalse(lock.unlocked)
        XCTAssertEqual(grants.last, false, "A failed replacement must not restore the old grant")
    }

    func testUnreadableKeychainRevokesAnUnlockedGrantUntilFreshAuthentication() {
        let phone = Phone()
        phone.biometrics = .unavailable
        var grants: [Bool] = []
        let lock = phone.launch(agentGrantChanged: { grants.append($0) })
        XCTAssertTrue(lock.setPIN("2468"))
        XCTAssertEqual(grants.last, true)
        phone.deviceLocked = true
        lock.refresh()
        XCTAssertEqual(lock.state, .deviceLocked)
        XCTAssertEqual(grants.last, false)
        XCTAssertFalse(lock.unlock(pin: "2468"))
        phone.deviceLocked = false
        lock.refresh()
        XCTAssertFalse(lock.unlocked)
        XCTAssertEqual(grants.last, false)
        XCTAssertTrue(lock.unlock(pin: "2468"))
        XCTAssertEqual(grants.last, true)
    }

    func testTimedGrantExpiresAtDeadlineAndCannotBeRenewedByReads() {
        let clock = GrantTestClock()
        let lease = HistoryQueryPermissionLease(enabled: true, duration: .seconds(300), now: { clock.now })
        lease.setUnlocked(true)
        let start = lease.grant
        XCTAssertNotNil(start)
        clock.advance(.seconds(299))
        XCTAssertEqual(lease.grant, start)
        XCTAssertEqual(lease.revision, start)
        clock.advance(.seconds(1))
        XCTAssertNil(lease.grant)
        XCTAssertNotEqual(lease.revision, start)
        let expired = lease.revision
        XCTAssertEqual(lease.revision, expired, "Expiration only invalidates the revision once")
        lease.setUnlocked(true)
        XCTAssertNotNil(lease.grant)
        XCTAssertNotEqual(lease.grant, start)
    }

    func testTurningFeatureOffDoesNotRestoreTimedGrantWhenEnabledAgain() {
        let lease = HistoryQueryPermissionLease(enabled: true)
        lease.setUnlocked(true)
        XCTAssertNotNil(lease.grant)
        lease.setEnabled(false)
        XCTAssertNil(lease.grant)
        lease.setEnabled(true)
        XCTAssertNil(lease.grant)
        lease.setUnlocked(true)
        XCTAssertNotNil(lease.grant)
        lease.setUnlocked(false)
        XCTAssertNil(lease.grant)
    }

    // MARK: Helpers

    private enum Kept { case read, summaryOnly }

    private func read(_ app: String, _ text: [String]) -> [String: Any] {
        ["ok": true, "app": app, "title": "", "text": text, "changed": true]
    }

    private func lockDefaults() -> [String: Any] {
        UserDefaults.standard.dictionaryRepresentation().filter { $0.key.hasPrefix("history.lock.") }
    }

    private func wipeLockDefaults() {
        lockDefaults().keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }

    private func setSimulatorBiometricsEnrolled(_ enrolled: Bool) {
        var token: Int32 = 0
        guard notify_register_check("com.apple.BiometricKit.enrollmentChanged", &token) == NOTIFY_STATUS_OK else { return }
        _ = notify_set_state(token, enrolled ? 1 : 0)
        _ = notify_post("com.apple.BiometricKit.enrollmentChanged")
        _ = notify_cancel(token)
        // The simulator applies the change a moment later, and later still on a busy Mac.
        let deadline = Date().addingTimeInterval(10)
        while LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) != enrolled, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }
}

/// An iPhone with its keychain, Face ID, clock and Poki's settings in memory. Poki's settings and its
/// Screen History go with a reinstall; the keychain stays.
@MainActor
private final class Phone {
    /// Each item with whether it can be read only while the iPhone is unlocked.
    var keychain: [String: (value: Data, whenUnlocked: Bool)] = [:]
    var deviceLocked = false
    var failPINWrite = false
    var onPINWrite: (() -> Void)?
    var evaluate: (() async -> Bool)?
    var biometrics = HistoryLock.Biometrics.usable
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    private var defaults = Phone.freshDefaults()
    private let history: () -> Bool?

    init(history: @escaping () -> Bool? = { false }) {
        self.history = history
    }

    func launch(agentGrantChanged: ((Bool) -> Void)? = nil) -> HistoryLock {
        HistoryLock(boundary: HistoryLock.Boundary(
            biometrics: { [self] in biometrics },
            evaluateBiometrics: { [self] _ in
                if let evaluate { return await evaluate() }
                return biometrics.ready
            },
            readKeychain: { [self] account in
                guard let item = keychain[account] else { return .absent }
                return deviceLocked && item.whenUnlocked ? .inaccessibleWhileDeviceLocked : .present(item.value)
            },
            writeKeychain: { [self] account, value, accessible in
                let whenUnlocked = accessible == kSecAttrAccessibleWhenUnlockedThisDeviceOnly
                guard !(deviceLocked && whenUnlocked) else { return false }
                if account == "pin" {
                    onPINWrite?()
                    if failPINWrite { keychain[account] = nil; return false }
                }
                keychain[account] = (value, whenUnlocked)
                return true
            },
            deleteKeychain: { [self] account in keychain[account] = nil },
            defaults: defaults,
            historyHoldsAnything: { [self] in history() },
            now: { [self] in now }
        ), agentGrantChanged: agentGrantChanged)
    }

    /// Poki's settings go. Screen History goes too, and the caller empties the store it reads.
    func reinstall() {
        defaults = Self.freshDefaults()
    }

    private static func freshDefaults() -> UserDefaults {
        let name = "HistoryLockTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }
}

private extension HistoryLock.Biometrics {
    static let usable = Self(ready: true, name: "Face ID", blockedOrDeniedOnHardware: false)
    static let unavailable = Self(ready: false, name: "Face ID", blockedOrDeniedOnHardware: false)
    static let deniedForPoki = Self(ready: false, name: "Face ID", blockedOrDeniedOnHardware: true)
}

/// Deterministically models elapsed continuous time without sleeping or changing the system clock.
private final class GrantTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock().now
    var now: ContinuousClock.Instant { lock.withLock { instant } }
    func advance(_ duration: Duration) { lock.withLock { instant = instant.advanced(by: duration) } }
}
