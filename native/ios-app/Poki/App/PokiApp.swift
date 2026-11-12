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

/// The chat is the app (ESP-326): it opens on Poki's conversation. The conversations slide in from the
/// leading edge on iPhone and stand beside the chat on iPad; an outside agent's session, the voice
/// page and a setup step push over the chat; every setting lives in Poki's profile, which opens from
/// the bear.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(ChatModel.self) private var chat
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var width

    /// What is pushed over the chat on iPhone.
    @State private var home = NavigationPath()
    /// The right-hand column on iPad.
    @State private var wide: HomeRoute = .chat
    @State private var threadsOpen = false
    @State private var detailsOpen = false
    @State private var detailsPath = NavigationPath()
    @Namespace private var profile

    enum HomeRoute: Hashable { case chat, session(String), voice, setup }

    private func show(_ route: HomeRoute) {
        if threadsOpen { withAnimation(ThreadsDrawerMotion.settle) { threadsOpen = false } }
        wide = route
        home = route == .chat ? NavigationPath() : NavigationPath([route])
    }

    private func openDetails(_ items: [any Hashable] = []) {
        var next = NavigationPath()
        for item in items { next.append(item) }
        detailsPath = next
        detailsOpen = true
    }

    private var sessions: some View {
        SessionsView(
            openChat: { show(.chat) },
            openSession: { show(.session($0)) }
        )
    }

    private func chatPage(split: Bool) -> some View {
        ChatView(
            openDetails: { openDetails() },
            openVoice: openLiveVoice,
            openSetup: { openDetails([DetailsRoute.hands, DetailsRoute.setup]) },
            // Beside the list (iPad) the chat has no stack of its own to push on: the step opens in the profile.
            openSetupStep: { step in
                if split { openDetails([DetailsRoute.hands, DetailsRoute.setup, step]) } else { home.append(step) }
            },
            openModel: { openDetails([DetailsRoute.model]) },
            openThreads: split ? nil : { withAnimation(ThreadsDrawerMotion.settle) { threadsOpen = true } },
            openUpdates: { openDetails([DetailsRoute.updates]) }
        )
    }

    @ViewBuilder private func destination(_ route: HomeRoute, split: Bool) -> some View {
        switch route {
        case .chat:
            chatPage(split: split)
        case .voice:
            // The voice page keeps its own header and blue ground (not redrawn in ESP-340's first batch).
            VoicePage(
                back: split ? nil : { show(.chat) },
                openDetails: { openDetails() },
                openModel: { openDetails([DetailsRoute.model]) },
                select: { target in if target == .chat { show(.chat) } }
            )
            .background(Site.blue.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
        case .session(let id):
            SessionView(id: id, back: { show(.chat) })
        case .setup:
            SetupChecklist().toolbar(.visible, for: .navigationBar)
        }
    }

    @ViewBuilder private var mainNavigation: some View {
        if width == .regular {
            // Two plain stacks side by side, not a NavigationSplitView: its sidebar is a floating panel
            // on iOS 26, set in from the top edge. The left stack is the iPhone's drawer as it is.
            HStack(spacing: 0) {
                NavigationStack { sessions }
                    .frame(width: 375)
                Divider().ignoresSafeArea()
                NavigationStack {
                    destination(wide, split: true).id(wide)
                        .navigationDestination(for: SetupStep.self) { SetupStepPage(step: $0).toolbar(.visible, for: .navigationBar) }
                }
            }
        } else {
            NavigationStack(path: $home) {
                chatPage(split: false)
                    .navigationDestination(for: HomeRoute.self) { destination($0, split: false) }
                    .navigationDestination(for: SetupStep.self) { SetupStepPage(step: $0).toolbar(.visible, for: .navigationBar) }
            }
            .threadsDrawer(isOpen: $threadsOpen, enabled: home.isEmpty) { sessions }
        }
    }

    /// The navigation and Poki's profile, apart from `body`: together with its alerts and handlers the one
    /// expression was more than the compiler would type-check in its time limit (main #145).
    private var navigation: some View {
        mainNavigation
            // Poki's profile rises from the bottom (ESP-376): a full-height sheet on iPhone, a sheet at a
            // page's width beside the list on iPad, as the system's own are.
            .sheet(isPresented: $detailsOpen) {
                profilePage.presentationSizing(.page).presentationDragIndicator(.visible)
            }
    }

    private var profilePage: some View {
        PokiDetailsView(
            openVoice: {
                detailsOpen = false
                openLiveVoice()
            },
            openSetup: {
                var next = NavigationPath()
                next.append(DetailsRoute.hands)
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
            Text("The update is almost in. Poki will close to finish it. Open Poki again afterwards.")
        }
        // Turning on after Off: Poki exits by itself and has to be opened again.
        .alert("Poki Restarts to Turn On", isPresented: Binding(get: { model.relaunchNotice }, set: { if !$0 { model.relaunchNotice = false } })) {
            Button("Cancel", role: .cancel) { model.relaunchNotice = false }
            Button("Continue") { model.continueRelaunch() }
        } message: {
            Text("Poki closes by itself so agents can see the screen again. Open Poki again afterwards, from the notification or the Home Screen. It turns on when it opens.")
        }
        // Before the first automation after a restart: iOS's passcode screen is next, and expected.
        .alert("Enter Your Passcode Next", isPresented: Binding(get: { model.passcodeHeadsUp }, set: { if !$0 { model.passcodeHeadsUp = false } })) {
            Button("Cancel", role: .cancel) { model.passcodeHeadsUp = false }
            Button("Continue") { model.continueAfterPasscodeHeadsUp() }
        } message: {
            Text("This is the first time Poki starts automation since your iPhone restarted, so iOS will ask for your passcode on the next screen. That screen belongs to iOS. Poki can’t see or read what you enter, and it asks only once until the next restart.")
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active { model.becameActive(); AskPoki.refresh(); model.startSigner(); model.signer.maintain(); Task { await model.verifyPairing() } } else if phase == .background { model.wentToBackground() }
        }
        // A tap on the Live Activity opens the screen its state is about (ActivityFace.link): the chat,
        // the setup step, or the Activity Log for a problem; `poki://voice` opens the voice page.
        .onOpenURL { url in open(link: url) }
        .onAppear(perform: openLaunchScreen)
        .task {
            #if DEBUG
            // Development builds: `-pokiVoiceLink "poki://voice?…"` at launch starts a silent test run.
            if let link = UserDefaults.standard.string(forKey: "pokiVoiceLink"), let url = URL(string: link), url.host() == "voice" {
                show(.voice)
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
            threadsOpen = false
            if width == .regular { openDetails([DetailsRoute.hands, DetailsRoute.setup, step]) } else { home = NavigationPath([step]) }
        } else if url.host() == "setup", !url.absoluteString.contains("relay=") {
            openDetails([DetailsRoute.hands, DetailsRoute.setup])
        } else if url.host() == "log" {
            openDetails([DetailsRoute.history])
        } else if url.host() == "voice" {
            detailsOpen = false
            model.voice.open(url)
            show(.voice)
        } else {
            detailsOpen = false
            show(.chat)
        }
    }

    /// Opens the full-screen Voice page over Poki's chat and starts the live voice conversation if ready.
    private func openLiveVoice() {
        show(.voice)
        if !model.voice.isOn, model.voice.canTalkLive {
            ApprovalNotice.requestPermission()
            Task { await model.voice.start() }
        }
    }

    /// A run from the Activity Log: Poki's own chat or an outside agent's session.
    private func openRun(_ id: String) {
        if let session = SessionStore.shared.session(id), session.kind == .poki {
            if session.id != chat.sessionID { chat.restore(session) }
            show(.chat)
        } else {
            show(.session(id))
        }
    }

    /// `-pokiScreen setup` (connect, debug, activity, details, model, voice…) opens that screen at launch,
    /// for the build's screenshots; `-pokiSetupStep 3` opens setup at that step. The names are the ones
    /// the build's scripts already pass; each opens where that screen lives now.
    private func openLaunchScreen() {
        let defaults = UserDefaults.standard
        if let address = defaults.string(forKey: "pokiVoiceBridge") { _ = model.voice.setBridge(address) }
        // `-pokiHome sessions|paused` (the old home's samples): the conversations, open.
        if defaults.string(forKey: "pokiHome") != nil, defaults.string(forKey: "pokiChat") == nil { threadsOpen = true }
        switch defaults.string(forKey: "pokiScreen") {
        case "chat":
            show(.chat)
        case "home", "threads":
            threadsOpen = true
        case "voice":
            show(.voice)
        case "session":
            if let first = SessionStore.shared.ordered.first(where: { $0.kind == .agent || $0.kind == .handoff }) {
                show(.session(first.id))
            }
        case "setup":
            let step = defaults.integer(forKey: "pokiSetupStep")
            if step > 0 {
                let target = SetupStep.shown[min(step, SetupStep.shown.count) - 1]
                openDetails([DetailsRoute.hands, DetailsRoute.setup, target])
            } else {
                openDetails([DetailsRoute.hands, DetailsRoute.setup])
            }
        case "moreSettings", "details", "status":
            // More Settings is gone: its rows are on Poki's profile, by what they are about.
            openDetails()
        case "hands":
            openDetails([DetailsRoute.hands])
        case "rules":
            openDetails([DetailsRoute.approvals])
        case "health":
            openDetails([DetailsRoute.health])
        case "connect", "settings":
            openDetails([DetailsRoute.settings])
        case "debug":
            openDetails([DetailsRoute.health, SettingsRoute.diagnostics])
        case "activity":
            openDetails([DetailsRoute.health, SettingsRoute.diagnostics, SettingsRoute.activityPreview])
        case "connector":
            if let first = model.identity.secrets.first {
                openDetails([DetailsRoute.settings, SettingsRoute.connector(first)])
            } else {
                openDetails([DetailsRoute.settings])
            }
        case "model":
            openDetails([DetailsRoute.model])
        case "steps":
            openDetails([DetailsRoute.history])
        default: break
        }
    }
}
