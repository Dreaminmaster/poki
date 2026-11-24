import XCTest
@testable import PokiCore

/// ESP-465: a task asked in Poki's chat begins with Poki in front. In the owner's log the first look of
/// 3 of 5 tasks (build 800) read Poki's own chat, and the task card showed that picture.
final class PokiFrontTests: XCTestCase {
    func pokiInFront() -> FakeWDA {
        let wda = FakeWDA()
        wda.source([("Button", "Talk"), ("StaticText", "Message to a friend")], app: "Poki")
        wda.set("GET /wda/activeAppInfo") { _ in (200, ["value": ["bundleId": "nz.zheha.poki", "name": "Poki"]]) }
        return wda
    }

    func testALookWithPokiInFrontShowsNoneOfPokiAndSaysHowToStart() async {
        let (core, _, _) = makeCore(pokiInFront())
        let events = LockedBox<[CoreEvent]>([])
        Task { for await e in core.events { events.update { $0.append(e) } } }
        let looked = await core.call("look", [:])
        XCTAssertFalse(looked.isError, looked.text)
        XCTAssertNil(looked.jpeg, "no picture of the owner's chat goes to the model")
        XCTAssertFalse(looked.text.contains("Talk"), looked.text)
        XCTAssertFalse(looked.text.contains("Message to a friend"), looked.text)
        XCTAssertTrue(looked.text.contains("{launch: \"bundle id\"}"), looked.text)
        let finished = await eventually { events.value.contains { if case .toolFinished = $0 { return true }; return false } }
        XCTAssertTrue(finished)
        guard case .toolFinished(_, _, let facts)? = events.value.last else { return XCTFail("\(events.value)") }
        XCTAssertNil(facts.thumbnail, "the task card and the Live Activity get no picture of Poki")
    }

    /// The launch from Poki answers with the launched app's screen, picture and all.
    func testALaunchFromPokiShowsTheLaunchedApp() async {
        let wda = pokiInFront()
        let (core, _, _) = makeCore(wda)
        _ = await core.call("look", [:])
        for key in ["POST /wda/apps/launch", "POST /wda/apps/activate"] {
            wda.set(key) { [wda] _ in
                wda.set("GET /wda/activeAppInfo") { _ in (200, ["value": ["bundleId": "com.apple.mobilenotes", "name": "Notes"]]) }
                wda.source([("Button", "New Note")], app: "Notes")
                return (200, ["value": .null])
            }
        }
        let opened = await core.call("do", ["actions": [["launch": "com.apple.mobilenotes"]]])
        XCTAssertTrue(opened.text.contains("New Note"), opened.text)
        XCTAssertNotNil(opened.jpeg, opened.text)
    }

