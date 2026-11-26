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

    private static let farePattern = #/^(?:[¥￥]|RMB|CNY)?\s*([0-9]+(?:,[0-9]{3})*(?:\.[0-9]+)?)\s*(元)?\s*(起)?$/#

    /// Normalizes model-provided fare strings (such as "¥1568起", "￥1,568 起", "1568起", "¥1568") into a
    /// consistent "元起" / "元" format at render time without depending on prompt output formatting.
    static func normalizedFare(_ raw: String, preferStartingSuffix: Bool = false) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let match = trimmed.wholeMatch(of: farePattern.ignoresCase()) else { return trimmed }
        let amount = String(match.output.1).replacingOccurrences(of: ",", with: "")
        let hasYuan = match.output.2 != nil
        let hasStarting = match.output.3 != nil
        if hasStarting || (preferStartingSuffix && !hasYuan) {
            return "\(amount)元起"
        }
        return "\(amount)元"
    }
}

/// The trains, one row each, as 12306's list draws them. A tap on a row selects that train.
struct RailwayTrainsList: View {
    var card: ResultCard
    var selected: ResultCard.Item
    var choose: ((String) -> Void)?
    @State private var fareColumnWidth: CGFloat = 0

    private var trains: [(id: String, train: RailwayTrains.Train)] {
        card.items.compactMap { item in RailwayTrains.Train(item).map { (item.id, $0) } }
    }

    private var hasAnyPrice: Bool {
        trains.contains { $0.train.price != nil }
    }

    private var prefersStartingSuffix: Bool {
        trains.contains { $0.train.price?.contains("起") == true }
    }

    var body: some View {
        let rows = trains
        let sharedFareWidth = hasAnyPrice ? fareColumnWidth : 0
        let preferStarting = prefersStartingSuffix
        VStack(alignment: .leading, spacing: 0) {
            header(rows.first?.train)
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 {
                    let touchesSelection = row.id == selected.id || rows[index - 1].id == selected.id
                    Divider()
                        .padding(.horizontal, TrainRowMetrics.horizontalInset)
                        .opacity(touchesSelection ? 0 : 1)
                }
                let displayPrice = row.train.price.map {
                    RailwayTrains.normalizedFare($0, preferStartingSuffix: preferStarting)
                }
                TrainRow(
                    train: row.train,
                    displayPrice: displayPrice,
                    selected: row.id == selected.id,
                    minFareWidth: sharedFareWidth
                )
                    .contentShape(.rect)
                    .onTapGesture { choose?(row.id) }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(row.id == selected.id ? [.isButton, .isSelected] : .isButton)
            }
        }
        .onPreferenceChange(FareWidthKey.self) { width in
            if abs(fareColumnWidth - width) > 0.5 { fareColumnWidth = width }
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
        .padding(.horizontal, TrainRowMetrics.horizontalInset).padding(.top, 14).padding(.bottom, 10)
    }
}

private enum TrainRowMetrics {
    static let horizontalInset: CGFloat = 14
    static let contentHorizontalPadding: CGFloat = 10
    static let contentVerticalPadding: CGFloat = 12
    static let selectionRadius: CGFloat = 8
    static let accentWidth: CGFloat = 3
    static let minColumnGap: CGFloat = 8
    static let fareGap: CGFloat = 12
    static let rowSpacing: CGFloat = 6
    static let seatHorizontalSpacing: CGFloat = 12
    static let seatVerticalSpacing: CGFloat = 4
}

private struct FareWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private enum TrainSlot: Hashable {
    case depart, middle, arrive, price, seats, note
}

private struct TrainSlotKey: LayoutValueKey {
    static let defaultValue: TrainSlot? = nil
}

private struct TrainRow: View {
    var train: RailwayTrains.Train
    var displayPrice: String?
    var selected: Bool
    var minFareWidth: CGFloat

