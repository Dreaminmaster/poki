import SwiftUI

/// 12306's journeys with a change of train (中转, kind `12306.transfers`), as its 中转 list draws them
/// (read off the app on the test phone, Nov 19, 2026): the first train's departure and the last one's
/// arrival large, the whole journey's length over the change station in a pill, what the change takes
/// in orange under it (车内换座), and the seats left on each leg (1程, 2程) under the row.
enum RailwayTransfers {
    static let kind = "12306.transfers"
    static let change = Color(light: 0xFF6A00, dark: 0xFF8A33)

    /// The journey's ends: the item's own fields, else its first and last legs'.
    struct Ends {
        var from: String
        var to: String
        var depart: String
        var arrive: String

        init?(_ item: ResultCard.Item, _ legs: [ResultCardLeg]) {
            guard let from = item.text("from") ?? legs.first?.from, let to = item.text("to") ?? legs.last?.to,
                  let depart = item.text("depart") ?? legs.first?.depart, let arrive = item.text("arrive") ?? legs.last?.arrive else { return nil }
            self.from = from
            self.to = to
            self.depart = depart
            self.arrive = arrive
        }
    }

    static func problem(_ items: [ResultCard.Item]) -> String? {
        for item in items {
            guard let legs = ResultCardLeg.legs(of: item) else { return "journey \(item.id) needs legs, two or more, each with its number" }
            if Ends(item, legs) == nil { return "journey \(item.id) needs from, to, depart and arrive" }
        }
        return nil
    }

    static let look = ResultCardLook(problem: problem, tint: RailwayTrains.blue, buttonShape: .roundedRectangle(radius: 8)) { card, selected, choose in
        AnyView(RailwayTransferList(card: card, selected: selected, choose: choose))
    }
}

struct RailwayTransferList: View {
    var card: ResultCard
    var selected: ResultCard.Item
    var choose: ((String) -> Void)?

    var body: some View {
        let first = card.items.first
        let ends = first.flatMap { item in ResultCardLeg.legs(of: item).flatMap { RailwayTransfers.Ends(item, $0) } }
        ResultCardList(card: card, selected: selected, choose: choose, tint: RailwayTrains.blue, carried: "rails12306",
                       heading: ends.map { "\($0.from) → \($0.to)" }, subheading: first?.text("date")) { item in
            if let legs = ResultCardLeg.legs(of: item), let ends = RailwayTransfers.Ends(item, legs) {
                TransferRow(item: item, legs: legs, ends: ends)
            }
        }
    }
}

private struct TransferRow: View {
    var item: ResultCard.Item
    var legs: [ResultCardLeg]
    var ends: RailwayTransfers.Ends

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 0) {
                end(ends.depart, ends.from, alignment: .leading)
                Spacer(minLength: 6)
                middle
                Spacer(minLength: 6)
                end(ends.arrive, ends.to, alignment: .trailing)
                if let price = item.text("price") {
                    Text(verbatim: price)
                        .font(.callout.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(RailwayTrains.fare)
                        .frame(minWidth: 58, alignment: .trailing)
                }
            }
            Text(verbatim: legs.map(\.number).joined(separator: " → "))
                .font(.subheadline.weight(.medium)).lineLimit(1).minimumScaleFactor(0.8)
            ResultCardChanges(legs: legs, warning: RailwayTransfers.change)
            ForEach(Array(legs.enumerated()), id: \.offset) { index, leg in
                if !leg.seats.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("Leg \(index + 1)", comment: "A result card's leg of a journey with changes, as 12306 numbers them (1程, 2程)")
                            .font(.caption2).foregroundStyle(Color(.secondaryLabel))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 3))
                        Text(verbatim: leg.seats.map { "\($0.name) \($0.left)" }.joined(separator: "   "))
                            .font(.caption).foregroundStyle(Color(.secondaryLabel))
                            .lineLimit(1).minimumScaleFactor(0.8)
                    }
                }
            }
            ResultCardParts.caption(item.text("note"))
        }
    }

    private func end(_ time: String, _ station: String, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(verbatim: time).font(.title3.weight(.semibold)).monospacedDigit()
            Text(verbatim: station).font(.footnote).foregroundStyle(Color(.secondaryLabel)).lineLimit(1)
        }
    }

    /// The journey's length, the change stations in a pill, and what the first change takes.
    private var middle: some View {
        VStack(spacing: 3) {
            if let duration = item.text("duration") {
                Text(verbatim: duration).font(.caption2).foregroundStyle(Color(.secondaryLabel))
            }
            let stations = zip(legs, legs.dropFirst()).compactMap { $0.to ?? $1.from }
            if !stations.isEmpty {
                Text(verbatim: stations.joined(separator: " "))
                    .font(.caption.weight(.medium)).lineLimit(1)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .overlay(Capsule().strokeBorder(Color(.separator)))
            }
            if let change = legs.dropFirst().compactMap(\.change).first {
                Text(verbatim: change).font(.caption2).foregroundStyle(RailwayTransfers.change).lineLimit(1)
            }
        }
    }
}
