import PokiCore
import SwiftUI

@main
struct PokiApp: App {
    @State private var model: AppModel
    @State private var chat: ChatModel

    init() {
        // PokiLauncher (Rust) and the relay write to sockets the other side may have closed. In an app,
        // unlike a Rust executable, nothing ignores SIGPIPE, and it would end the whole app.
        signal(SIGPIPE, SIG_IGN)
        // iOS 26: the background task that keeps Poki up is registered before launch ends, as iOS asks.
        if #available(iOS 26.0, *) { ContinuedRun.registerAtLaunch() }
        // Settings an update, a reinstall or a re-sign lost come back from the Keychain, before anything
        // reads them; from here on every change is mirrored there.
        SettingsVault.restore()
        SettingsVault.watch()
        // Page titles in Geist, the website's typeface (prominent text only).
        if let large = Prominent.uiFont(.largeTitle, .bold), let inline = Prominent.uiFont(.headline, .semibold) {
            UINavigationBar.appearance().largeTitleTextAttributes = [.font: large]
            UINavigationBar.appearance().titleTextAttributes = [.font: inline]
        }
        #if DEBUG && targetEnvironment(simulator)
        TestCredential.importIfGiven()
        #endif
        // A memory backup Poki Setup put back (Documents/AgentBackup) is merged in before any agent asks.
        _ = RoutineStore.shared.importRestoredBackup()
        let model = AppModel()
        _model = State(initialValue: model)
        let chat = ChatModel(app: model)
        _chat = State(initialValue: chat)
        AskPoki.install(app: model, chat: chat)
    }

    var body: some Scene {
        WindowGroup {
            RootView().environment(model).environment(chat)
        }
    }
}

