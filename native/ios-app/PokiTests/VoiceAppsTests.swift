import XCTest
import PokiCore
@testable import Poki

/// open_app, the live voice's way into an app (the owner, 2026-11-18: "open WeChat" went to the Home
/// Screen's search instead of straight to the app).
@MainActor
final class VoiceAppsTests: XCTestCase {
    func testVoiceOpenAppResumesTheOriginalRunnerRequestAfterAuthorization() async throws {
        try XCTSkipUnless(AutomationPath.current == .runner, "Launch the test host with -automationPath runner")
        let setup = SetupState.load()
        defer { setup.save() }
        let model = AppModel(launcher: FakeLauncher(), pairer: FakePairing(), automation: FakeAutomation())
        model.loopback.simulate(.working(ms: 9))
        model.runnerChanged(RunnerStatus(state: "launching", detail: "Waiting for the owner", code: "passcode"))
        let transport = VoiceScreenTransport()
        let core = PokiCore(config: CoreConfig(busyWait: 0.1, runnerWait: 0, humanize: false),
                            host: model.host, transport: transport)

        let started = expectation(description: "The original voice tool started")
        let observer = Task {
            for await event in core.events {
                if case .toolStarted(let activity) = event, activity.name == "do" {
                    started.fulfill()
                    break
                }
            }
        }
        defer { observer.cancel() }
        let original = Task {
            await VoiceApps.open(#"{"app":"Settings"}"#, tool: { name, arguments in
                let result = await core.tool(name, arguments: arguments)
                return (result.text, result.isError, result.jpeg)
            }, openLink: { _ in false })
        }
        defer { original.cancel() }
        await fulfillment(of: [started], timeout: 5)
        let whileWaiting = await core.tool("look", arguments: "{}")
        XCTAssertTrue(whileWaiting.text.contains("Poki is waiting for automation to be ready"), whileWaiting.text)
        let beforeAuthorization = await transport.launches
        XCTAssertEqual(beforeAuthorization, 0, "The original action must not be sent before authorization")

