import PokiCore
import SwiftUI

// The details screen opens from the header like iMessage's contact info (GetStream/swiftui-iMessage-clone,
// commit df114b4, iMessageClone/MessageList/View/Header/MessageListHeaderModifier.swift: a sheet from the
// header button). Its content is the ESP-174 board "D2 Poki details plus", with deeper settings layered
// behind "More Settings" according to the ESP-174 capability table.

/// Layer 1: Poki's picture, name and what it does; Pause, Voice and History; Accounts and Models;
/// Voice; and More Settings (which holds Setup, Updates, Memory, Approvals,
/// Agents and Relay, Notifications, and Diagnostics).
struct PokiDetailsView: View {
    @Environment(AppModel.self) private var model
    @Environment(ChatModel.self) private var chat
    @Environment(\.dismiss) private var dismiss
    var openVoice: () -> Void
    var openSetup: () -> Void
    /// Opens a run in Chats (from the Activity Log).
    var openSession: (String) -> Void = { _ in }
    @Binding var path: NavigationPath
    var inTab = false

    private var isSample: Bool { UserDefaults.standard.bool(forKey: "pokiDetailsSample") }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: 0) {
                    HStack {
                        Spacer()
                        Button("Done") { dismiss() }
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Site.blue)
                            .accessibilityIdentifier("details.done")
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 18)
                    .padding(.bottom, 4)

                    header
                    actions
                        .padding(.horizontal, 16)
                        .padding(.bottom, 22)

                    NavigationLink(value: DetailsRoute.model) { modelRow }
                        .buttonStyle(.plain)
                        .groupCard()
                        .padding(.horizontal, 16)
                        .padding(.bottom, 20)
                        .accessibilityIdentifier("details.accountsAndModels")

                    // On and off is the Turn On / Pause tile above (ESP-321): the Poki Is On switch here did
                    // the same, minus stopping the task and standing by.
                    VStack(spacing: 0) {
                        NavigationLink(value: DetailsRoute.voice) {
                            HStack {
                                Text("Voice")
                                    .font(.system(size: 17))
                                    .foregroundStyle(Color(.label))
                                Spacer()
                                Text(voiceSummary)
                                    .font(.system(size: 17))
                                    .foregroundStyle(ChatColor.secondary)
                            }
                            .padding(.vertical, 11)
                            .padding(.horizontal, 16)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("details.voice")
                    }
                    .groupCard()
                    .padding(.horizontal, 16)
                    .padding(.bottom, 20)

                    if !isSample {
                        let issues = Issue.current(model)
                        if !issues.isEmpty {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(issues.enumerated()), id: \.element.id) { index, issue in
                                    DetailsIssueRow(issue: issue, openSetup: { path.append(DetailsRoute.setup) })
                                        .padding(.vertical, 11)
                                        .padding(.horizontal, 16)
                                        .rowDivider(index + 1 < issues.count)
                                }
                            }
                            .groupCard()
                            .padding(.horizontal, 16)
                            .padding(.bottom, 20)
                            .accessibilityIdentifier("details.issues")
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        NavigationLink(value: DetailsRoute.moreSettings) {
                            HStack {
                                Text("More Settings")
                                    .font(.system(size: 17))
                                    .foregroundStyle(Color(.label))
                                Spacer()
                                Chevron()
                            }
                            .padding(.vertical, 11)
                            .padding(.horizontal, 16)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .groupCard()
                        .accessibilityIdentifier("details.moreSettings")

                        Text("Setup, updates, memory, approvals, agents and diagnostics.")
                            .font(.system(size: 13))
                            .foregroundStyle(Color(hex: 0x6D6D72))
                            .padding(.horizontal, 16)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 20)
                }
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: DetailsRoute.self) { route in
                switch route {
                case .model:
                    ModelSettingsView().toolbar(.visible, for: .navigationBar)
                case .history:
                    ActionLogView(openSession: { id in dismiss(); openSession(id) }).toolbar(.visible, for: .navigationBar)
                case .voice:
                    VoiceView(embedded: true).toolbar(.visible, for: .navigationBar)
                case .moreSettings:
                    MoreSettingsView(path: $path, openSetup: { path.append(DetailsRoute.setup) }).toolbar(.visible, for: .navigationBar)
                case .settings:
                    AgentsAndRelayView(path: $path).toolbar(.visible, for: .navigationBar)
                case .setup:
                    SetupLayer2View(path: $path)
                case .updates:
                    Form { SigningSection() }
                        .navigationTitle("Updates")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar(.visible, for: .navigationBar)
                case .approvals:
                    ApprovalsSettingsView().toolbar(.visible, for: .navigationBar)
                }
            }
            .navigationDestination(for: SetupStep.self) { SetupStepPage(step: $0).toolbar(.visible, for: .navigationBar) }
            .navigationDestination(for: SettingsRoute.self) { route in
                SettingsDestination(route: route, push: { path.append($0) }, pop: { if !path.isEmpty { path.removeLast() } })
                    .toolbar(.visible, for: .navigationBar)
            }
        }
    }

    private var header: some View {
        VStack(spacing: 6) {
            PokiAvatar(size: 96)
            Text(verbatim: "Poki")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(Color(.label))
            Text("Taps and types on this iPhone for you")
                .font(.system(size: 15))
                .foregroundStyle(ChatColor.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 20)
    }

    private var actions: some View {
        let active = model.sessionOn || model.wantsOn
        return HStack(spacing: 8) {
            if isSample || active || chat.running {
                ActionTile(title: "Pause", symbol: "pause.fill") {
                    chat.stop()
                    if model.sessionOn && !model.runnerPaused {
                        model.pauseRunner()
                    } else {
                        model.stopSession()
                    }
                }
            } else {
                ActionTile(title: "Turn On", symbol: "play.fill") {
                    model.startSession()
                }
            }
            ActionTile(title: "Voice", symbol: "mic.fill") { dismiss(); openVoice() }
            ActionTile(title: "History", symbol: "clock") { path.append(DetailsRoute.history) }
        }
    }

    private var modelRow: some View {
        let provider = ModelKeys.selectedProvider
        let hasKey = isSample || ModelKeys.hasKey(provider)
        return HStack(spacing: 12) {
            if isSample {
                Text(verbatim: "A")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Color(hex: 0xD97757), in: .rect(cornerRadius: 7, style: .continuous))
            } else {
                ProviderTile(provider: provider, size: 30)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text("Accounts and Models")
                    .font(.system(size: 17))
                    .foregroundStyle(Color(.label))
                Text(isSample
                     ? String(localized: "Claude Sonnet 5.5, your Anthropic key")
                     : (hasKey ? String(localized: "\(ModelKeys.selectedModelName), your \(provider.name) key") : String(localized: "Add an account to chat with Poki")))
                    .font(.system(size: 13))
                    .foregroundStyle(hasKey ? ChatColor.secondary : Color(.systemOrange))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Chevron()
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 16)
        .contentShape(.rect)
        .id(ModelKeys.saved)
    }

    private var voiceSummary: String {
        if isSample || VoiceDirect.apiKey != nil || VoiceBridge.saved != nil {
            return String(localized: "Live Voice") + " ›"
        }
        return String(localized: "Dictation Only") + " ›"
    }
}

