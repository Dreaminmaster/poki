import Foundation
#if canImport(OSLog)
import OSLog
#endif

/// What a tool call answers: facts as text, a screenshot when there is one, and whether it failed.
public struct ToolResult: Sendable {
    public var text: String
    public var jpeg: Data?
    public var isError = false
    var splitView: PokiCore.SplitViewRead?
    var splitViewNeedsRead = false
    /// What the read behind this answer saw: the app in front and its element tree, without the read's
    /// time or the changes since the read before, and a mark that is new each time when the picture
    /// moved with the same elements (a canvas, a web view). The same screen reads the same, so a loop
    /// that goes nowhere can be told from a task that moves. Nil when no tree was read.
    var screen: String?
    var waitingForOwner = false
    var offeredMemories: [MemoryNote] = []
    var readApp: String?
    var automationAuthorizationDeclined = false
    var screenEvidence: ScreenEvidence? = nil
    var numberedScreen: PokiCore.NumberedScreen? = nil
    var itemPictureSource: ItemPictureSource?
    var freshPNG: Data? = nil
    var observedApp: String? = nil
}

struct ScreenEvidence: OptionSet, Sendable {
    let rawValue: UInt8
    static let references = Self(rawValue: 1 << 0)
    static let screenshot = Self(rawValue: 1 << 1)
}

/// A sent action failed: whether it may have reached the phone.
struct ActionFailure: Error, CustomStringConvertible {
    var message: String
    var delivery: Delivery
    var description: String { message }
}

/// The computer-use tools (look and do), ported from src/cua.mjs and src/cua-wda.mjs. One call does
/// some actions and then reads the screen once; the answer is facts only, and the model decides what
/// happened. Every step has a deadline, so a call always answers within `toolDeadline`.
final class Computer: @unchecked Sendable {
    let runner: Runner
    let host: CoreHost
    let config: CoreConfig
    let approvals: Approvals
    /// Distinguishes an external request without a transport session from
    /// Poki's own chat. Used for display/routing, never as a grant principal.
    private let anonymousExternalOrigin = "anonymous-external-\(UUID().uuidString)"
    let emit: @Sendable (CoreEvent) -> Void
    /// Explicit state machine for steps handed to the owner (`{handoff: {kind, text}}`).
    let handoff: HandoffTracker

    // Kept between calls; one tool call runs at a time (the gate in PokiCore), so no lock is needed.
    /// The numbers of the latest read. An element that is still there in the next read keeps its
    /// number, so a `do` can list only what changed.
    var refs: [Int: Element] = [:]
    var listed: [(ref: Int, element: Element)] = []
    var nextRef = 1
    /// Every element of the latest tree with a frame, listed or not (for what covers what).
    var lastAll: [Element] = [] {
        didSet { currentBackTarget = BackTarget(in: lastAll) }
    }
    private(set) var currentBackTarget = BackTarget(in: [])
    /// When the latest tree was read (a `wait_until: settled` takes a fresh one as its first sample).
    var lastTreeAt: Double?
    /// A swipe or drag went out that no tree read has shown yet: `scroll_to` reads before it swipes
    /// again, so a target cannot pass between two reads (the gym's row 250, scrolled past unread).
    var swipeUnread = false
    private func workingTarget(_ app: Foreground?) -> Foreground? {
        guard let app, let bundle = app.bundleID, !bundle.isEmpty,
              bundle != "com.apple.springboard", !config.isPoki(app) else { return nil }
        return app
    }

    var lastForeground: Foreground? {
        didSet {
            if let app = workingTarget(lastForeground) {
                lastWorkingApp = app
            }
        }
    }
    var lastWorkingApp: Foreground?
    private var selectedPane: (side: String, identity: String, app: String, other: String, session: String?)?
    private let workspaceOwner = LockedBox<String?>(nil)
    var hasLocalWorkspace: Bool { workspaceOwner.value != nil }
    func heldByLocalTask(otherThan session: String?) -> Bool {
        workspaceOwner.value.map { $0 != session } ?? false
    }
    func reserveWorkspace(session: String) -> Bool {
        guard !heldByLocalTask(otherThan: session), selectedPane == nil, !handoffWaiting, approvals.pending == nil,
              beginsTask() || origin?.session == session else { return false }
        workspaceOwner.value = session
        return true
    }

    func clearWorkspacePaneForSetup(session: String) async -> Bool {
        guard workspaceOwner.value == session, !handoffWaiting, approvals.pending == nil else { return false }
        guard let selectedPane else { return true }
        guard selectedPane.session == session else { return false }
        return await selectPane("auto", session: session, until: now() + 6, keepWorkspace: true) == nil
    }
    private var confirmedPaneRead = false
    private struct WorkspaceRead {
        let layout, app: String
        let size: ScreenSize
        let x, y, at: Double
        let images: Int
        let picture: PictureSketch?
    }
    private var workspaceReads: [String: WorkspaceRead] = [:]
    private var workspaceDrop: (before: WorkspaceRead, delivery: Delivery)?
    private var interruptedDropApp: String?
    private struct WorkspaceDrag {
        let fromApp, toApp, layout: String
        let image: String?
        let x, y: Double

        func matches(_ other: Self) -> Bool {
            guard fromApp == other.fromApp, toApp == other.toApp else { return false }
            if let image, image == other.image { return true }
            if image != nil && other.image != nil { return false }
            return layout == other.layout && hypot(x - other.x, y - other.y) <= 8
        }
    }
    // Keep the sent item after the destination read consumes its one-time drop evidence.
    private var workspaceDrags: [WorkspaceDrag] = []
    private static let repeatedDrop = "this item was already dragged to the same app in this task. Inspect the destination before continuing."
    private var paneOffset: (x: Double, y: Double)?
    var size: ScreenSize?
    var lastPNG: Data?
    /// The latest failed step's error, worded for the app log: what the field held is named by case
    /// only (see recoverType). Core takes it after each call.
    let failureLog = LockedBox<String?>(nil)
    /// When `lastPNG` was taken (it stands in, marked stale, when a read gives no picture at all).
    var lastPNGAt: Double?
    private var activeLocalTask: String?
    /// How long the last look or do took inside the computer, for the MCP's own accounting.
    var lastCallTook: Double?
    var lastTree: String?
    var lastPicture: PictureSketch?
    /// Where the owner asked: the app in front at the task's first look or do, and the MCP session
    /// that made that call (nil from inside the app). The phone goes back there when the task ends.
    var origin: (app: Foreground, session: String?, lastCall: Double)?

    /// The element the last scroll_to found, so the read after it can give its number (it may be
    /// past the listing's limit: the gym's 1,507-element grid had its button at 1506).
    var scrollFound: Element?
    struct ScrollTargetObservation {
        let inputAt: Double
        let elements: [Element]
        let foreground: Foreground
        let targetTreeAt: Double
        let target: Element
        let swipes: Int
    }
    var scrollObservation: ScrollTargetObservation?
    var actionGeneration: UInt64 = 0
    private var preparedCapture: PreparedCapture?
    /// Shapes touches and typing after a person's (see `Humanize`); off sends the legacy schedules.
    var humanize: Humanize
    /// The element the last type went to and its text, so the read after it can say which number the
    /// field has now when the app replaced it (Settings' search field is a new element in search mode).
    var typedInto: (ref: Int, text: String)?
    /// The text this task last typed (not a password), for the send check after Return in a chat app.
    var typedText: String?
    /// How much of the picture changed in the latest read while the elements did not (nil when the
    /// elements changed too, or nothing did): a whole new picture over an unchanged tree is the old
    /// app's tree under the new app's screen (gym: Photos launched from Safari).
    var pictureOnlyShare: Double?

    /// The agent's memory library, and this task's recorded steps (what skills {save} keeps).
    var memory: SkillStore?
    var trace: [RecordedStep] = []
    /// The foreground a new skill step can use. Home and launch invalidate it until a read.
    var skillStepApp: String?
    var recordingTask: String?
    var memoryAppsOffered: Set<String> = []
    /// A skill ran whole in this task (the finish line does not offer to save it again).
    var skillRanWhole = false
    /// The app a session named with `app`: kept across its calls until it lets go of it.
    var sessionApp: (bundle: String, name: String, session: String?)?
    /// The last run or path ended on a check that found what it looked for on screen.
    var runEndedOnARead = false

    var lastElements: [Element] { listed.map(\.element) }
    var layout: Layout { Layout(all: lastAll, screen: size ?? ScreenSize(width: 10_000, height: 10_000)) }

    static let settle: [String: Double] = ["tap": 0.45, "type": 0.25, "key": 0.3, "swipe": 0.6, "drag": 0.35, "long_press": 0.4, "pinch": 0.6, "button": 0.7, "launch": 0.9, "scroll_to": 0.2, "wait": 0, "wait_until": 0, "run_read": 0]
    static let lineLimit = 120
    static let textLimit = 160

    init(runner: Runner, host: CoreHost, config: CoreConfig, approvals: Approvals, emit: @escaping @Sendable (CoreEvent) -> Void = { _ in }) {
        self.emit = emit
        self.runner = runner
        self.host = host
        self.config = config
        self.humanize = Humanize(enabled: config.humanize ?? Humanize.envEnabled)
        self.approvals = approvals
        self.handoff = HandoffTracker(emit: emit)
        self.memory = config.memory ?? SkillStore.shared
    }

    // MARK: Reading and answering

    func screenSize(until: Double, refreshing: Bool = false) async throws -> ScreenSize {
        if !refreshing, let size { return size }
        let s = try await runner.screenSize(timeout: max(0.5, min(3, until - now())))
        size = s
        return s
    }

    /// Refresh after the read chooses a pane, before encoding the picture or mapping OCR to points.
    private func updateReadSize(until: Double) async {
        guard size == nil || runner.transport.usesDynamicScreenSize else { return }
        let previous = size
        size = try? await screenSize(until: until, refreshing: true)
        if previous != size {
            // A failed read of the new pane must not leave a picture or hit targets from the old one.
            lastPNG = nil; lastPNGAt = nil; lastPicture = nil; lastTree = nil
            refs = [:]; listed = []; lastAll = []; lastTreeAt = nil
        }
    }

    /// The screenshot's width: one pixel per screen point, so a point read off the picture is a point
    /// to tap.
    static func pictureWidth(_ screen: ScreenSize?) -> Int {
        guard let w = screen?.width, w >= 200, w <= 1400 else { return 300 }
        return Int(w.rounded())
    }