    func testMissingAppCanRecoverThroughHomeScreenSearch() async {
        let wda = pokiInFront()
        let (core, _, host) = makeCore(wda) { $0.appNames = { true } }
        host.state.value = .automationReady(revision: 1)
        let missing = await core.callTool("do", arguments: #"{"actions":[{"launch":"com.dianping.dpscope"}]}"#, localTask: "open-app")
        XCTAssertTrue(missing.isError)
        XCTAssertTrue(missing.text.contains("no app named"), missing.text)

        let batch = await core.callTool("do", arguments: #"{"actions":[{"button":"home"},{"swipe":"down"},{"type":"WeChat"}]}"#, localTask: "open-app")
        XCTAssertTrue(batch.isError)
        XCTAssertTrue(batch.text.contains("Send {button: \"home\"} by itself"), batch.text)
        XCTAssertTrue(wda.bodies("POST /wda/homescreen").isEmpty)

        wda.set("POST /wda/homescreen") { _ in
            wda.set("GET /wda/activeAppInfo") { _ in (200, ["value": ["bundleId": "com.apple.springboard", "name": "SpringBoard"]]) }
            wda.source([("Icon", "WeChat")], app: "SpringBoard")
            return (200, ["value": .null])
        }
        wda.set("POST /wda/pressAndDragWithVelocity") { _ in
            wda.source([("SearchField", "Search")], app: "SpringBoard")
            return (200, ["value": .null])
        }
        let home = await core.callTool("do", arguments: #"{"actions":[{"button":"home"}]}"#, localTask: "open-app")
        XCTAssertFalse(home.isError, home.text)
        XCTAssertTrue(home.text.contains("WeChat"), home.text)

        let search = await core.callTool("do", arguments: #"{"actions":[{"swipe":"down"}]}"#, localTask: "open-app")
        XCTAssertFalse(search.isError, search.text)
        XCTAssertTrue(search.text.contains("Search"), search.text)
    }

    func testNewTaskFirstStepNeverReusesPreviousTaskCalculatorScreenshot() async throws {
        let wda = FakeWDA()
        let calcPNG = Data("calculator-screen-png".utf8)
        let weatherPNG = Data("weather-screen-png".utf8)
        let currentPNG = LockedBox<Data?>(calcPNG)
        let front = LockedBox(("com.apple.calculator", "Calculator"))
        wda.set("GET /wda/activeAppInfo") { _ in
            let app = front.value
            return (200, ["value": ["bundleId": .string(app.0), "name": .string(app.1)]])
        }
        wda.set("GET /screenshot") { _ in
            guard let data = currentPNG.value else {
                return (500, ["value": ["error": "screenshot unavailable"]])
            }
            return (200, ["value": .string(data.base64EncodedString())])
        }
        wda.source([("Button", "7")], app: "Calculator")
        let (core, _, host) = makeCore(wda)
        host.state.value = .automationReady(revision: 1)

        let events = LockedBox<[CoreEvent]>([])
        let collector = Task { for await event in core.events { events.update { $0.append(event) } } }
        defer { collector.cancel() }

        func finishedFacts(count: Int) async throws -> ToolFacts {
            let arrived = await eventually {
                events.value.filter { if case .toolFinished = $0 { return true }; return false }.count >= count
            }
            XCTAssertTrue(arrived, "expected \(count) toolFinished events")
            let finished = events.value.compactMap { event -> ToolFacts? in
                if case .toolFinished(_, _, let facts) = event { return facts }
                return nil
            }
            return try XCTUnwrap(finished.last)
        }

        // Task 1 ends in Calculator with a fresh screenshot cached in Computer.
        let task1 = await core.callTool("look", arguments: "{}", localTask: "chat#1")
        XCTAssertNotNil(task1.jpeg)
        let task1Facts = try await finishedFacts(count: 1)
        XCTAssertEqual(task1Facts.app, "Calculator")
        XCTAssertNotNil(task1Facts.thumbnail)
        _ = await core.finishTask(switching: false)

        // Task 2 step 1 fails before any read after automation re-opens.
        host.state.value = .automationReady(revision: 2)
        let blocked = await core.callTool("do", arguments: #"{"actions":[{"tap":[20,100]}]}"#, localTask: "chat#2")
        XCTAssertTrue(blocked.isError, blocked.text)
        XCTAssertNil(blocked.jpeg, "early failure must not return previous task's screenshot to the model")
        let blockedFacts = try await finishedFacts(count: 2)
        XCTAssertNil(blockedFacts.thumbnail, "task card must not receive Calculator's screenshot on task 2 step 1")
        XCTAssertNil(blockedFacts.app, "task card must not receive Calculator as task 2 step 1's app")

        // Task 2 stays in Calculator without finishTask, then Task 3 starts when screenshot capture fails.
        front.value = ("com.apple.calculator", "Calculator")
        currentPNG.value = calcPNG
        _ = await core.callTool("look", arguments: "{}", localTask: "chat#2")
        _ = try await finishedFacts(count: 3)

        front.value = ("com.apple.weather", "Weather")
        wda.source([("StaticText", "Beijing")], app: "Weather")
        currentPNG.value = nil
        let task3Step1 = await core.callTool("look", arguments: "{}", localTask: "chat#3")
        XCTAssertFalse(task3Step1.isError, task3Step1.text)
        XCTAssertNil(task3Step1.jpeg, "new task step 1 must not fall back to previous task's Calculator screenshot: \(task3Step1.text)")
        XCTAssertFalse(task3Step1.text.contains("the screenshot is the one of the read before"), task3Step1.text)
        let task3Step1Facts = try await finishedFacts(count: 4)
        XCTAssertNil(task3Step1Facts.thumbnail, "task card must show no screenshot when new task step 1 fails to capture one")

        // Once Task 3 captures a fresh screenshot, both model and task card receive it.
        currentPNG.value = weatherPNG
        let task3Step2 = await core.callTool("look", arguments: "{}", localTask: "chat#3")
        XCTAssertEqual(task3Step2.jpeg, Data("jpeg:\(weatherPNG.count)".utf8))
        let task3Step2Facts = try await finishedFacts(count: 5)
        XCTAssertEqual(task3Step2Facts.app, "Weather")
        XCTAssertEqual(task3Step2Facts.thumbnail, Data("jpeg:\(weatherPNG.count)".utf8))
    }
}