enum DetailsRoute: Hashable {
    case model, history, voice, moreSettings, settings, setup, updates, approvals
}

// MARK: Layer 2 - More Settings

/// Layer 2 ("More Settings"): Setup, Updates, Memory, Approvals, Agents and Relay, Notifications, and Diagnostics.
struct MoreSettingsView: View {
    @Environment(AppModel.self) private var model
    @Binding var path: NavigationPath
    var openSetup: () -> Void

    var body: some View {
        @Bindable var model = model
        List {
            Section {
                NavigationLink(value: DetailsRoute.setup) {
                    let done = SetupStep.shown.filter(model.isDone).count
                    let total = SetupStep.shown.count
                    LabeledContent {
                        Text(model.setupComplete || done == total ? String(localized: "Done") : String(localized: "\(done) of \(total)"))
                            .foregroundStyle(model.setupComplete || done == total ? Color.secondary : Color.orange)
                    } label: {
                        Label("Setup", systemImage: "checklist")
                    }
                }
                .accessibilityIdentifier("moreSettings.setup")

                // Main's "Updates" (the version, a new build, signing until and Signing Options), by its own name.
                NavigationLink(value: DetailsRoute.updates) {
                    LabeledContent {
                        if model.signer.updateNotReady || model.signer.next?.kind == "update" {
                            Text("Update Available").foregroundStyle(Color.orange)
                        } else {
                            Text(verbatim: "\(model.signer.installedVersion) (\(model.signer.installedBuild))")
                                .foregroundStyle(Color.secondary)
                        }
                    } label: {
                        Label("Updates", systemImage: "arrow.down.circle")
                    }
                }
                .accessibilityIdentifier("moreSettings.updates")
            } header: {
                Text("This iPhone")
            }

            Section {
                NavigationLink(value: SettingsRoute.memory) {
                    LabeledContent {
                        Text("\(RoutineStore.shared.routines.count) routines")
                    } label: {
                        Label("Memory", systemImage: "brain")
                    }
                }
                .accessibilityIdentifier("moreSettings.memory")

                NavigationLink(value: DetailsRoute.approvals) {
                    LabeledContent {
                        Text(model.askBeforeSensitiveSteps ? String(localized: "Ask First") : String(localized: "Off"))
                    } label: {
                        Label("Approvals", systemImage: "hand.raised")
                    }
                }
                .accessibilityIdentifier("moreSettings.approvals")

                Toggle("Ask Before Sensitive Steps", isOn: $model.askBeforeSensitiveSteps)
                    .accessibilityIdentifier("moreSettings.askBeforeSensitiveSteps")
            } header: {
                Text("Behavior")
            } footer: {
                Text("Memory holds the routines and notes every agent shares. Approvals asks you before an agent pays, deletes, sends a message, places a call, types a password or does anything in Wallet.")
            }

            Section {
                NavigationLink(value: DetailsRoute.settings) {
                    LabeledContent {
                        Text(Health.relay(model).word)
                    } label: {
                        Label("Agents and Relay", systemImage: "point.3.connected.trianglepath.dotted")
                    }
                }
                .accessibilityIdentifier("moreSettings.agentsAndRelay")
            } header: {
                Text("External Agents")
            }

            Section {
                Button {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Label("Notifications", systemImage: "bell.badge")
                }
                .foregroundStyle(Color(.label))
                .accessibilityIdentifier("moreSettings.notifications")

                NavigationLink(value: SettingsRoute.diagnostics) {
                    Label("Diagnostics", systemImage: "stethoscope")
                }
                .accessibilityIdentifier("moreSettings.diagnostics")

                NavigationLink(value: SettingsRoute.log) {
                    Label("Log", systemImage: "doc.text")
                }
                .accessibilityIdentifier("moreSettings.log")

                NavigationLink { TestingOptionsView().toolbar(.visible, for: .navigationBar) } label: {
                    Label("Testing Options", systemImage: "testtube.2")
                }
                .accessibilityIdentifier("moreSettings.testingOptions")
            } header: {
                Text("Debugging")
            }

            // Main #143's Setup › Advanced › Typing: the Poki keyboard by default, Paste only when chosen.
            if model.automationPath == .nativeServices { TypingSettingsSection() }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("More Settings")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Approvals page in Layer 2/3.
struct ApprovalsSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Toggle("Ask Before Sensitive Steps", isOn: $model.askBeforeSensitiveSteps)
            } header: {
                Text("Approvals")
            } footer: {
                Text("Poki asks you before an agent pays, deletes, sends a message, places a call, types a password or does anything in Wallet: on the Live Activity, in a notification, or here in Poki. Turned off, agents do all of that without asking. Changes take effect the next time Poki opens.")
            }
        }
        .navigationTitle("Approvals")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Agents and Relay page in Layer 2/3: external agents list, add/revoke, QR code connector detail, and MCP relay switch & address.
struct AgentsAndRelayView: View {
    @Environment(AppModel.self) private var model
    @Binding var path: NavigationPath

