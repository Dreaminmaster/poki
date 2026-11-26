import Foundation

/// What needs the owner's approval on the phone before it is sent. Words match whole words or
/// phrases, case-insensitively, in the label, value or identifier of the element an action touches: at
/// the start of the text, anywhere in a short one, or anywhere on an action button. A name inside a
/// longer text is not an action (seen on the phone: "Contact photo for Best Buy" was taken for a payment).
public struct SensitivityRules: Sendable, Equatable {
    public var secureFields = true
    public var payments: [String] = ["pay", "payment", "buy", "purchase", "subscribe", "checkout", "place order", "transfer", "send money", "confirm payment", "apple pay", "支付", "付款", "购买", "订阅", "转账", "确认支付", "下单", "購買", "訂閱", "轉賬", "轉帳", "確認支付", "下單"]
    public var deletions: [String] = ["delete", "remove", "erase", "reset", "delete all", "删除", "移除", "抹掉", "清空", "还原", "刪除", "還原"]
    public var sending: [String] = ["send", "post", "reply", "发送", "回复", "发布", "發送", "回覆", "發布"]
    /// Apps where every input needs approval (banking, wallets).
    public var guardedApps: [String] = ["com.apple.Passbook"]
    /// Words that place a call wherever they are tapped.
    public var calling: [String] = ["call", "拨打", "呼叫", "撥打"]
    /// Apps where tapping anything can place a call (a contact in Favorites or Recents rings it). FaceTime is
    /// here rather than a word: Settings lists a "FaceTime" row that places no call.
    public var callingApps: [String] = ["com.apple.mobilephone", "com.apple.facetime"]
    /// Apps where tapping a sending word needs approval.
    public var messagingApps: [String] = ["com.apple.MobileSMS", "com.apple.mobilemail", "com.tencent.xin", "net.whatsapp.WhatsApp", "ph.telegra.Telegraph", "com.burbn.instagram", "com.atebits.Tweetie2", "com.facebook.Messenger", "com.hammerandchisel.discord", "com.tinyspeck.chatlyio"]
    public var enabled = true
    public init() {}

    /// The rules a way of asking holds steps back by. Never asking lets typing a password, sending a
    /// message and placing a call go ahead; payments, deletions and Wallet still wait for the owner.
    public func asked(_ mode: ApprovalMode) -> SensitivityRules {
        guard mode == .off else { return self }
        var rules = self
        rules.secureFields = false
        rules.sending = []
        rules.messagingApps = []
        rules.calling = []
        rules.callingApps = []
        return rules
    }

    private static let actionControlTypes: Set<String> = ["Button", "MenuItem", "Link"]
    private static let lightActionTypes: Set<String> = ["Other", "Text", "StaticText"]
    private static let deleteControlTypes: Set<String> = ["Button", "MenuItem", "Cell", "Other", "StaticText", "Text", "Link"]
    private static let deleteMenuContainerTypes: Set<String> = ["Menu", "MenuBar", "MenuBarItem", "MenuItem", "Popover"]
    private static let deleteDialogContainerTypes: Set<String> = ["Alert", "Sheet", "Dialog"]
    private static let nonDialogContainerTypes: Set<String> = [
        "Application", "Window", "NavigationBar", "TabBar", "Toolbar",
        "Table", "CollectionView", "ScrollView", "WebView", "Cell", "Group",
    ]
    private static let formInputTypes: Set<String> = [
        "TextField", "SecureTextField", "SearchField", "TextView", "Switch", "Slider", "Picker",
    ]
    private static let contextContainerTokens = ["contextmenu", "actionsheet", "confirmationdialog", "alertdialog"]
    private static let cancelLabels: Set<String> = [
        "cancel", "取消", "暂不", "不删除", "保留", "keep", "don't delete", "dont delete", "not now",
    ]
    private static let confirmationPromptTokens = [
        "？", "?", "确认", "确定", "是否", "无法恢复", "永久", "confirm", "sure", "cannot be undone", "permanently", "irreversible",
    ]

