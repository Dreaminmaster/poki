import Foundation
import PokiCore

struct MessageScroll {
    private struct Page {
        let bundleID: String
        let pane: String?
        let rows: [Element]
    }

    let target: Int
    private var page: Page?
    private var confirmed = 0
    private var anchor: Element?
    private var problem: Problem?
    private(set) var needsCount = false
    var started: Bool { page != nil }
    var reachedTarget: Bool { confirmed == target && !needsCount && problem == nil }
    var observedStopReason: String? { problem?.words }

    init(target: Int) { self.target = target }

    // Explicit requests can activate the completion check even if the model skips the counting tool.
    private static let targetPatterns = [
        #"\b(?:scroll|go)\s+(?:up|back)\s+(?:by\s+)?([0-9]+)\s+(?:older\s+)?messages?\b"#,
        #"(?:往上|向上|往回|向回)\s*(?:翻|滑|滚动|滾動)\s*([0-9]+)\s*(?:条|條|則)\s*(?:消息|信息|訊息)"#,
    ].map { try! NSRegularExpression(pattern: $0, options: .caseInsensitive) }

    static func requestedTarget(in request: String) -> Int? {
        let range = NSRange(request.startIndex..., in: request)
        for pattern in targetPatterns {
            if let match = pattern.firstMatch(in: request, range: range),
               let digits = Range(match.range(at: 1), in: request),
               let target = Int(request[digits]), target > 0 {
                return target
            }
        }
        return nil
    }

    mutating func actionTookPlace(error: Bool) {
        needsCount = true
        problem = error ? .actionFailed : .unreadable
    }

    mutating func rejectCompletion() -> PokiCore.ToolAnswer {
        if reachedTarget || !started { return rejected(.unreadable) }
        return progress(error: true)
    }

    func verifiedTarget(in screen: PokiCore.NumberedScreen?, pane: String?) -> Bool {
        guard reachedTarget, let page, let anchor, let screen,
              page.bundleID == screen.bundleID, page.pane == pane else { return false }
        return screen.elements.values.contains { $0.key == anchor.key && $0.frame == anchor.frame }
    }

    mutating func count(_ refs: [Int], in screen: PokiCore.NumberedScreen?, pane: String?) -> PokiCore.ToolAnswer {
        guard let screen else { return rejected(.unreadable) }
        let rows = refs.compactMap { screen.elements[$0] }
        guard !rows.isEmpty, rows.count == refs.count,
              zip(rows, rows.dropFirst()).allSatisfy({ $0.0.frame.centre.y < $0.1.frame.centre.y }) else {
            return rejected(.unreadable)
        }
        let current = Page(bundleID: screen.bundleID, pane: pane, rows: rows)
        guard let previous = page else {
            page = current
            anchor = rows.first
            needsCount = false
            problem = nil
            return progress()
        }
        guard previous.bundleID == current.bundleID, previous.pane == current.pane else {
            return rejected(.differentApp)
        }
        if rows.map(\.key) == previous.rows.map(\.key) {
            if let anchor, let index = previous.rows.firstIndex(of: anchor) { self.anchor = rows[index] }
            let stationary = zip(previous.rows, rows).allSatisfy { old, new in
                abs(old.frame.centre.y - new.frame.centre.y) < 1
            }
            page = current
            problem = needsCount && confirmed < target && stationary ? .stationary : nil
            needsCount = false
            return progress()
        }
        // An older page ends with the first rows of the previous page. Require the matching
        // rows to have moved down, so listing more refs from the same screen cannot add to the count.
        let overlaps = (1...min(previous.rows.count, rows.count)).filter { length in
            zip(previous.rows.prefix(length), rows.suffix(length)).allSatisfy { old, new in
                old.key == new.key && new.frame.centre.y > old.frame.centre.y
            }
        }
        guard overlaps.count == 1, let overlap = overlaps.first else { return rejected(.unmatched) }
        let newRows = rows.count - overlap
        let added = min(newRows, target - confirmed)
        confirmed += added
        if added > 0 { anchor = rows[newRows - added] }
        page = current
        needsCount = false
        problem = nil
        return progress()
    }

    private mutating func rejected(_ problem: Problem) -> PokiCore.ToolAnswer {
        self.problem = problem
        if !started { needsCount = true }
        if problem == .unmatched { needsCount = false }
        return progress(error: true)
    }

    func progress(error: Bool = false) -> PokiCore.ToolAnswer {
        let next = reachedTarget ? "The requested message is visible. Call finish_task." :
            problem?.instruction ?? "Use one small drag, then check the next page."
        return PokiCore.ToolAnswer(text: "Confirmed \(confirmed) of \(target) older messages. \(next)",
                                   jpeg: nil, isError: error)
    }

    func summary(success: Bool, reason: String? = nil) -> String {
        let progress = AppLocalization.text(LocalizedStringResource("I confirmed \(confirmed) of \(target) older messages."))
        let position: String
        if let anchor, !anchor.text.isEmpty {
            let text = String(anchor.text.prefix(80))
            position = AppLocalization.text(LocalizedStringResource("The last confirmed message is “\(text)”."))
        } else if anchor != nil {
            position = AppLocalization.text(LocalizedStringResource("The last confirmed message is at the top of the checked screen."))
        } else {
            position = AppLocalization.text(LocalizedStringResource("I couldn't verify a starting message."))
        }
        if success { return "\(progress) \(position)" }
        let why = reason ?? observedStopReason ??
            AppLocalization.text(LocalizedStringResource("The task ended before I could verify the requested count."))
        return "\(progress) \(position) \(why)"
    }

    private enum Problem {
        case unreadable, stationary, unmatched, differentApp, actionFailed

        var instruction: String {
            switch self {
            case .unreadable: return "Use a full screen read and submit the current message refs in top-to-bottom order."
            case .stationary: return "The list stopped moving. Check whether more history is available."
            case .unmatched: return "Couldn't match the overlap. Go back to the last verified page and try a smaller drag."
            case .differentApp: return "The app or pane changed. Return to the original conversation."
            case .actionFailed: return "The scroll could not be verified. Read the conversation again."
            }
        }

        var words: String {
            switch self {
            case .unreadable: return AppLocalization.text(LocalizedStringResource("I couldn't read the messages after the scroll."))
            case .stationary: return AppLocalization.text(LocalizedStringResource("The list stopped moving."))
            case .unmatched: return AppLocalization.text(LocalizedStringResource("I couldn't match the messages across the last scroll."))
            case .differentApp: return AppLocalization.text(LocalizedStringResource("The app or pane changed."))
            case .actionFailed: return AppLocalization.text(LocalizedStringResource("The scroll action failed."))
            }
        }
    }
}
