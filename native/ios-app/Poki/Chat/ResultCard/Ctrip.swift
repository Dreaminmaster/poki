import SwiftUI

/// Trip.com (携程旅行) cards: flights, hotels, a hotel's room types and a flight's fares, each as 携程
/// lists them. Read off the app on the test phone (Nov 18, 2026): prices in 携程's blue, times large,
/// a hotel's score in a blue badge, facts that bear on the choice in grey under the row.
enum Ctrip {
    static let app = "ctrip.com"
    static let blue = Color(light: 0x287DFA, dark: 0x4A93FF)
    /// What a connection takes (不同航站楼转机), in 携程's orange.
    static let warning = Color(light: 0xFF7700, dark: 0xFF9233)
    static let carried = "ctrip"

    static let flights = "ctrip.flights"
    static let hotels = "ctrip.hotels"
    static let rooms = "ctrip.rooms"
    static let fares = "ctrip.fares"

    static func look(_ kind: String) -> ResultCardLook {
        let needs = kind == flights ? ["depart", "arrive", "price"] : ["price"]
        let what = kind == flights ? "flight" : kind == hotels ? "hotel" : kind == rooms ? "room" : "fare"
        return ResultCardLook(problem: { ResultCardParts.missing($0, needs, what: what) }, tint: blue,
                              buttonShape: .roundedRectangle(radius: 8)) { card, selected, choose in
            if kind == flights { return AnyView(CtripFlightList(card: card, selected: selected, choose: choose)) }
            if kind == hotels { return AnyView(CtripHotelList(card: card, selected: selected, choose: choose)) }
            if kind == rooms { return AnyView(CtripRoomList(card: card, selected: selected, choose: choose)) }
            return AnyView(CtripFareList(card: card, selected: selected, choose: choose))
        }
    }
}

/// Flights, one row each as 携程's flight list draws them: departure and arrival large with their
/// airports, the stops and the journey's length between, the arrival's extra days beside its time, the
/// price on the right and the airline under the row. A return leg's price is what it adds ("+¥0").
/// A flight with connections lists each one under it: where, the times between, the layover, and what
/// the connection takes in orange (不同航站楼转机), from the item's `legs`.
struct CtripFlightList: View {
    var card: ResultCard
    var selected: ResultCard.Item
    var choose: ((String) -> Void)?

    var body: some View {
        let first = card.items.first
        ResultCardList(card: card, selected: selected, choose: choose, tint: Ctrip.blue, carried: Ctrip.carried,
                       heading: route(first), subheading: first?.text("date")) { item in
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    end(item.text("depart") ?? "", item.text("from"), day: nil, alignment: .leading)
                    Spacer(minLength: 6)
                    VStack(spacing: 2) {
                        if let stops = item.text("stops") { Text(verbatim: stops).font(.caption) }
                        Capsule().fill(Color(.tertiaryLabel)).frame(width: 52, height: 1)
                        if let duration = item.text("duration") {
                            Text(verbatim: duration).font(.caption2).foregroundStyle(Color(.secondaryLabel))
                        }
                    }
                    Spacer(minLength: 6)
                    end(item.text("arrive") ?? "", item.text("to"), day: item.text("arrive_day"), alignment: .trailing)
                    Text(verbatim: item.text("price") ?? "")
                        .font(.callout.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(Ctrip.blue)
                        .frame(minWidth: 72, alignment: .trailing)
                }
                ResultCardParts.caption(ResultCardParts.line([item.text("airline"), item.title == item.text("airline") ? nil : item.title, item.text("cabin")]), lines: 1)
                if let legs = ResultCardLeg.legs(of: item) { ResultCardChanges(legs: legs, warning: Ctrip.warning) }
                ResultCardParts.caption(item.text("note"))
            }
        }
    }

    private func route(_ item: ResultCard.Item?) -> String? {
        guard let from = item?.text("from_city"), let to = item?.text("to_city") else { return nil }
        return "\(from) → \(to)"
    }

    private func end(_ time: String, _ airport: String?, day: String?, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(verbatim: time).font(.title3.weight(.semibold)).monospacedDigit()
                if let day { Text(verbatim: day).font(.caption2.weight(.semibold)).baselineOffset(6) }
            }
            if let airport {
                Text(verbatim: airport).font(.footnote).foregroundStyle(Color(.secondaryLabel)).lineLimit(1)
            }
        }
    }
}

