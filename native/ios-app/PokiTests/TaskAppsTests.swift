import XCTest
@testable import Poki

/// The app a task was for, in the shapes of three tasks whose rows showed the wrong icon: the app PokiCore
/// last saw in front was kept, and that reading could be an app the phone had been in before.
@MainActor
final class TaskAppsTests: XCTestCase {
    private let meituan = "com.meituan.itakeaway", notes = "com.apple.mobilenotes", settings = "com.apple.Preferences"

    private func task(launching launched: [String] = [], steps: [String?]) -> TaskApps {
        var apps = TaskApps()
        for bundle in launched { apps.launch(bundle) }
        for app in steps { apps.step(in: app) }
        return apps
    }

    /// "打开美团外卖点下酒菜" showed Photos: the reads after the launch kept naming Photos.
    func testTheAppTheTaskOpenedWinsOverAStaleFrontApp() {
        let launches = TaskApps.launches(inArguments: #"{"actions":[{"launch":"com.meituan.itakeaway"},{"wait":1}]}"#)
        XCTAssertEqual(launches, [meituan])
        let apps = task(launching: launches, steps: ["美团外卖", "照片", "照片", "照片"])
        XCTAssertEqual(apps.target(request: "打开美团外卖点下酒菜"), meituan)
    }

    /// "新建日期备忘录" showed WeChat: Notes was already open, and the last read named WeChat.
    func testWithoutALaunchTheAppMostActionsRanInWins() {
        let apps = task(steps: ["备忘录", "备忘录", "备忘录", "Home screen (SpringBoard: the home screen, the App Switcher, a banner or a system alert)", "微信"])
        XCTAssertEqual(apps.target(request: "新建一条备忘录，写上今天的日期"), notes)
    }

    /// "移动网络测试" showed WeChat: Settings was opened by its launch, the end read named WeChat.
    func testTheLaunchedAppWinsOverTheAppTheTaskEndedIn() {
        let launches = TaskApps.launches(inArguments: #"{"actions":[{"launch":{"bundle":"com.apple.Preferences","fresh":true}}]}"#)
        let apps = task(launching: launches, steps: ["设置", "设置", "微信"])
        XCTAssertEqual(apps.target(request: "测一下移动网络"), settings)
    }

    func testBetweenTwoOpenedAppsTheOneTheRequestNamesWins() {
        let apps = task(launching: ["com.apple.mobileslideshow", meituan], steps: ["照片", "照片", "照片", "美团外卖"])
        XCTAssertEqual(apps.target(request: "在美团外卖点下酒菜，菜名在照片里"), meituan, "both named: the last opened of them")
        XCTAssertEqual(apps.target(request: "Order bar snacks on Meituan Waimai"), meituan)
        XCTAssertEqual(task(launching: ["com.apple.mobileslideshow", meituan], steps: ["照片", "照片", "美团外卖"]).target(request: "点下酒菜"),
                       "com.apple.mobileslideshow", "none named: the most actions")
    }

    func testPokiAndTheHomeScreenAreNoApp() {
        let apps = task(launching: [Bundle.main.bundleIdentifier ?? "Poki"], steps: ["Poki", "Home screen (SpringBoard: the home screen)", "unknown", nil])
        XCTAssertNil(apps.target(request: "打开微信"), "nothing it worked in: no icon rather than the app it names")
    }

    /// An outside agent's own steps: the conversation row shows the app most of them ran in, not the last.
    func testAnAgentSessionShowsTheAppMostOfItsStepsRanIn() {
        func step(_ app: String?) -> ChatEntry { var entry = ChatEntry(.step("Tap", ok: true)); entry.app = app; return entry }
        let session = SavedSession(id: "agent", kind: .agent, client: "Codex", title: "Codex", started: Date(), updated: Date(), live: false, outcome: .done,
                                   entries: [step("备忘录"), step("备忘录"), step("备忘录"), step("微信")], calls: [])
        XCTAssertEqual(session.app, notes)
    }
}
