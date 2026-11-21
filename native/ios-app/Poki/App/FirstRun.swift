import AVFoundation
import Speech
import SwiftUI
import UserNotifications

/// What an earlier version of Poki left on this phone. None of it is written by this version before
/// launch has read it, so it tells an update (or a reinstall the Keychain restored) from a fresh install:
/// a saved conversation, or a setting an earlier version stored (setup progress, the relay, the model,
/// approvals, voice).
enum EarlierVersion {
    nonisolated static func leftTraces(defaults: UserDefaults, sessionsFolder: URL) -> Bool {
        let settings = ["setup", "relayAddress", "relayEnabled", "chat.provider", "chat.installationID", "approvals.ask", "wantsOn", "voice.model"]
        let conversations = (try? FileManager.default.contentsOfDirectory(at: sessionsFolder, includingPropertiesForKeys: nil))?
            .contains { $0.pathExtension == "json" } ?? false
        return conversations || settings.contains { defaults.object(forKey: $0) != nil }
    }
}

/// The welcome panel: on a fresh install, and once after each new version (the owner, 2026-11-20), Poki
/// comes out of the launch screen into one page that sets up everything it uses. A fresh install gets the
/// hello first; an update gets a shorter hello that names the version. It can be gone through again from
/// Settings › Connection.
enum FirstRun {
    /// Absent until the first launch of a version with the first run decides it, once.
    static let key = "pokiFirstRun"
    /// The version whose welcome was last closed. A newer version shows the update's welcome once.
    static let versionKey = "pokiWelcomeVersion"
    enum Record: String { case due, done }

    /// Which welcome a launch shows.
    enum Kind: Equatable {
        case firstRun
        /// After an update, with the version now installed.
        case update(String)
    }

    /// The version as people see it (0.4.7): builds of one version share a welcome.
    nonisolated static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" }

    /// Call at launch before anything this version writes to the defaults.
    nonisolated static func decide(defaults: UserDefaults = .standard, sessionsFolder: URL = SessionStore.defaultFolder) {
        guard defaults.string(forKey: key) == nil else { return }
        let record: Record = EarlierVersion.leftTraces(defaults: defaults, sessionsFolder: sessionsFolder) ? .done : .due
        defaults.set(record.rawValue, forKey: key)
    }

    /// The welcome the records ask for. Someone who used a version before the welcome panel existed has
    /// no version noted, so they see the update's welcome once too.
    nonisolated static func pending(defaults: UserDefaults, version: String) -> Kind? {
        switch defaults.string(forKey: key).flatMap(Record.init) {
        case .due: return .firstRun
        case .done:
            guard !version.isEmpty, defaults.string(forKey: versionKey) != version else { return nil }
            return .update(version)
        case nil: return nil
        }
    }

    /// The welcome to show at this launch. Scripted launches (the in-app tests, the screenshot and check
    /// scripts, which all pass `-poki…` arguments) have nobody to go through it; `-pokiScreen welcome`
    /// asks for the first run's, `-pokiScreen welcomeUpdate` for an update's.
    static func due(defaults: UserDefaults = .standard) -> Kind? {
        let arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        switch arguments["pokiScreen"] as? String {
        case "welcome": return .firstRun
        case "welcomeUpdate": return .update(version)
        default: break
        }
        if ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil { return nil }
        if arguments.keys.contains(where: { $0.hasPrefix("poki") }) { return nil }
        return pending(defaults: defaults, version: version)
    }

    /// Whether the first run (not an update's welcome) is up or still to come at this launch: entries
    /// from outside wait for it.
    static func isDue(defaults: UserDefaults = .standard) -> Bool { due(defaults: defaults) == .firstRun }

    static func finish(defaults: UserDefaults = .standard, version: String = FirstRun.version) {
        defaults.set(Record.done.rawValue, forKey: key)
        if !version.isEmpty { defaults.set(version, forKey: versionKey) }
    }
}

/// The launch screen and the welcome, over the app: at a launch that has a welcome, the welcome is drawn
/// under the launch screen with the word and the bear where the launch screen has them, so the launch
/// screen goes without a seam and the hello starts from it. Without a welcome the launch screen lets go
/// into the home page as before (`LaunchCurtain`). Kept here so the app's body adds one line.
struct LaunchLayers: ViewModifier {
    @Binding var curtain: Bool
    @Binding var welcome: FirstRun.Kind?
    @Binding var link: SetupStep?
    /// The first frame under the curtain, with its display time, and the curtain gone (the startup log).
    var firstFrame: (CFTimeInterval) -> Void = { _ in }
    var finished: () -> Void = {}

