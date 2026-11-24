import SwiftUI

/// The items of a card one row each, under the app's icon and name and, where the look has one, a
/// heading line (the journey, the hotel). The selected row is marked in the app's colour as 12306's
/// list marks it; a tap on a row selects it. Every look but 12306's draws its rows through this.
struct ResultCardList<Row: View>: View {
    var card: ResultCard
    var selected: ResultCard.Item
    var choose: ((String) -> Void)?
    /// The app's colour, for the selection mark.
    var tint: Color
    /// The icon Poki carries for the app (`Poki/AppIcons`), shown when the app is not installed.
    var carried: String?
    var heading: String?
    var subheading: String?
    /// The side of the item's picture at the start of its row, for a look whose app shows one; rows
    /// without a picture (`ResultCard.pictures`) start with their text.
    var picture: CGFloat? = nil
    @ViewBuilder var row: (ResultCard.Item) -> Row

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ForEach(Array(card.items.enumerated()), id: \.element.id) { index, item in
                if index > 0 { Divider().padding(.leading, 14) }
                let isSelected = item.id == selected.id
                HStack(alignment: .top, spacing: 10) {
                    if let picture, let data = card.pictures?[item.id] { ResultCardPicture(data: data, side: picture) }
                    row(item)
                }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    .background(isSelected ? tint.opacity(0.08) : .clear)
                    .overlay(alignment: .leading) {
                        if isSelected { Rectangle().fill(tint).frame(width: 3) }
                    }
                    .animation(.snappy(duration: 0.2), value: isSelected)
                    .contentShape(.rect)
                    .onTapGesture { choose?(item.id) }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .sensoryFeedback(.selection, trigger: selected.id)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                AppIconView(app: card.app, size: 18, carried: carried)
                Text(verbatim: AppIconStore.name(card.app) ?? card.app)
                    .font(.caption).foregroundStyle(Color(.secondaryLabel))
            }
            if let heading {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: heading).font(.headline).lineLimit(2)
                    if let subheading {
                        Text(verbatim: subheading).font(.subheadline).foregroundStyle(Color(.secondaryLabel))
                    }
                }
                .padding(.top, 6)
            }
        }
        .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 10)
    }
}

/// Small pieces the looks share.
enum ResultCardParts {
    /// Facts in one grey line, in the order given, leaving out the missing ones.
    static func line(_ parts: [String?], separator: String = "  ") -> String? {
        let present = parts.compactMap { $0 }
        return present.isEmpty ? nil : present.joined(separator: separator)
    }

    /// A grey caption line, or nothing.
    @ViewBuilder static func caption(_ text: String?, lines: Int = 2) -> some View {
        if let text {
            Text(verbatim: text).font(.caption).foregroundStyle(Color(.secondaryLabel)).lineLimit(lines)
        }
    }

    /// The first item missing one of `keys`, as a card's `problem`.
    static func missing(_ items: [ResultCard.Item], _ keys: [String], what: String) -> String? {
        for item in items {
            if let key = keys.first(where: { item.text($0) == nil }) {
                return "\(what) \(item.id) needs \(key)"
            }
        }
        return nil
    }
}