    private static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.value > 0x2E80 }
    }

    private static func allowsCJKMatch(_ lowered: String, elementType: String, allowCompactCell: Bool = false) -> Bool {
        let trimmed = lowered.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isNewline) else { return false }
        let tokens = trimmed.split(whereSeparator: \.isWhitespace).count
        if actionControlTypes.contains(elementType) {
            return trimmed.count <= 32 && tokens <= 8
        }
        if lightActionTypes.contains(elementType) || (allowCompactCell && elementType == "Cell") {
            return trimmed.count <= 14 && tokens <= 4
        }
        return false
    }

    private static func isOversizedContainer(_ element: Element) -> Bool {
        let frame = element.frame
        guard !frame.isEmpty else { return false }
        if frame.width > 260 && frame.height > 260 { return true }
        if !actionControlTypes.contains(element.type), frame.height > 160 || frame.area > 60_000 {
            return true
        }
        return false
    }

    private static func isCompactDeleteTarget(_ element: Element) -> Bool {
        guard deleteControlTypes.contains(element.type) else { return false }
        let frame = element.frame
        if !frame.isEmpty, frame.height > 120 || frame.area > 45_000 { return false }
        let text = element.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = text.isEmpty ? (element.identifier ?? "").trimmingCharacters(in: .whitespacesAndNewlines) : text
        guard !label.isEmpty, !label.contains(where: \.isNewline) else { return false }
        return label.count <= 48 && label.split(whereSeparator: \.isWhitespace).count <= 6
    }

    private static func isCancelButton(_ element: Element) -> Bool {
        guard deleteControlTypes.contains(element.type) else { return false }
        let frame = element.frame
        if !frame.isEmpty, frame.height > 120 { return false }
        return [element.text, element.identifier ?? ""].contains { raw in
            let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return !normalized.isEmpty && cancelLabels.contains(normalized)
        }
    }

    private static func isConfirmationPrompt(_ element: Element) -> Bool {
        guard !actionControlTypes.contains(element.type), !formInputTypes.contains(element.type) else { return false }
        let lowered = element.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lowered.isEmpty else { return false }
        return confirmationPromptTokens.contains { lowered.contains($0) }
    }

    private static func isContextMenuOrDialogContainer(_ element: Element) -> Bool {
        if deleteMenuContainerTypes.contains(element.type) || deleteDialogContainerTypes.contains(element.type) {
            return true
        }
        if let id = element.identifier?.lowercased(),
           contextContainerTokens.contains(where: { id.contains($0) }) {
            return true
        }
        return false
    }

    private static func isInDeleteMenuOrDialog(_ element: Element, in elements: [Element]) -> Bool {
        if element.type == "MenuItem" { return true }
        guard element.node > 0 else { return false }
        let ancestors = elements
            .filter { $0.contains(element) }
            .sorted { ($0.end - $0.node, -$0.depth) < ($1.end - $1.node, -$1.depth) }
        if ancestors.contains(where: isContextMenuOrDialogContainer) { return true }
        for container in ancestors {
            if nonDialogContainerTypes.contains(container.type) { return false }
            if !container.frame.isEmpty, container.frame.height > 460 { continue }
            let inside = elements.filter { container.contains($0) }
            if inside.contains(where: { formInputTypes.contains($0.type) }) { continue }
            let textBearing = inside.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            let actionCount = inside.filter { actionControlTypes.contains($0.type) }.count
            guard textBearing.count <= 12, actionCount <= 6 else { continue }
            let hasCancel = inside.contains { sibling in
                sibling.node != element.node
                    && !sibling.contains(element)
                    && !element.contains(sibling)
                    && isCancelButton(sibling)
            }
            let hasPrompt = inside.contains { sibling in
                sibling.node != element.node
                    && !sibling.contains(element)
                    && !element.contains(sibling)
                    && isConfirmationPrompt(sibling)
            }
            if hasCancel && hasPrompt { return true }
        }
        return false
    }

    private static func matches(
        _ text: String,
        _ words: [String],
        elementType: String,
        allowCJK: Bool,
        allowCompactCellCJK: Bool
    ) -> String? {
        let lowered = text.lowercased()
        // Preserve the base matcher’s whitespace-based short-label protection for every type.
        // Long Buttons and later whole-word matches add protection to that baseline.
        let short = lowered.split(whereSeparator: \.isWhitespace).count <= 4
        let cjkAllowed = allowCJK && allowsCJKMatch(lowered, elementType: elementType, allowCompactCell: allowCompactCellCJK)
        // Explicit exception agreed for this rule: digits also bound Latin words, so buy1/1pay
        // remain unmatched even though the original matcher treated digits as boundaries.
        let boundary: (Character?) -> Bool = { c in c.map { !$0.isLetter && !$0.isNumber } ?? true }
        for word in words {
            let w = word.lowercased()
            guard !w.isEmpty else { continue }
            if containsCJK(w) {
                guard cjkAllowed, lowered.contains(w) else { continue }
                return word
            }
            var search = lowered.startIndex..<lowered.endIndex
            while let range = lowered.range(of: w, range: search) {
                let before = range.lowerBound == lowered.startIndex ? nil : lowered[lowered.index(before: range.lowerBound)]
                let after = range.upperBound == lowered.endIndex ? nil : lowered[range.upperBound]
                let opens = lowered[..<range.lowerBound].allSatisfy { !$0.isLetter && !$0.isNumber }
                if boundary(before) && boundary(after) && (elementType == "Button" || elementType == "MenuItem" || opens || short) { return word }
                // An earlier substring ("buying") must not hide a later whole word ("buy").
                search = range.upperBound..<lowered.endIndex
            }
        }
        return nil
    }

    /// Why this action needs approval, or nil.
    /// Pass `in: elements` when the full accessibility tree is known (allowing ordinary page deletes
    /// while guarding compact deletes inside menus and confirmation dialogs). Pass `in: nil` when
    /// only a label is available (such as bridged voice taps), where compact delete labels remain
    /// guarded because menu/dialog membership cannot be ruled out.
    func reason(
        touching element: Element?,
        typing: Bool,
        app: Foreground?,
        secureOnScreen: Bool,
        in elements: [Element]? = nil
    ) -> String? {
        guard enabled else { return nil }
        if let bundle = app?.bundleID, guardedApps.contains(bundle) { return "input in \(app?.describe ?? bundle)" }
        if typing, secureFields, element?.isSecure == true || (element == nil && secureOnScreen) { return "typing into a password field" }
        guard !typing else { return nil }
        guard let element else {
            // A tap in Phone rings whatever it lands on, also where nothing can be read.
            if let bundle = app?.bundleID, callingApps.contains(bundle) { return "a call (in \(app?.describe ?? bundle))" }
            return nil
        }
        let texts = [element.text, element.identifier ?? ""]
        let allowCJK = !Self.isOversizedContainer(element)
        func match(_ words: [String], allowCompactCellCJK: Bool = false) -> String? {
            texts.lazy.compactMap {
                Self.matches($0, words, elementType: element.type, allowCJK: allowCJK, allowCompactCellCJK: allowCompactCellCJK)
            }.first
        }
        if let word = match(payments) { return "a payment (\"\(word)\")" }
        let deleteRequiresApproval = elements.map { Self.isInDeleteMenuOrDialog(element, in: $0) } ?? true
        if Self.isCompactDeleteTarget(element),
           deleteRequiresApproval,
           let word = match(deletions, allowCompactCellCJK: elements != nil) {
            return "deleting (\"\(word)\")"
        }
        if let bundle = app?.bundleID, callingApps.contains(bundle) { return "a call (in \(app?.describe ?? bundle))" }
        if let word = match(calling) { return "a call (\"\(word)\")" }
        if let bundle = app?.bundleID, messagingApps.contains(bundle), let word = match(sending) {
            return "sending a message (\"\(word)\")"
        }
        return nil
    }
}

