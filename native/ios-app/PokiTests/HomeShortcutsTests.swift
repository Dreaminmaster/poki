import XCTest
@testable import Poki

/// The home page's quick actions from a made-up history: the owner's routines, then the requests made
/// at least twice, most used first, then the default examples; private requests never on a pill, and
/// every pill an app and an action.
@MainActor
final class HomeShortcutsTests: XCTestCase {
    private var language = AppLocalization.system

    override func setUp() async throws {
        language = AppLocalization.shared.preference
        AppLocalization.shared.preference = "en"
    }

    override func tearDown() async throws { AppLocalization.shared.preference = language }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func ago(_ hours: Double) -> Date { now.addingTimeInterval(-hours * 3600) }

    private var history: [HomeShortcuts.Request] {
        [.init(text: "打开设置看看电池", at: ago(72)),
         .init(text: "打开设置，看看电池。", at: ago(48)),
         .init(text: "帮我打开设置看看电池", at: ago(0.5)),
         .init(text: "查一下明天的天气", at: ago(240)),
         .init(text: "查一下今天的天气", at: ago(216)),
         .init(text: "打开相机", at: ago(1)),
         .init(text: "给妈妈发消息说我到了", at: ago(2)), .init(text: "给妈妈发消息说我到了", at: ago(3)),
         .init(text: "转账 200 元给小王", at: ago(4)), .init(text: "转账 300 元给小王", at: ago(5)),
         .init(text: "验证码是 482913", at: ago(6)), .init(text: "验证码是 551200", at: ago(7)),
         .init(text: "我的 Apple 密码是什么", at: ago(8)), .init(text: "我的 Apple 密码是什么", at: ago(9))]
    }
    private let routine = HomeShortcuts.Remembered(text: "Order oat milk again", app: "com.starbucks.mystarbucks", runs: 4, at: Date(timeIntervalSince1970: 1_799_950_000))

    private func pills(routines: [HomeShortcuts.Remembered] = [], requests: [HomeShortcuts.Request] = [], forgotten: Set<String> = [],
                       edits: [HomeShortcuts.Edit] = []) -> [HomeShortcut] {
        HomeShortcuts.rank(routines: routines, requests: requests, examples: HomeIdea.examples, pinned: [HomeIdea.star],
                           forgotten: forgotten, edits: edits, now: now)
    }
    private func texts(routines: [HomeShortcuts.Remembered] = [], requests: [HomeShortcuts.Request] = [], forgotten: Set<String> = []) -> [String] {
        pills(routines: routines, requests: requests, forgotten: forgotten).map(\.text)
    }

    func testANewOwnerSeesTheExamples() {
        XCTAssertEqual(texts(), ["Tell the team I’m late", "Star Poki", "Text Mom I’m on my way", "Book a ride home",
                                 "Order my usual coffee", "Add milk to my list", "Post today’s photo"])
    }

    func testRoutinesThenRepeatedRequestsThenExamples() {
        XCTAssertEqual(texts(routines: [routine], requests: history),
                       ["Order oat milk again", "Star Poki", "看看电池", "Tell the team I’m late", "Text Mom I’m on my way",
                        "Book a ride home", "Order my usual coffee"])
    }

    /// The owner (2026-11-14): starring Poki is on the home page from the first open, second (the top
    /// row opens with its first pill half off the screen), also for an owner whose own pills fill the
    /// rows, and it pushes none of theirs off. A tap fills the field with the task for Poki's browser.
    /// Forgotten, it is gone and its place goes back to the owner's. Old code had no such pill.
    func testStarringPokiComesSecondAndPushesNothingOff() {
        let own = ["打开相机拍一张照片", "打开备忘录记一条待办", "打开淘宝看看购物车", "打开京东看看购物车", "打开闲鱼看看我的闲置",
                   "打开美团外卖点一份午饭", "打开小红书搜一下露营", "打开百度地图导航去公司"]
        let busy = own.enumerated().flatMap { n, text in [HomeShortcuts.Request(text: text, at: ago(Double(n + 1))),
                                                           HomeShortcuts.Request(text: text, at: ago(Double(n + 1) + 0.5))] }
        let shown = pills(routines: [routine], requests: busy + history)
        XCTAssertEqual(shown.map(\.text), ["Order oat milk again", "Star Poki", "看看电池", "拍一张照片", "记一条待办",
                                            "看看购物车", "看看购物车"])
        XCTAssertEqual(shown[1].prompt, "Open https://github.com/JosssphZhou/poki in the built-in browser and star it. If I am not signed in to GitHub, open https://github.com/login?return_to=/JosssphZhou/poki and hand that page to me")
        XCTAssertEqual(shown[1].appName, "GitHub", "a name in bold before the action, as on every pill")
        XCTAssertNotNil(shown[1].icon.flatMap(AppIconStore.carried), "GitHub's mark, carried in the app")

        XCTAssertEqual(texts(forgotten: [HomeIdea.star.key]), ["Tell the team I’m late", "Text Mom I’m on my way", "Book a ride home",
                                                               "Order my usual coffee", "Add milk to my list", "Post today’s photo"])
    }

