import UIKit
import XCTest
@testable import Poki

/// The owner: the apps named in the message field show as capsules, its icon and its name. A home
/// pill puts its app in the field as a capsule, a known app's name typed in becomes one, one backspace
/// removes it, and the words sent to the model stay exactly as written.
@MainActor
final class AppCapsuleTests: XCTestCase {
    private func apps(_ plain: String) -> [String] {
        CapsuleText.segments(plain).compactMap { if case .app(let app, _) = $0 { app.id } else { nil } }
    }

    private func joined(_ plain: String) -> String {
        CapsuleText.segments(plain).map { segment in
            switch segment {
            case .text(let words), .app(_, let words): words
            }
        }.joined()
    }

    /// Old code knew seven apps: of the Chinese pills only WeChat's prompt had a capsule.
    func testEveryHomePillPutsItsAppInTheFieldAsACapsule() {
        for language in [AppLanguage.simplifiedChinese, .english] {
            for pill in HomeIdea.examples(for: language) {
                XCTAssertEqual(apps(pill.prompt), [pill.app], "\(language) \(pill.prompt)")
                XCTAssertEqual(joined(pill.prompt), pill.prompt)
            }
        }
    }

    func testTypedNamesBecomeCapsulesWhereTheyNameAnApp() {
        XCTAssertEqual(apps("帮我在拼多多和京东比一下价格"), ["com.xunmeng.pinduoduo", "com.360buy.jdmobile"])
        XCTAssertEqual(apps("打开百度地图导航回家"), ["com.baidu.map"], "the longest name wins")
        XCTAssertEqual(apps("用 uber 叫车回家"), ["com.ubercab.UberClient"])
        XCTAssertEqual(apps("Open Gmail and find the receipt"), ["com.google.Gmail"])
        XCTAssertEqual(apps("打开设置看看电池"), ["com.apple.Preferences"])
        XCTAssertEqual(apps("信息里找一下验证码"), ["com.apple.MobileSMS"])
        // Everyday words, not the apps.
        XCTAssertEqual(apps("给妈妈打电话"), [])
        XCTAssertEqual(apps("帮我发信息给小王"), [])
        XCTAssertEqual(apps("notes about the trip"), [])
        XCTAssertEqual(apps("fix the box"), [])
        XCTAssertEqual(apps("Buy a red dress and find a podcast"), [])
        XCTAssertEqual(apps("打开QQ 音乐放首歌"), ["com.tencent.QQMusic"])
        XCTAssertEqual(apps("Post on X"), ["com.atebits.Tweetie2"])
    }

    func testOneBackspaceRemovesTheWholeCapsule() {
        let field = CapsuleTextView(frame: CGRect(x: 0, y: 0, width: 320, height: 44), textContainer: nil)
        field.font = CapsuleTextView.bodyFont
        field.setPlain("打开淘宝")
        XCTAssertEqual(field.textStorage.length, 3, "打开 and one capsule")
        field.deleteBackward()
        XCTAssertEqual(field.plainText, "打开")
    }
}
