import AVFoundation
import SwiftUI

/// The chat is the app (ESP-326 boards "01 Chat: Greeting", "03 Chat: Back in Poki mid-task",
/// "04 Chat: Needs you"): Poki's face, name and status in the navigation bar, the conversation, and the
/// two-layer message field. Before your first message the page is the bear and what you could ask.
/// An approval or a hand-over shows as a card above the message field, where iOS hides the Dynamic
/// Island while Poki is in front.
struct ChatView: View {
    @Environment(AppModel.self) private var model
    @Environment(ChatModel.self) private var chat
    var openDetails: () -> Void
    var openVoice: () -> Void
    var openSetup: () -> Void
    var openSetupStep: (SetupStep) -> Void = { _ in }
    var openModel: () -> Void
    /// Opens the conversations (the drawer on iPhone); nil where the list is always beside the chat.
    var openThreads: (() -> Void)? = nil
    /// The bear here is where Poki's profile zooms out of.
    var profileSource: Namespace.ID? = nil

    private var voice: VoiceModel { model.voice }
    @State private var draft = ""

    private var sampleScene: String? { UserDefaults.standard.string(forKey: "pokiChat") }

    /// No message of yours yet: the page is the bear and what you could ask, not a transcript.
    private var isGreeting: Bool {
        guard !chat.running, !voice.isOn, voice.lines.isEmpty else { return false }
        return !chat.entries.contains(where: Self.isContent)
    }

    /// Anything but the time and Poki's own opening lines.
    private static func isContent(_ entry: ChatEntry) -> Bool {
        switch entry.kind {
        case .time, .poki: false
        default: true
        }
    }

    /// The greeting's last line: whether Poki asks before a sensitive step (ChatModel writes it from the
    /// approval setting). The page says it under the bear.
    private var promise: String? {
        for entry in chat.entries.reversed() {
            if case .poki(let text) = entry.kind { return text }
        }
        return nil
    }

    /// The conversation without the greeting's lines, which the page said under the bear.
    private var shown: [ChatEntry] {
        guard let first = chat.entries.firstIndex(where: Self.isContent) else { return chat.entries }
        return chat.entries.enumerated().compactMap { i, entry in
            if i < first, case .poki = entry.kind { return nil }
            return entry
        }
    }

    /// The task is under way; the screenshots' sample scenes stand still in that state.
    private var live: Bool { busy || sampleScene == "setupHint" }

    /// Poki is at work (or the sample scene shows it at work): the message field offers Stop.
    private var busy: Bool {
        chat.running || ["working", "approval", "handoff"].contains(sampleScene ?? "")
    }

