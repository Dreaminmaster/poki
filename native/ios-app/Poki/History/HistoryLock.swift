import LocalAuthentication
import Security
import SwiftUI
import UIKit
import notify

/// The lock in front of Screen History (the owner, Nov 21 2026): only the iPhone's own Face ID, Touch ID
/// or passcode prompt opens it. Poki has no PIN of its own any more, and no lock screen or overlay of its
/// own: a row that leads behind the lock asks the system first and opens its page only once the prompt
/// has passed, so nothing shows before it.
///
/// The device's biometric always opens it. One choice, on Settings › Face ID & Passcode: Also Allow
/// iPhone Passcode, under the biometric, never in its place (the owner, Nov 21 2026). An iPhone with no
/// biometric set up can use Senses only after the owner acknowledged the risk: then its passcode opens
/// history.
@MainActor
final class HistoryLock: ObservableObject {
    static let shared = HistoryLock(boundary: .live, agentGrantChanged: HistoryCapture.setAgentHistoryUnlocked)

    enum State: Equatable {
        case locked
        case unlocked
        /// Neither a biometric nor a passcode is set up on this iPhone: nothing can stand in front of
        /// history until one is, in the iPhone's Settings.
        case unavailable
        /// The iPhone itself is locked (protected data is gone): nothing opens until it is unlocked.
        case deviceLocked
    }

    struct Biometrics: Equatable {
        var ready: Bool
        var name: String
        var blockedOrDeniedOnHardware: Bool
    }

    /// What the lock reads from outside Poki's memory: the iPhone's Face ID or Touch ID, whether a
    /// passcode is set, the system prompt, and Poki's settings.
    struct Boundary {
        var biometrics: @MainActor () -> Biometrics
        var passcodeSet: @MainActor () -> Bool
        /// The system prompt. `passcode`: the passcode is offered too (and is the way in without a biometric).
        var evaluate: @MainActor (_ reason: String, _ passcode: Bool) async -> Bool
        /// Poki's PIN and its set-up mark, from before Nov 21 2026, removed once.
        var forgetPIN: @MainActor () -> Void
        var defaults: UserDefaults
    }

    @Published private(set) var state: State = .locked
    /// The owner's choice: the passcode works too, under the biometric.
    @Published private(set) var passcodeOn: Bool
    /// The owner read the warning that, without Face ID or Touch ID, only the passcode guards history.
    @Published private(set) var riskAccepted: Bool
    @Published private(set) var biometrics: Biometrics
    /// A system prompt is up: rows that lead behind the lock wait instead of asking twice.
    @Published private(set) var asking = false

    private let boundary: Boundary
    /// Only the live lock owns the production grant. Test boundaries may observe their own grants.
    private let agentGrantChanged: ((Bool) -> Void)?
    private var agentGrantOpen = false
    private var protectedDataUnavailable = false
    /// The prompt in flight. Locking while it is up makes its answer stale.
    private var attempt: UUID?
    private var passcodeSet: Bool
    static let riskKey = "history.lock.noBiometricsAccepted"
    static let passcodeKey = "history.lock.passcode"
    private static let forgotPINKey = "history.lock.pinRemoved"
    private let subscriptions = Subscriptions()

