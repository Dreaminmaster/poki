import PokiCore
import SwiftUI

// Settings (ESP-469; before it Poki's profile, ESP-326 board "09 Poki") opens from the bottom of the
// conversations and from the status card on Poki's picture. It replaced ESP-174's details screen and its
// "More Settings" layer. It now has the hierarchy of the redesign proposed in pull request 250,
// drawn with Poki's own rows: the card, then one row each for Connection, Models, Agents, Memory,
// Appearance and Language, and every other setting on a page under one of them (signing, approvals
// and the advanced pages under Connection, voice under Models). The rows and the card are
// PokiSettingsKit's.

/// Settings: Poki's card with what it is doing and Pause, Voice and Activity; any problem that keeps it
/// from working; then the parts of Poki and its look and language, each a row into its own page.
struct PokiDetailsView: View {
    @Environment(AppModel.self) private var model
    @Environment(ChatModel.self) private var chat
    @Environment(\.dismiss) private var dismiss
    var openVoice: () -> Void
    var openSetup: () -> Void
    /// Opens a run in the chat (from the Activity Log).
    var openSession: (String) -> Void = { _ in }
    @Binding var path: NavigationPath
    /// Bumped when the chosen model changes, so the Models row's value redraws (ModelKeys is not observable).
    @State private var modelVersion = 0

    private var isSample: Bool { UserDefaults.standard.bool(forKey: "pokiDetailsSample") }

    var body: some View {
        let power = isSample ? PowerTile.pause : PowerTile.card(model: model)
        let status = isSample ? PokiStatus(.ready) : PokiStatusCopy.card(PokiStatus.current(model: model, chat: chat), power: power)
        NavigationStack(path: $path) {
            List {
                Section {
                    PokiSettingsCard(status: status, power: power,
                                     act: { $0.act(model: model, chat: chat) },
                                     openConnection: { path.append(DetailsRoute.connection) },
                                     openVoice: { dismiss(); openVoice() },
                                     openActivity: { path.append(DetailsRoute.history) })
                }

                if !isSample {
                    let issues = Issue.current(model)
                    if !issues.isEmpty {
                        Section {
                            ForEach(issues) { issue in
                                DetailsIssueRow(issue: issue, openSetup: { path.append(DetailsRoute.connection) })
                            }
                        }
                        .accessibilityIdentifier("details.issues")
                    }
                }

                // One row for each part of Poki; every other setting is a page under one of them.
                Section {
                    NavigationLink(value: DetailsRoute.connection) {
                        SettingsRow(title: "Connection", symbol: "iphone.gen3", value: connectionValue, warns: !setupDone || updateWaits)
                    }
                    .accessibilityIdentifier("details.hands")
                    NavigationLink(value: DetailsRoute.model) {
                        SettingsRow(title: "Models", symbol: "sparkles", value: brainValue, warns: !hasModel)
                            .id(modelVersion)
                    }
                    .accessibilityIdentifier("details.accountsAndModels")
                    NavigationLink(value: DetailsRoute.agents) {
                        SettingsRow(title: "Agents", symbol: "chevron.left.forwardslash.chevron.right", value: agentsValue)
                    }
                    .accessibilityIdentifier("moreSettings.agentsAndRelay")
                    NavigationLink(value: SettingsRoute.memory) {
                        SettingsRow(title: "Memory", symbol: "bookmark", value: "\(isSample ? 10 : RoutineStore.shared.routines.count)")
                    }
                    .accessibilityIdentifier("moreSettings.memory")
                    NavigationLink(value: DetailsRoute.appearance) {
                        SettingsRow(title: "Appearance", symbol: "circle.lefthalf.filled", value: String(localized: appearance.title))
                    }
                    .accessibilityIdentifier("details.appearance")
                    NavigationLink(value: DetailsRoute.language) {
                        SettingsRow(title: "Language", symbol: "globe", value: LanguageView.name(AppLocalization.shared.preference))
                    }
                    .accessibilityIdentifier("general.language")
                } footer: {
                    Text(verbatim: "Poki \(model.signer.installedVersion) (\(model.signer.installedBuild))")
                        .monospacedDigit()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 12)
                }
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(16)
            .contentMargins(.top, 4, for: .scrollContent)
            .settingsPage()
            .navigationTitle(AppLocalization.text("Settings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                        .accessibilityIdentifier("details.done")
                }
            }
            // Every page under Settings takes the same ground and the same round icons.
            .navigationDestination(for: DetailsRoute.self) { route in
                Group { switch route {
                case .model:
                    ModelSettingsView()
                case .history:
                    ActionLogView(openSession: { id in dismiss(); openSession(id) })
                case .conversations:
                    ConversationsSettingsView(openSession: { id in dismiss(); openSession(id) })
                case .voice:
                    VoiceView(embedded: true)
                case .connection:
                    ConnectionView()
                case .advanced:
                    ConnectionAdvancedView()
                case .agents:
                    AgentsAndRelayView(path: $path)
                case .updates:
                    Form { SigningSection() }
                        .navigationTitle(AppLocalization.text("Signing & Updates"))
                        .navigationBarTitleDisplayMode(.inline)
                case .approvals:
                    ApprovalsSettingsView()
                case .appearance:
                    AppearanceView()
                case .language:
                    LanguageView()
                } }
                .settingsPage()
            }
            .navigationDestination(for: SetupStep.self) { SetupStepPage(step: $0) }
            .navigationDestination(for: SettingsRoute.self) { route in
                SettingsDestination(route: route, push: { path.append($0) }, pop: { if !path.isEmpty { path.removeLast() } })
                    .settingsPage()
            }
            .onReceive(NotificationCenter.default.publisher(for: ModelKeys.changed)) { _ in modelVersion += 1 }
        }
    }

