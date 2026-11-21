import SwiftUI
import UIKit

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
    @State private var editing = false

    private var hasText: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: scope == .memory ? "magnifyingglass" : "sparkle")
                .font(.allo(.body, .medium)).foregroundStyle(Color(.secondaryLabel))
                .accessibilityHidden(true)
            // A UIKit field: the words reach the page (which searches as they come) only once the
            // keyboard has committed them, so Pinyin or Zhuyin still composing does not search for
            // ㄊㄠ and empty the page (the owner, Nov 20 2026: nothing may fight the keyboard).
            AskTextField(placeholder: AppLocalization.text(scope == .memory ? LocalizedStringResource("Search or ask Poki") : LocalizedStringResource("Ask Poki")),
                         text: $text, focused: $editing, onSubmit: send)
                .frame(minHeight: 34)
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
        editing = false
    }
}

/// The ask bar's field. Its text goes out only when the keyboard is not composing: a SwiftUI
/// TextField hands over the marked text too, which the Memory page then searched for.
struct AskTextField: UIViewRepresentable {
    var placeholder: String
    @Binding var text: String
    @Binding var focused: Bool
    var onSubmit: () -> Void

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.delegate = context.coordinator
        field.placeholder = placeholder
        field.font = Typeface.uiFont(.body) ?? .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.textColor = .label
        field.returnKeyType = .send
        field.clearButtonMode = .never
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.parent = self
        field.placeholder = placeholder
        // Never while composing: setting the text would commit the keyboard's pending letters.
        if field.markedTextRange == nil, field.text != text { field.text = text }
        if focused, !field.isFirstResponder {
            DispatchQueue.main.async { field.becomeFirstResponder() }
        } else if !focused, field.isFirstResponder {
            DispatchQueue.main.async { field.resignFirstResponder() }
        }
    }

    /// One line high, as wide as offered: a UIKit field otherwise takes every point it is offered.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView field: UITextField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 200, height: max(34, field.intrinsicContentSize.height))
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: AskTextField
        init(parent: AskTextField) { self.parent = parent }

        @objc func changed(_ field: UITextField) {
            guard field.markedTextRange == nil else { return }
            if parent.text != field.text ?? "" { parent.text = field.text ?? "" }
        }

        func textFieldShouldReturn(_ field: UITextField) -> Bool {
            // Return while composing belongs to the keyboard (it commits); the send waits.
            guard field.markedTextRange == nil else { return true }
            parent.text = field.text ?? ""
            parent.onSubmit()
            return false
        }

        func textFieldDidBeginEditing(_ field: UITextField) { if !parent.focused { parent.focused = true } }
        func textFieldDidEndEditing(_ field: UITextField) {
            parent.text = field.text ?? ""
            if parent.focused { parent.focused = false }
        }
    }
}