    private final class Subscriptions {
        var observers: [NSObjectProtocol] = []
        var enrollmentToken: Int32 = NOTIFY_TOKEN_INVALID

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
            if enrollmentToken != NOTIFY_TOKEN_INVALID { notify_cancel(enrollmentToken) }
        }
    }

    init(boundary: Boundary, agentGrantChanged: ((Bool) -> Void)? = nil) {
        self.boundary = boundary
        self.agentGrantChanged = agentGrantChanged
        riskAccepted = boundary.defaults.bool(forKey: Self.riskKey)
        passcodeOn = boundary.defaults.object(forKey: Self.passcodeKey) as? Bool ?? false
        biometrics = boundary.biometrics()
        passcodeSet = boundary.passcodeSet()
        if !boundary.defaults.bool(forKey: Self.forgotPINKey) {
            boundary.forgetPIN()
            boundary.defaults.set(true, forKey: Self.forgotPINKey)
        }
        apply(settled(.locked))
        let center = NotificationCenter.default
        subscriptions.observers = [
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.lock() }
            },
            center.addObserver(forName: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.protectedDataUnavailable = true
                    self?.attempt = nil
                    self?.apply(.deviceLocked)
                }
            },
            center.addObserver(forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.protectedDataUnavailable = false
                    self?.refresh()
                }
            },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            },
        ]
        // Not documented for apps; coming back to the foreground reads Face ID again either way.
        notify_register_dispatch("com.apple.BiometricKit.enrollmentChanged", &subscriptions.enrollmentToken, DispatchQueue.main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    var unlocked: Bool { state == .unlocked }
    var unavailable: Bool { state == .unavailable }

    /// Face ID or Touch ID is set up on this iPhone and allowed for Poki.
    var biometricsReady: Bool { biometrics.ready }
    /// The biometric is what the prompt asks for, always where the iPhone has one.
    var usesBiometrics: Bool { biometrics.ready }
    /// The passcode opens history: by the owner's choice, or because there is no biometric to use.
    var usesPasscode: Bool { passcodeSet && (passcodeOn || !usesBiometrics) }
    /// Whether the passcode switch may be turned off: only with a biometric left to use.
    var canTurnOffPasscode: Bool { usesBiometrics }
    /// No Face ID or Touch ID, and the owner has not yet accepted that only the passcode guards history:
    /// Senses stays closed until they do.
    var needsRiskAcknowledgement: Bool { !biometrics.ready && !riskAccepted && state != .unavailable }

    /// The owner accepted the warning (Senses without Face ID or Touch ID).
    func acceptRisk() {
        riskAccepted = true
        boundary.defaults.set(true, forKey: Self.riskKey)
    }

    /// "Face ID", "Touch ID" or "Optic ID", as this iPhone has it.
    var biometricsName: String { biometrics.name }
    /// The same name in Poki's language.
    var biometricsLabel: String { AppLocalization.bundle.localizedString(forKey: biometricsName, value: nil, table: nil) }
    var biometricsSymbol: String {
        switch biometricsName {
        case "Touch ID": "touchid"
        case "Optic ID": "opticid"
        default: "faceid"
        }
    }

    /// Opens history with the system prompt. True once it is open, at once when it already was. The
    /// caller opens its page only after this returns true.
    @discardableResult
    func open(_ reason: String = AppLocalization.text("Unlock Screen History")) async -> Bool {
        refresh()
        if unlocked { return true }
        guard state == .locked, !asking, !needsRiskAcknowledgement else { return false }
        let mine = UUID()
        attempt = mine
        asking = true
        let passed = await boundary.evaluate(reason, usesPasscode)
        asking = false
        // Locked (the app left, the iPhone locked) while the prompt was up: the answer is stale.
        guard attempt == mine, !protectedDataUnavailable else { return false }
        attempt = nil
        guard passed else { return false }
        apply(.unlocked)
        return true
    }

    /// Asks the system prompt again for something that cannot be undone (clearing, forgetting). The
    /// page stays as it is; nothing is unlocked or locked by it.
    func confirm(_ reason: String) async -> Bool {
        refresh()
        guard state == .locked || state == .unlocked, !asking else { return false }
        asking = true
        defer { asking = false }
        return await boundary.evaluate(reason, usesPasscode)
    }

    /// Turns the iPhone passcode on or off for history, after the system prompt. Refused when it would
    /// leave no way in.
    func setPasscode(_ on: Bool) async -> Bool {
        guard on || canTurnOffPasscode else { return false }
        guard await confirm(AppLocalization.text("Change how Screen History unlocks")) else { return false }
        return changePasscode(on)
    }

    /// The change itself, once the owner passed the prompt (tests call it directly).
    @discardableResult
    func changePasscode(_ on: Bool) -> Bool {
        guard on || canTurnOffPasscode else { return false }
        relock()
        passcodeOn = on
        boundary.defaults.set(on, forKey: Self.passcodeKey)
        return true
    }

    func lock() {
        attempt = nil
        relock()
    }

    /// Reads the iPhone again, as when Poki comes back from Settings.
    func refresh() {
        let bio = boundary.biometrics()
        if biometrics != bio { biometrics = bio }
        // With a biometric back, a later loss of it asks for the warning again.
        if bio.ready, riskAccepted {
            riskAccepted = false
            boundary.defaults.removeObject(forKey: Self.riskKey)
        }
        let code = boundary.passcodeSet()
        if passcodeSet != code { passcodeSet = code }
        apply(settled(state))
    }

    // MARK: State

    private func relock() {
        publishAgentGrant(false)
        apply(settled(.locked))
    }

    /// What `state` becomes given what the iPhone has now.
    private func settled(_ state: State) -> State {
        if protectedDataUnavailable { return .deviceLocked }
        if !biometrics.ready && !passcodeSet { return .unavailable }
        switch state {
        case .unlocked: return .unlocked
        case .locked, .unavailable, .deviceLocked: return .locked
        }
    }

    /// The single state publication boundary: the agents' grant follows the state, revoked first.
    private func apply(_ next: State) {
        if next != .unlocked { publishAgentGrant(false) }
        if state != next { state = next }
        publishAgentGrant(next == .unlocked)
    }

    private func publishAgentGrant(_ open: Bool) {
        guard agentGrantOpen != open else { return }
        agentGrantOpen = open
        agentGrantChanged?(open)
    }
}