    var body: some View {
        let status = PokiStatus.current(model: model, chat: chat)
        Group {
            if isGreeting {
                GreetingView(mood: status.mood, promise: promise, source: profileSource, openDetails: openDetails, pick: { draft = $0 }) {
                    if let hint = currentSetupHint {
                        SetupHintLine(hint: hint, openSetupStep: openSetupStep, openSetup: openSetup, openModel: openModel)
                    }
                }
            } else {
                ChatTranscript(entries: shown, typing: chat.awaitingModel, canRetry: chat.canRetry, retry: chat.retry, session: chat.sessionID,
                               live: live, waiting: !model.approvals.isEmpty || sampleScene == "approval",
                               handedOver: model.handoffText != nil || sampleScene == "handoff",
                               plan: chat.planSteps, app: sampleScene == nil ? model.currentApp : "Messages") {
                    if let hint = currentSetupHint {
                        SetupHintLine(hint: hint, openSetupStep: openSetupStep, openSetup: openSetup, openModel: openModel)
                    }
                    LiveVoiceTranscript(voice: voice)
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if voice.isOn { LiveVoiceBar(voice: voice).transition(.move(edge: .top).combined(with: .opacity)) }
        }
        .bottomBar {
            VStack(spacing: 8) {
                asks
                ComposerInputView(input: $draft, running: busy, progress: progress, sample: sampleScene != nil,
                                  send: chat.send, stop: chat.stop, openVoice: openVoice, openModel: openModel,
                                  openDetails: openDetails, newConversation: chat.newConversation)
            }
            .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 8)
            .frame(maxWidth: 720)
        }
        .animation(.snappy, value: voice.isOn)
        .animation(.snappy, value: model.approvals.first?.id)
        .animation(.snappy, value: model.handoffText)
        .background(Color(.systemBackground))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { bar(status) }
        .onChange(of: chat.running) { was, now in
            if was, !now, endedWell { DoneLinger.shared.celebrate() }
        }
    }

    // MARK: Navigation bar

    @ToolbarContentBuilder private func bar(_ status: PokiStatus) -> some ToolbarContent {
        if let openThreads {
            ToolbarItem(placement: .topBarLeading) {
                Button("Conversations", systemImage: "line.3.horizontal", action: openThreads)
                    .accessibilityIdentifier("chat.threads")
            }
        }
        ToolbarItem(placement: .principal) { header(status) }
        ToolbarItem(placement: .topBarTrailing) {
            Button("New Conversation", systemImage: "square.and.pencil") { chat.newConversation() }
                .disabled(chat.running)
                .accessibilityIdentifier("home.newChat")
        }
    }

    /// Poki's face, name and what it is doing: the way into its profile. On the greeting the big bear
    /// on the page is the face, so the bar keeps to the name.
    private func header(_ status: PokiStatus) -> some View {
        Button(action: openDetails) {
            HStack(spacing: 8) {
                if !isGreeting {
                    PokiAvatar(size: 32, mood: status.mood).profileSource(profileSource)
                }
                VStack(alignment: isGreeting ? .center : .leading, spacing: 0) {
                    Text(verbatim: "Poki").font(Prominent.font(.headline, .semibold)).foregroundStyle(Color(.label))
                    PokiStatusLine(status: status).font(.caption).foregroundStyle(Color(.secondaryLabel))
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Poki, \(status.word), details"))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("chat.header.details")
    }

    // MARK: What waits for you

    /// The step waiting for your answer, or the hand-over, above the message field.
    @ViewBuilder private var asks: some View {
        if sampleScene == "approval" {
            let sample = PendingApproval(id: "sample", app: "Messages", summary: String(localized: "Tap “Send”"),
                                         reason: "sending a message (\"send\")", expires: Date().addingTimeInterval(48))
            ApprovalAskCard(title: sample.question, detail: sample.reasonLine, quote: sample.summary, expires: sample.expires, answer: { _ in })
        } else if sampleScene == "handoff" {
            TurnCard(text: Self.local(AppModel.handoffWording(.passcode)), done: {})
        } else if let approval = model.approvals.first {
            ApprovalAskCard(title: approval.question, detail: approval.reasonLine, quote: approval.summary, expires: approval.expires,
                            answer: { approved in model.resolve(approval, approved: approved) })
                .transition(.move(edge: .bottom).combined(with: .opacity))
        } else if let text = model.handoffText {
            TurnCard(text: Self.local(text), done: model.handoffDoneInApp)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    /// The app's own hand-over wordings in the phone's language; the model's own words as they are.
    private static func local(_ text: String) -> String {
        Bundle.main.localizedString(forKey: text, value: text, table: nil)
    }

    /// How far the task is, for the ring around Stop: the finished steps out of the model's plan, or
    /// out of the steps so far when it published none.
    private var progress: Double? {
        guard busy else { return nil }
        for entry in chat.entries.reversed() {
            switch entry.kind {
            case .plan(let steps):
                let total = max(chat.planSteps?.count ?? 0, steps.count)
                return total > 0 ? Double(steps.filter { $0.state == .done }.count) / Double(total) : nil
            case .you, .request: return nil
            default: continue
            }
        }
        return nil
    }

    /// The task that just ended went through: its last steps hold no failure and it did not end on a problem.
    private var endedWell: Bool {
        for entry in chat.entries.reversed() {
            switch entry.kind {
            case .note(.problem): return false
            case .plan(let steps): return !steps.contains { $0.state == .failed }
            case .you, .request: return false
            default: continue
            }
        }
        return false
    }

    /// When a setup step or model account keeps Poki from acting, the chat shows one grey line and a
    /// link straight to that item (ESP-174 board "C1 Chat setup hint").
    private var currentSetupHint: SetupIssueHint? {
        if sampleScene == "setupHint" {
            return SetupIssueHint(
                message: String(localized: "Poki can’t tap Send yet: UI Automation is off."),
                link: String(localized: "Turn On UI Automation ›"),
                target: .step(.automation)
            )
        }
        guard sampleScene == nil else { return nil }
        return SetupIssueHint.first(model: model)
    }
}

/// The page before your first message: the bear, one line that says what Poki is for and whether it
/// asks first, and three things you could ask. A suggestion fills the message field; nothing is sent
/// until you send it.
private struct GreetingView<Footer: View>: View {
    var mood: PokiMood
    var promise: String?
    var source: Namespace.ID?
    var openDetails: () -> Void
    var pick: (String) -> Void
    @ViewBuilder var footer: () -> Footer

    private static var ideas: [(symbol: String, text: String)] {
        [("bubble.left", String(localized: "Text Mom I’m running 10 min late")),
         ("cup.and.saucer", String(localized: "Order my usual coffee")),
         ("bell.slash", String(localized: "Clear my notifications"))]
    }

    /// Sentences on one line: a space between them, except after a full-width stop, which brings its own.
    private static func line(_ sentences: [String?]) -> String {
        sentences.compactMap { $0 }.reduce(into: "") { line, next in
            line += line.isEmpty || line.hasSuffix("。") ? next : " " + next
        }
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    Button(action: openDetails) {
                        // The bear greets you while all is well; asleep, lost or waiting, it shows that.
                        PokiAvatar(size: 124, mood: mood == .ready ? .hello : mood).profileSource(source)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Poki, details"))
                    .accessibilityIdentifier("home.poki.details")

                    Text("Hand me your phone.")
                        .font(Prominent.font(.largeTitle, .bold)).foregroundStyle(Color(.label))
                        .multilineTextAlignment(.center).padding(.top, 24)
                    Text(verbatim: Self.line([String(localized: "I tap, type and scroll for you."), promise]))
                        .font(.body).foregroundStyle(Color(.secondaryLabel))
                        .multilineTextAlignment(.center).padding(.top, 8)

                    VStack(spacing: 10) {
                        ForEach(Self.ideas, id: \.text) { idea in
                            Button { pick(idea.text) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: idea.symbol).frame(width: 24)
                                    Text(verbatim: idea.text).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                                    // The arrow of a search suggestion: it goes into the field, it is not sent.
                                    Image(systemName: "arrow.up.left").font(.footnote.weight(.semibold)).foregroundStyle(Color(.tertiaryLabel))
                                }
                                .foregroundStyle(Color(.label))
                                .padding(.vertical, 2)
                            }
                            // The system's grey bordered button: blue stays Poki's, so no tint.
                            .buttonStyle(.bordered).buttonBorderShape(.roundedRectangle(radius: 16)).controlSize(.large)
                            .accessibilityHint(Text("Puts this in the message field"))
                        }
                    }
                    .padding(.top, 28)
                    footer().padding(.top, 8)
                }
                .padding(.horizontal, 24).padding(.vertical, 16)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
        }
    }
}

extension View {
    /// The message field's place on the bottom edge: a safe-area bar on iOS 26 (the conversation fades
    /// under it, as under the system's bars), an inset before it.
    @ViewBuilder func bottomBar<Bar: View>(@ViewBuilder _ bar: () -> Bar) -> some View {
        if #available(iOS 26.0, *) {
            safeAreaBar(edge: .bottom, spacing: 0) { GlassEffectContainer(spacing: 8) { bar() } }
        } else {
            safeAreaInset(edge: .bottom, spacing: 0) { bar() }
        }
    }

    /// Marks the bear Poki's profile zooms out of: "poki" in the chat, "poki-threads" in the drawer.
    @ViewBuilder func profileSource(_ namespace: Namespace.ID?, id: String = "poki") -> some View {
        if let namespace { matchedTransitionSource(id: id, in: namespace) } else { self }
    }
}

/// A setup or account issue surfaced inline in the chat, with a direct link to the exact item.
struct SetupIssueHint: Equatable {
    enum Target: Equatable {
        case step(SetupStep)
        case model
        case setup
        /// Agents and Relay (Home only).
        case agents
    }
    var message: String
    var link: String
    var target: Target

    /// Runner or pairing failure from the launcher (#78 failure codes: `unreachable` "Can't Reach iPhone",
    /// `handshake`, `pairing`, `developer_mode`, `no_cryptexd`, `runner_blocked`, `runner`, `loopback`).
    @MainActor static func runnerIssue(model: AppModel) -> SetupIssueHint? {
        if let trouble = model.pairingTrouble {
            return SetupIssueHint(
                message: String(localized: "The phone no longer accepts Poki’s pairing (\(trouble)). Pair again in Setup; it takes a minute."),
                link: String(localized: "Pair This iPhone ›"),
                target: .step(.pairing)
            )
        }
        let runner = model.runner
        if runner.state == "failed" || model.servicesSilent {
            let code = runner.code ?? (model.servicesSilent ? "handshake" : nil)
            let headline = AppModel.problemText(code: code, fix: runner.fix ?? "Can’t Reach iPhone")
            let localizedHeadline = Bundle.main.localizedString(forKey: headline, value: headline, table: "LiveActivity")
            let rawFix = runner.fix ?? ""
            let detail = rawFix.isEmpty
                ? localizedHeadline
                : Bundle.main.localizedString(forKey: rawFix, value: rawFix, table: nil)
            let message = detail.contains(localizedHeadline) ? detail : "\(localizedHeadline): \(detail)"
            switch code {
            case "unreachable", "handshake", "loopback":
                return SetupIssueHint(
                    message: message,
                    link: String(localized: "Turn On Local Connection ›"),
                    target: .step(.loopback)
                )
            case "pairing":
                return SetupIssueHint(
                    message: message,
                    link: String(localized: "Pair This iPhone ›"),
                    target: .step(.pairing)
                )
            case "developer_mode", "no_cryptexd":
                return SetupIssueHint(
                    message: message,
                    link: String(localized: "Turn On Developer Mode ›"),
                    target: .step(.developerMode)
                )
            case "runner_blocked":
                return SetupIssueHint(
                    message: message,
                    link: String(localized: "Turn On UI Automation ›"),
                    target: .step(.automation)
                )
            case "runner":
                return SetupIssueHint(
                    message: message,
                    link: String(localized: "Install Poki Runner ›"),
                    target: .step(.runner)
                )
            default:
                return SetupIssueHint(
                    message: message,
                    link: String(localized: "Open Setup ›"),
                    target: .setup
                )
            }
        }
        return nil
    }

    /// `looks` counts a step as Home shows it (`AppModel.looksDone`), so the loopback's first check after
    /// launch doesn't flash a hint.
    @MainActor static func first(model: AppModel, looks: Bool = false) -> SetupIssueHint? {
        if let runnerHint = runnerIssue(model: model) {
            return runnerHint
        }
        let done: (SetupStep) -> Bool = looks ? model.looksDone : model.isDone
        if !SetupStep.shown.allSatisfy(done) {
            for step in SetupStep.shown where !done(step) {
                switch step {
                case .runner:
                    return SetupIssueHint(
                        message: String(localized: "Poki can’t act yet: Poki Runner isn’t installed."),
                        link: String(localized: "Install Poki Runner ›"),
                        target: .step(.runner)
                    )
                case .developerMode:
                    return SetupIssueHint(
                        message: String(localized: "Poki can’t act yet: Developer Mode is off."),
                        link: String(localized: "Turn On Developer Mode ›"),
                        target: .step(.developerMode)
                    )
                case .loopback:
                    return SetupIssueHint(
                        message: String(localized: "Poki can’t connect yet: Local Connection is off."),
                        link: String(localized: "Turn On Local Connection ›"),
                        target: .step(.loopback)
                    )
                case .pairing:
                    return SetupIssueHint(
                        message: String(localized: "Poki can’t act yet: this iPhone isn’t paired."),
                        link: String(localized: "Pair This iPhone ›"),
                        target: .step(.pairing)
                    )
                case .automation:
                    return SetupIssueHint(
                        message: String(localized: "Poki can’t tap Send yet: UI Automation is off."),
                        link: String(localized: "Turn On UI Automation ›"),
                        target: .step(.automation)
                    )
                case .background:
                    return SetupIssueHint(
                        message: String(localized: "Poki can’t stay on in the background yet."),
                        link: String(localized: "Turn On Background ›"),
                        target: .step(.background)
                    )
                }
            }
        }
        if !ModelKeys.hasUsableKey {
            return SetupIssueHint(
                message: String(localized: "Poki needs a model account before it can reply."),
                link: String(localized: "Add an Account ›"),
                target: .model
            )
        }
        return nil
    }
}

extension SetupIssueHint {
    /// Home's one line (ESP-321): what main's two tab dots said, one problem at a time. A runner or
    /// pairing failure, then an open setup step (Setup's dot), then no chat account, then the relay
    /// offline (the Agents dot). The chat doesn't show the relay: it needs no relay to reply.
    @MainActor static func home(model: AppModel) -> SetupIssueHint? {
        if let hint = first(model: model, looks: true) { return hint }
        if case .offline = model.relayStatus {
            return SetupIssueHint(
                message: String(localized: "MCP Relay is offline: agents can’t reach this iPhone."),
                link: String(localized: "Guests ›"),
                target: .agents
            )
        }
        return nil
    }
}

/// One grey line and a blue direct link under the bubbles (ESP-174 board "C1 Chat setup hint").
struct SetupHintLine: View {
    var hint: SetupIssueHint
    var openSetupStep: (SetupStep) -> Void
    var openSetup: () -> Void
    var openModel: () -> Void
    var openAgents: () -> Void = {}

    var body: some View {
        VStack(spacing: 2) {
            Text(verbatim: hint.message)
                .font(.footnote)
                .foregroundStyle(Color(.secondaryLabel))
                .multilineTextAlignment(.center)
            Button {
                switch hint.target {
                case .step(let step): openSetupStep(step)
                case .model: openModel()
                case .setup: openSetup()
                case .agents: openAgents()
                }
            } label: {
                Text(verbatim: hint.link)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Tint.blueText)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("chat.setupHintLink")
        }
        .padding(.horizontal, 24)
        .padding(.top, 6)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity)
    }
}

/// The bubbles of one conversation: an in-app chat, a hand-off from an outside agent, or an outside
/// agent's own steps (grey lines). Used by the chat and by a saved session.
struct ChatTranscript<Footer: View>: View {
    var entries: [ChatEntry]
    var typing = false
    var canRetry = false
    var retry: () -> Void = {}
    /// The run these entries belong to, for the details of its steps (the Activity Log's session).
    var session: String? = nil
    /// The conversation's task is under way: its last plan is the live task card.
    var live = false
    /// A step of it waits for your answer, or the phone is handed back to you.
    var waiting = false
    var handedOver = false
    /// The live task's whole plan, when the model published it, and the app it is in.
    var plan: [String]? = nil
    var app: String? = nil
    @ViewBuilder var footer: () -> Footer
    @State private var details: ChatRunDetails?