    private var hasModel: Bool { isSample || ModelKeys.hasUsableKey }
    private var brainValue: String {
        if isSample { return "GPT-6.1 Terra" }
        return hasModel ? ModelKeys.selectedModelName : AppLocalization.text(LocalizedStringResource("Add"))
    }

    private var setupDone: Bool { isSample || model.setupComplete }
    private var updateWaits: Bool { !isSample && (model.signer.updateNotReady || model.signer.next?.kind == "update") }
    /// Setup first, then a waiting update (both under Connection), then whether Poki is on.
    private var connectionValue: String {
        if isSample { return AppLocalization.text(LocalizedStringResource("On")) }
        if !model.setupComplete {
            let steps = SetupStep.shown
            return AppLocalization.text(LocalizedStringResource("\(steps.filter(model.isDone).count) of \(steps.count)"))
        }
        if updateWaits { return AppLocalization.text(LocalizedStringResource("Update Available")) }
        if !model.sessionOn { return AppLocalization.text(LocalizedStringResource("Off")) }
        return model.ownerPaused ? AppLocalization.text(LocalizedStringResource("Paused")) : AppLocalization.text(LocalizedStringResource("On"))
    }

    private var agentsValue: String {
        if isSample { return AppLocalization.text(LocalizedStringResource("\(2) Connected")) }
        if model.relayAddress == nil || !model.relayEnabled { return AppLocalization.text(LocalizedStringResource("Off")) }
        if model.relayStatus.isOffline { return Health.relay(model).word }
        let count = model.identity.secrets.count
        return count == 0 ? AppLocalization.text(LocalizedStringResource("None yet")) : AppLocalization.text(LocalizedStringResource("\(count) Connected"))
    }

    @AppStorage(Appearance.key) private var appearanceChoice = Appearance.automatic.rawValue
    private var appearance: Appearance { Appearance(rawValue: appearanceChoice) ?? .automatic }
}

enum DetailsRoute: Hashable {
    case model, history, conversations, voice, connection, advanced, agents, updates, approvals, appearance, language
}