    /// Reads the screen and answers with the facts, whatever part of the read failed. `changes` lists
    /// only what changed since the read before (a `do`); `full` lists every element, as the tree has it.
    func readAndReply(until: Double, full: Bool, changes: Bool = false, checkingTouch: Bool = false, did: [String] = [], error: String? = nil, extra: [String] = [], reading confirmedRead: Reading? = nil) async -> ToolResult {
        let inWorkspace = selectedPane != nil
        let readTimeout = inWorkspace ? max(config.readTimeout, 6) : config.readTimeout
        let budget = max(0.8, min(readTimeout, until - now() - 0.2))
        var reading: Reading
        if let confirmedRead {
            reading = confirmedRead
        } else {
            reading = await runner.read(timeout: budget, extra: max(0, min(4, until - now() - budget - 3)), format: config.treeFormat,
                                        callEnds: until, allowHostPicture: !inWorkspace, workspace: inWorkspace)
        }
        if let pane = selectedPane {
            let besidePoki = config.isPoki(Foreground(bundleID: pane.other, name: nil))
            let front = reading.foreground?.bundleID
            if let companion = reading.screenshotCompanion {
                confirmedPaneRead = besidePoki && companion.identity == pane.identity &&
                    companion.bundleID == pane.app && companion.pokiPane != pane.side && (front == nil || front == pane.app)
                if confirmedPaneRead, front == nil {
                    reading.foreground = Foreground(bundleID: companion.bundleID, name: nil, pokiPane: companion.pokiPane)
                    reading.elements = []
                }
            } else {
                confirmedPaneRead = front == pane.app && reading.png != nil && (besidePoki || !reading.elements.isEmpty)
            }
            if !confirmedPaneRead {
                invalidateWorkspaceRead()
                return ToolResult(text: (["Split View: the \(pane.side) pane could not be confirmed; call look with that pane again"] +
                    did.map { "did: \($0)" } + (error.map { ["error: \($0)"] } ?? [])).joined(separator: "\n"),
                    jpeg: nil, isError: true, splitViewNeedsRead: true, screenEvidence: [])
            }
        }
        skillStepApp = reading.foreground?.bundleID
        if reading.png != nil || !reading.elements.isEmpty {
            await updateReadSize(until: now() + 1.5)
        }
        let screen = size ?? ScreenSize(width: 10_000, height: 10_000)
        var notes = reading.notes
        if let modal = modalOnly(reading.elements) { notes.append(modal) }
        if reading.png == nil && reading.elements.isEmpty {
            lastForeground = reading.foreground
            // Nothing came back: say what was sent and what the runner is doing, and nothing else.
            // Reading it asks for nothing: a call that failed does not start another open.
            let state = host.currentRunner
            let did = did.map { $0.replacingOccurrences(of: "(sent,", with: "(sent, not confirmed: no read after it,") }
            // The numbers of the read before stand: nothing newer was read, and the model can act on
            // them or send the same action again (CI simulator: a type sent again after "nothing was
            // typed" was refused as stale because the refused call's read had failed).
            let kept = refs.isEmpty ? [] : ["the elements of the read before keep their numbers (nothing newer was read)"]
            // The picture of the read before, marked with its age, is better than none (gym: three
            // calls blind for 32 s while the runner restarted under load).
            var stale: Data?, staleNote: [String] = []
            if let old = lastPNG, let at = lastPNGAt, now() - at < 120, let jpeg = try? host.jpeg(fromPNG: old, width: Self.pictureWidth(size), quality: 0.6) {
                stale = jpeg
                staleNote = ["the screenshot is the one of the read before, \(Int((now() - at).rounded())) s old (no newer one came)"]
            }
            var lines: [String] = ["read: failed (\(notes.joined(separator: "; ")))", "runner: \(state.describe)"]
            lines += did.map { "did: \($0)" }
            if let error { lines.append("error: \(error)") }
            lines += extra + kept + staleNote
            return ToolResult(text: lines.joined(separator: "\n"), jpeg: stale, isError: true, screenEvidence: [], observedApp: reading.foreground?.describe)
        }
        let treeRead = !reading.elements.isEmpty || reading.notes.isEmpty
        if !treeRead { currentBackTarget = BackTarget(in: []) }
        let sameApp = reading.foreground?.bundleID == nil || reading.foreground?.bundleID == lastForeground?.bundleID
        lastForeground = reading.foreground ?? lastForeground
        if config.isPoki(reading.foreground) { return pokiInFront(reading, did: did, error: error, extra: extra) }
        if reading.png != nil { lastPNGAt = now() }
        lastPNG = reading.png ?? lastPNG

        // Whether the screen changed since the read before (the one the model saw last).
        let visible = listable(reading.elements, screen, includeUnlabeledImages: selectedPane != nil)
        let tree = visible.map { "\($0.key)@\($0.frame.described)" }.joined(separator: "\n")
        let picture = reading.png.map { PictureSketch(png: $0) }
        let pictureMoved = picture.flatMap { now in lastPicture.map { now.differs(from: $0) } } ?? false
        var changedLine: String?
        var touchEffectUnconfirmed = false
        if changes, treeRead, let before = lastTree {
            let pictureChanged: Bool? = picture.flatMap { now in lastPicture.map { now.differs(from: $0) } }
            // Where and how much the picture moved, so a small change (an indicator fading, a badge)
            // can be told from a page coming in without looking.
            var where_ = ""
            if pictureChanged == true, let now = picture, let last = lastPicture, let change = now.change(from: last), size != nil {
                let box = [change.x * screen.width, change.y * screen.height, change.width * screen.width, change.height * screen.height].map { Int($0.rounded()) }
                where_ = ", in \(max(1, Int((change.share * 100).rounded()))) % of it, within [\(box.map(String.init).joined(separator: ", "))]"
            }
            pictureOnlyShare = nil
            if tree != before { changedLine = "screen_changed: true (the elements changed)" }
            else if pictureChanged == true {
                changedLine = "screen_changed: true (only the picture changed\(where_); the elements are the same)"
                if let now = picture, let last = lastPicture { pictureOnlyShare = now.change(from: last)?.share }
            }
            else {
                changedLine = "screen_changed: false (the elements\(pictureChanged == false ? " and the picture" : "") are the same as in the read before)"
                touchEffectUnconfirmed = checkingTouch && sameApp && reading.foreground?.bundleID != nil
            }
        }
        if treeRead { lastTree = tree }
        if let picture { lastPicture = picture }

        // What to list: the elements without repeats, and in a full read the text inside collapsed ones.
        var shown = treeRead ? lean(visible, full: full) : []
        let collapsed = Set(shown.filter { isCollapsed($0, in: reading.elements) }.map(\.node))
        // A web view with nothing of its page in the tree is read from the picture in every look.
        let emptyWeb = shown.contains { $0.type == "WebView" && collapsed.contains($0.node) }
        if full || emptyWeb, !collapsed.isEmpty, let png = reading.png, size != nil {
            let host = self.host
            // Vision's first pass on a CI simulator took 3.7 s (seen in the gym); the read gives it 4 s
            // when the call has them.
            let left = max(0.3, min(4, until - now() - 0.5))
            if let texts = (try? await withDeadline(left, "reading text from the picture", { await host.recognizeText(inPNG: png) })) ?? nil {
                // Each text goes right after the collapsed element it lies in, top to bottom.
                var inside: [Int: [Element]] = [:]
                let holders = shown.filter { collapsed.contains($0.node) }
                for t in texts {
                    let frame = Rect(x: t.box.x * screen.width, y: t.box.y * screen.height, width: t.box.width * screen.width, height: t.box.height * screen.height)
                    guard let holder = holders.last(where: { $0.frame.contains(frame.centre) }) else { continue }
                    inside[holder.node, default: []].append(Element(type: "Text", label: t.text, value: nil, identifier: nil, frame: frame, depth: holder.depth + 1, fromPicture: true))
                }
                shown = shown.flatMap { e in [e] + (inside[e.node] ?? []).sorted { ($0.frame.y, $0.frame.x) < ($1.frame.y, $1.frame.x) } }
            } else {
                notes.append("no text read from the picture (reading it did not finish within \(DeadlineExceeded.format(left)); call look again, or tap a point on the picture)")
            }
        }

        // No tree in time (a slow runner, a heavy keyboard): the text read from the picture stands in for
        // it, numbered and tappable at its centre, so the model is never left with only a picture.
        var pictureOnly = false
        if !treeRead, let png = reading.png, size != nil {
            let host = self.host
            // Vision's accurate model (needed for Chinese and Japanese) on a whole screenshot takes up to
            // a few seconds on a slow machine.
            let left = min(3.5, until - now() - 0.6)
            // Say why nothing came of it, so a slow or failing recogniser is told apart from an empty screen.
            var outcome = "no time left to read text from the picture"
            if left >= 0.3 {
                let began = now()
                do {
                    let texts = try await withDeadline(left, "reading text from the picture", { await host.recognizeText(inPNG: png) })
                    let ms = Int(((now() - began) * 1000).rounded())
                    if let texts, !texts.isEmpty {
                        shown = texts.map { t in
                            Element(type: "Text", label: t.text, value: nil, identifier: nil,
                                    frame: Rect(x: t.box.x * screen.width, y: t.box.y * screen.height, width: t.box.width * screen.width, height: t.box.height * screen.height),
                                    depth: 0, fromPicture: true)
                        }.sorted { ($0.frame.y, $0.frame.x) < ($1.frame.y, $1.frame.x) }
                        pictureOnly = true
                    }
                    outcome = texts == nil ? "text could not be read from the picture; the picture is the screen now: tap points on it ([x, y]) or call look again" : "no text found in the picture (\(ms) ms); tap points on the picture ([x, y]) or call look again"
                } catch {
                    outcome = "reading text from the picture did not finish within \(Int(((now() - began) * 1000).rounded())) ms"
                }
            }
            if !pictureOnly { notes.append(outcome) }
        }

        // Numbers: an element still there keeps its number (same text and frame first, then same text).
        let prior = treeRead ? listed : []
        var exact: [String: [Int]] = [:], loose: [String: [Int]] = [:]
        var inPlace: [String: [(ref: Int, text: String)]] = [:]
        func place(_ e: Element) -> String { "\(e.type)@\(e.frame.described)" }
        for (r, e) in prior where !e.fromPicture {
            exact["\(e.key)@\(e.frame.described)", default: []].append(r)
            inPlace[place(e), default: []].append((r, e.text))
            loose[e.key, default: []].append(r)
        }
        let sinceRead = lastTreeAt.map { now() - $0 } ?? 0
        var used = Set<Int>()
        var assigned = [Int?](repeating: nil, count: shown.count)
        var moved = Set<Int>()
        for (i, e) in shown.enumerated() where !e.fromPicture {
            if let r = exact["\(e.key)@\(e.frame.described)"]?.first(where: { !used.contains($0) }) {
                assigned[i] = r
                used.insert(r)
                if let previous = refs[r], previous.isDisabled != e.isDisabled { moved.insert(r) }
            }
        }
        // Only a countdown in its text ran on, in the same place: the same control, listed as changed
        // so the model reads the new text.
        for (i, e) in shown.enumerated() where !e.fromPicture && assigned[i] == nil {
            if let r = inPlace[place(e)]?.first(where: { !used.contains($0.ref) && Countdown.sameControl(before: $0.text, after: e.text, elapsed: sinceRead) })?.ref {
                assigned[i] = r; used.insert(r); moved.insert(r)
            }
        }
        for (i, e) in shown.enumerated() where !e.fromPicture && assigned[i] == nil {
            if let r = loose[e.key]?.first(where: { !used.contains($0) }) { assigned[i] = r; used.insert(r); moved.insert(r) }
        }
        // Another screen: numbering starts again.
        let fresh = prior.isEmpty || !sameApp || Double(used.count) < 0.3 * Double(max(1, shown.count))
        if fresh {
            assigned = [Int?](repeating: nil, count: shown.count)
            moved = []
            used = []
            if selectedPane == nil { nextRef = 1 }
        }
        for i in assigned.indices where assigned[i] == nil {
            assigned[i] = nextRef
            nextRef += 1
        }
        let gone = fresh ? [] : prior.filter { !used.contains($0.ref) && !$0.element.fromPicture }
        if treeRead {
            refs = [:]
            listed = []
            for (i, e) in shown.enumerated() {
                refs[assigned[i]!] = e
                listed.append((assigned[i]!, e))
            }
            lastAll = reading.elements
            lastTreeAt = now()
            swipeUnread = false
        } else if shown.isEmpty, !refs.isEmpty {
            // A picture but no tree and no text read from it: the numbers of the read before stand.
            notes.append("the elements of the read before keep their numbers (nothing newer was read)")
        } else {
            refs = [:]
            listed = []
            for (i, e) in shown.enumerated() { refs[assigned[i]!] = e }
        }

        func line(_ ref: Int, _ e: Element, _ mark: String) -> String {
            var text = e.text.isEmpty && e.type == "WebView" ? "web page (its parts are not in the tree yet: read again in a second)" : e.text
            if !full, text.count > Self.textLimit { text = "\(text.prefix(Self.textLimit - 10))… (+\(text.count - Self.textLimit + 10) characters)" }
            var tag = e.fromPicture ? " (read from the picture)" : collapsed.contains(e.node) ? " [collapsed]" : ""
            if tag.isEmpty, let size, coversScreenAlone(e, in: reading.elements, screen: size) {
                tag = " (one element covering \(Int((e.frame.width * e.frame.height * 100 / (size.width * size.height)).rounded())) % of the screen with no parts in the tree: tap a point on the picture, not its number)"
            }
            if e.isDisabled { tag += " [disabled]" }
            return "\(mark)\(ref) \(e.type) \"\(text)\" \(e.frame.described)\(tag)"
        }
        var body: [String] = []
        var heading: String
        let marks: [String] = shown.indices.map { i in
            let r = assigned[i]!
            if fresh { return " " }
            return used.contains(r) ? (moved.contains(r) ? "~" : " ") : "+"
        }
        if changes, !full, !fresh {
            let changed = shown.indices.filter { marks[$0] != " " }
            let same = shown.count - changed.count
            heading = changed.isEmpty
                ? "elements: none changed (\(shown.count) on screen keep their numbers)"
                : "elements (\(shown.count) on screen; only the changed are listed: + new, ~ moved; the \(same) others keep their numbers, full=true lists all):"
            body = changed.prefix(Self.lineLimit).map { line(assigned[$0]!, shown[$0], marks[$0]) }
        } else {
            heading = prior.isEmpty ? "elements (\(shown.count)):" : fresh ? "elements (\(shown.count); a new screen: numbered from 1 again, the numbers of the read before no longer apply):" : "elements (\(shown.count); + new since the last read, ~ moved):"
            let limit = full ? 1000 : Self.lineLimit
            body = shown.indices.prefix(limit).map { line(assigned[$0]!, shown[$0], marks[$0]) }
            if shown.count > limit {
                // What was left out, by type, so the model knows what it cannot see (the gym's grid
                // put the state button past the limit) and that scroll_to by text numbers any of them.
                var byType: [String: Int] = [:]
                for e in shown[limit...] { byType[e.type, default: 0] += 1 }
                let types = byType.sorted { $0.value > $1.value }.prefix(6).map { "\($0.key) \($0.value)" }.joined(separator: ", ")
                body.append("… \(shown.count - limit) more not listed (\(types)); \(full ? "" : "full=true lists up to 1000; ")scroll_to with an element's text finds it and gives its number")
            }
        }
        if let wanted = scrollFound {
            // The element scroll_to found, with its number, listed whether or not the listing reached it.
            scrollFound = nil
            if let i = shown.firstIndex(where: { $0.key == wanted.key && $0.frame.described == wanted.frame.described }) ?? shown.firstIndex(where: { $0.key == wanted.key }) {
                body.append("found by scroll_to: \(line(assigned[i]!, shown[i], " ").trimmingCharacters(in: .whitespaces)) (tap \(assigned[i]!))")
            }
        }
        if pictureOnly { heading = "elements (\(shown.count), read from the picture because the element tree did not come in time; a number taps the text's centre):" }
        if !collapsed.isEmpty, !full { heading += "  ([collapsed] = one element whose parts are not in the tree; full=true adds the text read from the picture inside it, or tap a point on the screenshot)" }

        var jpeg: Data?
        let width = Self.pictureWidth(size)
        if let png = reading.png {
            do { jpeg = try host.jpeg(fromPNG: png, width: width, quality: 0.6) }
            catch { notes.append("screenshot not encoded: \(error)") }
        } else if let old = lastPNG, let at = lastPNGAt, now() - at < 120, let stale = try? host.jpeg(fromPNG: old, width: width, quality: 0.6) {
            // No picture from the runner or the host (a restart under load): the picture of the read
            // before, marked with its age, is better than none (gym: three calls blind for 32 s).
            jpeg = stale
            notes.append("the screenshot is the one of the read before, \(Int((now() - at).rounded())) s old (no newer one came); the elements, when read, are current")
        }
        let app = reading.foreground?.describe ?? "unknown"
        var header = ["app: \(app)   read: \(ISO8601DateFormatter().string(from: Date())) (\(reading.ms) ms)" + (notes.isEmpty ? "" : "   note: \(notes.joined(separator: "; "))")]
        if let side = reading.foreground?.pokiPane, side == "left" || side == "right" {
            header.append("Duo Split View: Poki is on the \(side). The picture, elements and input are for the \(side == "left" ? "right" : "left") pane.")
        }
        if jpeg != nil { header.append(size != nil ? "screenshot: \(width) px wide, 1 px = 1 screen point (the same points as the frames and taps)" : "screenshot: \(width) px wide; screen size unknown") }
        header += did.map { "did: \($0)" }
        if let error { header.append("error: \(error)") }
        if let line = handoffLine(clear: true) { header.append(line) }
        if let changedLine { header.append(changedLine) }
        if touchEffectUnconfirmed {
            header.append("touch effect: unconfirmed (sent reports the input request, not the app’s response). Verify the expected screen or element before repeating the touch or continuing.")
        }
        header += extra
        header.append(heading)
        if let typed = typedInto, gone.contains(where: { $0.ref == typed.ref }), let i = shown.firstIndex(where: { Self.fieldTypes.contains($0.type) && ($0.value ?? "").contains(typed.text) }), let n = assigned[i] {
            body.append("the field typed into is now element \(n) (\(typed.ref) is gone: the app replaced the field)")
        }
        typedInto = nil
        let footer = gone.isEmpty ? [] : ["gone since the last read: " + gone.prefix(20).map { "\($0.ref) \($0.element.type) \"\($0.element.text.prefix(40))\"" }.joined(separator: ", ")]
        var evidence: ScreenEvidence = []
        if treeRead || pictureOnly { evidence.insert(.references) }
        if reading.png != nil, jpeg != nil, size != nil { evidence.insert(.screenshot) }
        let numberedScreen: PokiCore.NumberedScreen?
        if full, evidence.contains(.references), let bundleID = reading.foreground?.bundleID {
            let elements = Dictionary(uniqueKeysWithValues: shown.indices.prefix(1000).map { (assigned[$0]!, shown[$0]) })
            numberedScreen = PokiCore.NumberedScreen(bundleID: bundleID, elements: elements)
        } else {
            numberedScreen = nil
        }
        var itemPictureSource: ItemPictureSource?
        let pokiPane = reading.foreground?.pokiPane
        if !inWorkspace, reading.screenshotCompanion == nil, pokiPane != "left", pokiPane != "right",
           let png = reading.png, jpeg != nil, let size {
            let images = reading.elements.filter { $0.type == "Image" && !$0.fromPicture }.map(\.frame)
            itemPictureSource = ItemPictureSource(png: png, screen: size, images: images)
        }
        // A screenshot helps the caller recover from a failed action without hiding the failure.
        return ToolResult(text: (header + body + footer).joined(separator: "\n"), jpeg: jpeg, isError: error != nil,
                          screen: treeRead ? "\(reading.foreground?.bundleID ?? "")\n\(tree)" + (pictureMoved ? "\npicture moved: \(UUID().uuidString)" : "") : nil,
                          waitingForOwner: handoffWaiting, readApp: treeRead ? reading.foreground?.bundleID : nil,
                          screenEvidence: evidence, numberedScreen: numberedScreen, itemPictureSource: itemPictureSource,
                          freshPNG: reading.png, observedApp: lastForeground?.describe)
    }

    /// An answer with nothing done but the picture (served apart from WDA's queue), so a busy runner
    /// never leaves the model blind: it sees the screen and the next look is not an error.
    /// `isErrorWithoutPicture: false` for an answer that already says what to do next (wait for the
    /// runner): it is not an error even when the runner is too far gone to give the picture.
    func withPicture(_ text: String, timeout: Double, remember: Bool = true, isErrorWithoutPicture: Bool = true) async -> ToolResult {
        guard timeout > 0.3, let png = try? await runner.screenshot(timeout: min(3, timeout)) else {
            // The runner gives none: the host's own path to the screen, when it has one.
            if selectedPane == nil, timeout > 0.3, let fallback = runner.screenshotFallback, let png = (try? await withDeadline(6, "the host's screenshot") { await fallback() }) ?? nil, let jpeg = try? host.jpeg(fromPNG: png, width: Self.pictureWidth(size), quality: 0.6) {
                return ToolResult(text: text + "\nscreenshot: the screen now, taken apart from the runner (nothing was sent)", jpeg: jpeg, isError: false, freshPNG: png, observedApp: lastForeground?.describe)
            }
            return ToolResult(text: text + "\nscreenshot: none (the runner did not give one either)", jpeg: nil, isError: isErrorWithoutPicture)
        }
        await updateReadSize(until: now() + 1)
        if remember { lastPNG = png }
        let jpeg = try? host.jpeg(fromPNG: png, width: Self.pictureWidth(size), quality: 0.6)
        return ToolResult(text: text + (jpeg == nil ? "" : "\nscreenshot: the screen now (nothing was sent)"), jpeg: jpeg, isError: jpeg == nil && isErrorWithoutPicture, freshPNG: png, observedApp: lastForeground?.describe)
    }

    /// The answer when Poki is in front, as when a task asked in Poki's chat begins (ESP-465: the first
    /// look of 3 of 5 tasks read the owner's chat with Poki, and the task card showed it). The chat is
    /// the owner's, not a screen of the task: the answer lists none of it, carries no picture, and keeps
    /// none for the task card or the Live Activity; it says how a task starts instead.
    func pokiInFront(_ reading: Reading, did: [String], error: String?, extra: [String]) -> ToolResult {
        refs = [:]
        listed = []
        lastAll = []
        lastTree = nil
        lastPicture = nil
        lastPNG = nil
        lastPNGAt = nil
        var lines = ["app: \(reading.foreground?.describe ?? "Poki")   read: \(ISO8601DateFormatter().string(from: Date())) (\(reading.ms) ms)"]
        lines += did.map { "did: \($0)" }
        if let error { lines.append("error: \(error)") }
        lines += extra
        lines.append("poki: Poki is in front. The owner's chat is private, so this read has no screenshot or element numbers. Start the task in its app: do {launch: \"bundle id\"}, or do {run: \"name\"} for a saved skill. To search for an app, send {button: \"home\"} by itself to read the Home Screen.")
        return ToolResult(text: lines.joined(separator: "\n"), jpeg: nil, isError: error != nil, screen: "poki", waitingForOwner: handoffWaiting, screenEvidence: [])
    }

    /// The `handoff:` line: a step handed to the owner that is waiting, or just done (reported once).
    func handoffLine(clear: Bool) -> String? {
        handoff.apply(.readLine(consumeCompleted: clear, now: Date())).line
    }

    var handoffWaiting: Bool { handoff.isWaiting }

    func handoffDone(id: String) {
        handoff.apply(.ownerCompleted(id: id, now: Date()))
    }

    private func endHandoff() {
        handoff.apply(.endTask)
    }

    private var authorizationRead: (revision: UInt64, task: String?, evidence: ScreenEvidence)?

    func look(full: Bool, pane: String? = nil, session: String? = nil, local: Bool = false, expectedApps: Set<String>? = nil, localTask: String? = nil) async -> ToolResult {
        let started = now()
        defer { lastCallTook = now() - started }
        resetScreenForNewTask(session: session, localTask: localTask)
        return await lookNow(full: full, pane: pane, session: session, local: local, expectedApps: expectedApps, localTask: localTask)
    }

    func lookNow(full: Bool, pane: String? = nil, session: String? = nil, local: Bool = false, expectedApps: Set<String>? = nil, localTask: String? = nil) async -> ToolResult {
        if local { authorizationRead = nil }
        let until: Double
        let revision: UInt64?
        switch await waitForRunner(until: now() + config.toolDeadline, authorization: local ? .ready : .none) {
        case .ready(let deadline, let readyRevision): (until, revision) = (deadline, readyRevision)
        case .blocked(let result): return result
        }
        if let selectedPane, selectedPane.session != session, (hasLocalWorkspace || !beginsTask() || pane == nil) { return workspaceInUse() }
        async let locked = isLocked()
        var unlocked = false
        if localTask != nil, await locked {
            unlocked = await unlockForLocalTask(until: until)
            if !unlocked { unlocked = await !isLocked() }
        }
        if let pane, !(await locked) || unlocked {
            if let failure = await selectPane(pane, session: session, until: until) { return failure }
            workspaceOwner.value = local && pane != "auto" ? session : nil
        }
        if let expectedApps, let selectedPane, Set([selectedPane.app, selectedPane.other]) != expectedApps {
            invalidateWorkspaceRead()
            return ToolResult(text: "not_sent: the two visible apps do not match the planned Split View pair.",
                              jpeg: nil, isError: true, splitViewNeedsRead: true)
        }
        let begins = beginsTask() || recordingTask != localTask || (pane != nil && origin?.session != session)
        if begins { beginRecording(task: localTask); typedText = nil }
        var result = restartNote(await readAndReply(until: until, full: full))
        if let selectedPane {
            if !result.isError, let size, let paneOffset {
                result.splitView = .init(side: selectedPane.side, app: selectedPane.app, otherApp: selectedPane.other,
                                         layout: workspaceLayout(selectedPane.identity))
                let layout = workspaceLayout(selectedPane.identity)
                let images = visibleWorkspaceImages(in: size)
                workspaceReads[selectedPane.side] = WorkspaceRead(layout: layout, app: selectedPane.app, size: size,
                                                                 x: paneOffset.x, y: paneOffset.y, at: now(), images: images, picture: lastPicture)
                if let drop = workspaceDrop, drop.before.app == selectedPane.app {
                    if interruptedDropApp == drop.before.app || drop.before.layout != layout {
                        interruptedDropApp = drop.before.app
                    } else {
                        var evidence = "Split View drop: gesture \(drop.delivery == .sent ? "sent" : "delivery unknown"); visible image elements in the destination before: \(drop.before.images), now: \(images)."
                        if let before = drop.before.picture, let after = lastPicture, let change = after.change(from: before) {
                            if change.share > 0.01 {
                                let bounds = Rect(x: change.x * size.width, y: change.y * size.height,
                                                  width: change.width * size.width, height: change.height * size.height)
                                evidence += " The destination screenshot changed within \(bounds.described)."
                            } else {
                                evidence += " The destination screenshot is visually unchanged."
                            }
                        }
                        result.text += "\n" + evidence + " Check the destination screenshot for the intended item. A photo may be visible without an accessibility image element."
                    }
                    workspaceDrop = nil
                }
                if interruptedDropApp == selectedPane.app {
                    result.text += "\nSplit View drop: the previous drag may already have landed. Inspect the destination for the intended item now. Do not repeat the drag; if you cannot tell whether it landed, report the uncertain outcome."
                }
            } else {
                workspaceReads.removeValue(forKey: selectedPane.side)
            }
            result.text += "\nSplit View: \(selectedPane.side) is \(selectedPane.app); the other pane is \(selectedPane.other)."
            if config.isPoki(Foreground(bundleID: selectedPane.other, name: nil)) {
                result.text += " Poki only controls the \(selectedPane.side) pane."
            } else {
                result.text += " Use look with pane left or right before acting on the other app."
            }
        }
        if begins, let app = lastForeground { origin = (app, session, now()) } else if origin?.session == session { origin?.lastCall = now() }
        if begins, let line = skillsLine() { result.text += "\n" + line }
        if await locked, !unlocked { return lockedScreen(result) }
        if local, let revision, !Task.isCancelled, !result.isError, let evidence = result.screenEvidence,
           host.currentRunner.automationRevision == revision {
            authorizationRead = (revision, localTask, evidence)
        }
        return result
    }

    private func lockedScreen(_ result: ToolResult) -> ToolResult {
        var result = result
        var lines = result.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        lines.insert("screen: locked (the owner has to unlock the phone before anything can be done)", at: min(1, lines.count))
        result.text = lines.joined(separator: "\n")
        result.waitingForOwner = true
        result.splitView = nil
        return result
    }

    private func workspaceInUse() -> ToolResult {
        ToolResult(text: "another task is using Split View; wait for it to finish", jpeg: nil, isError: true)
    }