    var body: some View {
        ScrollView {
            VStack(spacing: 4) {
                Spacer(minLength: 0)
                ForEach(Array(entries.enumerated()), id: \.element.id) { i, entry in
                    row(entry, at: i).id(entry.id)
                }
                if typing {
                    HStack { TypingBubble(); Spacer(minLength: .messageInsetPadding) }
                        .padding(.top, 4).transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .bottomLeading)))
                }
                if canRetry {
                    Button("Try Again", systemImage: "arrow.clockwise", action: retry)
                        .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small).tint(Color(.label))
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4).padding(.bottom, 6)
                }
                footer()
            }
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 10)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
            .animation(PlanMotion.enter, value: entries)
            .animation(.easeOut(duration: 0.2), value: typing)
        }
        // Opens at the newest message, keeps a short chat at the bottom, and follows new lines (the
        // live voice transcript grows below the messages) while the content itself scrolls freely.
        // A frame fixed to the screen's height here cut off everything above it.
        .defaultScrollAnchor(.bottom)
        .defaultScrollAnchor(.bottom, for: .alignment)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .scrollDismissesKeyboard(.interactively)
        .sheet(item: $details) { run in RunDetailsView(title: run.title, steps: run.steps, actions: run.actions) }
    }

    /// The task entry `i` is part of: its steps, and the actions the Activity Log has between the
    /// message that asked for it and the next one.
    private func run(at i: Int) -> ChatRunDetails {
        func asks(_ entry: ChatEntry) -> Bool {
            switch entry.kind { case .you, .request: true; default: false }
        }
        let start = entries[...i].lastIndex(where: asks)
        let end = entries[(i + 1)...].firstIndex(where: asks)
        let from = start.map { entries[$0].at.addingTimeInterval(-1) } ?? entries[i].at.addingTimeInterval(-600)
        let to = end.map { entries[$0].at } ?? Date.distantFuture
        var steps: [PlanStep] = []
        var title = String(localized: "Task Details")
        for entry in entries[(start ?? i)..<(end ?? entries.count)] {
            switch entry.kind {
            case .plan(let plan): steps += plan
            case .step(let text, let ok): steps.append(PlanStep(text, state: ok == true ? .done : ok == false ? .failed : .current))
            case .you(let text, _): title = String(text.prefix(40))
            case .request(let text, _): title = String(text.prefix(40))
            default: break
            }
        }
        return ChatRunDetails(title: title, steps: steps, actions: ActionLog.shared.entries(session: session, from: from, to: to))
    }

    /// Touch and hold on a task's steps, a step line or an approval.
    @ViewBuilder private func menu(at i: Int) -> some View {
        Button("View Details", systemImage: "info.circle") { details = run(at: i) }
        Button("Copy Steps", systemImage: "doc.on.doc") {
            let run = run(at: i)
            UIPasteboard.general.string = RunDetailsView.text(title: run.title, steps: run.steps, actions: [])
        }
        Button("Copy Details", systemImage: "list.bullet.clipboard") { UIPasteboard.general.string = run(at: i).text }
        Button("Copy Diagnostic Log", systemImage: "doc.text") { UIPasteboard.general.string = AppLog.shared.text }
        ShareLink(item: run(at: i).text) { Label("Share", systemImage: "square.and.arrow.up") }
    }

    @ViewBuilder private func row(_ entry: ChatEntry, at i: Int) -> some View {
        switch entry.kind {
        case .time(let date):
            Text(ChatTime.header(date))
                .font(.caption).foregroundStyle(Color(.secondaryLabel))
                .padding(.bottom, 6).frame(maxWidth: .infinity)
        case .you(let text, let delivered):
            let last = isLast(i, poki: false)
            VStack(alignment: .trailing, spacing: 4) {
                MessageBubble(direction: .outgoing, text: text, tail: last)
                if last, delivered {
                    Text("Delivered").font(.caption2.weight(.medium)).foregroundStyle(Color(.secondaryLabel))
                        .padding(.horizontal, 4).padding(.bottom, 8)
                        .transition(.opacity)
                }
            }
            .padding(.top, startsRun(i) ? 10 : 0)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        case .request(let text, let from):
            // A guest's request: its name above, and the ink bubble that sets it apart from your grey one.
            VStack(alignment: .trailing, spacing: 3) {
                if startsRun(i) || i == 0 {
                    Text(verbatim: from).font(.caption2.weight(.medium)).foregroundStyle(Color(.secondaryLabel)).padding(.horizontal, 14)
                }
                MessageBubble(direction: .guest, text: text, tail: isLast(i, poki: false))
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.top, startsRun(i) ? 10 : 0)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        case .poki(let text):
            MessageBubble(direction: .incoming, text: text, tail: isLast(i, poki: true))
                .padding(.top, startsRun(i) ? 10 : 0)
                .transition(PlanMotion.stepTransition)
        case .plan(let steps):
            let ask = asking(at: i)
            let current = live && isLastPlan(i)
            TaskCard(title: ask.title, steps: steps,
                     state: TaskCardState(steps: steps, live: current, waiting: waiting, handedOver: handedOver),
                     upcoming: current ? Array((plan ?? []).dropFirst(steps.count)) : [],
                     asker: ask.from, app: current ? app : nil, started: entry.at)
                .contentShape(.contextMenuPreview, .rect(cornerRadius: 24, style: .continuous))
                .contextMenu { menu(at: i) }
                .padding(.vertical, 6)
                .transition(PlanMotion.stepTransition)
        case .note(.approval(let approval)):
            HStack {
                ApprovalNoteCard(note: approval)
                    .contentShape(.contextMenuPreview, .rect(cornerRadius: 16, style: .continuous))
                    .contextMenu { menu(at: i) }
                Spacer(minLength: .messageInsetPadding)
            }
            .padding(.vertical, 4)
            .transition(PlanMotion.stepTransition)
        case .note(let note):
            NoteLine(note: note)
        case .step(let text, let ok):
            StepLine(text: text, ok: ok).contextMenu { menu(at: i) }
        }
    }

    /// What was asked for the task entry `i` belongs to, and by which outside agent (nil when you asked).
    private func asking(at i: Int) -> (title: String, from: String?) {
        for entry in entries[...i].reversed() {
            switch entry.kind {
            case .you(let text, _): return (text, nil)
            case .request(let text, let from): return (text, from)
            default: continue
            }
        }
        return (String(localized: "Task"), nil)
    }

    /// No plan follows entry `i`: it is the task under way, if one is.
    private func isLastPlan(_ i: Int) -> Bool {
        !entries[(i + 1)...].contains { if case .plan = $0.kind { true } else { false } }
    }

    /// The last bubble from that side in the conversation has the small corner (the boards).
    private func isLast(_ i: Int, poki: Bool) -> Bool {
        !entries[(i + 1)...].contains { entry in
            switch entry.kind {
            case .poki, .plan: poki
            case .you, .request: !poki
            default: false
            }
        }
    }

    /// A bubble after the other side's (or the time) leaves 10 pt more.
    private func startsRun(_ i: Int) -> Bool {
        guard i > 0 else { return false }
        let mine = entries[i].isPoki
        for entry in entries[..<i].reversed() {
            switch entry.kind {
            case .note: continue
            case .time, .step: return true
            default: return entry.isPoki != mine
            }
        }
        return false
    }
}

