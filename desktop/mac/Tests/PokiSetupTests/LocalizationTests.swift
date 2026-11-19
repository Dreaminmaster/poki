import XCTest
@testable import PokiSetup

final class LocalizationTests: XCTestCase {
    func testSystemLanguageAndFallback() {
        XCTAssertEqual(SetupLanguage.system.resolve(preferred: ["zh-CN"]), "zh-Hans")
        XCTAssertEqual(SetupLanguage.system.resolve(preferred: ["de"]), "en")
        XCTAssertEqual(SetupLanguage.english.resolve(preferred: ["zh-Hans"]), "en")
    }

    func testSwitchingAndRestoringLanguage() {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let localization = SetupLocalization(defaults: defaults)
        XCTAssertEqual(localization.language, .system)
        localization.language = .simplifiedChinese
        XCTAssertEqual(localization.text("Apple Account"), "Apple 账户")
        let name = "Jane's iPad"
        let run = 42
        XCTAssertEqual(localization.text("Installed test build \(run) on \(name)."), "已在 Jane's iPad 上安装测试构建 42。")
        XCTAssertEqual(SetupLocalization(defaults: defaults).language, .simplifiedChinese)
        localization.language = .english
        XCTAssertEqual(localization.text("Apple Account"), "Apple Account")
        defaults.set("unknown", forKey: "uiLanguage")
        XCTAssertEqual(SetupLocalization(defaults: defaults).language, .system)
    }

    func testBundledTranslationsKeepEveryKeyAndArgument() throws {
        func entries(_ language: String, table: String) throws -> [String: String] {
            let url = try XCTUnwrap(Bundle.module.url(forResource: table, withExtension: "strings",
                                                       subdirectory: nil, localization: language))
            let data = try Data(contentsOf: url)
            return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
        }

        // A translation may reorder arguments using e.g. %2$@, but their types must agree.
        let placeholder = try NSRegularExpression(pattern: #"%(?:(\d+)\$)?(lld|d|@)"#)
        func signature(_ text: String) -> [String] {
            let source = text as NSString
            let matches = placeholder.matches(in: text, range: NSRange(location: 0, length: source.length))
            return matches.enumerated().map { offset, match in
                let index = match.range(at: 1)
                let position = index.location == NSNotFound ? String(offset + 1) : source.substring(with: index)
                return position + source.substring(with: match.range(at: 2))
            }.sorted()
        }

        for table in ["Localizable", "Progress"] {
            let english = try entries("en", table: table)
            let chinese = try entries("zh-Hans", table: table)
            XCTAssertEqual(Set(english.keys), Set(chinese.keys))
            for (key, value) in chinese {
                XCTAssertFalse(value.isEmpty, key)
                XCTAssertEqual(signature(key), signature(value), key)
            }
        }
    }
}