    private func selectPane(_ side: String, session: String?, until: Double, keepWorkspace: Bool = false) async -> ToolResult? {
        guard ["left", "right", "auto"].contains(side) else {
            return ToolResult(text: "pane must be left, right, or auto", jpeg: nil, isError: true)
        }
        guard runner.transport.supportsPaneSelection else {
            return side == "auto" ? nil : ToolResult(text: "Split View targeting is unavailable on this automation path", jpeg: nil, isError: true)
        }
        guard !handoffWaiting || side == "auto" else {
            return ToolResult(text: "the owner has control; wait for them to finish before selecting a pane", jpeg: nil, isError: true, waitingForOwner: true)
        }
        do {
            let reply = try await runner.call("POST", "/poki/pane", ["side": .string(side)], timeout: min(6, max(0.5, until - now())))
            let oldIdentity = selectedPane?.identity
            let ownerChanged = selectedPane.map { $0.session != session } ?? false
            let oldWorkspace = workspaceOwner.value
            if side == "auto" {
                selectedPane = nil
                if !keepWorkspace { workspaceOwner.value = nil }
                paneOffset = nil
                workspaceReads.removeAll()
                workspaceDrop = nil
                interruptedDropApp = nil
                workspaceDrags.removeAll()
            } else {
                guard let identity = reply["identity"]?.string, !identity.isEmpty,
                      let app = reply["bundleId"]?.string, !app.isEmpty,
                      let other = reply["otherBundleId"]?.string, !other.isEmpty else {
                    invalidateWorkspaceRead()
                    return ToolResult(text: "could not confirm the two Split View apps", jpeg: nil, isError: true,
                                      splitViewNeedsRead: true)
                }
                if ownerChanged || oldIdentity.map({ workspaceLayout($0) != workspaceLayout(identity) }) == true { workspaceReads.removeAll() }
                if ownerChanged {
                    workspaceDrop = nil
                    interruptedDropApp = nil
                    workspaceDrags.removeAll()
                }
                selectedPane = (side, identity, app, other, session)
                paneOffset = reply["x"]?.double.flatMap { x in reply["y"]?.double.map { (x, $0) } }
            }
            if oldIdentity != selectedPane?.identity || ownerChanged {
                approvals.discardWorkspaceDecisions(session: oldWorkspace)
                if let pending = approvals.pending { approvals.withdraw(id: pending.id) }
                clearPaneRead()
            }
            return nil
        } catch {
            invalidateWorkspaceRead()
            return ToolResult(text: "could not select the \(side) pane: \(error)", jpeg: nil, isError: true,
                              splitViewNeedsRead: side != "auto")
        }
    }

    private func workspaceLayout(_ identity: String) -> String {
        String(identity.split(separator: "/", maxSplits: 1).last ?? "")
    }

    /// Image elements may be unlabeled. Count distinct visible bounds so nested duplicate views do
    /// not turn one attachment into multiple images, and tiny icons are excluded.
    private func visibleWorkspaceImages(in size: ScreenSize) -> Int {
        let pane = Rect(x: 0, y: 0, width: size.width, height: size.height)
        var frames = Set<String>()
        for image in lastAll where image.type == "Image" && !image.fromPicture {
            let frame = image.frame.intersection(pane)
            if frame.width >= 44, frame.height >= 44 { frames.insert(frame.described) }
        }
        return frames.count
    }

    private func workspaceDrag(from: (x: Double, y: Double)) -> WorkspaceDrag? {
        guard let pane = selectedPane else { return nil }
        let images = lastAll.filter { element in
            element.type == "Image" && !element.fromPicture && !element.text.isEmpty &&
                element.frame.x <= from.x && from.x <= element.frame.x + element.frame.width &&
                element.frame.y <= from.y && from.y <= element.frame.y + element.frame.height
        }
        // Identical labels on multiple visible images are not a unique item.
        let image = images.count == 1
            && lastAll.filter({ $0.type == "Image" && !$0.fromPicture && $0.text == images[0].text }).count == 1
            ? images[0].text : nil
        return WorkspaceDrag(fromApp: pane.app, toApp: pane.other, layout: workspaceLayout(pane.identity),
                             image: image, x: from.x, y: from.y)
    }

    func crossPaneDrag(_ spec: JSON, from: (x: Double, y: Double), until: Double) async throws {
        let side = spec["to_pane"]?.string ?? ""
        if let other = selectedPane?.other, interruptedDropApp == other || workspaceDrop?.before.app == other {
            throw ActionFailure(message: "a previous drag may already have landed in this app. Read the destination before issuing another drag; interrupted drags are not replayed in this task", delivery: .notSent)
        }
        guard let pane = selectedPane, confirmedPaneRead, side != pane.side,
              let source = workspaceReads[pane.side], let target = workspaceReads[side],
              source.layout == workspaceLayout(pane.identity), target.layout == source.layout,
              target.app == pane.other, now() - source.at < 60, now() - target.at < 60,
              let to = spec["to"]?.array?.compactMap(\.double), to.count == 2,
              (0..<target.size.width).contains(to[0]), (0..<target.size.height).contains(to[1]) else {
            throw ActionFailure(message: "read both panes in this task, then select the source again and use current [x, y] points for the drop", delivery: .notSent)
        }
        let drag = workspaceDrag(from: from)
        if let drag, workspaceDrags.contains(where: { $0.matches(drag) }) {
            throw ActionFailure(message: Self.repeatedDrop, delivery: .notSent)
        }
        let end = (to[0] + target.x - source.x, to[1] + target.y - source.y)
        let travel = min(2, max(0.25, (spec["ms"]?.double ?? 850) / 1000))
        let hold = min(2, max(0.15, (spec["hold_ms"]?.double ?? 360) / 1000))
        let rest = 0.35
        let finger = humanize.drag(from: from, to: end, seconds: travel, hold: hold, rest: rest)
        workspaceReads.removeValue(forKey: side)
        do {
            _ = try await runner.input("/poki/workspace-drag", Humanize.actions([finger]),
                                       timeout: min(until - now(), travel + hold + rest + 4), countsAsMiss: false)
            workspaceDrop = (target, .sent)
            if let drag { workspaceDrags.append(drag) }
        } catch let error as RunnerError where error.delivery == .unknown {
            workspaceDrop = (target, .unknown)
            interruptedDropApp = target.app
            swipeUnread = true
            throw error
        } catch is CancellationError {
            // The call can be cancelled while the driver still holds the finger down.
            workspaceDrop = (target, .unknown)
            interruptedDropApp = target.app
            swipeUnread = true
            throw CancellationError()
        }
        swipeUnread = true
    }

    private func clearTaskScreenshotCache() {
        lastPNG = nil; lastPNGAt = nil; lastPicture = nil; pictureOnlyShare = nil
    }

    private func resetScreenForNewTask(session: String?, localTask: String?) {
        guard selectedPane == nil || selectedPane?.session == session else { return }
        let taskChanged = localTask != activeLocalTask
        guard beginsTask() || taskChanged else { return }
        clearTaskScreenshotCache()
        if taskChanged { origin = nil; lastWorkingApp = nil; lastForeground = nil }
        activeLocalTask = localTask
    }

    private func clearPaneRead() {
        confirmedPaneRead = false
        clearTaskScreenshotCache()
        lastTree = nil; size = nil
        refs = [:]; listed = []; lastAll = []; lastTreeAt = nil; lastForeground = nil; skillStepApp = nil
        typedInto = nil; typedText = nil; swipeUnread = false
    }

    private func invalidateWorkspaceRead() {
        if let drop = workspaceDrop { interruptedDropApp = drop.before.app }
        workspaceReads.removeAll()
        approvals.discardWorkspaceDecisions(session: workspaceOwner.value)
        clearPaneRead()
    }

    private func referencedTargets(in action: JSON) -> [ApprovalScope.Target] {
        Self.refs(in: action).sorted().map { n in
            guard let element = refs[n] else { return .init(ref: n, type: "missing", label: "", identifier: "") }
            return .init(ref: n, type: element.type, label: element.label ?? "", identifier: element.identifier ?? "")
        }
    }

    /// What an approval for these actions covers: the pane, the app in front, the actions and the
    /// controls they name in the latest read. After actions that change the screen, the controls are
    /// not read yet.
    private func approvalScope(_ actions: [JSON], afterPrefix prefix: [JSON] = []) -> ApprovalScope {
        let steps = JSON.array(actions).serialized()
        let prefixChangesScreen = prefix.contains { ActionKind($0)?.changesScreen($0) == true }
        let app = prefixChangesScreen ? "after_change" : "\(lastForeground?.bundleID ?? "")|\(lastForeground?.name ?? "")"
        let key = "\(app)\n\(steps)"
        return ApprovalScope(actions: selectedPane.map { "\($0.identity)\n\(key)" } ?? key,
                             targets: prefixChangesScreen ? [] : actions.flatMap(referencedTargets),
                             readAt: lastTreeAt ?? now())
    }

    /// Drop references on an owner stop without a runner request or a visible app switch.
    func forgetTask(discardingPane: Bool = false) {
        if let ws = workspaceOwner.value {
            approvals.discardWorkspaceDecisions(session: ws)
        } else {
            approvals.discardAll()
        }
        endHandoff()
        if discardingPane {
            selectedPane = nil
            paneOffset = nil
            authorizationRead = nil
            clearPaneRead()
        }
        if selectedPane == nil { workspaceOwner.value = nil }
        origin = nil
        lastWorkingApp = nil
        lastForeground = nil
        activeLocalTask = nil
        workspaceReads.removeAll()
        workspaceDrop = nil
        interruptedDropApp = nil
        workspaceDrags.removeAll()
        if selectedPane != nil { clearPaneRead() } else { clearTaskScreenshotCache() }
    }

    /// The answer with the reason for a restart this side made, reported once: the model learns why
    /// its last calls got nothing and that the runner is a fresh one (its numbers start over).
    func restartNote(_ result: ToolResult) -> ToolResult {
        guard let why = runner.lastRestart.update({ r -> String? in defer { r = nil }; return r }) else { return result }
        var result = result
        result.text = "runner: \(why); this is the new runner\n" + result.text
        return result
    }

    /// WDA's lock state, without a session; unknown counts as unlocked (a failed read must not block).
    func isLocked() async -> Bool {
        (try? await runner.raw("GET", "/wda/locked", timeout: 1, countsAsMiss: false))?.bool ?? false
    }

    private func unlockForLocalTask(until: Double) async -> Bool {
        let timeout = min(16, until - now() - config.readTimeout)
        guard timeout > 0, approvals.pending == nil, !handoffWaiting, !Task.isCancelled else { return false }
        let unlocked = await host.unlockForLocalTask(timeout: timeout)
        if selectedPane != nil {
            invalidateWorkspaceRead()
            selectedPane = nil
            paneOffset = nil
        } else {
            clearPaneRead()
        }
        authorizationRead = nil
        return unlocked
    }

    static let authorizationWait: Double = 90

    private enum AuthorizationWait { case none, ready, freshScreen }

    private enum RunnerReadiness {
        case ready(deadline: Double, revision: UInt64?)
        case blocked(ToolResult)
    }

    private func waitForRunner(until: Double, authorization: AuthorizationWait) async -> RunnerReadiness {
        var state = host.runnerState()
        let wasStarting = state.isStarting
        let startupDeadline = min(now() + config.runnerWait, until - config.readTimeout - 1)
        var authorizationDeadline: Double?
        var waitedForOwner = false
        while state.isStarting, !Task.isCancelled {
            if authorization != .none {
                if state.isWaitingForAutomation, authorizationDeadline == nil {
                    authorizationDeadline = now() + Self.authorizationWait
                }
                if case .awaitingAutomationAuthorization = state { waitedForOwner = true }
            }
            guard now() < (authorizationDeadline ?? startupDeadline) else { break }
            await sleep(seconds: 0.25)
            state = host.currentRunner
        }
        if Task.isCancelled {
            return .blocked(ToolResult(text: "Task stopped. Nothing was sent.", jpeg: nil, isError: true))
        }
        if wasStarting { runner.forgetRunner() }
        if let authorizationDeadline, now() >= authorizationDeadline {
            return .blocked(ToolResult(text: "Poki stopped waiting for automation to be ready. Nothing was sent.", jpeg: nil, isError: true))
        }
        if state.isRunning {
            if authorizationDeadline != nil {
                // The owner may have left the phone on a different screen while approving automation.
                if authorization == .freshScreen, waitedForOwner { return .blocked(readRequiredAfterAuthorization()) }
                return .ready(deadline: now() + config.toolDeadline, revision: state.automationRevision)
            }
            return .ready(deadline: until, revision: state.automationRevision)
        }
        if case .automationAuthorizationDeclined = state {
            let recovery = authorization == .none ? " Fix it on the phone, then call look again." : ""
            return .blocked(ToolResult(text: "runner: \(state.describe)\nNothing was sent.\(recovery)", jpeg: nil, isError: true,
                                       automationAuthorizationDeclined: authorization != .none))
        }
        let why = runner.lastRestart.value.map { "runner: \($0)\n" } ?? ""
        if case .failed = state {
            return .blocked(ToolResult(text: "runner: \(state.describe)\nNothing was sent. Fix it on the phone, then call look again.", jpeg: nil, isError: true))
        }
        return .blocked(ToolResult(text: "\(why)runner: \(state.describe)\nNothing was sent. Call look or status again in a few seconds and continue the task when automation is ready.", jpeg: nil, isError: false, waitingForOwner: true))
    }

    func bindCompanionTarget() async -> Bool {
        guard case .ready = await waitForRunner(until: now() + config.toolDeadline, authorization: .ready),
              !Task.isCancelled else { return false }
        return (try? await runner.call("POST", "/poki/companion-target", timeout: 4, countsAsMiss: false))?.bool == true
    }

    private func readRequiredAfterAuthorization() -> ToolResult {
        ToolResult(text: "Automation is ready. Nothing was sent. Call look to read the current screen before choosing the next action. Coordinates need a current screenshot; element numbers need current references. Send {button: \"home\"} by itself to search from the Home Screen, or launch the task's app in a separate call.",
                   jpeg: nil, isError: true)
    }

    private func hasRequiredScreenEvidence(_ action: JSON, evidence: ScreenEvidence) -> Bool {
        guard let kind = ActionKind(action) else { return true }
        let target = action[kind.rawValue]
        func sourceForPoint(_ point: JSON?) -> ScreenEvidence {
            if point?.array != nil || (point?["ref"]?.int == nil && point?["x"]?.double != nil && point?["y"]?.double != nil) {
                return .screenshot
            }
            return .references
        }
        switch kind {
        case .launch, .handoff, .wait, .waitUntil:
            return true
        case .button:
            return target?.text?.lowercased() == "home" || !evidence.isEmpty
        case .tap, .longPress, .pinch:
            return evidence.contains(sourceForPoint(target))
        case .drag:
            if target?.array != nil { return evidence.contains(.screenshot) }
            return evidence.contains(sourceForPoint(target?["from"]).union(sourceForPoint(target?["to"])))
        case .type:
            return action["ref"] == nil && action["into"] == nil ? !evidence.isEmpty : evidence.contains(.references)
        case .scrollTo:
            // Scrolling to a text reads the screen as it goes; a number is the latest read's.
            return target?.string != nil || (target?["ref"] == nil && target?["in"] == nil && target?["text"] != nil) || evidence.contains(.references)
        case .swipe:
            return (target?["in"] ?? action["in"]) == nil ? !evidence.isEmpty : evidence.contains(.references)
        case .path:
            // A path's steps name their targets by text and each waits for its target on the screen it
            // lands on, so no earlier read is needed for them; only a point in one is the screenshot's.
            let steps = target?["steps"]?.array ?? target?.array ?? []
            return steps.allSatisfy { canActInPathAfterAuthorization($0, evidence: evidence) }
        case .back:
            return currentBackTarget.button == nil ? !evidence.isEmpty : evidence.contains(.references)
        case .run:
            // A saved skill waits for each target and acts on a single match, as a path does.
            return true
        case .key:
            return !evidence.isEmpty
        }
    }

    private func canActInPathAfterAuthorization(_ step: JSON, evidence: ScreenEvidence) -> Bool {
        guard let kind = ActionKind(step), kind != .path else { return false }
        let target = step[kind.rawValue]
        switch kind {
        case .tap, .longPress:
            return target?.array == nil && target?["x"] == nil ? true : evidence.contains(.screenshot)
        case .type:
            return step["into"] != nil || !evidence.isEmpty
        case .swipe:
            return true
        default:
            return hasRequiredScreenEvidence(step, evidence: evidence)
        }
    }

    // MARK: do

    /// How long to hold for the owner: `approvalWait`, but a relay stops waiting for its caller at
    /// `answerBy`, so the hold ends early enough for the answer (a read of the screen, and a margin)
    /// to get there first. The request stays open: the owner approves, and the same `do` sent again runs.
    func approvalHold(answerBy: Double?) -> Double {
        guard let answerBy else { return config.approvalWait }
        return max(0, min(config.approvalWait, answerBy - now() - config.readTimeout - Self.relayMargin))
    }
    static let relayMargin = 2.0

    /// What one action may take (`run` holds each to it). A launch gets 9 s; a fresh one (the app
    /// ended first, up to 6 s on its own) 14 s. A type is a tap, a wait for the focus and the keys (and
    /// a wait for a busy runner): 9 s. A wait_until gets the time it asks for (up to 10 s) plus a read:
    /// 8000 ms asked became 6000 under the action cap (gym, an app relaunch under the wait).
    func actionCap(_ action: JSON) -> Double {
        // A routine's steps each have their own time inside it; the run as a whole has the call's.
        if action["run"] != nil || action["path"] != nil { return max(config.actionCap, config.toolDeadline - config.readTimeout - 1) }
        if action["launch"] != nil { return max(config.actionCap, action["launch"]?["fresh"]?.bool == true ? 14 : 9) }
        if action["scroll_to"] != nil { return max(config.actionCap, Self.scrollCap) }
        if action["type"] != nil { return max(config.actionCap, 9) }
        if action["wait_until"] != nil { return max(config.actionCap, min(10, max(0.2, (action["wait_until"]?["ms"]?.double ?? 3000) / 1000)) + 1.5) }
        return config.actionCap
    }

    /// The most `actions`, the pause after the last and the read of the screen can take once they
    /// start, each action within its own cap. The call's deadline (`until`) may bound it sooner.
    func timeToFinish(_ actions: [JSON], until: Double) -> Double {
        let longestPause = Self.settle.values.max() ?? 1
        return min(max(0, until - now()), actions.reduce(0) { $0 + actionCap($1) } + longestPause + config.readTimeout)
    }

