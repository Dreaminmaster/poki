#if targetEnvironment(simulator)
import Darwin
import Security
import XCTest
@testable import Poki

@MainActor
final class AutoUnlockTests: XCTestCase {
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
}
#endif