    func testTheOrderFollowsUse() {
        let recent = history + [.init(text: "打开天气看看明天", at: ago(0.3)), .init(text: "打开天气看看后天", at: ago(0.2)),
                                .init(text: "打开天气，看看后天", at: ago(0.1))]
        XCTAssertEqual(Array(texts(requests: recent).prefix(3)), ["看看后天", "Star Poki", "看看电池"])
    }

    func testAForgottenShortcutStaysAway() {
        let key = HomeShortcuts.normalize("打开设置看看电池")
        XCTAssertEqual(Array(texts(requests: history, forgotten: [key]).prefix(3)),
                       ["Tell the team I’m late", "Star Poki", "Text Mom I’m on my way"])
        let example = HomeShortcuts.normalize("Tell the team I’m late")
        XCTAssertFalse(texts(forgotten: [example]).contains("Tell the team I’m late"))
    }

    /// The owner: every pill is an app and what to do in it. Old code showed "查一下今天的天气" and a
    /// routine with no app as bare words.
    func testEveryPillIsAnAppAndAnAction() {
        let plain = HomeShortcuts.Remembered(text: "Order oat milk", app: nil, runs: 9, at: now)
        let shown = pills(routines: [routine, plain], requests: history)
        XCTAssertFalse(shown.contains { $0.text.contains("天气") || $0.text == "Order oat milk" }, "\(shown.map(\.text))")
        for pill in shown where pill != HomeIdea.star {
            XCTAssertFalse(pill.app.isEmpty || pill.appName.isEmpty || pill.text.isEmpty, "\(pill)")
            XCTAssertNotNil(AppIconStore.bundleID(pill.app), pill.app)
        }
        XCTAssertEqual(shown.first { $0.text == "看看电池" }?.app, "com.apple.Preferences")
        XCTAssertEqual(shown.first?.app, "com.starbucks.mystarbucks")
    }

    /// The owner: every default pill shows its app's icon, also for an app this iPhone does not have
    /// and before the App Store answers. On 0.3.1 (865) Taobao's was blank: the build's generated asset
    /// catalog was older than the Chinese pills' icons.
    func testEveryDefaultPillHasAnIconOnThePhone() {
        for (language, count) in [(AppLanguage.simplifiedChinese, 10), (.english, 6)] {
            let shown = HomeIdea.examples(for: language)
            XCTAssertEqual(shown.count, count, "\(language)")
            for pill in shown { XCTAssertNotNil(AppIconStore.shared.icon(pill.app), "\(language) \(pill.appName)") }
        }
    }

    func testAnAppIsFoundAtTheStartOfARequest() {
        XCTAssertEqual(ShortcutApp.leading("Open Notes, add milk to my list")?.action, "add milk to my list")
        XCTAssertEqual(ShortcutApp.leading("Open Notes, add milk to my list")?.id, "com.apple.mobilenotes")
        XCTAssertEqual(ShortcutApp.leading("帮我在备忘录里记一条待办")?.action, "记一条待办")
        XCTAssertNil(ShortcutApp.leading("notes about the trip"), "notes in lower case is a word")
        XCTAssertNil(ShortcutApp.leading("Book a ride home"))
        XCTAssertNil(ShortcutApp.leading("打开设置"), "an app and nothing to do")
    }

