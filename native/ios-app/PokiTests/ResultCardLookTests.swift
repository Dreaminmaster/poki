import Foundation
import PokiCore
import XCTest
@testable import Poki

/// The result card looks past 12306's, from the real screens read on the test phone (Nov 18, 2026):
/// each kind decodes and draws with the fields its app shows, says which field is missing otherwise,
/// is offered to the model in finish_task, and keeps the item pictures cut from the screen.
final class ResultCardLookTests: XCTestCase {
    private func card(_ kind: String, _ app: String, _ items: [[String: Any]]) throws -> ResultCard {
        let json: [String: Any] = ["app": app, "kind": kind, "items": items, "recommended": items[0]["id"]!,
                                   "primary": ["label": "查看", "say": "打开 {title}"]]
        return try JSONDecoder().decode(ResultCard.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testEachNewKindDrawsWithItsAppsFieldsAndNamesAMissingOne() throws {
        let cases: [(String, String, [String: Any], String)] = [
            (Ctrip.flights, Ctrip.app, ["depart": "17:30", "arrive": "13:00", "arrive_day": "+2", "price": "¥19,852"], "price"),
            (Ctrip.hotels, Ctrip.app, ["price": "¥1799", "rating": "4.4", "stars": "4钻"], "price"),
            (Ctrip.rooms, Ctrip.app, ["price": "¥1819", "beds": "1张1.8米特大床"], "price"),
            (Ctrip.fares, Ctrip.app, ["price": "¥19588", "baggage": "托运行李1x23kg"], "price"),
            (Taobao.kind, Taobao.app, ["price": "¥27.8", "sold": "3000+人付款"], "price"),
            (Dianping.kind, Dianping.app, ["rating": "4.5", "reviews": "79条"], "rating"),
            (UberEats.kind, UberEats.app, ["price": "$8.79", "calories": "410 Cal."], "price"),
        ]
        for (kind, app, fields, needed) in cases {
            let named: [[String: Any]] = [["id": "a", "title": "A"], ["id": "b", "title": "B"]]
            let whole = named.map { $0.merging(fields) { a, _ in a } }
            XCTAssertNil(try card(kind, app, whole).problem, kind)
            var short = whole
            short[1][needed] = nil
            XCTAssertEqual(try card(kind, app, short).problem?.hasSuffix("b needs \(needed)"), true, kind)
        }
    }

    func testFinishTaskOffersEveryLookAndTheItemsPictureBox() throws {
        let finish = try XCTUnwrap(Harness.tools.first { $0.name == "finish_task" })
        let schema = try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: finish.schema), encoding: .utf8))
        for kind in ResultCardLooks.all.keys { XCTAssertTrue(schema.contains("\"\(kind)\""), kind) }
        XCTAssertTrue(schema.contains("\"image\""))
    }

    func testAnItemsImageBoxIsReadAndOnlyWhenItIsFourPositiveNumbers() throws {
        let items: [[String: Any]] = [
            ["id": "a", "title": "A", "price": "¥27.8", "image": [9, 198, 140, 140]],
            ["id": "b", "title": "B", "price": "¥83.9", "image": [9, 362, 0, 140]],
            ["id": "c", "title": "C", "price": "¥99", "image": "9,520,140,140"],
        ]
        let card = try card(Taobao.kind, Taobao.app, items)
        XCTAssertEqual(card.items[0].box("image"), Rect(x: 9, y: 198, width: 140, height: 140))
        XCTAssertNil(card.items[1].box("image"))
        XCTAssertNil(card.items[2].box("image"))
        // The box is the model's pointer to the screen, not a fact to read back with the conversation.
        XCTAssertFalse(card.context(chosen: nil).contains("198"))
    }

    func testCutPicturesStayWithTheSavedCard() throws {
        var card = try card(UberEats.kind, UberEats.app, [["id": "a", "title": "Nuggets", "price": "$8.79"], ["id": "b", "title": "Fries", "price": "$3.19"]])
        card.pictures = ["a": Data([0xFF, 0xD8, 0xFF])]
        let again = try JSONDecoder().decode(ResultCard.self, from: JSONEncoder().encode(card))
        XCTAssertEqual(again.pictures, card.pictures)
    }
}
