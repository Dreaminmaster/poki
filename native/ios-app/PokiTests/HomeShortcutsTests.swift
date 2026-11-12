import XCTest
@testable import Poki

/// The home page's quick actions from a made-up history: the owner's routines, then the requests made
/// at least twice, most used first, then the default examples; private requests never on a pill.
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
    private let routine = HomeShortcuts.Remembered(text: "Order oat milk again", app: nil, runs: 4, at: Date(timeIntervalSince1970: 1_799_950_000))

    private func texts(routines: [HomeShortcuts.Remembered] = [], requests: [HomeShortcuts.Request] = [], forgotten: Set<String> = []) -> [String] {
        HomeShortcuts.rank(routines: routines, requests: requests, examples: HomeIdea.examples, forgotten: forgotten, now: now).map(\.text)
    }

    func testANewOwnerSeesTheExamples() {
        XCTAssertEqual(texts(), ["Tell the team I’m late", "Text Mom I’m on my way", "Book a ride home",
                                 "Order my usual coffee", "Add milk to my list", "Post today’s photo"])
    }

    func testRoutinesThenRepeatedRequestsThenExamples() {
        XCTAssertEqual(texts(routines: [routine], requests: history),
                       ["Order oat milk again", "帮我打开设置看看电池", "查一下今天的天气",
                        "Tell the team I’m late", "Text Mom I’m on my way", "Book a ride home"])
    }

    func testTheOrderFollowsUse() {
        let recent = history + [.init(text: "查一下后天的天气", at: ago(0.2)), .init(text: "查一下天气", at: ago(0.1))]
        XCTAssertEqual(Array(texts(requests: recent).prefix(2)), ["查一下天气", "帮我打开设置看看电池"])
    }

    func testAForgottenShortcutStaysAway() {
        let key = HomeShortcuts.normalize("打开设置看看电池")
        XCTAssertEqual(Array(texts(requests: history, forgotten: [key]).prefix(2)), ["查一下今天的天气", "Tell the team I’m late"])
        let example = HomeShortcuts.normalize("Tell the team I’m late")
        XCTAssertFalse(texts(forgotten: [example]).contains("Tell the team I’m late"))
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