/// How a tap sent outside `do` (`PokiCore.clearTap`) may go ahead. The associated text is the rule's reason.
public enum TapClearance: Sendable, Equatable {
    /// No rule asks for approval.
    case clear
    case approved(String)
    case declined(String)
    /// Nobody answered in time, or another request replaced it.
    case unanswered(String)
    /// The tap would land in Poki, where the approval card is; the text says so for the model.
    case refused(String)

    public var mayTap: Bool {
        switch self { case .clear, .approved: true; case .declined, .unanswered, .refused: false }
    }
}

public struct Approval: Sendable, Equatable {
    public var id: String
    public var app: String
    public var summary: String
    public var reason: String
    public var requested: Date
    public var expires: Date
    /// Turning asking off (Never Ask) would stop every step this approval covers from asking: the owner
    /// can be offered Don't Ask Again. False where a payment, a deletion, Wallet or a screen not read yet
    /// would still ask.
    public var stopsWhenOff = false
    /// The outside agent's MCP session that asked, nil for Poki's own chat and voice.
    public var session: String? = nil
    /// The agent's words on what the step is for (`do`'s `intent`), nil when it gave none.
    public var intent: String? = nil
    /// What it covers: the same actions sent again on the same controls run once it is granted.
    var scope: ApprovalScope
    var workspaceSession: String?
    /// Raw source of the request, for app-level approval display/routing only.
    /// Grant ownership is deliberately unchanged; unified Core #609 handles it.
    public var sourceSession: String? = nil

