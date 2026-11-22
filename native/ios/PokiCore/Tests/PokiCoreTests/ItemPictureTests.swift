import XCTest
@testable import PokiCore

/// Where a result card's item pictures are cut, from boxes GPT-6.1 gave on real screens (Nov 19, 2026:
/// 淘宝, Uber Eats, 大众点评 and 携程 at 402 × 874 points).
final class ItemPictureTests: XCTestCase {
    let screen = ScreenSize(width: 402, height: 874)

    func testChatCanRetrieveAnEarlierScreenshotFromTheSameTask() async throws {
        let (core, wda, host) = makeCore()
        defer { withExtendedLifetime(host) {} }
        let first = Data("original screenshot".utf8).base64EncodedString()
        wda.set("GET /screenshot") { _ in (200, ["value": .string(first)]) }
        let before = await core.callTool("look", arguments: "{}", localTask: "compare")
        let prefix = "screenshot_id: "
        let line = try XCTUnwrap(before.text.split(separator: "\n").first { $0.hasPrefix(prefix) })
        let id = String(line.dropFirst(prefix.count))
        let args = JSON.object(["screenshot_id": .string(id)]).serialized()

        let second = Data("next screenshot with a different size".utf8).base64EncodedString()
        wda.set("GET /screenshot") { _ in (200, ["value": .string(second)]) }
        let after = await core.callTool("look", arguments: "{}", localTask: "compare")
        XCTAssertNotNil(before.jpeg)
        XCTAssertNotNil(after.jpeg)
        XCTAssertNotEqual(before.jpeg, after.jpeg)
        let retrieved = await core.callTool("get_screenshot", arguments: args, localTask: "compare")
        XCTAssertFalse(retrieved.isError, retrieved.text)
        XCTAssertEqual(retrieved.jpeg, before.jpeg)

        let fromAnotherTask = await core.callTool("get_screenshot", arguments: args, localTask: "another task")
        XCTAssertTrue(fromAnotherTask.isError)
        XCTAssertNil(fromAnotherTask.jpeg)
    }

    func testLongTaskCanRetrieveFirstScreenshotAfterMoreThanTenReads() async throws {
        let (core, wda, host) = makeCore()
        defer { withExtendedLifetime(host) {} }
        let frame = Rect(x: 10, y: 200, width: 100, height: 100)
        let box = Rect(x: 12, y: 201, width: 100, height: 100)
        var captured: [(id: String, jpeg: Data, png: Data)] = []

        for step in 1...11 {
            let png = Data("long-task-screen-\(step)-\(String(repeating: "x", count: step))".utf8)
            wda.set("GET /screenshot") { _ in (200, ["value": .string(png.base64EncodedString())]) }
            wda.tree([Node("Image", "Step \(step)", [frame.x, frame.y, frame.width, frame.height])])
            let answer = await core.callTool("look", arguments: "{}", localTask: "long-task")
            let jpeg = try XCTUnwrap(answer.jpeg)
            let prefix = "screenshot_id: "
            let line = try XCTUnwrap(answer.text.split(separator: "\n").first { $0.hasPrefix(prefix) })
            captured.append((String(line.dropFirst(prefix.count)), jpeg, png))
        }

        let first = try XCTUnwrap(captured.first)
        let latest = try XCTUnwrap(captured.last)
        XCTAssertNotEqual(first.jpeg, latest.jpeg)

        let firstArgs = JSON.object(["screenshot_id": .string(first.id)]).serialized()
        let retrieved = await core.callTool("get_screenshot", arguments: firstArgs, localTask: "long-task")
        XCTAssertFalse(retrieved.isError, retrieved.text)
        XCTAssertEqual(retrieved.jpeg, first.jpeg)

        let fromAnotherTask = await core.callTool("get_screenshot", arguments: firstArgs, localTask: "other-task")
        XCTAssertTrue(fromAnotherTask.isError)
        XCTAssertNil(fromAnotherTask.jpeg)

        let cardRequests = Dictionary(uniqueKeysWithValues: captured.enumerated().map { index, item in
            ("step-\(index + 1)", ItemPictureRequest(screenshotID: item.id, box: box))
        })
        let cardPictures = await core.itemPictures(cardRequests, localTask: "long-task")
        XCTAssertEqual(cardPictures.count, 8)
        XCTAssertFalse(cardPictures.contains { $0.png == first.png })
        XCTAssertTrue(cardPictures.contains { $0.png == latest.png })

        _ = await core.finishTask(switching: false, localTask: "long-task")
        let afterTaskEnded = await core.callTool("get_screenshot", arguments: firstArgs, localTask: "long-task")
        XCTAssertTrue(afterTaskEnded.isError)
        XCTAssertNil(afterTaskEnded.jpeg)
    }

