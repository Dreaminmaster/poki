import AVFoundation
import Speech
import SwiftUI
import UserNotifications

/// Everything Poki can be set up with, as one list (the owner, Nov 21 2026: one checklist in two
/// forms). The start flow walks it one page each (`StartRoute`); the Setup page in Settings and the
/// guide's last page show it as sections (`SetupSections`), the iPhone's steps folded into one card.
enum SetupItem: Hashable {
    case step(SetupStep)
    /// The Poki Loopback Shortcut, right after the loopback.
    case shortcut
    case models
    /// Screen History, Memory, Dictation, Notifications and Agents, all optional.
    case features

    static var all: [SetupItem] {
        SetupStep.shown.flatMap { $0 == .loopback ? [SetupItem.step($0), .shortcut] : [SetupItem.step($0)] }
            + [.models, .features]
    }

    /// Still to do: Guide Me starts at the first of these. The features are optional, never open.
    @MainActor func isOpen(_ model: AppModel) -> Bool {
        switch self {
        case .step(let step): !model.stepReadyForUse(step)
        case .shortcut: !HistoryReconnect.shared.isSetUp
        case .models: !ModelKeys.hasUsableKey
        case .features: false
        }
    }

    @MainActor static func firstOpen(_ model: AppModel) -> SetupItem? { all.first { $0.isOpen(model) } }
}

/// The setup list's sections, one copy for the Setup page and the guide's last page: the iPhone's
/// steps in one foldable card, the Poki Loopback Shortcut, Models, Features and Agents. The rows open
/// Settings' own pages, so nothing here is a second copy of them.
struct SetupSections: View {
    @Environment(AppModel.self) private var model
    @Binding var path: NavigationPath
    /// On the Setup page: Guide Me under the card, which walks the list one page at a time.
    var guideMe = false

    @State private var hasModel = ModelKeys.hasUsableKey
    @State private var modelName = ModelKeys.selectedModelName
    /// Nil until the card is opened or closed by hand: open while a step is missing, closed once all are done.
    @State private var stepsOpen: Bool?

    /// The first of this iPhone's steps still open.
    private var nextStep: SetupStep? { SetupStep.shown.first { !model.stepReadyForUse($0) } }

    var body: some View {
        Section {
            DisclosureGroup(isExpanded: Binding(get: { stepsOpen ?? (nextStep != nil) }, set: { stepsOpen = $0 })) {
                ForEach(SetupStep.shown) { step in
                    NavigationLink(value: step) { stepRow(step) }
                        .accessibilityIdentifier("firstRun.step.\(step.rawValue)")
                }
            } label: {
                stepsRow
            }
            .accessibilityIdentifier("setup.steps")
            if guideMe { SetupGuideMe() }
        } footer: {
            Group {
                Text("Each one is turned on once. They tick themselves as you go.")
            }
            .settingsFooter()
        }

        WelcomeCellularSection()

        Section {
            NavigationLink(value: DetailsRoute.model) {
                SettingsRow(title: "Accounts", caption: hasModel ? nil : "Sign in or add a key",
                            symbol: "sparkles", value: hasModel ? modelName : nil,
                            accessory: hasModel ? .done : nil)
            }
            .accessibilityIdentifier("firstRun.models")
            WelcomeLocalModels()
        } header: {
            Group {
                SettingsHeader("Models")
            }
            .settingsHeader()
        } footer: {
            Group {
                Text("Poki thinks with a model from your own account. Local models run on this iPhone and keep what they read on it.")
            }
            .settingsFooter()
        }

        WelcomeFeaturesSection(openSenses: { path.append(DetailsRoute.screenHistory) })

        Section {
            NavigationLink(value: DetailsRoute.agents) {
                SettingsRow(title: "Agents", symbol: "chevron.left.forwardslash.chevron.right")
            }
            .accessibilityIdentifier("firstRun.agents")
            .onReceive(NotificationCenter.default.publisher(for: ModelKeys.changed)) { _ in refresh() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in refresh() }
            .onAppear(perform: refresh)
        } header: {
            Group {
                SettingsHeader("Connections")
            }
            .settingsHeader()
        } footer: {
            Group {
                Text("Let Claude, ChatGPT and other agents use this iPhone")
            }
            .settingsFooter()
        }
    }

