import PokiCore
import SwiftUI

@main
struct PokiApp: App {
    @State private var model: AppModel
    @State private var chat: ChatModel
    @State private var inDuoSplitView = false
    @Environment(\.scenePhase) private var scenePhase
    private let startupLog: StartupLog?

    @discardableResult
    static func scheduleStartupWork(routines: RoutineStore = .shared) -> Task<String?, Never> {
        Task.detached(priority: .utility) { routines.importRestoredBackup() }
    }

    init() {
        startupLog = StartupLog.begin()
        // PokiLauncher (Rust) and the relay write to sockets the other side may have closed. In an app,
        // unlike a Rust executable, nothing ignores SIGPIPE, and it would end the whole app.
        signal(SIGPIPE, SIG_IGN)
        // Settings an update, a reinstall or a re-sign lost come back from the Keychain, before anything
        // reads them; from here on every change is mirrored there.
        SettingsVault.restore()
        AppLocalization.publish()
        SettingsVault.watch()
        // Install history lock observers before any local or external agent can query the store.
        _ = HistoryLock.shared
        HistoryCapture.shared.watchLock()
        // Someone updating from an earlier version keeps the dictation microphone it always showed; this
        // reads what that version left behind, so it runs before the conversations and the model load.
        FieldDictation.keepButtonForUpgrade()
        #if DEBUG
        // Only a dedicated UI-test launch flag installs the disposable Memory
        // source records; production launches never write synthetic conversations.
        MemorySourceUITestFixture.installIfRequested()
        #endif
        // Whether this phone gets the first run: not when an earlier version was used here. Read before
        // anything this version writes, like the line above.
        let priorFirstRun = UserDefaults.standard.string(forKey: FirstRun.key)
        FirstRun.decide()
        // Record the installed version as seen only on a true fresh install so What's New shows after updates.
        WhatsNew.decide(priorFirstRun: priorFirstRun)
        // Page titles in Allo Rounded, the face for prominent text (Shared/Typeface.swift).
        if let large = Prominent.uiFont(.largeTitle, .bold), let inline = Prominent.uiFont(.headline, .semibold) {
            UINavigationBar.appearance().largeTitleTextAttributes = [.font: large]
            UINavigationBar.appearance().titleTextAttributes = [.font: inline]
        }
        #if DEBUG && targetEnvironment(simulator)
        TestCredential.importIfGiven()
        #endif
        #if DEBUG
        LaunchBackdropRender.writeIfAsked()
        #endif
        // A memory backup Poki Setup put back (Documents/AgentBackup) is merged in off the main thread.
        Self.scheduleStartupWork()
        // The three-dimensional bear loads while the app starts, to be there when Poki's picture first shows.
        BearModel.shared.load()
        let model = AppModel()
        // Started by iOS in the background (a change of place, a shortcut) with Screen History on:
        // reading starts without waiting for Poki to be opened.
        HistoryCapture.shared.monitor(model: model)
        BackgroundRefresh.register { model.background.woke("background refresh") }
        _model = State(initialValue: model)
        let chat = ChatModel(app: model)
        _chat = State(initialValue: chat)
        AskPoki.install(app: model, chat: chat)
    }

    var body: some Scene {
        WindowGroup {
            RootView().environment(model).environment(chat)
                // Body text in Allo wherever a view does not choose a font of its own.
                .font(.allo(.body))
                #if DEBUG
                .overlay { if UserDefaults.standard.string(forKey: "pokiScreen") == "fonts" { FontCompare().background(Color(.systemBackground)) } }
                .overlay { if UserDefaults.standard.string(forKey: "pokiScreen") == "bear" { BearStage() } }
                #endif
                .environment(\.startupLog, startupLog)
                .environment(\.inDuoSplitView, inDuoSplitView)
                .environment(\.locale, AppLocalization.locale)
                .environment(\.layoutDirection, AppLocalization.locale.language.characterDirection == .rightToLeft ? .rightToLeft : .leftToRight)
                .background(LanguageNavigationFonts())
                .onChange(of: AppLocalization.shared.preference) { _, _ in
                    model.languageChanged()
                    chat.languageChanged()
                }
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { _ in
                    updateDuoSplitView()
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { updateDuoSplitView() }
                }
        }
    }