    var body: some View {
        TrainRowLayout(minFareWidth: minFareWidth) {
            end(train.depart, train.from, alignment: .leading)
                .layoutValue(key: TrainSlotKey.self, value: .depart)
            middle
                .layoutValue(key: TrainSlotKey.self, value: .middle)
            end(train.arrive, train.to, alignment: .trailing)
                .layoutValue(key: TrainSlotKey.self, value: .arrive)
            if let price = displayPrice {
                Text(verbatim: price)
                    .font(.allo(.callout, .semibold)).monospacedDigit()
                    .foregroundStyle(RailwayTrains.fare)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(key: FareWidthKey.self, value: proxy.size.width)
                        }
                    }
                    .layoutValue(key: TrainSlotKey.self, value: .price)
            }
            if !train.seats.isEmpty {
                SeatWrapLayout(
                    horizontalSpacing: TrainRowMetrics.seatHorizontalSpacing,
                    verticalSpacing: TrainRowMetrics.seatVerticalSpacing
                ) {
                    ForEach(Array(train.seats.enumerated()), id: \.offset) { _, seat in
                        Text(verbatim: "\(seat.name) \(seat.left)")
                            .font(.allo(.caption))
                            .foregroundStyle(Color(.secondaryLabel))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                .layoutValue(key: TrainSlotKey.self, value: .seats)
            }
            if let note = train.note {
                Text(verbatim: note)
                    .font(.allo(.caption))
                    .foregroundStyle(Color(.secondaryLabel))
                    .layoutValue(key: TrainSlotKey.self, value: .note)
            }
        }
        .padding(.horizontal, TrainRowMetrics.contentHorizontalPadding)
        .padding(.vertical, TrainRowMetrics.contentVerticalPadding)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: TrainRowMetrics.selectionRadius, style: .continuous)
                    .fill(RailwayTrains.blue.opacity(0.08))
            }
        }
        .overlay(alignment: .leading) {
            if selected {
                Rectangle()
                    .fill(RailwayTrains.blue)
                    .frame(width: TrainRowMetrics.accentWidth)
            }
        }
        .clipShape(.rect(cornerRadius: TrainRowMetrics.selectionRadius, style: .continuous))
        .padding(.horizontal, TrainRowMetrics.horizontalInset)
        .animation(.snappy(duration: 0.2), value: selected)
    }

    private func end(_ time: String, _ station: String, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(verbatim: time)
                .font(.alloRounded(.title3, .semibold)).monospacedDigit()
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Text(verbatim: station)
                .font(.allo(.footnote))
                .foregroundStyle(Color(.secondaryLabel))
                .lineLimit(1)
        }
    }

    private var middle: some View {
        VStack(spacing: 2) {
            Text(verbatim: train.number)
                .font(.allo(.subheadline, .medium))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Capsule().fill(Color(.tertiaryLabel)).frame(width: 52, height: 1)
            if let duration = train.duration {
                Text(verbatim: duration)
                    .font(.allo(.caption2))
                    .foregroundStyle(Color(.secondaryLabel))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
    }
}

/// Lays out a train row as four fixed blocks (depart, middle, arrive, fare) with a fixed gap before
/// the trailing-aligned fare column. When the four blocks do not fit without cramping or truncating
/// times, the fare moves to the trailing edge of the seats row.
private struct TrainRowLayout: Layout {
    var minFareWidth: CGFloat

    private struct Placement {
        var totalSize: CGSize
        var frames: [TrainSlot: (origin: CGPoint, proposal: ProposedViewSize)]
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? fallbackWidth(subviews: subviews)
        return compute(width: width, subviews: subviews).totalSize
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = compute(width: bounds.width, subviews: subviews)
        for subview in subviews {
            guard let slot = subview[TrainSlotKey.self], let frame = layout.frames[slot] else { continue }
            let point = CGPoint(x: bounds.minX + frame.origin.x, y: bounds.minY + frame.origin.y)
            subview.place(at: point, anchor: .topLeading, proposal: frame.proposal)
        }
    }

    private func fallbackWidth(subviews: Subviews) -> CGFloat {
        let map = slotMap(subviews)
        let departW = map[.depart]?.sizeThatFits(.unspecified).width ?? 0
        let middleW = map[.middle]?.sizeThatFits(.unspecified).width ?? 0
        let arriveW = map[.arrive]?.sizeThatFits(.unspecified).width ?? 0
        let priceW = max(map[.price]?.sizeThatFits(.unspecified).width ?? 0, minFareWidth)
        return departW + TrainRowMetrics.minColumnGap + middleW + TrainRowMetrics.minColumnGap + arriveW
            + (priceW > 0 ? TrainRowMetrics.fareGap + priceW : 0)
    }

    private func slotMap(_ subviews: Subviews) -> [TrainSlot: LayoutSubview] {
        var result: [TrainSlot: LayoutSubview] = [:]
        for subview in subviews {
            if let slot = subview[TrainSlotKey.self] { result[slot] = subview }
        }
        return result
    }

    private func compute(width: CGFloat, subviews: Subviews) -> Placement {
        let map = slotMap(subviews)
        var frames: [TrainSlot: (origin: CGPoint, proposal: ProposedViewSize)] = [:]

        let departView = map[.depart]
        let middleView = map[.middle]
        let arriveView = map[.arrive]
        let priceView = map[.price]
        let seatsView = map[.seats]
        let noteView = map[.note]

        let departIdeal = departView?.sizeThatFits(.unspecified) ?? .zero
        let middleIdeal = middleView?.sizeThatFits(.unspecified) ?? .zero
        let arriveIdeal = arriveView?.sizeThatFits(.unspecified) ?? .zero
        let priceIdeal = priceView?.sizeThatFits(.unspecified) ?? .zero
        let fareColumn = priceView != nil ? max(priceIdeal.width, minFareWidth) : minFareWidth

        let inlineFareReserve = fareColumn > 0 ? TrainRowMetrics.fareGap + fareColumn : 0
        let inlineNeeded = departIdeal.width + TrainRowMetrics.minColumnGap
            + middleIdeal.width + TrainRowMetrics.minColumnGap
            + arriveIdeal.width + inlineFareReserve
        let priceInline = fareColumn == 0 || inlineNeeded <= width

        let journeyWidth = priceInline && fareColumn > 0
            ? max(0, width - fareColumn - TrainRowMetrics.fareGap)
            : width
        let middleWidth = min(middleIdeal.width, journeyWidth)
        let endsBudget = max(0, journeyWidth - middleWidth - 2 * TrainRowMetrics.minColumnGap)

        let departWidth: CGFloat
        let arriveWidth: CGFloat
        if departIdeal.width + arriveIdeal.width <= endsBudget {
            departWidth = departIdeal.width
            arriveWidth = arriveIdeal.width
        } else {
            let half = endsBudget / 2
            if departIdeal.width <= half {
                departWidth = departIdeal.width
                arriveWidth = max(0, endsBudget - departWidth)
            } else if arriveIdeal.width <= half {
                arriveWidth = arriveIdeal.width
                departWidth = max(0, endsBudget - arriveWidth)
            } else {
                departWidth = half
                arriveWidth = max(0, endsBudget - half)
            }
        }

        let departProposal = ProposedViewSize(width: departWidth, height: nil)
        let middleProposal = ProposedViewSize(width: middleWidth, height: nil)
        let arriveProposal = ProposedViewSize(width: arriveWidth, height: nil)
        let priceProposal = ProposedViewSize(width: priceIdeal.width, height: nil)

        let departDim = departView?.dimensions(in: departProposal)
        let middleDim = middleView?.dimensions(in: middleProposal)
        let arriveDim = arriveView?.dimensions(in: arriveProposal)
        let priceDim = priceView?.dimensions(in: priceProposal)

        let departBase = departDim?[.firstTextBaseline] ?? 0
        let middleBase = middleDim?[.firstTextBaseline] ?? 0
        let arriveBase = arriveDim?[.firstTextBaseline] ?? 0
        let inlinePriceBase = priceInline ? (priceDim?[.firstTextBaseline] ?? 0) : 0
        let topBaseline = max(departBase, middleBase, arriveBase, inlinePriceBase)

        let departPlacedWidth = departDim?.width ?? 0
        let middlePlacedWidth = middleDim?.width ?? 0
        let arrivePlacedWidth = arriveDim?.width ?? 0

        let departY = topBaseline - departBase
        let middleY = topBaseline - middleBase
        let arriveY = topBaseline - arriveBase

        let minMiddleX = departPlacedWidth + TrainRowMetrics.minColumnGap
        let maxMiddleX = max(minMiddleX, journeyWidth - arrivePlacedWidth - TrainRowMetrics.minColumnGap - middlePlacedWidth)
        let idealMiddleX = (journeyWidth - middlePlacedWidth) / 2
        let middleX = min(max(idealMiddleX, minMiddleX), maxMiddleX)
        let arriveX = max(0, journeyWidth - arrivePlacedWidth)

        if departView != nil { frames[.depart] = (CGPoint(x: 0, y: departY), departProposal) }
        if middleView != nil { frames[.middle] = (CGPoint(x: middleX, y: middleY), middleProposal) }
        if arriveView != nil { frames[.arrive] = (CGPoint(x: arriveX, y: arriveY), arriveProposal) }

        var topHeight = max(
            departY + (departDim?.height ?? 0),
            middleY + (middleDim?.height ?? 0),
            arriveY + (arriveDim?.height ?? 0)
        )
        if priceInline, let priceDim {
            let priceY = topBaseline - (priceDim[.firstTextBaseline])
            let priceX = max(0, width - priceDim.width)
            frames[.price] = (CGPoint(x: priceX, y: priceY), priceProposal)
            topHeight = max(topHeight, priceY + priceDim.height)
        }

        var cursorY = topHeight
        let hasFallbackPrice = !priceInline && priceView != nil
        if seatsView != nil || hasFallbackPrice {
            cursorY += TrainRowMetrics.rowSpacing
            if hasFallbackPrice, let priceDim {
                if let seatsView {
                    let seatsBudget = max(0, width - priceDim.width - TrainRowMetrics.fareGap)
                    let seatsProposal = ProposedViewSize(width: seatsBudget, height: nil)
                    let seatsDim = seatsView.dimensions(in: seatsProposal)
                    let seatsBase = seatsDim[.firstTextBaseline]
                    let priceBase = priceDim[.firstTextBaseline]
                    let rowBase = max(seatsBase, priceBase)
                    let seatsY = cursorY + (rowBase - seatsBase)
                    let priceY = cursorY + (rowBase - priceBase)
                    frames[.seats] = (CGPoint(x: 0, y: seatsY), seatsProposal)
                    frames[.price] = (CGPoint(x: max(0, width - priceDim.width), y: priceY), priceProposal)
                    cursorY = max(seatsY + seatsDim.height, priceY + priceDim.height)
                } else {
                    frames[.price] = (CGPoint(x: max(0, width - priceDim.width), y: cursorY), priceProposal)
                    cursorY += priceDim.height
                }
            } else if let seatsView {
                let seatsProposal = ProposedViewSize(width: width, height: nil)
                let seatsSize = seatsView.sizeThatFits(seatsProposal)
                frames[.seats] = (CGPoint(x: 0, y: cursorY), seatsProposal)
                cursorY += seatsSize.height
            }
        }

        if let noteView {
            cursorY += TrainRowMetrics.rowSpacing
            let noteProposal = ProposedViewSize(width: width, height: nil)
            let noteSize = noteView.sizeThatFits(noteProposal)
            frames[.note] = (CGPoint(x: 0, y: cursorY), noteProposal)
            cursorY += noteSize.height
        }

        return Placement(totalSize: CGSize(width: width, height: cursorY), frames: frames)
    }
}

/// Flows seat availability items onto multiple lines at their natural font size without shrinking.
private struct SeatWrapLayout: Layout {
    var horizontalSpacing: CGFloat
    var verticalSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let positions = arrange(maxWidth: maxWidth, subviews: subviews)
        return positions.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let positions = arrange(maxWidth: bounds.width, subviews: subviews)
        for (subview, origin) in zip(subviews, positions.origins) {
            subview.place(
                at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                anchor: .topLeading,
                proposal: .unspecified
            )
        }
    }

    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGFloat? {
        guard guide == .firstTextBaseline, let first = subviews.first else { return nil }
        return bounds.minY + first.dimensions(in: .unspecified)[.firstTextBaseline]
    }

    private func arrange(maxWidth: CGFloat, subviews: Subviews) -> (origins: [CGPoint], size: CGSize) {
        var origins: [CGPoint] = []
        origins.reserveCapacity(subviews.count)
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var usedWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += lineHeight + verticalSpacing
                lineHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            usedWidth = max(usedWidth, x + size.width)
            lineHeight = max(lineHeight, size.height)
            x += size.width + horizontalSpacing
        }

        let totalWidth = maxWidth.isFinite ? min(maxWidth, usedWidth) : usedWidth
        let totalHeight = subviews.isEmpty ? 0 : y + lineHeight
        return (origins, CGSize(width: totalWidth, height: totalHeight))
    }
}
