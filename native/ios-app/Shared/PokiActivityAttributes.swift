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
    /// notification: the agent's words as they are, or PokiCore's in the system's language.
    var sentence: String {
        if ask.isEmpty { return String(activity: "Allow this step?") }
        return byAgent ? ask : ActivityWords.ask(ask)
    }

    /// The rules' kinds beside the agent's own sentence ("Payment and Deletion"): an agent can call a
    /// payment something harmless. Nil when the sentence is PokiCore's, which names the kind itself.
    var kindLine: String? {
        guard byAgent else { return nil }
        let words = kinds.compactMap(Self.kindWord)
        return words.isEmpty ? nil : ListFormatter.localizedString(byJoining: words)
    }

    /// The kinds and the sentence on one line ("Payment: Order lunch, ¥38 in total"), for the island.
    var islandLine: String? { kindLine.map { String(activity: "\($0): \(sentence)") } }

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

enum SharedContainer {
    static let appGroup = Bundle.main.object(forInfoDictionaryKey: "PokiAppGroup") as? String ?? "group.nz.zheha.poki"
    static var url: URL? { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) }
    static var thumbnailURL: URL? { url?.appendingPathComponent("activity-thumbnail.jpg") }
    static var defaults: UserDefaults { UserDefaults(suiteName: appGroup) ?? .standard }
}
