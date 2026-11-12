// The Live Activity's shared data. Phase layout and the terminal flag follow AgentActivityAttributes.swift
// from Clarklevis1995/dsh-mobile (commit ebe19764, DeepSeekHarnessMobile/LiveActivity/AgentActivityAttributes.swift),
// MIT License, Copyright (c) 2026 Chaofan Li. See THIRD_PARTY_NOTICES.md.
import ActivityKit
import Foundation

/// The Live Activity's data, shared by the app (which starts and updates it) and the widget extension
/// (which draws it). ActivityKit caps the payload at 4 KB, so the screenshot thumbnail is not in it:
/// the app writes it to the App Group container and the state carries only its version.
struct PokiActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// `done` is set by ActivityController itself when the agent has been quiet for a while after a
        /// run of steps; `deciding` by AppModel the moment Allow or Deny is tapped on the Live Activity,
        /// until PokiCore has the answer. `handoff`: the agent cannot act on this screen (a passcode, a
        /// verification, a payment) and the person has to; the agent keeps polling meanwhile. See `Handoff`.
        enum Phase: String, Codable, Hashable {
            case idle, working, approval, deciding, pairing, setup, problem, done, handoff

            /// The phases a person has to answer: a step from the agent never replaces them.
            var holdsApproval: Bool { self == .approval || self == .deciding }
        }
        /// Live voice session state when Poki's voice mode is active.
        enum Voice: String, Codable, Hashable {
            case listening, thinking, speaking
        }
        var phase: Phase
        /// What the agent is doing, in a few words ("Tap “Send”"), or the phase's line, in English: the
        /// face words it in the system's language (ActivityWords).
        var headline: String
        /// The status word in place of the phase's own ("Runner Stopped").
        var label: String?
        /// The app in front.
        var app: String?
        /// The outside agent driving the phone ("Claude Code"), nil for Poki's own chat.
        var caller: String?
        /// Bumped whenever a new thumbnail is written to the App Group container.
        var thumbnailVersion: Int
        /// A pending approval, if any. Its buttons are App Intents; see ApprovalIntents.swift.
        var approval: PendingApproval?
        /// While `deciding`: true for Allow, false for Deny.
        var decision: Bool?
        /// What the person has to do themselves, while phase is `handoff`.
        var handoff: Handoff?
        /// The pairing PIN while on-device pairing is waiting for it.
        var pin: String?
        /// The runner is stopped while no agent uses the phone (no automation banner); the next
        /// request starts it again.
        var runnerPaused = false
        /// During setup: which step the person is on ("2/6").
        var guide: Guide?
        /// Live voice conversation state, when active.
        var voice: Voice? = nil
        /// When the agent's current run of steps began.
        var since: Date?
        /// Actions taken in the current run, and how many of them did not go through. Kept by
        /// ActivityController. What the Live Activity shows as the step is `progress` (ActivityFace).
        var stepCount = 0
        var failedCount = 0
        /// The step before the one under way, in English like `headline`: the expanded island shows
        /// it ticked under the current one. Kept by ActivityController.
        var previous: String?
        /// When the run finished (phase `done`), so the summary shows a fixed duration.
        var endedAt: Date?
        /// A short-lived event ("Started", "Now in WeChat", "Allowed") shown as the status word for a few
        /// seconds. ActivityController clears it.
        var event: Event?

        /// The plan the chat's model published: the Live Activity then counts the plan's steps, as the
        /// chat's plan bubble does, not the single taps under them.
        var plan: Plan?
    }
    /// report_plan's plan, in the model's own words: the Live Activity says the step under way as the
    /// plan words it ("Open the chat with Mom"), not the tap under it.
    struct Plan: Codable, Hashable {
        var steps: [String]
        /// The step under way, from 1.
        var current: Int
        /// The task in a few words ("Text Mom"), from report_plan's `title`.
        var title: String? = nil
        /// Who the task's message goes to ("Mom"), from report_plan's `to`.
        var to: String? = nil

        var total: Int { steps.count }
    }
    struct Event: Codable, Hashable {
        enum Kind: String, Codable, Hashable { case started, app, finished, approved, denied, expired, problem, paired, code, handoff, resumed }
        var kind: Kind
        var text: String
    }
    /// The agent (or the runner's launch) handed a screen to the person. `kind` picks the words and
    /// the symbol; `text` is the agent's own one-line note of what is needed, if any. The person taps
    /// Done on the Live Activity when finished (HandoffDoneIntent), which the app passes on to PokiCore.
    struct Handoff: Codable, Hashable {
        enum Kind: String, Codable, Hashable { case runnerPasscode, automationPasscode, passcode, password, verification, payment, other }
        var id: String
        var kind: Kind
        var text: String?
        var app: String?
        var since: Date
    }
    struct Guide: Codable, Hashable {
        var number: Int
        var count: Int
        var title: String
    }
    var deviceName: String
}

