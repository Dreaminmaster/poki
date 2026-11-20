import SwiftUI

/// What a result card in the chat can do: select an item and send a button's sentence. `busy` while a
/// task runs, when the buttons wait.
struct ResultCardActions {
    var busy: Bool
    var choose: @MainActor (_ entry: UUID, _ item: String) -> Void
    var say: @MainActor (String) -> Void
}

/// A result card: the app's own look for its items, then its main button and, when there is one, the
/// next step as a blue text button. Both say what they do for the selected item.
struct ResultCardView: View {
    var entry: UUID
    var card: ResultCard
    var chosen: String?
    /// Nil where the card is only shown.
    var actions: ResultCardActions?

    var body: some View {
        if let look = ResultCardLooks.all[card.kind] {
            let item = card.selected(chosen)
            VStack(alignment: .leading, spacing: 0) {
                look.body(card, item, actions.map { actions in { actions.choose(entry, $0) } })
                VStack(spacing: 4) {
                    Button { actions?.say(item.fill(card.primary.say)) } label: {
                        Text(verbatim: item.fill(card.primary.label))
                            .font(.allo(.body, .semibold))
                            .frame(maxWidth: .infinity, minHeight: 30)
                    }
                    .buttonStyle(.borderedProminent).buttonBorderShape(look.buttonShape).tint(look.tint)
                    .accessibilityIdentifier("resultCard.primary")
                    if let next = card.next {
                        Button(item.fill(next.label)) { actions?.say(item.fill(next.say)) }
                            .buttonStyle(.borderless).font(.allo(.body))
                            .frame(minHeight: 36)
                            .accessibilityIdentifier("resultCard.next")
                    }
                }
                .disabled(actions?.busy ?? true)
                .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, card.next == nil ? 14 : 4)
            }
            .contentTransition(.opacity)
            .animation(.snappy(duration: 0.2), value: item.id)
            .frame(maxWidth: 420)
            .background(Color(light: 0xFFFFFF, dark: 0x1C1C1E), in: .rect(cornerRadius: 22, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Tint.line, lineWidth: 0.5) }
            .clipShape(.rect(cornerRadius: 22, style: .continuous))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
