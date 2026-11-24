import SwiftUI
import UIKit

/// The message field with app capsules (ESP-377). `text` is the plain text and the only
/// source: an app's name in it shows as a capsule, the capsule is one character to the caret and to
/// backspace, and reading the field gives the plain text back with the names in place.
struct CapsuleField: UIViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    var maxLines = 6
    var maxHeight: CGFloat = 200
    @Environment(\.dynamicTypeSize) private var typeSize
    /// Whether the message is scrolled away from its first line, for a swipe down on the field: that
    /// swipe scrolls the message back, it does not put the keyboard away.
    var scroll: CapsuleScroll? = nil
    /// Tracks caret offset and horizontal mention anchor without recreating the text view.
    var editorBridge: CapsuleEditorBridge? = nil
    /// An upright swipe on the field itself, true for up. The text view's own drag wins over a SwiftUI
    /// gesture around it while it has the keyboard, so the field reads the swipe itself as well.
    var onSwipe: ((Bool) -> Void)? = nil
    /// Return: the keyboard's Send key, as on the current field.
    var onMentionReady: ((Bool) -> Void)? = nil
    var onMentionCaretX: ((CGFloat?) -> Void)? = nil
    var onSubmit: () -> Void
    /// What is being written at the caret that may name an app or a connector, for the list that
    /// follows the caret; and the way to put a picked name in.
    var mentions: MentionBridge? = nil

    func makeUIView(context: Context) -> CapsuleTextView {
        let view = CapsuleTextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.font = CapsuleTextView.bodyFont
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = UIEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        view.textContainer.lineFragmentPadding = 0
        view.returnKeyType = .send
        view.enablesReturnKeyAutomatically = true
        view.isScrollEnabled = true
        view.showsVerticalScrollIndicator = false
        // No inline prediction: its grey ghost words sat under the keyboard's marked text (Pinyin
        // "Tai" over "Tailscale", the owner, Nov 20 2026), and the mention list is the field's own
        // completion. The keyboard's QuickType bar still predicts.
        if #available(iOS 17.0, *) { view.inlinePredictionType = .no }
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.accessibilityIdentifier = "capsule.field"
        view.accessibilityLabel = AppLocalization.text(LocalizedStringResource("Message Poki"))
        view.updateFont(for: UIContentSizeCategory(typeSize))
        view.setPlain(text)
        mentions?.view = view
        let swipe = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.swiped(_:)))
        swipe.delegate = context.coordinator
        swipe.cancelsTouchesInView = false
        view.addGestureRecognizer(swipe)
        return view
    }

    func updateUIView(_ view: CapsuleTextView, context: Context) {
        context.coordinator.parent = self
        mentions?.view = view
        view.updateFont(for: UIContentSizeCategory(typeSize))
        view.accessibilityLabel = AppLocalization.text(LocalizedStringResource("Message Poki"))
        // A write from outside (a recommendation, dictation, app insertion, Send emptying the field):
        // render it whole, keeping an explicit cursor target when provided. Never while the keyboard is
        // composing: an update that came with the binding a keystroke behind (the mention list appearing,
        // say) rewrote the field and committed the pending Pinyin as Latin letters ("tai" became
        // "ttaiai"). Outside writes do not happen mid-composition, and the binding catches up on the
        // next change.
        if view.markedTextRange == nil, view.plainText != text {
            if let target = editorBridge?.consumePendingCursor() {
                view.setPlain(text, cursorUTF16: target)
            } else {
                view.setPlain(text)
            }
        }
        if focused, !view.isFirstResponder {
            DispatchQueue.main.async { view.becomeFirstResponder() }
        } else if !focused, view.isFirstResponder {
            DispatchQueue.main.async { view.resignFirstResponder() }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView view: CapsuleTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 280
        let fit = view.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let font = view.font ?? CapsuleTextView.bodyFont
        let most = (font.lineHeight * CGFloat(maxLines) + view.textContainerInset.top + view.textContainerInset.bottom).rounded(.up)
        return CGSize(width: width, height: min(fit, most, max(maxHeight, font.lineHeight + view.textContainerInset.top + view.textContainerInset.bottom)))
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
        var parent: CapsuleField
        /// The message was scrolled away from its first line when the swipe began.
        private var startedScrolled = false

        init(parent: CapsuleField) { self.parent = parent }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            if text == "\n" {
                guard textView.markedTextRange == nil else { return true }
                if let view = textView as? CapsuleTextView { parent.text = view.plainText }
                parent.onSubmit()
                return false
            }
            return true
        }

        func textViewDidChange(_ textView: UITextView) {
            guard let view = textView as? CapsuleTextView else { return }
            view.reconcile()
            if parent.text != view.plainText { parent.text = view.plainText }
            parent.mentions?.update(view.mentionQuery())
            mentionReadiness(view)
        }

        /// Also when SwiftUI writes the text (inside its own update), so the report waits a turn.
        func textViewDidChangeSelection(_ textView: UITextView) {
            mentionReadiness(textView)
            guard let view = textView as? CapsuleTextView else { return }
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view else { return }
                self.parent.mentions?.update(view.mentionQuery())
            }
        }

        private var lastMentionReady: Bool?
        private var lastMentionCaretX: CGFloat?

        private func mentionReadiness(_ view: UITextView) {
            let selection = view.selectedRange
            if let capsuleView = view as? CapsuleTextView {
                parent.editorBridge?.plainCursorUTF16 = capsuleView.plainOffset(selection.location)
            }
            let ready = view.isFirstResponder && view.markedTextRange == nil &&
                selection.length == 0 && selection.location == view.textStorage.length
            let caretX: CGFloat? = if ready, let selected = view.selectedTextRange {
                view.caretRect(for: selected.start).minX.rounded()
            } else {
                nil
            }
            if ready != lastMentionReady, parent.onMentionReady != nil {
                lastMentionReady = ready
                DispatchQueue.main.async { self.parent.onMentionReady?(ready) }
            }
            if caretX != lastMentionCaretX, parent.onMentionCaretX != nil {
                lastMentionCaretX = caretX
                DispatchQueue.main.async { self.parent.onMentionCaretX?(caretX) }
            }
        }

        @objc func swiped(_ pan: UIPanGestureRecognizer) {
            guard let view = pan.view as? UITextView else { return }
            switch pan.state {
            case .began: startedScrolled = Self.scrolledDown(view)
            case .ended:
                let (move, speed) = (pan.translation(in: view), pan.velocity(in: view))
                guard abs(move.y) > abs(move.x) * 1.5 else { return }
                if move.y < -24 || speed.y < -600 { parent.onSwipe?(true) }
                if move.y > 24 || speed.y > 600, !startedScrolled { parent.onSwipe?(false) }
            default: break
            }
        }

        /// Alongside the text view's own scrolling and selection.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            parent.scroll?.scrolledDown = Self.scrolledDown(scrollView)
        }

        /// Away from the first line of a message taller than the field. A message that fits can sit a
        /// few points off (the caret's line brought into view), and that is not scrolled.
        private static func scrolledDown(_ view: UIScrollView) -> Bool {
            view.contentSize.height > view.bounds.height + 1 && view.contentOffset.y + view.adjustedContentInset.top > 1
        }

        func textViewDidBeginEditing(_ textView: UITextView) { if !parent.focused { parent.focused = true } }
        func textViewDidEndEditing(_ textView: UITextView) {
            if parent.focused { parent.focused = false }
            parent.mentions?.update(nil)
        }
    }
}