    /// `byOwnersVoice`: the Voice tab's model acting for the owner, not the agent: it is not held back
    /// by a step handed to the owner, and it leaves the agent's unused approval in place.
    func act(actions: [JSON], full: Bool, finish: Bool = false, session: String? = nil, answerBy: Double? = nil, app: JSON? = nil, byOwnersVoice: Bool = false, local: Bool = false, localTask: String? = nil, onActionSucceeded: PokiCore.ActionSucceeded?) async -> ToolResult {
        resetScreenForNewTask(session: session, localTask: localTask)
        let originalActionCount = actions.count
        var actions = actions
        var bound: String?
        if config.appNames() {
            do {
                actions = try actions.map(resolvingLaunchNames)
            } catch {
                return ToolResult(text: "\(error)", jpeg: nil, isError: true)
            }
            // The session's app: named once, kept until it is let go, a task ends or a new one begins.
            if beginsTask() { sessionApp = nil }
            if let app {
                if app == .bool(false) || app == .null {
                    sessionApp = nil
                } else if let text = app.string,
                          case let given = text.trimmingCharacters(in: .whitespacesAndNewlines), !given.isEmpty {
                    guard let bundle = config.resolveInstalledApp(text) else {
                        return ToolResult(text: unknownApp(given).message, jpeg: nil, isError: true)
                    }
                    sessionApp = (bundle, given, session)
                    if actions.first?["launch"] == nil, actions.count < 20, await !isInFront(bundle) { actions.insert(["launch": .string(bundle)], at: 0) }
                } else {
                    return ToolResult(text: "do: app takes the app's name or bundle id, or false to let go of the session's app; nothing was sent", jpeg: nil, isError: true)
                }
            }
            if let kept = sessionApp, kept.session == session { bound = kept.bundle }
        } else if let app, app != .bool(false), app != .null {
            // Apps by Name is off (the app's Testing Options): the actions would go to whatever app is
            // in front, so none is sent.
            return ToolResult(text: "do: app is turned off on this phone (Apps by Name, in Poki's Testing Options); nothing was sent. Send the actions without app, starting with {launch: \"bundle id\"} when the app is not in front", jpeg: nil, isError: true)
        }
        let actionSucceeded: PokiCore.ActionSucceeded?
        if let onActionSucceeded, actions.count > originalActionCount {
            // The app binding prepended a launch, which has no index in the model's batch.
            actionSucceeded = { index, step, skill in
                if index > 0 { onActionSucceeded(index - 1, step, skill) }
            }
        } else {
            actionSucceeded = onActionSucceeded
        }
        var result = restartNote(await actNow(actions: actions, full: full, finish: finish, session: session, answerBy: answerBy, byOwnersVoice: byOwnersVoice, local: local, localTask: localTask, onActionSucceeded: actionSucceeded))
        if local, let read = authorizationRead, read.task == localTask, let evidence = result.screenEvidence,
           host.currentRunner.automationRevision == read.revision {
            let keepErrorEvidence = result.isError && actions.contains { $0["run"] != nil || $0["path"] != nil }
                && lastForeground.map { !config.isPoki($0) } == true
            authorizationRead = (read.revision, localTask, result.isError && !keepErrorEvidence ? [] : evidence)
        }
        if finish { sessionApp = nil }
        else if let bound, let kept = sessionApp, let front = lastForeground?.bundleID, front != bound, !config.isPoki(lastForeground) {
            result.text += "\nthe session's app \(kept.name) (\(bound)) is not in front; \(lastForeground?.describe ?? front) is. app: \"\(kept.name)\" brings it back; app: false lets go of it"
        }
        return result
    }

    /// Whether the session's app is in front, so nothing needs bringing forward: the latest read says
    /// so. A read more than a few seconds old is checked with the runner (the owner may have switched
    /// apps since), and a runner that does not answer leaves the read's word standing.
    func isInFront(_ bundle: String) async -> Bool {
        guard lastForeground?.bundleID == bundle else { return false }
        if let at = lastTreeAt, now() - at < 10 { return true }
        guard let info = try? await runner.raw("GET", "/wda/activeAppInfo", timeout: 1.5, countsAsMiss: false), let front = info["bundleId"]?.string, !front.isEmpty else { return true }
        return front == bundle
    }

    private func unknownApp(_ name: String) -> ActionFailure {
        ActionFailure(message: "do: no app named \"\(name)\" is known on this phone; nothing was sent. Give its bundle id. To search from the Home Screen, send {button: \"home\"} by itself. Use the returned screen to swipe down, then type the app's name and tap its result.", delivery: .notSent)
    }