extension HistoryLock.Boundary {
    private static let service = "nz.zheha.poki.history-lock"

    static var live: Self {
        Self(
            biometrics: {
                let context = LAContext()
                var error: NSError?
                let ready = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
                let name: String = switch context.biometryType {
                case .touchID: "Touch ID"
                case .opticID: "Optic ID"
                default: "Face ID"
                }
                let code = error?.code
                let blockedOrDenied = code == LAError.biometryLockout.rawValue
                    || (context.biometryType != .none && code == LAError.biometryNotAvailable.rawValue)
                return HistoryLock.Biometrics(ready: ready, name: name, blockedOrDeniedOnHardware: blockedOrDenied)
            },
            passcodeSet: {
                var error: NSError?
                let can = LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
                return can || error?.code != LAError.passcodeNotSet.rawValue
            },
            evaluate: { reason, passcode in
                let context = LAContext()
                if passcode {
                    // Face ID or Touch ID first where it is on, with Enter Passcode under it.
                    return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
                }
                // No Enter Passcode button: the owner chose the biometric alone.
                context.localizedFallbackTitle = ""
                return (try? await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)) ?? false
            },
            forgetPIN: {
                let match: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
                SecItemDelete(match as CFDictionary)
                UserDefaults.standard.removeObject(forKey: "history.lock.install")
            },
            defaults: .standard
        )
    }
}

// MARK: Views

/// A page behind the lock, for a link that the system prompt already opened. The page draws nothing
/// of its own content until history is open: after Poki comes back from the background it asks the
/// system prompt again over a plain ground, and goes back if the owner cancels.
struct HistoryGate<Content: View>: View {
    @ObservedObject var lock = HistoryLock.shared
    @ObservedObject var capture = HistoryCapture.shared
    /// Open without an unlock while Screen History is off: nothing read off the screen is behind it.
    var whenOff = false
    @ViewBuilder var content: () -> Content
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase

    private var open: Bool { lock.unlocked || (whenOff && !capture.enabled) }

    var body: some View {
        Group {
            if open {
                content()
            } else if lock.unavailable {
                HistoryNoPasscodePage()
            } else if lock.needsRiskAcknowledgement {
                HistoryNoBiometricsPage()
            } else {
                // The ground only, while the system prompt is up.
                Color.clear.settingsPage()
            }
        }
        .task(id: phase) {
            guard phase == .active, !open, !lock.unavailable, !lock.needsRiskAcknowledgement else { return }
            if await lock.open() == false, !lock.unlocked { dismiss() }
        }
    }
}

/// An iPhone with neither a biometric nor a passcode: the one thing to do is in the iPhone's Settings.
struct HistoryNoPasscodePage: View {
    var body: some View {
        List {
            Section {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    Button { UIApplication.shared.open(url) } label: {
                        SettingsRow(title: "Open Settings", symbol: "gear", accessory: .leaves)
                    }
                }
            } header: {
                Group {
                    Text("Set a Passcode First")
                }
                .settingsHeader()
            } footer: {
                Group {
                    Text("Screen History opens with the iPhone’s Face ID, Touch ID or passcode. Set a passcode in Settings › Face ID & Passcode, then come back.")
                }
                .settingsFooter()
            }
        }
        .settingsPage()
    }
}

/// An iPhone without Face ID or Touch ID: Senses opens only after the owner read what that means
/// (the owner, Nov 21 2026) and chose to go on with the passcode alone.
struct HistoryNoBiometricsPage: View {
    @ObservedObject private var lock = HistoryLock.shared

