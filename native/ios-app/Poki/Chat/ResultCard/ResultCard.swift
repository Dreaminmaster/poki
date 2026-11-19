import Foundation
import PokiCore
import SwiftUI

/// A finished task's choices (finish_task's `card`), drawn in the look of the app they came from, under
/// the task card. The card keeps one thing of its own: which item is selected (`ChatEntry.chosen`). Its
/// buttons and their words follow from that item, and a tap sends the button's sentence as your message.
/// Progress, approvals and the Live Activity of what follows are the chat's own.
struct ResultCard: Codable, Equatable {
    var app: String
    /// Which look draws it (`ResultCardLooks`).
    var kind: String
    var items: [Item]
    /// The item Poki suggests: selected until you choose another.
    var recommended: String
    var primary: Action
    var next: Action?
    /// Each item's picture (a product's photo), JPEG, cut from the phone's screenshot where the item's
    /// `image` box points when the task finished (`ResultCardPictures`). Only items whose picture was
    /// whole on the screen have one.
    var pictures: [String: Data]?

    /// One choice. Every kind of card needs only its id and title; the rest are the app's own fields,
    /// kept as the model sent them for that app's look to read.
    struct Item: Codable, Equatable, Identifiable {
        let id: String
        let title: String
        let fields: [String: JSON]

        init(from decoder: Decoder) throws {
            fields = try [String: JSON](from: decoder)
            guard let id = fields["id"]?.text, !id.isEmpty, let title = fields["title"]?.text, !title.isEmpty else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "an item needs an id and a title"))
            }
            self.id = id
            self.title = title
        }

        func encode(to encoder: Encoder) throws { try fields.encode(to: encoder) }

        func text(_ key: String) -> String? {
            fields[key]?.text.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        }

        /// A box the model gave as [x, y, width, height] in the screenshot's points, such as `image`.
        func box(_ key: String) -> Rect? {
            guard case .array(let parts)? = fields[key], parts.count == 4 else { return nil }
            let n = parts.compactMap { part -> Double? in if case .number(let v) = part, v.isFinite { return v } else { return nil } }
            guard n.count == 4, n[2] > 0, n[3] > 0 else { return nil }
            return Rect(x: n[0], y: n[1], width: n[2], height: n[3])
        }

        /// A button's words for this item: each `{field}` becomes the item's value of it.
        func fill(_ template: String) -> String {
            template.replacing(ResultCard.field) { match in text(String(match.1)) ?? "" }
        }
    }

    /// A button: what it says, and the sentence a tap sends as your message, both for the selected item.
    struct Action: Codable, Equatable {
        var label: String
        var say: String
    }

    /// The selected item: the one you chose, or Poki's suggestion.
    func selected(_ chosen: String?) -> Item {
        items.first { $0.id == chosen } ?? items.first { $0.id == recommended } ?? items[0]
    }

    /// A `{field}` in a button's words.
    fileprivate static let field = #/\{([A-Za-z_]+)\}/#

    /// Why this card cannot be shown, for the model to answer in words instead; nil when it can.
    var problem: String? {
        guard let look = ResultCardLooks.all[kind] else {
            return "kind \(kind) has no card; use one of: \(ResultCardLooks.all.keys.sorted().joined(separator: ", "))"
        }
        guard !items.isEmpty else { return "a card needs at least one item" }
        guard Set(items.map(\.id)).count == items.count else { return "item ids must be unique" }
        guard items.contains(where: { $0.id == recommended }) else { return "recommended must be one of the item ids" }
        for action in [primary] + (next.map { [$0] } ?? []) {
            if action.label.isBlank || action.say.isBlank { return "primary and next need a label and a say" }
            // A sentence with no field would send the suggested item whichever one is selected.
            if !action.say.contains(Self.field) { return "primary.say and next.say must name the selected item with {field}, such as {title}" }
        }
        return look.problem(items)
    }

    /// The card's facts for the model when a conversation is opened again.
    func context(chosen: String?) -> String {
        let choice = selected(chosen)
        let rows = items.map { item in
            ([item.title] + item.fields.keys.sorted().filter { $0 != "id" && $0 != "title" }.compactMap { key in
                item.text(key).map { "\(key) \($0)" }
            }).joined(separator: ", ")
        }
        return "Result card (\(app)), selected \(choice.title): " + rows.joined(separator: "; ")
    }
}

/// A card's look for one kind, in the app's own style. A new kind of card is a look and a line in `all`.
struct ResultCardLook {
    /// Why these items cannot be drawn in this look (a field it needs is missing), nil when they can.
    let problem: ([ResultCard.Item]) -> String?
    /// The app's colour and button shape, for the card's main button.
    let tint: Color
    let buttonShape: ButtonBorderShape
    /// The items in the app's style, with the selected one marked; `choose` is nil where the card is
    /// only shown (an outside agent's conversation).
    let body: @MainActor (_ card: ResultCard, _ selected: ResultCard.Item, _ choose: ((String) -> Void)?) -> AnyView
}

enum ResultCardLooks {
    static let all: [String: ResultCardLook] = [
        RailwayTrains.kind: ResultCardLook(problem: RailwayTrains.problem, tint: RailwayTrains.blue, buttonShape: .roundedRectangle(radius: 8)) {
            AnyView(RailwayTrainsList(card: $0, selected: $1, choose: $2))
        },
        Ctrip.flights: Ctrip.look(Ctrip.flights),
        Ctrip.hotels: Ctrip.look(Ctrip.hotels),
        Ctrip.rooms: Ctrip.look(Ctrip.rooms),
        Ctrip.fares: Ctrip.look(Ctrip.fares),
        Taobao.kind: Taobao.look,
        Dianping.kind: Dianping.look,
        UberEats.kind: UberEats.look,
    ]
}

private extension String {
    var isBlank: Bool { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}