/// Hotels as 携程's hotel list draws them: the name and its English name, the score in a blue badge
/// with the review count, where it is, and the nightly price on the right over the stay's total.
struct CtripHotelList: View {
    var card: ResultCard
    var selected: ResultCard.Item
    var choose: ((String) -> Void)?

    var body: some View {
        let first = card.items.first
        ResultCardList(card: card, selected: selected, choose: choose, tint: Ctrip.blue, carried: Ctrip.carried,
                       heading: first?.text("city"), subheading: first?.text("dates"), picture: 72) { item in
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(verbatim: item.title).font(.body.weight(.semibold)).lineLimit(2)
                        if let stars = item.text("stars") {
                            Text(verbatim: stars).font(.caption).foregroundStyle(Color(.secondaryLabel))
                        }
                    }
                    if let subtitle = item.text("subtitle") {
                        Text(verbatim: subtitle).font(.footnote).foregroundStyle(Color(.secondaryLabel)).lineLimit(1)
                    }
                    if item.text("rating") != nil || item.text("reviews") != nil {
                        HStack(spacing: 6) {
                            if let rating = item.text("rating") {
                                Text(verbatim: rating).font(.caption.weight(.semibold)).monospacedDigit()
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Ctrip.blue, in: .rect(cornerRadius: 4))
                            }
                            ResultCardParts.caption(item.text("reviews"), lines: 1)
                        }
                    }
                    ResultCardParts.caption(item.text("location"))
                    ResultCardParts.caption(item.text("note"))
                }
                Spacer(minLength: 0)
                CtripPrice(price: item.text("price"), was: item.text("was"), total: item.text("total"))
            }
        }
    }
}

/// A hotel's room types as 携程's room list draws them: the room, its beds and size, breakfast and
/// the cancellation rule, the nightly price on the right over the stay's total.
struct CtripRoomList: View {
    var card: ResultCard
    var selected: ResultCard.Item
    var choose: ((String) -> Void)?

    var body: some View {
        let first = card.items.first
        ResultCardList(card: card, selected: selected, choose: choose, tint: Ctrip.blue, carried: Ctrip.carried,
                       heading: first?.text("hotel"), subheading: first?.text("dates"), picture: 64) { item in
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: item.title).font(.body.weight(.semibold)).lineLimit(2)
                    ResultCardParts.caption(item.text("beds"))
                    ResultCardParts.caption(ResultCardParts.line([item.text("breakfast"), item.text("cancel")]))
                    ResultCardParts.caption(item.text("note"))
                }
                Spacer(minLength: 0)
                CtripPrice(price: item.text("price"), was: item.text("was"), total: item.text("total"))
            }
        }
    }
}

/// A flight's fares as 携程's booking page lists them: the price large, then what differs between
/// fares (cabin, baggage, refund and change rules, ticketing) in grey, one fact a line.
struct CtripFareList: View {
    var card: ResultCard
    var selected: ResultCard.Item
    var choose: ((String) -> Void)?

    var body: some View {
        let first = card.items.first
        ResultCardList(card: card, selected: selected, choose: choose, tint: Ctrip.blue, carried: Ctrip.carried,
                       heading: first?.text("trip"), subheading: first?.text("dates")) { item in
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: item.text("price") ?? "")
                        .font(.title3.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(Ctrip.blue)
                    if item.title != item.text("price") {
                        Text(verbatim: item.title).font(.subheadline.weight(.medium)).lineLimit(1)
                    }
                }
                ResultCardParts.caption(item.text("cabin"))
                ResultCardParts.caption(item.text("baggage"))
                ResultCardParts.caption(item.text("refund"))
                ResultCardParts.caption(item.text("ticketing"))
                ResultCardParts.caption(item.text("note"))
            }
        }
    }
}

/// 携程's price column: the price in blue, the old price struck through before it, the total under it.
struct CtripPrice: View {
    var price: String?
    var was: String?
    var total: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if let was {
                    Text(verbatim: was).font(.caption).strikethrough().foregroundStyle(Color(.secondaryLabel))
                }
                Text(verbatim: price ?? "").font(.callout.weight(.semibold)).monospacedDigit().foregroundStyle(Ctrip.blue)
            }
            if let total {
                Text(verbatim: total).font(.caption2).foregroundStyle(Color(.secondaryLabel))
            }
        }
        .fixedSize()
    }
}
