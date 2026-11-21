import SwiftUI

/// The look for any app without its own (kind `list`): the app's icon and name, then one row per item
/// with its title, a line under it, the value that decides the choice (a price, a time, a score) on
/// the right, and facts that bear on the choice in grey. Neutral system colours with Poki's blue for
/// the selection, so a new app is never text only.
enum AnyAppList {
    static let kind = "list"

    static let look = ResultCardLook(problem: { _ in nil }, tint: Tint.blue, buttonShape: .roundedRectangle(radius: 10)) { card, selected, choose in
        AnyView(AnyAppRows(card: card, selected: selected, choose: choose))
    }
}

struct AnyAppRows: View {
    var card: ResultCard
    var selected: ResultCard.Item
    var choose: ((String) -> Void)?

    var body: some View {
        let first = card.items.first
        ResultCardList(card: card, selected: selected, choose: choose, tint: Tint.blue, carried: nil,
                       heading: first?.text("heading"), subheading: first?.text("subheading"), picture: 56) { item in
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: item.title).font(.allo(.body, .semibold)).lineLimit(2)
                    if let subtitle = item.text("subtitle") {
                        Text(verbatim: subtitle).font(.allo(.footnote)).foregroundStyle(Color(.secondaryLabel)).lineLimit(2)
                    }
                    ResultCardParts.caption(item.text("detail"))
                    if let legs = ResultCardLeg.legs(of: item) { ResultCardChanges(legs: legs, warning: Tint.amberInk) }
                    ResultCardParts.caption(item.text("note"))
                }
                Spacer(minLength: 0)
                if item.text("value") != nil || item.text("value_note") != nil {
                    VStack(alignment: .trailing, spacing: 2) {
                        if let value = item.text("value") {
                            Text(verbatim: value).font(.allo(.callout, .semibold)).monospacedDigit()
                        }
                        if let note = item.text("value_note") {
                            Text(verbatim: note).font(.allo(.caption2)).foregroundStyle(Color(.secondaryLabel))
                        }
                    }
                    .fixedSize()
                }
            }
        }
    }
}
