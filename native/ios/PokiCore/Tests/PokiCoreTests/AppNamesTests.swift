import Foundation
import XCTest
@testable import PokiCore

/// Apps by name, the session's app, and the read that comes as soon as the screen has settled.
final class AppNamesTests: XCTestCase {
    static let names = ["clock": "com.apple.mobiletimer", "时钟": "com.apple.mobiletimer", "com.apple.mobiletimer": "com.apple.mobiletimer"]

    func core(names: Bool = true, quick: Bool = true) -> (PokiCore, FakeWDA) {
        let wda = FakeWDA()
        wda.tree([Node("Button", "General", [16, 100, 358, 44])], app: "Settings")
        let (core, _, _) = makeCore(wda) {
            $0.resolveApp = { Self.names[$0.lowercased()] }
            $0.appNames = { names }
            $0.quickRead = { quick }
        }
        return (core, wda)
    }

    func launched(_ wda: FakeWDA) -> [String] {
        (wda.bodies("POST /wda/apps/activate") + wda.bodies("POST /wda/apps/launch")).compactMap { $0["bundleId"]?.string }
    }

    func testALaunchTakesTheAppsName() async {
        let (core, wda) = core()
        _ = await core.call("look", [:])
        let result = await core.call("do", ["actions": [["launch": "Clock"]]])
        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(launched(wda), ["com.apple.mobiletimer"])
        XCTAssertTrue(result.text.contains("launch com.apple.mobiletimer"), result.text)

        _ = await core.call("do", ["actions": [["launch": ["name": "时钟"]]]])
        XCTAssertEqual(launched(wda), ["com.apple.mobiletimer", "com.apple.mobiletimer"])
    }

    func testANameNobodyKnowsSendsNothing() async {
        let (core, wda) = core()
        _ = await core.call("look", [:])
        let result = await core.call("do", ["actions": [["launch": "Nonesuch"]]])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("no app named \"Nonesuch\" is known"), result.text)
        XCTAssertEqual(launched(wda), [])
    }

    func testABundleIdStillLaunchesAsItIs() async {
        let (core, wda) = core()
        _ = await core.call("look", [:])
        _ = await core.call("do", ["actions": [["launch": "com.example.shop"]]])
        XCTAssertEqual(launched(wda), ["com.example.shop"])
    }

    func testWithNamesOffALaunchIsSentAsGiven() async {
        let (core, wda) = core(names: false)
        _ = await core.call("look", [:])
        _ = await core.call("do", ["actions": [["launch": "Clock"]]])
        XCTAssertEqual(launched(wda), ["Clock"])
    }

    func testAPathsLaunchStepTakesAName() async {
        let (core, wda) = core()
        _ = await core.call("look", [:])
        let result = await core.call("do", ["actions": [["path": ["steps": [["launch": "Clock"], ["tap": "General"]]]]]])
        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(launched(wda), ["com.apple.mobiletimer"])
    }

    func testTheSessionsAppIsNamedOnceAndKeptUntilLetGo() async {
        let (core, wda) = core()
        _ = await core.call("look", [:])
        // Named: brought to the front, since Settings is there.
        let first = await core.call("do", ["actions": [], "app": "Clock"])
        XCTAssertFalse(first.isError, first.text)
        XCTAssertEqual(launched(wda), ["com.apple.mobiletimer"])
        // Kept: the next call does not name it, and is told that another app is in front.
        let second = await core.call("do", ["actions": [["wait": 10]]])
        XCTAssertTrue(second.text.contains("the session's app Clock (com.apple.mobiletimer) is not in front"), second.text)
        XCTAssertEqual(launched(wda).count, 1)
        // Let go: no more is said.
        let third = await core.call("do", ["actions": [["wait": 10]], "app": false])
        XCTAssertFalse(third.text.contains("the session's app"), third.text)
        let fourth = await core.call("do", ["actions": [["wait": 10]]])
        XCTAssertFalse(fourth.text.contains("the session's app"), fourth.text)
    }

    func testAnAppNobodyKnowsIsRefusedBeforeAnythingIsSent() async {
        let (core, wda) = core()
        _ = await core.call("look", [:])
        let taps = wda.bodies("POST /wda/tap").count
        let result = await core.call("do", ["actions": [["tap": 1]], "app": "Nonesuch"])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("no app named \"Nonesuch\""), result.text)
        XCTAssertEqual(wda.bodies("POST /wda/tap").count, taps)
    }

    func testAScreenThatChangedAndHoldsStillIsReadBeforeThePauseIsOver() async {
        let (core, wda) = core()
        _ = await core.call("look", [:])
        wda.set("POST /wda/apps/activate") { [wda] _ in
            wda.tree([Node("Button", "World Clock", [16, 100, 358, 44]), Node("Button", "Alarms", [16, 144, 358, 44])], app: "Clock")
            return (200, ["value": .null])
        }
        let result = await core.call("do", ["actions": [["launch": "Clock"]]])
        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains("the screen had changed and held still"), result.text)
        XCTAssertFalse(result.text.contains("paused 900 ms"), result.text)
    }

    func testAScreenThatDidNotChangeGetsTheWholePause() async {
        let (core, _) = core()
        _ = await core.call("look", [:])
        let result = await core.call("do", ["actions": [["launch": "Clock"]]])
        XCTAssertTrue(result.text.contains("paused 9"), result.text)
    }

    func testWithTheQuickReadOffThePauseIsTheFixedOne() async {
        let (core, wda) = core(quick: false)
        _ = await core.call("look", [:])
        wda.set("POST /wda/apps/activate") { [wda] _ in
            wda.tree([Node("Button", "World Clock", [16, 100, 358, 44])], app: "Clock")
            return (200, ["value": .null])
        }
        let result = await core.call("do", ["actions": [["launch": "Clock"]]])
        XCTAssertTrue(result.text.contains("paused 900 ms before reading"), result.text)
    }
}
