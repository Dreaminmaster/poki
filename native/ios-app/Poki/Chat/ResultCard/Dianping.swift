import SwiftUI

/// Dianping's shop list (kind `dianping.places`) as 大众点评 lists it, read off the app on the test
/// phone (Nov 18, 2026): the shop's name, its score in 点评's orange with the review count and the
/// price per person, then its category and area with the distance on the right.
enum Dianping {
    static let kind = "dianping.places"
    static let app = "com.dianping.dpscope"
    static let orange = Color(light: 0xFF6633, dark: 0xFF7A4D)

    static let look = ResultCardLook(problem: { ResultCardParts.missing($0, ["rating"], what: "place") }, tint: orange,
                                     buttonShape: .roundedRectangle(radius: 10)) { card, selected, choose in
        AnyView(DianpingPlaceList(card: card, selected: selected, choose: choose))
    }
}

struct DianpingPlaceList: View {
    var card: ResultCard
    var selected: ResultCard.Item
    var choose: ((String) -> Void)?

    var body: some View {
        ResultCardList(card: card, selected: selected, choose: choose, tint: Dianping.orange, carried: "dianping",
                       heading: card.items.first?.text("query"), subheading: nil, picture: 64) { item in
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: item.title).font(.allo(.body, .semibold)).lineLimit(1)
                if let subtitle = item.text("subtitle") {
                    Text(verbatim: subtitle).font(.allo(.footnote)).foregroundStyle(Color(.secondaryLabel)).lineLimit(1)
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let rating = item.text("rating") {
                        Text(verbatim: rating).font(.allo(.subheadline, .semibold)).monospacedDigit()
                            .foregroundStyle(Dianping.orange)
                    }
                    ResultCardParts.caption(ResultCardParts.line([item.text("reviews"), item.text("price")]), lines: 1)
                }
                HStack(alignment: .firstTextBaseline) {
                    ResultCardParts.caption(ResultCardParts.line([item.text("category"), item.text("area")]), lines: 1)
                    Spacer(minLength: 6)
                    ResultCardParts.caption(item.text("distance"), lines: 1)
                }
                ResultCardParts.caption(item.text("note"))
            }
        }
    }
}
