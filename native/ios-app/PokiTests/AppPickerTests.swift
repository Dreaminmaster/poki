import SwiftUI
import XCTest
@testable import Poki

@MainActor
final class AppPickerTests: XCTestCase {
    func testQuickAndRecentAppsFollowRecentOrderWithLanguageDefaults() {
        let suiteName = "AppPickerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = RecentAppsStore(defaults: defaults)
        let defaultQuickZh = AppPickerCatalog.quickApps(limit: 3, recentIDs: store.recentIDs, language: .simplifiedChinese, dynamicApps: [])
        XCTAssertEqual(defaultQuickZh.map(\.id), ["com.tencent.xin", "com.meituan.itakeaway", "com.xingin.discover"])

        let defaultRecentZh = AppPickerCatalog.recentApps(limit: 5, recentIDs: store.recentIDs, language: .simplifiedChinese, dynamicApps: [])
        XCTAssertEqual(defaultRecentZh.map(\.id), [
            "com.tencent.xin",
            "com.xingin.discover",
            "com.meituan.itakeaway",
            "com.taobao.taobao4iphone",
            "com.autonavi.amap",
        ])

        store.record("com.xiaojukeji.didi")
        store.record("ctrip.com")
        store.record("com.xiaojukeji.didi")

        let updatedQuick = AppPickerCatalog.quickApps(limit: 3, recentIDs: store.recentIDs, language: .simplifiedChinese, dynamicApps: [])
        XCTAssertEqual(updatedQuick.map(\.id), ["com.xiaojukeji.didi", "ctrip.com", "com.tencent.xin"])
    }

    func testCategoryFilterAndAliasSearchCoverKnownAndDynamicApps() {
        let dynamic = [DynamicApps.Entry(id: "com.example.coffee", name: "Coffee Club", user: true)]

        let lifestyleSections = AppPickerCatalog.filteredSections(query: "", category: .lifestyle, language: .simplifiedChinese, dynamicApps: dynamic)
        XCTAssertEqual(lifestyleSections.map(\.kind), [.lifestyle])
        XCTAssertTrue(lifestyleSections[0].apps.contains { $0.id == "com.xiaojukeji.didi" })
        XCTAssertFalse(lifestyleSections[0].apps.contains { $0.id == "com.tencent.xin" })

        let alias12306 = AppPickerCatalog.filteredSections(query: "12306", category: .all, language: .simplifiedChinese, dynamicApps: dynamic)
        XCTAssertEqual(alias12306.flatMap(\.apps).map(\.id), ["cn.12306.rails12306"])

        let aliasBilibili = AppPickerCatalog.filteredSections(query: "B站", category: .all, language: .simplifiedChinese, dynamicApps: dynamic)
        XCTAssertEqual(aliasBilibili.flatMap(\.apps).map(\.id), ["tv.danmaku.bilianime"])

        let dynamicMatch = AppPickerCatalog.filteredSections(query: "coffee", category: .all, language: .simplifiedChinese, dynamicApps: dynamic)
        XCTAssertEqual(dynamicMatch.map(\.kind), [.installed])
        XCTAssertEqual(dynamicMatch[0].apps.map(\.id), ["com.example.coffee"])

        let empty = AppPickerCatalog.filteredSections(query: "xyz-no-such-app", category: .all, language: .simplifiedChinese, dynamicApps: dynamic)
        XCTAssertTrue(empty.isEmpty)
    }

    func testAlphabetIndexLettersAndTargetsForChineseApps() {
        XCTAssertEqual(AppPickerCatalog.indexLetter(for: "大众点评"), "D")
        XCTAssertEqual(AppPickerCatalog.indexLetter(for: "滴滴出行"), "D")
        XCTAssertEqual(AppPickerCatalog.indexLetter(for: "铁路12306"), "T")
        XCTAssertEqual(AppPickerCatalog.indexLetter(for: "携程旅行"), "X")
        XCTAssertEqual(AppPickerCatalog.indexLetter(for: "备忘录"), "B")
        XCTAssertEqual(AppPickerCatalog.indexLetter(for: "Messages"), "M")

        let sections = AppPickerCatalog.filteredSections(query: "", category: .all, language: .simplifiedChinese, dynamicApps: [])
        let targets = AppPickerCatalog.indexTargets(for: sections, includesRecent: true, language: .simplifiedChinese)
        XCTAssertEqual(targets.first, AppPickerIndexTarget(label: "热", targetID: "section.recent"))
        XCTAssertTrue(targets.contains { $0.label == "D" })
        XCTAssertTrue(targets.contains { $0.label == "X" })
    }

