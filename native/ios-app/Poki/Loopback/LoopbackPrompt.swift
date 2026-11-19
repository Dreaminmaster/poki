import SwiftUI

/// Asks the owner to turn the loopback on when Poki opens and Screen History needs it.
///
/// Backtape (Screen History and what Poki senses from it) reads this iPhone through the loopback,
/// all the time, not only during a task. When the owner opens Poki with Screen History on and the
/// loopback off, a small sheet says so and offers the one step that turns it back on: the proxy
/// app the owner chose in Setup, or Setup itself. Poki's own connection is no longer offered. On
/// cellular it offers the reconnect shortcut, which Setup offers with the loopback too. It waits for
/// the first check after Poki opens, closes by itself once the loopback answers, and Not Now keeps
/// it away for an hour.
struct LoopbackPrompt: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var capture = HistoryCapture.shared
    /// False while something else covers the app (Settings, the first-run guide).
    var enabled = true

    @State private var shown = false
    @State private var openedAt = Date.distantPast

    static let snoozeKey = "loopbackPrompt.snoozedUntil"
    static let snooze: TimeInterval = 3600

    func body(content: Content) -> some View {
        content
            .onChange(of: scenePhase, initial: true) { _, phase in
                if phase == .active {
                    openedAt = Date()
                } else {
                    shown = false
                }
            }
            .onChange(of: model.loopback.checkedAt) { decide() }
            .onChange(of: model.loopback.isWorking) { if model.loopback.isWorking { shown = false } }
            .onChange(of: enabled) { decide() }
            .sheet(isPresented: $shown, onDismiss: dismissed) {
                LoopbackPromptSheet(
                    action: action,
                    lastRead: capture.lastReadAt,
                    turnOn: turnOn,
                    notNow: { snoozeAndClose() }
                )
                .presentationDetents([.height(340)])
                .presentationDragIndicator(.visible)
            }
    }

    /// What turns the loopback on for this owner.
    enum Action: Equatable {
        case proxy(name: String, url: URL)
        case openSetup
        /// On cellular with the reconnect shortcut set up: Wi-Fi or the shortcut brings it back.
        case wiFi
        /// On cellular without the shortcut: iOS will not start the loopback, and the shortcut is
        /// what keeps it going there (offered with the loopback in Setup too).
        case shortcut
    }

    private var action: Action {
        if model.loopback.cellularOnly { return HistoryReconnect.shared.lastAt == nil ? .shortcut : .wiFi }
        if let app = ProxyApps.all.first(where: { $0.id == model.setup.proxyApp }), app.isInstalled, let url = URL(string: "\(app.scheme)://") {
            return .proxy(name: app.name, url: url)
        }
        return .openSetup
    }

    /// Shown once per opening, after the first check since Poki came to the front says the loopback
    /// is down. Never during a task, a first run, or while the owner snoozed it.
    private func decide() {
        guard enabled, scenePhase == .active, !shown, capture.enabled,
              let checked = model.loopback.checkedAt, checked > openedAt,
              !model.loopback.isWorking, model.loopback.state != .checking,
              !model.hasOpenInProcessSession, !FirstRun.isDue() else { return }
        let until = UserDefaults.standard.object(forKey: Self.snoozeKey) as? Date ?? .distantPast
        guard until < Date() else { return }
        // Once per opening: the next check of the same opening does not bring it back.
        openedAt = .distantFuture
        shown = true
    }

    private func turnOn() {
        switch action {
        case .proxy(_, let url):
            UIApplication.shared.open(url)
        case .openSetup:
            shown = false
            if let url = URL(string: "poki://setup") { UIApplication.shared.open(url) }
        case .wiFi:
            shown = false
        case .shortcut:
            UIApplication.shared.open(HistoryReconnect.shortcut)
        }
    }

    private func snoozeAndClose() {
        UserDefaults.standard.set(Date().addingTimeInterval(Self.snooze), forKey: Self.snoozeKey)
        shown = false
    }

    /// A swipe down counts as Not Now, unless the loopback came on.
    private func dismissed() {
        if !model.loopback.isWorking && scenePhase == .active {
            UserDefaults.standard.set(Date().addingTimeInterval(Self.snooze), forKey: Self.snoozeKey)
        }
    }
}

private struct LoopbackPromptSheet: View {
    let action: LoopbackPrompt.Action
    let lastRead: Date?
    let turnOn: () -> Void
    let notNow: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(Tint.blueText)
                .padding(.top, 8)
            Text("Turn On the Loopback")
                .font(.title3.weight(.semibold))
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: turnOn) {
                Text(primary)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("loopbackPrompt.turnOn")
            if action != .wiFi {
                Button("Not Now", action: notNow)
                    .accessibilityIdentifier("loopbackPrompt.notNow")
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
    }

    private var message: String {
        let reads: String
        if action == .shortcut {
            reads = AppLocalization.text(LocalizedStringResource("Screen History reads this iPhone through the loopback, and on cellular iOS does not let it start. The Poki shortcut turns it on again when Wi-Fi disconnects. Add it once and Poki keeps reading on cellular."))
        } else if action == .wiFi {
            reads = AppLocalization.text(LocalizedStringResource("Screen History reads this iPhone through the loopback, and on cellular iOS does not let it start. Connect to Wi-Fi and Poki turns it on again."))
        } else if let lastRead {
            let since = lastRead.formatted(.relative(presentation: .named))
            reads = AppLocalization.text(LocalizedStringResource("Screen History reads this iPhone through the loopback, and it is off. The last read was \(since)."))
        } else {
            reads = AppLocalization.text(LocalizedStringResource("Screen History reads this iPhone through the loopback, and it is off. Turn it on so Poki can keep reading."))
        }
        return reads
    }

    private var primary: String {
        switch action {
        case .proxy(let name, _): AppLocalization.text(LocalizedStringResource("Open \(name)"))
        case .openSetup: AppLocalization.text(LocalizedStringResource("Open Setup"))
        case .wiFi: AppLocalization.text(LocalizedStringResource("OK"))
        case .shortcut: AppLocalization.text(LocalizedStringResource("Get the Shortcut"))
        }
    }
}