    func covers(_ other: ApprovalScope, workspaceSession session: String?) -> Bool {
        workspaceSession == session && scope.covers(other)
    }
}

/// What an approval covers: the actions with the pane and app they were for, and the controls they
/// name as the read at `readAt` showed them. A control's label may differ in a later read only by a
/// countdown that ran on with the time between the two reads (`Countdown.sameControl`); a count, an
/// amount, an account or a time of day that changed is another control.
struct ApprovalScope: Sendable, Equatable {
    struct Target: Sendable, Equatable {
        var ref: Int
        var type: String
        var label: String
        var identifier: String
    }
    var actions: String
    var targets: [Target] = []
    /// When the targets were read (`now()`).
    var readAt: Double = 0

    func covers(_ other: ApprovalScope) -> Bool {
        actions == other.actions && Self.sameTargets(targets, other.targets, elapsed: other.readAt - readAt)
    }

    static func sameTargets(_ before: [Target], _ after: [Target], elapsed: Double) -> Bool {
        before.count == after.count && zip(before, after).allSatisfy { b, a in
            b.ref == a.ref && b.type == a.type && b.identifier == a.identifier
                && Countdown.sameControl(before: b.label, after: a.label, elapsed: elapsed)
        }
    }
}

/// Time readings in a label (0:59, 1:02:03, 59 s, 59 秒) and whether a change in them is a countdown
/// running on. Only the form of a reading makes it one; words around it (left, remaining, in) do not.
enum Countdown {
    /// A private-use character, so it cannot be part of a label.
    private static let mark = "\u{E000}"
    private static let reading = try! NSRegularExpression(pattern: "(?<![0-9.,:])(?:[0-9]{1,2}(?::[0-9]{2}){1,2}|[0-9]+ ?(?:s|sec|secs|seconds|秒)(?![A-Za-z]))(?![0-9:])")
    /// How far a countdown may be off the time that passed: the reads' own time and a second's rounding.
    static let slack = 2.0

    /// The label with each reading replaced by a mark, and the readings in seconds.
    static func readings(_ label: String) -> (masked: String, seconds: [Int]) {
        let ns = label as NSString
        var masked = "", seconds: [Int] = [], last = 0
        for match in reading.matches(in: label, range: NSRange(location: 0, length: ns.length)) {
            masked += ns.substring(with: NSRange(location: last, length: match.range.location - last)) + mark
            let text = ns.substring(with: match.range)
            seconds.append(text.contains(":")
                ? text.split(separator: ":").reduce(0) { $0 * 60 + (Int($1) ?? 0) }
                : Int(text.prefix { $0.isNumber }) ?? 0)
            last = match.range.location + match.range.length
        }
        return (masked + ns.substring(from: last), seconds)
    }

    /// The same control read again `elapsed` seconds later: the same text, or text whose readings
    /// that changed are each lower and went down by the time that passed, within `slack`. A reading
    /// that went up by any amount, went down faster or slower than the clock, or a time of day that
    /// moved (10:30 to 14:30) makes it another control.
    static func sameControl(before: String, after: String, elapsed: Double) -> Bool {
        guard before != after else { return true }
        let b = readings(before), a = readings(after)
        guard b.masked == a.masked else { return false }
        // One reading at a time, with its types written out: as one expression Xcode's type checker
        // gives up on it ("unable to type-check this expression in reasonable time").
        return zip(b.seconds, a.seconds).allSatisfy { (old: Int, new: Int) -> Bool in
            if old == new { return true }
            let fell = Double(old - new)
            return new < old && abs(fell - elapsed) <= slack
        }
    }
}