    func body(content: Content) -> some View {
        content
            .accessibilityHidden(welcome != nil)
            .overlay {
                if let kind = welcome {
                    FirstRunGuide(kind: kind, fromLaunch: true, link: $link, done: { welcome = nil })
                        .logStartupAppearance(.welcome)
                        .transition(.opacity)
                }
            }
            .overlay {
                if curtain {
                    LaunchCurtain(handsOver: welcome != nil, firstFrame: firstFrame, done: {
                        curtain = false
                        finished()
                    })
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }
            }
    }
}

/// The welcome: the hello over the home page's light, then the setup panel.
struct FirstRunGuide: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var kind: FirstRun.Kind = .firstRun
    /// Drawn under the launch screen: the hello starts as the launch screen's own picture.
    var fromLaunch = false
    /// A setup step a link opened (a pairing file from Poki Setup) while the welcome is up.
    @Binding var link: SetupStep?
    var done: () -> Void

    @State private var stage = WelcomeHello.Stage.launch
    @State private var path = NavigationPath()
    private let design = StartDesign.current

    var body: some View {
        NavigationStack(path: $path) {
            StartHello(design: design, kind: kind, shown: stage == .hello, setUp: openPanel, later: finish)
                .background { StartGround(design: design, hello: true) }
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: StartRoute.self) { route in
                    StartFlowPage(route: route, kind: kind, path: $path, finish: finish)
                }
                .welcomeDestinations(path: $path)
        }
        .environment(\.startDesign, design)
        .interactiveDismissDisabled()
        // Keep the existing limit until the panel's rows and buttons are verified at AX3–AX5.
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .task {
            // The launch screen holds still, then lets go onto this page (LaunchCurtain).
            if fromLaunch { try? await Task.sleep(for: .seconds(LaunchMotion.hold + LaunchMotion.handOver * 0.6)) }
            withAnimation(reduceMotion ? .easeInOut(duration: 0.3) : .spring(duration: 0.7, bounce: 0.12)) { stage = .hello }
        }
        .onChange(of: link, initial: true) { _, step in
            guard let step else { return }
            link = nil
            stage = .hello
            path = NavigationPath([step])
        }
    }

    private func openPanel() {
        guard stage == .hello, let first = StartRoute.order.first else { return }
        path.append(first)
    }

    private func finish() {
        FirstRun.finish()
        withAnimation(.easeInOut(duration: 0.3)) { done() }
    }
}

/// The hello: "Poki" and the bear where the launch screen has them, then the word lifts, the bear sinks
/// as far as the words need, and the words and the button come in between them.
struct WelcomeHello: View {
    enum Stage { case launch, hello, leaving, gone }

    var kind: FirstRun.Kind
    var stage: Stage
    var setUp: () -> Void
    var later: () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            let screen = CGSize(width: geometry.size.width + geometry.safeAreaInsets.leading + geometry.safeAreaInsets.trailing,
                                height: geometry.size.height + geometry.safeAreaInsets.top + geometry.safeAreaInsets.bottom)
            let art = LaunchArt.on(screen, dark: scheme == .dark)
            let lifted = max(geometry.safeAreaInsets.top + art.word.height, art.word.midY - screen.height * 0.08)
            let wordY = stage == .launch ? art.word.midY : lifted
            let contentTop = lifted + art.word.height / 2 + 20
            let drop = bearDrop(room: contentTop + contentHeight + 28 - art.bear.minY, height: art.bear.height)
            let showsWords = stage == .hello

