import AVFoundation
import Speech
import SwiftUI

/// What an earlier version of Poki left on this phone. None of it is written by this version before
/// launch has read it, so it tells an update (or a reinstall the Keychain restored) from a fresh install:
/// a saved conversation, or a setting an earlier version stored (setup progress, the relay, the model,
/// approvals, voice).
enum EarlierVersion {
    nonisolated static func leftTraces(defaults: UserDefaults, sessionsFolder: URL) -> Bool {
        let settings = ["setup", "relayAddress", "relayEnabled", "chat.provider", "chat.installationID", "approvals.ask", "wantsOn", "voice.model", WhatsNew.seenVersionKey]
        let conversations = (try? FileManager.default.contentsOfDirectory(at: sessionsFolder, includingPropertiesForKeys: nil))?
            .contains { $0.pathExtension == "json" } ?? false
        return conversations || settings.contains { defaults.object(forKey: $0) != nil }
    }
}

/// The first run: Poki says hello, then goes through what it needs (this iPhone, a model, the microphone),
/// each of which can wait, and says what to try. Someone who used an earlier version never sees it on
/// updating; it can be gone through again from Settings › Setup.
enum FirstRun {
    /// Absent until the first launch of a version with the first run decides it, once.
    static let key = "pokiFirstRun"
    enum Record: String { case due, done }

    /// Call at launch before anything this version writes to the defaults.
    nonisolated static func decide(defaults: UserDefaults = .standard, sessionsFolder: URL = SessionStore.defaultFolder) {
        guard defaults.string(forKey: key) == nil else { return }
        let record: Record = EarlierVersion.leftTraces(defaults: defaults, sessionsFolder: sessionsFolder) ? .done : .due
        defaults.set(record.rawValue, forKey: key)
    }

    /// Whether to show it at this launch. Scripted launches (the in-app tests, the screenshot and check
    /// scripts, which all pass `-poki…` arguments) have nobody to go through it; `-pokiScreen welcome` asks
    /// for it.
    static func isDue(defaults: UserDefaults = .standard) -> Bool {
        let arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        if arguments["pokiScreen"] as? String == "welcome" { return true }
        if ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil { return false }
        if arguments.keys.contains(where: { $0.hasPrefix("poki") }) { return false }
        return defaults.string(forKey: key) == Record.due.rawValue
    }

    static func finish(defaults: UserDefaults = .standard) { defaults.set(Record.done.rawValue, forKey: key) }
}

struct FirstRunGuide: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Opened again from Settings: the hello offers Not Now, and every step shows where it stands.
    var replay = false
    /// A setup step a link opened (a pairing file from Poki Setup) while the welcome is up.
    @Binding var link: SetupStep?
    var done: () -> Void

    @State private var shown = false
    @State private var path = NavigationPath()
    private let design = StartDesign.current

    init(replay: Bool = false, startAt: [StartRoute] = [],
         link: Binding<SetupStep?>, done: @escaping () -> Void) {
        self.replay = replay
        _link = link
        self.done = done
        _path = State(initialValue: NavigationPath(startAt))
    }

    var body: some View {
        NavigationStack(path: $path) {
            StartHello(design: design, replay: replay, shown: shown, setUp: openPanel, later: finish)
                .background { StartGround(design: design, hello: true) }
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: StartRoute.self) { route in
                    StartFlowPage(route: route, path: $path, finish: finish)
                }
                .welcomeDestinations(path: $path)
        }
        .environment(\.startDesign, design)
        .interactiveDismissDisabled()
        // Keep the existing limit until the panel's rows and buttons are verified at AX3–AX5.
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .onAppear {
            withAnimation(reduceMotion ? .easeInOut(duration: 0.3) : .spring(duration: 0.7, bounce: 0.12)) { shown = true }
        }
        .onChange(of: link, initial: true) { _, step in
            guard let step else { return }
            link = nil
            shown = true
            path = NavigationPath([step])
        }
    }

    private func openPanel() {
        guard shown, let first = StartRoute.order.first else { return }
        path.append(first)
    }

    private func finish() {
        FirstRun.finish()
        withAnimation(.easeInOut(duration: 0.3)) { done() }
    }
}