extension ChatTranscript where Footer == EmptyView {
    init(entries: [ChatEntry]) { self.init(entries: entries, footer: { EmptyView() }) }
}

/// "Today 9:41 AM", "Yesterday 6:02 PM", "Monday 8:15 AM", "Oct 3, 8:15 AM", as Messages writes them.
enum ChatTime {
    static func header(_ date: Date) -> AttributedString {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        let day: String
        if calendar.isDateInToday(date) { day = String(localized: "Today") }
        else if calendar.isDateInYesterday(date) { day = String(localized: "Yesterday") }
        else if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: Date())).day, days < 7 {
            day = date.formatted(.dateTime.weekday(.wide))
        } else {
            day = date.formatted(.dateTime.month(.abbreviated).day())
        }
        var bold = AttributedString(day)
        bold.font = .caption.weight(.semibold)
        return bold + AttributedString(" \(time)")
    }

    /// The Sessions list's right-hand time: "9:41 AM", "Yesterday", "Monday", "10/3/26".
    static func row(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if calendar.isDateInYesterday(date) { return String(localized: "Yesterday") }
        if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: Date())).day, days < 7 {
            return date.formatted(.dateTime.weekday(.wide))
        }
        return date.formatted(date: .numeric, time: .omitted)
    }
}

/// Three dots that rise in turn: the model is working on its answer.
struct TypingBubble: View {
    /// Dot i's height in 0...1 at time t. Typed step by step: as one expression inside the view
    /// builder it can exceed the type checker's time limit on a busy CI runner.
    static func phase(_ t: Double, _ i: Int) -> Double {
        let angle: Double = t * 2 * Double.pi / 1.2 - Double(i) * 0.9
        let wave: Double = sin(angle)
        return (wave + 1) / 2
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<3) { i in
                    let phase = TypingBubble.phase(t, i)
                    Circle().fill(ChatColor.secondary.opacity(0.45 + 0.45 * phase)).frame(width: 8, height: 8).offset(y: -3 * phase)
                }
            }
            .padding(.vertical, 10).padding(.horizontal, 2)
        }
        .accessibilityLabel(Text("Poki is typing"))
    }
}