        model.runnerChanged(RunnerStatus(state: "running"))
        let answer = await original.value
        XCTAssertFalse(answer.failed, answer.text)
        XCTAssertTrue(answer.text.contains("Settings") && answer.text.contains("General"), answer.text)
        XCTAssertNotNil(answer.screen)
        let afterAuthorization = await transport.launches
        XCTAssertEqual(afterAuthorization, 1, "The original request must open the app exactly once")
    }

    func testFirstVoiceTapUsesTheReferencesReturnedByTheSettingsLink() async throws {
        let host = AppCoreHost()
        host.update(runner: .automationReady(revision: 1))
        let transport = VoiceScreenTransport()
        let core = PokiCore(config: CoreConfig(humanize: false), host: host, transport: transport)
        let answer = await VoiceApps.open(#"{"app":"Settings","page":"general"}"#, tool: { name, arguments in
            let result = await core.tool(name, arguments: arguments)
            return (result.text, result.isError, result.jpeg)
        }, openLink: { url in await transport.openLink(url) })
        XCTAssertFalse(answer.failed, answer.text)
        XCTAssertTrue(answer.text.contains("opened Settings by the link"), answer.text)
        XCTAssertNotNil(answer.screen)
        let row = try XCTUnwrap(answer.text.split(separator: "\n").first { $0.contains(#"Button "About""#) }, answer.text)
        let words = row.split(whereSeparator: \.isWhitespace)
        let reference = try XCTUnwrap(words.compactMap { Int($0) }.first, String(row))

        let tapped = await core.tool("do", arguments: #"{"actions":[{"tap":\#(reference)}]}"#)
        XCTAssertFalse(tapped.isError, tapped.text)
        XCTAssertTrue(tapped.text.contains("Model Name"), tapped.text)
        let tapCount = await transport.taps
        XCTAssertEqual(tapCount, 1)

        host.update(runner: .automationReady(revision: 2))
        let stale = await core.tool("do", arguments: #"{"actions":[{"tap":\#(reference)}]}"#)
        XCTAssertTrue(stale.isError, stale.text)
        XCTAssertTrue(stale.text.contains("Call look"), stale.text)
        let afterRestart = await transport.taps
        XCTAssertEqual(afterRestart, tapCount, "References from before the new automation session must not be sent")
    }

    /// What open_app sends to PokiCore for what the user said, and whether it answers a failure.
    func testOpenAppGoesStraightToTheAppTheUserNamed() async {
        let installed: Set<String> = ["com.tencent.xin", "com.bilibili.inter", "com.apple.Preferences"]
        let cases: [(arguments: String, linkOpens: Bool, sent: [String], failed: Bool)] = [
            (#"{"app":"微信"}"#, true, [#"{"actions":[{"launch":{"bundle":"com.tencent.xin"}}]}"#], false),
            (#"{"app":"WeChat"}"#, true, [#"{"actions":[{"launch":{"bundle":"com.tencent.xin"}}]}"#], false),
            // Bilibili's own edition is not installed here; its international one is.
            (#"{"app":"B站"}"#, true, [#"{"actions":[{"launch":{"bundle":"tv.danmaku.bilianime"}}]}"#, #"{"actions":[{"launch":{"bundle":"com.bilibili.inter"}}]}"#], false),
            (#"{"app":"设置","page":"bluetooth"}"#, true, [#"{"actions":[{"wait_until":{"settled":true,"ms":2500}}]}"#], false),
            // Poki in the background cannot open the link: Settings opens, and the model taps the page.
            (#"{"app":"设置","page":"bluetooth"}"#, false, [#"{"actions":[{"launch":{"bundle":"com.apple.Preferences"}}]}"#], false),
            // A name Poki does not know, and one that names two apps: nothing is sent.
            (#"{"app":"Zorblax"}"#, true, [], true),
            (#"{"app":"微信和支付宝"}"#, true, [], true),
            // An app this iPhone does not have: the launch is tried, and the answer says to search for it.
            (#"{"app":"美团"}"#, true, [#"{"actions":[{"launch":{"bundle":"com.meituan.imeituan"}}]}"#], true),
        ]
        for c in cases {
            var sent: [String] = []
            var links: [URL] = []
            let answer = await VoiceApps.open(c.arguments, tool: { name, arguments in
                sent.append(arguments)
                return arguments.contains("launch") && !installed.contains(where: { arguments.contains("\"\($0)\"") })
                    ? ("not_sent: launch: no app with that bundle id is installed on this device", true, nil)
                    : ("app: in front", false, Data([1]))
            }, openLink: { links.append($0); return c.linkOpens })
            XCTAssertEqual(sent, c.sent, c.arguments)
            XCTAssertEqual(answer.failed, c.failed, c.arguments)
            if c.arguments.contains("bluetooth") { XCTAssertEqual(links, [URL(string: "App-prefs:Bluetooth")!], c.arguments) }
        }
    }
}

private actor VoiceScreenTransport: HTTPTransport {
    private enum Page: String {
        case home = "Home Screen"
        case settings = "General"
        case general = "About"
        case about = "Model Name"
    }

    private var page = Page.home
    private(set) var launches = 0
    private(set) var taps = 0

    func openLink(_ url: URL) -> Bool {
        guard url.absoluteString == "App-prefs:General" else { return false }
        page = .general
        return true
    }

    func send(method: String, url: URL, body: Data?, timeout: Double) async throws -> (status: Int, body: Data) {
        let path = url.path.replacingOccurrences(of: #"^/session/[^/]+"#, with: "", options: .regularExpression)
        let value: JSON
        switch (method, path) {
        case ("POST", "/session"):
            value = ["sessionId": "voice-test"]
        case ("GET", "/status"):
            value = ["ready": true]
        case ("GET", "/wda/locked"):
            value = false
        case ("GET", "/wda/screen"):
            value = ["screenSize": ["width": 390, "height": 844]]
        case ("GET", "/wda/activeAppInfo"):
            value = page == .home ? ["bundleId": "com.apple.springboard", "name": "Home Screen"]
                                 : ["bundleId": "com.apple.Preferences", "name": "Settings"]
        case ("GET", "/screenshot"):
            value = "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAADklEQVR4nGP4DwYMEAoAU7oL9ZisIGcAAAAASUVORK5CYII="
        case ("GET", "/source"):
            let app = page == .home ? "Home Screen" : "Settings"
            let role = page == .about ? "StaticText" : "Button"
            value = .string(#"<AppiumAUT><XCUIElementTypeApplication name="\#(app)" label="\#(app)" x="0" y="0" width="390" height="844"><XCUIElementType\#(role) name="\#(page.rawValue)" label="\#(page.rawValue)" x="16" y="100" width="358" height="44" /></XCUIElementTypeApplication></AppiumAUT>"#)
        case ("POST", "/wda/apps/activate"), ("POST", "/wda/apps/launch"):
            launches += 1
            guard let body, try JSON.parse(String(decoding: body, as: UTF8.self))["bundleId"]?.string == "com.apple.Preferences" else {
                return (400, JSON.object(["value": ["error": "unexpected app"]]).data())
            }
            page = .settings
            value = .null
        case ("POST", "/wda/tap"):
            taps += 1
            guard page == .general, let body, let point = try? JSON.parse(String(decoding: body, as: UTF8.self)),
                  let x = point["x"]?.double, let y = point["y"]?.double,
                  (16...374).contains(x), (100...144).contains(y) else {
                return (400, JSON.object(["value": ["error": "unexpected tap"]]).data())
            }
            page = .about
            value = .null
        default:
            value = .null
        }
        let response: JSON = ["value": value]
        return (200, response.data())
    }
}