    var body: some View {
        List {
            Section {
                Button(role: .destructive) {
                    lock.acceptRisk()
                    Task { await lock.open() }
                } label: {
                    Text("Use Senses with the Passcode Only").frame(maxWidth: .infinity)
                }
                .accessibilityIdentifier("lock.acceptRisk")
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    Button { UIApplication.shared.open(url) } label: {
                        SettingsRow(title: "Open Settings", symbol: "gear", accessory: .leaves)
                    }
                }
            } header: {
                Group {
                    HistoryRiskText.title
                }
                .settingsHeader()
            } footer: {
                Group {
                    HistoryRiskText.body
                }
                .settingsFooter()
            }
        }
        .settingsPage()
    }
}

/// The warning's words, on the page above and in the alert before Screen History turns on.
enum HistoryRiskText {
    static var title: Text { Text("No Face ID or Touch ID") }
    static var body: Text {
        Text("Senses keeps what was on your screen. Without Face ID or Touch ID set up, anyone who knows or sees your iPhone passcode can open it, and agents can be given it after a passcode alone. Set up Face ID or Touch ID in Settings to protect it properly.")
    }
}

/// A row that opens a page behind the lock: it looks like a navigation row, asks the system prompt
/// first, and only then opens its page (the owner, Nov 21 2026: nothing may show before the prompt is
/// done). Already open, or with Screen History off and `whenOff`, it opens at once.
struct UnlockLink<Label: View>: View {
    @ObservedObject private var lock = HistoryLock.shared
    @ObservedObject private var capture = HistoryCapture.shared
    var whenOff = false
    var go: () -> Void
    @ViewBuilder var label: () -> Label

    var body: some View {
        Button {
            Task {
                // No passcode at all, or the warning to read first: the page itself says so.
                if (whenOff && !capture.enabled) || lock.unavailable || lock.needsRiskAcknowledgement {
                    go()
                } else if await lock.open() {
                    go()
                }
            }
        } label: {
            HStack(spacing: 8) {
                label()
                Chevron()
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(lock.asking)
    }
}

/// Settings › Face ID & Passcode: the device's biometric and the iPhone passcode, with or in place of
/// it. One of them always stays on; changing either asks the system prompt first.
struct HistoryLockSettings: View {
    @ObservedObject private var lock = HistoryLock.shared
    @State private var refused = 0

    var body: some View {
        List {
            Section {
                SettingsRow(title: LocalizedStringKey(lock.biometricsName), symbol: lock.biometricsSymbol,
                            value: AppLocalization.text(lock.biometricsReady ? LocalizedStringResource("On") : LocalizedStringResource("Not Set Up")),
                            warns: !lock.biometricsReady)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("lock.biometrics")
            } footer: {
                Group {
                    if lock.biometricsReady {
                        EmptyView()
                    } else if lock.biometrics.blockedOrDeniedOnHardware {
                        Text(verbatim: String(format: AppLocalization.text("%@ is off for Poki. Turn it on in Settings › Poki."), lock.biometricsLabel))
                    } else {
                        Text(verbatim: String(format: AppLocalization.text("%@ is not set up on this iPhone, so only the passcode guards Senses. Set it up in Settings › %@ & Passcode."), lock.biometricsLabel, lock.biometricsLabel))
                    }
                }
                .settingsFooter()
            }
            Section {
                Toggle(isOn: Binding(get: { lock.usesPasscode }, set: { on in
                    Task { if await lock.setPasscode(on) == false { refused += 1 } }
                })) {
                    SettingsRow(title: "Also Allow iPhone Passcode", symbol: "lock")
                }
                .disabled(!lock.canTurnOffPasscode || lock.asking)
                .accessibilityIdentifier("lock.passcode")
            } footer: {
                Group {
                    if !lock.usesBiometrics {
                        Text("Without Face ID or Touch ID, the iPhone passcode opens Senses.")
                    } else {
                        Text(verbatim: String(format: AppLocalization.text("Off, only %@ opens Senses. On, Enter Passcode is offered when %@ does not work."), lock.biometricsLabel, lock.biometricsLabel))
                    }
                }
                .settingsFooter()
            }
        }
        .sensoryFeedback(.error, trigger: refused)
        .navigationTitle(lock.biometricsName == "Touch ID" ? AppLocalization.text("Touch ID & Passcode") : AppLocalization.text("Face ID & Passcode"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { lock.refresh() }
    }
}
