// MessageBubble is from Mackarous/ConversationUI (commit e77c69e,
// Sources/ConversationUI/MessageBubble.swift), Copyright (c) 2024 Andrew Mackarous, MIT License. See
// THIRD_PARTY_NOTICES.md. Changed: Poki's message kinds, the tail corner on the last bubble of a run,
// 60 pt kept free on the far side, and for ESP-326 your bubble in grey, an outside agent's in ink, and
// Poki's words without a bubble, in the system's body text.
import SwiftUI

struct MessageBubble: View {
    /// Poki's words, yours, or an outside agent's request to Poki.
    enum Direction { case incoming, outgoing, guest }
    var direction: Direction
    var text: String
    /// The last bubble of its run has the small corner on its side.
    var tail: Bool

    var body: some View {
        HStack {
            if direction != .incoming {
                Spacer(minLength: .messageInsetPadding)
            }
            if direction == .incoming {
                // Poki's words stand on the page without a bubble (ESP-326): blue is kept for what Poki
                // does on the phone, and a reply reads as text, not as a message from another person.
                Text(rendered)
                    .font(.body)
                    .tint(Tint.blueText)
                    .foregroundStyle(Color(.label))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 4)
                    .contextMenu { copyButton { UIPasteboard.general.string = text } }
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(rendered)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(direction == .guest ? Tint.onSolid : Color(.label))
                    .padding(.vertical, .messageVerticalPadding)
                    .padding(.horizontal, 14)
                    .background(direction == .guest ? Tint.solid : ChatColor.incoming, in: shape)
                    .contentShape(.contextMenuPreview, shape)
                    .contextMenu { copyButton { UIPasteboard.general.string = text } }
                    .frame(maxWidth: 300, alignment: .trailing)
            }
        }
    }

    /// Poki's words as Markdown (bold, italics, code, links), as models write them; the owner's as typed.
    private var rendered: AttributedString {
        guard direction == .incoming, text.contains(where: { "*_`[".contains($0) }),
              let markdown = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
            return AttributedString(text)
        }
        return markdown
    }

    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: .cornerRadius, bottomLeadingRadius: .cornerRadius,
                               bottomTrailingRadius: tail ? .tailRadius : .cornerRadius,
                               topTrailingRadius: .cornerRadius, style: .continuous)
    }

    private func copyButton(copy: @escaping () -> Void) -> some View {
        Button(action: copy) {
            Label("Copy", systemImage: "doc.on.doc")
        }
    }
}

extension CGFloat {
    static let cornerRadius: CGFloat = 20
    static let tailRadius: CGFloat = 6
    static let messageInsetPadding: CGFloat = 60
    static let messageVerticalPadding: CGFloat = 9
}

/// The chat's greys. The boards draw iMessage's light colours, which are iOS's own system colours, so
/// these follow them (and dark mode) instead of fixed values.
enum ChatColor {
    /// #E9E9EB on the board (iMessage's incoming bubble): systemGray5, #E5E5EA.
    static let incoming = Color(.systemGray5)
    /// #8E8E93: times, "Delivered", the grey notes, values.
    static let secondary = Color(.systemGray)
    /// #6B6B70: a step not done yet (Site.text2 on the board).
    static let pending = Color(.secondaryLabel)
    /// #34C759.
    static let green = Color(.systemGreen)
    /// #D1D1D6: the message field's edge.
    static let fieldEdge = Color(.systemGray4)
    /// #A1A1A6: the placeholder.
    static let placeholder = Color(.placeholderText)
    /// #C6C6C8: the header's bottom line and the rows' separators.
    static let separator = Color(.opaqueSeparator)
}
