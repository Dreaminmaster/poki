import Foundation
import PokiCore

struct MessageScroll {
    private struct Page {
        let bundleID: String
        let pane: String?
        let rows: [Element]
    }

    private enum Recovery {
        case returning(distance: Double)
        case retrying(distance: Double)
        case exhausted
    }

    let target: Int
    private var page: Page?
    private var confirmed = 0
    private var anchor: Element?
    private var problem: Problem?
    private var dragTravel: Double? = 0
    private var recovery: Recovery?
    private(set) var needsCount = false
    var started: Bool { page != nil }
    var reachedTarget: Bool { confirmed == target && !needsCount && problem == nil }
    var observedStopReason: String? { problem?.words }

    init(target: Int) { self.target = target }

    // Explicit requests can activate the completion check even if the model skips the counting tool.
    private static let targetPatterns = [
        #"\b(?:scroll|go)\s+(?:up|back)\s+(?:by\s+)?([0-9]+)\s+(?:older\s+)?messages?\b"#,
        #"\bscroll\s+([0-9]+)\s+(?:older\s+)?messages?\s+(?:up|back)\b"#,
        #"(?:往上|向上|往回|向回)\s*(?:翻|滑动|滑動|滑|滚动|滾動)\s*([0-9]+)\s*(?:条|條|則)(?:\s*(?:消息|信息|訊息))?"#,
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

    func boundedDrag(_ drag: Any?) -> (action: [String: Any], distance: Double)? {
        guard let page, page.rows.count >= 2 else { return nil }
        let points: [Double]
        if let coordinates = drag as? [Double], coordinates.count == 4 {
            points = coordinates
        } else if let action = drag as? [String: Any], action["to_pane"] == nil,
                  let from = action["from"] as? [Double], from.count == 2,
                  let to = action["to"] as? [Double], to.count == 2 {
            points = from + to
        } else {
            return nil
        }
        guard points.allSatisfy(\.isFinite), abs(points[2] - points[0]) <= 2,
              let first = page.rows.first, let last = page.rows.last else { return nil }
        let down = points[3] - points[1]
        let span = last.frame.centre.y - first.frame.centre.y
        let limit: Double
        switch recovery {
        case .returning(let distance):
            guard down < 0 else { return nil }
            limit = distance
        case .retrying(let distance):
            guard down > 0 else { return nil }
            limit = distance
        case .exhausted:
            return nil
        case nil:
            guard down > 0 else { return nil }
            limit = abs(down) >= span ? span / 2 : span * 2 / 3
        }
        let distance = min(abs(down), limit).rounded(.down)
        guard distance >= 12 else { return nil }
        let low = first.frame.centre.y
        let high = last.frame.centre.y
        let from = down > 0 ? min(max(points[1], low), high - distance) :
            min(max(points[1], low + distance), high)
        let signed = down > 0 ? distance : -distance
        let milliseconds = (drag as? [String: Any])?["ms"] as? Double ?? 700
        guard milliseconds.isFinite else { return nil }
        let action: [String: Any] = ["from": [points[0], from], "to": [points[0], from + signed],
                                     "ms": min(1500, max(500, milliseconds)), "_counted_scroll": true]
        return (["drag": action], signed)
    }

    mutating func actionTookPlace(error: Bool, distance: Double?) {
        needsCount = true
        problem = error ? .actionFailed : .unreadable
        dragTravel = error ? nil : distance
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
            dragTravel = 0
            return progress()
        }
        guard previous.bundleID == current.bundleID, previous.pane == current.pane else {
            return rejected(.differentApp)
        }
        let positionTolerance = 2.0
        let samePage = previous.rows.count == rows.count && zip(previous.rows, rows).allSatisfy { old, new in
            old.key == new.key && old.identifier == new.identifier &&
            abs(old.frame.centre.x - new.frame.centre.x) <= positionTolerance &&
            abs(old.frame.centre.y - new.frame.centre.y) <= positionTolerance
        }
        if case .exhausted = recovery { return rejected(.unmatched) }
        if case .returning(let distance) = recovery {
            guard let dragTravel, dragTravel < 0, samePage else { return rejected(.unmatched) }
            if let anchor, let index = previous.rows.firstIndex(of: anchor) { self.anchor = rows[index] }
            page = current
            recovery = .retrying(distance: distance / 2)
            needsCount = false
            problem = nil
            self.dragTravel = 0
            return progress()
        }
        // When the bounded drag could have moved past the old page, neither text nor spacing can prove overlap.
        let span = rows[rows.count - 1].frame.centre.y - previous.rows[0].frame.centre.y
        guard let dragTravel, dragTravel + positionTolerance < span else { return rejected(.unmatched) }
        if samePage {
            if let anchor, let index = previous.rows.firstIndex(of: anchor) { self.anchor = rows[index] }
            page = current
            if needsCount, confirmed < target { problem = .stationary }
            needsCount = false
            self.dragTravel = 0
            if case .retrying = recovery { recovery = .exhausted }
            return progress()
        }
        guard let overlap = Self.overlap(between: previous.rows, and: rows, within: dragTravel, tolerance: positionTolerance) else {
            return rejected(.unmatched)
        }
        let newRows = rows.count - overlap
        let added = min(newRows, target - confirmed)
        confirmed += added
        if added > 0 { anchor = rows[newRows - added] }
        page = current
        needsCount = false
        problem = nil
        self.dragTravel = 0
        recovery = nil
        return progress()
    }