    func testTaskScreenshotStoreExpiresAndDeletesTemporaryFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("poki-screenshot-store-test-\(UUID().uuidString.lowercased())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = LockedBox<Double>(100)
        let store = TaskScreenshotStore(root: root, clock: { clock.value })

        let firstBytes = Data("jpeg-step-1".utf8)
        let secondBytes = Data("jpeg-step-2".utf8)
        let otherTaskBytes = Data("jpeg-other".utf8)
        store.record(firstBytes, id: "shot-1", task: "task-a")
        clock.value = 160
        store.record(secondBytes, id: "shot-2", task: "task-a")
        store.record(otherTaskBytes, id: "shot-other", task: "task-b")

        let firstFile = root.appendingPathComponent("shot-1.jpg")
        let secondFile = root.appendingPathComponent("shot-2.jpg")
        let otherFile = root.appendingPathComponent("shot-other.jpg")
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstFile.path))
        XCTAssertEqual(store.screenshot("shot-1", task: "task-a"), firstBytes)
        XCTAssertNil(store.screenshot("shot-1", task: "task-b"))

        clock.value = 220
        XCTAssertNil(store.screenshot("shot-1", task: "task-a"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstFile.path))
        XCTAssertEqual(store.screenshot("shot-2", task: "task-a"), secondBytes)

        store.clear(task: "task-a")
        XCTAssertNil(store.screenshot("shot-2", task: "task-a"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondFile.path))
        XCTAssertEqual(store.screenshot("shot-other", task: "task-b"), otherTaskBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: otherFile.path))
    }

    func testItemPicturesUseTheScreenThatSuppliedTheirCoordinates() async throws {
        let (core, wda, host) = makeCore()
        defer { withExtendedLifetime(host) {} }
        let firstPNG = Data("first screenshot".utf8)
        let secondPNG = Data("second screenshot".utf8)
        let firstFrame = Rect(x: 10, y: 200, width: 100, height: 100)
        let secondFrame = Rect(x: 15, y: 202, width: 100, height: 100)
        let box = Rect(x: 12, y: 201, width: 100, height: 100)
        func show(_ png: Data, _ frame: Rect) {
            wda.set("GET /screenshot") { _ in (200, ["value": .string(png.base64EncodedString())]) }
            wda.tree([Node("Image", "Product photo", [frame.x, frame.y, frame.width, frame.height])])
        }
        func screenshotID(_ answer: PokiCore.ToolAnswer) throws -> String {
            XCTAssertNotNil(answer.jpeg)
            let prefix = "screenshot_id: "
            let line = try XCTUnwrap(answer.text.split(separator: "\n").first { $0.hasPrefix(prefix) })
            return String(line.dropFirst(prefix.count))
        }

        show(firstPNG, firstFrame)
        let first = await core.callTool("look", arguments: "{}", localTask: "shop")
        show(secondPNG, secondFrame)
        let second = await core.callTool("look", arguments: "{}", localTask: "shop")
        wda.set("GET /screenshot") { _ in (200, ["value": .null]) }
        wda.tree([Node("Image", "Another page", [19, 204, 100, 100])])
        let treeOnly = await core.callTool("look", arguments: "{}", localTask: "shop")
        XCTAssertTrue(treeOnly.text.contains("the screenshot is the one of the read before"))
        XCTAssertFalse(treeOnly.text.contains("screenshot_id: "))

        let requests = [
            "first": ItemPictureRequest(screenshotID: try screenshotID(first), box: box),
            "second": ItemPictureRequest(screenshotID: try screenshotID(second), box: box),
            "unknown": ItemPictureRequest(screenshotID: "unknown", box: box),
        ]
        let pictures = await core.itemPictures(requests, localTask: "shop")
        XCTAssertEqual(pictures.count, 2)
        XCTAssertEqual(pictures.first { $0.png == firstPNG }?.frames, ["first": firstFrame])
        XCTAssertEqual(pictures.first { $0.png == secondPNG }?.frames, ["second": secondFrame])
        let fromAnotherTask = await core.itemPictures(requests, localTask: "another task")
        XCTAssertTrue(fromAnotherTask.isEmpty)
    }

    func testABoxThatMatchesAnImageTakesTheImagesWholeFrame() {
        let photo = Rect(x: 8, y: 196, width: 142, height: 142)
        let box = Rect(x: 9, y: 198, width: 140, height: 140)
        XCTAssertEqual(ItemPictureFit.frame(for: box, images: [Rect(x: 8, y: 360, width: 142, height: 142), photo], screen: screen), photo)
    }

    func testABoxFollowingAnImageOffScreenIsLeftOut() {
        let tile = Rect(x: 328, y: 193, width: 148, height: 149)
        XCTAssertNil(ItemPictureFit.frame(for: Rect(x: 330, y: 193, width: 140, height: 149), images: [tile], screen: screen))
    }

    func testABoxAroundOnlyTheVisiblePartOfAnImageIsLeftOut() {
        let tile = Rect(x: 345, y: 193, width: 100, height: 80)
        let visible = Rect(x: 345, y: 193, width: 57, height: 80)
        XCTAssertNil(ItemPictureFit.frame(for: visible, images: [tile], screen: screen))
    }

    func testWithoutAnImageElementABoxTouchingTheScreenEdgeIsLeftOut() {
        let edgeBoxes = [
            Rect(x: 345, y: 350, width: 57, height: 80),
            Rect(x: 0, y: 350, width: 57, height: 80),
            Rect(x: 24, y: 0, width: 80, height: 57),
            Rect(x: 24, y: 817, width: 80, height: 57),
        ]
        for box in edgeBoxes {
            XCTAssertNil(ItemPictureFit.frame(for: box, images: [], screen: screen), "\(box)")
        }
    }

    func testWithoutAnImageElementABoxIsUsedWhenItIsAWholePicture() {
        let box = Rect(x: 12, y: 218, width: 90, height: 91)
        XCTAssertEqual(ItemPictureFit.frame(for: box, images: [], screen: screen), box)
        // 淘宝's first row on the second screen sits under the search bar: the model boxed a strip.
        XCTAssertNil(ItemPictureFit.frame(for: Rect(x: 9, y: 107, width: 140, height: 59), images: [], screen: screen))
        // A box past the screen's edge.
        XCTAssertNil(ItemPictureFit.frame(for: Rect(x: 340, y: 193, width: 100, height: 100), images: [], screen: screen))
    }

    func testABoxTooSmallToShowAnythingIsLeftOut() {
        XCTAssertNil(ItemPictureFit.frame(for: Rect(x: 20, y: 400, width: 20, height: 20), images: [], screen: screen))
    }
}