/// Between the field and the list that follows its caret: the field reports what it is writing, and
/// the list's pick goes back into the field.
@MainActor
@Observable
final class MentionBridge {
    private(set) var query: MentionQuery?
    /// The words the owner put the list away for; it stays away until other words are written.
    private var dismissed: NSRange?
    @ObservationIgnored weak var view: CapsuleTextView?

    func update(_ next: MentionQuery?) {
        if let dismissed, let next, next.range.location == dismissed.location { return }
        dismissed = nil
        if query != next { query = next }
    }

    func dismiss() {
        dismissed = query?.range
        query = nil
    }

    func pick(_ match: MentionMatch) {
        guard let query, let view else { return }
        if !match.isConnector { CapsuleText.confirm(match.insert); MentionRecents.used(match.capsule.id) }
        self.query = nil
        view.insertMention(match.insert, replacing: query.range)
    }
}

/// Where the message field is scrolled, read when a swipe on the field starts.
final class CapsuleScroll {
    var scrolledDown = false
}

/// Coordinates cursor-aware app capsule insertions with `CapsuleTextView`.
final class CapsuleEditorBridge {
    var plainCursorUTF16: Int?
    private var pendingCursorUTF16: Int?

    func scheduleCursor(_ utf16Offset: Int) {
        pendingCursorUTF16 = utf16Offset
        plainCursorUTF16 = utf16Offset
    }

    func consumePendingCursor() -> Int? {
        defer { pendingCursorUTF16 = nil }
        return pendingCursorUTF16
    }
}

