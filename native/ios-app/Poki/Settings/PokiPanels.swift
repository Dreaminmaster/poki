import SwiftUI

// Senses and Memory on Settings (the owner, Nov 20 2026): two taller cards side by side under Poki's
// row, each opening its panel over Settings, with a search and ask bar at the panel's foot. The cards
// are plain system cards with a soft wash of their colour, the name large, one quiet line of what is
// in them, the last update and one symbol: the reference's idea of two "places" for what Poki takes
// in and what it keeps, without its gradients, grain, capitals or monospaced type.

/// One of the two cards.
struct PokiSpaceCard: View {
    var title: LocalizedStringKey
    var detail: Text
    var date: Date?
    var symbol: String
    var tint: Color
    @ScaledMetric(relativeTo: .body) private var height: CGFloat = 148

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.title2.weight(.bold)).foregroundStyle(Color(.label)).lineLimit(1).minimumScaleFactor(0.8)
            detail.font(.footnote).foregroundStyle(Color(.secondaryLabel)).lineLimit(2)
            Spacer(minLength: 16)
            HStack(alignment: .lastTextBaseline) {
                if let date {
                    Text(date, format: .dateTime.month(.abbreviated).day().locale(AppLocalization.locale))
                        .font(.footnote).foregroundStyle(Color(.secondaryLabel))
                }
                Spacer(minLength: 8)
                Image(systemName: symbol).font(.title2.weight(.semibold)).foregroundStyle(tint)
                    .accessibilityHidden(true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: min(height, 220), alignment: .topLeading)
        .background {
            shape.fill(Color(.secondarySystemGroupedBackground))
            shape.fill(LinearGradient(colors: [tint.opacity(0.16), tint.opacity(0.03)], startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        .contentShape(shape)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// A card's panel: its page in its own navigation, over Settings, with the ask bar at its foot.
struct PokiPanel: View {
    enum Kind: String, Identifiable {
        case senses, memory
        var id: String { rawValue }
    }

    var kind: Kind
    /// Opens a conversation (a memory's Source), closing Settings.
    var openSession: (String) -> Void = { _ in }
    @State private var path = NavigationPath()
    @State private var asking = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                switch kind {
                case .memory:
                    MemoryView(back: { dismiss() }, query: $asking)
                case .senses:
                    ScreenHistorySettingsView()
                        .safeAreaInset(edge: .bottom) { PokiAskBar(text: $asking, scope: .senses) }
                }
            }
            .settingsPage()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                        .accessibilityIdentifier("panel.close")
                }
            }
            .navigationDestination(for: SettingsRoute.self) { route in
                SettingsDestination(route: route, push: { path.append($0) }, pop: { if !path.isEmpty { path.removeLast() } })
                    .settingsPage()
            }
        }
        .presentationDragIndicator(.visible)
    }
}

/// Where a question or a change typed in a panel goes.
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

/// The bar at a panel's foot: typing searches the page (Memory), sending asks Poki.
struct PokiAskBar: View {
    @Binding var text: String
    var scope: MemoryAsk.Scope
    @Environment(\.openURL) private var openURL
    @FocusState private var focused: Bool

    private var hasText: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: scope == .memory ? "magnifyingglass" : "sparkle")
                .font(.body.weight(.medium)).foregroundStyle(Color(.secondaryLabel))
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
                    Image(systemName: "arrow.up.right").font(.body.weight(.semibold)).foregroundStyle(Tint.blueText)
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
