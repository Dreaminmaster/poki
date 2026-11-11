import Foundation

typealias PokiState = PokiActivityAttributes.ContentState

/// What the Live Activity shows for a state, worked out once per phase. The Lock Screen, the expanded
/// island, the compact island and the minimal circle all draw this, so a phase's words and colours
/// live in one table (`PokiState.face`) instead of a switch in every view. The layout, words and
/// colours follow ESP-139's final board 02 and ESP-171's final Dynamic Island / Lock Screen boards.
struct ActivityFace: Hashable {
    enum Meta: Hashable {
        case none
        /// A short count or location ("Step 7", "2 of 6", "Settings").
        case text(String)
        /// The time left on an approval, counted down by the system.
        case countdown(Date)
        /// A time of day ("9:41 AM").
        case clock(Date)
        /// How long the agent has waited for the person, counted up by the system.
        case elapsed(Date)
    }
    enum Compact: Hashable {
        /// Words and short counts ("Step 7", "2/6").
        case text(String, ActivityTone)
        /// The pairing code, tabular digits.
        case code(String)
        /// A single bold mark ("!").
        case mark(String, ActivityTone)
        case countdown(Date)
        case elapsed(Date)
        case symbol(String, ActivityTone)
    }
    enum Bottom: Hashable {
        case none
        /// One dot per step on a line, the missed ones larger and red, the current step hollow; the
        /// line turns green when the run is finished. Stop beside it while working.
        case progress(outcomes: [Bool], current: Bool, finished: Bool, stop: Bool)
        case approval(id: String)
        /// The answer is on its way to PokiCore.
        case deciding(String)
        /// "Done, carry on" for a screen the agent handed to the person.
        case handoff(id: String)
        /// Open Poki to fix a stopped runner or pairing error.
        case openPoki
        /// The setup steps: done, the current one, the rest.
        case segments(number: Int, count: Int)
    }
    enum Minimal: Hashable {
        case avatar
        /// The avatar in a ring that fills with the run's steps.
        case ring(Double)
        case approval
        case problem
    }
    enum Thumbnail: Hashable { case none, large, small }

    /// SF Symbol used for the in-app debug preview list icon.
    var symbol: String = "sparkles"
    /// The status word on the Lock Screen ("Approval Required"), coloured by `tone`.
    var status: String
    /// The same, short enough for the expanded island's leading region ("Approval").
    var shortStatus: String
    var tone: ActivityTone
    /// The Lock Screen's top-right value, and the expanded island's (shorter where it has to be).
    var meta: Meta
    var shortMeta: Meta
    /// The main title line.
    var content: String
    /// The title is a pairing code in large digits.
    var contentIsCode = false
    /// The secondary line under the title on the Lock Screen and expanded island.
    var subtitle: String? = nil
    var subtitleTone: ActivityTone = .quiet
    var bottom: Bottom
    /// The latest screenshot beside the Lock Screen card's words.
    var thumbnail: Thumbnail = .none
    var compact: Compact
    var minimal: Minimal = .avatar
    /// Outline the island in the website's blue (an approval or handoff waiting).
    var outlined = false
    /// The screen a tap opens.
    var link: URL = ActivityLink.chat
    /// The app has not updated the activity for longer than it should have: what it shows may be old.
    var stale = false
    /// Who is calling: the outside agent whose badge sits beside the meta value.
    var caller: String?
}

/// Where a tap on the Live Activity goes, handled by RootView's onOpenURL.
enum ActivityLink {
    /// The chat that runs the agent (also approvals and handoffs, which the chat shows).
    static let chat = URL(string: "poki://chat")!
    /// The Activity Log, where a problem's details are.
    static let log = URL(string: "poki://log")!
    static func setup(_ step: String? = nil) -> URL {
        URL(string: step.map { "poki://setup?step=\($0)" } ?? "poki://setup")!
    }
}

extension PokiActivityAttributes.Event {
    var tone: ActivityTone {
        switch kind {
        case .started, .app, .code, .resumed: .accent
        case .handoff: .approval
        case .finished, .approved, .paired: .done
        case .denied, .expired: .quiet
        case .problem: .problem
        }
    }
}

extension PokiState {
    var hasThumbnail: Bool { thumbnailVersion > 0 }

    /// "12 steps in 1:24".
    var runLine: String {
        let steps = stepCount == 1 ? String(activity: "1 step") : String(activity: "\(stepCount) steps")
        guard let since, let endedAt else { return steps }
        let time = Duration.seconds(max(0, endedAt.timeIntervalSince(since))).formatted(.time(pattern: .minuteSecond))
        return String(activity: "\(steps) in \(time)")
    }

    /// "12 steps in 1:24, 1 missed".
    var runSummary: String {
        failedCount > 0 ? String(activity: "\(runLine), \(failedCount) missed") : runLine
    }