/// Settings > Conversations: the archived conversations, each one line as in the drawer, to open, bring
/// back or delete; and a search through every conversation, archived or not.
private struct ConversationsSettingsView: View {
    var openSession: (String) -> Void
    @State private var query = ""
    private var store: SessionStore { SessionStore.shared }

    private var matches: [SavedSession] {
        let words = query.trimmingCharacters(in: .whitespaces)
        return store.ordered.filter { session in
            [session.name, session.title, session.lastLine, session.client ?? ""].contains { $0.localizedCaseInsensitiveContains(words) }
        }
    }

    var body: some View {
        List {
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                let archived = store.archivedSessions
                Section {
                    ForEach(archived) { session in
                        Button { openSession(session.id) } label: {
                            ConversationTitle(session: session)
                                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button("Delete", systemImage: "trash", role: .destructive) { store.delete(session.id) }
                            Button("Unarchive", systemImage: "tray.and.arrow.up") { store.unarchive(session.id) }.tint(Tint.blue)
                        }
                        .contextMenu {
                            Button("Unarchive", systemImage: "tray.and.arrow.up") { store.unarchive(session.id) }
                            Button("Delete", systemImage: "trash", role: .destructive) { store.delete(session.id) }
                        }
                        .accessibilityIdentifier("archived.row")
                    }
                } header: {
                    Text("Archived Conversations").textCase(nil)
                }
                if archived.isEmpty {
                    ContentUnavailableView("No Archived Conversations", systemImage: "archivebox",
                                           description: Text("Conversations you archive appear here."))
                        .listRowBackground(Color.clear)
                }
            } else {
                ForEach(matches) { session in
                    Button { openSession(session.id) } label: {
                        HStack(spacing: 12) {
                            SessionAvatar(session: session, size: 36)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: session.name).foregroundStyle(Color(.label))
                                Text(verbatim: session.lastLine).font(.subheadline)
                                    .foregroundStyle(Color(.secondaryLabel)).lineLimit(2)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
                if matches.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
        }
        .navigationTitle(AppLocalization.text("Conversations"))
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: Text("Search"))
    }
}

// MARK: The card

/// Poki on the settings home (ESP-469 board "01 设置首页"): the bear's face, the name and where Poki
/// stands, which opens Connection, then Pause (or Resume, or Turn On), Voice and Activity, what you
/// reach for most.
private struct PokiSettingsCard: View {
    var status: PokiStatus
    var power: PowerTile
    var act: (PowerTile) -> Void
    var openConnection: () -> Void
    var openVoice: () -> Void
    var openActivity: () -> Void
    @ScaledMetric(relativeTo: .title2) private var face = 64.0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button(action: openConnection) { header }
                .buttonStyle(PressedDimStyle())
                .accessibilityIdentifier("details.status")
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { pills }
                VStack(spacing: 8) { pills }
            }
        }
        .padding(.vertical, 10)
        .animation(.easeInOut(duration: 0.3), value: status.mood)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Group {
                if let image = PokiMood.cutout(status.mood, small: true) {
                    Image(uiImage: image).resizable().interpolation(.high).scaledToFit()
                }
            }
            .frame(width: face, height: face)
            .background(status.mood == .paused ? Tint.night : Tint.portrait, in: .circle)
            .clipShape(.circle)
            .overlay(Circle().strokeBorder(Tint.ring, lineWidth: 1))
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: "Poki").font(Prominent.font(.title2, .bold)).foregroundStyle(Color(.label))
                    .accessibilityAddTraits(.isHeader)
                HStack(spacing: 6) {
                    Circle().fill(status.mood.dot).frame(width: 7, height: 7)
                    Text(verbatim: PokiStatusCopy.word(status)).lineLimit(1)
                }
                .font(.subheadline).foregroundStyle(Color(.secondaryLabel))
                .accessibilityElement(children: .combine)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Color(.tertiaryLabel))
                .accessibilityHidden(true)
        }
        .contentShape(.rect)
    }

    @ViewBuilder private var pills: some View {
        SettingsPill(title: power.title, symbol: power.symbol, prominent: true) { act(power) }
            .accessibilityIdentifier("details.\(power.name)")
        SettingsPill(title: "Voice", symbol: "waveform", action: openVoice)
        SettingsPill(title: "Activity", symbol: "clock", action: openActivity)
            .accessibilityIdentifier("details.activity")
    }
}

