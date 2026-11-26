import XCTest
@testable import Poki

/// The owner: the list that follows the caret finds the app being typed, also while a Pinyin keyboard
/// is still composing, and offers connectors after @.
@MainActor
final class MentionSearchTests: XCTestCase {
    private let taobao = "com.taobao.taobao4iphone"

    private func ids(_ query: String, pending: Bool = false, explicit: Bool = false) -> [String] {
        MentionSearch.matches(query, pending: pending, explicit: explicit).map(\.capsule.id)
    }

    func testLatinWordFindsTheAppByItsStart() {
        let found = MentionSearch.query(before: "open Taob", pendingStart: nil)
        XCTAssertEqual(found?.text, "Taob")
        XCTAssertEqual(found?.start, 5)
        XCTAssertEqual(ids("Taob").first, taobao)
    }

    func testTwoLettersAreNotAQueryWithoutAt() {
        XCTAssertNil(MentionSearch.query(before: "go", pendingStart: nil))
    }

    func testPendingPinyinFindsTheChineseName() {
        // The keyboard composes "tao'b" after 打开.
        let found = MentionSearch.query(before: "打开tao'b", pendingStart: 2)
        XCTAssertEqual(found?.text, "tao'b")
        XCTAssertEqual(found?.start, 2)
        XCTAssertTrue(ids("tao'b", pending: true).contains(taobao))
        XCTAssertTrue(ids("tb", pending: true).contains(taobao))
    }

    /// The owner, Nov 20 2026: Pinyin's pending letters spell a Chinese name. "sla" still composing
    /// is not Slack, and "tao" composing finds 淘宝 by its Pinyin, not Taobao by its Latin name.
    func testPendingPinyinLettersMatchOnlyChineseNamesByTheirPinyin() {
        XCTAssertTrue(ids("Sla").contains("com.tinyspeck.chatlyio"))
        XCTAssertFalse(ids("sla", pending: true).contains("com.tinyspeck.chatlyio"))
        XCTAssertTrue(ids("tao", pending: true).contains(taobao))
    }

    /// The Pinyin keyboard composes with a six-per-em space between syllables ("t\u{2006}b").
    func testPinyinSyllableSpacesDoNotStopTheMatch() {
        XCTAssertTrue(ids("t\u{2006}b", pending: true).contains(taobao))
        XCTAssertTrue(ids("tao\u{2006}bao", pending: true).contains(taobao))
    }

    func testCommittedChineseFindsTheNameFromTheEndOfTheRun() {
        let found = MentionSearch.query(before: "帮我打开淘", pendingStart: nil)
        XCTAssertEqual(found?.text, "淘")
        XCTAssertTrue(ids("淘").contains(taobao))
    }

    /// 大 is in both 大众点评 and 大眾點評: what goes in is the name in Poki's language.
    func testATieGoesToTheNameInPokisLanguage() {
        let saved = AppLocalization.shared.preference
        defer { AppLocalization.shared.preference = saved }
        let dianping = "com.dianping.dpscope"
        for (language, expected) in [("zh-Hant", "大眾點評"), ("zh-Hans", "大众点评"), ("en", "大众点评")] {
            AppLocalization.shared.preference = language
            let match = MentionSearch.matches("大", pending: false, explicit: false).first { $0.capsule.id == dianping }
            XCTAssertEqual(match?.insert, expected, language)
        }
    }

    func testAtStartsAnExplicitQuery() {
        let found = MentionSearch.query(before: "ask @No", pendingStart: nil)
        XCTAssertEqual(found?.text, "No")
        XCTAssertEqual(found?.start, 4)
        XCTAssertEqual(found?.explicit, true)
        // An address is not a mention.
        XCTAssertNil(MentionSearch.query(before: "mail@No", pendingStart: nil))
    }

    func testConnectorCapsuleReadsBackAsWritten() {
        ConnectorCapsules.set([AppCapsule(id: ConnectorCapsules.prefix + "notion", names: ["@Notion"], symbol: "doc.text")])
        defer { ConnectorCapsules.set([]) }
        let segments = CapsuleText.segments("find it in @Notion please")
        XCTAssertTrue(segments.contains { if case .app(let app, "@Notion") = $0 { app.isConnector } else { false } })
        XCTAssertEqual(ids("Not", explicit: true).first, ConnectorCapsules.prefix + "notion")
    }

    func testPickedEverydayNameBecomesACapsuleMidSentence() {
        XCTAssertFalse(CapsuleText.segments("我想看设置").contains { if case .app = $0 { true } else { false } })
        CapsuleText.confirm("设置")
        defer { CapsuleText.forgetConfirmed() }
        XCTAssertTrue(CapsuleText.segments("我想看设置").contains { if case .app = $0 { true } else { false } })
    }

    func testConnectorToolNamesStayUniqueAndShort() {
        var taken = Set<String>()
        let first = ConnectorTools.uniqueName(prefix: "notion", tool: "search pages", taken: &taken)
        let second = ConnectorTools.uniqueName(prefix: "notion", tool: "search pages", taken: &taken)
        XCTAssertEqual(first, "notion__search_pages")
        XCTAssertNotEqual(first, second)
        let long = ConnectorTools.uniqueName(prefix: "notion", tool: String(repeating: "x", count: 100), taken: &taken)
        XCTAssertLessThanOrEqual(long.count, 64)
    }
}