    private var relayLine: String {
        if model.relayAddress == nil { return String(localized: "Set an address first") }
        if !model.relayEnabled { return String(localized: "Off: agents can’t reach this iPhone") }
        if !model.sessionOn { return String(localized: "Waiting for Poki: turn Poki on and agents can connect") }
        return Health.relay(model).word
    }

    var body: some View {
        @Bindable var model = model
        List {
            Section {
                ForEach(model.identity.secrets) { secret in
                    let last = SessionStore.shared.sessions(for: secret, among: model.identity.secrets).first
                    NavigationLink(value: SettingsRoute.connector(secret)) {
                        LabeledContent {
                            Text(last.map { ChatTime.row($0.updated) } ?? String(localized: "Not Used Yet"))
                        } label: {
                            Label {
                                Text(verbatim: secret.name)
                            } icon: {
                                if let client = secret.agent ?? last?.client {
                                    AgentBadge(name: client, size: 28)
                                } else {
                                    Image(systemName: "point.3.connected.trianglepath.dotted")
                                }
                            }
                        }
                    }
                    .swipeActions { Button("Revoke", role: .destructive) { model.revoke(secret) } }
                }
                Button(action: add) {
                    Label {
                        Text("Add Agent")
                    } icon: {
                        Image(systemName: "plus.circle.fill").foregroundStyle(.blue)
                    }
                }
                .disabled(model.relayAddress == nil)
            } header: {
                Text("External Agents")
            } footer: {
                Text(model.relayAddress == nil
                     ? "Set your relay first: each agent gets its own MCP address on it."
                     : "Each agent gets its own MCP address; add it as a remote MCP server in Claude, Codex or any MCP client. It takes the agent’s name and icon when the agent first connects, unless you renamed it. Swipe to revoke.")
            }

            Section {
                Toggle(isOn: Binding(get: { model.relayEnabled && model.relayAddress != nil }, set: { model.setRelayEnabled($0) })) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("MCP Relay")
                            Text(relayLine)
                                .font(.footnote).foregroundStyle(Color(.secondaryLabel))
                        }
                    } icon: {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                    }
                }
                .disabled(model.relayAddress == nil || !model.sessionOn)

