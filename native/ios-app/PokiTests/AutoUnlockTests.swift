#if targetEnvironment(simulator)
import Security
import XCTest
@testable import Poki

@MainActor
final class AutoUnlockTests: XCTestCase {
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
