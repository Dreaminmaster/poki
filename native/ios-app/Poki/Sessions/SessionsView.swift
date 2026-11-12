//
//  SessionsView.swift
//  Poki
//
//  The conversations list began as GetStream/swiftui-iMessage-clone's channel list (commit df114b4,
//  iMessageClone/ChannelList, by Stefan Blos; the repository has no licence file). For ESP-326 it is a
//  system List: the rows, their swipe actions and their separators are the system's own.
//

import SwiftUI
import UIKit

/// The drawer contains conversations and the action for starting a new one.
struct SessionsView: View {
    @Environment(AppModel.self) private var model
    @Environment(ChatModel.self) private var chat
    var openChat: () -> Void
    var openSession: (String) -> Void
    @State private var renaming: SavedSession?
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.drawerOnGlass) private var onGlass
    @Environment(\.colorScheme) private var scheme

    /// The time and the summary line. On the drawer's glass in dark mode a step lighter than the
    /// system's secondary label, so they still read where a bright part of the chat (the home page's
    /// bear) shows through, without a ground under the row.
    private var secondary: Color {
        onGlass && scheme == .dark ? Color(white: 0.92, opacity: 0.9) : Color(.secondaryLabel)
    }
    @State private var newName = ""

    private var store: SessionStore { SessionStore.shared }
    private var sampleHome: String? { UserDefaults.standard.string(forKey: "pokiHome") }

    var body: some View {
        List {
            Section {
                ForEach(shown) { session in
                    row(session)
                        .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
                        .listRowSeparator(.hidden)
                        .listRowBackground(rowGround(session))
                }
                if shown.isEmpty { empty }
            }
            .listSectionSeparator(.hidden)
        }
        .listStyle(.plain)
        .scrollContentBackground(onGlass ? .hidden : .automatic)
        .scrollDismissesKeyboard(.immediately)
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .safeAreaInset(edge: .bottom, spacing: 0) { SettingsEntryRow() }
        .background(onGlass ? Color.clear : Color(.systemBackground))
        .toolbar(.hidden, for: .navigationBar)
        .alert("Rename Session", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Save") {
                if let session = renaming { store.rename(session.id, to: newName) }
                renaming = nil
            }
        }
    }

    private var header: some View {
        HStack {
            Spacer()
            Button {
                if !chat.running { chat.newConversation() }
                openChat()
            } label: {
                Image(systemName: "square.and.pencil").font(.body.weight(.semibold)).foregroundStyle(Tint.onSolid)
                    .frame(width: 40, height: 40).background(Tint.solid, in: .circle)
            }
            .buttonStyle(.plain)
            .disabled(chat.running)
            .accessibilityLabel(Text("New Conversation"))
            .accessibilityIdentifier("threads.newChat")
        }
        .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 6)
        .background(onGlass ? Color.clear : Color(.systemBackground))
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }

    private var big: Bool { typeSize.isAccessibilitySize }

    /// The conversation on screen in the chat, marked as the selected row.
    private func current(_ session: SavedSession) -> Bool {
        session.kind == .poki && session.id == chat.sessionID && sampleHome == nil
    }

    /// The selected row's soft fill; on glass every other row is clear, elsewhere the list's own ground.
    @ViewBuilder private func rowGround(_ session: SavedSession) -> some View {
        if current(session) {
            RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.primary.opacity(0.07)).padding(.horizontal, 8)
        } else {
            onGlass ? Color.clear : Color(.systemBackground)
        }
    }

    /// The app it worked in: for the chat's own task under way, the app it is in now.
    private func app(_ session: SavedSession) -> String? {
        if session.live, session.id == chat.sessionID, let now = chat.taskApp, !now.isEmpty { return now }
        return session.app
    }

    /// One conversation: its app's icon, the name and the time on the first line, one line of what
    /// happened last under it, amber with a dot while a step waits for you. The chat's own type
    /// sizes: the body for the name as for a bubble, the footnote for the time as for a bubble's.
    private func row(_ session: SavedSession) -> some View {
        let needs = needsYou(session)
        return Button { open(session) } label: {
            HStack(alignment: .center, spacing: 12) {
                SessionAvatar(session: session, app: app(session), size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    if big {
                        Text(verbatim: session.name).font(.body.weight(.semibold)).foregroundStyle(Color(.label)).lineLimit(2)
                    } else {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(verbatim: session.name).font(.body.weight(.semibold)).foregroundStyle(Color(.label)).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(verbatim: stamp(session)).font(.footnote).monospacedDigit().foregroundStyle(secondary)
                        }
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(verbatim: line(session))
                            .font(.subheadline).foregroundStyle(needs ? Tint.amberInk : secondary)
                            .lineLimit(big ? 2 : 1).frame(maxWidth: .infinity, alignment: .leading)
                        if needs { Circle().fill(Tint.amber).frame(width: 8, height: 8).accessibilityHidden(true) }
                    }
                    if big { Text(verbatim: stamp(session)).font(.footnote).foregroundStyle(secondary) }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 10)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        // The icon says which app the conversation worked in; VoiceOver says its name, as the iPhone names it.
        .accessibilityValue(app(session).flatMap(AppIconStore.name) ?? "")
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if !session.live, sampleHome == nil {
                Button("Delete", systemImage: "trash", role: .destructive) { store.delete(session.id) }
            }
            Button("Rename", systemImage: "pencil") { startRename(session) }
        }
        .contextMenu {
            Button("Rename", systemImage: "pencil") { startRename(session) }
            if !session.live, sampleHome == nil {
                Button("Delete", systemImage: "trash", role: .destructive) { store.delete(session.id) }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var empty: some View {
        ContentUnavailableView("No Conversations Yet", systemImage: "bubble.left.and.bubble.right")
            .listRowSeparator(.hidden)
    }

    private var shown: [SavedSession] {
        if sampleHome == "paused" { return [] }
        return sampleHome == "sessions" ? Self.sampleSessions : store.ordered
    }

    /// Held by a step that waits for the owner: its own last plan says so, or it is the conversation
    /// the waiting approval or hand-over belongs to.
    private func needsYou(_ session: SavedSession) -> Bool {
        if session.needsYou { return true }
        guard session.live, session.id == chat.sessionID || session.id == store.activeSessionID else { return false }
        return !model.approvals.isEmpty || model.handoffText != nil
    }

    private func line(_ session: SavedSession) -> String {
        let line = session.lastLine
        if session.kind != .poki, line.isEmpty { return session.title }
        return line
    }

    private func stamp(_ session: SavedSession) -> String {
        if sampleHome == "sessions" {
            switch session.id {
            case "sample-1": return String(localized: "now")
            case "sample-2": return "12:23 PM"
            case "sample-3": return "11:22 AM"
            default: return String(localized: "Yesterday")
            }
        }
        return session.live ? String(localized: "now") : ChatTime.row(session.updated)
    }

    private static var sampleSessions: [SavedSession] {
        let now = Date()
        let yesterday = now.addingTimeInterval(-86400)
        return [
            SavedSession(
                id: "sample-1",
                kind: .handoff,
                client: "Claude Code",
                title: "Claude → Poki",
                started: now,
                updated: now,
                live: true,
                outcome: nil,
                entries: [ChatEntry(.poki(String(localized: "Needs your OK: send “On my way” to Mom"))), ChatEntry(.note(.waiting))],
                calls: [],
                customName: "Claude → Poki"
            ),
            SavedSession(
                id: "sample-2",
                kind: .poki,
                client: nil,
                title: String(localized: "What iOS version is this?"),
                started: now,
                updated: now,
                live: false,
                outcome: .done,
                entries: [ChatEntry(.poki(String(localized: "It’s iOS 27.3. Want me to check for an update?")))],
                calls: []
            ),
            SavedSession(
                id: "sample-3",
                kind: .agent,
                client: "Codex",
                title: "Codex",
                started: now,
                updated: now,
                live: false,
                outcome: .done,
                entries: [ChatEntry(.poki(String(localized: "Opened Photos and tapped “Albums”. Done in 3 steps.")))],
                calls: [],
                customName: "Codex"
            ),
            SavedSession(
                id: "sample-4",
                kind: .poki,
                client: nil,
                title: String(localized: "Order oat milk again"),
                started: yesterday,
                updated: yesterday,
                live: false,
                outcome: .done,
                entries: [ChatEntry(.poki(String(localized: "Ran your routine: same order as last week, $4.99.")))],
                calls: []
            ),
            SavedSession(
                id: "sample-5",
                kind: .agent,
                client: "Claude Code",
                title: "Claude Code",
                started: yesterday,
                updated: yesterday,
                live: false,
                outcome: .done,
                entries: [ChatEntry(.poki(String(localized: "Your turn, enter your Apple Account password")))],
                calls: [],
                customName: "Claude Code"
            ),
        ]
    }


    private func startRename(_ session: SavedSession) {
        newName = session.name
        renaming = session
    }

    private func open(_ session: SavedSession) {
        if session.kind == .poki {
            if session.id != chat.sessionID, sampleHome == nil { chat.restore(session) }
            openChat()
        } else {
            openSession(session.id)
        }
    }
}

extension SavedSession {
    /// Live, and its task is held by a step that waits for the owner's answer.
    var needsYou: Bool {
        guard live else { return false }
        for entry in entries.reversed() {
            switch entry.kind {
            case .plan(let steps): return steps.contains { $0.state == .waiting }
            case .note(.waiting): return true
            case .note(.approval(let note)): return note.state == .asking && !note.byModel
            case .you, .request: return false
            default: continue
            }
        }
        return false
    }
}

extension View {
    /// The line under the title (iOS 26's navigation subtitle); nothing before iOS 26.
    @ViewBuilder func sessionSubtitle(_ text: String) -> some View {
        if #available(iOS 26.0, *), !text.isEmpty { navigationSubtitle(Text(verbatim: text)) } else { self }
    }
}

/// What a row shows on its leading side: the icon of the app the conversation worked in, with the
/// outside agent's badge on its corner for an agent's session or hand-off. Without an app icon, an
/// agent's badge, or for a chat with Poki the one placeholder tile.
struct SessionAvatar: View {
    var session: SavedSession
    /// The app it worked in, when the row knows better than what is saved (a task under way).
    var app: String? = nil
    var size: CGFloat
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let app = app ?? session.app
        let agent = session.kind == .agent || session.kind == .handoff
        // An agent's session shows the app only once its icon is at hand; a chat with Poki shows the
        // placeholder while the icon is fetched.
        let icon = app.flatMap { name in agent ? (AppIconStore.shared.icon(name, dark: scheme == .dark) != nil ? name : nil) : name }
        ZStack(alignment: .bottomTrailing) {
            if let icon {
                AppIconView(app: icon, size: size)
            } else if agent {
                AgentBadge(name: session.client ?? "", size: size)
            } else {
                tile(session.kind == .voice ? "waveform" : "bubble.left")
            }
            if agent, icon != nil {
                // Whose session it is, on the app's corner.
                AgentBadge(name: session.client ?? "", size: size * 0.46, edge: true).offset(x: 4, y: 4)
            } else if session.kind == .handoff {
                PokiAvatar(size: size * 0.46)
                    .overlay(RoundedRectangle(cornerRadius: size * 0.13, style: .continuous).strokeBorder(Color(.systemBackground), lineWidth: 1.5))
                    .offset(x: 4, y: 4)
            }
        }
        .frame(width: size, height: size)
        .task(id: app) { if let app { await AppIconStore.shared.load(app) } }
        .accessibilityHidden(true)
    }

    /// The placeholder: the same icon shape as an app's, on the system's quiet fill.
    private func tile(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: size * 0.42, weight: .medium)).foregroundStyle(Color(.secondaryLabel))
            .frame(width: size, height: size)
            .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: size * 0.225, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// An outside agent's badge: its provider's logo, or its initials (see `CallerBadge`). In dark mode a
/// dark badge (OpenAI's is black) turns light, so it never is a black disc on a dark panel.
struct AgentBadge: View {
    var name: String
    var size: CGFloat
    /// On another icon's corner: a ring in the page's colour sets it apart from the icon.
    var edge = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        CallerBadge(name: name, size: size, lifted: scheme == .dark)
            .overlay(Circle().strokeBorder(edge ? Color(.systemBackground) : Tint.ring, lineWidth: edge ? 1.5 : 1))
            .accessibilityHidden(true)
    }
}