/// The mark in front of a status line. Steps, approvals and the plan all draw the same tick and cross.
enum StatusGlyph: Equatable {
    case ok, failed, working, warning, island, none

    @ViewBuilder var view: some View {
        switch self {
        case .ok: Image(systemName: "checkmark").font(.caption2.weight(.bold)).foregroundStyle(Tint.green)
        case .failed: Image(systemName: "xmark").font(.caption2.weight(.bold)).foregroundStyle(Tint.red)
        case .working: ProgressView().controlSize(.mini)
        case .warning: Image(systemName: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(Tint.amber)
        // The Dynamic Island, small.
        case .island: Capsule().fill(Color(hex: 0x1C1C1E)).frame(width: 22, height: 8)
        case .none: EmptyView()
        }
    }
}

/// One status line of the conversation: a mark and grey words that wrap, on the bubbles' leading edge.
/// A notice (an approval or a problem) sits on a grey card; a step is bare, so a run of them reads as a list.
struct StatusLine: View {
    var glyph: StatusGlyph
    var text: String
    var card = false

    var body: some View {
        HStack(spacing: 0) {
            HStack(alignment: .center, spacing: 6) {
                if glyph != .none { glyph.view.frame(minWidth: 14) }
                Text(text).fixedSize(horizontal: false, vertical: true)
            }
            .font(.footnote).foregroundStyle(Color(.secondaryLabel))
            .multilineTextAlignment(.leading)
            .padding(.vertical, card ? 8 : 2).padding(.horizontal, card ? 12 : 2)
            .background { if card { RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(.secondarySystemBackground)) } }
            Spacer(minLength: card ? .messageInsetPadding : 16)
        }
        .padding(.vertical, card ? 4 : 0)
        .accessibilityElement(children: .combine)
        .transition(.opacity)
    }
}

/// An outside agent's own step: one grey line, ticked when it went through.
private struct StepLine: View {
    var text: String
    var ok: Bool?
    var body: some View {
        StatusLine(glyph: ok == true ? .ok : ok == false ? .failed : .working, text: text)
    }
}

// MARK: Header

// MessageListHeader is from GetStream/swiftui-iMessage-clone (commit df114b4,
// iMessageClone/MessageList/View/Header/MessageListHeader.swift, by Stefan Blos; the repository has no
// licence file). Changed: Poki's picture at the board's 56 pt instead of 20, the 12 pt name with its
// chevron, no video button, and a view of its own instead of a toolbar item.
struct MessageListHeader: View {
    var dark: Bool
    /// The model answering, under the name (the chat); nil on the voice page.
    var subtitle: String? = nil
    var title: String = "Poki"
    var back: (() -> Void)? = nil
    var openDetails: () -> Void

    var body: some View {
        Button(action: openDetails) {
            VStack(spacing: 4) {
                PokiAvatar(size: 56)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(verbatim: title)
                        .font(.system(size: 12))
                        .foregroundStyle(dark ? Color.white : Color(.label))
                    Image(systemName: "chevron.right")
                        .resizable()
                        .scaledToFit()
                        .fontWeight(.semibold)
                        .frame(width: 5, height: 8)
                        .foregroundStyle(dark ? Color.white.opacity(0.7) : ChatColor.secondary)
                }
                if let subtitle, !subtitle.isEmpty {
                    Text(verbatim: subtitle).font(.system(size: 11)).foregroundStyle(ChatColor.secondary).lineLimit(1)
                }
            }
            .padding(.top, 2).padding(.bottom, 8)
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("\(title), details"))
        .accessibilityIdentifier("chat.header.details")
        .overlay(alignment: .topLeading) {
            if let back, UserDefaults.standard.string(forKey: "pokiChat") == nil, UserDefaults.standard.string(forKey: "pokiVoiceSample") == nil {
                Button(action: back) {
                    Image(systemName: "chevron.left").font(.system(size: 20, weight: .semibold)).foregroundStyle(dark ? .white : Site.blue)
                        .frame(width: 44, height: 44).contentShape(.rect)
                }
                .buttonStyle(.plain).padding(.leading, 6)
                .accessibilityLabel(Text("Sessions"))
            }
        }
        .background {
            if !dark {
                Rectangle().fill(.bar).ignoresSafeArea(edges: .top)
                    .overlay(alignment: .bottom) { Color(hex: 0xC6C6C8).opacity(0.75).frame(height: 0.75) }
            }
        }
    }
}

// MARK: Notes

/// A notice about an approval or a problem, on a grey card under the steps.
private struct NoteLine: View {
    var note: ChatNote
    var body: some View {
        StatusLine(glyph: glyph, text: text, card: true)
    }

    private var glyph: StatusGlyph {
        switch note {
        case .waiting: .island
        case .approved, .modelApproved: .ok
        case .approval(let note): note.state == .allowed ? StatusGlyph.ok : note.state == .asking ? StatusGlyph.working : StatusGlyph.failed
        case .declined, .modelDeclined: .failed
        case .expired, .problem: .warning
        case .modelChecking: .working
        }
    }

    private var text: String {
        switch note {
        case .waiting: String(localized: "Waiting for your approval")
        case .approved(let at): String(localized: "Approved, \(at.formatted(date: .omitted, time: .shortened))")
        case .declined: String(localized: "Not approved, so Poki skipped that step")
        case .expired: String(localized: "The approval ran out, so Poki skipped that step")
        case .problem(let text): text
        case .approval(let note): note.summary
        case .modelChecking: String(localized: "The model is checking this step")
        case .modelApproved(let why): why.isEmpty ? String(localized: "Approved by model") : String(localized: "Approved by model: \(why)")
        case .modelDeclined(let why):
            why.isEmpty ? String(localized: "Not approved by model. Say yes in the chat to let it through.")
                : String(localized: "Not approved by model: \(why). Say yes in the chat to let it through.")
        }
    }
}

/// What View Details shows for one task of a chat.
struct ChatRunDetails: Identifiable {
    let id = UUID()
    var title: String
    var steps: [PlanStep]
    var actions: [ActionLog.Entry]
    var text: String { RunDetailsView.text(title: title, steps: steps, actions: actions) }
}

/// An approval in the conversation: what was asked, why it needed an answer, and who answered what.
struct ApprovalNoteCard: View {
    var note: ApprovalNote