/// Pending and granted approvals. At most one approval is pending or granted at a time, and all
/// transitions go through `transition(_:now:)` so pending waiters and granted tickets cannot coexist.
final class Approvals: @unchecked Sendable {
    enum Decision: Sendable { case approved, declined, expired }

    private enum State {
        case idle
        case pending(approval: Approval, waiters: [UUID: CheckedContinuation<Decision?, Never>])
        case granted(approval: Approval)
    }

    private enum Event {
        case inspectPending
        case request(Approval)
        case withdraw(id: String)
        case withdrawPending
        case rekey(id: String, scope: ApprovalScope)
        case withdrawIfMismatch(scope: ApprovalScope?, workspaceSession: String?, keepingGrant: Bool)
        case discardWorkspace(session: String)
        case discardAll
        case resolve(id: String, approved: Bool)
        case consumeGrant(scope: ApprovalScope, workspaceSession: String?)
        case registerWaiter(id: String, token: UUID, continuation: CheckedContinuation<Decision?, Never>, cancelled: Bool)
        case cancelWaiter(id: String, token: UUID)
    }

    private struct Effects {
        var pending: Approval?
        var consumed: Approval?
        var immediate: (CheckedContinuation<Decision?, Never>, Decision?)?
        var resumed: [(CheckedContinuation<Decision?, Never>, Decision?)] = []
        var events: [CoreEvent] = []
    }

    private let lock = NSLock()
    private var state: State = .idle
    let lifetime: Double
    let emit: @Sendable (CoreEvent) -> Void

    init(lifetime: Double = 120, emit: @escaping @Sendable (CoreEvent) -> Void) {
        self.lifetime = lifetime
        self.emit = emit
    }

    @discardableResult
    private func apply(_ event: Event, now: Date = Date()) -> Effects {
        lock.lock()
        let effects = transition(event, now: now)
        lock.unlock()
        if let (continuation, value) = effects.immediate {
            continuation.resume(returning: value)
        }
        for (continuation, value) in effects.resumed {
            continuation.resume(returning: value)
        }
        for coreEvent in effects.events {
            emit(coreEvent)
        }
        return effects
    }

    private func expireIfNeeded(now: Date, into effects: inout Effects) {
        switch state {
        case .idle:
            break
        case .pending(let approval, let waiters) where approval.expires <= now:
            state = .idle
            effects.resumed.append(contentsOf: waiters.values.map { ($0, .expired) })
            effects.events.append(.approvalEnded(id: approval.id, approved: nil))
        case .granted(let approval) where approval.expires <= now:
            state = .idle
        case .pending, .granted:
            break
        }
    }

    private func clearCurrent(into effects: inout Effects) {
        switch state {
        case .idle:
            break
        case .pending(let old, let waiters):
            state = .idle
            effects.resumed.append(contentsOf: waiters.values.map { ($0, .expired) })
            effects.events.append(.approvalEnded(id: old.id, approved: nil))
        case .granted:
            state = .idle
        }
    }

