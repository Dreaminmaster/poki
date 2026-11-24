#if targetEnvironment(simulator)
import Darwin
import Security
import XCTest
@testable import Poki

@MainActor
final class AutoUnlockTests: XCTestCase {
    func testRunnerLocalUnlockStaysOffWithASavedPasscode() async throws {
        let native = UnlockSession()
        let model = AppModel(launcher: FakeLauncher(), pairer: FakePairing(), automation: native)
        try XCTSkipUnless(model.automationPath == .runner, "Launch the test host with -automationPath runner")
        try XCTSkipUnless(!model.autoUnlock.enabled, "This simulator already has an automatic unlock configuration")
        defer {
            try? model.autoUnlock.disable()
            model.stopSession()
            UserDefaults.standard.removeObject(forKey: "relayAddress")
            UserDefaults.standard.removeObject(forKey: "relayEnabled")
            UserDefaults.standard.removeObject(forKey: "wantsOn")
        }
        model.setup.loopback = .proxy
        model.loopback.simulate(.working(ms: 9))
        _ = model.setRelay("https://relay.invalid")
        model.startSession()
        XCTAssertTrue(model.sessionOn)
        try model.autoUnlock.save("046215")

        let unlocked = await model.host.unlockForLocalTask(timeout: 8)
        XCTAssertFalse(unlocked, "An existing opt-in must not unlock the phone while Automatic Unlock is unavailable")
        XCTAssertFalse(native.isOpen, "The disabled feature must not leave an unlock session open")
    }

    func testFailedPasscodeDeletionKeepsAutomaticUnlockOnUntilRetrySucceeds() throws {
        let process = dlopen(nil, RTLD_LAZY)
        let symbol = dlsym(process, "poki_test_fail_next_auto_unlock_delete")
        try XCTSkipUnless(symbol != nil, "Run scripts/auto-unlock-deletion-tests.sh to inject the Keychain error")
        let failNextDelete = unsafeBitCast(try XCTUnwrap(symbol), to: (@convention(c) (CInt) -> Void).self)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "nz.zheha.poki",
            kSecAttrAccount as String: "device-unlock.passcode.v1",
        ]
        let setting = AutoUnlock()
        guard !setting.enabled, SecItemCopyMatching(query as CFDictionary, nil) == errSecItemNotFound else {
            throw XCTSkip("This simulator already has an automatic unlock configuration")
        }
        defer {
            failNextDelete(0)
            try? setting.disable()
        }

        try setting.save("046215")
        failNextDelete(1)
        XCTAssertThrowsError(try setting.disable()) { error in
            XCTAssertEqual((error as NSError).code, Int(errSecInteractionNotAllowed))
        }
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, nil), errSecSuccess)
        XCTAssertTrue(setting.enabled, "A failed deletion must leave the switch on")
        XCTAssertTrue(AutoUnlock().enabled, "A failed deletion must leave the saved setting on")
        XCTAssertTrue(setting.deletionFailed)
        XCTAssertTrue(AutoUnlock().deletionFailed, "The retry must still be offered when settings are read again")

        try setting.disable()
        XCTAssertFalse(setting.enabled)
        XCTAssertFalse(AutoUnlock().enabled)
        XCTAssertFalse(AutoUnlock().deletionFailed)
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, nil), errSecItemNotFound)
    }

    func testSavingAndTurningOffAutomaticUnlockUpdatesThePrivateKeychain() throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "nz.zheha.poki",
            kSecAttrAccount as String: "device-unlock.passcode.v1",
            kSecReturnAttributes as String: true,
        ]
        let setting = AutoUnlock()
        guard !setting.enabled, SecItemCopyMatching(query as CFDictionary, nil) == errSecItemNotFound else {
            throw XCTSkip("This simulator already has an automatic unlock configuration")
        }
        defer { try? setting.disable() }

        XCTAssertFalse(setting.enabled)
        XCTAssertThrowsError(try setting.save("invalid"))
        XCTAssertFalse(AutoUnlock().enabled)
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, nil), errSecItemNotFound)

        let fakePasscode = "046215"
        try setting.save(fakePasscode)
        XCTAssertTrue(AutoUnlock().enabled)
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &result), errSecSuccess)
        let item = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(item[kSecAttrAccessible as String] as? String, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        XCTAssertFalse(item[kSecAttrSynchronizable as String] as? Bool ?? false)
        XCTAssertTrue(item[kSecValueData as String] as? Data == Data(fakePasscode.utf8))

        try setting.disable()
        XCTAssertFalse(AutoUnlock().enabled)
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, nil), errSecItemNotFound)
    }

    func testFailedPasscodeUpdateKeepsTheSavedPasscodeAndSwitchOn() throws {
        let symbol = dlsym(dlopen(nil, RTLD_LAZY), "poki_test_fail_next_auto_unlock_write")
        try XCTSkipUnless(symbol != nil, "Run scripts/auto-unlock-deletion-tests.sh to inject the Keychain error")
        let failNextWrite = unsafeBitCast(try XCTUnwrap(symbol), to: (@convention(c) (CInt) -> Void).self)
        let account = "device-unlock.passcode.v1"
        let setting = AutoUnlock()
        guard !setting.enabled, try Keychain.read(account) == nil else {
            throw XCTSkip("This simulator already has an automatic unlock configuration")
        }
        defer {
            failNextWrite(0)
            try? setting.disable()
        }

        let original = "046215"
        let replacement = "517406"
        try setting.save(original)
        failNextWrite(1)
        XCTAssertThrowsError(try setting.save(replacement))
        XCTAssertTrue(try Keychain.read(account) == Data(original.utf8), "A failed update must keep the saved passcode")
        XCTAssertTrue(setting.enabled, "The switch must still be on after the update fails")
        XCTAssertTrue(AutoUnlock().enabled, "The enabled setting must survive reopening Settings")
        XCTAssertFalse(setting.deletionFailed, "The update failed, not a request to turn off Automatic Unlock")

        try setting.save(replacement)
        XCTAssertTrue(try Keychain.read(account) == Data(replacement.utf8), "Retry must replace the passcode")
        XCTAssertTrue(AutoUnlock().enabled)
        try setting.disable()
        XCTAssertNil(try Keychain.read(account))
    }
}

private final class UnlockSession: InProcessAutomation, @unchecked Sendable {
    private let session = FakeAutomation()
    var isOpen: Bool { session.isOpen }
    func prepare() -> [String: Any] { session.prepare() }
    func close() -> [String: Any] { session.close() }
    func pauseAutomation() -> [String: Any] { session.pauseAutomation() }
    func submitUnlockPasscode(_ passcode: String, timeout: TimeInterval, allowed: @escaping () -> Bool) -> PKUnlockResult {
        isOpen && passcode == "046215" && allowed() ? .unlocked : .unavailable
    }
}
#endif
