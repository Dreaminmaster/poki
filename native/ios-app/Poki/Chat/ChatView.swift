import AVFoundation
import SwiftUI

/// The chat page (ESP-171 boards "M Chat empty", "M Chat working", "M Chat approved", and ESP-174 boards
/// "P1 Chat approval in app", "C1 Chat setup hint"): Poki's picture and name on top, the bubbles, and the
/// message field. Approvals happen in the Dynamic Island, which iOS hides while Poki is in front, so the
/// chat also shows the waiting approval's card.
struct ChatView: View {
    @Environment(AppModel.self) private var model
    @Environment(ChatModel.self) private var chat
    var openDetails: () -> Void
    var openVoice: () -> Void
    var openSetup: () -> Void
    var openSetupStep: (SetupStep) -> Void = { _ in }
    var openModel: () -> Void
    var selectMode: ((RootPage) -> Void)? = nil
    /// Back to the Sessions list, when the chat was opened from it.
    var back: (() -> Void)? = nil

    private var voice: VoiceModel { model.voice }
    @State private var renaming = false
    @State private var newName = ""

    private var sampleScene: String? { UserDefaults.standard.string(forKey: "pokiChat") }

    var body: some View {
        VStack(spacing: 0) {
            MessageListHeader(dark: false, title: SessionStore.shared.session(chat.sessionID)?.name ?? "Poki", back: back, openDetails: openDetails)
            if voice.isOn {
                LiveVoiceBar(voice: voice).transition(.move(edge: .top).combined(with: .opacity))
            }
            ChatTranscript(entries: chat.entries, typing: chat.awaitingModel, canRetry: chat.canRetry, retry: chat.retry) {
                if let hint = currentSetupHint {
                    SetupHintLine(hint: hint, openSetupStep: openSetupStep, openSetup: openSetup, openModel: openModel)
                }
                if sampleScene == "approval" {
                    ForegroundApprovalSection(
                        title: String(localized: "Send “On my way” to Mom?"),
                        subtitle: String(localized: "Messages · Poki taps Send only if you allow"),
                        answer: { _ in }
                    )
                } else if !ApprovalClassifier.isOn, let approval = model.approvals.first {
                    ForegroundApprovalSection(
                        title: approval.summary,
                        subtitle: model.currentApp.map { String(localized: "\($0) · Poki acts only if you allow") } ?? String(localized: "Poki acts only if you allow"),
                        answer: { approved in model.resolve(approval, approved: approved) }
                    )
                }
                LiveVoiceTranscript(voice: voice)
            }
            ComposerInputView(running: chat.running, send: chat.send, stop: chat.stop, openVoice: openVoice, openModel: openModel,
                              openDetails: openDetails, newConversation: chat.newConversation)
            ModeLabels(page: .chat, dark: false, select: selectMode ?? { if $0 == .voice { openVoice() } })
        }
        .animation(.snappy, value: voice.isOn)
        .background(Color(.systemBackground))
        .toolbar(.hidden, for: .navigationBar)
        .alert("Rename Conversation", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Save") { SessionStore.shared.rename(chat.sessionID, to: newName) }
        }
    }

    /// When a setup step or model account keeps Poki from acting, the chat shows one grey line and a
    /// blue link straight to that item (ESP-174 board "C1 Chat setup hint").
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

/// A setup or account issue surfaced inline in the chat, with a direct link to the exact item.
struct SetupIssueHint: Equatable {
    enum Target: Equatable {
        case step(SetupStep)
        case model
        case setup
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

