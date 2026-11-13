import Foundation
import XCTest
@testable import Poki

final class LocalizationCacheTests: XCTestCase {
    func testRepeatedLookupsKeepTheirLanguageAndPreferenceChangesSwitchIt() {
        let cache = LocalizationCache(supported: ["en", "zh-Hans", "zh-Hant"], preferred: { ["en"] })
        XCTAssertEqual(cache.value(for: "en").language, "en")
        XCTAssertEqual(cache.value(for: "en").language, "en")
        // This is also the key read from effectiveUILanguage in extension builds.
        XCTAssertEqual(cache.value(for: "zh-Hans").language, "zh-Hans")
        XCTAssertEqual(cache.value(for: "zh-Hans").locale.language.languageCode, "zh")
        XCTAssertEqual(cache.value(for: "zh-Hant").language, "zh-Hant")
        XCTAssertEqual(cache.value(for: "zh-Hant").locale.language.script, "Hant")
        XCTAssertEqual(cache.value(for: "en").language, "en")
        XCTAssertEqual(cache.value(for: "en").locale.language.languageCode, "en")
    }

    func testSystemLocaleNotificationRefreshesRegionAndSystemLanguage() {
        let notifications = NotificationCenter()
        var preferred = ["en"]
        var region = Locale(identifier: "en_US")
        let cache = LocalizationCache(supported: ["en", "zh-Hant"], notifications: notifications,
                                      preferred: { preferred }, currentLocale: { region })
        XCTAssertEqual(cache.value(for: "system").language, "en")
        preferred = ["zh-Hant"]
        region = Locale(identifier: "zh_TW")
        notifications.post(name: NSLocale.currentLocaleDidChangeNotification, object: nil)
        XCTAssertEqual(cache.value(for: "system").language, "zh-Hant")
        XCTAssertEqual(cache.value(for: "system").locale.region?.identifier, "TW")
        XCTAssertEqual(cache.value(for: "en").locale.region?.identifier, "TW")
        region = Locale(identifier: "en_GB")
        notifications.post(name: NSLocale.currentLocaleDidChangeNotification, object: nil)
        XCTAssertEqual(cache.value(for: "en").language, "en")
        XCTAssertEqual(cache.value(for: "en").locale.region?.identifier, "GB")
    }
}
