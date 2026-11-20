import AVFoundation
import Speech
import SwiftUI
import UserNotifications

/// The welcome's one page: everything Poki uses, as rows like Settings', each with where it stands and a
/// tap to the page that sets it up. The pages are Settings' own (the setup steps, Models, Screen History,
/// Memory, Agents), so nothing here is a second copy of them. What Poki needs before it can work (the
/// iPhone's steps and a model) comes first and the button at the bottom goes to the next of those; the
/// rest is optional and says so.
struct WelcomePanel: View {
    @Environment(AppModel.self) private var model
    var kind: FirstRun.Kind
    @Binding var path: NavigationPath
    var finish: () -> Void

    @State private var hasModel = ModelKeys.hasUsableKey
    @State private var modelName = ModelKeys.selectedModelName
    @State private var voiceAllowed = WelcomePanel.voiceAllowedNow
    @State private var notices = UNAuthorizationStatus.notDetermined

    static var voiceAllowedNow: Bool {
        AVAudioApplication.shared.recordPermission == .granted && SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    /// The first of this iPhone's steps still open, numbered from one.
    private var nextStep: (number: Int, step: SetupStep)? {
        SetupStep.shown.enumerated().first { !model.stepReadyForUse($0.element) }.map { ($0.offset + 1, $0.element) }
    }

    var body: some View {
        List {
            Section {
                ForEach(SetupStep.shown) { step in
                    NavigationLink(value: step) { stepRow(step) }
                        .accessibilityIdentifier("firstRun.step.\(step.rawValue)")
                }
            } header: {
                SettingsHeader("This iPhone")
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
                SettingsHeader("Models")
            } footer: {
                Group {
                    Text("Poki thinks with a model from your own account. Local models run on this iPhone and keep what they read on it.")
                }
                .settingsFooter()
            }

            Section {
                WelcomeSensesRow()
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
                SettingsHeader("Features")
            } footer: {
                Group {
                    Text("All optional. Each can be changed later in Settings.")
                }
                .settingsFooter()
            }

            Section {
                NavigationLink(value: DetailsRoute.agents) {
                    SettingsRow(title: "Agents", caption: "Let Claude, ChatGPT and other agents use this iPhone",
                                symbol: "chevron.left.forwardslash.chevron.right")
                }
                .accessibilityIdentifier("firstRun.agents")
            } header: {
                SettingsHeader("Connections")
            }
        }
        .settingsPage()
        .navigationTitle(kind == .firstRun ? AppLocalization.text("Set Up Poki") : AppLocalization.text("Check Setup"))
        .safeAreaInset(edge: .bottom) { buttons }
        .onAppear { model.loopback.resume() }
        .onChange(of: path.count) { _, _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: ModelKeys.changed)) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in refresh() }
        .task { await readNotices() }
    }

    private func stepRow(_ step: SetupStep) -> some View {
        let done = model.stepReadyForUse(step)
        return SettingsRow(title: LocalizedStringKey(step.pageTitle), symbol: step.symbol,
                           value: done ? nil : nextStep?.step == step ? AppLocalization.text(LocalizedStringResource("Next")) : nil,
                           warns: !done && nextStep?.step == step, accessory: done ? .done : nil)
    }

    // MARK: The buttons

    private var buttons: some View {
        VStack(spacing: 4) {
            SettingsPill(title: primaryWord, prominent: true, action: primary)
                .accessibilityIdentifier("firstRun.next")
            if nextStep != nil || !hasModel {
                Button(action: finish) {
                    Text(kind == .firstRun ? LocalizedStringKey("Finish Later") : LocalizedStringKey("Not Now"))
                        .font(.allo(.subheadline, .medium)).foregroundStyle(Color(.label).opacity(0.72))
                        .frame(maxWidth: .infinity, minHeight: 44).contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("firstRun.finishLater")
            }
        }
        .padding(.horizontal, 24).padding(.top, 10).padding(.bottom, 8)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity)
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

    private func refresh() {
        hasModel = ModelKeys.hasUsableKey
        modelName = ModelKeys.selectedModelName
        voiceAllowed = Self.voiceAllowedNow
        Task { await readNotices() }
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
                    case .screenHistory: ScreenHistorySettingsView(asks: false)
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
