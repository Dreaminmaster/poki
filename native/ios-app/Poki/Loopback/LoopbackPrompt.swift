import SwiftUI

/// Asks the owner to turn the loopback on when Poki opens and Screen History needs it.
///
/// Backtape (Screen History and what Poki senses from it) reads this iPhone through the loopback,
/// all the time, not only during a task. When the owner opens Poki with Screen History on and the
/// loopback off, a small sheet says so and offers the one step that turns it back on: Poki's own
/// connection, or the proxy app the owner chose in Setup. It waits for the first check after Poki
/// opens, closes by itself once the loopback answers, and Not Now keeps it away for an hour.
struct LoopbackPrompt: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var capture = HistoryCapture.shared
    /// False while something else covers the app (Settings, the first-run guide).
    var enabled = true

    @State private var shown = false
    @State private var openedAt = Date.distantPast
    @State private var turningOn = false
    @State private var failure: String?

    static let snoozeKey = "loopbackPrompt.snoozedUntil"
    static let snooze: TimeInterval = 3600

    func body(content: Content) -> some View {
        content
            .onChange(of: scenePhase, initial: true) { _, phase in
                if phase == .active {
                    openedAt = Date()
                    failure = nil
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
                    turningOn: turningOn,
                    failure: failure,
                    turnOn: turnOn,
                    notNow: { snoozeAndClose() }
                )
                .presentationDetents([.height(340)])
                .presentationDragIndicator(.visible)
            }
    }

    /// What turns the loopback on for this owner.
    enum Action: Equatable {
        case builtIn
        case proxy(name: String, url: URL)
        case openSetup
        case wiFi
    }

    private var action: Action {
        if model.loopback.cellularOnly { return .wiFi }
        switch model.setup.loopback {
        case .builtIn: return .builtIn
        case .proxy:
            if let app = ProxyApps.all.first(where: { $0.id == model.setup.proxyApp }), app.isInstalled, let url = URL(string: "\(app.scheme)://") {
                return .proxy(name: app.name, url: url)
            }
            return .openSetup
        case .none: return .openSetup
        }
    }

    /// Shown once per opening, after the first check since Poki came to the front says the loopback
    /// is down. Never during a task, a first run, or while the owner snoozed it.
    private func decide() {
        guard enabled, scenePhase == .active, !shown, capture.enabled, model.setup.loopback != .none,
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
        case .builtIn:
            turningOn = true
            failure = nil
            Task {
                do {
                    try await model.tunnel.connect()
                } catch {
                    failure = error.localizedDescription
                }
                model.loopback.check()
                turningOn = false
                // Screen History starts its run again on the new connection.
                if failure == nil { _ = await HistoryCollector.shared.reconnect(model, by: "the loopback prompt") }
            }
        case .proxy(_, let url):
            UIApplication.shared.open(url)
        case .openSetup:
            shown = false
            if let url = URL(string: "poki://setup") { UIApplication.shared.open(url) }
        case .wiFi:
            shown = false
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
    let turningOn: Bool
    let failure: String?
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
            if let failure {
                Text(failure)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
            Spacer(minLength: 0)
            Button(action: turnOn) {
                Group {
                    if turningOn {
                        ProgressView()
                    } else {
                        Text(primary)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(turningOn)
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
        if action == .wiFi {
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
        case .builtIn: AppLocalization.text(LocalizedStringResource("Turn On"))
        case .proxy(let name, _): AppLocalization.text(LocalizedStringResource("Open \(name)"))
        case .openSetup: AppLocalization.text(LocalizedStringResource("Open Setup"))
        case .wiFi: AppLocalization.text(LocalizedStringResource("OK"))
        }
    }
}