    private func installedLaunchBundle(_ given: String) throws -> String {
        guard let bundle = config.resolveInstalledApp(given) else {
            throw unknownApp(given.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return bundle
    }

    private func resolvingLaunchNames(_ action: JSON) throws -> JSON {
        guard case .object(var fields) = action else { return action }
        if let spec = fields["launch"] {
            if let given = spec.string {
                fields["launch"] = .string(try installedLaunchBundle(given))
            } else if case .object(var launch) = spec, launch["bundle"]?.string == nil {
                if let name = launch["name"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) {
                    guard let bundle = config.resolveApp(name) else { throw unknownApp(name) }
                    launch["bundle"] = .string(bundle)
                } else if let given = launch["app"]?.string {
                    launch["bundle"] = .string(try installedLaunchBundle(given))
                } else {
                    return action
                }
                launch["name"] = nil
                launch["app"] = nil
                fields["launch"] = .object(launch)
            }
            return .object(fields)
        }
        if case .object(var path)? = fields["path"], let steps = path["steps"]?.array {
            path["steps"] = .array(try steps.map(resolvingLaunchNames))
            fields["path"] = .object(path)
            return .object(fields)
        }
        if let steps = fields["path"]?.array {
            fields["path"] = .array(try steps.map(resolvingLaunchNames))
            return .object(fields)
        }
        return action
    }

    func actNow(actions: [JSON], full: Bool, finish: Bool = false, session: String? = nil, answerBy: Double? = nil, byOwnersVoice: Bool = false, local: Bool = false, localTask: String? = nil, onActionSucceeded: PokiCore.ActionSucceeded?) async -> ToolResult {
        scrollFound = nil
        scrollObservation = nil
        typedInto = nil
        // The approval event carries the source that raised it. Grant matching
        // remains the upstream workspace/action policy until unified Core #609.
        let sourceSession: String? = (local || byOwnersVoice) ? nil : (session ?? anonymousExternalOrigin)
        var started = now()
        let callStarted = started
        var approvalWaited = 0.0
        var until: Double
        let revision: UInt64?
        let needsCurrentScreen = actions.contains { !hasRequiredScreenEvidence($0, evidence: []) }
        let authorization: AuthorizationWait = local ? (needsCurrentScreen ? .freshScreen : .ready) : .none
        switch await waitForRunner(until: started + config.toolDeadline, authorization: authorization) {
        case .ready(let deadline, let readyRevision): (until, revision) = (deadline, readyRevision)
        case .blocked(let result): return result
        }
        if local, let revision {
            let read = authorizationRead
            let evidence = read?.revision == revision && read?.task == localTask ? read?.evidence ?? [] : []
            if actions.contains(where: { !hasRequiredScreenEvidence($0, evidence: evidence) }) {
                return readRequiredAfterAuthorization()
            }
        }
        if let selectedPane, selectedPane.session != session { return workspaceInUse() }
        // The app the owner is in before anything is sent: the read before may be another task's.
        if beginsTask() || recordingTask != localTask {
            beginRecording(task: localTask)
            typedText = nil
            if let front = try? await runner.call("GET", "/wda/activeAppInfo", timeout: 1.5), let bundle = front["bundleId"]?.string {
                origin = (Foreground(bundleID: bundle, name: front["name"]?.string), session, now())
                skillStepApp = bundle
            }
        } else {
            origin?.lastCall = now()
        }

        // A runner still finishing a request this side gave up on gets nothing new: what is sent now
        // would wait its turn and run late, after the model had moved on.
        if await !runner.waitUntilFree(timeout: min(config.actionCap, until - now() - config.readTimeout - 0.5)), let busy = runner.busyWith {
            return await withPicture("not_sent: the runner is still finishing an earlier \(busy); nothing was sent. Call look again in a few seconds; it answers when the runner is through, or after the restart.", timeout: until - now() - 0.5, isErrorWithoutPicture: false)
        }

        // While a step is handed to the owner, nothing is sent (they may be typing a password):
        // the model sees the screen, waits, or takes the step back.
        let harmless = actions.allSatisfy { $0["wait"] != nil || $0["wait_until"] != nil || $0["handoff"] != nil }
        if let action = actions.first, let drag = action["drag"], drag["to_pane"] != nil,
           let from = try? point(drag["from"]), let attempted = workspaceDrag(from: from),
           workspaceDrags.contains(where: { $0.matches(attempted) }) {
            return ToolResult(text: "not_sent: \(Self.repeatedDrop)",
                              jpeg: nil, isError: true)
        }
        if !harmless, !byOwnersVoice, let h = handoff.active {
            var result = await withPicture("not_sent: a step is handed to the owner (\(h.kind): \"\(h.text.prefix(80))\"), so no input is sent until they tap Done on the phone or you send {handoff: false}. Keep polling with look, or {wait_until: {handoff_done: true, ms: 10000}}.", timeout: until - now() - 0.5, isErrorWithoutPicture: false)
            result.waitingForOwner = true
            return result
        }
        let onlyButtons = actions.allSatisfy { $0["button"] != nil || $0["wait"] != nil }
        if !onlyButtons, await isLocked() {
            guard localTask != nil, !harmless else {
                return ToolResult(text: "screen: locked. Nothing was sent. The owner has to unlock the phone; call look once they have.", jpeg: nil, isError: true, waitingForOwner: true)
            }
            guard await unlockForLocalTask(until: until) else {
                let result = await readAndReply(until: until, full: true, error: "Automatic unlock could not be confirmed. Nothing was sent. Call look before choosing the next action.")
                return await isLocked() ? lockedScreen(result) : result
            }
            if needsCurrentScreen {
                return await readAndReply(until: until, full: true, error: "The iPhone unlocked. No requested action was sent. Call look before acting on the new screen.")
            }
        }
        if selectedPane != nil, !harmless, !confirmedPaneRead {
            return ToolResult(text: "Split View: look at the selected pane before sending input; nothing was sent",
                              jpeg: nil, isError: true, splitViewNeedsRead: true)
        }

        // The approval card is in Poki: no input lands there, and the request waiting stays for the owner.
        if landsInPoki(actions) {
            return ToolResult(text: "not_sent: \(CoreConfig.ownAppRefusal). Nothing was sent. Leave Poki first ({button: \"home\"} or {launch: \"bundle id\"}).", jpeg: nil, isError: true)
        }

        // A number that is not in the latest read is refused before anything is sent.
        let stale = Set(actions.flatMap(Self.refs(in:))).filter { refs[$0] == nil }.sorted()
        if !stale.isEmpty {
            return await readAndReply(until: until, full: true, error: "element \(stale.map(String.init).joined(separator: ", ")) is not in the latest read; nothing was sent. The current elements are below.")
        }

        if config.sensitive.enabled {
            var scan = SensitiveScan(front: lastForeground, secureOnScreen: lastElements.contains(where: \.isSecure))
            for (at, action) in actions.enumerated() {
                if scan.moved, let kind = ActionKind(action), presses(kind, action, scan, unread: false).contains(where: \.atPoint) {
                    var result = await actNow(actions: Array(actions[..<at]), full: full, finish: false, session: session, answerBy: answerBy, byOwnersVoice: byOwnersVoice, local: local, localTask: localTask, onActionSucceeded: onActionSucceeded)
                    result.text += "\nnot_sent from action \(at + 1): a coordinate action needs a fresh read after an earlier action that could change the screen. This check runs before the final screen comparison. Choose the remaining actions from the screen above and send them in a new do call. Do not repeat actions already sent."
                    return result
                }
                if sensitive(action, &scan) != nil { break }
            }
        }

        // The runner's start and the checks above are not the actions' time (seen on the phone: a
        // launch sent while the runner was starting had its 9 s used up before it went). The call's
        // backstop allows `runnerWait` for that, so the shift stops there: a runner that was waited
        // for and then busy for the action cap on top (the soak, call 111) must not push the
        // actions past the backstop, which answers with nothing.
        let prepared = now()
        until += min(prepared - started, config.runnerWait)
        started = prepared
        let before = lastForeground
        var extra: [String] = []
        // The screen before the actions, for the read after them: only a read that differs from it
        // shows that the actions have landed.
        let seenBefore: String? = size.flatMap { screen in lastTreeAt == nil ? nil : listable(lastAll, screen).map { "\($0.key)@\($0.frame.described)" }.joined(separator: ";") }

        // Approval: from the first action that needs it, nothing is sent until the owner approves it
        // on the phone. The actions before it are plain and go first (seen on the phone: a last
        // selection tap held back with the Delete after it was never made, so the Delete, once
        // approved, would have missed it).
        var did: [String] = []
        var error: String?
        var lastKind: String?
        var toRun = actions
        // What the screen said before these actions, for the send check: a message that was already there does not count as sent.
        let textsBefore = lastAll.filter { !$0.fromPicture && !Self.fieldTypes.contains($0.type) }.map(\.text)
        var approvedNote: String?
        let steps = sensitiveSteps(actions)
        let sensitive = firstSensitive(actions)
        let workspaceSession = workspaceOwner.value
        let matchingScope = sensitive.map { approvalScope(Array(actions[$0.at...]), afterPrefix: Array(actions[..<$0.at])) }
        // Any other actions withdraw an unconsumed request or grant so stale approvals never carry over.
        // The owner's voice leaves the agent's unused grant in place.
        approvals.withdrawMismatching(scope: matchingScope, workspaceSession: workspaceSession, keepingGrant: byOwnersVoice)
        // The gated actions on their own, on the screen the model saw, before anything is sent.
        let gatedAlone = sensitive.map { approvalScope(Array(actions[$0.at...])) }
        if let (at, reason) = sensitive {
            let tail = Array(actions[at...])
            let scope = matchingScope!
            if approvals.consumeGrant(scope: scope, workspaceSession: workspaceSession) != nil {
                approvedNote = "approval: approved on the phone (\(reason))"
            } else {
                if at > 0 {
                    (did, error, lastKind) = await run(Array(actions[..<at]), started: started, until: until, onActionSucceeded: onActionSucceeded)
                    if error != nil {
                        return await readAndReply(until: until, full: full, changes: true, did: did, error: error, extra: ["action \(at + 1) and the actions after it were not sent (they would have needed the owner's approval: \(reason))"])
                    }
                }
                let approval = approvals.pending.flatMap { $0.covers(scope, workspaceSession: workspaceSession) ? $0 : nil }
                    ?? approvals.request(app: lastForeground?.describe ?? "unknown", summary: labels(tail), reason: reason, scope: scope, workspaceSession: workspaceSession,
                                           stopsWhenOff: sensitiveSteps(actions, under: config.sensitive.asked(.off)).isEmpty,
                                           sourceSession: sourceSession)
                // The time the owner takes is not the actions' time: the clock starts again after it.
                let asked = now()
                let outcome = await approvals.wait(id: approval.id, seconds: approvalHold(answerBy: answerBy))
                let waited = now() - asked
                until += waited
                started += waited
                approvalWaited += waited
                // The caller gave up while the owner was being waited for (the relay sent `cancel`): the
                // model will send these actions again, so nothing is sent for this call, whatever the owner does.
                if Task.isCancelled {
                    approvals.discardWorkspaceDecisions(session: workspaceSession)
                    return ToolResult(text: "cancelled: the caller stopped waiting before the owner answered; nothing was sent from action \(at + 1).", jpeg: nil, isError: true)
                }
                // The owner's approval can open Poki: the app comes back before anything is sent into Poki.
                // Nothing of the owner's can have done that while the request is still unanswered, and
                // the time is the answer's.
                if outcome != nil, let back = await bringBack(from: before, why: "after the approval", check: true) { extra.append(back) }
                let sentFirst = at > 0 ? " Actions 1 to \(at) were sent (below)." : ""
                let again = at > 0 ? "send action \(at + 1)\(tail.count > 1 ? " to \(actions.count)" : "") again, on their own" : "send the same actions again"
                switch outcome {
                case .approved? where answerBy.map({ now() + timeToFinish(tail, until: until) + Self.relayMargin > $0 }) == true:
                    // Too late for the relay: the actions would run after it answered its caller with a 504, and
                    // the model would send them again. The approval stays; the same actions sent again run at once.
                    return await refusedAwaitingResend(approval, tail: tail, before: gatedAlone!, at: at, until: until, full: full, did: did, text: "not_sent from action \(at + 1): approval_required (id \(approval.id)): \(reason). The owner approved on the phone, but too late for this call to send the actions and read the screen before the relay gives up on it.\(sentFirst) The approval is kept: \(again) and they run at once (within \(Int(approvals.lifetime / 60)) minutes).")
                case .approved?:
                    guard approvals.consumeGrant(scope: scope, workspaceSession: workspaceSession) != nil else {
                        return await refused(until: until, full: full, did: did, text: "not_sent from action \(at + 1): approval_required (id \(approval.id)): \(reason). The approval went to another call with the same actions, so nothing was sent from this one.\(sentFirst) To run them, \(again) and ask again.")
                    }
                    approvedNote = "approval: approved on the phone after \(Int(waited.rounded())) s (\(reason))"
                    toRun = tail
                case .declined?:
                    return await refused(until: until, full: full, did: did, text: "not_sent from action \(at + 1): the owner declined on the phone (\(reason)).\(sentFirst)")
                case .expired?:
                    return await refused(until: until, full: full, did: did, text: "not_sent from action \(at + 1): the approval request ended unanswered (\(reason)).\(sentFirst)")
                case nil:
                    return await refusedAwaitingResend(approval, tail: tail, before: gatedAlone!, at: at, until: until, full: full, did: did, text: "not_sent from action \(at + 1): approval_required (id \(approval.id)): \(reason). The owner was asked on the phone.\(sentFirst) When they approve, \(again) (within \(Int(approvals.lifetime / 60)) minutes); other actions withdraw the request.")
                }
            }
        }

        let numberTap = local && !finish && sensitive == nil && config.quickRead() ? numberTapTarget(actions) : nil
        let generation = nextActionGeneration()
        let beforePicture = lastPicture
        let actionsStarted = now()
        let approved = approvedNote == nil ? [:] : Dictionary(steps.map { ($0.at, $0.reason) }, uniquingKeysWith: { a, _ in a })
        let movedBefore = actions[..<(actions.count - toRun.count)].contains { ActionKind($0)?.changesScreen($0) == true }
        let (moreDid, moreError, moreKind) = await run(toRun, started: started, until: until, numberedFrom: actions.count - toRun.count, moved: movedBefore, approved: approved, onActionSucceeded: onActionSucceeded)
        let actionsTook = now() - actionsStarted
        did += moreDid
        error = moreError
        lastKind = moreKind ?? lastKind
        let readStarted = now()
        var tapRead: TapRead?
        if error == nil, moreKind == ActionKind.tap.rawValue, let numberTap {
            tapRead = await readNumberTap(numberTap, started: readStarted, until: until)
            if let tapRead, !tapRead.confirmed {
                if tapRead.reading?.png == nil {
                    lastPNG = nil
                    lastPNGAt = nil
                }
                extra.append("touch effect: unconfirmed (\(tapRead.reason)). Recheck the display with look before continuing. The tap was sent once.")
            }
        }
        let launched = toRun.compactMap { $0["launch"].flatMap { $0.string ?? $0["bundle"]?.string } }.last
        var screenObservation: FreshScreenObservation?
        if error == nil, tapRead == nil, config.quickRead(), selectedPane == nil, !finish {
            if moreKind == ActionKind.scrollTo.rawValue, let scroll = scrollObservation {
                screenObservation = await readAfterScroll(scroll, generation: generation, beforePicture: beforePicture, until: until)
            } else if moreKind == ActionKind.launch.rawValue, let launched {
                screenObservation = await readAfterLaunch(bundleID: launched, beforeApp: before?.bundleID, beforePicture: beforePicture, generation: generation, started: readStarted, until: until)
            }
            if let screenObservation, screenObservation.omitStalePicture {
                lastPNG = nil
                lastPNGAt = nil
                extra.append("screenshot omitted: only a pre-action image arrived after the action; call look before tapping coordinates")
            }
        }
        if let lastKind, tapRead?.reading == nil, screenObservation?.reading == nil {
            cancelPreparedCapture()
            let elapsed = (tapRead == nil && screenObservation == nil) ? 0 : now() - readStarted
            let remainingPause = (Self.settle[lastKind] ?? 0.4) - elapsed
            let pause = min(remainingPause, max(0, until - now() - config.readTimeout - 0.3))
            if pause >= 0.6, config.quickRead(), let seen = seenBefore {
                // The long pauses (a launch, a swipe, a hardware button) cover the slowest screens: one
                // that has changed and holds still across two reads is read now.
                let outcome = await settledPause(pause, before: seen, generation: generation, earliestAllowedAt: readStarted, beforePicture: beforePicture, until: until)
                did.append(outcome.settled ? "read after \(Int((outcome.waited * 1000).rounded())) ms: the screen had changed and held still" : "paused \(Int((outcome.waited * 1000).rounded())) ms before reading")
                if let reused = outcome.observation {
                    screenObservation = reused
                    if reused.omitStalePicture {
                        lastPNG = nil
                        lastPNGAt = nil
                        extra.append("screenshot omitted: only a pre-action image arrived after the action; call look before tapping coordinates")
                    }
                }
            } else if pause > 0.01 {
                await sleep(seconds: pause)
                did.append("paused \(Int((pause * 1000).rounded())) ms before reading")
            }
        }
        if local, finish, actions.isEmpty, error == nil {
            let line = await returnToOrigin() ?? "finish: the app this task began in is not known, so the phone stays here"
            var lines = [line]
            if trace.count >= 2, !skillRanWhole {
                lines.append("learn: this task took \(trace.count) recorded steps; if it worked and may be asked for again, skills {action: \"save\", name, description} keeps them so do {run: name} repeats them in one call next time")
            }
            return ToolResult(text: lines.joined(separator: "\n"), jpeg: nil)
        }
        let checkingTouch = actions.count == 1 && error == nil
            && (moreKind == ActionKind.tap.rawValue || moreKind == ActionKind.longPress.rawValue)
        // What the model saw last, so a read made again in this call still compares with it.
        let seenTree = lastTree, seenPicture = lastPicture
        var result = await readAndReply(until: until, full: full, changes: true, checkingTouch: checkingTouch && tapRead == nil, did: did, error: error,
                                        extra: (approvedNote.map { [$0] } ?? []) + extra, reading: tapRead?.reading ?? screenObservation?.reading)
        // The read shows Poki in front where another app was being worked in: a tap at the top of
        // the screen landed on Poki's Live Activity in the Dynamic Island. The app comes back and
        // the read is made again, so the model never sees (or acts in) Poki's own screen.
        if tapRead == nil, screenObservation == nil, config.isPoki(lastForeground), !toRun.contains(where: { $0["launch"] != nil }), until - now() > config.readTimeout + 1,
           let back = await bringBack(from: before, why: "after the actions (a tap near the top of the screen lands on Poki's Live Activity in the Dynamic Island)", check: false) {
            result = await readAndReply(until: until, full: full, changes: true, checkingTouch: checkingTouch, did: did, error: error, extra: (approvedNote.map { [$0] } ?? []) + extra + [back])
        }
        // After a launch the runner's tree can still be the old app's while the picture is the new
        // app's (gym: Photos launched from Safari answered Safari's whole tree under Photos' screen,
        // twice). The read is made again, within the call, until the launched app is in front, or
        // when the whole picture changed over an unchanged tree.
        var rereads = 0
        // Up to six re-reads: a cold launch on the simulator (Photos from Safari) had the old app in
        // front past the third re-read at 5.8 s (gym finding 39); the action's time bounds them.
        while rereads < 6, until - now() > config.readTimeout + 1 {
            let notYetInFront = launched.map { lastForeground?.bundleID != nil && lastForeground?.bundleID != $0 } ?? false
            let stalePicture = (pictureOnlyShare ?? 0) >= 0.9
            guard notYetInFront || stalePicture else { break }
            // A system alert over the launched app (a permission prompt): no re-read brings the app
            // in front; the answer says so, so the model answers the alert first.
            if notYetInFront, lastForeground?.bundleID == "com.apple.springboard", let alert = alertOnScreen() {
                result.text += "\na system alert is in front (\(alert)); the launched app is behind it: answer the alert first"
                break
            }
            rereads += 1
            await sleep(seconds: 0.4)
            let why = notYetInFront ? "\(launched!) was not in front yet" : "the whole picture had changed while the elements had not (an app's tree can lag its screen)"
            lastTree = seenTree
            lastPicture = seenPicture
            result = await readAndReply(until: until, full: full, changes: true, checkingTouch: checkingTouch, did: did, error: error, extra: (approvedNote.map { [$0] } ?? []) + extra + ["the screen was read again (\(rereads)): \(why)"])
        }
        // The app this call opened answers no tree because its process has no accessibility server
        // (on the phone, WeChat for half an hour: "Error getting main window kAXErrorServerNotFound",
        // while Settings and Poki read; the same WeChat process read fine later). It is opened once
        // more from a fresh start, which brings up a process with one, and read again. Only an app the
        // call itself brought forward: ending one the owner was in would lose their place.
        let cameForward = launched ?? (lastForeground?.bundleID != before?.bundleID ? lastForeground?.bundleID : nil)
        if tapRead == nil, let app = cameForward, lastForeground?.bundleID == app, !config.isPoki(lastForeground), app != "com.apple.springboard",
           result.text.contains("kAXErrorServerNotFound"), until - now() > config.readTimeout + 4 {
            var how = "it was opened again from a fresh start"
            do {
                _ = try await runner.call("POST", "/wda/apps/terminate", ["bundleId": .string(app)], timeout: 6, countsAsMiss: false)
                _ = try await runner.call("POST", "/wda/apps/launch", ["bundleId": .string(app)], timeout: max(3, min(10, until - now() - config.readTimeout - 0.5)))
            } catch {
                how = "opening it again from a fresh start did not answer (\(error))"
            }
            await sleep(seconds: 0.4)
            lastTree = seenTree
            lastPicture = seenPicture
            result = await readAndReply(until: until, full: full, changes: true, checkingTouch: checkingTouch, did: did, error: error, extra: (approvedNote.map { [$0] } ?? []) + extra + ["\(app) answered no element tree (no accessibility server in its process: kAXErrorServerNotFound); \(how), so its earlier page is gone"])
        }
        if let line = sendCheck(toRun, error: error, textsBefore: textsBefore) { result.text += "\n" + line }
        if selectedPane != nil, error?.contains("split_view_changed") == true {
            invalidateWorkspaceRead()
            result.splitViewNeedsRead = true
        }
        // A call that took far longer than its parts says where the time went (gym: a wait_until
        // whose parts said 5 s answered after 29.8 s).
        let total = now() - callStarted
        let readTook = now() - readStarted
        #if canImport(OSLog)
        let deliveredAt = now()
        if let tapRead {
            let firstPicture = tapRead.firstPictureAt.map { String(Int((($0 - readStarted) * 1000).rounded())) } ?? "none"
            let target = tapRead.targetAt.map { String(Int((($0 - readStarted) * 1000).rounded())) } ?? "none"
            let rereads = tapRead.reading == nil ? tapRead.samples : max(0, tapRead.samples - 1)
            let timing = "tap observation: input_uptime=\(readStarted) first_picture_ms=\(firstPicture) target_tree_ms=\(target) read_ms=\(Int((readTook * 1000).rounded())) rereads=\(rereads) reason=\(tapRead.reason)"
            Logger(subsystem: "nz.zheha.poki", category: "screen").notice("\(timing, privacy: .public)")
        } else if let screenObservation {
            let base = screenObservation.inputAt
            let firstPicture = screenObservation.firstPictureAt.map { String(Int((($0 - base) * 1000).rounded())) } ?? "none"
            let target = screenObservation.targetAt.map { String(Int((($0 - base) * 1000).rounded())) } ?? "none"
            let totalReadMs = Int(((deliveredAt - base) * 1000).rounded())
            let rereads = screenObservation.reading == nil ? screenObservation.samples : max(0, screenObservation.samples - 1)
            let timing = "screen observation: kind=\(screenObservation.kind) input_uptime=\(base) pause_ms=\(screenObservation.pauseMs) first_picture_ms=\(firstPicture) target_tree_ms=\(target) read_ms=\(totalReadMs) delivered_uptime=\(deliveredAt) rereads=\(rereads) reused_tree=\(screenObservation.reusedTree) reason=\(screenObservation.reason)"
            Logger(subsystem: "nz.zheha.poki", category: "screen").notice("\(timing, privacy: .public)")
        }
        #endif
        let parts = (prepared - callStarted) + actionsTook + readTook + approvalWaited
        lastCallTook = total
        if total >= 8 || total - parts > 2 {
            result.text += "\ntook: \(Self.seconds(total)) s in all: \(Self.seconds(prepared - callStarted)) s before the actions (runner start, busy wait, lock check), \(Self.seconds(actionsTook)) s actions, \(Self.seconds(readTook)) s read\(approvalWaited > 0 ? ", \(Self.seconds(approvalWaited)) s the owner's approval" : "")\(total - parts > 2 ? ", \(Self.seconds(total - parts)) s elsewhere" : "")"
        }
        let openedApp = launched.map { lastForeground?.bundleID == $0 } ?? false
        let openedHome = toRun.count == 1 && toRun.first?["button"]?.text?.lowercased() == "home"
            && lastForeground?.bundleID == "com.apple.springboard"
        let ranAutonomous = toRun.contains { $0["run"] != nil || $0["path"] != nil }
            && lastForeground.map { !config.isPoki($0) } == true
        // Voice can open a Settings link before asking the runner to wait for its screen.
        let settledVoiceScreen = byOwnersVoice && actions.count == 1 && actions.first?["wait_until"]?["settled"]?.bool == true
        if local, !finish, let revision,
           (!result.isError && (openedApp || openedHome || settledVoiceScreen)) || ranAutonomous,
           let evidence = result.screenEvidence, !evidence.isEmpty, host.currentRunner.automationRevision == revision {
            authorizationRead = (revision, localTask, evidence)
        }
        // The read above is the work's last screen; the owner then sees their own app again.
        if finish, error == nil {
            let line = await returnToOrigin() ?? "finish: the app this task began in is not known, so the phone stays here"
            var lines = result.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            lines.insert(line, at: min(1, lines.count))
            if trace.count >= 2, !skillRanWhole {
                lines.append("learn: this task took \(trace.count) recorded steps; if it worked and may be asked for again, skills {action: \"save\", name, description} keeps them so do {run: name} repeats them in one call next time")
            }
            result.text = lines.joined(separator: "\n")
        }
        return result
    }

    /// Chat apps, where Return sends what the message field holds. The approval rules' own list may be
    /// emptied (Approvals off); this one stays.
    static let chatApps = Set(SensitivityRules().messagingApps)

    /// A Return key, or typed text that ends in a new line.
    static func isReturn(_ action: JSON) -> Bool {
        if let key = action["key"]?.text?.lowercased() { return key == "return" || key == "enter" }
        return action["type"]?.text?.hasSuffix("\n") == true
    }

    /// After Return in a chat app: what the read just made shows of the text this task typed, so the
    /// model knows what to check (it had spent one to three turns after Return working that out).
    /// The message field is the lowest text field; the last message is the lowest element with text
    /// above it. The answer is never "sent": a message that failed or is still sending reads the same
    /// in the field and the last message, and no app's element tree has been checked for the marks
    /// that tell them apart, so the model reads the screen again.
    func sendCheck(_ actions: [JSON], error: String?, textsBefore: [String]) -> String? {
        guard actions.contains(where: Self.isReturn), error == nil, let app = lastForeground?.bundleID, Self.chatApps.contains(app),
              let text = typedText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        let keyboard = lastAll.first { $0.type == "Keyboard" }
        let read = lastAll.filter { !$0.fromPicture && !(keyboard?.contains($0) ?? false) && $0.frame.width > 0 && $0.frame.height > 0 }
        let quoted = "\"\(text.count > 60 ? String(text.prefix(59)) + "…" : text)\""
        func notConfirmed(_ why: String) -> String {
            "send check: not confirmed: \(why). Read the screen to verify the send before finish_task."
        }
        guard let field = read.filter({ Self.fieldTypes.contains($0.type) }).max(by: { $0.frame.y < $1.frame.y }) else {
            return notConfirmed("no message field was read")
        }
        if (field.value ?? "").contains(text) { return notConfirmed("the message field still holds the text") }
        let frames: Set<String> = ["Keyboard", "NavigationBar", "Toolbar", "TabBar", "Application", "Window", "StatusBar"]
        let messages = read.filter { e in
            !Self.fieldTypes.contains(e.type) && !frames.contains(e.type) && !e.text.isEmpty && e.frame.y + e.frame.height <= field.frame.y + 1
        }
        guard let last = messages.max(by: { a, b in
            let (ab, bb) = (a.frame.y + a.frame.height, b.frame.y + b.frame.height)
            return ab != bb ? ab < bb : a.frame.width * a.frame.height > b.frame.width * b.frame.height
        }) else { return notConfirmed("no message was read above the message field") }
        func reads(_ s: String?) -> Bool { s?.trimmingCharacters(in: .whitespacesAndNewlines) == text }
        guard reads(last.label) || reads(last.value) else {
            return notConfirmed("the message field is empty, and the last message on screen reads \"\(last.text.prefix(60))\"")
        }
        let shown = { (texts: [String]) in texts.filter { $0.trimmingCharacters(in: .whitespacesAndNewlines) == text }.count }
        guard shown(messages.map(\.text)) > shown(textsBefore) else {
            return notConfirmed("the last message reads the same text, but it was on screen before Return")
        }
        typedText = nil
        return "send check: not confirmed: the message field is empty and the last message on screen now reads \(quoted), but a message that failed or is still sending reads the same here. Look again before finish_task: a failure or sending mark beside that message (a red exclamation mark, a retry button, a spinner) means it has not gone."
    }

    /// A call with no task open, or after `taskGap` without one, begins a task.
    func beginsTask() -> Bool { origin.map { now() - $0.lastCall > config.taskGap } ?? true }

    func ownsTask(session: String) -> Bool {
        if let owner = workspaceOwner.value { return owner == session }
        if let selectedPane { return selectedPane.session == session }
        return origin?.session == session
    }

    /// Ends the task: the app it began in comes to the front again (the home screen by the Home
    /// button), and nothing is sent when it is in front already. nil when no task was open.
    func returnToOrigin() async -> String? {
        endHandoff()
        if let selectedPane {
            let exit = await selectPane("auto", session: selectedPane.session, until: now() + 3)
            origin = nil
            lastWorkingApp = nil
            lastForeground = nil
            activeLocalTask = nil
            if exit != nil {
                approvals.discardWorkspaceDecisions(session: workspaceOwner.value)
                self.selectedPane = nil
                workspaceOwner.value = nil
                paneOffset = nil
                workspaceReads.removeAll()
                workspaceDrop = nil
                interruptedDropApp = nil
                workspaceDrags.removeAll()
                clearPaneRead()
            } else {
                clearTaskScreenshotCache()
            }
            return exit.map { "finish: Split View stays open; \($0.text)" } ?? "finish: both apps stay open in Split View"
        }
        if hasLocalWorkspace {
            forgetTask()
            return "finish: the phone stays in its current layout"
        }
        approvals.discardAll()
        clearTaskScreenshotCache()
        lastWorkingApp = nil
        lastForeground = nil
        activeLocalTask = nil
        guard let task = origin else { return nil }
        origin = nil
        guard let bundle = task.app.bundleID else { return nil }
        let front = try? await runner.call("GET", "/wda/activeAppInfo", timeout: 1.5)
        if front?["bundleId"]?.string == bundle { return "finish: \(task.app.describe), where the task began, is in front" }
        do {
            if bundle == "com.apple.springboard" {
                // WDA serves the Home button only outside a session.
                _ = try await runner.raw("POST", "/wda/homescreen", [:], timeout: 8, countsAsMiss: false)
            } else {
                _ = try await runner.call("POST", "/wda/apps/activate", ["bundleId": .string(bundle)], timeout: 4)
            }
            // The answer comes while the switch still animates (seen on the simulator: a look right
            // after found the App Switcher), so the app is watched until it is in front.
            let until = now() + 3
            while now() < until {
                if (try? await runner.call("GET", "/wda/activeAppInfo", timeout: 1))?["bundleId"]?.string == bundle {
                    return "finish: back in \(task.app.describe), where the task began"
                }
                await sleep(seconds: 0.25)
            }
            return "finish: \(task.app.describe), where the task began, was brought back but is not in front after 3 s"
        } catch {
            return "finish: \(task.app.describe), where the task began, could not be brought back (\(error))"
        }
    }

    static func seconds(_ t: Double) -> String { String(format: "%.1f", max(0, t)) }

    /// An alert in the latest tree, as its text and buttons ("Just a moment: Not now, Allow"), or nil.
    /// The tree holds an alert or a sheet and nothing named outside it: the in-process path snapshots
    /// the front layer alone (the alert's accessibility is modal), where WebDriverAgent's source keeps
    /// the screen behind. Said, so the model does not take the screen for gone (gym, in-process: a
    /// look under an alert listed the alert's three elements and nothing of the app).
    func modalOnly(_ all: [Element]) -> String? {
        guard let modal = all.first(where: { ($0.type == "Alert" || $0.type == "Sheet") && !$0.fromPicture }) else { return nil }
        let outside = all.filter { !$0.text.isEmpty && !modal.contains($0) && $0.node != modal.node && !Self.containers.contains($0.type) }
        guard outside.isEmpty else { return nil }
        return "the tree lists the \(modal.type == "Alert" ? "alert" : "sheet") only, not the screen behind it (it is still there, under the picture's dimming): answer or dismiss it to list the screen again"
    }

    func alertOnScreen() -> String? {
        guard let alert = lastAll.first(where: { $0.type == "Alert" && !$0.fromPicture }) else { return nil }
        let inside = lastAll.filter { alert.contains($0) }
        let text = inside.first { $0.type == "StaticText" && !$0.text.isEmpty }?.text.prefix(60)
        let buttons = inside.filter { $0.type == "Button" }.prefix(4).map { "\($0.text.prefix(30))" }.joined(separator: ", ")
        return "\(text.map { "\"\($0)\"" } ?? "an alert")\(buttons.isEmpty ? "" : ": \(buttons)")"
    }

    /// When Poki itself is in front although the model was working in another app, that app is
    /// activated again, and the line says so. nil when nothing had to be done.
    func bringBack(from before: Foreground?, why: String, check: Bool) async -> String? {
        guard selectedPane == nil, let app = before?.bundleID, !app.isEmpty, !config.isPoki(before) else { return nil }
        if check {
            guard let front = try? await runner.call("GET", "/wda/activeAppInfo", timeout: 1.5), config.isPoki(Foreground(bundleID: front["bundleId"]?.string, name: nil)) else { return nil }
        }
        do {
            _ = try await runner.call("POST", "/wda/apps/activate", ["bundleId": .string(app)], timeout: 4)
            return "note: Poki was in front \(why); \(before?.describe ?? app) was brought back. Nothing was sent into Poki. Poki's Live Activity can still be open over the top of the screen for a few seconds: before tapping near the top again, wait ({wait: 2000}) and look, so the tap does not land on it once more."
        } catch {
            return "note: Poki was in front \(why), and \(before?.describe ?? app) could not be brought back (\(error)). Launch it, or ask the owner."
        }
    }

    func bringBackTargetApp(why: String, check: Bool = true) async -> String? {
        guard !handoffWaiting, approvals.pending == nil else { return nil }
        let target = workingTarget(lastForeground) ?? workingTarget(lastWorkingApp)
        return await bringBack(from: target, why: why, check: check)
    }

