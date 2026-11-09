//
//  SessionsView.swift
//  Poki
//
//  Session rows and pinned channels are adapted from GetStream/swiftui-iMessage-clone (commit df114b4,
//  iMessageClone/ChannelList/iMessageChannelListItemView.swift and
//  iMessageClone/ChannelList/PinnedChannelsView.swift, by Stefan Blos; the repository has no licence file).
//

import SwiftUI
import UIKit

/// Poki's home (ESP-174 boards "H1 Home sessions" and "H2 Home paused"): every conversation, like the
/// Messages list, with no bottom tab bar and no permanent warning cards. Paused state is a small orange
/// badge on the top-left Poki avatar; tapping the avatar opens Poki Details.
struct SessionsView: View {
    @Environment(AppModel.self) private var model
    @Environment(ChatModel.self) private var chat
    var openChat: () -> Void
    var openSession: (String) -> Void
    var openModel: () -> Void = {}
    var openConnectors: () -> Void = {}
    var openDetails: () -> Void
    var openVoice: () -> Void = {}
    var openSetup: () -> Void = {}
    var openSetupStep: (SetupStep) -> Void = { _ in }
    @State private var query = ""
    @State private var renaming: SavedSession?
    @State private var newName = ""

    private var store: SessionStore { SessionStore.shared }
    private var sampleHome: String? { UserDefaults.standard.string(forKey: "pokiHome") }

    /// Whether Poki shows the small orange pause badge on the top-left avatar (board "H2 Home paused").
    /// Matches standalone's power state (#78 & #79): when Poki is on (or `wantsOn` after Poki Setup install)
    /// and setup is complete with no runner failure, Poki is ready (`isPaused == false`).
    var isPaused: Bool {
        if sampleHome == "paused" { return true }
        if sampleHome == "sessions" { return false }
        let setupIncomplete = !model.setupComplete && !SetupStep.shown.allSatisfy(model.isDone)
        let runnerFailed = model.runner.state == "failed" || model.pairingTrouble != nil || model.servicesSilent
        return !(model.sessionOn || model.wantsOn) || setupIncomplete || runnerFailed
    }