    private var title: String {
        switch (note.state, note.byModel) {
        case (.asking, true): String(localized: "Checking This Step")
        case (.asking, false): String(localized: "Waiting for Your Approval")
        case (.allowed, true): String(localized: "Approved Automatically")
        case (.allowed, false): String(localized: "You Approved")
        case (.refused, true): String(localized: "Not Approved")
        case (.refused, false): String(localized: "You Did Not Approve")
        case (.expired, _): String(localized: "Approval Ran Out")
        }
    }

    private var symbol: String {
        switch note.state {
        case .asking: "shield.lefthalf.filled"
        case .allowed: "checkmark.shield.fill"
        case .refused: "xmark.shield.fill"
        case .expired: "exclamationmark.shield.fill"
        }
    }

    private var tint: Color {
        switch note.state {
        case .asking: note.byModel ? Tint.blueText : Tint.amberInk
        case .allowed: Tint.greenInk
        case .refused: Tint.redInk
        case .expired: Tint.amberInk
        }
    }

    /// "Messages · sending a message": the app and PokiCore's reason, without its quoted word.
    private var context: String {
        let why = note.why.split(separator: "(").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let app = note.app.isEmpty || note.app == "unknown" || note.app.contains("(") ? nil : note.app
        return [app, why.isEmpty ? nil : why].compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.subheadline.weight(.semibold)).foregroundStyle(tint)
                Text(verbatim: title).font(.footnote.weight(.semibold)).foregroundStyle(tint)
                Spacer(minLength: 4)
                if note.state == .asking, note.byModel {
                    ProgressView().controlSize(.mini)
                } else if let at = note.answered {
                    Text(at.formatted(date: .omitted, time: .shortened)).font(.caption2).foregroundStyle(Color(.secondaryLabel))
                }
            }
            Text(verbatim: note.summary).font(.subheadline).foregroundStyle(Color(.label))
                .fixedSize(horizontal: false, vertical: true)
            if !context.isEmpty {
                Text(verbatim: context).font(.caption).foregroundStyle(Color(.secondaryLabel))
            }
            if !note.reason.isEmpty {
                Text(verbatim: note.reason).font(.footnote).foregroundStyle(Color(.secondaryLabel))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if note.state == .refused, note.reply {
                Text("Say yes in the chat to let it through.").font(.caption).foregroundStyle(Color(.secondaryLabel))
            }
        }
        .padding(.vertical, 10).padding(.horizontal, 12)
        .frame(maxWidth: 300, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 16, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color(.separator), lineWidth: 0.5) }
        .accessibilityElement(children: .combine)
    }
}

// MARK: Chat and Voice

enum RootPage: Hashable { case chat, voice }

/// CHAT and VOICE under the page, like Photo and Video in Camera: the page's own word sits in the middle.
struct ModeLabels: View {
    var page: RootPage
    var dark: Bool
    var select: ((RootPage) -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 22) {
                label("CHAT", .chat)
                label("VOICE", .voice)
            }
            // The board's 66 and 62 pt: the page's word in the middle.
            .padding(.leading, page == .chat ? 66 : 0).padding(.trailing, page == .voice ? 62 : 0)
            .padding(.top, 6).padding(.bottom, 4)
        }
        .frame(maxWidth: .infinity)
    }

    private func label(_ title: LocalizedStringKey, _ target: RootPage) -> some View {
        Button { select?(target) } label: {
            Text(title).font(.system(size: 13, weight: .semibold)).tracking(13 * 0.06)
                .foregroundStyle(color(target))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(page == target ? .isSelected : [])
    }

    private func color(_ target: RootPage) -> Color {
        if dark { return page == target ? .white : .white.opacity(0.55) }
        return page == target ? Site.blue : ChatColor.secondary
    }
}

// MARK: Composer

// ComposerInputView started from GetStream/swiftui-iMessage-clone (commit df114b4,
// iMessageClone/MessageList/View/Composer/ComposerInputView.swift, by Stefan Blos; no licence file in
// the repository), with the plus button in front from exyte/Chat (commit f382a14,
// Sources/ExyteChat/Views/InputView/InputView.swift, Copyright (c) 2019 exyte, MIT License). Now two
// layers on one sheet of glass (ESP-326 board "01 Chat: Greeting"): the message on top with dictation
// at its end; below it the plus menu, the model, the Hands switch, and one button that talks, sends or
// stops.
struct ComposerInputView: View {
    @Environment(AppModel.self) private var model
    /// The message being written; the greeting's suggestions fill it.
    @Binding var input: String
    var running: Bool
    /// How far the running task is, 0 to 1, for the ring around Stop; nil when unknown.
    var progress: Double? = nil
    /// A screenshot's sample scene: Hands reads on, whatever the simulator's state.
    var sample = false
    var send: (String) -> Void
    var stop: () -> Void
    /// Starts the live voice conversation.
    var openVoice: () -> Void
    var openModel: () -> Void
    var openDetails: () -> Void = {}
    var newConversation: () -> Void
    @State private var dictation = FieldDictation()
    @FocusState private var focused: Bool
    @State private var sent: (text: String, at: Date)?
    /// Bumped when the chosen model changes, so the chip redraws (ModelKeys is not observable).
    @State private var modelVersion = 0
    @State private var sends = 0
    /// The least room the model's name is worth showing in (about ten letters and the menu arrow).
    @ScaledMetric(relativeTo: .footnote) private var shortName: CGFloat = 104

    private var voice: VoiceModel { model.voice }
    private var hasText: Bool { !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(spacing: 4) {
            if let problem = dictation.problem, !dictation.on {
                Text(problem).font(.footnote).foregroundStyle(Tint.red)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16)
            }
            VStack(spacing: 8) {
                HStack(alignment: .bottom, spacing: 4) {
                    TextField(text: $input, prompt: Text(dictation.on ? "Listening…" : "Message Poki"), axis: .vertical) { Text("Message Poki") }
                        .font(.body)
                        .focused($focused)
                        .multilineTextAlignment(.leading)
                        .lineLimit(1...6)
                        .padding(.vertical, 6)
                        .submitLabel(.send)
                        .onSubmit(submit)
                    if !hasText || dictation.on { dictate }
                }
                .padding(.leading, 8)
                // What gives when the row is too narrow (a long model name, a small phone, large text):
                // Hands drops its picture; then the model's name is cut short, as a pop-up button's title
                // is; and where even a short name has no room (the largest text), Hands keeps its picture alone.
                ViewThatFits(in: .horizontal) {
                    controls(.full)
                    controls(.words)
                    controls(.shortName)
                    controls(.picture)
                }
                // Controls in a bar stop growing where the system's bars do; the message above grows freely.
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            }
            .padding(.top, 8).padding(.horizontal, 10).padding(.bottom, 10)
            .contentShape(.rect)
            .onTapGesture { focused = true }
            .composerGlass(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        }
        .animation(.snappy, value: dictation.on)
        .animation(.snappy, value: running)
        .onChange(of: dictation.text) { _, text in if dictation.on { input = dictation.base + text } }
        // A keyboard that was still composing (autocorrect, Pinyin) can commit its text after Send has
        // emptied the field, which put the sent message back: for a moment after Send, that is undone.
        .onChange(of: input) { _, text in
            if let sent, text == sent.text, Date().timeIntervalSince(sent.at) < 1 { input = "" }
        }
        .onReceive(NotificationCenter.default.publisher(for: ModelKeys.changed)) { _ in modelVersion += 1 }
        .onDisappear { dictation.stop(model) }
        .sensoryFeedback(.impact(weight: .light), trigger: sends)
    }