    /// The actions, in order, each within its own action time (`actionCap` from when it starts; a
    /// launch gets 9 s, the time XCTest's launch handshake takes on the phone) and the call's
    /// deadline. Stops at the first that fails.
    /// `moved`: an action sent before these may have changed the screen (`ActionKind.changesScreen`). `approved`: why the owner
    /// approved an action, by its number in the do.
    func run(_ actions: [JSON], started: Double, until: Double, numberedFrom offset: Int = 0, moved: Bool = false, approved: [Int: String] = [:], onActionSucceeded: PokiCore.ActionSucceeded?) async -> (did: [String], error: String?, lastKind: String?) {
        var did: [String] = []
        var error: String?
        var logError: String?
        var lastKind: String?
        var moved = moved
        // The last action that may have changed the screen, and when it was through.
        var changed: (kind: String, at: Double)?
        defer { if let line = logError ?? error { failureLog.value = line } }
        for (i, action) in actions.enumerated() {
            let index = offset + i
            defer { if let kind = ActionKind(action), kind.changesScreen(action) { moved = true; changed = (kind.rawValue, now()) } }
            let check = moved
                ? await pressNow(action, after: changed, approved: approved[index], until: until - config.readTimeout - 0.5)
                : (problem: nil, backTarget: nil)
            if let held = check.problem {
                did.append("\(action.serialized()) (not_sent)")
                error = "action \(index + 1) was not sent: \(held)\(i + 1 < actions.count ? "; the actions after it were not sent" : "")"
                break
            }
            let cap = actionCap(action)
            let actionsUntil = min(until - config.readTimeout - 0.5, now() + cap)
            let left = actionsUntil - now()
            if left < 0.3 {
                error = "stopped before action \(index + 1): the call's time ran out (\(Int(config.toolDeadline)) s for all the actions and the read); nothing more was sent"
                break
            }
            let began = now()
            let givenUp = runner.actionsGivenUp.value
            let recorded = recordable(action)
            let afterInput: Runner.AfterInput? = onActionSucceeded.map { notify in
                { @MainActor @Sendable step in
                    guard !Task.isCancelled, now() <= min(actionsUntil, step?.deadline ?? actionsUntil) else { return }
                    notify(index, step?.index, step?.skill)
                }
            }
            do {
                let (kind, text) = try await withDeadline(left, "action \(index + 1)") { [self] in
                    try await Runner.$afterInput.withValue(afterInput) {
                        try await perform(action, until: actionsUntil, backTarget: check.backTarget)
                    }
                }
                if let recorded { trace.append(recorded) }
                lastKind = kind
                did.append("\(text) (sent, \(Int(((now() - began) * 1000).rounded())) ms)")
            } catch is CancellationError {
                did.append("\(action.serialized()) (unknown: cancelled)")
                error = "cancelled at action \(index + 1)"
                break
            } catch let failure {
                let delivery: Delivery
                var why = "\(failure)"
                switch failure {
                case let e as ActionFailure: delivery = e.delivery
                case let e as RunnerError: delivery = e.delivery
                case is DeadlineExceeded where action["wait_until"] != nil || action["wait"] != nil:
                    // A wait only reads: nothing was sent, whatever the time it ran out of.
                    delivery = .notSent
                    why += " (it only reads the screen; nothing was sent)"
                case is DeadlineExceeded where !runner.hasSession && runner.actionsGivenUp.value == givenUp:
                    // The time ran out while a session was still being opened: nothing reached the phone.
                    delivery = .notSent
                    why += runner.busyWith.map { "; the runner is still finishing an earlier \($0)" } ?? "; no session was open yet"
                default: delivery = .unknown
                }
                // A type that failed or timed out may still have landed, or can be sent once more: what
                // the field holds decides (see recoverType). Every other action that may have been
                // delivered is never sent again by us.
                var recoveryNote = "", recoveryLog = ""
                if let text = action["type"]?.text, action["via"]?.string != "paste", !why.contains("split_view_changed"),
                   !(failure is ActionFailure), failure is RunnerError || failure is DeadlineExceeded {
                    let recovered = await Runner.$afterInput.withValue(afterInput) {
                        await recoverType(action, text: text, why: why, until: until - config.readTimeout - 0.5)
                    }
                    if let done = recovered.done {
                        lastKind = "type"
                        did.append("\(done) (sent, \(Int(((now() - began) * 1000).rounded())) ms)")
                        continue
                    }
                    recoveryNote = recovered.note.isEmpty ? "" : "; \(recovered.note)"
                    recoveryLog = recovered.logNote.isEmpty ? "" : "; \(recovered.logNote)"
                }
                did.append("\(action.serialized()) (\(delivery.rawValue), \(Int(((now() - began) * 1000).rounded())) ms)")
                // Nothing after a failed action is sent.
                let refusedLaunch = action["launch"] != nil && delivery == .notSent
                let outcome: String
                switch delivery {
                case .unknown: outcome = "may have been delivered"
                case .sent: outcome = "stopped after sending input"
                case .notSent: outcome = refusedLaunch ? "was refused" : "was not sent"
                }
                let head = "action \(index + 1) \(outcome): \(why)"
                var tail = i + 1 < actions.count ? "; the actions after it were not sent" : ""
                if (refusedLaunch && index > 0) || delivery == .sent {
                    tail += ". Do not repeat the actions marked sent"
                }
                error = head + recoveryNote + tail
                logError = head + recoveryLog + tail
                break
            }
        }
        return (did, error, lastKind)
    }

    /// Why an action that presses the screen is held back on the screen as it is now, after an action
    /// before it in the same do may have changed it: what lies where it will touch is read again and
    /// judged as the latest read was, so a Delete that came where Back was is not tapped. A press the
    /// owner approved goes on while it is still the step they approved (`approved`, its reason).
    /// The read comes no sooner after the action that changed the screen (`after`) than the pause the
    /// final read waits after it: a short wait between them does not take it away. It is the first of
    /// two reads in a row that agree (as `wait_until: settled`), within `settleWindow`, so a page still
    /// sliding in is not read as the one it covers; a screen that never holds still is judged on the
    /// latest read.
    func pressNow(_ action: JSON, after changed: (kind: String, at: Double)?, approved: String?, until: Double) async -> (problem: String?, backTarget: BackTarget?) {
        let rules = config.rules
        guard let kind = ActionKind(action), kind.presses(action), rules.enabled || kind == .back else { return (nil, nil) }
        if let changed {
            let pause = min((Self.settle[changed.kind] ?? 0.4) - (now() - changed.at), until - now() - 0.3)
            if pause > 0.01 { await sleep(seconds: pause) }
        }
        guard let screen = size, let elements = await settledRead(until: min(until, now() + Self.settleWindow)) else {
            return ("the action before it may have changed the screen, and it could not be read again to check this one. Choose the remaining actions from the fresh screen below and send them in a new do", nil)
        }
        skillStepApp = elements.foreground.bundleID
        let backTarget = kind == .back ? BackTarget(in: elements.all) : nil
        let scan = SensitiveScan(front: elements.foreground, secureOnScreen: false, elements: listable(elements.all, screen), allElements: elements.all)
        for press in presses(kind, action, scan, unread: false, backTarget: backTarget) {
            guard let reason = rules.reason(touching: press.element, typing: false, app: press.judged == .stroke ? nil : scan.front, secureOnScreen: false, in: scan.allElements ?? lastAll), reason != approved else { continue }
            return ("the action before it may have changed the screen, and where it touches now it needs the owner's approval (\(reason)). Choose the remaining actions from the fresh screen below and send them in a new do", nil)
        }
        return (nil, backTarget)
    }

    private struct NumberTapTarget {
        let app: String
        let screen: ScreenSize
        let elements: [Element]
        let display: Int
        let expected: String
        let before: PictureSketch

        var beforeValue: String { elements[display].text }
        var frame: Rect { elements[display].frame }
        var pictureRegion: Rect {
            Rect(x: frame.x / screen.width, y: frame.y / screen.height,
                 width: frame.width / screen.width, height: frame.height / screen.height)
        }

        func displayValue(in observed: [Element]) -> String? {
            var visible = listable(observed, screen)
            guard visible.count == elements.count else { return nil }
            let value = visible[display].text
            visible[display].label = elements[display].label
            visible[display].value = elements[display].value
            return visible == elements ? value : nil
        }
    }

    private func numberTapTarget(_ actions: [JSON]) -> NumberTapTarget? {
        guard actions.count == 1, let tap = actions[0]["tap"], let ref = tap.int ?? tap["ref"]?.int,
              let key = refs[ref], !key.fromPicture, key.type == "Button", let digit = key.label,
              digit.utf8.count == 1, let ascii = digit.utf8.first, (49...57).contains(ascii),
              selectedPane == nil, let front = lastForeground, front.pokiPane == nil, let app = front.bundleID,
              app != "com.apple.springboard", let screen = size, let picture = lastPicture, picture.hash == nil,
              let readAt = lastTreeAt, let pictureAt = lastPNGAt, now() - min(readAt, pictureAt) < 5,
              abs(readAt - pictureAt) < Runner.pictureLagLimit, !lastAll.contains(where: \.isSecure) else { return nil }
        let elements = listable(lastAll, screen)
        let buttons = lastAll.filter { $0.type == "Button" || $0.type == "Key" }
        let displays = elements.indices.filter { index in
            let element = elements[index]
            return element.type == "StaticText" && element.text == "0"
                && !buttons.contains { $0.contains(element) || $0.frame.intersects(element.frame) }
        }
        guard displays.count == 1, let display = displays.first else { return nil }
        let frame = elements[display].frame
        guard frame.x >= 0, frame.y >= 0, frame.maxX <= screen.width, frame.maxY <= screen.height else { return nil }
        return NumberTapTarget(app: app, screen: screen, elements: elements, display: display, expected: digit, before: picture)
    }

    private struct TapRead {
        var reading: Reading?
        var confirmed = false
        var firstPictureAt: Double?
        var targetAt: Double?
        var samples = 0
        var reason = "settling deadline"
    }

    private static let idleNumberTapWindow = 0.8

    private func readNumberTap(_ target: NumberTapTarget, started: Double, until: Double) async -> TapRead {
        let deadline = min(started + Self.settleWindow, until - config.readTimeout - 0.3)
        let idleDeadline = min(started + Self.idleNumberTapWindow, deadline)
        var result = TapRead()
        var prior: (picture: PictureSketch, at: Double)?
        var lastUnconfirmed: Reading?
        var triedFirstPicture = false
        var sawChange = false
        while deadline - now() > 0.15, !Task.isCancelled {
            let sampleAt = now()
            let reading = await runner.read(timeout: min(config.readTimeout, deadline - sampleAt), format: config.treeFormat,
                                            callEnds: deadline, allowHostPicture: false, appAfterSource: true)
            result.samples += 1
            if result.firstPictureAt == nil { result.firstPictureAt = reading.firstPictureAt }
            guard reading.foreground?.bundleID == target.app, reading.foreground?.pokiPane == nil else {
                result.reason = "foreground changed or is unknown"
                return result
            }
            guard let value = target.displayValue(in: reading.elements) else {
                result.reason = "screen layout changed"
                return result
            }
            if value == target.expected, result.targetAt == nil { result.targetAt = reading.treeAt }
            guard reading.notes.isEmpty, reading.screenshotCompanion == nil, let png = reading.png,
                  let pictureAt = reading.firstPictureAt, let treeAt = reading.treeAt,
                  treeAt - pictureAt <= Runner.pictureLagLimit else {
                result.reason = "no fresh picture paired with the tree"
                return result
            }
            var withoutPicture = reading
            withoutPicture.png = nil
            lastUnconfirmed = withoutPicture
            let picture = PictureSketch(png: png)
            let displayChanged = picture.differs(from: target.before, inside: target.frame, on: target.screen) == true
            if value != target.beforeValue || displayChanged { sawChange = true }
            if value == target.expected, displayChanged {
                if !triedFirstPicture, let change = picture.change(from: target.before), change.share < 0.08 {
                    triedFirstPicture = true
                    let confirmation = await confirmTapPicture(reading, target: target, until: deadline)
                    result.samples += confirmation.attempts
                    if let settled = confirmation.reading {
                        result.reading = settled
                        result.confirmed = true
                        result.reason = "display and picture settled"
                        return result
                    }
                    prior = nil
                    await sleep(seconds: max(0, min(deadline, sampleAt + 0.12) - now()))
                    continue
                }
                if let previous = prior, !picture.differs(from: previous.picture),
                   picture.differs(from: previous.picture, inside: target.frame, on: target.screen) == false {
                    if pictureAt - previous.at < 0.12 {
                        await sleep(seconds: min(deadline, previous.at + 0.12) - now())
                        continue
                    }
                    if await pictureShowsTapValue(png, target: target, until: deadline) {
                        if runner.transport.usesDynamicScreenSize {
                            let available = deadline - now()
                            guard available > 0.1, (try? await runner.screenSize(timeout: available)) == target.screen else {
                                result.reason = "screen size changed or is unknown"
                                return result
                            }
                        }
                        result.reading = reading
                        result.confirmed = true
                        result.reason = "display and picture settled"
                        return result
                    }
                }
                prior = (picture, pictureAt)
            } else {
                prior = nil
                if !sawChange, sampleAt >= idleDeadline {
                    result.reading = withoutPicture
                    result.reason = "no change before settle pause"
                    return result
                }
            }
            let nextSample: Double
            if sawChange {
                nextSample = min(deadline, sampleAt + 0.12)
            } else {
                let candidate = max(sampleAt + 0.12, now())
                nextSample = idleDeadline - candidate <= 0.15 ? idleDeadline : min(idleDeadline, candidate)
            }
            await sleep(seconds: max(0, nextSample - now()))
        }
        result.reading = lastUnconfirmed
        return result
    }

    private func confirmTapPicture(_ reading: Reading, target: NumberTapTarget, until: Double) async -> (reading: Reading?, attempts: Int) {
        guard let png = reading.png, let pictureAt = reading.firstPictureAt, until - now() > 0.2 else {
            return (nil, 0)
        }
        async let pictureMatches = pictureShowsTapValue(png, target: target, until: until)
        var attempts = 1
        guard var latest = await confirmationTree(target: target, until: until) else {
            return (nil, attempts)
        }
        guard await pictureMatches else { return (nil, attempts) }
        if latest.at < pictureAt + 0.12 {
            let wait = min(until, pictureAt + 0.12) - now()
            if wait > 0 { await sleep(seconds: wait) }
            attempts += 1
            guard let second = await confirmationTree(target: target, until: until),
                  second.at >= pictureAt + 0.12 else {
                return (nil, attempts)
            }
            latest = second
        }
        var settled = reading
        settled.elements = latest.elements
        settled.foreground = latest.foreground
        settled.treeAt = latest.at
        if latest.at - pictureAt > Runner.pictureLagLimit {
            let retakeBudget = until - now()
            guard retakeBudget > 0.4,
                  let capture = try? await runner.captureScreen(timeout: min(1.5, retakeBudget)),
                  capture.companion == nil else {
                return (nil, attempts)
            }
            let first = PictureSketch(png: png)
            let retaken = PictureSketch(png: capture.data)
            guard !retaken.differs(from: first),
                  retaken.differs(from: first, inside: target.frame, on: target.screen) == false,
                  await pictureShowsTapValue(capture.data, target: target, until: until) else {
                return (nil, attempts)
            }
            settled.png = capture.data
            settled.notes.append("the picture was taken again after the tree, which came \(Int(((latest.at - pictureAt) * 1000).rounded())) ms later than the first picture")
        }
        if runner.transport.usesDynamicScreenSize {
            let left = until - now()
            guard left > 0.1, (try? await runner.screenSize(timeout: left)) == target.screen else {
                return (nil, attempts)
            }
        }
        return (settled, attempts)
    }

    private func confirmationTree(target: NumberTapTarget, until: Double) async -> (elements: [Element], foreground: Foreground, at: Double)? {
        let remaining = until - now()
        guard remaining > 0.1, !Task.isCancelled,
              let tree = try? await runner.tree(timeout: min(config.readTimeout, remaining), format: config.treeFormat,
                                                countsAsMiss: false, appAfterSource: true) else { return nil }
        let treeAt = now()
        guard tree.foreground.bundleID == target.app, tree.foreground.pokiPane == nil,
              target.displayValue(in: tree.elements) == target.expected else { return nil }
        return (tree.elements, tree.foreground, treeAt)
    }

    private func pictureShowsTapValue(_ png: Data, target: NumberTapTarget, until: Double) async -> Bool {
        let remaining = until - now()
        guard remaining > 0, !Task.isCancelled else { return false }
        let region = target.pictureRegion
        guard let text = try? await withDeadline(min(0.25, remaining), "confirming the display in the screenshot", {
            TextRecognizer.recognize(png: png, in: region)
        }), text.count == 1, let digit = text.first else { return false }
        return digit.text == target.expected && region.contains(digit.box.centre)
    }

    private struct PreparedCapture: Sendable {
        let generation: UInt64
        let expectedApp: String?
        let earliestAllowedAt: Double
        let task: Task<ScreenCapture?, Never>
    }

    private struct FreshScreenObservation {
        let kind: String
        let inputAt: Double
        var reading: Reading?
        var confirmed = false
        var firstPictureAt: Double?
        var targetAt: Double?
        var pauseMs = 0
        var samples = 0
        var reusedTree = false
        var omitStalePicture = false
        var reason = "settling deadline"
    }

    private func nextActionGeneration() -> UInt64 {
        cancelPreparedCapture()
        actionGeneration &+= 1
        return actionGeneration
    }

    func cancelPreparedCapture() {
        preparedCapture?.task.cancel()
        preparedCapture = nil
    }

    func prepareCapture(generation: UInt64, expectedApp: String?, earliestAllowedAt: Double, timeout: Double) {
        preparedCapture?.task.cancel()
        guard selectedPane == nil else { preparedCapture = nil; return }
        let budget = max(0.2, timeout)
        let runner = self.runner
        let task = Task<ScreenCapture?, Never> {
            try? await runner.captureScreen(timeout: budget)
        }
        preparedCapture = PreparedCapture(generation: generation, expectedApp: expectedApp, earliestAllowedAt: earliestAllowedAt, task: task)
    }

    private func hasPreparedCapture(generation: UInt64, expectedApp: String?, earliestAllowedAt: Double) -> Bool {
        guard let prepared = preparedCapture else { return false }
        return prepared.generation == generation
            && prepared.expectedApp == expectedApp
            && prepared.earliestAllowedAt >= earliestAllowedAt
    }

    private func takePreparedCapture(generation: UInt64, expectedApp: String?, earliestAllowedAt: Double) async -> ScreenCapture? {
        guard let prepared = preparedCapture else { return nil }
        preparedCapture = nil
        guard prepared.generation == generation,
              prepared.expectedApp == expectedApp,
              prepared.earliestAllowedAt >= earliestAllowedAt else {
            prepared.task.cancel()
            return nil
        }
        guard let capture = await prepared.task.value,
              capture.companion == nil,
              capture.startedAt >= earliestAllowedAt else {
            return nil
        }
        return capture
    }

    private func freshCaptureIfStale(_ capture: ScreenCapture?, treeAt: Double, earliestAllowedAt: Double, deadline: Double) async -> ScreenCapture? {
        guard let existing = capture else { return nil }
        guard treeAt - existing.finishedAt > Runner.pictureLagLimit else { return existing }
        let retakeBudget = deadline - now()
        guard retakeBudget > 0.4,
              let retaken = try? await runner.captureScreen(timeout: min(1.5, retakeBudget)),
              retaken.companion == nil, retaken.startedAt >= earliestAllowedAt else {
            return nil
        }
        return retaken
    }

