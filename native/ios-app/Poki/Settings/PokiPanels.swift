import SwiftUI

// The ask bar on the Senses and Memory pages. It came with f1a436ae's Senses and Memory cards, which
// opened those pages as panels over Settings; the cards are gone (the owner, Nov 20 2026: Senses and
// Memory showed twice in Settings), and the bar stays at the foot of each page. Typing searches
// Memory; sending hands the words to Poki.

/// Where a question or a change typed in the ask bar goes.
enum MemoryAsk {
    enum Scope { case memory, senses }

    /// Hands `text` to Poki. Until the memory agent answers inside the panel (the Senses thread's
    /// SensesAsk, on the model the owner picks), it opens the chat with the words typed, for the owner
    /// to send.
    @MainActor static func ask(_ text: String, scope: Scope, openURL: OpenURLAction) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        var link = URLComponents()
        link.scheme = "poki"
        link.host = "chat"
        link.queryItems = [URLQueryItem(name: "text", value: clean)]
        if let url = link.url { openURL(url) }
    }
}

/// The bar at the foot of Senses and Memory: typing searches the page (Memory), sending asks Poki.
struct PokiAskBar: View {
    @Binding var text: String
    var scope: MemoryAsk.Scope
    @Environment(\.openURL) private var openURL
    @FocusState private var focused: Bool

    private var hasText: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: scope == .memory ? "magnifyingglass" : "sparkle")
                .font(.allo(.body, .medium)).foregroundStyle(Color(.secondaryLabel))
                .accessibilityHidden(true)
            Group {
                if scope == .memory {
                    TextField("Search or ask Poki", text: $text)
                } else {
                    TextField("Ask Poki", text: $text)
                }
            }
            .submitLabel(.send)
            .onSubmit(send)
            .focused($focused)
            .accessibilityIdentifier("panel.ask")
            if hasText {
                // A plain symbol in Poki's blue, not a blue ground under a white one.
                Button(action: send) {
                    Image(systemName: "arrow.up.right").font(.allo(.body, .semibold)).foregroundStyle(Tint.blueText)
                        .frame(width: 32, height: 32).contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Ask Poki"))
                .accessibilityIdentifier("panel.ask.send")
            }
        }
        .padding(.leading, 16).padding(.trailing, 8)
        .frame(minHeight: 50)
        .glassSurface(in: .capsule, fallback: .bar)
        .padding(.horizontal, 16).padding(.bottom, 8)
    }

    private func send() {
        MemoryAsk.ask(text, scope: scope, openURL: openURL)
        text = ""
        focused = false
    }
}
