import XCTest
@testable import PokiCore

/// Where a result card's item pictures are cut, from boxes GPT-6.1 gave on real screens (Nov 19, 2026:
/// 淘宝, Uber Eats, 大众点评 and 携程 at 402 × 874 points).
final class ItemPictureTests: XCTestCase {
    let screen = ScreenSize(width: 402, height: 874)

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

        show(firstPNG, firstFrame)
        let first = await core.callTool("look", arguments: "{}", localTask: "shop")
        XCTAssertNotNil(first.jpeg)
        show(secondPNG, secondFrame)
        let second = await core.callTool("look", arguments: "{}", localTask: "shop")
        XCTAssertNotNil(second.jpeg)

        let pictures = await core.itemPictures(["first": box, "second": box])
        XCTAssertEqual(pictures?.png, firstPNG, "The first item came from the first screenshot")
        XCTAssertEqual(pictures?.frames["first"], firstFrame)
        XCTAssertEqual(pictures?.frames["second"], secondFrame)
    }

    func testABoxThatMatchesAnImageTakesTheImagesWholeFrame() {
        let photo = Rect(x: 8, y: 196, width: 142, height: 142)
        let box = Rect(x: 9, y: 198, width: 140, height: 140)
        XCTAssertEqual(ItemPictureFit.frame(for: box, images: [Rect(x: 8, y: 360, width: 142, height: 142), photo], screen: screen), photo)
    }

    func testAPictureTheScreensEdgeCutsIsLeftOut() {
        // Uber Eats' third "Order again" tile runs off the right edge: the model boxed its visible half.
        let tile = Rect(x: 328, y: 193, width: 148, height: 149)
        XCTAssertNil(ItemPictureFit.frame(for: Rect(x: 328, y: 193, width: 74, height: 149), images: [tile], screen: screen))
        XCTAssertNil(ItemPictureFit.frame(for: Rect(x: 330, y: 193, width: 140, height: 149), images: [tile], screen: screen))
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
