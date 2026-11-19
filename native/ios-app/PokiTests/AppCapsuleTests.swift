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
        for (preference, language) in [("zh-Hans", AppLanguage.simplifiedChinese), ("en", .english), ("zh-Hant", .traditionalChinese)] {
            let saved = AppLocalization.shared.preference
            AppLocalization.shared.preference = preference
            defer { AppLocalization.shared.preference = saved }
            for pill in HomeIdea.examples(for: language) {
                XCTAssertEqual(apps(pill.prompt), [pill.app], "\(language) \(pill.prompt)")
                XCTAssertEqual(joined(pill.prompt), pill.prompt)
            }
        }
    }

    func testWeChatMiniProgramNameStaysTextInComposerAndRouting() {
        let weChat = "com.tencent.xin"
        let diDi = "com.xiaojukeji.didi"
        XCTAssertEqual(AppIconStore.bundleIDs(namedIn: "打开查找"), ["com.apple.findmy"])
        for request in [
            "帮我在微信滴滴充电小程序里查找我附近最便宜的充电桩",
            "在微信裡的「滴滴充電」小程式找充電樁",
        ] {
            XCTAssertEqual(apps(request), [weChat], request)
            XCTAssertEqual(AppIconStore.bundleIDs(namedIn: request), [weChat], request)
            XCTAssertEqual(joined(request), request)
        }

        for request in [
            "微信滴滴充电小程序里查价格，再打开滴滴出行",
            "打开微信然后打开滴滴出行查小程序订单",
            "打开微信和滴滴出行",
            "打开微信和滴滴出行看小程序订单",
        ] {
            XCTAssertEqual(apps(request), [weChat, diDi], request)
            XCTAssertEqual(AppIconStore.bundleIDs(namedIn: request), [weChat, diDi], request)
            XCTAssertEqual(joined(request), request)
        }
    }

    func testNetEaseCloudMusicRecognizesCommonChineseShortNames() {
        let music = "com.netease.cloudmusic"
        for name in ["网易云", "網易雲", "网易云音乐", "網易雲音樂"] {
            let request = "打开\(name)播放我的歌单"
            XCTAssertEqual(AppIconStore.bundleID(name), music, name)
            XCTAssertEqual(AppIconStore.bundleIDs(namedIn: request), [music], request)
            XCTAssertEqual(apps(request), [music], request)
            XCTAssertEqual(joined(request), request)
            let capsuleLabels = CapsuleText.segments(request).compactMap { segment -> String? in
                if case .app(_, let words) = segment { return words }
                return nil
            }
            XCTAssertEqual(capsuleLabels, [name], request)
        }
    }

    func testNetEaseCloudMusicShortNamesDoNotMatchOtherNetEaseProducts() {
        let music = "com.netease.cloudmusic"
        let aliases = ["网易云", "網易雲"]
        let productSuffixes = ["课堂", "課堂", "信", "游戏", "遊戲", "阅读", "閱讀"]

        for alias in aliases {
            for product in productSuffixes {
                let request = "打开\(alias)\(product)看内容"
                XCTAssertFalse(apps(request).contains(music), request)
                XCTAssertFalse(AppIconStore.bundleIDs(namedIn: request).contains(music), request)
                XCTAssertEqual(joined(request), request)
            }
        }

        let reportedRequest = "打开网易云课堂看课"
        XCTAssertFalse(apps(reportedRequest).contains(music), reportedRequest)
        XCTAssertFalse(AppIconStore.bundleIDs(namedIn: reportedRequest).contains(music), reportedRequest)
        XCTAssertEqual(joined(reportedRequest), reportedRequest)

        let separatedRequest = "打开网易云，查看课堂资料"
        XCTAssertEqual(apps(separatedRequest), [music], separatedRequest)
        XCTAssertEqual(AppIconStore.bundleIDs(namedIn: separatedRequest), [music], separatedRequest)
        XCTAssertEqual(joined(separatedRequest), separatedRequest)
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