/// Home is the Sessions list only (ESP-174 boards "H1 Home sessions", "H2 Home paused"): Poki's chat and
/// an agent's session open over it, like a conversation in Messages; swiping left in Poki's chat enters the
/// full-screen Voice page; all settings live inside Poki's avatar details screen, layered by frequency.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(ChatModel.self) private var chat
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var width

    @State private var home = NavigationPath()
    @State private var wide: HomeRoute = .chat
    @State private var page: RootPage = .chat
    @State private var detailsOpen = false
    @State private var detailsPath = NavigationPath()

    enum HomeRoute: Hashable { case chat, session(String), setup }

    private func show(_ route: HomeRoute) {
        wide = route
        home = NavigationPath([route])
    }

    private func openDetails(_ items: [any Hashable] = []) {
        var next = NavigationPath()
        for item in items { next.append(item) }
        detailsPath = next
        detailsOpen = true
    }

    private var sessions: some View {
        SessionsView(
            openChat: {
                page = .chat
                show(.chat)
            },
            openSession: { show(.session($0)) },
            openModel: { openDetails([DetailsRoute.model]) },
            openConnectors: { openDetails([DetailsRoute.moreSettings, DetailsRoute.settings]) },
            openDetails: { openDetails() },
            openVoice: openLiveVoice,
            openSetup: { openDetails([DetailsRoute.moreSettings, DetailsRoute.setup]) },
            openSetupStep: { step in home.append(step) }
        )
    }

    @ViewBuilder private func destination(_ route: HomeRoute, split: Bool) -> some View {
        switch route {
        case .chat:
            ZStack {
                if page == .chat {
                    ChatView(
                        openDetails: { openDetails() },
                        openVoice: { withAnimation(.snappy) { page = .voice } },
                        openSetup: { openDetails([DetailsRoute.moreSettings, DetailsRoute.setup]) },
                        openSetupStep: { step in home.append(step) },
                        openModel: { openDetails([DetailsRoute.model]) },
                        selectMode: { target in withAnimation(.snappy) { page = target } },
                        back: split ? nil : { home = NavigationPath() }
                    )
                    .transition(.move(edge: .leading))
                } else {
                    VoicePage(
                        back: split ? nil : { home = NavigationPath() },
                        openDetails: { openDetails() },
                        openModel: { openDetails([DetailsRoute.model]) },
                        select: { target in withAnimation(.snappy) { page = target } }
                    )
                    .transition(.move(edge: .trailing))
                }
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 40)
                    .onEnded { value in
                        let dx = value.translation.width
                        let dy = value.translation.height
                        guard abs(dx) > abs(dy) * 1.5 else { return }
                        if dx < -50, page == .chat {
                            withAnimation(.snappy) { page = .voice }
                        } else if dx > 50, page == .voice {
                            withAnimation(.snappy) { page = .chat }
                        }
                    }
            )
            .background((page == .voice ? Site.blue : Color(.systemBackground)).ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
        case .session(let id):
            SessionView(id: id, back: { home = NavigationPath() })
        case .setup:
            SetupChecklist().toolbar(.visible, for: .navigationBar)
        }
    }

    @ViewBuilder private var mainNavigation: some View {
        if width == .regular {
            // Two plain stacks side by side, not a NavigationSplitView: its sidebar is a floating panel
            // on iOS 26, set in from the top edge, which left a gap above home's blue header and pushed
            // the title down. The left stack is the iPhone's home as it is.
            HStack(spacing: 0) {
                NavigationStack {
                    sessions
                        .navigationDestination(for: SetupStep.self) { SetupStepPage(step: $0).toolbar(.visible, for: .navigationBar) }
                }
                .frame(width: 375)
                Divider().ignoresSafeArea()
                NavigationStack {
                    destination(wide, split: true).id(wide)
                        .navigationDestination(for: SetupStep.self) { SetupStepPage(step: $0).toolbar(.visible, for: .navigationBar) }
                }
            }
        } else {
            NavigationStack(path: $home) {
                sessions
                    .navigationDestination(for: HomeRoute.self) { destination($0, split: false) }
                    .navigationDestination(for: SetupStep.self) { SetupStepPage(step: $0).toolbar(.visible, for: .navigationBar) }
            }
        }
    }

    /// The navigation and Poki's details, apart from `body`: together with its alerts and handlers the one
    /// expression was more than the compiler would type-check in its time limit (main #145).
    private var navigation: some View {
        mainNavigation
            .fullScreenCover(isPresented: $detailsOpen) {
                PokiDetailsView(
                    openVoice: {
                        detailsOpen = false
                        openLiveVoice()
                    },
                    openSetup: {
                        var next = NavigationPath()
                        next.append(DetailsRoute.moreSettings)
                        next.append(DetailsRoute.setup)
                        detailsPath = next
                    },
                    openSession: { id in
                        detailsOpen = false
                        openRun(id)
                    },
                    path: $detailsPath
                )
            }
    }

    var body: some View {
        navigation
        .task { InProcessProbe.shared.startFromLaunchArguments(model: model) }
        .alert(model.connectionAsk.map { String(localized: "Allow \($0.client) to connect?") } ?? "",
               isPresented: Binding(get: { model.connectionAsk != nil }, set: { if !$0 { model.answerConnection(false) } }),
               presenting: model.connectionAsk) { _ in
            Button("Don’t Allow", role: .cancel) { model.answerConnection(false) }
            Button("Allow") { model.answerConnection(true) }
        } message: { ask in
            Text("\(ask.client) is signing in through \(ask.connector) and returns to \(ask.callback), which isn’t on Poki’s list of known agents. Allow it only if you are connecting it yourself right now. It could then see your screen and act on this iPhone.")
        }
        // The update's last step: Poki has to exit, and does so by itself.
        .alert("Poki Will Close to Finish the Update", isPresented: Binding(get: { model.signer.finishNotice }, set: { if !$0 { model.signer.finishNoticeAnswered() } })) {
            Button("OK") { model.signer.finishNoticeAnswered() }
        } message: {
            Text("The update is almost in. Poki will close to finish it; open Poki again afterwards.")
        }
        // Turning on after Off: Poki exits by itself and has to be opened again.
        .alert("Poki Restarts to Turn On", isPresented: Binding(get: { model.relaunchNotice }, set: { if !$0 { model.relaunchNotice = false } })) {
            Button("Cancel", role: .cancel) { model.relaunchNotice = false }
            Button("Continue") { model.continueRelaunch() }
        } message: {
            Text("Poki closes by itself so agents can see the screen again. Open Poki again afterwards, from the notification or the Home Screen; it turns on when it opens.")
        }
        // Before the first automation after a restart: iOS's passcode screen is next, and expected.
        .alert("Enter Your Passcode Next", isPresented: Binding(get: { model.passcodeHeadsUp }, set: { if !$0 { model.passcodeHeadsUp = false } })) {
            Button("Cancel", role: .cancel) { model.passcodeHeadsUp = false }
            Button("Continue") { model.continueAfterPasscodeHeadsUp() }
        } message: {
            Text("This is the first time Poki starts automation since your iPhone restarted, so iOS will ask for your passcode on the next screen. That screen belongs to iOS: Poki can’t see or read what you enter, and it asks only once until the next restart.")
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active { model.becameActive(); AskPoki.refresh(); model.startSigner(); model.signer.clearNotices(); model.signer.maintain(); Task { await model.verifyPairing() } } else if phase == .background { model.wentToBackground() }
        }
        // A tap on the Live Activity opens the screen its state is about (ActivityFace.link): the chat,
        // the setup step, or the Activity Log for a problem; `poki://voice` opens the voice page.
        .onOpenURL { url in open(link: url) }
        .onAppear(perform: openLaunchScreen)
        .task {
            #if DEBUG
            // Development builds: `-pokiVoiceLink "poki://voice?…"` at launch starts a silent test run.
            if let link = UserDefaults.standard.string(forKey: "pokiVoiceLink"), let url = URL(string: link), url.host() == "voice" {
                page = .voice
                show(.chat)
                model.voice.openAtLaunch(url)
            }
            #endif
        }
    }

    private func open(link url: URL) {
        AppLog.shared.add("app", "opened by link poki://\(url.host() ?? "")")
        // Pairing is not interrupted: it stays on the pairing step, where the PIN is.
        guard !model.pairingUnderWay else { return }
        // A pairing file or a setup link (from Poki Setup on a computer, AirDrop or Files) opens
        // setup at that step, where the result is shown.
        if let step = model.open(link: url) {
            detailsOpen = false
            home = NavigationPath([step])
        } else if url.host() == "setup", !url.absoluteString.contains("relay=") {
            openDetails([DetailsRoute.moreSettings, DetailsRoute.setup])
        } else if url.host() == "log" {
            openDetails([DetailsRoute.history])
        } else if url.host() == "voice" {
            detailsOpen = false
            model.voice.open(url)
            page = .voice
            show(.chat)
        } else {
            detailsOpen = false
            page = .chat
            show(.chat)
        }
    }

    /// Opens the full-screen Voice page inside Poki's chat and starts the live voice conversation if ready.
    private func openLiveVoice() {
        page = .voice
        show(.chat)
        if !model.voice.isOn, model.voice.canTalkLive {
            ApprovalNotice.requestPermission()
            Task { await model.voice.start() }
        }
    }

    /// A run from the Activity Log: Poki's own chat or an outside agent's session, in Chats.
    private func openRun(_ id: String) {
        if let session = SessionStore.shared.session(id), session.kind == .poki {
            if session.id != chat.sessionID { chat.restore(session) }
            page = .chat
            show(.chat)
        } else {
            show(.session(id))
        }
    }

    /// `-pokiScreen setup` (connect, debug, activity, details, model, voice…) opens that screen at launch,
    /// for the build's screenshots; `-pokiSetupStep 3` opens setup at that step.
    private func openLaunchScreen() {
        let defaults = UserDefaults.standard
        if let address = defaults.string(forKey: "pokiVoiceBridge") { _ = model.voice.setBridge(address) }
        if defaults.string(forKey: "pokiChat") != nil {
            page = .chat
            show(.chat)
        }
        switch defaults.string(forKey: "pokiScreen") {
        case "chat":
            page = .chat
            show(.chat)
        case "voice":
            page = .voice
            show(.chat)
        case "session":
            if let first = SessionStore.shared.ordered.first(where: { $0.kind == .agent || $0.kind == .handoff }) {
                show(.session(first.id))
            }
        case "setup":
            let step = defaults.integer(forKey: "pokiSetupStep")
            if step > 0 {
                let target = SetupStep.shown[min(step, SetupStep.shown.count) - 1]
                openDetails([DetailsRoute.moreSettings, DetailsRoute.setup, target])
            } else {
                openDetails([DetailsRoute.moreSettings, DetailsRoute.setup])
            }
        case "moreSettings":
            openDetails([DetailsRoute.moreSettings])
        case "connect", "settings":
            openDetails([DetailsRoute.moreSettings, DetailsRoute.settings])
        case "debug":
            openDetails([DetailsRoute.moreSettings, SettingsRoute.diagnostics])
        case "activity":
            openDetails([DetailsRoute.moreSettings, SettingsRoute.diagnostics, SettingsRoute.activityPreview])
        case "connector":
            if let first = model.identity.secrets.first {
                openDetails([DetailsRoute.moreSettings, DetailsRoute.settings, SettingsRoute.connector(first)])
            } else {
                openDetails([DetailsRoute.moreSettings, DetailsRoute.settings])
            }
        case "details", "status":
            openDetails()
        case "model":
            openDetails([DetailsRoute.model])
        case "steps":
            openDetails([DetailsRoute.history])
        default: break
        }
    }
}