    /// "Finished in Messages".
    var doneTitle: String {
        if let app, !app.isEmpty, app != "unknown" {
            return String(activity: "Finished in \(ActivityWords.local(app))")
        }
        if headline.hasPrefix("Finished in ") {
            let place = String(headline.dropFirst("Finished in ".count))
            return String(activity: "Finished in \(ActivityWords.local(place))")
        }
        return String(activity: "Finished")
    }

    var face: ActivityFace { face(stale: false) }

    /// The face for the widget: `stale` when ActivityKit says the content is past its stale date.
    func face(stale: Bool) -> ActivityFace {
        var face = baseFace
        face.caller = caller
        // A fresh event ("Started", "Allowed") takes the status word's place for a few seconds, in
        // its own colour. An app switch keeps the app's name as the word and only lights it up.
        if let event, !phase.holdsApproval {
            let word = event.kind == .app ? (app.map { ActivityWords.local($0) } ?? event.text) : ActivityWords.local(event.text)
            face.status = word
            face.shortStatus = word
            face.tone = event.tone
            // Compact text and its adjacent glyph are one status. A transient
            // event must not recolor only the glyph (for example blue + green Ready).
            switch face.compact {
            case .text(let text, _): face.compact = .text(text, event.tone)
            case .symbol(let name, _): face.compact = .symbol(name, event.tone)
            case .mark(let mark, _): face.compact = .mark(mark, event.tone)
            default: break
            }
        }
        if stale, phase == .working || phase == .handoff {
            // The app stopped updating (closed, or iOS suspended it): say so, and drop the action,
            // which needs the app.
            let word = String(activity: "Not updating")
            face.symbol = "clock.badge.exclamationmark"
            face.status = word
            face.shortStatus = String(activity: "Paused")
            face.tone = .quiet
            face.meta = .none
            face.shortMeta = .none
            face.bottom = .none
            face.compact = .text(String(activity: "Paused"), .quiet)
            face.outlined = false
            face.stale = true
        }
        return face
    }