    /// The card's own row: how many of the steps are done.
    private var stepsRow: some View {
        let steps = SetupStep.shown
        let done = steps.filter(model.stepReadyForUse).count
        return SettingsRow(title: "Required Steps", symbol: "iphone.gen3",
                           value: AppLocalization.text(LocalizedStringResource("\(done) of \(steps.count) Done")),
                           warns: done < steps.count)
    }

    private func stepRow(_ step: SetupStep) -> some View {
        let done = model.stepReadyForUse(step)
        // The names the Setup page lists them by, so a step has one name wherever it shows.
        return SettingsRow(title: step.rowTitle, symbol: step.symbol,
                           value: done ? nil : nextStep == step ? AppLocalization.text(LocalizedStringResource("Next")) : nil,
                           warns: !done && nextStep == step, accessory: done ? .done : nil)
    }

    private func refresh() {
        hasModel = ModelKeys.hasUsableKey
        modelName = ModelKeys.selectedModelName
    }
}

/// Guide Me: the start flow over everything, opened at the first item still open (at the first page
/// once all are done), with the pages before it behind Back.
struct SetupGuideMe: View {
    @Environment(AppModel.self) private var model
    @State private var start: [StartRoute]?

    var body: some View {
        Button {
            let order = StartRoute.order
            let open = SetupItem.firstOpen(model).flatMap { order.firstIndex(of: .item($0)) } ?? 0
            start = Array(order[...open])
        } label: {
            SettingsRow(title: "Guide Me", symbol: "signpost.right").contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("setup.guideMe")
        .fullScreenCover(isPresented: Binding(get: { start != nil }, set: { if !$0 { start = nil } })) {
            FirstRunGuide(replay: true, startAt: start ?? [], link: .constant(nil), done: { start = nil })
        }
    }
}

/// The guide's last page: the setup list itself, with the button at the bottom going to the next
/// item still open.
struct WelcomePanel: View {
    @Environment(AppModel.self) private var model
    var kind: FirstRun.Kind
    @Binding var path: NavigationPath
    var finish: () -> Void

    @State private var hasModel = ModelKeys.hasUsableKey

    static var voiceAllowedNow: Bool {
        AVAudioApplication.shared.recordPermission == .granted && SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    /// The first of this iPhone's steps still open, numbered from one.
    private var nextStep: (number: Int, step: SetupStep)? {
        SetupStep.shown.enumerated().first { !model.stepReadyForUse($0.element) }.map { ($0.offset + 1, $0.element) }
    }

    var body: some View {
        List {
            SetupSections(path: $path)
        }
        .settingsPage()
        .navigationTitle(kind == .firstRun ? AppLocalization.text("Set Up Poki") : AppLocalization.text("Check Setup"))
        // A safe-area bar on iOS 26, so the rows fade under the buttons through the system's scroll
        // edge instead of showing through them (the footer's words ran into Finish Later).
        .bottomBar(softEdge: true) { buttons }
        .onAppear { model.loopback.resume() }
        .onChange(of: path.count) { _, _ in hasModel = ModelKeys.hasUsableKey }
        .onReceive(NotificationCenter.default.publisher(for: ModelKeys.changed)) { _ in hasModel = ModelKeys.hasUsableKey }
    }

    // MARK: The buttons

    private var buttons: some View {
        StartButtons(primary: primaryWord, action: primary,
                     secondary: nextStep != nil || !hasModel ? (kind == .firstRun ? "Finish Later" : "Not Now") : nil,
                     secondaryAction: finish)
    }

    private var primaryWord: LocalizedStringKey {
        if let nextStep { return "Continue with Step \(nextStep.number)" }
        if !hasModel { return "Add an Account" }
        return "Start Using Poki"
    }

    private func primary() {
        if let nextStep {
            path.append(nextStep.step)
        } else if !hasModel {
            path.append(DetailsRoute.model)
        } else {
            finish()
        }
    }
}

/// What Poki can do beyond the iPhone's steps, all optional: Screen History, Memory, and the two
/// permissions asked here (dictation, notifications). On the welcome's list and as a start flow page.
struct WelcomeFeaturesSection: View {
    /// On its own start flow page, whose title and line already say what the header and footer do.
    var onItsPage = false
    /// Opens Senses on the page's navigation path.
    var openSenses: () -> Void
    @State private var voiceAllowed = WelcomePanel.voiceAllowedNow
    @State private var notices = UNAuthorizationStatus.notDetermined

