import Foundation
import PokiCore
import XCTest
@testable import Poki

/// The result card looks past 12306's, from the real screens read on the test phone (Nov 18, 2026):
/// each kind decodes and draws with the fields its app shows, says which field is missing otherwise,
/// is offered to the model in finish_task, and keeps the item pictures cut from the screen.
final class ResultCardLookTests: XCTestCase {
    private func make(_ kind: String, _ app: String, _ items: [[String: Any]]) throws -> ResultCard {
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
            XCTAssertNil(try make(kind, app, whole).problem, kind)
            var short = whole
            short[1][needed] = nil
            XCTAssertEqual(try make(kind, app, short).problem?.hasSuffix("b needs \(needed)"), true, kind)
        }
    }

    /// 12306's 中转 list from the test phone (Nov 19, 2026): G84 changes seats in the train at 常州北.
    func testAJourneyWithAChangeOfTrainNeedsTwoLegsAndTakesItsEndsFromThem() throws {
        func journey(_ id: String, _ legs: [[String: Any]]) -> [String: Any] {
            ["id": id, "title": id, "date": "11.19", "duration": "全程1小时7分", "legs": legs]
        }
        let g84: [[String: Any]] = [
            ["number": "G84", "from": "上海虹桥", "to": "常州北", "depart": "19:05", "arrive": "19:40", "seats": [["name": "二等", "left": "有"]]],
            ["number": "G84", "from": "常州北", "to": "南京南", "depart": "19:42", "arrive": "20:12", "wait": "2分", "change": "车内换座"],
        ]
        let g26: [[String: Any]] = [
            ["number": "G26", "from": "上海虹桥", "to": "苏州北", "depart": "17:00", "arrive": "17:21"],
            ["number": "G26", "from": "苏州北", "to": "南京南", "depart": "17:23", "arrive": "18:07", "change": "车内换座"],
        ]
        let card = try make(RailwayTransfers.kind, "cn.12306.rails12306", [journey("G84", g84), journey("G26", g26)])
        XCTAssertNil(card.problem)
        let legs = try XCTUnwrap(ResultCardLeg.legs(of: card.items[0]))
        XCTAssertEqual(legs.map(\.number), ["G84", "G84"])
        XCTAssertEqual(legs[1].change, "车内换座")
        XCTAssertEqual(legs[0].seats, [ResultCardLeg.Seat(name: "二等", left: "有")])
        let ends = try XCTUnwrap(RailwayTransfers.Ends(card.items[0], legs))
        XCTAssertEqual([ends.from, ends.depart, ends.to, ends.arrive], ["上海虹桥", "19:05", "南京南", "20:12"])

        let oneLeg = try make(RailwayTransfers.kind, "cn.12306.rails12306", [journey("G84", Array(g84.prefix(1))), journey("G26", g26)])
        XCTAssertEqual(oneLeg.problem, "journey G84 needs legs, two or more, each with its number")
        var unnamed = g26
        unnamed[1]["number"] = nil
        XCTAssertNotNil(try make(RailwayTransfers.kind, "cn.12306.rails12306", [journey("G84", g84), journey("G26", unnamed)]).problem)
    }

    func testAnyAppGetsTheListLookWithOnlyTitles() throws {
        let card = try make(AnyAppList.kind, "com.sankuai.meituan", [["id": "a", "title": "A", "value": "¥58"], ["id": "b", "title": "B"]])
        XCTAssertNil(card.problem)
    }

    func testRoomActionsKeepTheHotelAcrossSelections() throws {
        var card = try make(Ctrip.rooms, Ctrip.app, [
            ["id": "king", "title": "King Room", "hotel": "Harbor Hotel", "price": "¥700"],
            ["id": "twin", "title": "Twin Room", "price": "¥800"],
        ])
        card.primary.say = "Open {title} at {hotel} for {price}"

        XCTAssertEqual(card.selected(nil).fill(card.primary.say), "Open King Room at Harbor Hotel for ¥700")
        XCTAssertEqual(card.selected("twin").fill(card.primary.say), "Open Twin Room at Harbor Hotel for ¥800")
        XCTAssertEqual(card.selected("king").fill(card.primary.say), "Open King Room at Harbor Hotel for ¥700")
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
        let card = try make(Taobao.kind, Taobao.app, items)
        XCTAssertEqual(card.items[0].box("image"), Rect(x: 9, y: 198, width: 140, height: 140))
        XCTAssertNil(card.items[1].box("image"))
        XCTAssertNil(card.items[2].box("image"))
        // The box is the model's pointer to the screen, not a fact to read back with the conversation.
        XCTAssertFalse(card.context(chosen: nil).contains("198"))
    }

    func testCutPicturesStayWithTheSavedCard() throws {
        var card = try make(UberEats.kind, UberEats.app, [["id": "a", "title": "Nuggets", "price": "$8.79"], ["id": "b", "title": "Fries", "price": "$3.19"]])
        card.pictures = ["a": Data([0xFF, 0xD8, 0xFF])]
        let again = try JSONDecoder().decode(ResultCard.self, from: JSONEncoder().encode(card))
        XCTAssertEqual(again.pictures, card.pictures)
    }
}