                NavigationLink(value: SettingsRoute.relay) {
                    LabeledContent {
                        Text(model.relayAddress.map { $0.origin.host() ?? $0.origin.absoluteString } ?? String(localized: "Not Set"))
                            .foregroundStyle(model.relayAddress == nil ? Color.orange : Color.secondary)
                    } label: {
                        Label("Address", systemImage: "network")
                    }
                }
            } header: {
                Text("MCP Relay")
            } footer: {
                Text("The relay forwards agents’ requests to this iPhone while Poki is open or in the background. It stores nothing.")
            }

            if model.automationPath == .inProcess {
                Section {
                    Toggle("Hide Banner When Idle", isOn: $model.closeSessionWhenIdle)
                } header: {
                    Text("Automation")
                } footer: {
                    Text("Ends the automation session, and iOS’s banner with it, when the agent stops. Being tested: if the agent can’t see the screen after this, turn it off and open Poki again.")
                }
            }
            // Main's Runner section, where it was before the redesign (ESP-321 decision 3). The in-process
            // path has no Poki Runner to start or stop (ESP-152).
            if model.automationPath == .runner {
                Section {
                    LabeledContent("Runner", value: Health.runner(model).word)
                    Picker("Stop When Idle For", selection: $model.idleStopSeconds) {
                        ForEach(SettingsHome.idleChoices, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    if model.runnerPaused {
                        Button("Start Now") { model.wakeRunner() }
                    } else {
                        Button("Stop Runner", role: .destructive) { model.pauseRunner() }.disabled(!model.approvals.isEmpty)
                    }
                } header: {
                    Text("Runner")
                } footer: {
                    Text("iOS shows the automation banner only while the runner is active. Poki starts it when needed and stops it when idle. Don’t close Poki Runner while an agent is working.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Agents and Relay")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func add() {
        guard model.relayAddress != nil else { return }
        let secret = model.addConnector(name: "")
        path.append(SettingsRoute.connector(secret))
    }
}

// MARK: Layer 2 - Setup (ESP-174 board "S1 Setup layer 2")

/// Setup in Layer 2 (ESP-174 board "S1 Setup layer 2"): 5 items that tick themselves, Signing (optional,
/// Apple Account not needed), and Continue Setup. Each row navigates to its existing Layer 3 view.
struct SetupLayer2View: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Binding var path: NavigationPath
    @State private var guiding = false

    private var isSample: Bool { UserDefaults.standard.bool(forKey: "pokiSetupSample") }
    private var steps: [SetupStep] { SetupStep.shown }

    private func isStepDone(_ step: SetupStep) -> Bool {
        if isSample { return step != .automation }
        return model.isDone(step)
    }

    private var doneCount: Int {
        steps.filter(isStepDone).count
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    if !path.isEmpty { path.removeLast() } else { dismiss() }
                } label: {
                    Text("‹ More Settings")
                        .font(.system(size: 17))
                        .foregroundStyle(Site.blue)
                }
                .buttonStyle(.plain)
                .padding(.leading, 12)
                .padding(.trailing, 16)
                .padding(.top, 14)
                .padding(.bottom, 6)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Setup")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(Color(.label))
                    Text("\(doneCount) of \(steps.count) done. Each item ticks itself when the iPhone can check it.")
                        .font(.system(size: 15))
                        .foregroundStyle(ChatColor.secondary)
                }
                .padding(.leading, 20)
                .padding(.trailing, 16)
                .padding(.vertical, 6)

                VStack(spacing: 0) {
                    ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                        NavigationLink(value: step) {
                            HStack(spacing: 12) {
                                Image(systemName: step.symbol)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .frame(width: 29, height: 29)
                                    .background(tileColor(for: step), in: .rect(cornerRadius: 7, style: .continuous))

                                Text(step.rowTitle)
                                    .font(.system(size: 17))
                                    .foregroundStyle(Color(.label))
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                if isStepDone(step) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 22))
                                        .foregroundStyle(ChatColor.green)
                                } else {
                                    Text("Turn On ›")
                                        .font(.system(size: 17))
                                        .foregroundStyle(Site.blue)
                                }
                            }
                            .padding(.vertical, 12)
                            .padding(.horizontal, 16)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .rowDivider(index < steps.count - 1, leading: 57)
                    }
                    // Poki's own keyboard, which it types through on the native path (main #143).
                    if AutomationPath.current == .nativeServices {
                        NavigationLink { PokiKeyboardPage().toolbar(.visible, for: .navigationBar) } label: {
                            PokiKeyboardSetupRow()
                                .padding(.vertical, 12)
                                .padding(.horizontal, 16)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .overlay(alignment: .top) { ChatColor.separator.frame(height: 0.5).padding(.leading, 57) }
                        .accessibilityIdentifier("setup.pokiKeyboard")
                    }
                }
                .groupCard()
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 20)

                VStack(alignment: .leading, spacing: 6) {
                    Text("SIGNING · OPTIONAL")
                        .font(.system(size: 13))
                        .foregroundStyle(Color(hex: 0x6D6D72))
                        .padding(.horizontal, 16)

                    VStack(spacing: 0) {
                        HStack {
                            Text("Signed Until")
                                .font(.system(size: 17))
                                .foregroundStyle(Color(.label))
                            Spacer()
                            Text(signedUntilText)
                                .font(.system(size: 17))
                                .foregroundStyle(ChatColor.secondary)
                        }
                        .padding(.vertical, 11)
                        .padding(.horizontal, 16)
                        .rowDivider()

                        // The Apple Account lives in Signing Options, under Updates.
                        NavigationLink { SigningOptionsPage().toolbar(.visible, for: .navigationBar) } label: {
                            HStack {
                                Text("Apple Account")
                                    .font(.system(size: 17))
                                    .foregroundStyle(Color(.label))
                                Spacer()
                                Text(appleAccountText)
                                    .font(.system(size: 17))
                                    .foregroundStyle(ChatColor.secondary)
                            }
                            .padding(.vertical, 11)
                            .padding(.horizontal, 16)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                    .groupCard()

                    Text("Your Mac renews Poki’s signature. Sign in here only if you want this iPhone to renew it on its own.")
                        .font(.system(size: 13))
                        .foregroundStyle(Color(hex: 0x6D6D72))
                        .padding(.horizontal, 16)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 20)

                Button {
                    guiding = true
                } label: {
                    Text("Continue Setup")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(Site.blue, in: .rect(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { model.loopback.resume() }
        .sheet(isPresented: $guiding) {
            SetupGuide(start: SetupStep.shown.first { !model.isDone($0) })
        }
    }

    private func tileColor(for step: SetupStep) -> Color {
        switch step {
        case .developerMode: Color(hex: 0x8E8E93)
        case .loopback: Site.blue
        case .pairing: ChatColor.green
        case .automation: Color(hex: 0x5856D6)
        case .background: Color(hex: 0xFF9500)
        case .runner: Site.blue
        }
    }

    private var signedUntilText: String {
        if isSample { return "Nov 16" }
        if let expiry = model.signer.expiry {
            return expiry.formatted(.dateTime.month(.abbreviated).day())
        }
        return String(localized: "7 days")
    }

    private var appleAccountText: String {
        if isSample { return String(localized: "Not Needed") + " ›" }
        if let appleID = model.signer.status?.apple_id, !appleID.isEmpty {
            return appleID + " ›"
        }
        return String(localized: "Not Needed") + " ›"
    }
}

extension SetupStep {
    /// Short row title on the Setup Layer 2 page (ESP-174 board "S1 Setup layer 2").
    var rowTitle: LocalizedStringKey {
        switch self {
        case .developerMode: "Developer Mode"
        case .loopback: "Local Connection"
        case .pairing: "Pair This iPhone"
        case .automation: "UI Automation"
        case .background: "Stay On in Background"
        case .runner: "Poki Runner"
        }
    }
}

// MARK: Rows

/// A white group with 12 pt corners on the grouped grey (the boards' rows).
struct GroupCard: ViewModifier {
    func body(content: Content) -> some View {
        content.frame(maxWidth: .infinity).background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12, style: .continuous))
    }
}

extension View {
    func groupCard() -> some View { modifier(GroupCard()) }
    /// The 0.5 pt separator under a row, from the leading edge of the text.
    func rowDivider(_ show: Bool = true, leading: CGFloat = 16) -> some View {
        overlay(alignment: .bottom) {
            if show { ChatColor.separator.frame(height: 0.5).padding(.leading, leading) }
        }
    }
}

struct GroupedSection<Content: View>: View {
    var title: LocalizedStringKey
    var footer: LocalizedStringKey?
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 13)).foregroundStyle(Color(.secondaryLabel)).padding(.horizontal, 16)
            VStack(spacing: 0) { content }.groupCard()
            if let footer {
                Text(footer).font(.system(size: 13)).foregroundStyle(Color(.secondaryLabel)).padding(.horizontal, 16)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct Chevron: View {
    var body: some View { Text(verbatim: "›").font(.system(size: 17, weight: .semibold)).foregroundStyle(Color(.tertiaryLabel)) }
}

private struct DetailsIssueRow: View {
    @Environment(AppModel.self) private var model
    var issue: Issue
    var openSetup: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(issue.title, systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .symbolRenderingMode(.multicolor)
            Text(issue.text)
                .font(.subheadline)
                .foregroundStyle(Color(.secondaryLabel))
            if let button = issue.button {
                Button(button) { issue.act(model, openSetup: openSetup) }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Site.blue)
                    .buttonStyle(.borderless)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ActionTile: View {
    var title: LocalizedStringKey
    var symbol: String
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 18, weight: .medium)).frame(width: 22, height: 22)
                Text(title).font(.system(size: 12))
            }
            .foregroundStyle(Site.blue)
            .frame(maxWidth: .infinity).padding(.vertical, 12)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// The provider's letter on its coloured tile.
struct ProviderTile: View {
    var provider: ModelProvider
    var size: CGFloat = 29
    var body: some View {
        Group {
            if let logo = provider.logo {
                Image(logo).renderingMode(.template).resizable().scaledToFit().padding(size * 0.2)
            } else {
                Image(systemName: "server.rack").font(.system(size: size * 0.45, weight: .semibold))
            }
        }
        .foregroundStyle(.white)
        .frame(width: size, height: size)
        .background(Color(hex: provider.tile), in: .rect(cornerRadius: size * 0.225, style: .continuous))
        .accessibilityHidden(true)
    }
}

extension ModelProvider {
    /// The provider's own logo in the asset catalog (Poki/ProviderIcons).
    var logo: String? {
        switch self {
        case .anthropic: "Provider-anthropic"
        case .openai, .chatgpt: "Provider-openai"
        case .gemini: "Provider-googlegemini"
        case .deepseek: "Provider-deepseek"
        case .openrouter: "Provider-openrouter"
        case .opencodeGo: nil // Neutral server icon; do not borrow another provider's trademark.
        case .custom: nil
        }
    }
}
