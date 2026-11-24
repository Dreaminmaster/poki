import PokiCore
import SwiftUI

/// A journey with changes (a train change, a connecting flight): its legs in order, as the item's
/// `legs` field gives them. Each leg is one train or flight; `wait` and `change` belong to the change
/// before it (how long between, and what it takes: "车内换座", "不同航站楼转机").
struct ResultCardLeg: Equatable {
    struct Seat: Equatable {
        var name: String
        var left: String
    }
    var number: String
    var from: String?
    var to: String?
    var depart: String?
    var arrive: String?
    var arriveDay: String?
    var wait: String?
    var change: String?
    var seats: [Seat]

    /// The item's legs, nil unless there are two or more and each names its train or flight.
    static func legs(of item: ResultCard.Item) -> [ResultCardLeg]? {
        guard let raw = item.fields["legs"]?.array, raw.count >= 2 else { return nil }
        let legs = raw.compactMap { leg -> ResultCardLeg? in
            func text(_ key: String) -> String? {
                leg[key]?.text.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
            }
            guard let number = text("number") else { return nil }
            let seats = (leg["seats"]?.array ?? []).compactMap { seat -> Seat? in
                guard let name = seat["name"]?.text, let left = seat["left"]?.text else { return nil }
                return Seat(name: name, left: left)
            }
            return ResultCardLeg(number: number, from: text("from"), to: text("to"), depart: text("depart"), arrive: text("arrive"),
                                 arriveDay: text("arrive_day"), wait: text("wait"), change: text("change"), seats: seats)
        }
        return legs.count == raw.count ? legs : nil
    }
}

/// The changes of a journey, one line each, under its row: where, how long, and what the change takes
/// in the app's warning colour, as 12306 and 携程 mark a change (车内换座 in orange).
struct ResultCardChanges: View {
    var legs: [ResultCardLeg]
    var warning: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(legs.dropFirst().enumerated()), id: \.offset) { index, leg in
                let before = legs[index]
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "arrow.triangle.swap").font(.caption2).foregroundStyle(Color(.tertiaryLabel))
                    Text(verbatim: ResultCardParts.line([before.to ?? leg.from, times(before, leg), leg.wait]) ?? "")
                        .font(.caption).foregroundStyle(Color(.secondaryLabel)).lineLimit(1)
                    if let change = leg.change {
                        Text(verbatim: change).font(.caption).foregroundStyle(warning).lineLimit(1)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func times(_ before: ResultCardLeg, _ leg: ResultCardLeg) -> String? {
        switch (before.arrive, leg.depart) {
        case let (arrive?, depart?): return "\(arrive) → \(depart)"
        case let (arrive?, nil): return arrive
        case let (nil, depart?): return depart
        default: return nil
        }
    }
}
