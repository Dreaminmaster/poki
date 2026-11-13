import XCTest
@testable import Poki

/// The home page's quick actions from a made-up history: the owner's routines, then the requests made
/// at least twice, most used first, then the default examples; private requests never on a pill, and
/// every pill an app and an action.
@MainActor
final class HomeShortcutsTests: XCTestCase {
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

    private func pills(routines: [HomeShortcuts.Remembered] = [], requests: [HomeShortcuts.Request] = [], forgotten: Set<String> = []) -> [HomeShortcut] {
        HomeShortcuts.rank(routines: routines, requests: requests, examples: HomeIdea.examples, forgotten: forgotten, now: now)
    }
    private func texts(routines: [HomeShortcuts.Remembered] = [], requests: [HomeShortcuts.Request] = [], forgotten: Set<String> = []) -> [String] {
        pills(routines: routines, requests: requests, forgotten: forgotten).map(\.text)
    }

    func testANewOwnerSeesTheExamples() {
        XCTAssertEqual(texts(), ["Tell the team I’m late", "Text Mom I’m on my way", "Book a ride home",
                                 "Order my usual coffee", "Add milk to my list", "Post today’s photo"])
    }

    func testRoutinesThenRepeatedRequestsThenExamples() {
        XCTAssertEqual(texts(routines: [routine], requests: history),
                       ["Order oat milk again", "看看电池", "Tell the team I’m late", "Text Mom I’m on my way",
                        "Book a ride home", "Order my usual coffee"])
    }

    func testTheOrderFollowsUse() {
        let recent = history + [.init(text: "打开天气看看明天", at: ago(0.3)), .init(text: "打开天气看看后天", at: ago(0.2)),
                                .init(text: "打开天气，看看后天", at: ago(0.1))]
        XCTAssertEqual(Array(texts(requests: recent).prefix(2)), ["看看后天", "看看电池"])
    }

    func testAForgottenShortcutStaysAway() {
        let key = HomeShortcuts.normalize("打开设置看看电池")
        XCTAssertEqual(Array(texts(requests: history, forgotten: [key]).prefix(2)), ["Tell the team I’m late", "Text Mom I’m on my way"])
        let example = HomeShortcuts.normalize("Tell the team I’m late")
        XCTAssertFalse(texts(forgotten: [example]).contains("Tell the team I’m late"))
    }

    /// The owner: every pill is an app and what to do in it. Old code showed "查一下今天的天气" and a
    /// routine with no app as bare words.
    func testEveryPillIsAnAppAndAnAction() {
        let plain = HomeShortcuts.Remembered(text: "Order oat milk", app: nil, runs: 9, at: now)
        let shown = pills(routines: [routine, plain], requests: history)
        XCTAssertFalse(shown.contains { $0.text.contains("天气") || $0.text == "Order oat milk" }, "\(shown.map(\.text))")
        for pill in shown {
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

    func testPrivateRequestsNeverBecomePills() {
        let shown = texts(requests: history)
        for word in ["妈妈", "转账", "验证码", "密码"] {
            XCTAssertFalse(shown.contains { $0.contains(word) }, "\(word) in \(shown)")
        }
        XCTAssertTrue(HomeShortcuts.isPrivate("Pay $12 for parking"))
        XCTAssertTrue(HomeShortcuts.isPrivate("Text Sam “running late”"))
    }
}