    func testMentionTriggerRulesMutualExclusionAndEmptyResultState() {
        // Mutual exclusion with `+` menu and mentionReady gate.
        XCTAssertNil(AppPickerCatalog.mentionState(input: "帮我用 @m", mentionReady: true, adding: true, language: .simplifiedChinese, dynamicApps: []))
        XCTAssertNil(AppPickerCatalog.mentionState(input: "帮我用 @m", mentionReady: false, adding: false, language: .simplifiedChinese, dynamicApps: []))

        // Explicit `@` alone shows default recent apps.
        let bareAt = AppPickerCatalog.mentionState(input: "@", mentionReady: true, adding: false, language: .simplifiedChinese, dynamicApps: [])
        XCTAssertNotNil(bareAt)
        XCTAssertEqual(bareAt?.triggerLength, 1)
        XCTAssertEqual(bareAt?.isExplicit, true)
        XCTAssertFalse(bareAt?.matches.isEmpty ?? true)
        XCTAssertEqual(bareAt?.isEmptyResult, false)

        // Explicit `@m` matches multiple apps (>4.5 rows for scroll testing).
        let atM = AppPickerCatalog.mentionState(input: "帮我用 @m", mentionReady: true, adding: false, language: .simplifiedChinese, dynamicApps: [])
        XCTAssertNotNil(atM)
        XCTAssertEqual(atM?.triggerLength, 2)
        XCTAssertEqual(atM?.query, "m")
        XCTAssertGreaterThanOrEqual(atM?.matches.count ?? 0, 5)
        XCTAssertTrue(atM?.matches.contains { $0.id == "com.meituan.itakeaway" } ?? false)
        XCTAssertTrue(atM?.matches.contains { $0.id == "com.apple.MobileSMS" } ?? false)

        // Explicit `@m` right after Chinese text without space still triggers, while email does not.
        let inlineChinese = AppPickerCatalog.mentionState(input: "帮我用@m", mentionReady: true, adding: false, language: .simplifiedChinese, dynamicApps: [])
        XCTAssertEqual(inlineChinese?.triggerLength, 2)
        XCTAssertEqual(inlineChinese?.query, "m")
        XCTAssertNil(AppPickerCatalog.mentionState(input: "user@m", mentionReady: true, adding: false, language: .simplifiedChinese, dynamicApps: []))

        // Explicit `@xyz` keeps compact empty state instead of disappearing.
        let emptyAt = AppPickerCatalog.mentionState(input: "帮我用 @xyz", mentionReady: true, adding: false, language: .simplifiedChinese, dynamicApps: [])
        XCTAssertNotNil(emptyAt)
        XCTAssertEqual(emptyAt?.isEmptyResult, true)
        XCTAssertEqual(emptyAt?.triggerLength, 4)
        XCTAssertEqual(emptyAt?.query, "xyz")
        XCTAssertTrue(emptyAt?.matches.isEmpty ?? false)

        // Implicit prefix requires >= 3 characters, hides when exact match or no match.
        XCTAssertNil(AppPickerCatalog.mentionState(input: "me", mentionReady: true, adding: false, language: .simplifiedChinese, dynamicApps: []))
        let implicitMei = AppPickerCatalog.mentionState(input: "打开 mei", mentionReady: true, adding: false, language: .simplifiedChinese, dynamicApps: [])
        XCTAssertEqual(implicitMei?.isExplicit, false)
        XCTAssertEqual(implicitMei?.triggerLength, 3)
        XCTAssertTrue(implicitMei?.matches.contains { $0.id == "com.meituan.itakeaway" } ?? false)
        XCTAssertNil(AppPickerCatalog.mentionState(input: "xyz", mentionReady: true, adding: false, language: .simplifiedChinese, dynamicApps: []))
    }

    func testMentionPickerHeightFitsMatchesAndCapsLongLists() throws {
        for (input, expectedHeight) in [("帮我看看 123", 86.0), ("帮我用 @m", 252.0)] {
            let state = try XCTUnwrap(AppPickerCatalog.mentionState(
                input: input, mentionReady: true, adding: false, recentIDs: [],
                language: .simplifiedChinese, dynamicApps: []
            ))
            let picker = MentionPicker(state: state, composerWidth: 390, caretX: nil, pick: { _ in }, browseAll: {})
            let size = UIHostingController(rootView: picker).sizeThatFits(in: CGSize(width: 390, height: 400))
            XCTAssertEqual(size.height, expectedHeight, accuracy: 1, input)
        }
    }

    func testPrefixHighlightAndBackfillInsertion() throws {
        let enRange = try XCTUnwrap(AppPickerCatalog.highlightRange(in: "Meituan Waimai", query: "m"))
        XCTAssertEqual(String("Meituan Waimai"[enRange]), "M")

        let aliasRange = try XCTUnwrap(AppPickerCatalog.highlightRange(in: "DiDi / 滴滴", query: "滴"))
        XCTAssertEqual(String("DiDi / 滴滴"[aliasRange]), "滴")

        XCTAssertNil(AppPickerCatalog.highlightRange(in: "WeChat", query: "xyz"))

        let meituan = try XCTUnwrap(AppPickerCatalog.allEntries(language: .simplifiedChinese, dynamicApps: []).first { $0.id == "com.meituan.itakeaway" })
        let replaced = AppPickerCatalog.insertApp(meituan, into: "帮我用 @m", replacing: 2)
        XCTAssertEqual(replaced.text, "帮我用 美团外卖 ")
        XCTAssertEqual(replaced.cursorUTF16, replaced.text.utf16.count)

        let replacedInline = AppPickerCatalog.insertApp(meituan, into: "帮我用@xyz", replacing: 4)
        XCTAssertEqual(replacedInline.text, "帮我用 美团外卖 ")

        let middle = AppPickerCatalog.insertApp(meituan, into: "打开点奶茶", cursorUTF16: 2, replacing: 0)
        XCTAssertEqual(middle.text, "打开 美团外卖 点奶茶")
        XCTAssertEqual(middle.cursorUTF16, "打开 美团外卖 ".utf16.count)
    }

    func testWidescreenMentionClampingWithinComposerBounds() {
        let width = MentionPickerLayout.width(for: 640)
        XCTAssertEqual(width, 340)
        XCTAssertEqual(MentionPickerLayout.horizontalOffset(caretX: 10, pickerWidth: 340, composerWidth: 640), 0)
        XCTAssertEqual(MentionPickerLayout.horizontalOffset(caretX: 200, pickerWidth: 340, composerWidth: 640), 176)
        XCTAssertEqual(MentionPickerLayout.horizontalOffset(caretX: 620, pickerWidth: 340, composerWidth: 640), 300)
        XCTAssertEqual(MentionPickerLayout.horizontalOffset(caretX: 120, pickerWidth: 340, composerWidth: 320), 0)
    }
}