/// A plain button that dims while pressed, for tiles that draw their own surface.
struct PressedDimStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: Connection

/// Connection: whether Poki may act on this iPhone, each thing the phone needs for it (the setup items,
/// each opening its own page), what Poki asks about first, signing and updates, the advanced pages, and
/// turning Poki off altogether.
struct ConnectionView: View {
    @Environment(AppModel.self) private var model
    @Environment(ChatModel.self) private var chat
    @State private var guiding = false

    private var on: Bool { model.sessionOn && !model.ownerPaused }
    private var updateWaits: Bool { model.signer.updateNotReady || model.signer.next?.kind == "update" }

    var body: some View {
        List {
            Section {
                Toggle(isOn: Binding(get: { on }, set: set)) {
                    SettingsLabel("Automation", systemImage: "hand.tap")
                }
                .accessibilityIdentifier("hands.on")
            } footer: {
                // Paused is not a lock: an agent's request, or a task you send, starts Poki again.
                Text(on ? "Poki can tap, type, and scroll on this iPhone."
                     : model.sessionOn ? "Poki is paused. It resumes automatically upon a new task or agent request."
                     : "Poki is off. Agents can’t reach this iPhone.")
            }

            Section {
                ForEach(SetupStep.shown) { step in
                    NavigationLink(value: step) {
                        LabeledContent {
                            if model.isDone(step) {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(ChatColor.green)
                                    .accessibilityLabel(Text("Done"))
                            } else {
                                Text("Turn On").foregroundStyle(Tint.amberInk)
                            }
                        } label: {
                            SettingsLabel(step.rowTitle, systemImage: step.symbol)
                        }
                    }
                }
                Button(model.setupComplete ? "Set Up Again" : "Continue Setup") { guiding = true }
                    .foregroundStyle(Tint.blueText)
                    .accessibilityIdentifier("moreSettings.setup")
                FirstRunAgain()
            } header: {
                Text("This iPhone")
            } footer: {
                Text("Poki uses Apple’s developer tools on this iPhone. Keep all of these on.")
            }

            Section {
                NavigationLink(value: DetailsRoute.approvals) {
                    LabeledContent(content: { Text(model.approvalMode.title) }, label: { SettingsLabel("Approvals", systemImage: "checkmark.shield") })
                }
                .accessibilityIdentifier("moreSettings.approvals")
                NavigationLink(value: DetailsRoute.updates) {
                    LabeledContent {
                        if updateWaits {
                            Text("Update Available").foregroundStyle(Tint.amberInk)
                        } else {
                            Text(verbatim: "\(model.signer.installedVersion) (\(model.signer.installedBuild))")
                        }
                    } label: {
                        SettingsLabel("Signing & Updates", systemImage: "signature")
                    }
                }
                .accessibilityIdentifier("moreSettings.updates")
                NavigationLink(value: DetailsRoute.advanced) {
                    SettingsLabel("Advanced", systemImage: "slider.horizontal.3")
                }
                .accessibilityIdentifier("details.health")
            }

            // The off side of main's Poki switch: resting only stands by, this ends the session and the relay.
            if model.sessionOn {
                Section {
                    Button("Turn Off Poki", role: .destructive) { chat.stop(); model.stopSession() }
                        .accessibilityIdentifier("details.turnOff")
                } footer: {
                    Text("Ends the session and disconnects agents until you turn Poki on again.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(16)
        .navigationTitle(AppLocalization.text("Connection"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { model.loopback.resume() }
        .sheet(isPresented: $guiding) {
            SetupGuide(start: SetupStep.shown.first { !model.isDone($0) })
        }
    }

    private func set(_ on: Bool) {
        if !on {
            chat.stop()
            model.pauseByOwner()
        } else if model.sessionOn {
            model.wakeRunner()
        } else {
            model.startSession()
        }
    }
}

// MARK: Advanced

/// Connection › Advanced: how the automation banner or the runner behaves, notifications, and the tools
/// under the hood (diagnostics, the log, testing options).
struct ConnectionAdvancedView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List {
            if model.automationPath == .inProcess {
                Section {
                    Toggle(isOn: $model.closeSessionWhenIdle) { SettingsLabel("Hide Banner When Idle", systemImage: "rectangle.on.rectangle.slash") }
                } header: {
                    Text("Automation Banner")
                } footer: {
                    Text("Ends the automation session, and iOS’s banner with it, when the agent stops. Being tested. If the agent can’t see the screen after this, turn it off and open Poki again.")
                }
            }
            // Main's Runner section. The in-process path has no Poki Runner to start or stop (ESP-152).
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

            Section {
                Button {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    LabeledContent {
                        Image(systemName: "arrow.up.forward").font(.footnote.weight(.semibold)).foregroundStyle(Color(.tertiaryLabel))
                    } label: {
                        SettingsLabel("Notifications", systemImage: "bell.badge")
                    }
                }
                .foregroundStyle(Color(.label))
                .accessibilityIdentifier("moreSettings.notifications")
            }

            Section {
                NavigationLink(value: SettingsRoute.diagnostics) {
                    SettingsLabel("Diagnostics", systemImage: "stethoscope")
                }
                .accessibilityIdentifier("moreSettings.diagnostics")

                NavigationLink(value: SettingsRoute.log) {
                    SettingsLabel("Log", systemImage: "doc.text")
                }
                .accessibilityIdentifier("moreSettings.log")

                NavigationLink { TestingOptionsView().settingsPage() } label: {
                    SettingsLabel("Testing Options", systemImage: "testtube.2")
                }
                .accessibilityIdentifier("moreSettings.testingOptions")
            } header: {
                Text("Debugging")
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(16)
        .navigationTitle(AppLocalization.text("Advanced"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: Appearance

/// The app's light or dark look, or the iPhone's own (`PokiApp` applies it to every window).
enum Appearance: String, CaseIterable, Identifiable {
    case automatic = "", light, dark
    static let key = "appearance"

    var id: String { rawValue }
    var title: LocalizedStringResource {
        switch self {
        case .automatic: "Automatic"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
    var style: UIUserInterfaceStyle {
        switch self {
        case .automatic: .unspecified
        case .light: .light
        case .dark: .dark
        }
    }
}

/// Settings › Appearance: Automatic, Light or Dark.
struct AppearanceView: View {
    @AppStorage(Appearance.key) private var choice = Appearance.automatic.rawValue

    var body: some View {
        List {
            Section {
                ForEach(Appearance.allCases) { option in
                    Button { choice = option.rawValue } label: {
                        HStack {
                            Text(option.title).foregroundStyle(Color(.label))
                            Spacer()
                            if option.rawValue == choice {
                                Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Tint.blueText)
                            }
                        }
                        .contentShape(.rect)
                    }
                    .accessibilityAddTraits(option.rawValue == choice ? .isSelected : [])
                    .accessibilityIdentifier("appearance.\(option == .automatic ? "automatic" : option.rawValue)")
                }
            } footer: {
                Text("Automatic follows the iPhone’s appearance setting.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: Language

/// Settings › Language: Follow System, or one of the languages Poki carries, each under its own name.
/// The choice changes Poki's own screens at once (`AppLocalization`).
struct LanguageView: View {
    /// A language under its own name ("繁體中文"), or Follow System in the language now shown.
    static func name(_ preference: String) -> String {
        if preference == AppLocalization.system { return AppLocalization.text("Follow System") }
        return Locale(identifier: preference).localizedString(forIdentifier: preference) ?? preference
    }

    var body: some View {
        let chosen = AppLocalization.shared.preference
        List {
            Section {
                ForEach([AppLocalization.system] + AppLocalization.languages, id: \.self) { option in
                    Button { AppLocalization.shared.preference = option } label: {
                        HStack {
                            Text(verbatim: Self.name(option)).foregroundStyle(Color(.label))
                            Spacer()
                            if option == chosen {
                                Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Tint.blueText)
                            }
                        }
                        .contentShape(.rect)
                    }
                    .accessibilityAddTraits(option == chosen ? .isSelected : [])
                    .accessibilityIdentifier("language.\(option)")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(AppLocalization.text("Language"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Approvals (ESP-469 board "03 审批"): what always needs you, how Poki asks before a sensitive step, and
/// how much your chat model may approve by itself. The way of asking is chosen on Poki's card only (the
/// owner: one setting in one place); this page says which is in use and what it does. The sensitivity's
/// four levels are segments in their own order, least asking first.
struct ApprovalsSettingsView: View {
    @Environment(AppModel.self) private var model
    /// The way of asking says itself in one line; Learn More opens the whole of it.
    @State private var more = false

    var body: some View {
        @Bindable var model = model
        List {
            Section {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "lock.fill").foregroundStyle(Tint.amberInk).accessibilityHidden(true)
                    Text("Payments, deletions and actions in Wallet always need your confirmation.")
                        .font(.subheadline.weight(.medium)).foregroundStyle(Tint.amberInk)
                }
                .padding(.vertical, 4)
                .listRowBackground(Tint.amberSoft)
            }

            Section {
                LabeledContent("Approval Method", value: model.approvalMode.title)
                    .accessibilityIdentifier("approvals.mode.current")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Change it on Poki’s card: tap Poki’s picture at the top of the chat.")
                    switch model.approvalMode {
                    case .reply: Text("Poki asks in the chat and proceeds after you reply.")
                    case .confirm: Text("Tap Allow or Don’t Allow in the Live Activity, a notification, or Poki.")
                    case .off: Text("Optional steps run automatically without asking.")
                    }
                    if more {
                        switch model.approvalMode {
                        case .reply: Text("With Message Reply, Poki asks you in the chat and your yes lets the step through. Away from Poki you can answer from the notification. Outside agents have no chat, so their steps ask with Allow and Don’t Allow.")
                        case .confirm: Text("With Confirmation, you tap Allow or Don’t Allow on the Live Activity, in a notification, or here in Poki.")
                        case .off: Text("Optional steps continue without asking. Payments, deletions and actions in Wallet still need your confirmation.")
                        }
                        Text("Sensitive steps are paying, deleting, sending a message, placing a call, typing a password and anything in Wallet.")
                        Text("Changes apply right away, starting from Poki’s next step.")
                    } else {
                        Button("Learn More") { withAnimation(.snappy) { more = true } }
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Tint.blueText)
                            .buttonStyle(.borderless)
                            .padding(.top, 2)
                            .accessibilityIdentifier("approvals.learnMore")
                    }
                }
            }
            .accessibilityIdentifier("approvals.mode")

            if model.approvalMode != .off {
                Section {
                    Picker("Sensitivity", selection: $model.classifierLevel) {
                        ForEach(ApprovalClassifier.Level.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    .accessibilityIdentifier("approvals.sensitivity")
                } header: {
                    Text("Sensitivity").textCase(nil)
                } footer: {
                    switch model.classifierLevel {
                    case .permissive: Text("Permissive. Your chat model approves a step in Poki’s own chat unless it clearly has nothing to do with what you asked, or you said no.")
                    case .balanced: Text("Balanced. Your chat model approves a step in Poki’s own chat when it directly serves what you asked for. You are asked about the rest.")
                    case .strict: Text("Strict. Your chat model approves a step in Poki’s own chat only when you asked for that exact action. You are asked about the rest.")
                    case .everything: Text("Ask All. Nothing is approved automatically. Each request needs your answer.")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(16)
        .navigationTitle(AppLocalization.text("Approvals"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Agents: the MCP relay outside agents come through (its switch and address), then the agents that control
/// this iPhone through Poki (list, add, revoke, each one's QR code and address).
struct AgentsAndRelayView: View {
    @Environment(AppModel.self) private var model
    @Binding var path: NavigationPath

    private var relayLine: String {
        if model.relayAddress == nil { return AppLocalization.text(LocalizedStringResource("Set an address first")) }
        if !model.relayEnabled { return AppLocalization.text(LocalizedStringResource("Off, agents can’t reach this iPhone")) }
        if !model.sessionOn { return AppLocalization.text(LocalizedStringResource("Waiting for Poki, turn Poki on and agents can connect")) }
        return Health.relay(model).word
    }

    var body: some View {
        @Bindable var model = model
        List {
            Section {
                Toggle(isOn: Binding(get: { model.relayEnabled && model.relayAddress != nil }, set: { model.setRelayEnabled($0) })) {
                    SettingsLabel {
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
                        Text(model.relayAddress.map { $0.origin.host() ?? $0.origin.absoluteString } ?? AppLocalization.text(LocalizedStringResource("Not Set")))
                            .foregroundStyle(model.relayAddress == nil ? Color.orange : Color.secondary)
                    } label: {
                        SettingsLabel("Address", systemImage: "network")
                    }
                }
            } header: {
                Text("MCP Relay")
            } footer: {
                Text("The relay forwards agents’ requests to this iPhone while Poki is open or in the background. It stores nothing.")
            }

            Section {
                ForEach(model.identity.secrets) { secret in
                    let last = SessionStore.shared.sessions(for: secret, among: model.identity.secrets).first
                    NavigationLink(value: SettingsRoute.connector(secret)) {
                        LabeledContent {
                            Text(last.map { ChatTime.row($0.updated) } ?? AppLocalization.text(LocalizedStringResource("Not Used Yet")))
                        } label: {
                            // An agent's own badge is its picture; only the generic symbol takes the round ground.
                            if let client = secret.agent ?? last?.client {
                                HStack(spacing: 12) {
                                    AgentBadge(name: client, size: 30)
                                    Text(verbatim: secret.name)
                                }
                            } else {
                                SettingsLabel { Text(verbatim: secret.name) } icon: { Image(systemName: "point.3.connected.trianglepath.dotted") }
                            }
                        }
                    }
                    .swipeActions { Button("Revoke", role: .destructive) { model.revoke(secret) } }
                    // 752's Agents and Relay had it too: a long press revokes.
                    .contextMenu { Button("Revoke Access", systemImage: "xmark.circle", role: .destructive) { model.revoke(secret) } }
                }
                Button(action: add) {
                    SettingsLabel { Text("Add Agent") } icon: { Image(systemName: "plus") }
                }
                .disabled(model.relayAddress == nil)
            } header: {
                Text("Agents")
            } footer: {
                Text(model.relayAddress == nil
                     ? "Set your relay first. Each agent gets its own MCP address on it."
                     : "Each agent gets its own MCP address. Add it as a remote MCP server in Claude, Codex or any MCP client. It takes the agent’s name and icon when the agent first connects, unless you renamed it. Swipe to revoke.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(AppLocalization.text("Agents"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func add() {
        guard model.relayAddress != nil else { return }
        let secret = model.addConnector(name: "")
        path.append(SettingsRoute.connector(secret))
    }
}

extension SetupStep {
    /// Short row title on Connection's list of what this iPhone needs.
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

/// The first tile on Poki's details: main's Pause and Resume pair, and Turn On while Poki is off.
/// Standing by (right after Turn On, or after the idle minute) is Resume, as on main.
enum PowerTile: Equatable {
    case pause, resume, turnOn

    @MainActor init(model: AppModel, running: Bool) {
        if model.sessionOn && !model.runnerPaused || running { self = .pause }
        else if model.sessionOn { self = .resume }
        else { self = .turnOn }
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
        .background(Color(hex: provider.tile), in: .circle)
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
        case .custom: nil
        }
    }
}