    // MARK: Top layer

    /// Dictation: the words appear in the field; nothing is sent until you tap Send.
    private var dictate: some View {
        Button { dictation.on ? dictation.stop(model) : dictation.start(model, after: input) } label: {
            Image(systemName: "mic.fill")
                .font(.body.weight(.medium))
                .foregroundStyle(dictation.on ? Tint.red : Color(.secondaryLabel))
                .symbolEffect(.pulse, isActive: dictation.on)
                .frame(width: 36, height: 36).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(voice.isOn)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityLabel(Text(dictation.on ? "Stop Dictation" : "Dictate"))
    }

    // MARK: Bottom layer

    /// What the row shows of Hands and of the model's name.
    private enum Fit { case full, words, shortName, picture }

    private func controls(_ fit: Fit) -> some View {
        HStack(spacing: 8) {
            plus
            // The name takes what the row has left. `shortName` asks for no more than a short name's
            // width, so it is the row chosen while a long name can still show most of itself.
            modelChip.frame(idealWidth: fit == .shortName ? shortName : nil).layoutPriority(1)
            if !running { hands(fit == .full ? .full : fit == .picture ? .picture : .words).fixedSize().layoutPriority(1) }
            Spacer(minLength: 0)
            mainButton
        }
    }

    private var plus: some View {
        Menu {
            Button("New Conversation", systemImage: "square.and.pencil", action: newConversation).disabled(running)
            Button("Accounts and Models", systemImage: "person.crop.circle", action: openModel)
            Button("Poki Details", systemImage: "gearshape", action: openDetails)
        } label: {
            Image(systemName: "plus")
                .font(.body.weight(.medium)).foregroundStyle(Color(.label))
                .frame(width: 34, height: 34)
                .background(Color(.tertiarySystemFill), in: .circle)
        }
        .accessibilityLabel(Text("More"))
    }

    /// The model that answers, and the menu that changes it: the chat models of every account that is
    /// set up, the voice model, and the way to the Brain page. With no account yet it is a plain
    /// button straight to adding one.
    @ViewBuilder private var modelChip: some View {
        // A screenshot's sample scene shows the chip as it reads with an account, whatever the simulator has.
        if ModelKeys.hasUsableKey || sample {
            Menu {
                ForEach(ModelProvider.allCases.filter { ModelAccounts.isSetUp($0) && ModelAccounts.canChat($0) }) { provider in
                    Section(provider.name) {
                        ForEach(ModelCatalog.available(provider)) { choice in
                            Button {
                                ModelKeys.selectedProvider = provider
                                ModelKeys.selectedModel = choice.id
                                ModelKeys.saved += 1
                            } label: {
                                if ModelKeys.selectedProvider == provider && ModelKeys.selectedModel == choice.id { Label(choice.name, systemImage: "checkmark") } else { Text(choice.name) }
                            }
                        }
                    }
                }
                if VoiceDirect.apiKey != nil {
                    Menu("Voice Model: \(VoiceDirect.model)", systemImage: "waveform") {
                        ForEach(ModelCatalog.voiceAvailable) { choice in
                            Button { ModelCatalog.voiceModel = choice.id; modelVersion += 1 } label: {
                                if VoiceDirect.model == choice.id { Label(choice.name, systemImage: "checkmark") } else { Text(choice.name) }
                            }
                        }
                    }
                }
                Button("Accounts and Models", systemImage: "person.crop.circle", action: openModel)
            } label: {
                chip(Text(verbatim: ModelKeys.selectedModelName), symbol: "chevron.down")
            }
            .accessibilityLabel(Text("Chat Model: \(ModelKeys.selectedModelName)"))
        } else {
            Button(action: openModel) { chip(Text("Add Model"), symbol: "plus") }
                .buttonStyle(.plain)
                .accessibilityIdentifier("composer.addModel")
        }
    }

    private func chip(_ title: Text, symbol: String) -> some View {
        HStack(spacing: 4) {
            // A name a little too long shrinks before it is cut short (the smallest is caption-sized).
            title.lineLimit(1).minimumScaleFactor(0.85)
            Image(systemName: symbol).font(.caption2.weight(.bold)).foregroundStyle(Color(.secondaryLabel))
        }
        .font(.footnote.weight(.medium)).foregroundStyle(Color(.label))
        .padding(.horizontal, 10).frame(height: 34)
        .background(Color(.tertiarySystemFill), in: .capsule)
        .contentShape(.capsule)
        .id(modelVersion)
    }

    /// Poki's hands: on, resting (you paused it; it starts again when you or an agent asks), or off.
    private enum Hands { case on, resting, off }

    private var handsNow: Hands {
        // A screenshot's sample scene shows the switch as that scene has it, whatever the simulator runs.
        if sample { return UserDefaults.standard.string(forKey: "pokiChat") == "paused" ? .resting : .on }
        if !model.sessionOn { return .off }
        return model.ownerPaused ? .resting : .on
    }

    private func hands(_ shows: ChipToggleStyle.Shows) -> some View {
        let state = handsNow
        let value = switch state {
        case .on: String(localized: "On")
        case .resting: String(localized: "Resting")
        case .off: String(localized: "Off")
        }
        return Toggle(isOn: Binding(get: { state == .on }, set: setHands)) {
            switch state {
            case .on: Label("Hands On", systemImage: "hand.tap.fill")
            case .resting: Label("Resting", systemImage: "moon.zzz.fill")
            case .off: Label("Off", systemImage: "power")
            }
        }
        .toggleStyle(ChipToggleStyle(shows: shows, valueText: value))
        .sensoryFeedback(.selection, trigger: state == .on)
        .accessibilityIdentifier("composer.hands")
    }

    private func setHands(_ on: Bool) {
        guard !sample else { return }
        if !on {
            stop()
            model.pauseByOwner()
        } else if model.sessionOn {
            model.wakeRunner()
        } else {
            model.startSession()
        }
    }

    /// One button: talk when the field is empty, send when it has words, stop while a task runs.
    private var mainButton: some View {
        Button {
            if running { stop() } else if hasText { submit() } else { openVoice() }
        } label: {
            Image(systemName: running ? "stop.fill" : hasText ? "arrow.up" : "waveform")
                .font(.body.weight(.semibold))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(Tint.onSolid)
                .frame(width: 36, height: 36)
                .background(Tint.solid, in: .circle)
                .overlay {
                    if running {
                        // How far the task is; a short arc from the start, so it reads as a ring.
                        Circle().trim(from: 0, to: max(0.06, min(progress ?? 0.06, 1)))
                            .stroke(Tint.blue, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90)).padding(-4)
                            .animation(.easeInOut(duration: 0.4), value: progress)
                    }
                }
                .padding(.leading, 6)
                .frame(minWidth: 44, minHeight: 44).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(running ? "Stop" : hasText ? "Send" : "Talk to Poki"))
        .accessibilityIdentifier("composer.main")
    }