    private static func overlap(between previous: [Element], and current: [Element], within travel: Double, tolerance: Double) -> Int? {
        let maximum = min(previous.count, current.count)
        guard maximum >= 2 else { return nil }
        // A repeated label can join two disjoint pages. Require a sequence with context
        // whose rows all moved down together, and reject competing alignments.
        let candidates = (2...maximum).filter { length in
            let olderPageTail = current.suffix(length)
            let shift = current[current.count - length].frame.centre.y - previous[0].frame.centre.y
            // The list starts moving only after recognizing the pan. In the simulator,
            // a 420-point resting drag moved the visible rows 399 points.
            let panAllowance = 32.0
            guard shift > tolerance, shift <= travel + tolerance, travel - shift <= panAllowance,
                  Set(olderPageTail.map(\.key)).count > 1 else { return false }
            return zip(previous.prefix(length), olderPageTail).allSatisfy { old, new in
                old.key == new.key && old.identifier == new.identifier &&
                    abs(new.frame.centre.x - old.frame.centre.x) <= tolerance &&
                    abs(new.frame.centre.y - old.frame.centre.y - shift) <= tolerance
            }
        }
        return candidates.count == 1 ? candidates[0] : nil
    }

    private mutating func rejected(_ problem: Problem) -> PokiCore.ToolAnswer {
        if self.problem != .actionFailed { self.problem = problem }
        if !started { needsCount = true }
        if problem == .unmatched, needsCount {
            if recovery == nil, let dragTravel, dragTravel >= 24 {
                recovery = .returning(distance: dragTravel)
            } else {
                recovery = .exhausted
            }
            needsCount = false
        }
        return progress(error: true)
    }

    func progress(error: Bool = false) -> PokiCore.ToolAnswer {
        let next: String
        if reachedTarget {
            next = "The requested message is visible. Call finish_task."
        } else if problem == .actionFailed {
            next = problem?.instruction ?? ""
        } else {
            switch recovery {
            case .returning:
                next = "The overlap is unconfirmed. Reverse the last drag, then check that the last verified page is back."
            case .retrying:
                next = "The last verified page is back. Try one shorter forward drag and check the overlap."
            case .exhausted:
                next = "The overlap could not be verified. Stop and report the confirmed count."
            case nil:
                next = problem?.instruction ?? "Use one small drag, then check the next page."
            }
        }
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
            case .unmatched: return "Couldn't match the overlap. Stop and report the confirmed count."
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