    private var baseFace: ActivityFace {
        let step = String(activity: "Step \(stepCount + 1)")
        switch phase {
        case .working:
            let name = app.map { ActivityWords.local($0) } ?? (voice != nil ? String(activity: "Voice") : String(activity: "Working"))
            return ActivityFace(
                symbol: voice != nil ? "waveform" : "hand.tap.fill",
                status: name, shortStatus: name, tone: .quiet,
                meta: .text(step), shortMeta: .text(step),
                content: ActivityWords.step(headline),
                subtitle: nil,
                bottom: .progress(outcomes: outcomes, current: true, finished: false, stop: true),
                thumbnail: hasThumbnail ? .large : .none,
                compact: .text(step, .plain),
                minimal: .ring(Double(outcomes.count) / Double(Self.outcomeLimit)))
        case .approval, .deciding:
            guard let approval else { return quietFace }
            let question = approval.question
            if phase == .deciding {
                let allowed = decision == true
                let word = allowed ? String(activity: "Allowed") : String(activity: "Denied")
                return ActivityFace(
                    symbol: allowed ? "checkmark.circle.fill" : "xmark.circle.fill",
                    status: word, shortStatus: word, tone: allowed ? .approval : .quiet,
                    meta: .none, shortMeta: .none,
                    content: question,
                    subtitle: approval.reasonLine, subtitleTone: .reason,
                    bottom: .deciding(allowed ? String(activity: "Continuing") : String(activity: "Telling the agent")),
                    thumbnail: hasThumbnail ? .small : .none,
                    compact: .symbol(allowed ? "checkmark" : "xmark", allowed ? .approval : .quiet),
                    minimal: .approval)
            }
            return ActivityFace(
                symbol: "hand.raised.fill",
                status: String(activity: "Approval Required"), shortStatus: String(activity: "Approval"), tone: .approval,
                meta: .countdown(approval.expires), shortMeta: .countdown(approval.expires),
                content: question,
                subtitle: approval.reasonLine, subtitleTone: .reason,
                bottom: .approval(id: approval.id),
                thumbnail: hasThumbnail ? .small : .none,
                compact: .countdown(approval.expires),
                minimal: .approval,
                outlined: true)
        case .done:
            let time: ActivityFace.Meta = endedAt.map { .clock($0) } ?? .none
            let word = String(activity: "Done")
            return ActivityFace(
                symbol: "checkmark.circle.fill",
                status: word, shortStatus: word, tone: .done,
                meta: time, shortMeta: time,
                content: doneTitle,
                subtitle: runSummary,
                bottom: .progress(outcomes: outcomes, current: false, finished: true, stop: false),
                thumbnail: hasThumbnail ? .large : .none,
                compact: .symbol("checkmark", .done))
        case .problem:
            let meta: ActivityFace.Meta = stepCount > 0 ? .text(step) : .none
            let short = label == "Pairing Failed" ? String(activity: "Failed") : String(activity: "Stopped")
            let (problemTitle, problemSubtitle) = Self.problemPresentation(for: headline)
            return ActivityFace(
                symbol: "exclamationmark.triangle.fill",
                status: ActivityWords.local(label ?? "Problem"), shortStatus: short,
                tone: .problem, meta: meta, shortMeta: meta,
                content: problemTitle,
                subtitle: problemSubtitle,
                bottom: .openPoki,
                compact: .mark("!", .problem),
                minimal: .problem,
                link: label == "Pairing Failed" ? ActivityLink.setup("pairing") : ActivityLink.log)
        case .pairing:
            if let pin {
                return ActivityFace(
                    symbol: "link",
                    status: String(activity: "Pairing Code"), shortStatus: String(activity: "Pairing"),
                    tone: .accent,
                    meta: .text(String(activity: "Settings › Developer Mode")),
                    shortMeta: .text(String(activity: "Settings")),
                    content: pin.count == 6 ? "\(pin.prefix(3)) \(pin.suffix(3))" : pin, contentIsCode: true,
                    subtitle: String(activity: "Tap Pair with Poki, then enter this code."),
                    bottom: .none,
                    compact: .code(pin),
                    link: ActivityLink.setup("pairing"))
            }
            let word = String(activity: "Pairing")
            return ActivityFace(
                symbol: "link",
                status: word, shortStatus: word, tone: .accent,
                meta: .text(String(activity: "Settings › Developer Mode")),
                shortMeta: .text(String(activity: "Settings")),
                content: String(activity: "Pair in Settings"),
                subtitle: String(activity: "Open Pair with Poki there. The code shows up here."),
                bottom: .none,
                compact: .symbol("link", .accent),
                link: ActivityLink.setup("pairing"))
        case .setup:
            guard let guide else { return quietFace }
            let word = String(activity: "Setup")
            let (setupTitle, setupSubtitle) = Self.setupPresentation(for: guide.title)
            return ActivityFace(
                symbol: "checklist",
                status: word, shortStatus: word, tone: .accent,
                meta: .text(String(activity: "Step \(guide.number) of \(guide.count)")),
                shortMeta: .text(String(activity: "\(guide.number) of \(guide.count)")),
                content: setupTitle,
                subtitle: setupSubtitle,
                bottom: .segments(number: guide.number, count: guide.count),
                compact: .text("\(guide.number)/\(guide.count)", .plain),
                link: ActivityLink.setup())
        case .handoff:
            guard let handoff else { return quietFace }
            let word = String(activity: "Your turn")
            return ActivityFace(
                symbol: handoff.symbol,
                status: word, shortStatus: word, tone: .approval,
                meta: .elapsed(handoff.since), shortMeta: .elapsed(handoff.since),
                content: handoff.line,
                subtitle: handoff.detail,
                bottom: .handoff(id: handoff.id),
                compact: .elapsed(handoff.since),
                minimal: .approval,
                outlined: true)
        case .idle:
            if let voice {
                let word = String(activity: "Voice")
                let (line, hint): (String, String) = switch voice {
                case .listening: (String(activity: "Listening"), String(activity: "Speak to Poki, or tap to open Voice."))
                case .thinking: (String(activity: "Thinking"), String(activity: "Working out the next step."))
                case .speaking: (String(activity: "Speaking"), String(activity: "Tap to return to Voice."))
                }
                return ActivityFace(
                    symbol: "waveform",
                    status: word, shortStatus: word, tone: .accent,
                    meta: .none, shortMeta: .none,
                    content: line,
                    subtitle: hint,
                    bottom: .none,
                    compact: .symbol("waveform", .accent))
            }
            return quietFace
        }
    }

    /// Ready (the runner is up) and Idle (it sleeps until an agent asks).
    private var quietFace: ActivityFace {
        let word = runnerPaused ? String(activity: "Idle") : String(activity: "Ready")
        return ActivityFace(
            symbol: runnerPaused ? "zzz" : "checkmark",
            status: word, shortStatus: word,
            tone: runnerPaused ? .quiet : .done,
            meta: .none, shortMeta: .none,
            content: ActivityWords.local(headline),
            subtitle: runnerPaused
                ? String(activity: "The runner wakes when an agent asks.")
                : String(activity: "Runner on. Waiting for the agent."),
            bottom: .none,
            compact: .symbol(runnerPaused ? "zzz" : "checkmark", runnerPaused ? .quiet : .done))
    }