            ZStack(alignment: .topLeading) {
                if let bear = art.bearPicture {
                    Image(uiImage: bear)
                        .resizable()
                        .frame(width: art.bear.width, height: art.bear.height)
                        .position(x: art.bear.midX, y: art.bear.midY + drop)
                        .accessibilityHidden(true)
                }
                Group {
                    if let word = art.wordPicture { Image(uiImage: word).resizable() } else { Color.clear }
                }
                .frame(width: art.word.width, height: art.word.height)
                .position(x: art.word.midX, y: wordY)
                .opacity(stage == .leaving || stage == .gone ? 0 : 1)
                .accessibilityElement()
                .accessibilityLabel(Text(verbatim: "Poki"))
                .accessibilityAddTraits(.isHeader)
                words
                    .frame(width: min(screen.width - 48, 440))
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                    .position(x: screen.width / 2, y: contentTop + contentHeight / 2)
                    .opacity(showsWords ? 1 : 0)
                    .offset(y: showsWords ? 0 : 14)
                    .allowsHitTesting(showsWords)
            }
            .frame(width: screen.width, height: screen.height)
            .offset(x: -geometry.safeAreaInsets.leading, y: -geometry.safeAreaInsets.top)
        }
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    /// How far the bear goes down: as far as the words need, and out of sight when they need most of
    /// the page or the hello goes.
    private func bearDrop(room: CGFloat, height: CGFloat) -> CGFloat {
        switch stage {
        case .launch: return 0
        case .hello: return room <= 0 ? 0 : room < height * 0.55 ? room : height + 8
        case .leaving, .gone: return height + 8
        }
    }

    private var words: some View {
        VStack(spacing: 22) {
            VStack(spacing: 8) {
                Text(verbatim: headline)
                    .font(Prominent.font(size: 22, relativeTo: .title2, .semibold))
                    .foregroundStyle(Color(.label))
                Text(verbatim: line)
                    .font(.allo(.body))
                    .foregroundStyle(Tint.homeSecondary)
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 6) {
                Button(action: setUp) {
                    Text(kind == .firstRun ? LocalizedStringKey("Set Up Poki") : LocalizedStringKey("Check Setup"))
                        .font(.allo(.headline))
                        .padding(.horizontal, 26)
                        .frame(minHeight: 34)
                }
                .controlSize(.large)
                .glassButton()
                .accessibilityIdentifier("firstRun.primary")
                if kind != .firstRun {
                    Button(action: later) {
                        Text("Not Now").font(.allo(.subheadline, .medium)).foregroundStyle(Color(.label).opacity(0.72))
                            .frame(minWidth: 120, minHeight: 44).contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("firstRun.later")
                }
            }
        }
    }

    private var headline: String {
        switch kind {
        case .firstRun: AppLocalization.text(LocalizedStringResource("Hello, I’m Poki"))
        case .update(let version): AppLocalization.text(LocalizedStringResource("Poki \(version) Is Here"))
        }
    }

    private var line: String {
        switch kind {
        case .firstRun: AppLocalization.text(LocalizedStringResource("Tell me what you need, by text or by voice, and I do it on your iPhone while you watch."))
        case .update: AppLocalization.text(LocalizedStringResource("See what is set up and turn on what is new, all on one page."))
        }
    }
}

/// The launch screen's word and bear as LaunchScreen.storyboard lays them out on a screen of this size:
/// read from the storyboard's own view, so the hello's first frame is the launch screen's to the point
/// whatever the storyboard's constraints become, with its own pictures in this appearance.
@MainActor
struct LaunchArt {
    var word = CGRect.zero
    var bear = CGRect.zero
    var wordPicture: UIImage?
    var bearPicture: UIImage?

    private static var laidOut: [String: LaunchArt] = [:]

    static func on(_ screen: CGSize, dark: Bool) -> LaunchArt {
        let key = "\(screen.width)x\(screen.height)-\(dark)"
        if let known = laidOut[key] { return known }
        var art = LaunchArt()
        if screen.width > 0, screen.height > 0,
           let view = UIStoryboard(name: "LaunchScreen", bundle: .main).instantiateInitialViewController()?.view {
            view.frame = CGRect(origin: .zero, size: screen)
            view.layoutIfNeeded()
            let traits = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
            func picture(_ part: LaunchCurtain.Part) -> (CGRect, UIImage?) {
                guard let image = view.viewWithTag(part.rawValue) as? UIImageView else { return (.zero, nil) }
                let drawn = image.image.map { $0.imageAsset?.image(with: traits) ?? $0 }
                return (image.frame, drawn)
            }
            (art.word, art.wordPicture) = picture(.word)
            (art.bear, art.bearPicture) = picture(.bear)
            // The storyboard's word has its own Dark Mode picture (Poki/LaunchArt/README.md); should the
            // catalogue not have it, the hello still draws the dark word make-launch-art.swift writes
            // beside the light one, at the same size and place.
            if dark, let file = Bundle.main.path(forResource: "LaunchWordmarkDark@3x", ofType: "png"),
               let darkWord = UIImage(contentsOfFile: file) {
                art.wordPicture = darkWord
            }
        }
        laidOut[key] = art
        return art
    }
}

/// Settings' way back into the welcome: a blue text button that opens it over everything.
/// It carries its own cover, so whichever settings page lists the setup items places it with one line.
/// `wide` stretches it to the page width with a 44-point row, for pages that are not a List; `row`
/// draws it as a settings row, with the icon the rows beside it have.
struct FirstRunAgain: View {
    var wide = false
    var row = false
    @State private var welcoming = false

    var body: some View {
        Button { welcoming = true } label: {
            if row {
                SettingsRow(title: "Show Welcome Pages Again", symbol: "hand.wave").contentShape(.rect)
            } else {
                Text("Show Welcome Pages Again")
                    .foregroundStyle(Tint.blueText)
                    .frame(maxWidth: wide ? .infinity : nil, minHeight: wide ? 44 : nil)
                    .contentShape(.rect)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("setup.firstRun")
        .fullScreenCover(isPresented: $welcoming) { FirstRunGuide(link: .constant(nil), done: { welcoming = false }) }
    }
}
