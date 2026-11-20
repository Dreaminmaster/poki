import Foundation
import XCTest
@testable import PokiCore

/// Apps by name, the session's app, and the read that comes as soon as the screen has settled.
final class AppNamesTests: XCTestCase {
    static let names = ["clock": "com.apple.mobiletimer", "时钟": "com.apple.mobiletimer", "com.apple.mobiletimer": "com.apple.mobiletimer",
                        "com.example.alias": "com.example.other"]
    static let installedApps = ["clock": "com.apple.mobiletimer", "时钟": "com.apple.mobiletimer",
                                "com.apple.mobiletimer": "com.apple.mobiletimer", "com.example.shop": "com.example.shop"]

    func core(names: Bool = true, quick: Bool = true) -> (PokiCore, FakeWDA) {
        let wda = FakeWDA()
        wda.tree([Node("Button", "General", [16, 100, 358, 44])], app: "Settings")
        let (core, _, _) = makeCore(wda) {
            $0.resolveApp = { Self.names[$0.lowercased()] }
            $0.resolveInstalledApp = { Self.installedApps[$0.lowercased()] }
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

    func testTheSessionsAppAlreadyInFrontTakesATapAfterAnOldRead() async {
        let (core, wda) = core()
        wda.set("GET /wda/activeAppInfo") { _ in (200, ["value": ["bundleId": "com.apple.mobiletimer", "name": "Clock"]]) }
        wda.tree([Node("Button", "Start", [16, 100, 358, 44])], app: "Clock")
        _ = await core.call("look", [:])
        // The model thought for a while before its first do with the app.
        core.computer.lastTreeAt = core.computer.lastTreeAt.map { $0 - 15 }

        let result = await core.call("do", ["actions": [["tap": 1]], "app": "Clock"])

        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(launched(wda), [], "Clock was in front: nothing was launched")
        XCTAssertEqual(wda.bodies("POST /wda/tap").count, 1, result.text)
        XCTAssertFalse(result.text.contains("approval"), result.text)
        XCTAssertFalse(result.text.contains("action 2"), result.text)
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

    func testAnUnknownNameLaterInTheBatchSendsNothingBeforeIt() async {
        for actions: [JSON] in [
            [["tap": 1], ["launch": "Nonesuch"]],
            [["tap": 1], ["path": ["steps": [["tap": "General"], ["launch": ["name": "Nonesuch"]]]]]],
        ] {
            let (core, wda) = core()
            _ = await core.call("look", [:])
            let result = await core.call("do", ["actions": .array(actions)])
            XCTAssertTrue(result.isError, result.text)
            XCTAssertTrue(result.text.contains("no app named \"Nonesuch\" is known") && result.text.contains("nothing was sent"), result.text)
            XCTAssertEqual(wda.bodies("POST /wda/tap").count, 0, "\(actions): the tap before the unknown name was not sent")
            XCTAssertEqual(launched(wda), [])
        }
    }

    func testExplicitLaunchFieldsKeepTheirMeaningInBatchesAndPaths() async {
        for inPath in [false, true] {
            let (core, wda) = core()
            _ = await core.call("look", [:])
            let unknown: JSON = ["launch": ["name": "tutti.ch"]]
            let actions: [JSON] = inPath
                ? [["path": ["steps": [["tap": "General"], unknown]]]]
                : [["tap": 1], unknown]
            let refused = await core.call("do", ["actions": .array(actions)])
            XCTAssertTrue(refused.isError, refused.text)
            XCTAssertTrue(refused.text.contains("no app named \"tutti.ch\" is known") && refused.text.contains("nothing was sent"), refused.text)
            XCTAssertEqual(wda.bodies("POST /wda/tap").count, 0, refused.text)
            XCTAssertEqual(launched(wda), [], refused.text)

            for bundle in ["vendor.app", "com.example.alias"] {
                let (core, wda) = self.core()
                _ = await core.call("look", [:])
                let launch: JSON = ["launch": ["bundle": .string(bundle)]]
                let actions: [JSON] = inPath ? [["path": ["steps": [launch]]]] : [launch]
                let opened = await core.call("do", ["actions": .array(actions)])
                XCTAssertFalse(opened.isError, opened.text)
                XCTAssertEqual(launched(wda), [bundle], opened.text)
            }
        }
    }

    func testAnUnknownDottedLaunchShorthandSendsNothing() async {
        for actions: [JSON] in [
            [["tap": 1], ["launch": "tutti.ch"]],
            [["path": ["steps": [["tap": "General"], ["launch": "tutti.ch"]]]]],
        ] {
            let (core, wda) = core()
            _ = await core.call("look", [:])
            let result = await core.call("do", ["actions": .array(actions)])
            XCTAssertTrue(result.isError, result.text)
            XCTAssertTrue(result.text.contains("tutti.ch") && result.text.contains("nothing was sent"), result.text)
            XCTAssertEqual(wda.bodies("POST /wda/tap").count, 0, result.text)
            XCTAssertEqual(launched(wda), [], result.text)
        }
    }

    func testWithNamesOffTheSessionsAppIsRefusedNotIgnored() async {
        let (core, wda) = core(names: false)
        _ = await core.call("look", [:])
        let result = await core.call("do", ["actions": [["tap": 1]], "app": "Clock"])
        XCTAssertTrue(result.isError, result.text)
        XCTAssertTrue(result.text.contains("Apps by Name"), result.text)
        XCTAssertEqual(wda.bodies("POST /wda/tap").count, 0, "the tap would have gone to Settings")
        // Letting go of an app is still taken.
        let letGo = await core.call("do", ["actions": [["wait": 10]], "app": false])
        XCTAssertFalse(letGo.isError, letGo.text)
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

    /// Clock in front from its launch on: its screen is drawn `after` seconds later.
    func clockOnLaunch(_ wda: FakeWDA, drawnAfter after: Double = 0, reads: Double = 0) {
        wda.set("POST /wda/apps/activate") { [wda] _ in
            wda.set("GET /wda/activeAppInfo") { _ in (200, ["value": ["bundleId": "com.apple.mobiletimer", "name": "Clock"]]) }
            let drawn = { wda.tree([Node("Button", "World Clock", [16, 100, 358, 44])], app: "Clock"); if reads > 0 { wda.delay("GET /source", reads) } }
            if after > 0 {
                wda.tree([], app: "Clock")
                DispatchQueue.global().asyncAfter(deadline: .now() + after) { drawn() }
            } else { drawn() }
            return (200, ["value": .null])
        }
    }

    func testAnEmptyScreenAfterALaunchIsNotTakenForTheSettledOne() async {
        let (core, wda) = core()
        _ = await core.call("look", [:])
        clockOnLaunch(wda, drawnAfter: 0.4)

        let result = await core.call("do", ["actions": [["launch": "Clock"]]])

        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains("World Clock"), result.text)
    }

    func testReadsSlowerThanThePauseDoNotMakeItLonger() async throws {
        let wda = FakeWDA()
        wda.tree([Node("Button", "General", [16, 100, 358, 44])], app: "Settings")
        let (core, _, _) = makeCore(wda) {
            $0.resolveInstalledApp = { Self.installedApps[$0.lowercased()] }
            $0.toolDeadline = 25
            $0.readTimeout = 4
        }
        _ = await core.call("look", [:])
        clockOnLaunch(wda, reads: 1.8)

        let result = await core.call("do", ["actions": [["launch": "Clock"]]])

        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains("World Clock"), result.text)
        let waited = try XCTUnwrap(["paused ", "read after "].lazy.compactMap { key in result.text.range(of: key).flatMap { Int(result.text[$0.upperBound...].prefix(while: \.isNumber)) } }.first, result.text)
        // The launch's fixed pause is 900 ms; a read let run past it made it 1.4 s.
        XCTAssertLessThanOrEqual(waited, 1200, result.text)
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