    private func submit() {
        guard !running, hasText else { return }
        dictation.cancel(model)
        let text = input
        send(text)
        sends += 1
        sent = (text, Date())
        input = ""
        // Once more after the keyboard has settled, for a commit that arrives in pieces.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            if input == text { input = "" }
        }
    }
}

/// A switch drawn as a chip: Poki's soft blue while on, grey while off. VoiceOver meets a plain switch.
private struct ChipToggleStyle: ToggleStyle {
    /// How much of the label the row has room for.
    enum Shows { case full, words, picture }
    var shows = Shows.full
    /// What VoiceOver reads as the switch's value.
    var valueText: String

    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            Group {
                switch shows {
                case .full: configuration.label.labelStyle(.titleAndIcon)
                case .words: configuration.label.labelStyle(.titleOnly)
                case .picture: configuration.label.labelStyle(.iconOnly)
                }
            }
            .font(.footnote.weight(.medium)).lineLimit(1)
            .foregroundStyle(configuration.isOn ? Tint.blueText : Color(.secondaryLabel))
            .padding(.horizontal, shows == .picture ? 0 : 10).frame(minWidth: 34).frame(height: 34)
            .background(configuration.isOn ? Tint.blueSoft : Color(.tertiarySystemFill), in: .capsule)
        }
        .buttonStyle(.plain)
        // VoiceOver meets a switch named Hands; what the chip says ("Hands On", "Resting", "Off") is its value.
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { Text("Hands") }.accessibilityValue(Text(verbatim: valueText))
        }
    }
}

/// Dictation into the message field (Apple's speech recognition, on the device when it can), separate
/// from the live conversation: it only writes words, it never sends them.
@MainActor
@Observable
final class FieldDictation {
    private(set) var on = false
    private(set) var text = ""
    private(set) var base = ""
    private(set) var problem: String?
    private var engine: Dictation?
    /// Between the tap and the microphone being on (the permission question can sit in between).
    private var starting = false

    func start(_ model: AppModel, after current: String) {
        guard !on, !starting else { return }
        starting = true
        problem = nil
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        base = trimmed.isEmpty ? "" : trimmed + " "
        text = ""
        Task {
            guard await Dictation.allowed() else {
                starting = false
                problem = String(localized: "Poki needs the microphone and speech recognition: allow them in Settings › Poki.")
                return
            }
            guard starting else { return }
            starting = false
            let engine = Dictation()
            engine.onHeard = { [weak self] heard in self?.text = heard }
            engine.onFailed = { [weak self, weak model] why in
                guard let self else { return }
                if let model { self.stop(model) }
                self.problem = why
            }
            model.background.pauseAudio()
            do {
                try engine.listen()
                self.engine = engine
                on = true
            } catch {
                model.background.resumeAudio()
                problem = error.localizedDescription
            }
        }
    }

    /// Send was tapped: dictation ends, also one that was still asking for the microphone.
    func cancel(_ model: AppModel) {
        starting = false
        stop(model)
    }

    func stop(_ model: AppModel) {
        guard on, let engine else { return }
        on = false
        self.engine = nil
        Task {
            _ = await engine.finish()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            model.background.resumeAudio()
        }
    }
}

// MARK: Live voice

/// Under the header while a live conversation is on: whether Poki is listening, hearing you, working or
/// speaking, and the buttons to quiet it or end it.
struct LiveVoiceBar: View {
    var voice: VoiceModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                .symbolEffect(.variableColor.iterative, isActive: voice.phase == .hearing || voice.phase == .speaking)
                .frame(width: 30, height: 30).background(tint, in: .circle)
            VStack(alignment: .leading, spacing: 1) {
                Text(voice.isLive ? "Live Voice" : "Voice, turn by turn").font(.system(size: 15, weight: .semibold))
                Text(detail).font(.system(size: 13)).foregroundStyle(ChatColor.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if voice.phase == .speaking {
                Button { voice.stopTalking() } label: { Image(systemName: "speaker.slash.fill") }
                    .buttonStyle(.bordered).buttonBorderShape(.circle).accessibilityLabel(Text("Stop Talking"))
            }
            Button("End", role: .destructive) { voice.stop() }
                .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).tint(Color(.systemRed)).controlSize(.small)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .composerGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 4)
    }

    private var symbol: String {
        switch voice.phase {
        case .hearing: "waveform"
        case .thinking: "ellipsis"
        case .speaking: "speaker.wave.2.fill"
        case .connecting: "antenna.radiowaves.left.and.right"
        case .lost: "exclamationmark"
        default: "mic.fill"
        }
    }

    private var tint: Color {
        switch voice.phase {
        case .hearing: Color(.systemRed)
        case .lost: Color(.systemOrange)
        default: Site.blue
        }
    }

    private var detail: String {
        switch voice.phase {
        case .connecting: String(localized: "Connecting…")
        case .listening: voice.isLive ? String(localized: "Listening. Just talk; Poki answers when you pause.") : String(localized: "Ready")
        case .hearing: String(localized: "Hearing you…")
        case .thinking: String(localized: "Working on it…")
        case .speaking: String(localized: "Speaking")
        case .off: String(localized: "Off")
        case .lost(let why): why
        }
    }
}

/// What was said in the live conversation, as bubbles under the chat: your words (grey while Poki is
/// still hearing them), Poki's answers, and its steps as grey lines.
struct LiveVoiceTranscript: View {
    var voice: VoiceModel

    var body: some View {
        if voice.isOn || !voice.lines.isEmpty {
            let lines = voice.lines
            VStack(spacing: 4) {
                if !lines.isEmpty {
                    Label("Voice conversation", systemImage: "waveform")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(ChatColor.secondary)
                        .padding(.top, 12).padding(.bottom, 4).frame(maxWidth: .infinity)
                }
                ForEach(Array(lines.enumerated()), id: \.element.id) { i, line in
                    let pending = i == lines.count - 1 && line.role == .you && voice.phase == .hearing
                    switch line.role {
                    case .you:
                        MessageBubble(direction: .outgoing, text: line.text, tail: true).opacity(pending ? 0.55 : 1)
                    case .poki:
                        MessageBubble(direction: .incoming, text: line.text, tail: true)
                    case .tool, .note:
                        StatusLine(glyph: .none, text: line.text)
                    }
                }
                if voice.phase == .hearing, lines.last?.role != .you {
                    MessageBubble(direction: .outgoing, text: String(localized: "Listening…"), tail: true).opacity(0.55)
                }
            }
            .animation(PlanMotion.enter, value: voice.lines)
        }
    }
}

extension View {
    /// Liquid Glass on iOS 26 and later; the bar material with a hairline edge before it.
    @ViewBuilder func composerGlass<S: Shape>(in shape: S) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: shape)
        } else {
            self.background(.bar, in: shape).overlay(shape.stroke(ChatColor.fieldEdge, lineWidth: 0.5))
        }
    }
}
