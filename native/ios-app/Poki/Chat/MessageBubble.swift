// MessageBubble is from Mackarous/ConversationUI (commit e77c69e,
// Sources/ConversationUI/MessageBubble.swift), Copyright (c) 2024 Andrew Mackarous, MIT License. See
// THIRD_PARTY_NOTICES.md. Changed: Poki's message kinds, the tail corner on the last bubble of a run,
// 60 pt kept free on the far side, and the colours: an outside agent's request in ink, and for
// ESP-376 your bubble in Poki's blue and Poki's words in a white bubble with a soft shadow; in your
// bubble the apps you named show as capsules, as in the message field.
import SwiftUI
import UIKit

struct MessageBubble: View {
    /// Poki's words, yours, or an outside agent's request to Poki.
    enum Direction { case incoming, outgoing, guest }
    var direction: Direction
    var text: String
    /// The last bubble of its run has the small corner on its side.
    var tail: Bool
    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack {
            if direction != .incoming {
                Spacer(minLength: .messageInsetPadding)
            }
            if direction == .incoming {
                Text(rendered)
                    .font(.body)
                    .tint(Tint.blueText)
                    .foregroundStyle(Color(.label))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, .messageVerticalPadding)
                    .padding(.horizontal, .messageHorizontalPadding)
                    .pokiBubble(tail: tail)
                    .contextMenu { copyButton { UIPasteboard.general.string = text } }
                Spacer(minLength: .messageInsetPadding)
            } else {
                (direction == .outgoing ? withCapsules : Text(rendered))
                    .font(.body)
                    .accessibilityLabel(Text(verbatim: text))
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(direction == .guest ? Tint.onSolid : Color.white)
                    .padding(.vertical, .messageVerticalPadding)
                    .padding(.horizontal, .messageHorizontalPadding)
                    .background(direction == .guest ? Tint.solid : Tint.blue, in: shape)
                    // The bubble is one flat layer with its own outline, so the lifted copy of it (the
                    // long press) is cut to the same outline and the small corner stays where it is.
                    .clipShape(shape)
                    .compositingGroup()
                    .contentShape(.contextMenuPreview, shape)
                    .contentShape(.interaction, shape)
                    .contextMenu { copyButton { UIPasteboard.general.string = text } }
                    .frame(maxWidth: 320, alignment: .trailing)
            }
        }
        .transaction { if direction == .incoming { $0.animation = nil } }
    }

    private var rendered: AttributedString {
        direction == .incoming ? AnswerMarkdown.render(text) : AttributedString(text)
    }

    /// Your words with each app's name as its capsule; the words themselves are what was sent, and
    /// what Copy copies.
    private var withCapsules: Text {
        let segments = CapsuleText.segments(text)
        guard segments.contains(where: { if case .app = $0 { true } else { false } }) else { return Text(rendered) }
        let font = UIFont.preferredFont(forTextStyle: .body)
        return segments.reduce(Text(verbatim: "")) { line, segment in
            switch segment {
            case .text(let words):
                return line + Text(verbatim: words)
            case .app(let app, let words):
                let data = PillTextAttachmentData(app: app, text: words, font: font, onAccent: true)
                guard let image = PillView.image(data, scale: displayScale, dark: scheme == .dark) else { return line + Text(verbatim: words) }
                return line + Text(Image(uiImage: image)).baselineOffset(data.baselineOffset)
            }
        }
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

@MainActor
private enum AnswerMarkdown {
    private static let pendingLink = URL(string: "poki-pending-link:")!
    /// Each answer is parsed once: the conversation redraws on every key typed in the message field.
    private static var cache: [String: AttributedString] = [:]

    static func render(_ source: String) -> AttributedString {
        if let done = cache[source] { return done }
        let result = parse(source)
        if cache.count >= 300 { cache.removeAll(keepingCapacity: true) }
        cache[source] = result
        return result
    }

    private static func parse(_ source: String) -> AttributedString {
        let source = stableMarkdown(source)
        guard let parsed = try? AttributedString(markdown: source, options: .init(interpretedSyntax: .full)) else {
            return AttributedString(source)
        }
        var result = AttributedString()
        var block: Int?
        var lastItem: Int?
        for run in parsed.runs {
            let components = run.presentationIntent?.components ?? []
            let identity = components.first?.identity
            var piece = AttributedString(parsed[run.range])
            piece.presentationIntent = nil
            if identity != block {
                if !result.characters.isEmpty { result.append(AttributedString("\n")) }
                block = identity
                let lists = components.filter {
                    switch $0.kind { case .orderedList, .unorderedList: true; default: false }
                }
                if let item = components.first(where: { if case .listItem = $0.kind { true } else { false } }) {
                    result.append(AttributedString(String(repeating: "  ", count: max(0, lists.count - 1))))
                    if item.identity != lastItem, case .listItem(let ordinal) = item.kind {
                        let ordered = lists.first.map { if case .orderedList = $0.kind { true } else { false } } ?? false
                        result.append(AttributedString(ordered ? "\(ordinal). " : "• "))
                    }
                    lastItem = item.identity
                } else {
                    lastItem = nil
                }
                if components.contains(where: { if case .blockQuote = $0.kind { true } else { false } }) {
                    result.append(AttributedString("▎ "))
                }
            }
            for component in components {
                switch component.kind {
                case .header:
                    piece.font = .body.weight(.semibold)
                case .codeBlock:
                    piece.font = .body.monospaced()
                case .blockQuote:
                    piece.foregroundColor = .secondary
                case .thematicBreak:
                    piece = AttributedString("────────")
                    piece.foregroundColor = .secondary
                default: break
                }
            }
            if run.inlinePresentationIntent?.contains(.code) == true { piece.font = .body.monospaced() }
            if run.link == pendingLink {
                piece.link = nil
                piece.foregroundColor = Tint.blueText
            }
            result.append(piece)
        }
        return result
    }

    private static func stableMarkdown(_ source: String) -> String {
        var fence: String?
        return source.components(separatedBy: "\n").map { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let open = fence {
                if trimmed.hasPrefix(open), trimmed.dropFirst(open.count).allSatisfy(\.isWhitespace) {
                    fence = nil
                } else if !trimmed.isEmpty, trimmed.count < open.count, trimmed.allSatisfy({ $0 == open.first }) {
                    return ""
                }
                return line
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                fence = String(trimmed.prefix(while: { $0 == trimmed.first }))
                return line
            }
            if trimmed.hasPrefix("|") {
                let cells = trimmed.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                if cells.allSatisfy({ $0.allSatisfy { "-: ".contains($0) } }) { return "" }
                return cells.filter { !$0.isEmpty }.map(stableInline).joined(separator: "  ·  ") + "  "
            }
            if ["-", "--", "+", "`", "``", "~", "~~"].contains(trimmed) { return "" }
            if trimmed.count >= 3, trimmed.allSatisfy({ $0 == "*" || $0 == "_" || $0 == " " }) {
                return line
            }
            return stableInline(line)
        }.joined(separator: "\n")
    }

    private struct Delimiter {
        var character: Character
        var count: Int
        var text: String { String(repeating: String(character), count: count) }
    }

    // Complete only the display copy. The next token must not turn literal markers into styled words.
    private static func stableInline(_ source: String) -> String {
        let chars = Array(source)
        var result = ""
        var open: [Delimiter] = []
        var code: Int?
        var i = 0
        while i < chars.count {
            let char = chars[i]
            if let count = code {
                if char == "`" {
                    let end = chars[i...].prefix(while: { $0 == char }).count + i
                    if end - i == count { code = nil }
                    if end == chars.count, end - i < count { break }
                    result += String(chars[i..<end])
                    i = end
                } else {
                    result.append(char)
                    i += 1
                }
                continue
            }
            if char == "\\" {
                if i + 1 < chars.count { result += String(chars[i...i + 1]); i += 2 } else { i += 1 }
                continue
            }
            if char == "[" || (char == "!" && i + 1 < chars.count && chars[i + 1] == "[") {
                let start = i + (char == "!" ? 2 : 1)
                let close = chars[start...].firstIndex(of: "]")
                let label = String(chars[start..<(close ?? chars.count)])
                if let close, close + 1 < chars.count, chars[close + 1] == "(" {
                    var depth = 1
                    var end = close + 2
                    while end < chars.count, depth > 0 {
                        if chars[end] == "(" { depth += 1 }
                        if chars[end] == ")" { depth -= 1 }
                        end += 1
                    }
                    if depth == 0 {
                        result += "[" + stableInline(label) + String(chars[close..<end])
                        i = end
                        continue
                    }
                }
                if !label.isEmpty { result += "[" + stableInline(label) + "](\(pendingLink.absoluteString))" }
                i = close.map { $0 + 1 } ?? chars.count
                if i < chars.count, chars[i] == "(" { i = chars.count }
                continue
            }
            if char == "`" || char == "*" || char == "_" {
                let end = chars[i...].prefix(while: { $0 == char }).count + i
                let count = end - i
                if char == "_", i > 0, chars[i - 1].isLetter || chars[i - 1].isNumber,
                   end < chars.count, chars[end].isLetter || chars[end].isNumber {
                    result += String(chars[i..<end]); i = end; continue
                }
                if char == "`" {
                    if end < chars.count { code = count; result += String(chars[i..<end]) }
                } else if let last = open.last, last.character == char, i > 0, !chars[i - 1].isWhitespace {
                    if count >= last.count {
                        result += last.text
                        open.removeLast()
                        if count > last.count, end < chars.count {
                            let extra = Delimiter(character: char, count: count - last.count)
                            result += extra.text
                            open.append(extra)
                        }
                    } else if end < chars.count {
                        result += String(chars[i..<end])
                    }
                } else if end < chars.count, !chars[end].isWhitespace {
                    let delimiter = Delimiter(character: char, count: count)
                    result += delimiter.text
                    open.append(delimiter)
                } else if end < chars.count {
                    result += String(chars[i..<end])
                }
                i = end
                continue
            }
            result.append(char)
            i += 1
        }
        if let code { result += String(repeating: "`", count: code) }
        for delimiter in open.reversed() { result += delimiter.text }
        return result
    }
}

extension CGFloat {
    static let cornerRadius: CGFloat = 22
    static let tailRadius: CGFloat = 7
    static let messageInsetPadding: CGFloat = 60
    static let messageVerticalPadding: CGFloat = 13
    static let messageHorizontalPadding: CGFloat = 18
}

extension View {
    /// Poki's bubble (ESP-376): the card's white with a soft shadow in light; in dark the card's grey
    /// with a hairline, where a shadow does not show. The small corner sits on Poki's side.
    func pokiBubble(tail: Bool) -> some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: .cornerRadius, bottomLeadingRadius: tail ? .tailRadius : .cornerRadius,
                                           bottomTrailingRadius: .cornerRadius, topTrailingRadius: .cornerRadius, style: .continuous)
        return background(Color(.secondarySystemGroupedBackground), in: shape)
            .overlay(shape.strokeBorder(Tint.ring.opacity(0.5), lineWidth: 0.5))
            // One flat layer cut to its outline (as your bubble), under the shadow.
            .clipShape(shape)
            .compositingGroup()
            .shadow(color: Tint.bubbleShadow, radius: 6, y: 2)
            .contentShape(.contextMenuPreview, shape)
            .contentShape(.interaction, shape)
    }
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