    /// The owner (2026-11-13): an edited pill's icon must show. Edited in place, it keeps its app's icon,
    /// and with no app this iPhone knows it stays on the page, as Poki's icon and the words; both come
    /// back after a restart. Old code had no edit, and dropped any pill without a known app.
    func testAnEditedShortcutKeepsItsIconAndOutlivesARestart() {
        let defaults = UserDefaults.standard
        let keys = ["home.shortcuts.edited", "home.shortcuts.forgotten"]
        let before = keys.map { defaults.object(forKey: $0) }
        for key in keys { defaults.removeObject(forKey: key) }
        defer { for (key, value) in zip(keys, before) { defaults.set(value, forKey: key) } }

        let store = HomeShortcutStore()
        // The second is starring Poki, which has GitHub's mark and no app.
        let (first, second) = (store.shortcuts[0], store.shortcuts[2])
        store.edit(first, sentence: first.prompt + " please", app: first.app)
        store.edit(second, sentence: "Water the plants", app: nil)

        for shown in [store.shortcuts, HomeShortcutStore().shortcuts] {
            XCTAssertEqual(shown[0].prompt, first.prompt + " please")
            XCTAssertEqual(shown[0].app, first.app)
            XCTAssertNotNil(AppIconStore.shared.icon(shown[0].app), "\(shown[0])")
            XCTAssertEqual(shown[2].prompt, "Water the plants")
            XCTAssertEqual(shown[2].text, "Water the plants")
            XCTAssertEqual(shown[2].app, "", "no app: AppIconView draws Poki's icon")
        }
    }

    /// An edit holds its place while the history changes, and stays when the pill it replaced is gone.
    func testAnEditOutlivesThePillItReplaced() {
        let edit = HomeShortcuts.Edit(replaces: HomeShortcuts.normalize("打开设置看看电池"), sentence: "打开备忘录记一条待办", app: "com.apple.mobilenotes")
        let withIt = pills(requests: history, edits: [edit])
        XCTAssertEqual(withIt.first?.text, "记一条待办")
        XCTAssertEqual(withIt.first?.app, "com.apple.mobilenotes")

        let without = pills(edits: [edit])
        XCTAssertEqual(without.count, 7)
        XCTAssertEqual(without.last?.prompt, "打开备忘录记一条待办")

        // Sent twice since, its sentence is a repeated request of its own: still one pill.
        let used = history + [.init(text: "打开备忘录记一条待办", at: ago(0.2)), .init(text: "打开备忘录记一条待办", at: ago(0.1))]
        XCTAssertEqual(pills(requests: used, edits: [edit]).filter { $0.text == "记一条待办" }.count, 1)
    }

    /// The Edit page: a sentence that begins with another app takes that app's icon; one that loses the
    /// app it began with has none; a routine's words that never named its app keep it. Picking another
    /// app puts its name in the sentence, so the pill never shows one app's icon over another's name.
    func testAnEditedSentenceTakesItsAppAlong() {
        let settings = "com.apple.Preferences"
        let picked = ShortcutApp.sentence("Slack Tell the team I’m late", for: "com.apple.mobilenotes")
        XCTAssertEqual(picked, "Notes Tell the team I’m late")
        let pill = HomeShortcuts.pill(.init(replaces: "x", sentence: picked, app: "com.apple.mobilenotes"))
        XCTAssertEqual(pill.text, "Tell the team I’m late")
        XCTAssertEqual(ShortcutApp.sentence("Slack Tell the team I’m late", for: nil), "Tell the team I’m late")
        XCTAssertEqual(ShortcutApp.following("打开淘宝看看物流", was: "打开设置看看电池", app: settings), "com.taobao.taobao4iphone")
        XCTAssertNil(ShortcutApp.following("看看电池", was: "打开设置看看电池", app: settings))
        XCTAssertEqual(ShortcutApp.following("Order oat milk twice", was: "Order oat milk again", app: "com.starbucks.mystarbucks"),
                       "com.starbucks.mystarbucks")
    }

    func testPrivateRequestsNeverBecomePills() {
        let shown = texts(requests: history)
        for word in ["妈妈", "转账", "验证码", "密码"] {
            XCTAssertFalse(shown.contains { $0.contains(word) }, "\(word) in \(shown)")
        }
        XCTAssertTrue(HomeShortcuts.isPrivate("Pay $12 for parking"))
        XCTAssertTrue(HomeShortcuts.isPrivate("Text Sam “running late”"))
    }
}