    @MainActor static func first(model: AppModel) -> SetupIssueHint? {
        if let runnerHint = runnerIssue(model: model) {
            return runnerHint
        }
        if !model.setupComplete {
            for step in SetupStep.shown where !model.isDone(step) {
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

/// One grey line and a blue direct link under the bubbles (ESP-174 board "C1 Chat setup hint").
struct SetupHintLine: View {
    var hint: SetupIssueHint
    var openSetupStep: (SetupStep) -> Void
    var openSetup: () -> Void
    var openModel: () -> Void

    var body: some View {
        VStack(spacing: 2) {
            Text(verbatim: hint.message)
                .font(.system(size: 12))
                .foregroundStyle(ChatColor.secondary)
                .multilineTextAlignment(.center)
            Button {
                switch hint.target {
                case .step(let step): openSetupStep(step)
                case .model: openModel()
                case .setup: openSetup()
                }
            } label: {
                Text(verbatim: hint.link)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Site.blue)
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

/// The note line and card shown when Poki is in the foreground and an action needs approval (ESP-174 board "P1 Chat approval in app").
struct ForegroundApprovalSection: View {
    var title: String
    var subtitle: String
    var answer: (Bool) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Capsule().fill(Color(hex: 0x1C1C1E)).frame(width: 22, height: 8)
                Text("Poki is open, so it asks here instead")
                    .font(.system(size: 12))
                    .foregroundStyle(ChatColor.secondary)
            }
            .padding(.top, 12)
            .padding(.bottom, 2)
            .frame(maxWidth: .infinity)

            ApprovalCard(title: title, subtitle: subtitle, answer: answer)
        }
    }
}

/// The bubbles of one conversation: an in-app chat, a hand-off from an outside agent, or an outside
/// agent's own steps (grey lines). Used by the chat and by a saved session.
struct ChatTranscript<Footer: View>: View {
    var entries: [ChatEntry]
    var typing = false
    var canRetry = false
    var retry: () -> Void = {}
    @ViewBuilder var footer: () -> Footer

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
                    Button(action: retry) { Label("Try Again", systemImage: "arrow.clockwise").font(.system(size: 13, weight: .semibold)) }
                        .buttonStyle(.bordered).buttonBorderShape(.capsule).tint(Site.blue).padding(.top, 2).padding(.bottom, 6)
                }
                footer()
            }
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 10)
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
    }

    @ViewBuilder private func row(_ entry: ChatEntry, at i: Int) -> some View {
        switch entry.kind {
        case .time(let date):
            Text(ChatTime.header(date))
                .font(.system(size: 12)).foregroundStyle(ChatColor.secondary)
                .padding(.bottom, 6).frame(maxWidth: .infinity)
        case .you(let text, let delivered):
            let last = isLast(i, poki: false)
            VStack(alignment: .trailing, spacing: 4) {
                MessageBubble(direction: .outgoing, text: text, tail: last)
                if last, delivered {
                    Text("Delivered").font(.system(size: 11, weight: .medium)).foregroundStyle(ChatColor.secondary)
                        .padding(.horizontal, 4).padding(.bottom, 8)
                        .transition(.opacity)
                }
            }
            .padding(.top, startsRun(i) ? 10 : 0)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        case .request(let text, let from):
            VStack(alignment: .trailing, spacing: 2) {
                if startsRun(i) || i == 0 {
                    Text(verbatim: from).font(.system(size: 11, weight: .medium)).foregroundStyle(ChatColor.secondary).padding(.horizontal, 14)
                }
                MessageBubble(direction: .outgoing, text: text, tail: isLast(i, poki: false))
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.top, startsRun(i) ? 10 : 0)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        case .poki(let text):
            MessageBubble(direction: .incoming, text: text, tail: isLast(i, poki: true))
                .padding(.top, startsRun(i) ? 10 : 0)
                .transition(PlanMotion.stepTransition)
        case .plan(let steps):
            HStack {
                PlanBubble(steps: steps, tail: isLast(i, poki: true))
                Spacer(minLength: .messageInsetPadding)
            }
            .padding(.top, startsRun(i) ? 10 : 0)
            .transition(PlanMotion.stepTransition)
        case .note(let note):
            NoteLine(note: note)
        case .step(let text, let ok):
            StepLine(text: text, ok: ok)
        }
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
        bold.font = .system(size: 12, weight: .semibold)
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
            .padding(.vertical, 13).padding(.horizontal, 15)
            .background(ChatColor.incoming, in: UnevenRoundedRectangle(topLeadingRadius: .cornerRadius, bottomLeadingRadius: .tailRadius,
                                                                       bottomTrailingRadius: .cornerRadius, topTrailingRadius: .cornerRadius, style: .continuous))
        }
        .accessibilityLabel(Text("Poki is typing"))
    }
}

/// The mark in front of a status line. Steps, approvals and the plan all draw the same tick and cross.
enum StatusGlyph: Equatable {
    case ok, failed, working, warning, island, none

