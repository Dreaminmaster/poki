import SwiftUI

/// Taobao's search results (kind `taobao.products`) as 淘宝 lists them, read off the app on the test
/// phone (Nov 18, 2026): the product's title over two lines, the price large in 淘宝's orange with the
/// kind of price beside it (补贴价, 优惠后), how many have paid, then the shop and delivery in grey.
enum Taobao {
    static let kind = "taobao.products"
    static let app = "com.taobao.taobao4iphone"
    static let orange = Color(light: 0xFF5000, dark: 0xFF6A26)

    static let look = ResultCardLook(problem: { ResultCardParts.missing($0, ["price"], what: "product") }, tint: orange,
                                     buttonShape: .capsule) { card, selected, choose in
        AnyView(TaobaoProductList(card: card, selected: selected, choose: choose))
    }
}

struct TaobaoProductList: View {
    var card: ResultCard
    var selected: ResultCard.Item
    var choose: ((String) -> Void)?

    var body: some View {
        ResultCardList(card: card, selected: selected, choose: choose, tint: Taobao.orange, carried: "taobao",
                       heading: card.items.first?.text("query"), subheading: nil, picture: 88) { item in
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: item.title).font(.allo(.subheadline)).lineLimit(2)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: item.text("price") ?? "")
                        .font(.alloRounded(.title3, .semibold)).monospacedDigit()
                        .foregroundStyle(Taobao.orange)
                    if let label = item.text("price_label") {
                        Text(verbatim: label).font(.allo(.caption)).foregroundStyle(Taobao.orange)
                    }
                    if let sold = item.text("sold") {
                        Text(verbatim: sold).font(.allo(.caption)).foregroundStyle(Color(.secondaryLabel)).lineLimit(1)
                    }
                }
                ResultCardParts.caption(ResultCardParts.line([item.text("shop"), item.text("delivery")]), lines: 1)
                ResultCardParts.caption(item.text("note"))
            }
        }
    }
}
