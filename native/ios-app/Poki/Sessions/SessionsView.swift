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

/// Every conversation (ESP-326 board "07 Threads"): the drawer beside the chat on iPhone, the left
/// column on iPad. Pinned on top are Poki itself and the guests that borrow its hands (outside agents);
/// below them the recent conversations. Poki's status sits on the bottom edge and opens its profile.
struct SessionsView: View {
    @Environment(AppModel.self) private var model
    @Environment(ChatModel.self) private var chat
    /// Shows Poki's chat (and closes the drawer).
    var openChat: () -> Void
    var openSession: (String) -> Void
    var openModel: () -> Void = {}
    var openConnectors: () -> Void = {}
    var openDetails: () -> Void
    var openSetup: () -> Void = {}
    var openSetupStep: (SetupStep) -> Void = { _ in }
    /// The bear on the bottom edge is where Poki's profile zooms out of when it opens from here.
    var profileSource: Namespace.ID? = nil
    @State private var query = ""
    @State private var filter = Filter.all
    @State private var renaming: SavedSession?
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var newName = ""

    enum Filter: Hashable { case all, needsYou, guests }

    private var store: SessionStore { SessionStore.shared }
    private var sampleHome: String? { UserDefaults.standard.string(forKey: "pokiHome") }

    /// One problem at a time under the list: a runner or pairing failure, an open setup step, no chat
    /// account, or the relay offline (see `SetupIssueHint.home`).
    private var homeHint: SetupIssueHint? {
        guard sampleHome == nil else { return nil }
        return SetupIssueHint.home(model: model)
    }

