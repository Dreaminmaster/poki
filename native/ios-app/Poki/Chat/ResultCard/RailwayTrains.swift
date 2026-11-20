import SwiftUI

/// Railway 12306's train list (kind `12306.trains`): each train as 12306 lists it, with the departure and
/// arrival times large, the train number and the journey's length between them, the fare on the right
/// and the seats left under it.
enum RailwayTrains {
    static let kind = "12306.trains"
    /// 查询车票's blue, read off the app on the test phone.
    static let blue = Color(light: 0x5597F5, dark: 0x5C9CF7)
    static let fare = Color(light: 0xFF6A00, dark: 0xFF8A33)

    struct Train {
        struct Seat: Hashable {
            var name: String
            var left: String
        }
        var number: String
        var date: String?
        var from: String
        var to: String
        var depart: String
        var arrive: String
        var duration: String?
        var price: String?
        var seats: [Seat]
        /// A fact that bears on the choice ("15:00 有冲突"), in grey.
        var note: String?

        init?(_ item: ResultCard.Item) {
            guard let from = item.text("from"), let to = item.text("to"), let depart = item.text("depart"),
                  let arrive = item.text("arrive") else { return nil }
            number = item.title
            self.from = from
            self.to = to
            self.depart = depart
            self.arrive = arrive
            date = item.text("date")
            duration = item.text("duration")
            price = item.text("price")
            note = item.text("note")
            seats = (item.fields["seats"]?.array ?? []).compactMap { seat in
                guard let name = seat["name"]?.text, let left = seat["left"]?.text else { return nil }
                return Seat(name: name, left: left)
            }
        }
    }

    static func problem(_ items: [ResultCard.Item]) -> String? {
        items.first { Train($0) == nil }.map { "train \($0.id) needs from, to, depart and arrive" }
    }
}

/// The trains, one row each, as 12306's list draws them. A tap on a row selects that train.
struct RailwayTrainsList: View {
    var card: ResultCard
    var selected: ResultCard.Item
    var choose: ((String) -> Void)?

    private var trains: [(id: String, train: RailwayTrains.Train)] {
        card.items.compactMap { item in RailwayTrains.Train(item).map { (item.id, $0) } }
    }

    var body: some View {
        let rows = trains
        VStack(alignment: .leading, spacing: 0) {
            header(rows.first?.train)
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 { Divider().padding(.leading, 14) }
                TrainRow(train: row.train, selected: row.id == selected.id)
                    .contentShape(.rect)
                    .onTapGesture { choose?(row.id) }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(row.id == selected.id ? [.isButton, .isSelected] : .isButton)
            }
        }
        .sensoryFeedback(.selection, trigger: selected.id)
    }

    /// The app, then the journey and its day, as 12306 heads its list.
    private func header(_ first: RailwayTrains.Train?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                AppIconView(app: card.app, size: 18, carried: "rails12306")
                Text(verbatim: AppIconStore.name(card.app) ?? card.app)
                    .font(.allo(.caption)).foregroundStyle(Color(.secondaryLabel))
            }
            if let first {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: "\(first.from) → \(first.to)").font(.allo(.headline))
                    if let date = first.date {
                        Text(verbatim: date).font(.allo(.subheadline)).foregroundStyle(Color(.secondaryLabel))
                    }
                }
                .padding(.top, 6)
            }
        }
        .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 10)
    }
}

private struct TrainRow: View {
    var train: RailwayTrains.Train
    var selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                end(train.depart, train.from, alignment: .leading)
                Spacer(minLength: 6)
                middle
                Spacer(minLength: 6)
                end(train.arrive, train.to, alignment: .trailing)
                if let price = train.price {
                    Text(verbatim: price)
                        .font(.allo(.callout, .semibold)).monospacedDigit()
                        .foregroundStyle(RailwayTrains.fare)
                        .frame(minWidth: 58, alignment: .trailing)
                }
            }
            if !train.seats.isEmpty {
                Text(verbatim: train.seats.map { "\($0.name) \($0.left)" }.joined(separator: "   "))
                    .font(.allo(.caption)).foregroundStyle(Color(.secondaryLabel))
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            if let note = train.note {
                Text(verbatim: note).font(.allo(.caption)).foregroundStyle(Color(.secondaryLabel))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(selected ? RailwayTrains.blue.opacity(0.08) : .clear)
        .overlay(alignment: .leading) {
            if selected { Rectangle().fill(RailwayTrains.blue).frame(width: 3) }
        }
        .animation(.snappy(duration: 0.2), value: selected)
    }

    private func end(_ time: String, _ station: String, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(verbatim: time).font(.alloRounded(.title3, .semibold)).monospacedDigit()
            Text(verbatim: station).font(.allo(.footnote)).foregroundStyle(Color(.secondaryLabel)).lineLimit(1)
        }
    }

    private var middle: some View {
        VStack(spacing: 2) {
            Text(verbatim: train.number).font(.allo(.subheadline, .medium))
            Capsule().fill(Color(.tertiaryLabel)).frame(width: 52, height: 1)
            if let duration = train.duration {
                Text(verbatim: duration).font(.allo(.caption2)).foregroundStyle(Color(.secondaryLabel))
            }
        }
    }
}