    private func updateDuoSplitView() {
        let placement = PKInProcess.shared().duoPlacement()
        inDuoSplitView = placement != nil && placement != "fullscreen"
    }
}

extension EnvironmentValues {
    @Entry var inDuoSplitView = false
}

/// The chat is the app (ESP-326): it opens on Poki's conversation. The conversations slide in from the
/// leading edge in narrow windows and stand beside the chat when both columns fit. An outside agent's
/// session, the voice page and a setup step push over the chat. Poki's profile opens from the bear.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(ChatModel.self) private var chat
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.startupLog) private var startupLog
    var sessionStore: SessionStore = .shared
    var shortcutStore: HomeShortcutStore = .shared
    @State private var sidebarWidth: CGFloat?
    private var showsSidebar: Bool { sidebarWidth != nil }
    // Both navigation layouts share the composer while the window changes size.
    @State private var draft = UserDefaults.standard.string(forKey: "pokiDraft") ?? ""

    private static let regularSidebarWidth: CGFloat = 375
    private static let minimumDuoSidebarWidth: CGFloat = 280
    private static let minimumChatWidth: CGFloat = 375

    /// What is pushed over the chat in a narrow window.
    @State private var home = NavigationPath()
    /// The right-hand column when both columns fit.
    @State private var wide: HomeRoute = .chat
    @State private var threadsOpen = false
    @State private var detailsOpen = false
    @State private var signingInForVoice = false
    @State private var resumeVoiceAfterSignIn = false
    @State private var detailsPath = NavigationPath()
    @State private var searchNavigation = ConversationSearchNavigation()
    private var searchJump: ConversationSearchJump? { searchNavigation.pending }
    /// The welcome is up, over everything (`FirstRunGuide`): after a fresh install or a new version.
    @State private var welcome = FirstRun.due()
    private var welcoming: Bool { welcome != nil }
    /// A setup step a link opened while the first run is up: it opens there.
    @State private var welcomeLink: SetupStep?
    /// The Apple Account sign-in for a free account's install, as a sheet after setup (`RenewSignIn`).
    /// `-pokiScreen renewSignIn` opens it at launch for screenshots.
    @State private var renewAsk = UserDefaults.standard.string(forKey: "pokiScreen") == "renewSignIn"
    /// The welcome closed at this launch, or Poki Setup put Poki here just before it.
    @State private var afterSetup = false
    private var renewDue: Bool {
        RenewSignIn.shouldAsk(freeSigning: model.signer.freeSigning, needsAccount: model.signer.needsAppleAccountForRenewal,
                              statusKnown: model.signer.status != nil, afterSetup: afterSetup && !welcoming && !curtain && !whatsNewOpen,
                              expiry: model.signer.expiry, askedFor: RenewSignIn.askedFor())
    }
    /// The post-update What's New card, presented after Home has appeared.
    @State private var whatsNewOpen = false
    @State private var whatsNewGate = WhatsNewLaunchGate()
    @Environment(\.dynamicTypeSize) private var typeSize
    @AppStorage(AppInterfaceSize.defaultsKey) private var interfaceSize = AppInterfaceSize.system
    @AppStorage(Appearance.key) private var appearance = Appearance.automatic.rawValue
    @Namespace private var profile
    /// The launch screen is still over the first frame, letting go (`LaunchCurtain`).
    @State private var curtain = true
    @State private var firstFrameDisplayed = false
    @State private var sceneHasBeenActive = false
    private var glassDeferred: Bool { !firstFrameDisplayed || !sceneHasBeenActive }

    enum HomeRoute: Hashable { case chat, session(String), voice, setup }

    private func show(_ route: HomeRoute) {
        // Ordinary navigation must not replay a previously selected search result.
        searchNavigation = ConversationSearchNavigation()
        if threadsOpen { withAnimation(ThreadsDrawerMotion.settle) { threadsOpen = false } }
        wide = route
        home = route == .chat ? NavigationPath() : NavigationPath([route])
    }

    private func consumeSearchJump(_ requestID: UUID) {
        searchNavigation.consume(requestID)
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
            openSession: { show(.session($0)) },
            sessionStore: sessionStore
        )
    }

    /// Opens where a setup hint's problem is fixed. A setup step pushes over the chat on iPhone (the
    /// drawer closes to show it); beside the list (iPad) the chat has no stack of its own to push on,
    /// so the step opens in the profile. Everything else opens in the profile.
    private func fix(_ target: SetupIssueHint.Target, split: Bool) {
        switch target {
        case .step(let step):
            if split {
                openDetails([DetailsRoute.connection, step])
            } else {
                if threadsOpen { withAnimation(ThreadsDrawerMotion.settle) { threadsOpen = false } }
                home.append(step)
            }
        case .setup: openDetails([DetailsRoute.connection])
        case .model: openDetails([DetailsRoute.model])
        case .agents: openDetails([DetailsRoute.agents])
        case .updates: openDetails([DetailsRoute.updates])
        }
    }

    private func chatPage(split: Bool) -> some View {
        ChatView(
            sharedDraft: $draft,
            openVoice: openLiveVoice,
            openChatGPTSignIn: { signingInForVoice = true },
            openSetup: { fix(.setup, split: split) },
            openSetupStep: { fix(.step($0), split: split) },
            openModel: { fix(.model, split: split) },
            searchJump: searchJump?.sessionID == chat.sessionID ? searchJump : nil,
            revealedSearchEntryID: searchNavigation.revealedEntry(in: chat.sessionID),
            onSearchJumpApplied: consumeSearchJump,
            openVoiceKey: { openDetails([DetailsRoute.voiceKey]) },
            openThreads: split ? nil : { withAnimation(ThreadsDrawerMotion.settle) { threadsOpen = true } },
            openAgents: { fix(.agents, split: split) },
            openUpdates: { fix(.updates, split: split) },
            sessionStore: sessionStore,
            shortcutStore: shortcutStore
        )
        // The bear stops drawing where it is out of sight: behind the open drawer or the profile over the
        // chat.
        .environment(\.bearCovered, threadsOpen || welcoming || whatsNewOpen || (detailsOpen && !showsSidebar))
    }

    @ViewBuilder private func destination(_ route: HomeRoute, split: Bool) -> some View {
        switch route {
        case .chat:
            chatPage(split: split)
        case .voice:
            // The voice page keeps its own header and blue ground (not redrawn in ESP-340's first batch).
            VoicePage(
                back: split ? nil : { show(.chat) },
                openModel: { openDetails([DetailsRoute.model]) },
                select: { target in if target == .chat { show(.chat) } }
            )
            .background(Site.blue.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
        case .session(let id):
            SessionView(id: id, back: { show(.chat) },
                        searchJump: searchJump?.sessionID == id ? searchJump : nil,
                        onSearchJumpApplied: consumeSearchJump,
                        sessionStore: sessionStore)
        case .setup:
            SetupChecklist().toolbar(.visible, for: .navigationBar)
        }
    }

    @ViewBuilder private var mainNavigation: some View {
        if let sidebarWidth {
            // Two plain stacks side by side, not a NavigationSplitView: its sidebar is a floating panel
            // on iOS 26, set in from the top edge. The left stack is the iPhone's drawer as it is.
            HStack(spacing: 0) {
                NavigationStack { sessions }
                    .frame(width: sidebarWidth)
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
            // Every page's top scroll edge is the system's soft one: the chat, the conversations, and
            // the pages pushed over them under the system's bar.
            .softTopEdge()
            // Settings opens from the bottom of the conversations.
            .environment(\.openPokiSettings, { openDetails() })
            .environment(\.pokiDetailsOpen, detailsOpen)
            // Settings covers the whole screen on iPhone (ESP-469: nothing of the chat shows around it), with
            // its Close button; beside the list on iPad it stays a sheet at a page's width (ESP-376).
            .fullScreenCover(isPresented: Binding(get: { detailsOpen && !showsSidebar }, set: { detailsOpen = $0 })) {
                profilePage
            }
            .sheet(isPresented: Binding(get: { detailsOpen && showsSidebar }, set: { detailsOpen = $0 })) {
                profilePage.presentationSizing(.page).presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $signingInForVoice, onDismiss: {
                if resumeVoiceAfterSignIn {
                    resumeVoiceAfterSignIn = false
                    openLiveVoice()
                }
            }) {
                ChatGPTSignIn { resumeVoiceAfterSignIn = true }
            }
            .onChange(of: PokiEntry.shared.pending, initial: true) { takeEntry() }
            .onChange(of: scenePhase) { takeEntry() }
    }

    private var profilePage: some View {
        PokiDetailsView(
            openSetup: {
                var next = NavigationPath()
                next.append(DetailsRoute.connection)
                detailsPath = next
            },
            openSession: { id, entryID in openRun(id, entryID: entryID) },
            searchJump: searchJump,
            onSearchJumpApplied: consumeSearchJump,
            revealedSearchEntryID: { id in searchNavigation.revealedEntry(in: id) },
            sessionStore: sessionStore,
            path: $detailsPath
        )
        // Presented on its own, so it says the edge's style itself rather than counting on the
        // presenting page's.
        .softTopEdge()
        // A Memory source is an internal navigation action, not an external app launch.
        // Use the same handler as onOpenURL while keeping the presented Settings stack.
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "poki", url.host() == "session" else { return .systemAction }
            open(link: url)
            return .handled
        })
        .modifier(AutomationNotices())
    }

    var body: some View {
        Group {
            if let message = model.signer.installMessage {
                UpdateFinishView(message: message, needsReopen: model.signer.needsReopen)
            } else {
                navigation
            }
        }
        .fullScreenCover(
            isPresented: Binding(get: { whatsNewOpen && !showsSidebar }, set: { whatsNewOpen = $0 }),
            onDismiss: { WhatsNew.markSeen() }
        ) {
            WhatsNewView(release: WhatsNewCatalog.release() ?? WhatsNewCatalog.current) {
                WhatsNew.markSeen()
                whatsNewOpen = false
            }
        }
        .sheet(
            isPresented: Binding(get: { whatsNewOpen && showsSidebar }, set: { whatsNewOpen = $0 }),
            onDismiss: { WhatsNew.markSeen() }
        ) {
            WhatsNewView(release: WhatsNewCatalog.release() ?? WhatsNewCatalog.current) {
                WhatsNew.markSeen()
                whatsNewOpen = false
            }
            .presentationSizing(.page)
            .presentationDragIndicator(.visible)
        }
        .onChange(of: curtain) { _, stillUp in
            if !stillUp { scheduleWhatsNewIfDue() }
        }
        .onChange(of: firstFrameDisplayed) { _, displayed in
            if displayed { scheduleWhatsNewIfDue() }
        }
        .onChange(of: welcoming) { _, isWelcoming in
            if !isWelcoming { scheduleWhatsNewIfDue() }
        }
        .onChange(of: detailsOpen) { _, isOpen in
            if !isOpen { scheduleWhatsNewIfDue() }
        }
        .onChange(of: model.pairingUnderWay) { _, pairing in
            if !pairing { scheduleWhatsNewIfDue() }
        }
        .onChange(of: model.signer.installMessage == nil) { _, cleared in
            if cleared { scheduleWhatsNewIfDue() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tint.page.ignoresSafeArea())
        .modifier(LaunchLayers(curtain: $curtain, welcome: $welcome, link: $welcomeLink, firstFrame: { timestamp in
            startupLog?.frameDisplayed(at: timestamp, glassDeferred: glassDeferred)
            firstFrameDisplayed = true
        }, finished: {
            startupLog?.finish()
            scheduleWhatsNewIfDue()
        }))
        // The welcome is an overlay in this window, so one alert serves it and the app.
        .modifier(LinkAskAlert())
        .onGeometryChange(for: CGFloat?.self) { geometry in
            let width = geometry.size.width
            guard width >= Self.regularSidebarWidth + 1 + Self.minimumChatWidth else { return nil }
            guard PKInProcess.canUseDuoSplitView() else { return Self.regularSidebarWidth }
            let windowWidth = width + geometry.safeAreaInsets.leading + geometry.safeAreaInsets.trailing
            return min(Self.regularSidebarWidth, max(Self.minimumDuoSidebarWidth, windowWidth / 3))
        } action: { sidebarWidth = $0 }
        .task {
            LoopbackShortcut.shared.start(model: model)
            InProcessProbe.shared.startFromLaunchArguments(model: model)
        }
        .alert(model.connectionAsk.map { AppLocalization.text(LocalizedStringResource("Allow \($0.client) to connect?")) } ?? "",
               isPresented: Binding(get: { model.connectionAsk != nil }, set: { if !$0 { model.answerConnection(false) } }),
               presenting: model.connectionAsk) { _ in
            Button("Don’t Allow", role: .cancel) { model.answerConnection(false) }
            Button("Allow") { model.answerConnection(true) }
        } message: { ask in
            Text("\(ask.client) is signing in through \(ask.connector) with callback destination \(ask.callback). Allow it only if you are connecting it yourself right now. It could then see your screen and act on this iPhone.")
        }
        .alert("Poki Will Close to Finish the Update", isPresented: Binding(get: { model.signer.finishNotice }, set: { if !$0 { model.signer.finishNoticeAnswered() } })) {
            Button("OK") { model.signer.finishNoticeAnswered() }
        } message: {
            Text("The update is almost in. Poki will close to finish it. Open Poki again afterwards.")
        }
        .modifier(AutomationNotices(enabled: !detailsOpen))
        .modifier(LoopbackPrompt(enabled: !detailsOpen && !welcoming && !renewAsk && model.signer.installMessage == nil))
        .sheet(isPresented: $renewAsk) { RenewSignInSheet() }
        .onChange(of: welcoming) { was, now in if was, !now { afterSetup = true } }
        .onChange(of: renewDue, initial: true) { _, due in if due { renewAsk = true } }
        .onChange(of: renewAsk) { _, up in if !up { scheduleWhatsNewIfDue() } }
        .task { if model.signer.handedAtLaunch { afterSetup = true } }
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active {
                sceneHasBeenActive = true
                scheduleWhatsNewIfDue()
                model.becameActive()
                HistoryCapture.shared.appDidBecomeActive()
                AskPoki.refresh()
                // New models a provider adds show up without a Poki release (lists a day old are read again).
                Task { await ModelCatalog.refreshStale() }
                model.startSigner()
                model.signer.maintain()
                Task { await model.verifyPairing() }
            } else if phase == .background {
                model.wentToBackground()
                if model.background.isOn { BackgroundRefresh.schedule() } else { BackgroundRefresh.cancel() }
            }
        }
        // A tap on the Live Activity opens the screen its state is about (ActivityFace.link): `poki://activity`
        // keeps an active task running and returns to its target app; other links open the chat, the setup
        // step, or the Activity Log for a problem, and `poki://voice` brings the chat to the front.
        .onOpenURL { url in open(link: url) }
        // On the window, not the view: sheets and full-screen covers take it too, and Automatic hands back to iOS.
        .onChange(of: appearance, initial: true) { _, value in
            let style = (Appearance(rawValue: value) ?? .automatic).style
            for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
                for window in scene.windows where window.overrideUserInterfaceStyle != style {
                    window.overrideUserInterfaceStyle = style
                }
            }
        }
        .task(id: interfaceSize) {
            // Apply outside the current layout pass. Coalesce events within roughly one frame,
            // while the preview and the rest of the window inherit the same native category.
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled else { return }
            for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
                for window in scene.windows { AppInterfaceSize.apply(interfaceSize, to: window) }
            }
        }
        .task(id: typeSize) {
            await Task.yield()
            guard !Task.isCancelled else { return }
            for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
                for window in scene.windows { AppInterfaceSize.updateNavigationFonts(in: window) }
            }
        }
        .onAppear {
            openLaunchScreen()
            #if DEBUG
            MemorySourceUITestFixture.beginActualLiveTaskIfRequested(chat)
            #endif
        }
        .environment(\.pokiGlassDeferred, glassDeferred)
        // A conversation archived or deleted (in the list or in Settings) is not left open on screen.
        .onChange(of: SessionStore.shared.removed) { _, removed in
            if let removed { leave(removed.id) }
        }
        .task {
            #if DEBUG
            // Development builds: `-pokiVoiceLink "poki://voice?…"` at launch starts a silent test run.
            if let link = UserDefaults.standard.string(forKey: "pokiVoiceLink"), let url = URL(string: link), url.host() == "voice" {
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
        let opening = model.open(link: url)
        guard opening != .ignored else { return }
        // During the first run a pairing file or a setup link opens its step there; nothing else moves.
        if welcoming {
            if case .showSetup(let step) = opening { welcomeLink = step }
            return
        }
        if whatsNewOpen { whatsNewOpen = false }
        // A pairing file or a setup link (from Poki Setup on a computer, AirDrop or Files) opens
        // setup at that step, where the result is shown.
        // Settings covers the screen on iPhone and would hide the question a link raised.
        if model.linkAsk != nil { detailsOpen = false }
        if case .showSetup(let step) = opening {
            detailsOpen = false
            threadsOpen = false
            if showsSidebar { openDetails([DetailsRoute.connection, step]) } else { home = NavigationPath([step]) }
        } else if url.host() == "setup", !url.absoluteString.contains("relay=") {
            openDetails([DetailsRoute.connection])
        } else if url.host() == "reconnect" {
            // A shortcut's last resort when Poki was not running: it opens Poki, which reconnects.
            Task { _ = await HistoryCollector.shared.reconnect(model, by: "a link") }
        } else if url.host() == "log" {
            openDetails([DetailsRoute.history])
        } else if url.host() == "approvals" {
            openDetails([DetailsRoute.approvals])
        } else if url.host() == "memory" {
            // poki://memory, and poki://memory/recent?change=<id> from a conversation's "Memory updated",
            // which lights that change up.
            let change = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "change" }?.value
            openDetails(url.path() == "/recent" ? [SettingsRoute.memory, SettingsRoute.memoryPage(.recent(highlight: change))] : [SettingsRoute.memory])
        } else if url.host() == "session" {
            // poki://session/<id>: a memory's Source, back to the conversation it was heard in. A conversation
            // that is no longer kept leaves the page where it is.
            if let id = url.pathComponents.dropFirst().first, sessionStore.session(id) != nil {
                openRun(id)
            }
        } else if url.host() == "voice" {
            detailsOpen = false
            model.voice.open(url)
            show(.chat)
            // A link never turns on the microphone: it brings the chat to the front, where the message
            // field's button starts a talk, and says what Talk with Poki is missing when it has no key.
            if !model.voice.isOn, !model.voice.canTalkLive { model.voice.keyAsked = true }
        } else {
            // poki://chat?text=…: the Memory page's Tell Poki in Chat starts the message for the owner,
            // who finishes and sends it. Nothing is sent by the link.
            if url.host() == "chat", let text = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "text" })?.value,
               !text.isEmpty {
                draft = text
            }
            detailsOpen = false
            show(.chat)
        }
    }

    /// Talk with Poki: a live conversation starts in the chat, which stays in front (pull request #250's
    /// way). Without a live voice (no OpenAI key, no voice bridge) the message field says so, with the
    /// way to the key in Settings.
    private func openLiveVoice() {
        show(.chat)
        guard model.voice.canTalkLive else { model.voice.keyAsked = true; return }
        if !model.voice.isOn {
            ApprovalNotice.requestPermission()
            model.prepareForTask()
            Task { await model.voice.start() }
        }
    }

    /// The Action Button, Control Center, Shortcuts or Spotlight (PokiEntry), once Poki is in front. A task
    /// under way is shown, not interrupted: Talk starts only when Poki is free. Pairing stays on its step,
    /// and the first run stays up: its record is asked, not `welcoming`, because at a cold launch the
    /// request can be here before the cover is. An update's welcome does not hold an entry up: it closes.
    private func takeEntry() {
        guard scenePhase == .active, let request = PokiEntry.shared.take(), !model.pairingUnderWay, !FirstRun.isDue() else { return }
        if welcoming { FirstRun.finish(); welcome = nil }
        if whatsNewOpen { whatsNewOpen = false }
        detailsOpen = false
        if let handoff = AskPoki.liveSessionID { show(.session(handoff)); return }
        show(.chat)
        guard request == .talk, !chat.running, !model.voice.isOn else { return }
        // Without a live voice (no OpenAI key, no voice bridge) Talk opens the message field instead.
        if model.voice.canTalkLive { openLiveVoice() } else { MessageFieldAsk.shared.ask() }
    }

    /// The conversation `id` left the list. When it is the one in the chat, the chat stops its task and
    /// starts a new conversation (`ChatModel.conversationLeft`); when an outside agent's session with that
    /// id is open over the chat (iPhone) or beside the list (iPad), the chat comes back. The drawer stays
    /// as it is: the owner is in it.
    private func leave(_ id: String) {
        chat.conversationLeft(id)
        if wide == .session(id) { wide = .chat }
        if home == NavigationPath([HomeRoute.session(id)]) { home = NavigationPath() }
    }

    /// A run from the Activity Log: Poki's own chat or an outside agent's session.
    private func openRun(_ id: String, entryID: UUID? = nil) {
        // Replacing the right-hand ChatView on iPad would destroy its unsent draft
        // and attachments. Open history within Settings while a live task is running.
        // Both search and Memory source links use this route. A preview must be on a
        // presented stack; never close Settings before pushing a destination into it.
        guard let session = sessionStore.session(id) else { return }
        if Self.usesSessionPreview(id: id, activeID: chat.sessionID, running: chat.running, wide: showsSidebar) {
            if !detailsOpen { detailsPath = NavigationPath() }
            detailsOpen = true
            searchNavigation.open(entryID.map { ConversationSearchJump(sessionID: id, entryID: $0) }, preview: true)
            // A preview is separate from the active chat; don't perturb its transcript selection.
            detailsPath.append(DetailsRoute.sessionPreview(id))
            return
        }
        detailsOpen = false
        if session.kind == .poki {
            if session.id != chat.sessionID { chat.restore(session) }
            show(.chat)
        } else {
            show(.session(id))
        }
        // show() clears the old request; install a new one after routing.
        searchNavigation.open(entryID.map { ConversationSearchJump(sessionID: id, entryID: $0) }, preview: false)
    }

    static func usesSessionPreview(id: String, activeID: String, running: Bool, wide: Bool) -> Bool {
        id != activeID && (running || wide)
    }

    /// Opens an initial screen from the app's local screenshot/test launch flags.
    /// These launch arguments remain unchanged by conversation search.
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
                openDetails([DetailsRoute.connection, target])
            } else {
                openDetails([DetailsRoute.connection])
            }
        case "moreSettings", "details", "status":
            // More Settings is gone: its rows are on Poki's profile, by what they are about.
            openDetails()
        case "hands", "connection":
            openDetails([DetailsRoute.connection])
        case "rules", "approvals":
            openDetails([DetailsRoute.approvals])
        case "health", "advanced":
            openDetails([DetailsRoute.advanced])
        case "connect", "settings", "agents":
            openDetails([DetailsRoute.agents])
        case "debug":
            openDetails([DetailsRoute.advanced, SettingsRoute.diagnostics])
        case "activity":
            openDetails([DetailsRoute.advanced, SettingsRoute.diagnostics, SettingsRoute.activityPreview])
        case "connector":
            if let first = model.identity.secrets.first {
                openDetails([DetailsRoute.agents, SettingsRoute.connector(first)])
            } else {
                openDetails([DetailsRoute.agents])
            }
        case "model":
            openDetails([DetailsRoute.model])
        case "memory":
            openDetails([SettingsRoute.memory])
        case "memoryRecent":
            openDetails([SettingsRoute.memory, SettingsRoute.memoryPage(.recent())])
        case "composer":
            openDetails([DetailsRoute.composer])
        case "interfaceSize":
            openDetails([DetailsRoute.interfaceSize])
        case "appearance":
            openDetails([DetailsRoute.appearance])
        case "language":
            openDetails([DetailsRoute.language])
        case "voiceSettings":
            openDetails([DetailsRoute.voice])
        case "conversations":
            openDetails([DetailsRoute.conversations])
        case "screenHistory":
            openDetails([DetailsRoute.screenHistory])
        case "updates":
            openDetails([DetailsRoute.updates])
        case "about":
            openDetails([DetailsRoute.about])
        case "steps":
            openDetails([DetailsRoute.history])
        default: break
        }
    }

    private var whatsNewGateContext: WhatsNewLaunchGate.Context {
        WhatsNewLaunchGate.Context(
            firstFrameDisplayed: firstFrameDisplayed,
            curtainUp: curtain,
            sceneActive: sceneHasBeenActive && scenePhase == .active,
            // The Apple Account sign-in after setup holds What's New back like the welcome does.
            welcoming: welcoming || renewAsk,
            detailsOpen: detailsOpen,
            installMessageActive: model.signer.installMessage != nil,
            pairingUnderWay: model.pairingUnderWay,
            whatsNewOpen: whatsNewOpen
        )
    }

    private func scheduleWhatsNewIfDue() {
        guard whatsNewGate.beginSchedulingIfReady(
            context: whatsNewGateContext,
            isDue: { WhatsNew.isDueAtLaunch() }
        ) else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            guard whatsNewGate.commitIfStillReady(
                context: whatsNewGateContext,
                isDue: { WhatsNew.isDueAtLaunch() }
            ) else { return }
            whatsNewOpen = true
        }
    }
}