final class CapsuleTextView: UITextView {
    /// Allo Text at the body style, as the chat writes; the system font if it did not load.
    static func textFont(compatibleWith traits: UITraitCollection? = nil) -> UIFont {
        Typeface.uiFont(.body, compatibleWith: traits) ?? .preferredFont(forTextStyle: .body, compatibleWith: traits)
    }
    static var bodyFont: UIFont { textFont() }
    private var requestedCategory: UIContentSizeCategory?
    private var needsFontRefresh = false

    func updateFont(for category: UIContentSizeCategory) {
        requestedCategory = category
        refreshFont()
    }

    private func refreshFont() {
        guard markedTextRange == nil else { needsFontRefresh = true; return }
        let traits = traitCollection.modifyingTraits {
            $0.preferredContentSizeCategory = requestedCategory ?? traitCollection.preferredContentSizeCategory
        }
        let next = Self.textFont(compatibleWith: traits)
        guard needsFontRefresh || font != next else { return }
        needsFontRefresh = false
        font = next
        redraw()
        invalidateIntrinsicContentSize()
    }

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        // The pills are pictures drawn for one appearance and one text size: draw them again.
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitPreferredContentSizeCategory.self]) { (view: CapsuleTextView, _: UITraitCollection) in
            view.needsFontRefresh = true
            view.refreshFont()
        }
        // An icon arrived or the installed apps changed: the capsules are pictures, so they are made again.
        iconsChanged = NotificationCenter.default.addObserver(forName: AppIconStore.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.redraw() }
        }
    }

    nonisolated(unsafe) private var iconsChanged: (any NSObjectProtocol)?

    deinit {
        if let iconsChanged { NotificationCenter.default.removeObserver(iconsChanged) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Not implemented") }

    override var keyCommands: [UIKeyCommand]? {
        let newline = UIKeyCommand(input: "\r", modifierFlags: .shift, action: #selector(insertLineBreak))
        newline.wantsPriorityOverSystemBehavior = true
        return (super.keyCommands ?? []) + [newline]
    }

    @objc private func insertLineBreak(_ command: UIKeyCommand) {
        guard markedTextRange == nil, let selection = selectedTextRange else { return }
        replace(selection, withText: "\n")
        delegate?.textViewDidChange?(self)
    }

    private var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: font ?? Self.bodyFont, .foregroundColor: UIColor.label]
    }

    /// The field's text with each capsule read back as the words it stands for.
    var plainText: String { Self.plain(textStorage, in: NSRange(location: 0, length: textStorage.length)) }

    /// Replaces everything with `plain`, placing the caret at `cursorUTF16` (or the end when nil).
    func setPlain(_ plain: String, cursorUTF16: Int? = nil) {
        textStorage.setAttributedString(render(CapsuleText.segments(plain)))
        if let cursorUTF16 {
            let clamped = max(0, min(cursorUTF16, plain.utf16.count))
            selectedRange = NSRange(location: storageOffset(clamped), length: 0)
        } else {
            selectedRange = NSRange(location: textStorage.length, length: 0)
        }
        typingAttributes = baseAttributes
    }

    /// After every edit: names that are now whole become capsules, and capsules whose words are no
    /// longer a name (a letter typed against them) become text again. Nothing changes while the
    /// keyboard is still composing (Pinyin before it commits), so the composition is never disturbed.
    func reconcile() {
        guard markedTextRange == nil else { return }
        if needsFontRefresh { refreshFont() }
        let wanted = CapsuleText.segments(plainText)
        guard wanted != segments() else { return }
        replaceKeepingSelection(with: wanted)
    }

    private func redraw() {
        guard markedTextRange == nil else { return }
        replaceKeepingSelection(with: CapsuleText.segments(plainText))
    }

    private func replaceKeepingSelection(with wanted: [CapsuleText.Segment]) {
        let selection = selectedRange
        let start = plainOffset(selection.location)
        let end = plainOffset(selection.location + selection.length)
        textStorage.beginEditing()
        textStorage.setAttributedString(render(wanted))
        textStorage.endEditing()
        let from = storageOffset(start), to = storageOffset(end)
        selectedRange = NSRange(location: from, length: max(0, to - from))
        typingAttributes = baseAttributes
    }

    // MARK: Plain text in and out

    private func render(_ segments: [CapsuleText.Segment]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let font = font ?? Self.bodyFont
        for segment in segments {
            switch segment {
            case .text(let text):
                out.append(NSAttributedString(string: text, attributes: baseAttributes))
            case .app(let app, let text):
                let pill = PillTextAttachment(pillData: PillTextAttachmentData(app: app, text: text, font: font), traits: traitCollection)
                let one = NSMutableAttributedString(attachment: pill)
                one.addAttributes(baseAttributes, range: NSRange(location: 0, length: one.length))
                out.append(one)
            }
        }
        return out
    }

    private func segments() -> [CapsuleText.Segment] {
        var out: [CapsuleText.Segment] = []
        let string = textStorage.string as NSString
        textStorage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: textStorage.length)) { value, range, _ in
            if let pill = value as? PillTextAttachment {
                out.append(.app(pill.pillData.app, pill.pillData.text))
            } else if case .text(let before)? = out.last {
                out[out.count - 1] = .text(before + string.substring(with: range))
            } else {
                out.append(.text(string.substring(with: range)))
            }
        }
        return out
    }

    static func plain(_ storage: NSAttributedString, in range: NSRange) -> String {
        var out = ""
        let string = storage.string as NSString
        storage.enumerateAttribute(.attachment, in: range) { value, run, _ in
            if let pill = value as? PillTextAttachment {
                out += pill.pillData.text
            } else {
                out += string.substring(with: run)
            }
        }
        return out
    }

    /// Where a position in the field falls in the plain text.
    func plainOffset(_ location: Int) -> Int {
        Self.plain(textStorage, in: NSRange(location: 0, length: min(location, textStorage.length))).utf16.count
    }

    /// Where a position in the plain text falls in the field; inside a capsule's words, after the capsule.
    private func storageOffset(_ plain: Int) -> Int {
        var seen = 0
        var result = textStorage.length
        textStorage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: textStorage.length)) { value, run, stop in
            let length = (value as? PillTextAttachment)?.pillData.text.utf16.count ?? run.length
            if plain <= seen + length {
                if let _ = value as? PillTextAttachment {
                    result = plain == seen ? run.location : run.location + 1
                } else {
                    result = run.location + (plain - seen)
                }
                stop.pointee = true
                return
            }
            seen += length
        }
        return result
    }

    // MARK: Mentions

    /// The words at the caret, with the keyboard's pending text, and where the caret is on screen.
    func mentionQuery() -> MentionQuery? {
        guard isFirstResponder, selectedRange.length == 0, let caretPosition = selectedTextRange?.end else { return nil }
        // Right after a capsule its words are already a name: no list (淘宝 just picked offered
        // Ele.me, whose other name begins with it).
        if selectedRange.location > 0, markedTextRange == nil,
           textStorage.attribute(.attachment, at: selectedRange.location - 1, effectiveRange: nil) is PillTextAttachment { return nil }
        let caretPlain = plainOffset(selectedRange.location)
        let before = String((plainText as NSString).substring(to: min(caretPlain, (plainText as NSString).length)))
        let pendingStart = markedTextRange.map { plainOffset(offset(from: beginningOfDocument, to: $0.start)) }
        guard let found = MentionSearch.query(before: before, pendingStart: pendingStart) else { return nil }
        let caret = caretRect(for: caretPosition).offsetBy(dx: -contentOffset.x, dy: -contentOffset.y)
        return MentionQuery(text: found.text, range: NSRange(location: found.start, length: caretPlain - found.start),
                            caret: caret, pending: pendingStart != nil, explicit: found.explicit)
    }

    /// Puts a picked name where its words were: the keyboard's composition is ended first (its pending
    /// letters are replaced, never left behind), then the words give way to the name, which becomes its
    /// capsule, and a space follows a name of a spaced script.
    func insertMention(_ name: String, replacing range: NSRange) {
        if markedTextRange != nil {
            inputDelegate?.textWillChange(self)
            unmarkText()
            inputDelegate?.textDidChange(self)
        }
        let from = storageOffset(range.location), to = storageOffset(range.location + range.length)
        guard let start = position(from: beginningOfDocument, offset: from),
              let end = position(from: beginningOfDocument, offset: max(from, to)),
              let target = textRange(from: start, to: end) else { return }
        let spaced = !name.unicodeScalars.contains(where: CapsuleText.isUnspaced)
        replace(target, withText: spaced ? name + " " : name)
        delegate?.textViewDidChange?(self)
    }

    // MARK: Copy, cut and paste carry plain text

    override func copy(_ sender: Any?) {
        guard selectedRange.length > 0 else { return }
        UIPasteboard.general.string = Self.plain(textStorage, in: selectedRange)
    }

    override func cut(_ sender: Any?) {
        guard selectedRange.length > 0, let range = selectedTextRange else { return }
        copy(sender)
        replace(range, withText: "")
        delegate?.textViewDidChange?(self)
    }

    override func paste(_ sender: Any?) {
        guard let string = UIPasteboard.general.string, let range = selectedTextRange else { return }
        replace(range, withText: string)
        delegate?.textViewDidChange?(self)
    }

    override var accessibilityValue: String? {
        get { plainText }
        set {}
    }
}