struct PendingApproval: Codable, Hashable {
    var id: String
    var app: String
    /// The actions as PokiCore's step labels ("Tap “Delete”, then tap “Delete”"): for the logs only.
    var summary: String
    /// Why it needs the owner, from PokiCore's rules: `sending a message ("send")`. For the logs only.
    var reason: String
    var expires: Date
    /// PokiCore's one sentence for the owner (`Approval.ask`): the agent's own words, or what the rules
    /// saw and where ("Delete in Notes").
    var ask = ""
    /// The agent wrote `ask` (do's `purpose`), so the rules' own kinds go beside it.
    var byAgent = false
    /// What the rules saw (`ApprovalKind`'s raw values), most serious first.
    var kinds: [String] = []

    /// What the owner is asked, in one sentence, on every card, the island, the alert and the
    /// notification: the agent's words as they are, or the rules' own in the system's language, which
    /// name every kind they saw ("In Lunch, about to delete something and pay").
    var sentence: String {
        if byAgent, !ask.isEmpty { return ask }
        if let rules = rulesSentence { return rules }
        return ask.isEmpty ? String(activity: "Allow this step?") : ActivityWords.ask(ask)
    }

    /// The rules' sentence from the kinds and the app; nil for an approval saved before kinds were kept.
    var rulesSentence: String? {
        guard let first = kinds.first else { return nil }
        let place = app.isEmpty || app == "unknown" || app.contains("(") ? nil : ActivityWords.local(app)
        guard kinds.count > 1 else { return Self.oneKind(first, place: place) }
        let verbs = ListFormatter.localizedString(byJoining: kinds.compactMap(Self.verb))
        return place.map { String(activity: "In \($0), about to \(verbs)") } ?? String(activity: "About to \(verbs)")
    }

    /// Every kind the rules saw ("Payment and Deletion"), for the lines that carry only text: the
    /// notification's subtitle and the island's alert. Nil when the rules saw none.
    var kindLine: String? {
        let words = kinds.compactMap(Self.kindWord)
        return words.isEmpty ? nil : ListFormatter.localizedString(byJoining: words)
    }

    /// The kinds and the sentence on one line ("Payment: Order lunch, ¥38 in total"), for the alert,
    /// which is text only; the kinds lead, so a cut never takes them.
    var alertLine: String { kindLine.map { String(activity: "\($0): \(sentence)") } ?? sentence }

    /// The rules' kinds as tags over the sentence, on every card, the island and the Lock Screen:
    /// an agent can word a payment as something harmless ("Payment cancelled, nothing to approve"),
    /// so the tags, which the agent cannot touch, are what stands out. Never cut.
    var tags: [ApprovalTag] {
        kinds.compactMap { kind in Self.kindWord(kind).map { ApprovalTag(word: $0, warning: Self.warning.contains(kind)) } }
    }

    /// The kinds in the warning colour: money, deletions, and the apps where every input waits
    /// (banking, Wallet).
    static let warning: Set<String> = ["payment", "deleting", "input"]

    private static func oneKind(_ kind: String, place: String?) -> String? {
        switch kind {
        case "payment": place.map { String(activity: "Pay in \($0)") } ?? String(activity: "Make a payment")
        case "deleting": place.map { String(activity: "Delete in \($0)") } ?? String(activity: "Delete something")
        case "sending": place.map { String(activity: "Send a message in \($0)") } ?? String(activity: "Send a message")
        case "call": place.map { String(activity: "Place a call in \($0)") } ?? String(activity: "Place a call")
        case "password": place.map { String(activity: "Type a password in \($0)") } ?? String(activity: "Type a password")
        case "input": place.map { String(activity: "Use \($0)") } ?? String(activity: "Use this app")
        case "unread": place.map { String(activity: "Go on in \($0)") } ?? String(activity: "Go on with this step")
        default: nil
        }
    }

    /// What a kind does, to list several in one sentence.
    private static func verb(_ kind: String) -> String? {
        switch kind {
        case "payment": String(activity: "pay")
        case "deleting": String(activity: "delete something")
        case "sending": String(activity: "send a message")
        case "call": String(activity: "place a call")
        case "password": String(activity: "type a password")
        case "input": String(activity: "use a protected app")
        case "unread": String(activity: "take a step Poki could not check")
        default: nil
        }
    }

    static func kindWord(_ kind: String) -> String? {
        switch kind {
        case "payment": String(activity: "Payment")
        case "deleting": String(activity: "Deletion")
        case "sending": String(activity: "Sending")
        case "call": String(activity: "Call")
        case "password": String(activity: "Password")
        case "input": String(activity: "Protected app")
        // The rules could not read what the press does.
        case "unread": String(activity: "Unchecked step")
        default: nil
        }
    }
}

/// One kind the rules saw, as a tag over an approval's sentence.
struct ApprovalTag: Hashable {
    var word: String
    /// Payment, deletion, a protected app: drawn in the warning colour.
    var warning: Bool
}

enum SharedContainer {
    static let appGroup = Bundle.main.object(forInfoDictionaryKey: "PokiAppGroup") as? String ?? "group.nz.zheha.poki"
    static var url: URL? { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) }
    static var thumbnailURL: URL? { url?.appendingPathComponent("activity-thumbnail.jpg") }
    static var defaults: UserDefaults { UserDefaults(suiteName: appGroup) ?? .standard }
}