    private func transition(_ event: Event, now: Date) -> Effects {
        var effects = Effects()
        expireIfNeeded(now: now, into: &effects)

        switch event {
        case .inspectPending:
            if case .pending(let approval, _) = state {
                effects.pending = approval
            }

        case .request(let approval):
            clearCurrent(into: &effects)
            state = .pending(approval: approval, waiters: [:])
            effects.events.append(.approvalRequested(approval))

        case .withdraw(let id):
            if case .pending(let approval, _) = state, approval.id == id {
                clearCurrent(into: &effects)
            } else if case .granted(let approval) = state, approval.id == id {
                state = .idle
            }

        case .withdrawPending:
            if case .pending = state {
                clearCurrent(into: &effects)
            }

        case .rekey(let id, let scope):
            switch state {
            case .pending(var approval, let waiters) where approval.id == id:
                approval.scope = scope
                state = .pending(approval: approval, waiters: waiters)
            case .granted(var approval) where approval.id == id:
                approval.scope = scope
                state = .granted(approval: approval)
            case .idle, .pending, .granted:
                break
            }

        case .withdrawIfMismatch(let scope, let workspaceSession, let keepingGrant):
            func matches(_ approval: Approval) -> Bool {
                scope.map { approval.covers($0, workspaceSession: workspaceSession) } ?? false
            }
            switch state {
            case .pending(let approval, _) where !matches(approval):
                clearCurrent(into: &effects)
            case .granted(let approval) where !keepingGrant && !matches(approval):
                state = .idle
            case .idle, .pending, .granted:
                break
            }

        case .discardWorkspace(let session):
            switch state {
            case .idle:
                break
            case .pending(let approval, _) where approval.workspaceSession == session:
                clearCurrent(into: &effects)
            case .granted(let approval) where approval.workspaceSession == session:
                state = .idle
            case .pending, .granted:
                break
            }

        case .discardAll:
            clearCurrent(into: &effects)

        case .resolve(let id, let approved):
            guard case .pending(let approval, let waiters) = state, approval.id == id else { break }
            let decision: Decision = approved ? .approved : .declined
            state = approved ? .granted(approval: approval) : .idle
            effects.resumed.append(contentsOf: waiters.values.map { ($0, decision) })
            effects.events.append(.approvalEnded(id: id, approved: approved))

        case .consumeGrant(let scope, let workspaceSession):
            if case .granted(let approval) = state,
               approval.covers(scope, workspaceSession: workspaceSession) {
                state = .idle
                effects.consumed = approval
            }

        case .registerWaiter(let id, let token, let continuation, let cancelled):
            switch state {
            case .pending(let approval, var waiters) where approval.id == id:
                if cancelled {
                    effects.immediate = (continuation, nil)
                } else {
                    waiters[token] = continuation
                    state = .pending(approval: approval, waiters: waiters)
                }
            case .granted(let approval) where approval.id == id:
                effects.immediate = (continuation, .approved)
            case .idle, .pending, .granted:
                effects.immediate = (continuation, .expired)
            }

        case .cancelWaiter(let id, let token):
            if case .pending(let approval, var waiters) = state, approval.id == id,
               let continuation = waiters.removeValue(forKey: token) {
                state = .pending(approval: approval, waiters: waiters)
                effects.immediate = (continuation, nil)
            }
        }

        if case .pending(let approval, _) = state {
            effects.pending = approval
        }
        return effects
    }

    var pending: Approval? {
        apply(.inspectPending).pending
    }

    /// A granted approval for these exact actions and screen context, consumed once.
    func consumeGrant(scope: ApprovalScope, workspaceSession: String? = nil) -> Approval? {
        apply(.consumeGrant(scope: scope, workspaceSession: workspaceSession)).consumed
    }

    func request(app: String, summary: String, reason: String, scope: ApprovalScope, workspaceSession: String? = nil, stopsWhenOff: Bool = false,
                 session: String? = nil, intent: String? = nil, sourceSession: String? = nil) -> Approval {
        let date = Date()
        let approval = Approval(
            id: String(UUID().uuidString.prefix(8)).lowercased(),
            app: app,
            summary: summary,
            reason: reason,
            requested: date,
            expires: date.addingTimeInterval(lifetime),
            stopsWhenOff: stopsWhenOff,
            session: session,
            intent: intent,
            scope: scope,
            workspaceSession: workspaceSession,
            sourceSession: sourceSession
        )
        apply(.request(approval), now: date)
        Task { [weak self, lifetime] in
            await sleep(seconds: lifetime + 0.05)
            _ = self?.pending
        }
        return approval
    }

    func withdraw(id: String) {
        apply(.withdraw(id: id))
    }

    /// Withdraws the request still waiting for the owner, if any. A granted approval that has not
    /// been used stays: it belongs to the agent's next `do`, not to whoever asks next.
    func withdrawPending() {
        apply(.withdrawPending)
    }

    /// Points an open request or unused grant at the actions as the agent will send them again: on
    /// their own, after the read that follows the actions sent before them.
    func rekey(id: String, scope: ApprovalScope) {
        apply(.rekey(id: id, scope: scope))
    }

    /// Withdraws a request, and unless `keepingGrant` an unused grant, for other actions than these.
    func withdrawMismatching(scope: ApprovalScope?, workspaceSession: String?, keepingGrant: Bool = false) {
        apply(.withdrawIfMismatch(scope: scope, workspaceSession: workspaceSession, keepingGrant: keepingGrant))
    }