    @ViewBuilder var view: some View {
        switch self {
        case .ok: Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(ChatColor.green)
        case .failed: Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Color(.systemRed))
        case .working: ProgressView().controlSize(.mini)
        case .warning: Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(Color(.systemOrange))
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
            .font(.system(size: 13)).foregroundStyle(ChatColor.pending)
            .multilineTextAlignment(.leading)
            .padding(.vertical, card ? 8 : 2).padding(.horizontal, card ? 12 : 14)
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

/// The bear in a round frame, as the ESP-171 boards draw it (`PokiFace.png` is the boards' own image: the
/// app icon's bear, closer up).
struct PokiAvatar: View {
    var size: CGFloat
    static let face = UIImage(named: "PokiFace")
    var body: some View {
        Group {
            if let face = Self.face { Image(uiImage: face).resizable().scaledToFill() } else { Image("Bear").resizable().scaledToFill() }
        }
        .frame(width: size, height: size).clipShape(.circle)
        .accessibilityHidden(true)
    }
}

// MARK: Plan

/// The steps of a task in one Poki bubble: done steps ticked, the step under way typing its words.
struct PlanBubble: View {
    var steps: [PlanStep]
    var tail: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(steps) { step in
                PlanRow(step: step).transition(PlanMotion.stepTransition)
            }
        }
        .animation(PlanMotion.enter, value: steps)
        .padding(.vertical, 10).padding(.horizontal, 14)
        .frame(width: 250, alignment: .leading)
        .background(ChatColor.incoming, in: UnevenRoundedRectangle(topLeadingRadius: .cornerRadius, bottomLeadingRadius: tail ? .tailRadius : .cornerRadius,
                                                                    bottomTrailingRadius: .cornerRadius, topTrailingRadius: .cornerRadius, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

private struct PlanRow: View {
    var step: PlanStep

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            ZStack {
                switch step.state {
                case .done:
                    DrawingCheck(color: ChatColor.green).frame(width: 12, height: 12).transition(PlanMotion.swapTransition)
                case .failed:
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Color(.systemRed)).transition(PlanMotion.swapTransition)
                case .current, .waiting:
                    let dashed = step.state == .waiting || UserDefaults.standard.string(forKey: "pokiChat") != nil
                    Circle()
                        .strokeBorder(ChatColor.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: dashed ? [2, 2] : []))
                        .frame(width: 13, height: 13)
                        .transition(PlanMotion.swapTransition)
                }
            }
            .frame(width: 13)
            .animation(PlanMotion.swap, value: step.state)
            Group {
                switch step.state {
                case .current, .waiting:
                    if UserDefaults.standard.string(forKey: "pokiChat") != nil {
                        Text(step.text).font(.system(size: 15)).foregroundStyle(ChatColor.pending)
                    } else {
                        TypewriterText(text: step.state == .waiting ? String(localized: "\(step.text), waiting for you") : step.text,
                                       font: .system(size: 15), color: ChatColor.pending)
                    }
                case .done, .failed:
                    Text(step.text).font(.system(size: 15)).foregroundStyle(Color(.label))
                        .transition(PlanMotion.swapTransition.animation(PlanMotion.swap.delay(PlanMotion.stagger)))
                }
            }
            .animation(PlanMotion.complete, value: step.state)
        }
        .lineLimit(2)
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
        case .modelChecking: String(localized: "The model is checking this step")
        case .modelApproved(let why): why.isEmpty ? String(localized: "Approved by model") : String(localized: "Approved by model: \(why)")
        case .modelDeclined(let why):
            why.isEmpty ? String(localized: "Not approved by model. Say yes in the chat to let it through.")
                : String(localized: "Not approved by model: \(why). Say yes in the chat to let it through.")
        }
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
// Sources/ExyteChat/Views/InputView/InputView.swift, Copyright (c) 2019 exyte, MIT License). Now: a
// rounded field with the plus menu on the left, dictation that writes into the field as you speak, the
// live voice button, and a stop button while a task runs.
struct ComposerInputView: View {
    @Environment(AppModel.self) private var model
    var running: Bool
    var send: (String) -> Void
    var stop: () -> Void
    /// Starts the live voice conversation.
    var openVoice: () -> Void
    var openModel: () -> Void
    var openDetails: () -> Void = {}
    var newConversation: () -> Void
    @State private var input = ""
    @State private var dictation = FieldDictation()
    @FocusState private var focused: Bool
    @State private var liveNote: String?
    @State private var sent: (text: String, at: Date)?