    var body: some View {
        Section {
            WelcomeSensesRow(open: openSenses)
            NavigationLink(value: SettingsRoute.memory) {
                SettingsRow(title: "Memory", caption: "What Poki keeps about you and your apps", symbol: "bookmark")
            }
            .accessibilityIdentifier("firstRun.memory")
            Button(action: allowVoice) {
                SettingsRow(title: "Dictation", caption: "Talk instead of typing", symbol: "mic",
                            value: voiceAllowed ? nil : AppLocalization.text(LocalizedStringResource("Allow")),
                            valueIsAction: true, accessory: voiceAllowed ? .done : nil)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("firstRun.voice")
            Button(action: allowNotices) {
                SettingsRow(title: "Notifications", caption: "Approvals and finished tasks", symbol: "bell.badge",
                            value: noticesValue, valueIsAction: notices == .notDetermined,
                            accessory: noticesAllowed ? .done : notices == .denied ? .leaves : nil)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("firstRun.notifications")
        } header: {
            if !onItsPage {
                Group {
                    SettingsHeader("Features")
                }
                .settingsHeader()
            }
        } footer: {
            if !onItsPage {
                Group {
                    Text("All optional. Each can be changed later in Settings.")
                }
                .settingsFooter()
            }
        }
        .task { await readNotices() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            voiceAllowed = WelcomePanel.voiceAllowedNow
            Task { await readNotices() }
        }
    }

    // MARK: Permissions asked on the page itself

    private var noticesAllowed: Bool { notices == .authorized || notices == .provisional || notices == .ephemeral }

    private var noticesValue: String? {
        switch notices {
        case .notDetermined: AppLocalization.text(LocalizedStringResource("Allow"))
        case .denied: AppLocalization.text(LocalizedStringResource("Off"))
        default: nil
        }
    }

    private func allowVoice() {
        guard !voiceAllowed else { return }
        Task {
            voiceAllowed = await Dictation.allowed()
        }
    }

    /// Asked here the first time; once turned down only the system's Settings can turn it on.
    private func allowNotices() {
        guard !noticesAllowed else { return }
        if notices == .denied {
            if let url = URL(string: UIApplication.openNotificationSettingsURLString) { UIApplication.shared.open(url) }
            return
        }
        Task {
            ApprovalNotice.registerActions()
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            await readNotices()
        }
    }

    private func readNotices() async {
        notices = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }
}

extension View {
    /// The pages the welcome's rows open: Settings' own, on the same ground.
    func welcomeDestinations(path: Binding<NavigationPath>) -> some View {
        navigationDestination(for: SetupStep.self) { SetupStepPage(step: $0).settingsPage() }
            .navigationDestination(for: DetailsRoute.self) { route in
                Group {
                    switch route {
                    case .model, .voiceKey: ModelSettingsView()
                    case .screenHistory: HistoryPage()
                    case .agents: AgentsAndRelayView(path: path)
                    default: EmptyView()
                    }
                }
                .settingsPage()
            }
            .navigationDestination(for: SettingsRoute.self) { route in
                SettingsDestination(route: route, push: { path.wrappedValue.append($0) },
                                    pop: { if !path.wrappedValue.isEmpty { path.wrappedValue.removeLast() } })
                    .settingsPage()
            }
    }
}