    func discardWorkspaceDecisions(session: String?) {
        guard let session else { return }
        apply(.discardWorkspace(session: session))
    }

    func discardAll() {
        apply(.discardAll)
    }

    func resolve(id: String, approved: Bool) {
        apply(.resolve(id: id, approved: approved))
    }

    func wait(id: String, seconds: Double) async -> Decision? {
        let token = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Decision?, Never>) in
                apply(.registerWaiter(id: id, token: token, continuation: continuation, cancelled: Task.isCancelled))
                Task {
                    await sleep(seconds: seconds)
                    self.apply(.cancelWaiter(id: id, token: token))
                }
            }
        } onCancel: {
            apply(.cancelWaiter(id: id, token: token))
        }
    }
}

/// Explicit state machine for steps handed to the phone's owner (`{handoff: ...}`).
final class HandoffTracker: @unchecked Sendable {
    private enum State {
        case idle
        case waiting(Handoff)
        case completedUnread(Handoff, completedAt: Date)
    }

    enum Event {
        case inspectWaiting
        case request(id: String, kind: String, text: String, app: String?, now: Date)
        case ownerCompleted(id: String, now: Date)
        case takeBack
        case endTask
        case readLine(consumeCompleted: Bool, now: Date)
    }

    struct Outcome {
        var active: Handoff?
        var takenBack: Handoff?
        var line: String?
        var events: [CoreEvent] = []
    }

    private let lock = NSLock()
    private var state: State = .idle
    private let emit: @Sendable (CoreEvent) -> Void

    init(emit: @escaping @Sendable (CoreEvent) -> Void) {
        self.emit = emit
    }

    @discardableResult
    func apply(_ event: Event) -> Outcome {
        lock.lock()
        let outcome = transition(event)
        lock.unlock()
        for coreEvent in outcome.events {
            emit(coreEvent)
        }
        return outcome
    }

    private func transition(_ event: Event) -> Outcome {
        var outcome = Outcome()
        switch event {
        case .inspectWaiting:
            if case .waiting(let handoff) = state {
                outcome.active = handoff
            }

        case .request(let id, let kind, let text, let app, let now):
            if case .waiting(let previous) = state {
                outcome.events.append(.handoffEnded(id: previous.id, how: "replaced"))
            }
            let handoff = Handoff(id: id, kind: kind, text: text, requested: now)
            state = .waiting(handoff)
            outcome.active = handoff
            outcome.events.append(.handoffRequested(id: id, kind: kind, text: text, app: app))

        case .ownerCompleted(let id, let now):
            guard case .waiting(var handoff) = state, handoff.id == id else { break }
            handoff.done = now
            state = .completedUnread(handoff, completedAt: now)
            outcome.events.append(.handoffEnded(id: id, how: "done"))

        case .takeBack:
            guard case .waiting(let handoff) = state else { break }
            state = .idle
            outcome.takenBack = handoff
            outcome.events.append(.handoffEnded(id: handoff.id, how: "takenBack"))

        case .endTask:
            switch state {
            case .idle:
                break
            case .waiting(let handoff):
                state = .idle
                outcome.events.append(.handoffEnded(id: handoff.id, how: "taskEnded"))
            case .completedUnread:
                state = .idle
            }

        case .readLine(let consumeCompleted, let now):
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            switch state {
            case .idle:
                break
            case .waiting(let handoff):
                outcome.active = handoff
                outcome.line = "handoff: waiting (\(handoff.kind)) since \(formatter.string(from: handoff.requested)) (\(Int(now.timeIntervalSince(handoff.requested))) s): \"\(handoff.text.prefix(80))\"; no input is sent until the owner taps Done on the phone or you send {handoff: false}; keep polling with look, or {wait_until: {handoff_done: true, ms: 10000}}"
            case .completedUnread(let handoff, let completedAt):
                if consumeCompleted {
                    state = .idle
                }
                outcome.line = "handoff: done at \(formatter.string(from: completedAt)) (\(handoff.kind), \(Int(completedAt.timeIntervalSince(handoff.requested))) s after \"\(handoff.text.prefix(80))\"); inputs are sent again, go on with the task"
            }
        }
        return outcome
    }

    var active: Handoff? { apply(.inspectWaiting).active }
    var isWaiting: Bool { active != nil }
}
