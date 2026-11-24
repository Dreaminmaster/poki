import SwiftUI

/// A store's menu items on Uber Eats (kind `ubereats.items`), read off the app on the test phone
/// (Nov 18, 2026): the item's name, its price, and what comes with it in grey, under the store's name.
enum UberEats {
    static let kind = "ubereats.items"
    static let app = "com.ubercab.UberEats"
    static let green = Color(light: 0x06C167, dark: 0x06C167)

    static let look = ResultCardLook(problem: { ResultCardParts.missing($0, ["price"], what: "item") }, tint: green,
                                     buttonShape: .capsule) { card, selected, choose in
        AnyView(UberEatsItemList(card: card, selected: selected, choose: choose))
    }
}

struct UberEatsItemList: View {
    var card: ResultCard
    var selected: ResultCard.Item
    var choose: ((String) -> Void)?

    var body: some View {
        ResultCardList(card: card, selected: selected, choose: choose, tint: UberEats.green, carried: "uber-eats",
                       heading: card.items.first?.text("store"), subheading: nil, picture: 64) { item in
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: item.title).font(.body.weight(.medium)).lineLimit(2)
                Text(verbatim: item.text("price") ?? "").font(.subheadline).monospacedDigit()
                ResultCardParts.caption(ResultCardParts.line([item.text("detail"), item.text("calories")]))
                ResultCardParts.caption(item.text("note"))
            }
        }
    }
}