    /// Runtime connection/runner failure hint (#78 "Can't Reach iPhone", pairing refusal, etc.) on the home page.
    private var homeRunnerHint: SetupIssueHint? {
        guard sampleHome == nil else { return nil }
        return SetupIssueHint.runnerIssue(model: model)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                topBar
                titleBar
                searchBar
                PinnedChannelsView(items: pinnedItems, openChat: openChat, openSession: openSession)
                if let hint = homeRunnerHint {
                    SetupHintLine(hint: hint, openSetupStep: openSetupStep, openSetup: openSetup, openModel: openModel)
                }
                sessionList
            }
        }
        .background(Color(.systemBackground).ignoresSafeArea())
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

    private var topBar: some View {
        HStack {
            Button(action: openDetails) {
                ZStack(alignment: .bottomTrailing) {
                    PokiAvatar(size: 36)
                    if isPaused {
                        PausedAvatarBadge()
                            .offset(x: 3, y: 3)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(isPaused ? "Poki, paused, details" : "Poki, details"))
            .accessibilityIdentifier("home.poki.details")

            Spacer()

            Button {
                if !chat.running { chat.newConversation() }
                openChat()
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Site.blue)
                    .frame(width: 28, height: 28)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(chat.running)
            .accessibilityLabel(Text("New Chat with Poki"))
            .accessibilityIdentifier("home.newChat")
        }
        .padding(.horizontal, 16)
        .padding(.top, 2)
    }

    private var titleBar: some View {
        Text(verbatim: "Poki")
            .font(.system(size: 34, weight: .bold))
            .foregroundStyle(Color(.label))
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 10)
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color(hex: 0x8E8E93))
            TextField("Search", text: $query)
                .font(.system(size: 17))
                .foregroundStyle(Color(.label))
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(Color(hex: 0xEEEEF0), in: .rect(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }

    @ViewBuilder private var sessionList: some View {
        let rows = shown
        if rows.isEmpty, query.isEmpty {
            Text("Tap Poki to ask for anything on this iPhone. Claude, Codex and other agents show up here once they connect.")
                .font(.system(size: 15))
                .foregroundStyle(ChatColor.secondary)
                .multilineTextAlignment(.center)
                .padding(.leading, 40)
                .padding(.trailing, 24)
                .padding(.top, 8)
                .frame(maxWidth: .infinity)
        } else if rows.isEmpty {
            ContentUnavailableView.search(text: query)
                .padding(.top, 24)
        } else {
            LazyVStack(spacing: 0) {
                ForEach(rows) { session in
                    Button { open(session) } label: {
                        iMessageChannelListItemView(session: session, stampOverride: sampleStamp(for: session.id))
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button { startRename(session) } label: { Label("Rename", systemImage: "pencil") }
                        if !session.live {
                            Button(role: .destructive) { store.delete(session.id) } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                }
            }
        }
    }

    private var pinnedItems: [PinnedChannelItem] {
        if sampleHome == "paused" {
            return [.poki]
        }
        if sampleHome == "sessions" {
            return [
                .poki,
                PinnedChannelItem(id: "sample-claude", name: "Claude Code", client: "Claude Code", isPoki: false, liveBubble: String(localized: "Typing “On my way”"), sessionID: "sample-1"),
                PinnedChannelItem(id: "sample-codex", name: "Codex", client: "Codex", isPoki: false, liveBubble: nil, sessionID: "sample-3"),
            ]
        }
        var result: [PinnedChannelItem] = [.poki]
        var seen: Set<String> = []
        for session in store.ordered where session.kind == .agent || session.kind == .handoff {
            let client = (session.client ?? session.name).trimmingCharacters(in: .whitespaces)
            guard !client.isEmpty, !seen.contains(client) else { continue }
            seen.insert(client)
            result.append(PinnedChannelItem(
                id: session.id,
                name: client,
                client: client,
                isPoki: false,
                liveBubble: session.live ? (session.lastLine.isEmpty ? String(localized: "Working…") : session.lastLine) : nil,
                sessionID: session.id
            ))
            if result.count == 3 { break }
        }
        return result
    }

    /// The sessions matching the search field: name, first message or last line.
    private var shown: [SavedSession] {
        if sampleHome == "paused" { return [] }
        let base = sampleHome == "sessions" ? Self.sampleSessions : store.ordered
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return base }
        return base.filter { [$0.name, $0.title, $0.lastLine, $0.client ?? ""].contains { $0.localizedCaseInsensitiveContains(q) } }
    }

    private func sampleStamp(for id: String) -> String? {
        guard sampleHome == "sessions" else { return nil }
        switch id {
        case "sample-1": return String(localized: "now")
        case "sample-2": return "12:23 PM"
        case "sample-3": return "11:22 AM"
        case "sample-4", "sample-5": return String(localized: "Yesterday")
        default: return nil
        }
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
                entries: [ChatEntry(.poki(String(localized: "Needs your OK: send “On my way” to Mom")))],
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

/// The orange pause badge at the bottom-right of the top-left Poki avatar (board "H2 Home paused").
struct PausedAvatarBadge: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(Color(hex: 0xFF9500))
                .frame(width: 16, height: 16)
                .overlay(Circle().strokeBorder(Color(.systemBackground), lineWidth: 2))
            HStack(spacing: 1.8) {
                RoundedRectangle(cornerRadius: 0.6).fill(.white).frame(width: 1.6, height: 6)
                RoundedRectangle(cornerRadius: 0.6).fill(.white).frame(width: 1.6, height: 6)
            }
        }
        .accessibilityHidden(true)
    }
}

struct PinnedChannelItem: Identifiable, Equatable {
    var id: String
    var name: String
    var client: String
    var isPoki: Bool
    var liveBubble: String?
    var sessionID: String?

    static let poki = PinnedChannelItem(id: "poki", name: "Poki", client: "Poki", isPoki: true, liveBubble: nil, sessionID: nil)
}

// Adapted from GetStream/swiftui-iMessage-clone (commit df114b4,
// iMessageClone/ChannelList/PinnedChannelsView.swift, by Stefan Blos).
struct PinnedChannelsView: View {
    var items: [PinnedChannelItem]
    var openChat: () -> Void
    var openSession: (String) -> Void

    let columnStructure = [
        GridItem(.flexible()),
        GridItem(.flexible()),
        GridItem(.flexible()),
    ]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items) { item in
                Button {
                    if item.isPoki {
                        openChat()
                    } else if let sessionID = item.sessionID {
                        openSession(sessionID)
                    }
                } label: {
                    VStack(spacing: 6) {
                        ZStack(alignment: .top) {
                            if item.isPoki {
                                PokiAvatar(size: 76)
                                    .shadow(color: Site.blue.opacity(0.20), radius: 5, y: 3)
                            } else {
                                AgentBadge(name: item.client, size: 76)
                                    .overlay {
                                        if item.liveBubble != nil {
                                            Circle()
                                                .strokeBorder(Color(.systemBackground), lineWidth: 3)
                                                .background(Circle().stroke(ChatColor.green, lineWidth: 5))
                                        }
                                    }
                            }
                            if let bubble = item.liveBubble {
                                HStack(spacing: 5) {
                                    Text(verbatim: bubble)
                                        .font(.system(size: 12))
                                        .foregroundStyle(Color(.label))
                                        .lineLimit(1)
                                    HStack(spacing: 2) {
                                        Circle().fill(Color(hex: 0x8E8E93)).frame(width: 4, height: 4)
                                        Circle().fill(Color(hex: 0xAEAEB2)).frame(width: 4, height: 4)
                                        Circle().fill(Color(hex: 0xC7C7CC)).frame(width: 4, height: 4)
                                    }
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(ChatColor.incoming, in: Capsule())
                                .shadow(color: .black.opacity(0.08), radius: 3, y: 2)
                                .fixedSize()
                                .offset(y: -24)
                            }
                        }
                        Text(verbatim: item.name)
                            .font(.system(size: 12))
                            .foregroundStyle(Color(hex: 0x6B6B70))
                            .lineLimit(1)
                    }
                    .frame(width: 100)
                }
                .buttonStyle(.plain)
                if items.count > 1, item.id != items.last?.id {
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 30)
        .padding(.bottom, 16)
        .padding(.horizontal, 12)
    }
}

// Adapted from GetStream/swiftui-iMessage-clone (commit df114b4,
// iMessageClone/ChannelList/iMessageChannelListItemView.swift, by Stefan Blos).
struct iMessageChannelListItemView: View {
    let session: SavedSession
    var stampOverride: String? = nil

    var lastMessageStamp: String {
        if let stampOverride { return stampOverride }
        return session.live ? String(localized: "now") : ChatTime.row(session.updated)
    }

    private var lastMessage: String {
        let line = session.lastLine
        if session.kind != .poki, line.isEmpty { return session.title }
        return line
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ZStack {
                if session.live {
                    Circle()
                        .fill(Site.blue)
                        .frame(width: 10, height: 10)
                }
            }
            .frame(width: 22)
            .padding(.top, 26)

            SessionAvatar(session: session, size: 50)
                .padding(.top, 8)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(verbatim: session.name)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color(.label))
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    Text(verbatim: lastMessageStamp)
                        .font(.system(size: 15))
                        .foregroundStyle(ChatColor.secondary)

                    Text(verbatim: "›")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color(hex: 0xC4C4C7))
                }

                HStack(alignment: .top, spacing: 4) {
                    outcomeMark
                    Text(verbatim: lastMessage)
                        .foregroundStyle(ChatColor.secondary)
                        .font(.system(size: 15))
                        .fixedSize(horizontal: false, vertical: true)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            .padding(.leading, 12)
            .padding(.top, 8)
            .padding(.bottom, 10)
            .overlay(alignment: .bottom) {
                ChatColor.separator.frame(height: 0.5)
            }
        }
        .padding(.trailing, 16)
        .background(Color(.systemBackground))
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var outcomeMark: some View {
        switch session.outcome {
        case .failed?:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(Color(.systemOrange))
                .padding(.top, 2)
        case .stopped?:
            Image(systemName: "pause.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(ChatColor.secondary)
                .padding(.top, 2)
        default:
            EmptyView()
        }
    }
}