    var body: some View {
        let status = sampleHome == "paused" ? PokiStatus(.paused) : PokiStatus.current(model: model, chat: chat)
        let rows = shown
        List {
            if filter == .all, query.isEmpty {
                Section {
                    pokiRow(status)
                    ForEach(guests) { guest in guestRow(guest) }
                } header: { Text("Pinned") }
                .listSectionSeparator(.hidden)
            }
            Section {
                ForEach(rows) { session in row(session) }
                if rows.isEmpty { empty }
            } header: { if !rows.isEmpty { Text("Recent") } }
            .listSectionSeparator(.hidden)
            if let hint = homeHint {
                SetupHintLine(hint: hint, openSetupStep: openSetupStep, openSetup: openSetup, openModel: openModel, openAgents: openConnectors)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollDismissesKeyboard(.immediately)
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .safeAreaInset(edge: .bottom, spacing: 0) { strip(status) }
        .background(Color(.systemBackground))
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

    // MARK: Search, new chat and the filter

    private var header: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Color(.secondaryLabel))
                    TextField("Search", text: $query).submitLabel(.search).autocorrectionDisabled()
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Color(.tertiaryLabel)) }
                            .buttonStyle(.plain).accessibilityLabel(Text("Clear"))
                    }
                }
                .padding(.horizontal, 12).frame(minHeight: 40)
                .background(Color(.tertiarySystemFill), in: .capsule)

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
            Picker("Show", selection: $filter) {
                Text("All").tag(Filter.all)
                Text(needing > 0 ? "Needs You (\(needing))" : "Needs You").tag(Filter.needsYou)
                Text("Guests").tag(Filter.guests)
            }
            .pickerStyle(.segmented)
        }
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 8)
        .background(Color(.systemBackground))
        // Bars stop growing here, as the system's do; the rows below grow freely.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }

    // MARK: Rows

    /// At the accessibility text sizes a row's time goes under its words instead of beside them.
    private var big: Bool { typeSize.isAccessibilitySize }

    /// Poki itself: its face and what it is doing. While it has the phone the row is Poki's soft blue.
    private func pokiRow(_ status: PokiStatus) -> some View {
        let busy = [.onYourPhone, .thinking, .checking].contains(status.mood)
        return Button(action: openChat) {
            HStack(spacing: 12) {
                PokiAvatar(size: 44, mood: status.mood)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: "Poki").font(.body.weight(.semibold)).foregroundStyle(Color(.label))
                    Text(verbatim: status.word).font(.subheadline).foregroundStyle(busy ? Tint.blueText : Color(.secondaryLabel)).lineLimit(big ? 2 : 1)
                    if busy, big { Text("now").font(.footnote).foregroundStyle(Tint.blueText) }
                }
                Spacer(minLength: 8)
                if busy, !big { Text("now").font(.footnote).foregroundStyle(Tint.blueText) }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .listRowSeparator(.hidden)
        .listRowBackground(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(busy ? Tint.blueSoft : Color.clear).padding(.horizontal, 8))
        .accessibilityIdentifier("threads.poki")
    }

    /// An outside agent that has used Poki's hands, by its latest session.
    private func guestRow(_ session: SavedSession) -> some View {
        let name = (session.client ?? session.name).trimmingCharacters(in: .whitespaces)
        return Button { openSession(session.id) } label: {
            HStack(spacing: 12) {
                AgentBadge(name: name, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: name).font(.body.weight(.semibold)).foregroundStyle(Color(.label)).lineLimit(big ? 2 : 1)
                    Text(verbatim: session.live ? (session.lastLine.isEmpty ? String(localized: "Working…") : session.lastLine)
                         : String(localized: "Over MCP, \(stamp(session))"))
                        .font(.subheadline).foregroundStyle(Color(.secondaryLabel)).lineLimit(big ? 2 : 1)
                    if session.live, big { Text("now").font(.footnote).foregroundStyle(Color(.secondaryLabel)) }
                }
                Spacer(minLength: 8)
                if session.live, !big { Text("now").font(.footnote).foregroundStyle(Color(.secondaryLabel)) }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .listRowSeparator(.hidden)
    }

    private func row(_ session: SavedSession) -> some View {
        let needs = needsYou(session)
        return Button { open(session) } label: {
            HStack(alignment: .top, spacing: 12) {
                SessionAvatar(session: session, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    if big {
                        Text(verbatim: session.name).font(.body.weight(.medium)).foregroundStyle(Color(.label)).lineLimit(2)
                    } else {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(verbatim: session.name).font(.body.weight(.medium)).foregroundStyle(Color(.label)).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(verbatim: stamp(session)).font(.footnote).foregroundStyle(Color(.secondaryLabel))
                        }
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(verbatim: line(session))
                            .font(.subheadline).foregroundStyle(needs ? Tint.amberInk : Color(.secondaryLabel))
                            .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                        if needs { Circle().fill(Tint.amber).frame(width: 8, height: 8).accessibilityHidden(true) }
                    }
                    if big { Text(verbatim: stamp(session)).font(.footnote).foregroundStyle(Color(.secondaryLabel)) }
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
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

    @ViewBuilder private var empty: some View {
        if !query.isEmpty {
            ContentUnavailableView.search(text: query).listRowSeparator(.hidden)
        } else if filter == .needsYou {
            ContentUnavailableView("Nothing Needs You", systemImage: "checkmark.circle",
                                   description: Text("Steps waiting for your answer show up here.").font(.subheadline))
                .listRowSeparator(.hidden)
        } else {
            ContentUnavailableView("No Conversations Yet", systemImage: "bubble.left.and.bubble.right",
                                   description: Text("Tap Poki to ask for anything on this iPhone. Claude, Codex and other agents show up here once they connect.").font(.subheadline))
                .listRowSeparator(.hidden)
        }
    }

    // MARK: Poki on the bottom edge

    private func strip(_ status: PokiStatus) -> some View {
        Button(action: openDetails) {
            HStack(spacing: 12) {
                PokiAvatar(size: 40, mood: status.mood).profileSource(profileSource, id: "poki-threads")
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: "Poki").font(.body.weight(.semibold)).foregroundStyle(Color(.label))
                    PokiStatusLine(status: status).font(.footnote).foregroundStyle(Color(.secondaryLabel))
                }
                Spacer(minLength: 8)
                Image(systemName: "slider.horizontal.3").font(.body.weight(.medium)).foregroundStyle(Color(.label))
                    .frame(width: 40, height: 40).background(Color(.tertiarySystemFill), in: .circle)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Poki, \(status.word), details"))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("threads.details")
    }

    // MARK: What is listed

    /// The outside agents, one row each by their latest session, at most two.
    private var guests: [SavedSession] {
        if sampleHome == "paused" { return [] }
        let base = sampleHome == "sessions" ? Self.sampleSessions : store.ordered
        var seen: Set<String> = []
        var result: [SavedSession] = []
        for session in base where session.kind == .agent || session.kind == .handoff {
            let client = (session.client ?? session.name).trimmingCharacters(in: .whitespaces)
            guard !client.isEmpty, !seen.contains(client) else { continue }
            seen.insert(client)
            result.append(session)
            if result.count == 2 { break }
        }
        return result
    }

    /// The sessions matching the filter and the search field: name, first message or last line.
    private var shown: [SavedSession] {
        if sampleHome == "paused" { return [] }
        var base = sampleHome == "sessions" ? Self.sampleSessions : store.ordered
        switch filter {
        case .all: break
        case .needsYou: base = base.filter(needsYou)
        case .guests: base = base.filter { $0.kind == .agent || $0.kind == .handoff }
        }
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return base }
        return base.filter { [$0.name, $0.title, $0.lastLine, $0.client ?? ""].contains { $0.localizedCaseInsensitiveContains(q) } }
    }

    private var needing: Int {
        if sampleHome == "paused" { return 0 }
        return (sampleHome == "sessions" ? Self.sampleSessions : store.ordered).filter(needsYou).count
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
                entries: [ChatEntry(.poki(String(localized: "Your turn: enter your Apple Account password.")))],
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

/// What kind of conversation a row is: a chat with Poki, a voice conversation, an outside agent's own
/// session (its badge), or a task it handed to Poki (its badge with Poki's face).
struct SessionAvatar: View {
    var session: SavedSession
    var size: CGFloat

    var body: some View {
        switch session.kind {
        case .poki: tile("bubble.left")
        case .voice: tile("waveform")
        case .agent: AgentBadge(name: session.client ?? "", size: size)
        case .handoff:
            ZStack(alignment: .bottomTrailing) {
                AgentBadge(name: session.client ?? "", size: size)
                PokiAvatar(size: size * 0.5).overlay(RoundedRectangle(cornerRadius: size * 0.14, style: .continuous).strokeBorder(Color(.systemBackground), lineWidth: 2))
                    .offset(x: 4, y: 4)
            }
        }
    }

    private func tile(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: size * 0.44, weight: .medium)).foregroundStyle(Color(.secondaryLabel))
            .frame(width: size, height: size)
            .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: size * 0.28, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// An outside agent's badge: its provider's logo, or its initials (see `CallerBadge`).
struct AgentBadge: View {
    var name: String
    var size: CGFloat
    var body: some View {
        // A dark badge (OpenAI's is black) keeps its edge on the dark background with a hairline.
        CallerBadge(name: name, size: size).overlay(Circle().strokeBorder(Tint.ring, lineWidth: 1)).accessibilityHidden(true)
    }
}

/// An outside agent's session or hand-off as a conversation: the agent's own steps as grey lines, its
/// request and Poki's answer as bubbles. Live while the session runs.
struct SessionView: View {
    @Environment(AppModel.self) private var model
    var id: String
    var back: () -> Void

    @State private var renaming = false
    @State private var newName = ""

    var body: some View {
        let session = SessionStore.shared.session(id)
        let running = AskPoki.live(id)
        let live = running?.running ?? (session?.live ?? false)
        ChatTranscript(entries: (running?.entries ?? session?.entries) ?? [], typing: running?.awaitingModel ?? false, canRetry: false, retry: {}, session: id,
                       live: live, waiting: live && !model.approvals.isEmpty, handedOver: live && model.handoffText != nil,
                       plan: running?.planSteps, app: model.currentApp) { EmptyView() }
        // The step that waits for you and Stop sit on the bottom edge, so the conversation scrolls under
        // them and the bars keep their scroll-edge behaviour (as in the chat).
        .bottomBar {
            let asking = session?.live == true && (!model.approvals.isEmpty || model.handoffText != nil)
            if asking || running != nil {
                VStack(spacing: 8) {
                    if session?.live == true, let approval = model.approvals.first {
                        ApprovalAskCard(title: approval.question, detail: approval.reasonLine, quote: approval.summary, expires: approval.expires,
                                        answer: { approved in model.resolve(approval, approved: approved) })
                    } else if session?.live == true, let text = model.handoffText {
                        TurnCard(text: Bundle.main.localizedString(forKey: text, value: text, table: nil), done: model.handoffDoneInApp)
                    }
                    if running != nil {
                        Button("Stop Poki", systemImage: "stop.fill") { AskPoki.live(id)?.stop() }
                            .buttonStyle(.bordered).buttonBorderShape(.capsule).tint(Tint.red)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .frame(maxWidth: 720)
            }
        }
        .background(Color(.systemBackground))
        // The session's name is the title; its menu renames it (the system title menu).
        .navigationTitle(Text(verbatim: session?.name ?? ""))
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