    private func stabilityElements(_ elements: [Element], screen: ScreenSize) -> [Element] {
        listable(elements, screen).filter { element in
            guard element.type != "ScrollBar" else { return false }
            let lower = element.text.lowercased()
            return !lower.contains("scroll bar") && !element.text.contains("滚动条") && !element.text.contains("捲動軸")
        }
    }

    private func layoutSettled(previous: [Element], current: [Element], screen: ScreenSize, tolerance: Double = 1.5) -> Bool {
        let a = stabilityElements(previous, screen: screen)
        let b = stabilityElements(current, screen: screen)
        guard a.count == b.count else { return false }
        for (x, y) in zip(a, b) {
            guard x.key == y.key,
                  abs(x.frame.x - y.frame.x) <= tolerance,
                  abs(x.frame.y - y.frame.y) <= tolerance,
                  abs(x.frame.width - y.frame.width) <= tolerance,
                  abs(x.frame.height - y.frame.height) <= tolerance else {
                return false
            }
        }
        return true
    }

    private func visibleTargetMatch(_ wanted: Element, in elements: [Element], screen: ScreenSize) -> Element? {
        let layout = Layout(all: elements, screen: screen)
        return elements.first { element in
            guard element.key == wanted.key else { return false }
            let frame = element.frame
            guard frame.x >= 0, frame.y >= 0, frame.maxX <= screen.width, frame.maxY <= screen.height else { return false }
            return !layout.covers(element).contains { $0.frame.contains(frame.centre) }
        }
    }

    private func readAfterScroll(_ scroll: ScrollTargetObservation, generation: UInt64, beforePicture: PictureSketch?, until: Double) async -> FreshScreenObservation {
        let screen = size ?? ScreenSize(width: 10_000, height: 10_000)
        let expectedApp = scroll.foreground.bundleID
        let earliestAllowedAt = scroll.inputAt
        let deadline = min(now() + Self.settleWindow, until - config.readTimeout - 0.3)
        let stalePictureDeadline = min(now() + Self.idleNumberTapWindow, deadline)
        let requiresPictureChange = beforePicture != nil && beforePicture?.hash == nil
        var result = FreshScreenObservation(kind: "scroll_to", inputAt: scroll.inputAt, targetAt: scroll.targetTreeAt)
        var priorElements = scroll.elements
        var priorPicture: PictureSketch?
        var sawCoasting = false
        var sawStalePicture = false
        var lastTreeWithoutPicture: Reading?

        while deadline - now() > 0.15, !Task.isCancelled {
            let sampleAt = now()
            let budget = min(config.readTimeout, deadline - sampleAt)
            if !hasPreparedCapture(generation: generation, expectedApp: expectedApp, earliestAllowedAt: earliestAllowedAt) {
                prepareCapture(generation: generation, expectedApp: expectedApp, earliestAllowedAt: earliestAllowedAt, timeout: budget)
            }
            let tree = try? await runner.tree(timeout: budget, format: config.treeFormat, countsAsMiss: false, appAfterSource: true)
            let treeAt = now()
            var capture = await takePreparedCapture(generation: generation, expectedApp: expectedApp, earliestAllowedAt: earliestAllowedAt)
            result.samples += 1

            guard let tree else {
                result.reason = "tree read failed"
                return result
            }
            if tree.elements.contains(where: { $0.type == "Alert" && !$0.fromPicture }) {
                result.reason = "system alert over list"
                return result
            }
            guard tree.foreground.bundleID == expectedApp, tree.foreground.pokiPane == nil, !config.isPoki(tree.foreground) else {
                result.reason = "foreground changed or is unknown"
                return result
            }
            capture = await freshCaptureIfStale(capture, treeAt: treeAt, earliestAllowedAt: earliestAllowedAt, deadline: deadline)
            if let capture, result.firstPictureAt == nil {
                result.firstPictureAt = capture.finishedAt
            }

            let targetNow = visibleTargetMatch(scroll.target, in: tree.elements, screen: screen)
            if !layoutSettled(previous: priorElements, current: tree.elements, screen: screen, tolerance: Self.scrollSettleTolerance) || targetNow == nil {
                sawCoasting = true
                priorElements = tree.elements
                priorPicture = capture.map { PictureSketch(png: $0.data) }
                await sleep(seconds: max(0, min(deadline, sampleAt + 0.12) - now()))
                continue
            }

            if let targetNow { scrollFound = targetNow }
            let withoutPicture = Reading(elements: tree.elements, foreground: tree.foreground, png: nil,
                                         screenshotCompanion: nil, firstPictureStartedAt: nil, firstPictureAt: nil,
                                         treeAt: treeAt, notes: [], ms: Int(((treeAt - scroll.inputAt) * 1000).rounded()))
            guard let capture else {
                lastTreeWithoutPicture = withoutPicture
                if sampleAt >= stalePictureDeadline {
                    result.reason = "no fresh picture paired with the tree"
                    return result
                }
                await sleep(seconds: max(0, min(deadline, sampleAt + 0.12) - now()))
                continue
            }

            let sketch = PictureSketch(png: capture.data)
            if requiresPictureChange, let before = beforePicture, !sketch.differs(from: before) {
                sawStalePicture = true
                lastTreeWithoutPicture = withoutPicture
                priorPicture = nil
                if sampleAt >= stalePictureDeadline {
                    result.reading = withoutPicture
                    result.omitStalePicture = true
                    result.reusedTree = true
                    result.reason = "stale pre-action picture rejected"
                    return result
                }
                await sleep(seconds: max(0, min(deadline, sampleAt + 0.12) - now()))
                continue
            }
            if sawCoasting {
                guard let previous = priorPicture, !sketch.differs(from: previous) else {
                    priorPicture = sketch
                    priorElements = tree.elements
                    await sleep(seconds: max(0, min(deadline, sampleAt + 0.12) - now()))
                    continue
                }
            }
            if runner.transport.usesDynamicScreenSize {
                let left = deadline - now()
                guard left > 0.1, let current = try? await runner.screenSize(timeout: left),
                      size == nil || current == size else {
                    result.reason = "screen size changed or is unknown"
                    return result
                }
                size = current
            }
            let settled = Reading(elements: tree.elements, foreground: tree.foreground, png: capture.data,
                                  screenshotCompanion: nil, firstPictureStartedAt: capture.startedAt,
                                  firstPictureAt: capture.finishedAt, treeAt: treeAt, notes: [],
                                  ms: Int(((now() - scroll.inputAt) * 1000).rounded()))
            result.reading = settled
            result.confirmed = true
            result.reusedTree = true
            result.reason = "scroll target and picture settled"
            return result
        }
        if sawStalePicture, let fallback = lastTreeWithoutPicture {
            result.reading = fallback
            result.omitStalePicture = true
            result.reusedTree = true
            result.reason = "stale pre-action picture rejected"
        }
        return result
    }

    private func readAfterLaunch(bundleID: String, beforeApp: String?, beforePicture: PictureSketch?, generation: UInt64, started: Double, until: Double) async -> FreshScreenObservation {
        let arriveDeadline = min(started + (Self.settle["launch"] ?? 0.9), until - config.readTimeout - 0.3)
        let settleDeadline = min(started + Self.settleWindow, until - config.readTimeout - 0.3)
        if size == nil, let fetched = try? await screenSize(until: settleDeadline) {
            size = fetched
        }
        let screen = size ?? ScreenSize(width: 10_000, height: 10_000)
        let requiresPictureChange = beforeApp != nil && beforeApp != bundleID && beforePicture != nil && beforePicture?.hash == nil
        var result = FreshScreenObservation(kind: "launch", inputAt: started)
        var sawTargetApp = false
        var prior: (elements: [Element], picture: PictureSketch, pictureAt: Double)?
        var sawStalePicture = false
        var lastTreeWithoutPicture: Reading?
        var stalePictureDeadline: Double?

        while !Task.isCancelled {
            let activeDeadline = sawTargetApp ? settleDeadline : arriveDeadline
            guard activeDeadline - now() > 0.15 else { break }
            let sampleAt = now()
            let budget = min(config.readTimeout, settleDeadline - sampleAt)
            prepareCapture(generation: generation, expectedApp: bundleID, earliestAllowedAt: started, timeout: budget)
            let tree = try? await runner.tree(timeout: budget, format: config.treeFormat, countsAsMiss: false, appAfterSource: true)
            let treeAt = now()
            var capture = await takePreparedCapture(generation: generation, expectedApp: bundleID, earliestAllowedAt: started)
            result.samples += 1

            guard let tree else {
                result.reason = "tree read failed"
                return result
            }
            if tree.foreground.bundleID == "com.apple.springboard",
               tree.elements.contains(where: { $0.type == "Alert" && !$0.fromPicture }) {
                capture = await freshCaptureIfStale(capture, treeAt: treeAt, earliestAllowedAt: started, deadline: settleDeadline)
                result.firstPictureAt = result.firstPictureAt ?? capture?.finishedAt
                if let existing = capture, requiresPictureChange, let before = beforePicture,
                   !PictureSketch(png: existing.data).differs(from: before) {
                    result.reading = Reading(elements: tree.elements, foreground: tree.foreground, png: nil,
                                             screenshotCompanion: nil, firstPictureStartedAt: nil,
                                             firstPictureAt: nil, treeAt: treeAt, notes: [],
                                             ms: Int(((now() - started) * 1000).rounded()))
                    result.omitStalePicture = true
                    result.reusedTree = true
                    result.reason = "stale pre-action picture rejected over system alert"
                    return result
                }
                guard let fresh = capture else {
                    result.reason = "system alert over launched app without fresh picture"
                    return result
                }
                result.reading = Reading(elements: tree.elements, foreground: tree.foreground, png: fresh.data,
                                         screenshotCompanion: nil, firstPictureStartedAt: fresh.startedAt,
                                         firstPictureAt: fresh.finishedAt, treeAt: treeAt, notes: [],
                                         ms: Int(((now() - started) * 1000).rounded()))
                result.reusedTree = true
                result.reason = "system alert over launched app"
                return result
            }
            guard tree.foreground.bundleID == bundleID, tree.foreground.pokiPane == nil,
                  !config.isPoki(tree.foreground), !stabilityElements(tree.elements, screen: screen).isEmpty else {
                prior = nil
                await sleep(seconds: max(0, min(activeDeadline, sampleAt + 0.1) - now()))
                continue
            }

            sawTargetApp = true
            if result.targetAt == nil { result.targetAt = treeAt }
            if stalePictureDeadline == nil {
                stalePictureDeadline = min(now() + Self.idleNumberTapWindow, settleDeadline)
            }

            capture = await freshCaptureIfStale(capture, treeAt: treeAt, earliestAllowedAt: started, deadline: settleDeadline)
            if let capture, result.firstPictureAt == nil {
                result.firstPictureAt = capture.finishedAt
            }

            let withoutPicture = Reading(elements: tree.elements, foreground: tree.foreground, png: nil,
                                         screenshotCompanion: nil, firstPictureStartedAt: nil, firstPictureAt: nil,
                                         treeAt: treeAt, notes: [], ms: Int(((treeAt - started) * 1000).rounded()))
            guard let capture else {
                lastTreeWithoutPicture = withoutPicture
                if let limit = stalePictureDeadline, sampleAt >= limit {
                    result.reason = "no fresh picture paired with launched app"
                    return result
                }
                await sleep(seconds: max(0, min(settleDeadline, sampleAt + 0.12) - now()))
                continue
            }

            let sketch = PictureSketch(png: capture.data)
            if requiresPictureChange, let before = beforePicture, !sketch.differs(from: before) {
                sawStalePicture = true
                lastTreeWithoutPicture = withoutPicture
                prior = nil
                if let limit = stalePictureDeadline, sampleAt >= limit {
                    result.reading = withoutPicture
                    result.omitStalePicture = true
                    result.reusedTree = true
                    result.reason = "stale pre-action picture rejected"
                    return result
                }
                await sleep(seconds: max(0, min(settleDeadline, sampleAt + 0.12) - now()))
                continue
            }

            if let previous = prior,
               layoutSettled(previous: previous.elements, current: tree.elements, screen: screen),
               !sketch.differs(from: previous.picture) {
                if capture.finishedAt - previous.pictureAt < 0.12 {
                    await sleep(seconds: max(0, min(settleDeadline, previous.pictureAt + 0.12) - now()))
                    continue
                }
                if runner.transport.usesDynamicScreenSize {
                    let left = min(config.readTimeout, until - now() - 0.3)
                    guard left > 0.1, let current = try? await runner.screenSize(timeout: left),
                          size == nil || current == size else {
                        result.reason = "screen size changed or is unknown"
                        return result
                    }
                    size = current
                }
                result.reading = Reading(elements: tree.elements, foreground: tree.foreground, png: capture.data,
                                         screenshotCompanion: nil, firstPictureStartedAt: capture.startedAt,
                                         firstPictureAt: capture.finishedAt, treeAt: treeAt, notes: [],
                                         ms: Int(((now() - started) * 1000).rounded()))
                result.confirmed = true
                result.reusedTree = true
                result.reason = "launched app and picture settled"
                return result
            }

            prior = (tree.elements, sketch, capture.finishedAt)
            await sleep(seconds: max(0, min(settleDeadline, sampleAt + 0.12) - now()))
        }

        if sawStalePicture, let fallback = lastTreeWithoutPicture {
            result.reading = fallback
            result.omitStalePicture = true
            result.reusedTree = true
            result.reason = "stale pre-action picture rejected"
        } else if !sawTargetApp {
            result.reason = "launched app not in front before launch pause"
        }
        return result
    }

    /// Up to `pause` seconds before the read after the actions, ended early once the screen differs
    /// from `before`, lists something, and two reads in a row agree (an app still drawing its first
    /// screen lists nothing). A read is given only the time left, and one slower than that left is not
    /// begun again: the pause is never longer than it was, and a read cut short by it is not taken
    /// for a runner gone. A read that fails ends the sampling, and the rest of the pause is slept.
    private func settledPause(_ pause: Double, before: String, generation: UInt64, earliestAllowedAt: Double, beforePicture: PictureSketch?, until: Double) async -> (waited: Double, settled: Bool, observation: FreshScreenObservation?) {
        let began = now()
        guard let screen = size else { await sleep(seconds: pause); return (pause, false, nil) }
        await sleep(seconds: min(pause, 0.05))
        var lastElements: [Element]?
        var samples = 0
        var targetAt: Double?
        while true {
            let left = pause - (now() - began)
            guard (lastElements != nil ? left > 0.14 : left > 0.20) else { break }
            guard let tree = try? await withDeadline(left, "a read while the screen settles", { [runner, format = config.treeFormat] in
                try await runner.tree(timeout: left, format: format, countsAsMiss: false, appAfterSource: true)
            }) else { break }
            let treeAt = now()
            samples += 1
            let signature = listable(tree.elements, screen).map { "\($0.key)@\($0.frame.described)" }.joined(separator: ";")
            let wasUnset = lastElements == nil
            if !signature.isEmpty, signature != before {
                if targetAt == nil { targetAt = treeAt }
                if let previous = lastElements, layoutSettled(previous: previous, current: tree.elements, screen: screen) {
                    let waited = treeAt - began
                    let observation = await finalizeSettledPauseTree(tree, treeAt: treeAt, waited: waited, samples: samples, targetAt: targetAt, generation: generation, earliestAllowedAt: earliestAllowedAt, beforePicture: beforePicture, until: until)
                    return (waited, true, observation)
                }
                lastElements = tree.elements
                if wasUnset { continue }
            } else {
                lastElements = nil
            }
            await sleep(seconds: 0.06)
        }
        cancelPreparedCapture()
        let rest = pause - (now() - began)
        if rest > 0.01 { await sleep(seconds: rest) }
        return (now() - began, false, nil)
    }

    private func finalizeSettledPauseTree(_ tree: (elements: [Element], foreground: Foreground), treeAt: Double, waited: Double, samples: Int, targetAt: Double?, generation: UInt64, earliestAllowedAt: Double, beforePicture: PictureSketch?, until: Double) async -> FreshScreenObservation? {
        guard selectedPane == nil, tree.foreground.pokiPane == nil, !config.isPoki(tree.foreground),
              !tree.elements.contains(where: { $0.type == "Alert" && !$0.fromPicture }) else {
            cancelPreparedCapture()
            return nil
        }
        let budget = min(config.readTimeout, max(0.4, until - now() - 0.3))
        var capture = await takePreparedCapture(generation: generation, expectedApp: tree.foreground.bundleID, earliestAllowedAt: earliestAllowedAt)
        if capture == nil, budget > 0.4 {
            if let fresh = try? await runner.captureScreen(timeout: budget),
               fresh.companion == nil, fresh.startedAt >= earliestAllowedAt {
                capture = fresh
            }
        }
        capture = await freshCaptureIfStale(capture, treeAt: treeAt, earliestAllowedAt: earliestAllowedAt, deadline: until - 0.3)
        guard let capture else { return nil }
        let requiresPictureChange = beforePicture != nil && beforePicture?.hash == nil
        if requiresPictureChange, let before = beforePicture, !PictureSketch(png: capture.data).differs(from: before) {
            var stale = FreshScreenObservation(kind: "settled_pause", inputAt: earliestAllowedAt, firstPictureAt: capture.finishedAt, targetAt: targetAt, pauseMs: Int((waited * 1000).rounded()), samples: samples, reusedTree: true, omitStalePicture: true, reason: "stale pre-action picture rejected")
            stale.reading = Reading(elements: tree.elements, foreground: tree.foreground, png: nil,
                                    screenshotCompanion: nil, firstPictureStartedAt: nil, firstPictureAt: nil,
                                    treeAt: treeAt, notes: [], ms: Int(((now() - earliestAllowedAt) * 1000).rounded()))
            return stale
        }
        var obs = FreshScreenObservation(kind: "settled_pause", inputAt: earliestAllowedAt, confirmed: true, firstPictureAt: capture.finishedAt, targetAt: targetAt, pauseMs: Int((waited * 1000).rounded()), samples: samples, reusedTree: true, reason: "settled pause tree reused")
        obs.reading = Reading(elements: tree.elements, foreground: tree.foreground, png: capture.data,
                              screenshotCompanion: nil, firstPictureStartedAt: capture.startedAt,
                              firstPictureAt: capture.finishedAt, treeAt: treeAt, notes: [],
                              ms: Int(((now() - earliestAllowedAt) * 1000).rounded()))
        return obs
    }

    /// How long `pressNow` reads for two reads in a row that agree.
    static let settleWindow = 2.0

    /// How far, in points, any listed element may still move between two reads after `scroll_to` for
    /// the list to count as at rest. Settings ends a scroll with a 1 to 2 pt bounce (simulator: the
    /// target read at y 714, then 716); a list still coasting moves tens of points between reads.
    static let scrollSettleTolerance = 3.0

    /// The screen once two reads in a row agree, or the latest read when `until` comes first; nil when
    /// nothing could be read.
    func settledRead(until: Double) async -> (all: [Element], foreground: Foreground)? {
        func signature(_ elements: [Element]) -> String { elements.map { "\($0.key)@\($0.frame.described)" }.joined(separator: ";") }
        var latest: (all: [Element], foreground: Foreground)?
        var last: String?
        while until - now() > 0.3 {
            guard let tree = try? await runner.tree(timeout: min(config.readTimeout, until - now()), format: config.treeFormat) else { break }
            let sig = signature(tree.elements)
            latest = (tree.elements, tree.foreground)
            if sig == last { break }
            last = sig
            await sleep(seconds: min(0.15, max(0, until - now() - 0.3)))
        }
        return latest
    }