/// Kept for compatibility with existing callers; wraps `iMessageChannelListItemView`.
struct SessionRow: View {
    var session: SavedSession
    var body: some View {
        iMessageChannelListItemView(session: session)
    }
}

extension View {
    /// The line under the title (iOS 26's navigation subtitle); nothing before iOS 26.
    @ViewBuilder func sessionSubtitle(_ text: String) -> some View {
        if #available(iOS 26.0, *), !text.isEmpty { navigationSubtitle(Text(verbatim: text)) } else { self }
    }
}

/// Poki's bear for its own chats; the agent's initial on its colour for an outside agent; both for a
/// hand-off.
struct SessionAvatar: View {
    var session: SavedSession
    var size: CGFloat

    var body: some View {
        switch session.kind {
        case .poki: PokiAvatar(size: size)
        case .voice:
            ZStack(alignment: .bottomTrailing) {
                PokiAvatar(size: size)
                Image(systemName: "waveform.circle.fill").font(.system(size: size * 0.42)).symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.blue).background(Circle().fill(Color(.systemBackground)).padding(-1.5))
                    .offset(x: 3, y: 3).accessibilityHidden(true)
            }
        case .agent: AgentBadge(name: session.client ?? "", size: size)
        case .handoff:
            ZStack(alignment: .bottomTrailing) {
                AgentBadge(name: session.client ?? "", size: size)
                PokiAvatar(size: size * 0.44).overlay(Circle().strokeBorder(Color(.systemBackground), lineWidth: 2))
                    .offset(x: 3, y: 3)
            }
        }
    }
}