private struct AutomationNotices: ViewModifier {
    @Environment(AppModel.self) private var model
    var enabled = true

    func body(content: Content) -> some View {
        content
        .alert("Poki Restarts to Turn On", isPresented: Binding(get: { enabled && model.relaunchNotice }, set: { if enabled && !$0 { model.relaunchNotice = false } })) {
            Button("Cancel", role: .cancel) { model.relaunchNotice = false }
            Button("Continue") { model.continueRelaunch() }
        } message: {
            Text("Poki closes by itself so agents can see the screen again. Open Poki again afterwards, from the notification or the Home Screen. It turns on when it opens.")
        }
        .alert("Enter Your Passcode Next", isPresented: Binding(get: { enabled && model.passcodeHeadsUp }, set: { if enabled && !$0 { model.passcodeHeadsUp = false } })) {
            Button("Cancel", role: .cancel) { model.cancelPasscodeHeadsUp() }
            Button("Continue") { model.continueAfterPasscodeHeadsUp() }
        } message: {
            Text(AppModel.passcodeHeadsUpMessage)
        }
    }
}

/// A one-shot scroll and a retained, session-scoped reveal serve different purposes.
/// Opening a read-only preview does not disturb the current chat's retained selection.
struct ConversationSearchNavigation {
    private(set) var pending: ConversationSearchJump?
    private var selected: ConversationSearchJump?

    mutating func open(_ jump: ConversationSearchJump?, preview: Bool) {
        pending = jump
        if !preview { selected = jump }
    }

    mutating func consume(_ requestID: UUID) {
        if pending?.requestID == requestID { pending = nil }
    }

    func revealedEntry(in sessionID: String) -> UUID? {
        selected?.sessionID == sessionID ? selected?.entryID : nil
    }
}