/// The boards' guest thread (02b) for the screenshots (`-pokiHome sessions`, the first row): an
/// outside agent borrowing Poki's hands, at step 2 of 3. Nothing runs.
private enum GuestSample {
    static var isOn: Bool { UserDefaults.standard.string(forKey: "pokiHome") != nil }
    static let plan = [String(localized: "Open TestFlight"), String(localized: "Find Poki"), String(localized: "Tap Update")]
    static let entries: [ChatEntry] = {
        var steps = ChatEntry(.plan([PlanStep(plan[0], state: .done), PlanStep(plan[1])]))
        steps.at = Date().addingTimeInterval(-42)
        steps.title = String(localized: "Install the newest build")
        return [ChatEntry(.request(String(localized: "Open TestFlight and install the newest Poki build."), from: "Claude Code")), steps]
    }()
}

/// An outside agent's session or hand-off as a conversation: the agent's own steps as grey lines, its
/// request and Poki's answer as bubbles. Live while the session runs.
struct SessionView: View {
    @Environment(AppModel.self) private var model
    var id: String
    var back: () -> Void

    @State private var renaming = false
    @State private var newName = ""
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let session = SessionStore.shared.session(id)
        let running = AskPoki.live(id)
        let sample = GuestSample.isOn && id == "sample-1"
        let live = sample || (running?.running ?? (session?.live ?? false))
        // The live task's card shows what Poki last saw of the screen, as in the chat.
        let shot: Image? = sample ? SampleShot.image(dark: scheme == .dark) : live ? model.lastShot.map { Image(uiImage: $0) } : nil
        ChatTranscript(entries: sample ? GuestSample.entries : (running?.entries ?? session?.entries) ?? [],
                       typing: running?.awaitingModel ?? false, canRetry: false, retry: {}, session: id,
                       live: live, waiting: live && !model.approvals.isEmpty, handedOver: live && model.handoffText != nil,
                       plan: sample ? GuestSample.plan : running?.planSteps, app: sample ? "TestFlight" : running.map(\.taskApp) ?? model.currentApp, shot: shot) { EmptyView() }
        // The step that waits for you and Stop sit on the bottom edge, so the conversation scrolls under
        // them and the bars keep their scroll-edge behaviour (as in the chat).
        .bottomBar {
            let asking = session?.live == true && (!model.approvals.isEmpty || model.handoffText != nil)
            if asking || running != nil || sample {
                VStack(spacing: 8) {
                    if session?.live == true, let approval = model.approvals.first {
                        // A message of the handed-over task: who it goes to and the words, as in the chat.
                        let words = running?.askWords[approval.id]
                        ApprovalAskCard(title: words?.title ?? approval.question, detail: words?.detail ?? approval.reasonLine,
                                        quote: words?.quote ?? ActivityWords.label(approval.summary), expires: approval.expires,
                                        answer: { approved in model.resolve(approval, approved: approved) })
                    } else if session?.live == true, let text = model.handoffText {
                        TurnCard(text: Bundle.main.localizedString(forKey: text, value: text, table: nil), done: model.handoffDoneInApp)
                    }
                    if running != nil || sample {
                        // Said where Stop is, and only there: the words promise what the button does.
                        Text("A guest is borrowing Poki’s hands. You can tap Stop anytime.")
                            .font(.footnote).foregroundStyle(Color(.secondaryLabel)).multilineTextAlignment(.center)
                        Button("Stop Poki", systemImage: "stop.fill") { AskPoki.live(id)?.stop() }
                            .buttonStyle(.bordered).buttonBorderShape(.capsule).tint(Tint.red)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .frame(maxWidth: 720)
            }
        }
        // The chat's own page colour, so Poki's white bubbles stand on it as they do there.
        .background(Tint.page.ignoresSafeArea())
        // The session's name is the title; its menu renames it (the system title menu).
        .navigationTitle(Text(verbatim: session?.name ?? (sample ? "Claude Code" : "")))
        .navigationBarTitleDisplayMode(.inline)
        .sessionSubtitle(caption(session))
        .toolbarTitleMenu {
            Button("Rename", systemImage: "pencil") { newName = session?.name ?? ""; renaming = true }
        }
        .alert("Rename Session", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Save") { SessionStore.shared.rename(id, to: newName) }
        }
    }

    private func caption(_ session: SavedSession?) -> String {
        guard let session else { return "" }
        switch session.kind {
        case .agent: return String(localized: "Over MCP, \(ChatTime.row(session.started))")
        case .handoff: return String(localized: "Handed to Poki, \(ChatTime.row(session.started))")
        case .voice: return String(localized: "Voice, \(ChatTime.row(session.started))")
        case .poki: return ""
        }
    }
}
