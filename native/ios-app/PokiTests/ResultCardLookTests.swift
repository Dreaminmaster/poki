import Foundation
import PokiCore
import SwiftUI
import UIKit
import XCTest
@testable import Poki

final class ResultCardLookTests: XCTestCase {
    private func make(_ kind: String, _ app: String, _ items: [[String: Any]], decoder: JSONDecoder = JSONDecoder()) throws -> ResultCard {
        let json: [String: Any] = ["app": app, "kind": kind, "items": items, "recommended": items[0]["id"]!,
                                   "primary": ["label": "查看", "say": "打开 {title}"]]
        return try decoder.decode(ResultCard.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testAppSpecificCardsAcceptRequiredFieldsAndNameAMissingField() throws {
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

    func testGenericCardAcceptsRowsContainingOnlyIDsAndTitles() throws {
        let card = try make(AnyAppList.kind, "com.sankuai.meituan", [["id": "a", "title": "A"], ["id": "b", "title": "B"]])
        XCTAssertNil(card.problem)
    }

    func testTransferPrimaryActionUsesTheSelectedJourneysDeparture() throws {
        var card = try make(RailwayTransfers.kind, "cn.12306.rails12306", [
            ["id": "a", "title": "G84 → G7", "date": "11.19", "legs": [
                ["number": "G84", "from": "上海虹桥", "depart": "19:05", "to": "常州北"],
                ["number": "G7", "from": "常州北", "to": "南京南", "arrive": "20:12"],
            ]],
            ["id": "b", "title": "G26 → G8", "date": "11.19", "from": "上海站", "legs": [
                ["number": "G26", "from": "上海", "depart": "17:00", "to": "苏州北"],
                ["number": "G8", "from": "苏州北", "to": "南京南", "arrive": "18:07"],
            ]],
        ])
        card.primary.say = "在 12306 打开 {date} {title}（{from} {depart} 开）"

        XCTAssertNil(card.problem)
        XCTAssertEqual(card.selected(nil).fill(card.primary.say), "在 12306 打开 11.19 G84 → G7（上海虹桥 19:05 开）")
        XCTAssertEqual(card.selected("b").fill(card.primary.say), "在 12306 打开 11.19 G26 → G8（上海站 17:00 开）")
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

    func testFinishTaskAdvertisesCardKindsAndPictureSourceFields() throws {
        let finish = try XCTUnwrap(Harness.tools.first { $0.name == "finish_task" })
        let properties = try XCTUnwrap(finish.schema["properties"] as? [String: Any])
        let card = try XCTUnwrap(properties["card"] as? [String: Any])
        let cardFields = try XCTUnwrap(card["properties"] as? [String: Any])
        let kind = try XCTUnwrap(cardFields["kind"] as? [String: Any])
        let kinds = try XCTUnwrap(kind["enum"] as? [String])
        XCTAssertEqual(Set(kinds), ["12306.trains", "12306.transfers", "ctrip.flights", "ctrip.hotels", "ctrip.rooms",
                                    "ctrip.fares", "taobao.products", "dianping.places", "ubereats.items", "list"])
        let items = try XCTUnwrap(cardFields["items"] as? [String: Any])
        let item = try XCTUnwrap(items["items"] as? [String: Any])
        let itemFields = try XCTUnwrap(item["properties"] as? [String: Any])
        let box = try XCTUnwrap(itemFields["image"] as? [String: Any])
        XCTAssertEqual(box["type"] as? String, "array")
        XCTAssertEqual((box["items"] as? [String: String])?["type"], "number")
        XCTAssertEqual(box["minItems"] as? Int, 4)
        XCTAssertEqual(box["maxItems"] as? Int, 4)
        XCTAssertEqual((itemFields["image_screenshot"] as? [String: Any])?["type"] as? String, "string")
    }

    func testFinishTaskDescribesTheFieldsUsedByCtripCardsAndPhotoCrops() throws {
        let finish = try XCTUnwrap(Harness.tools.first { $0.name == "finish_task" })
        let fields = try XCTUnwrap(finish.schema["properties"] as? [String: Any])
        let cardSchema = try XCTUnwrap(fields["card"] as? [String: Any])
        let description = try XCTUnwrap(cardSchema["description"] as? String)
        let lines = description.split(separator: "\n")
        let rooms = try XCTUnwrap(lines.first { $0.hasPrefix(Ctrip.rooms + " ") })
        let fares = try XCTUnwrap(lines.first { $0.hasPrefix(Ctrip.fares + " ") })

        let roomCard = try make(Ctrip.rooms, Ctrip.app, [
            ["id": "king", "title": "King Room", "hotel": "Harbor Hotel", "dates": "Dec 2–4", "price": "¥700", "was": "¥850"],
            ["id": "twin", "title": "Twin Room", "dates": "Dec 2–4", "price": "¥800", "was": "¥900"],
        ])
        let roomWords = rooms.split { !$0.isLetter && $0 != "_" }
        for field in ["dates", "was"] {
            XCTAssertNotNil(roomCard.items.first?.text(field))
            XCTAssertTrue(roomWords.contains(Substring(field)), "The room instructions must carry \(field).")
        }
        let roomAction = try XCTUnwrap(String(rooms).components(separatedBy: " / ").last)
        let selectedAction = roomCard.selected("twin").fill(roomAction)
        XCTAssertTrue(selectedAction.contains("Twin Room") && selectedAction.contains("Dec 2–4"), selectedAction)

        let fareCard = try make(Ctrip.fares, Ctrip.app, [
            ["id": "economy", "title": "Economy", "price": "¥900", "refund": "No refund. Changes cost ¥200."],
        ])
        XCTAssertEqual(fareCard.items[0].text("refund"), "No refund. Changes cost ¥200.")
        XCTAssertTrue(fares.contains("refund (refund and change rules)"), "Both fare rules belong in refund.")

        let cardFields = try XCTUnwrap(cardSchema["properties"] as? [String: Any])
        let items = try XCTUnwrap(cardFields["items"] as? [String: Any])
        let item = try XCTUnwrap(items["items"] as? [String: Any])
        let itemFields = try XCTUnwrap(item["properties"] as? [String: Any])
        let image = try XCTUnwrap(itemFields["image"] as? [String: Any])
        let imageDescription = try XCTUnwrap(image["description"] as? String)
        let pictures = try XCTUnwrap(lines.first { $0.hasPrefix("For pictured items,") })
        for guidance in [imageDescription, String(pictures)] {
            XCTAssertTrue(guidance.contains("photo itself"), "Crop coordinates must describe the photo.")
            XCTAssertTrue(guidance.contains("exclude") && guidance.contains("row"), "Keep the surrounding row out of the crop.")
        }
    }

    func testImageBoxRequiresFourFiniteNumbersWithPositiveDimensions() throws {
        let items: [[String: Any]] = [
            ["id": "a", "title": "A", "price": "¥27.8", "image": [-9.5, 198, 140, 140]],
            ["id": "b", "title": "B", "price": "¥83.9", "image": [9, 362, 0, 140]],
            ["id": "c", "title": "C", "price": "¥99", "image": [9, 520, 140, -1]],
            ["id": "d", "title": "D", "price": "¥99", "image": [9, 520, 140]],
            ["id": "e", "title": "E", "price": "¥99", "image": [9, 520, 140, 140, 1]],
            ["id": "f", "title": "F", "price": "¥99", "image": [9, 520, 140, "140"]],
            ["id": "g", "title": "G", "price": "¥99", "image": "9,520,140,140"],
            ["id": "h", "title": "H", "price": "¥99", "image": ["NaN", 520, 140, 140]],
            ["id": "i", "title": "I", "price": "¥99", "image": [9, 520, "Infinity", 140]],
        ]
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        let card = try make(Taobao.kind, Taobao.app, items, decoder: decoder)
        XCTAssertEqual(card.items[0].box("image"), Rect(x: -9.5, y: 198, width: 140, height: 140))
        for item in card.items.dropFirst() { XCTAssertNil(item.box("image"), item.id) }
        // The box is the model's pointer to the screen, not a fact to read back with the conversation.
        XCTAssertFalse(card.context(chosen: nil).contains("198"))
    }

    func testCutPicturesStayWithTheSavedCard() throws {
        var card = try make(UberEats.kind, UberEats.app, [["id": "a", "title": "Nuggets", "price": "$8.79"], ["id": "b", "title": "Fries", "price": "$3.19"]])
        card.pictures = ["a": Data([0xFF, 0xD8, 0xFF])]
        let again = try JSONDecoder().decode(ResultCard.self, from: JSONEncoder().encode(card))
        XCTAssertEqual(again.pictures, card.pictures)
    }

    @MainActor
    func testTrainCardLayoutSeparatesFareWrapsSeatsAndAlignsSelection() throws {
        let singleSeat = try make(RailwayTrains.kind, "cn.12306.rails12306", [[
            "id": "G531", "title": "G531", "date": "11月23日",
            "from": "北京南", "to": "上海虹桥", "depart": "06:08", "arrive": "12:04",
            "duration": "5小时56分", "price": "498元起",
            "seats": [["name": "二等", "left": "有票"]],
        ]])
        let fiveSeats = try make(RailwayTrains.kind, "cn.12306.rails12306", [[
            "id": "G547", "title": "G547", "date": "11月23日",
            "from": "北京南", "to": "上海虹桥", "depart": "06:18", "arrive": "12:11",
            "duration": "5小时53分", "price": "553元起",
            "seats": [
                ["name": "二等", "left": "候补"],
                ["name": "一等", "left": "有票"],
                ["name": "优选一等", "left": "候补"],
                ["name": "商务", "left": "11张"],
                ["name": "无座", "left": "有票"],
            ],
        ]])
        let narrowShortNoSeats = try make(RailwayTrains.kind, "cn.12306.rails12306", [[
            "id": "G3", "title": "G3", "date": "11月23日",
            "from": "北京南", "to": "上海", "depart": "06:52", "arrive": "11:33",
            "duration": "4小时41分", "price": "667元起",
        ]])
        let narrowLongNoSeats = try make(RailwayTrains.kind, "cn.12306.rails12306", [[
            "id": "G2688", "title": "G2688", "date": "11月23日",
            "from": "乌鲁木齐南站", "to": "北京首都国际机场", "depart": "08:40", "arrive": "16:55",
            "duration": "12小时15分", "price": "¥1568起",
        ]])

        // 1. On iPhone 16 Pro card width (370pt), arrival time and fare have clear horizontal spacing,
        //    and the selected row's blue left bar aligns with the card's 14pt horizontal inset.
        let rendered = try renderCard(singleSeat, width: 370)
        let (fareBox, arriveMaxX, accentMinX) = try inspectTrainCardPixels(rendered)
        XCTAssertGreaterThanOrEqual(
            Int(fareBox.minX) - arriveMaxX, 8,
            "Arrival time and fare must be separated (arriveMaxX=\(arriveMaxX), fareMinX=\(Int(fareBox.minX)))"
        )
        XCTAssertGreaterThanOrEqual(
            accentMinX, 12,
            "Selected row left bar must align with the card's 14pt inner padding (accentMinX=\(accentMinX))"
        )

        // 2. On narrow iPhone card width (343pt), 5 seats wrap naturally onto multiple lines instead of
        //    shrinking into a single line.
        let oneSeatHeight = try cardHeight(singleSeat, width: 343)
        let fiveSeatsHeight = try cardHeight(fiveSeats, width: 343)
        XCTAssertGreaterThanOrEqual(
            fiveSeatsHeight - oneSeatHeight, 10,
            "Seats that do not fit on one line must wrap naturally (one=\(oneSeatHeight), five=\(fiveSeatsHeight))"
        )

        // 3. On narrow iPhone card width (343pt), long stations + 4-digit fare move the fare below the
        //    journey line instead of colliding or truncating times.
        let shortHeight = try cardHeight(narrowShortNoSeats, width: 343)
        let longHeight = try cardHeight(narrowLongNoSeats, width: 343)
        XCTAssertGreaterThanOrEqual(
            longHeight - shortHeight, 14,
            "Overflowing fare on narrow widths must drop to the second row (short=\(shortHeight), long=\(longHeight))"
        )
    }

    func testTrainCardNormalizesMixedFareStrings() {
        XCTAssertEqual(RailwayTrains.normalizedFare("498元起"), "498元起")
        XCTAssertEqual(RailwayTrains.normalizedFare("¥1568起"), "1568元起")
        XCTAssertEqual(RailwayTrains.normalizedFare("￥1,568 起"), "1568元起")
        XCTAssertEqual(RailwayTrains.normalizedFare("1568起"), "1568元起")
        XCTAssertEqual(RailwayTrains.normalizedFare("¥553", preferStartingSuffix: true), "553元起")
        XCTAssertEqual(RailwayTrains.normalizedFare("¥553", preferStartingSuffix: false), "553元")
        XCTAssertEqual(RailwayTrains.normalizedFare("待公布"), "待公布")
    }

    @MainActor
    private func cardHeight(_ card: ResultCard, width: CGFloat) throws -> CGFloat {
        let host = UIHostingController(rootView: ResultCardView(entry: UUID(), card: card, chosen: nil, actions: nil))
        let size = host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
        return size.height
    }

    @MainActor
    private func renderCard(_ card: ResultCard, width: CGFloat) throws -> CGImage {
        let view = ResultCardView(entry: UUID(), card: card, chosen: nil, actions: nil)
            .frame(width: width)
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        return try XCTUnwrap(renderer.cgImage, "ImageRenderer must produce a bitmap for ResultCardView")
    }

    private func inspectTrainCardPixels(_ cg: CGImage) throws -> (fareBox: CGRect, arriveMaxX: Int, accentMinX: Int) {
        let w = cg.width
        let h = cg.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = try XCTUnwrap(CGContext(
            data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        var fareMinX = w, fareMaxX = 0, fareMinY = h, fareMaxY = 0
        for y in 0..<h {
            for x in (w / 2)..<w {
                let i = (y * w + x) * 4
                let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
                if r > 180, g > 60, b < 110, r - b > 90 {
                    fareMinX = min(fareMinX, x)
                    fareMaxX = max(fareMaxX, x)
                    fareMinY = min(fareMinY, y)
                    fareMaxY = max(fareMaxY, y)
                }
            }
        }
        guard fareMinX < fareMaxX, fareMinY <= fareMaxY else {
            XCTFail("Expected orange fare pixels in rendered train card (\(w)x\(h))")
            return (.zero, 0, 0)
        }

        var arriveMaxX = 0
        let scanStartX = w / 2
        if scanStartX < fareMinX {
            for y in max(0, fareMinY - 4)...min(h - 1, fareMaxY + 4) {
                for x in scanStartX..<fareMinX {
                    let i = (y * w + x) * 4
                    let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
                    if r < 140, g < 140, b < 140, abs(r - b) < 35 {
                        arriveMaxX = max(arriveMaxX, x)
                    }
                }
            }
        }
        XCTAssertGreaterThan(arriveMaxX, scanStartX, "Expected arrival time pixels left of the fare")

        var accentMinX = w
        let accentTop = max(0, fareMinY - 12)
        let accentBottom = min(h - 1, fareMaxY + 36)
        if accentTop <= accentBottom {
            for y in accentTop...accentBottom {
                for x in 0..<min(40, w) {
                    let i = (y * w + x) * 4
                    let r = Int(pixels[i]), b = Int(pixels[i + 2])
                    if b > 170, r < 150, b - r > 50 {
                        accentMinX = min(accentMinX, x)
                    }
                }
            }
        }
        XCTAssertLessThan(accentMinX, 40, "Expected blue selection bar on the leading edge of the selected row")
        let fareBox = CGRect(x: fareMinX, y: fareMinY, width: fareMaxX - fareMinX, height: fareMaxY - fareMinY)
        return (fareBox, arriveMaxX, accentMinX)
    }
}
