import Foundation
import XCTest
@testable import PokiCore

/// Issue #609: what the desktop parity report found missing on the phone too: element states in the
/// listing, a way to set a slider, and a picture the caller can leave out or ask for at full size.
final class StatesAdjustTests: XCTestCase {
    /// A screen with a disabled Undo, a selected tab and an exposure slider whose value moves with
    /// the last drag that ended on its track.
    func editor(_ wda: FakeWDA, value: LockedBox<String>) {
        wda.set("GET /source") { _ in
            let slider: JSON = ["type": "XCUIElementTypeSlider", "label": "Exposure", "value": .string(value.value), "isEnabled": true, "rect": ["x": 40, "y": 600, "width": 310, "height": 40]]
            let root: JSON = ["type": "XCUIElementTypeApplication", "label": "Photos", "rect": ["x": 0, "y": 0, "width": 390, "height": 844], "children": [
                ["type": "XCUIElementTypeButton", "label": "Undo", "isEnabled": false, "rect": ["x": 16, "y": 60, "width": 60, "height": 44]],
                ["type": "XCUIElementTypeButton", "label": "Adjust", "isSelected": true, "rect": ["x": 100, "y": 760, "width": 80, "height": 44]],
                slider,
            ]]
            return (200, ["value": root])
        }
        wda.set("POST /wda/pressAndDragWithVelocity") { body in
            // The slider's track runs 16 points in from each end of its frame.
            let x = body?["toX"]?.double ?? 0
            let f = min(1, max(0, (x - 56) / 278))
            value.value = "\(Int((f * 100).rounded()))%"
            return (200, ["value": .null])
        }
    }

    func testTheListingNamesDisabledSelectedAndAdjustableElements() async {
        let (core, wda, _) = makeCore()
        editor(wda, value: LockedBox("50%"))
        let look = await core.call("look", [:])
        XCTAssertTrue(look.text.contains("Button \"Undo\" [16,60,60,44] (disabled)"), look.text)
        XCTAssertTrue(look.text.contains("Button \"Adjust\" [100,760,80,44] (selected)"), look.text)
        XCTAssertTrue(look.text.contains("(adjustable)"), look.text)
    }

    func testAdjustDragsTheThumbFromItsValueAndSaysWhereItLanded() async throws {
        let (core, wda, _) = makeCore()
        let value = LockedBox("50%")
        editor(wda, value: value)
        let look = await core.call("look", [:])
        let line = try XCTUnwrap(look.text.split(separator: "\n").first { $0.contains("Exposure") })
        let ref = try XCTUnwrap(Int(line.drop { !$0.isNumber }.prefix { $0.isNumber }))
        let result = await core.call("do", ["actions": [["adjust": ["ref": .number(Double(ref)), "value": "80%"]]]])
        let drag = try XCTUnwrap(wda.bodies("POST /wda/pressAndDragWithVelocity").first)
        XCTAssertEqual(drag["fromX"]?.double ?? 0, 56 + 0.5 * 278, accuracy: 0.5, "starts on the thumb, where 50 % puts it")
        XCTAssertEqual(drag["toX"]?.double ?? 0, 56 + 0.8 * 278, accuracy: 0.5)
        XCTAssertEqual(drag["fromY"]?.double ?? 0, 620, accuracy: 0.5)
        XCTAssertTrue(result.text.contains("value now \"80%\""), result.text)
        XCTAssertEqual(value.value, "80%")
    }

    func testAdjustRefusesAValueItCannotPlaceAndSendsNothing() async throws {
        let (core, wda, _) = makeCore()
        editor(wda, value: LockedBox("+0.0"))
        let look = await core.call("look", [:])
        let line = try XCTUnwrap(look.text.split(separator: "\n").first { $0.contains("Exposure") })
        let ref = try XCTUnwrap(Int(line.drop { !$0.isNumber }.prefix { $0.isNumber }))
        let result = await core.call("do", ["actions": [["adjust": ["ref": .number(Double(ref)), "value": "0.7"]]]])
        XCTAssertTrue(result.text.contains("give min and max"), result.text)
        XCTAssertTrue(wda.bodies("POST /wda/pressAndDragWithVelocity").isEmpty)
    }

    func testSliderFractionReadsPercentagesPlainFractionsAndRanges() {
        XCTAssertEqual(Computer.sliderFraction("40%"), 0.4)
        XCTAssertEqual(Computer.sliderFraction("0.25"), 0.25)
        XCTAssertNil(Computer.sliderFraction("7"))
        XCTAssertEqual(Computer.sliderFraction("+1.0", min: -2, max: 2) ?? 0, 0.75, accuracy: 1e-9)
        XCTAssertEqual(Computer.sliderFraction("\u{2212}2", min: -2, max: 2), 0)
        XCTAssertNil(Computer.sliderFraction("Off"))
        XCTAssertNil(Computer.sliderFraction("+0.0"), "a signed reading needs its range")
        let tall = Rect(x: 0, y: 0, width: 40, height: 300)
        XCTAssertEqual(Computer.sliderPoint(tall, 0).y, 284, "a vertical slider's 0 is at the bottom")
    }

    func testPictureFalseLeavesTheImageOutAndFullSendsThePNG() {
        let read = ToolResult(text: "screen", jpeg: Data("jpeg".utf8))
        let without = PokiCore.applyPicture(.bool(false), to: read, png: Data("png".utf8))
        XCTAssertNil(without.jpeg)
        XCTAssertTrue(without.text.contains("picture: left out"))
        let full = PokiCore.applyPicture(.string("full"), to: read, png: Data("png".utf8))
        XCTAssertEqual(full.png, Data("png".utf8))
        XCTAssertNil(full.jpeg)
        let kept = PokiCore.applyPicture(nil, to: read, png: Data("png".utf8))
        XCTAssertEqual(kept.jpeg, Data("jpeg".utf8), "the picture stays by default")
    }
}