/// An outside agent's badge: its provider's logo, or its initials (see `CallerBadge`).
struct AgentBadge: View {
    var name: String
    var size: CGFloat
    var body: some View { CallerBadge(name: name, size: size).accessibilityHidden(true) }
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
        ChatTranscript(entries: (AskPoki.live(id)?.entries ?? session?.entries) ?? [], typing: AskPoki.live(id)?.awaitingModel ?? false, canRetry: false, retry: {}) {
            if session?.live == true, let approval = model.approvals.first {
                ForegroundApprovalSection(
                    title: approval.summary,
                    subtitle: model.currentApp.map { String(localized: "\($0) · Poki acts only if you allow") } ?? String(localized: "Poki acts only if you allow"),
                    answer: { approved in model.resolve(approval, approved: approved) }
                )
            }
        }
        // Stop sits on the bottom edge as an inset, so the bubbles scroll under it and the bars keep
        // their scroll-edge behaviour (as in the chat).
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if AskPoki.live(id) != nil {
                Button("Stop Poki") { AskPoki.live(id)?.stop() }.buttonStyle(.bordered).tint(Color(.systemRed)).padding(.vertical, 10)
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
        case .agent: return String(localized: "Over MCP · \(ChatTime.row(session.started))")
        case .handoff: return String(localized: "Handed to Poki · \(ChatTime.row(session.started))")
        case .voice: return String(localized: "Voice · \(ChatTime.row(session.started))")
        case .poki: return ""
        }
    }
}

/// An approval waiting for the owner, in the chat and in the session that asked for it (ESP-174 board
/// "P1 Chat approval in app"; also in the Dynamic Island when Poki is in the background).
struct ApprovalCard: View {
    var title: String
    var subtitle: String
    var answer: (Bool) -> Void

    init(approval: PendingApproval, answer: @escaping (Bool) -> Void) {
        self.title = approval.summary
        self.subtitle = String(localized: "Poki acts only if you allow")
        self.answer = answer
    }

    init(title: String, subtitle: String, answer: @escaping (Bool) -> Void) {
        self.title = title
        self.subtitle = subtitle
        self.answer = answer
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                PokiAvatar(size: 30)
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color(.label))
                    Text(verbatim: subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(ChatColor.secondary)
                }
            }
            HStack(spacing: 8) {
                Button { answer(false) } label: {
                    Text("Don’t Allow")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color(.label))
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .background(ChatColor.incoming, in: Capsule())
                }
                .buttonStyle(.plain)
                Button { answer(true) } label: {
                    Text("Allow")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .background(Site.blue, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 14)
        .padding(.bottom, 12)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemBackground), in: .rect(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color(hex: 0xD1D1D6), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.10), radius: 9, y: 6)
        .padding(.top, 8)
    }
}