    /// Maps `ContentState.headline` for `.problem` to an actionable title and explanatory subtitle
    /// matching ESP-139 final board 02.
    private static func problemPresentation(for headline: String) -> (String, String) {
        switch headline {
        case "Loopback Off", "Turn On Loopback", "Can’t Reach iPhone":
            return (String(activity: "Turn On Loopback"), String(activity: "In your proxy app, or connect LocalDevVPN."))
        case "No Internet", "Connect to the Internet":
            return (String(activity: "Connect to the Internet"), String(activity: "Poki needs it once after each restart, then tries again."))
        case "Disk Image Outdated", "Update the Disk Image":
            return (String(activity: "Update the Disk Image"), String(activity: "Open Poki's setup to download the latest one."))
        case "Fetching Disk Image", "Downloading the Disk Image":
            return (String(activity: "Downloading the Disk Image"), String(activity: "Poki downloads it again by itself."))
        case "Pairing Refused", "Pair Again":
            return (String(activity: "Pair Again"), String(activity: "In Poki's setup."))
        case "Loopback or Pairing":
            return (String(activity: "Turn On Loopback"), String(activity: "In your proxy app, or pair again in Poki's setup."))
        case "Developer Mode Off", "Check Developer Mode", "Turn On Developer Mode":
            return (String(activity: "Turn On Developer Mode"), String(activity: "Privacy & Security › Developer Mode, then restart."))
        case "Poki Runner Missing", "Poki Runner Didn’t Start", "Install Poki Runner":
            return (String(activity: "Install Poki Runner"), String(activity: "With the same signing tool and Apple ID as Poki."))
        case "Update iOS":
            return (String(activity: "Update iOS"), String(activity: "This feature requires a newer version of iOS."))
        default:
            return (ActivityWords.local(headline), String(activity: "Open Poki to fix it."))
        }
    }

    /// Maps `Guide.title` for `.setup` to an actionable title and two-line Settings path subtitle
    /// matching ESP-139 final board 02.
    private static func setupPresentation(for title: String) -> (String, String?) {
        switch title {
        case "Poki Runner", "Install Poki Runner":
            return (String(activity: "Install Poki Runner"), String(activity: "General › VPN & Device Management. Trust Poki Runner's developer."))
        case "Developer Mode", "Turn On Developer Mode":
            return (String(activity: "Turn On Developer Mode"), String(activity: "Privacy & Security › Developer Mode. Restart, then tap Turn On."))
        case "Loopback", "Turn On Loopback":
            return (String(activity: "Turn On Loopback"), String(activity: "In your proxy app, or connect LocalDevVPN. Then come back to Poki."))
        case "Pairing", "Pair This iPhone":
            return (String(activity: "Pair This iPhone"), String(activity: "Privacy & Security › Developer Mode › Pair with Poki."))
        case "UI Automation", "Allow UI Automation":
            return (String(activity: "Allow UI Automation"), String(activity: "Developer › Enable UI Automation."))
        case "Background", "Let Poki Stay On":
            return (String(activity: "Let Poki Stay On"), String(activity: "Allow location While Using the App, and keep Live Activities on."))
        default:
            return (ActivityWords.local(title), nil)
        }
    }
}

extension PokiActivityAttributes.Handoff {
    /// What the person has to do, in the agent's place.
    var title: String {
        switch kind {
        case .runnerPasscode: String(activity: "Enter your passcode to start the runner")
        case .automationPasscode: String(activity: "Enter your passcode to allow automation")
        case .passcode: String(activity: "Enter your passcode")
        case .password: String(activity: "Fill in your password")
        case .verification: String(activity: "Pass the verification yourself")
        case .payment: String(activity: "Finish the payment yourself")
        case .other: String(activity: "Do this step yourself")
        }
    }
    /// The content line: a fixed short line per kind.
    var line: String {
        switch kind {
        case .runnerPasscode: String(activity: "Passcode for the runner")
        case .automationPasscode: String(activity: "Passcode for automation")
        default: title
        }
    }
    /// The agent's own note, or what happens next (the subtitle and the alert's second line).
    var detail: String {
        if let text, !text.isEmpty { return text }
        switch kind {
        case .runnerPasscode: return String(activity: "iOS asks for it once after a restart. The agent waits.")
        case .automationPasscode: return String(activity: "iOS asks after Poki restarts or 8 hours later. The agent waits.")
        case .payment: return String(activity: "The agent does not pay for you. It waits, then carries on.")
        default: return String(activity: "The agent can't act on this screen. It waits for you.")
        }
    }
    var symbol: String {
        switch kind {
        case .runnerPasscode, .automationPasscode, .passcode: "lock.fill"
        case .password: "key.fill"
        case .verification: "checkmark.shield.fill"
        case .payment: "creditcard.fill"
        case .other: "person.fill"
        }
    }
}