    private var voice: VoiceModel { model.voice }
    private var hasText: Bool { !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(spacing: 4) {
            if let liveNote, !dictation.on {
                Text(liveNote).font(.system(size: 12)).foregroundStyle(ChatColor.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20)
                    .onTapGesture { self.liveNote = nil; openModel() }
            } else if let problem = dictation.problem, !dictation.on {
                Text(problem).font(.system(size: 12)).foregroundStyle(Color(.systemRed))
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20)
            }
            HStack(alignment: .bottom, spacing: 8) {
                Menu {
                    Button("New Conversation", systemImage: "square.and.pencil", action: newConversation).disabled(running)
                    Menu("Chat Model: \(ModelKeys.selectedModelName)", systemImage: "bubble.left.and.text.bubble.right") {
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
                    }
                    if VoiceDirect.apiKey != nil {
                        Menu("Voice Model: \(VoiceDirect.model)", systemImage: "waveform") {
                            ForEach(ModelCatalog.voiceAvailable) { choice in
                                Button { ModelCatalog.voiceModel = choice.id } label: {
                                    if VoiceDirect.model == choice.id { Label(choice.name, systemImage: "checkmark") } else { Text(choice.name) }
                                }
                            }
                        }
                    }
                    Button("Accounts and Models", systemImage: "person.crop.circle", action: openModel)
                    Button("Poki Details", systemImage: "gearshape", action: openDetails)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Color(hex: 0x6B6B70))
                        .frame(width: 34, height: 34)
                        .background(ChatColor.incoming, in: .circle)
                }
                .accessibilityLabel(Text("More"))

                HStack(alignment: .bottom, spacing: 4) {
                    TextField(text: $input, prompt: Text(dictation.on ? "Listening…" : "Message Poki").foregroundStyle(ChatColor.placeholder), axis: .vertical) { Text("Message Poki") }
                        .font(.system(size: 17))
                        .focused($focused)
                        .multilineTextAlignment(.leading)
                        .lineLimit(1...6)
                        .padding(.vertical, 7)
                        .submitLabel(.send)
                        .onSubmit(submit)
                    trailing.frame(height: 36)
                }
                .padding(.leading, 14).padding(.trailing, 6)
                .frame(minHeight: 36)
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(ChatColor.fieldEdge, lineWidth: 1))
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
        .animation(.snappy, value: dictation.on)
        .onChange(of: dictation.text) { _, text in if dictation.on { input = dictation.base + text } }
        // A keyboard that was still composing (autocorrect, Pinyin) can commit its text after Send has
        // emptied the field, which put the sent message back: for a moment after Send, that is undone.
        .onChange(of: input) { _, text in
            if let sent, text == sent.text, Date().timeIntervalSince(sent.at) < 1 { input = "" }
        }
        .onDisappear { dictation.stop(model) }
    }

    @ViewBuilder private var trailing: some View {
        HStack(spacing: 2) {
            if running {
                Button(action: stop) {
                    Image(systemName: "stop.circle.fill").resizable().scaledToFit().frame(width: 28, height: 28).foregroundStyle(.white, Site.blue)
                        .frame(width: 44, height: 40).contentShape(.rect)
                }
                .accessibilityLabel(Text("Stop"))
            } else if hasText {
                Button(action: submit) {
                    Image(systemName: "arrow.up.circle.fill").resizable().scaledToFit().frame(width: 28, height: 28).foregroundStyle(.white, Site.blue)
                }
                .accessibilityLabel(Text("Send"))
            } else {
                // Dictation: the words appear in the field; nothing is sent until you tap Send.
                Button { dictation.on ? dictation.stop(model) : dictation.start(model, after: input) } label: {
                    Image(systemName: dictation.on ? "mic.fill" : "mic.fill")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(dictation.on ? Color(.systemRed) : ChatColor.secondary)
                        .symbolEffect(.pulse, isActive: dictation.on)
                        .frame(width: 28, height: 36).contentShape(.rect)
                }
                .disabled(voice.isOn)
                .accessibilityLabel(Text(dictation.on ? "Stop Dictation" : "Dictate"))
            }
        }
    }

    private func submit() {
        guard !running, hasText else { return }
        dictation.cancel(model)
        let text = input
        send(text)
        sent = (text, Date())
        input = ""
        // Once more after the keyboard has settled, for a commit that arrives in pieces.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            if input == text { input = "" }
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