    /// After a type that failed or timed out: what the focused field holds says what happened, so the
    /// text is neither lost nor typed twice. The text is all there (the runner answered late or with an
    /// error after typing): it counts as typed. The field is empty (a placeholder is nothing) or being
    /// cleared, so a second try cannot double it: sent once more. Anything else, another person's text,
    /// a half-typed or unreadable field: not sent again. `done` is the step's text when the text is in
    /// the field. `note` goes on the answer to the model and may quote the field; `logNote` goes on the
    /// line the app log keeps and only ever says which case it was, never what the field holds.
    ///
    /// The real runner answers an empty field with its placeholder, so a value is read as text first
    /// (the value is the target text, or holds it) and as a placeholder second. A value equal to the
    /// placeholder is empty unless the text begins with it: then a first try may have landed that
    /// much, and the field is left alone rather than risk typing the text twice.
    func recoverType(_ action: JSON, text: String, why: String, until: Double) async -> (done: String?, note: String, logNote: String) {
        guard until - now() > 1.2 else { return (nil, "", "no time left to check the field") }
        let hidden = describe(action).hasSuffix("(hidden)")
        func shown(_ value: String) -> String { hidden ? "\(value.count) characters" : "\"\(value.count > 200 ? String(value.prefix(190)) + "…" : value)\"" }
        func typed(_ held: String) -> (done: String?, note: String, logNote: String) {
            ("\(describe(action)) (typed); the runner answered late or with an error, and the field now reads \(shown(held))", "", "")
        }
        enum Doubt { case none, mayBeThePlaceholder, placeholderUnread }
        var value = ""
        var doubt = Doubt.none
        switch await readField(until: until) {
        case .unreadable:
            return (nil, "the field could not be read afterwards, so the text was not typed again", "field unreadable, not typed again")
        case .empty:
            break
        case .text(let held, let id):
            // Exactly the text: typed, or the placeholder is this very text. Either way it is not typed twice.
            if held == text { return typed(held) }
            switch await placeholder(ofField: id, until: until) {
            case .text(let shownPlaceholder) where shownPlaceholder == held:
                if text.hasPrefix(held) { value = held; doubt = .mayBeThePlaceholder }
            case let known:
                if held.contains(text) { return typed(held) }
                value = held
                if known == .unreadable { doubt = .placeholderUnread }
            }
        }
        let state: String
        switch doubt {
        case .none: state = value.isEmpty ? "field empty" : "field has other text"
        case .mayBeThePlaceholder: state = "field reads its placeholder or the start of the text"
        case .placeholderUnread: state = "field has text, placeholder unreadable"
        }
        guard action["clear"]?.bool ?? false || value.isEmpty else {
            let reason: String
            switch doubt {
            case .none: reason = "the field holds \(shown(value)), which is not all of the text"
            case .mayBeThePlaceholder: reason = "the field reads \(shown(value)), which is either its placeholder or the start of the text"
            case .placeholderUnread: reason = "the field reads \(shown(value)); its placeholder could not be read, so it is not known whether that is text"
            }
            return (nil, "\(reason), so it was not typed again (a second try could double it)", "\(state), not typed again")
        }
        guard until - now() > 1.2 else {
            return (nil, value.isEmpty ? "the field is empty; there was no time left to type again" : "the field holds \(shown(value)); there was no time left to type again", "\(state), no time left to type again")
        }
        do {
            let (_, text) = try await withDeadline(until - now(), "the second try of the action") { [self] in try await perform(action, until: until) }
            return ("\(text) (sent again after the first try failed: \(why))", "", "")
        } catch {
            return (nil, "the text was typed again once and that failed too: \(error)", "\(state), typed again once and that failed too")
        }
    }

    /// The approval stays open for the actions the model sends again. After actions before them ran,
    /// it is matched to those actions on their own against the read this answer makes, so the request
    /// is not withdrawn by the very call it asks for. When that read shows other controls at their
    /// numbers than `before` (the same actions on the screen the owner was asked about), or another
    /// app, the approval is withdrawn instead.
    private func refusedAwaitingResend(_ approval: Approval, tail: [JSON], before: ApprovalScope, at: Int, until: Double, full: Bool, did: [String], text: String) async -> ToolResult {
        var result = await refused(until: until, full: full, did: did, text: text)
        guard at > 0 else { return result }
        let after = approvalScope(tail)
        if before.covers(after) {
            approvals.rekey(id: approval.id, scope: after)
        } else {
            approvals.withdraw(id: approval.id)
            result.text += "\napproval: withdrawn (id \(approval.id)); on this screen the numbers from action \(at + 1) name other controls than the owner was asked about. Choose from the elements above; a sensitive action asks again."
        }
        return result
    }

    /// The answer when the sensitive part was not sent: text only when nothing went, else the read
    /// after what did go.
    func refused(until: Double, full: Bool, did: [String], text: String) async -> ToolResult {
        guard !did.isEmpty else {
            // The screen it was refused on, so the model sees what it asked for (gym: the declined
            // answer was the one answer without a picture).
            let read = await readAndReply(until: until, full: full, changes: true)
            return ToolResult(text: text + " Nothing was sent.\n" + read.text, jpeg: read.jpeg, isError: true, freshPNG: read.freshPNG, observedApp: read.observedApp)
        }
        return await readAndReply(until: until, full: full, changes: true, did: did, error: text)
    }

    // MARK: Sensitivity

    /// Whether an input action would run with Poki in front: the app of the latest read, followed through
    /// the launches and Home presses before it.
    func landsInPoki(_ actions: [JSON]) -> Bool {
        var front = lastForeground
        for action in actions {
            if let spec = action["launch"] {
                front = Foreground(bundleID: spec.string ?? spec["bundle"]?.string, name: nil)
            } else if let button = action["button"]?.text {
                if button.lowercased() == "home" { front = nil }
            } else if action["wait"] != nil || action["wait_until"] != nil {
                continue
            } else if let spec = action["run"], let routine = memory?.routine(named: spec.string ?? spec["name"]?.string ?? ""),
                      let bundle = routine.steps.first?.action["launch"].flatMap({ $0.string ?? $0["bundle"]?.string }) ?? routine.app,
                      !config.isPoki(Foreground(bundleID: bundle, name: nil)) {
                // A run that begins with a launch (or whose app is launched first) leaves Poki on its
                // own: on the phone a task usually starts in Poki's own chat (gym finding 37).
                front = Foreground(bundleID: bundle, name: nil)
            } else if let spec = action["path"], let bundle = (spec["steps"]?.array ?? spec.array)?.first?["launch"].flatMap({ $0.string ?? $0["bundle"]?.string }),
                      !config.isPoki(Foreground(bundleID: bundle, name: nil)) {
                // A path that begins with a launch leaves Poki on its own, as such a run does.
                front = Foreground(bundleID: bundle, name: nil)
            } else if config.isPoki(front) {
                return true
            }
        }
        return false
    }

    func element(at point: (x: Double, y: Double), in elements: [Element]? = nil) -> Element? {
        (elements ?? lastElements).filter { f in f.frame.x <= point.x && point.x <= f.frame.x + f.frame.width && f.frame.y <= point.y && point.y <= f.frame.y + f.frame.height }
            .min { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    /// The element a spec points at: a number of the latest read, or what lies under a point (of the
    /// latest read, or of `elements`, where numbers mean nothing).
    func target(_ spec: JSON?, in elements: [Element]? = nil) -> Element? {
        guard let spec else { return nil }
        if let point = spec.array, point.count >= 2, let x = point[0].double, let y = point[1].double { return element(at: (x, y), in: elements) }
        if case .object = spec {
            if let ref = spec["ref"]?.int { return elements == nil ? refs[ref] : nil }
            if let x = spec["x"]?.double, let y = spec["y"]?.double { return element(at: (x, y), in: elements) }
            return nil
        }
        return elements == nil ? spec.int.flatMap { refs[$0] } : nil
    }

    func sensitiveReason(_ actions: [JSON]) -> String? { firstSensitive(actions)?.reason }

    /// What the approval check carries from one action to the next.
    struct SensitiveScan {
        /// The app the action lands in, followed through launches, Home and runs.
        var front: Foreground?
        /// The screen is still the one `elements` were read from: after a launch, Home or a run the
        /// numbers and points of that read belong to another screen.
        var read = true
        /// An action before this one may have changed the screen (a tap opens a conversation or a
        /// photo): a point is not judged by what the read had under it.
        var moved = false
        var typingTarget: Element?
        var secureOnScreen: Bool
        /// The elements to look under a point in; nil for the latest read (and its numbers).
        var elements: [Element]?
        /// The full element tree for ancestor context; nil uses `lastAll`.
        var allElements: [Element]? = nil
    }

    /// Each action of a batch that needs the owner's approval, and why, judged on the latest read.
    /// `rules`: judged by these instead of the ones the way of asking leaves (`stopsWhenOff`).
    func sensitiveSteps(_ actions: [JSON], under rules: SensitivityRules? = nil) -> [(at: Int, reason: String)] {
        guard config.sensitive.enabled else { return [] }
        var scan = SensitiveScan(front: lastForeground, secureOnScreen: lastElements.contains(where: \.isSecure))
        var matches: [(at: Int, reason: String)] = []
        for (at, action) in actions.enumerated() {
            if let reason = sensitive(action, &scan, under: rules) { matches.append((at, reason)) }
        }
        return matches
    }

    /// Where approval begins, with every reason the remaining batch must wait.
    func firstSensitive(_ actions: [JSON]) -> (at: Int, reason: String)? {
        let matches = sensitiveSteps(actions)
        guard let first = matches.first else { return nil }
        guard matches.count > 1 else { return first }
        let reasons = matches.map { "action \($0.at + 1): \($0.reason)" }.joined(separator: "; ")
        return (first.at, "multiple sensitive actions: " + reasons)
    }

    /// How a press is judged. `tap`: as a tap is, also by where it lands on a screen not read yet or at
    /// a point on a screen that may have changed. `button`: by the element and the app it is in (back
    /// taps the top-left button of the latest read). `stroke`: by the element's own words
    /// alone, since a swipe in Phone or Wallet scrolls rather than calls or pays.
    enum Press { case tap, button, stroke }

    /// Where an action puts a finger down and lifts it on one element, which a control takes as a press
    /// whatever the action is called. A swipe or scroll_to presses what holds both ends of its first
    /// stroke on a screen that was read (a stroke inside one tall button, or across a wide one). A
    /// key's tap lands on the keyboard's own return key (Go, Search, Send: `returnKeyLabels`), judged
    /// with the key.
    func presses(_ kind: ActionKind, _ action: JSON, _ scan: SensitiveScan, unread: Bool, backTarget: BackTarget? = nil) -> [(element: Element?, atPoint: Bool, judged: Press)] {
        let spec = action[kind.rawValue]
        let localDrag = kind == .drag && spec?["to_pane"] == nil
        // Photos can put the text of a receipt in the Image's label. A gesture over that image
        // moves content, even when the label contains a payment or deletion word.
        func isPhotoContent(_ element: Element?) -> Bool {
            scan.front?.bundleID == "com.apple.mobileslideshow" && element?.type == "Image"
        }
        // On a screen read after the numbers were given, a number is judged by what lies where it is touched.
        func under(_ p: (x: Double, y: Double)?) -> Element? { p.flatMap { element(at: $0, in: scan.elements) } }
        func at(_ spec: JSON?) -> (element: Element?, atPoint: Bool, judged: Press)? {
            guard let spec else { return nil }
            let atPoint = spec.array != nil || spec["x"] != nil
            let e = unread ? nil : scan.elements == nil || atPoint ? target(spec, in: scan.elements) : under(try? point(spec))
            return (localDrag && isPhotoContent(e) ? nil : e, atPoint, .tap)
        }
        func stroke(in spec: JSON?, _ direction: String, _ distance: String) -> [(element: Element?, atPoint: Bool, judged: Press)] {
            guard !unread, let screen = size, let path = try? swipePath(try area(spec, screen), direction, distance),
                  let down = element(at: (path.0, path.1), in: scan.elements), !isPhotoContent(down),
                  down == element(at: (path.2, path.3), in: scan.elements) else { return [] }
            return [(down, false, .stroke)]
        }
        switch kind {
        case .tap, .longPress, .pinch: return [at(spec)].compactMap { $0 }
        // The field is tapped before the text goes.
        case .type: return [at(action["ref"])].compactMap { $0 }
        case .drag:
            if spec?["to_pane"] != nil { return [at(spec?["from"])].compactMap { $0 } }
            if let a = spec?.array, a.count == 4 { return [at([a[0], a[1]]), at([a[2], a[3]])].compactMap { $0 } }
            return [at(spec?["from"]), at(spec?["to"])].compactMap { $0 }
        case .back:
            guard let button = (backTarget ?? currentBackTarget).button else { return [] }
            return [(scan.elements == nil ? button : under(button.frame.centre), false, .button)]
        case .swipe: return stroke(in: spec?["in"] ?? action["in"], spec?.string ?? spec?["direction"]?.string ?? "", spec?["distance"]?.string ?? "long")
        case .scrollTo: return stroke(in: spec?["in"], ["down": "up", "up": "down", "right": "left", "left": "right"][spec?["direction"]?.string ?? "down"] ?? "up", "scroll")
        case .run, .path, .handoff, .key, .button, .launch, .waitUntil, .wait: return []
        }
    }

    /// Why this action needs the owner's approval, or nil; `scan` moves on past it. `do` checks its
    /// actions with it before sending any, and a routine run each step before it sends it.
    func sensitive(_ action: JSON, _ scan: inout SensitiveScan, under override: SensitivityRules? = nil) -> String? {
        let rules = override ?? config.rules
        guard rules.enabled, let kind = ActionKind(action) else { return nil }
        defer { if kind.movesScreen { scan.moved = true } }
        let messaging = scan.front?.bundleID.map(rules.messagingApps.contains) ?? false
        // In a messaging app, after an action that may have opened another screen, that screen is not
        // read yet: the composer's Send sits where the list had nothing, and the search field's number
        // from the list no longer says where typed text goes.
        let unread = !scan.read || (scan.moved && messaging)
        let app = scan.front?.describe ?? "unknown"
        let spec = action[kind.rawValue] ?? .null
        if kind == .drag, spec["to_pane"] != nil, let destination = selectedPane?.other,
           destination != "com.apple.mobilenotes" { return "dropping content into \(destination)" }
        let tree = scan.read ? (scan.allElements ?? lastAll) : []
        if kind == .tap { scan.typingTarget = unread ? nil : target(spec, in: scan.elements) }
        for press in presses(kind, action, scan, unread: unread) {
            if let r = rules.reason(touching: press.element, typing: false, app: press.judged == .stroke ? nil : scan.front, secureOnScreen: scan.secureOnScreen, in: tree) { return r }
            guard press.judged == .tap else { continue }
            if unread, messaging { return "sending a message (a tap in \(app) on a screen not read yet)" }
            // After a launch or a run nothing of the app's screen was read: a Delete there reads as nothing.
            // The home screen after Home opens apps, which ask for themselves.
            if !scan.read, scan.front != nil { return "a tap on a screen not read yet (in \(app))" }
            if scan.moved, press.atPoint { return "a tap at a point on a screen that may have changed since it was read (in \(app))" }
        }
        switch kind {
        case .launch:
            scan.front = Foreground(bundleID: spec.string ?? spec["bundle"]?.string, name: nil)
            scan.read = false; scan.typingTarget = nil
        case .button where spec.text?.lowercased() == "home":
            scan.front = nil
            scan.read = false; scan.typingTarget = nil
        case .run:
            // A routine sends its own taps and keys: in a guarded app, in front or the routine's own
            // (launched first), running it is input there.
            let name = spec.string ?? spec["name"]?.string ?? ""
            let routineApp = memory?.routine(named: name)?.app
            for bundle in [scan.front?.bundleID, routineApp].compactMap({ $0 }) where rules.guardedApps.contains(bundle) {
                return "input in \(bundle == scan.front?.bundleID ? scan.front?.describe ?? bundle : bundle) (skill \"\(name)\")"
            }
            if let routineApp { scan.front = Foreground(bundleID: routineApp, name: nil) }
            scan.read = false; scan.typingTarget = nil
        case .path:
            // A path sends its own taps and keys, each held by these rules on the screen it lands on:
            // in a guarded app, in front or launched by the path, running it is input there.
            let launched = (spec["steps"]?.array ?? spec.array ?? []).compactMap { $0["launch"].flatMap { $0.string ?? $0["bundle"]?.string } }
            for bundle in [scan.front?.bundleID].compactMap({ $0 }) + launched where rules.guardedApps.contains(bundle) {
                return "input in \(bundle == scan.front?.bundleID ? scan.front?.describe ?? bundle : bundle) (a path)"
            }
            if let last = launched.last { scan.front = Foreground(bundleID: last, name: nil) }
            scan.read = false; scan.typingTarget = nil
        case .type:
            guard let text = spec.text else { return nil }
            let e = if let ref = action["ref"] {
                unread ? nil : (scan.elements == nil ? refs[ref.int ?? -1] : nil) ?? scan.typingTarget
            } else {
                scan.read ? scan.typingTarget : nil
            }
            scan.typingTarget = e
            if let r = rules.reason(touching: e, typing: true, app: scan.front, secureOnScreen: scan.read && scan.secureOnScreen && e == nil, in: tree) { return r }
            if messaging, text.contains(where: \.isNewline), !Self.isSearch(e) { return "sending a message (a return typed in \(app))" }
        case .key:
            let key = spec.text ?? ""
            if key.lowercased() == "return", let field = scan.typingTarget, rules.reason(touching: field, typing: true, app: scan.front, secureOnScreen: false, in: tree) != nil {
                return "submitting a password field"
            }
            // Return is the send key in WeChat, WhatsApp and Telegram: typed text goes out on it.
            if messaging, (Self.keyText[key.lowercased()] ?? key).contains(where: \.isNewline), !Self.isSearch(scan.typingTarget) {
                return "sending a message (return in \(app))"
            }
            // Waiting, handing the screen over, swipes, Home and launches are not input in a guarded app.
            if let bundle = scan.front?.bundleID, rules.guardedApps.contains(bundle) { return "input in \(app)" }
        case .button, .tap, .back, .handoff, .swipe, .scrollTo, .longPress, .drag, .pinch, .waitUntil, .wait:
            break
        }
        return nil
    }

    /// A search field: return there searches, it sends nothing.
    static func isSearch(_ field: Element?) -> Bool {
        guard let field else { return false }
        return field.type == "SearchField" || [field.text, field.identifier ?? ""].contains { $0.localizedCaseInsensitiveContains("search") || $0.contains("搜索") }
    }

    func describe(_ action: JSON) -> String {
        for key in ["tap", "long_press"] {
            if let spec = action[key] {
                if let e = target(spec), !e.text.isEmpty { return "\(key) \"\(e.text)\"" }
                return "\(key) \(spec.serialized())"
            }
        }
        if let text = action["type"]?.text {
            let e = action["ref"].flatMap { refs[$0.int ?? -1] }
            return e?.isSecure == true || lastElements.contains(where: \.isSecure) ? "type \(text.count) characters (hidden)" : "type \"\(text.prefix(40))\""
        }
        return action.serialized()
    }

    static func refs(in action: JSON) -> [Int] {
        var out: [Int] = []
        func add(_ value: JSON?) {
            guard let value else { return }
            switch value {
            case .number(let n): out.append(Int(n))
            case .string(let s): if let n = Int(s) { out.append(n) }
            case .object: if let r = value["ref"]?.int { out.append(r) }
            default: break
            }
        }
        for key in ["tap", "long_press", "pinch", "ref", "in"] { add(action[key]) }
        if case .object = action["drag"] { add(action["drag"]?["from"]); add(action["drag"]?["to"]) }
        if case .object = action["swipe"] { add(action["swipe"]?["in"]) }
        if case .object = action["scroll_to"] { add(action["scroll_to"]?["ref"]); add(action["scroll_to"]?["in"]) }
        return out
    }
}
