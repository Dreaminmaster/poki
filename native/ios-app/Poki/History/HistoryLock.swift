import CryptoKit
import LocalAuthentication
import Security
import SwiftUI
import UIKit
import notify

/// The lock in front of iPhone History (the owner, 2026-11-14): its pages open only after Face ID or
/// Touch ID, with no fall back to the iPhone's passcode, or after a PIN that belongs to Poki alone.
/// Either one can be turned off, but never both.
@MainActor
final class HistoryLock: ObservableObject {
    static let shared = HistoryLock(boundary: .live, agentGrantChanged: HistoryCapture.setAgentHistoryUnlocked)

    enum AuthMethods: Equatable {
        case biometricsOnly
        case pinOnly
        case biometricsAndPIN

        init?(biometrics: Bool, pin: Bool) {
            switch (biometrics, pin) {
            case (true, true): self = .biometricsAndPIN
            case (true, false): self = .biometricsOnly
            case (false, true): self = .pinOnly
            case (false, false): return nil
            }
        }

        var usesBiometrics: Bool { self != .pinOnly }
        var hasPIN: Bool { self != .biometricsOnly }
    }

    struct PINCooldown: Equatable {
        var failures = 0
        var blockedUntil: Date?
    }

    enum State: Equatable {
        case unconfigured
        case locked(methods: AuthMethods, evaluatingBiometrics: UUID?, cooldown: PINCooldown)
        case biometricsUnavailable
        case deviceLocked
        case unlocked(methods: AuthMethods)
    }

    enum KeychainRead: Equatable {
        case present(Data)
        case absent
        case inaccessibleWhileDeviceLocked
    }

    struct Biometrics: Equatable {
        var ready: Bool
        var name: String
        var blockedOrDeniedOnHardware: Bool
    }

    /// What the lock reads from and writes to outside Poki's memory: the iPhone's Face ID or Touch ID,
    /// the keychain, Poki's settings, Screen History's store and the clock.
    struct Boundary {
        var biometrics: @MainActor () -> Biometrics
        var evaluateBiometrics: @MainActor (_ reason: String) async -> Bool
        var readKeychain: @MainActor (_ account: String) -> KeychainRead
        var writeKeychain: @MainActor (_ account: String, _ value: Data, _ accessible: CFString) -> Bool
        var deleteKeychain: @MainActor (_ account: String) -> Void
        var defaults: UserDefaults
        /// Nil while the store cannot be read.
        var historyHoldsAnything: @MainActor () -> Bool?
        var now: @MainActor () -> Date
    }

    private struct Environment {
        let biometricsOn: Bool
        let biometrics: Biometrics
        let storedPIN: KeychainRead
        let armed: Bool
    }

    private enum Event {
        case refresh
        case enteredBackground
        case protectedDataUnavailable
        case protectedDataAvailable
        case beginBiometrics(UUID)
        case finishBiometrics(attempt: UUID, passed: Bool)
        case setPIN(String)
        case unlockWithPIN(String)
        case removePIN
        case setBiometrics(Bool)
        case readStarting
    }

    /// Changes only on events (a lock action, the app coming back, the phone unlocking, a Face ID
    /// change), so the pages read it without asking the keychain or the iPhone each time they draw.
    @Published private(set) var state: State = .unconfigured
    /// The owner's choice. Whether it can be used also depends on the iPhone (`biometricsReady`).
    @Published private(set) var biometricsOn: Bool
    @Published private(set) var biometrics: Biometrics

    private let boundary: Boundary
    /// Only the live lock owns the production grant. Test boundaries may observe their own grants.
    private let agentGrantChanged: ((Bool) -> Void)?
    private var agentGrantOpen = false
    /// The will-become-unavailable event precedes the keychain losing access.
    private var protectedDataUnavailable = false
    private static let pinAccount = "pin"
    private static let armedAccount = "armed"
    private static let biometricsKey = "history.lock.biometrics"
    /// This install of Poki. The keychain outlives a deleted app, Poki's settings and Screen History do
    /// not, so the mark that the lock was set up counts only for the install that wrote it.
    private static let installKey = "history.lock.install"
    private let subscriptions = Subscriptions()

    /// What the lock listens to, given back when the lock goes.
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
        biometricsOn = boundary.defaults.object(forKey: Self.biometricsKey) as? Bool ?? true
        biometrics = boundary.biometrics()
        _ = transition(.refresh)
        let center = NotificationCenter.default
        subscriptions.observers = [
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.lock() }
            },
            center.addObserver(forName: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { _ = self?.transition(.protectedDataUnavailable) }
            },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            },
            center.addObserver(forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { _ = self?.transition(.protectedDataAvailable) }
            },
        ]
        // Not documented for apps; coming back to the foreground reads Face ID again either way.
        notify_register_dispatch("com.apple.BiometricKit.enrollmentChanged", &subscriptions.enrollmentToken, DispatchQueue.main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    var unlocked: Bool {
        if case .unlocked = state { return true }
        return false
    }

    var hasPIN: Bool {
        switch state {
        case .locked(let methods, _, _), .unlocked(let methods): return methods.hasPIN
        case .unconfigured, .biometricsUnavailable, .deviceLocked: return false
        }
    }

    // MARK: Biometrics

    /// Face ID or Touch ID is set up on this iPhone and allowed for Poki.
    var biometricsReady: Bool { biometrics.ready }

    var usesBiometrics: Bool {
        switch state {
        case .locked(let methods, _, _), .unlocked(let methods): return methods.usesBiometrics
        case .unconfigured, .biometricsUnavailable, .deviceLocked: return false
        }
    }

    /// "Face ID", "Touch ID" or "Optic ID", as this iPhone has it.
    var biometricsName: String { biometrics.name }

    /// The same name in Poki's language.
    var biometricsLabel: String { AppLocalization.bundle.localizedString(forKey: biometricsName, value: nil, table: nil) }

    /// Nothing can unlock history yet: a PIN has to be made first.
    var needsSetup: Bool { state == .unconfigured }

    var biometricsUnavailable: Bool { state == .biometricsUnavailable }

    var failures: Int {
        if case .locked(_, _, let cooldown) = state { return cooldown.failures }
        return 0
    }

    var blockedUntil: Date? {
        if case .locked(_, _, let cooldown) = state { return cooldown.blockedUntil }
        return nil
    }

    func unlockWithBiometrics() async {
        let attempt = UUID()
        guard transition(.beginBiometrics(attempt)) else { return }
        let passed = await boundary.evaluateBiometrics(AppLocalization.text("Unlock Screen History"))
        _ = transition(.finishBiometrics(attempt: attempt, passed: passed))
    }

    /// Asks for Face ID or Touch ID again, for something that cannot be undone. The page stays as it is.
    func confirm(_ reason: String) async -> Bool {
        guard usesBiometrics else { return false }
        return await boundary.evaluateBiometrics(reason)
    }

    // MARK: PIN

    static func valid(_ pin: String) -> Bool { (4...8).contains(pin.count) && pin.allSatisfy(\.isNumber) }

    /// Keeps a new PIN. Allowed while history is unlocked, or when nothing can unlock it yet.
    @discardableResult
    func setPIN(_ pin: String) -> Bool { transition(.setPIN(pin)) }

    func unlock(pin: String) -> Bool { transition(.unlockWithPIN(pin)) }

    /// Removes the PIN. Refused unless Face ID or Touch ID stays as the way in.
    @discardableResult
    func removePIN() -> Bool { transition(.removePIN) }

    /// Turns Face ID or Touch ID on or off for history. Turning it off is refused without a PIN.
    @discardableResult
    func setBiometrics(_ on: Bool) -> Bool { transition(.setBiometrics(on)) }

    func lock() { _ = transition(.enteredBackground) }

    /// Reads the iPhone and the keychain again, as when Poki comes back from Settings.
    func refresh() { _ = transition(.refresh) }

    /// A read is about to start. With a way in already there (Face ID, Touch ID or a PIN), the lock
    /// counts as set up from now on, so what the read keeps never waits behind a first PIN.
    func readStarting() { _ = transition(.readStarting) }

    // MARK: State machine

    @discardableResult
    private func transition(_ event: Event) -> Bool {
        // Revoke synchronously before credential I/O and before the device loses protected data.
        // Only this transition may restore a grant, once the final state is known.
        defer { publishAgentGrant(unlocked) }
        switch event {
        case .enteredBackground, .setPIN, .removePIN, .setBiometrics:
            publishAgentGrant(false)
        case .protectedDataUnavailable:
            protectedDataUnavailable = true
            publishAgentGrant(false)
            apply(.deviceLocked)
            return true
        case .protectedDataAvailable:
            protectedDataUnavailable = false
        default: break
        }
        guard !protectedDataUnavailable else {
            apply(.deviceLocked)
            return false
        }
        let now = boundary.now()
        var env = readEnvironment()
        let current = Self.reconcile(state, env: env, now: now)
        apply(current)

        let next: State
        let accepted: Bool

        switch event {
        case .refresh, .protectedDataAvailable:
            next = current
            accepted = true

        case .protectedDataUnavailable:
            next = .deviceLocked
            accepted = true

        case .enteredBackground:
            let base: State = switch current {
            case .unlocked(let methods):
                .locked(methods: methods, evaluatingBiometrics: nil, cooldown: PINCooldown())
            case .locked(let methods, _, let cooldown):
                .locked(methods: methods, evaluatingBiometrics: nil, cooldown: cooldown)
            case .unconfigured, .biometricsUnavailable, .deviceLocked:
                current
            }
            next = Self.reconcile(base, env: env, now: now)
            accepted = true

        case .beginBiometrics(let attempt):
            guard case .locked(let methods, nil, let cooldown) = current, methods.usesBiometrics else {
                return refuse(current)
            }
            next = .locked(methods: methods, evaluatingBiometrics: attempt, cooldown: cooldown)
            accepted = true

        case .finishBiometrics(let attempt, let passed):
            guard case .locked(let methods, let active?, let cooldown) = current, active == attempt else {
                return refuse(current)
            }
            if passed, methods.usesBiometrics {
                markArmed()
                next = .unlocked(methods: methods)
                accepted = true
            } else {
                next = .locked(methods: methods, evaluatingBiometrics: nil, cooldown: cooldown)
                accepted = false
            }

        case .setPIN(let pin):
            let allowed = switch current {
            case .unconfigured, .unlocked: true
            case .locked, .biometricsUnavailable, .deviceLocked: false
            }
            guard Self.valid(pin), allowed, let sealed = Self.seal(pin) else {
                return refuse(current)
            }
            guard boundary.writeKeychain(Self.pinAccount, sealed, kSecAttrAccessibleWhenUnlockedThisDeviceOnly) else {
                // The keychain replacement may have removed the old PIN before failing.
                // Never restore an unlocked grant on the strength of that old credential.
                return refuse(Self.reconcile(Self.closed(current), env: readEnvironment(), now: now))
            }
            markArmed()
            env = readEnvironment()
            guard let methods = AuthMethods(biometrics: env.biometricsOn && env.biometrics.ready, pin: true) else {
                return false
            }
            next = .unlocked(methods: methods)
            accepted = true

        case .unlockWithPIN(let pin):
            switch current {
            case .locked(let methods, let attempt, var cooldown) where methods.hasPIN:
                if let until = cooldown.blockedUntil, until > now {
                    return refuse(current)
                }
                guard case .present(let value) = env.storedPIN else {
                    return refuse(current)
                }
                if Self.matchesPIN(pin, stored: value) {
                    markArmed()
                    next = .unlocked(methods: methods)
                    accepted = true
                } else {
                    cooldown.failures += 1
                    // Five wrong tries in a row, then a wait that doubles: 30 s, 1 min, 2 min, up to an hour.
                    if cooldown.failures >= 5 {
                        cooldown.blockedUntil = now.addingTimeInterval(min(3600, 30 * pow(2, Double(cooldown.failures - 5))))
                    }
                    next = .locked(methods: methods, evaluatingBiometrics: attempt, cooldown: cooldown)
                    accepted = false
                }
            case .unlocked(let methods) where methods.hasPIN:
                guard case .present(let value) = env.storedPIN else { return false }
                next = current
                accepted = Self.matchesPIN(pin, stored: value)
            default:
                return refuse(current)
            }

        case .removePIN:
            guard case .unlocked(.biometricsAndPIN) = current else {
                return refuse(current)
            }
            boundary.deleteKeychain(Self.pinAccount)
            next = .unlocked(methods: .biometricsOnly)
            accepted = true

        case .readStarting:
            switch current {
            case .locked, .unlocked: markArmed()
            case .unconfigured, .biometricsUnavailable, .deviceLocked: break
            }
            next = current
            accepted = true

        case .setBiometrics(let on):
            guard case .unlocked(let methods) = current, on || methods.hasPIN,
                  let updated = AuthMethods(biometrics: on && env.biometrics.ready, pin: methods.hasPIN) else {
                return refuse(current)
            }
            biometricsOn = on
            boundary.defaults.set(on, forKey: Self.biometricsKey)
            if on, env.biometrics.ready { markArmed() }
            next = .unlocked(methods: updated)
            accepted = true
        }

        apply(next)
        return accepted
    }

    /// The single state publication boundary. Revoke before changing any authorization state;
    /// transition's defer restores a grant only if the final state is unlocked.
    private func apply(_ next: State) {
        guard state != next else { return }
        publishAgentGrant(false)
        state = next
    }

    private func publishAgentGrant(_ open: Bool) {
        guard agentGrantOpen != open else { return }
        agentGrantOpen = open
        agentGrantChanged?(open)
    }

    private static func closed(_ state: State) -> State {
        if case .unlocked(let methods) = state {
            return .locked(methods: methods, evaluatingBiometrics: nil, cooldown: PINCooldown())
        }
        return state
    }

    /// Refuses an event: the state catches up with what was just read, and nothing else changes.
    private func refuse(_ current: State) -> Bool {
        apply(current)
        return false
    }

    private func readEnvironment() -> Environment {
        let on = boundary.defaults.object(forKey: Self.biometricsKey) as? Bool ?? true
        let bio = boundary.biometrics()
        if biometricsOn != on { biometricsOn = on }
        if biometrics != bio { biometrics = bio }
        forgetADeletedInstall()
        let pin = boundary.readKeychain(Self.pinAccount)
        let armed = pin != .absent || armedOnThisInstall() || adoptKeptHistory(biometricsOn: on, biometrics: bio)
        return Environment(biometricsOn: on, biometrics: bio, storedPIN: pin, armed: armed)
    }

    private static func reconcile(_ state: State, env: Environment, now: Date) -> State {
        let knownHasPIN: Bool = switch state {
        case .locked(let methods, _, _), .unlocked(let methods): methods.hasPIN
        case .unconfigured, .biometricsUnavailable, .deviceLocked: false
        }
        let hasPIN: Bool = switch env.storedPIN {
        case .present: true
        case .absent: false
        case .inaccessibleWhileDeviceLocked: knownHasPIN
        }
        let usesBiometrics = env.biometricsOn && env.biometrics.ready
        if case .inaccessibleWhileDeviceLocked = env.storedPIN { return .deviceLocked }
        guard let methods = AuthMethods(biometrics: usesBiometrics, pin: hasPIN) else {
            return env.armed ? .biometricsUnavailable : .unconfigured
        }
        switch state {
        case .unlocked:
            return .unlocked(methods: methods)
        case .locked(let previousMethods, let activeAttempt, var cooldown):
            if let until = cooldown.blockedUntil, until <= now { cooldown.blockedUntil = nil }
            // A callback from a previous authentication-method configuration is stale.
            return .locked(methods: methods, evaluatingBiometrics: methods.usesBiometrics && previousMethods == methods ? activeAttempt : nil, cooldown: cooldown)
        case .unconfigured, .biometricsUnavailable, .deviceLocked:
            return .locked(methods: methods, evaluatingBiometrics: nil, cooldown: PINCooldown())
        }
    }

    // MARK: Set-up mark

    /// The lock was set up on this install: Face ID or Touch ID opened history, or a PIN was made or used.
    /// From then on, losing Face ID or Touch ID leads to Settings and never to making a first PIN.
    private func armedOnThisInstall() -> Bool {
        switch boundary.readKeychain(Self.armedAccount) {
        case .inaccessibleWhileDeviceLocked: return true
        case .absent: return false
        case .present(let mark): return boundary.defaults.string(forKey: Self.installKey).map { Data($0.utf8) == mark } ?? false
        }
    }

    private func markArmed() {
        let install: String
        if let known = boundary.defaults.string(forKey: Self.installKey) {
            install = known
        } else {
            install = UUID().uuidString
            boundary.defaults.set(install, forKey: Self.installKey)
        }
        let mark = Data(install.utf8)
        guard boundary.readKeychain(Self.armedAccount) != .present(mark) else { return }
        _ = boundary.writeKeychain(Self.armedAccount, mark, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
    }

    /// History kept while the lock was not set up yet stays behind the Face ID or Touch ID that could
    /// open it: reads kept before Screen History was first opened, and history from an earlier Poki that
    /// had no set-up mark. Asked on every event until the lock is set up, so a read counts once it is kept,
    /// also when Face ID is locked out or turned off for Poki after it. An iPhone without Face ID or
    /// Touch ID had nothing guarding its history and still makes a first PIN.
    private func adoptKeptHistory(biometricsOn on: Bool, biometrics bio: Biometrics) -> Bool {
        guard on, bio.ready || bio.blockedOrDeniedOnHardware else { return false }
        switch boundary.historyHoldsAnything() {
        case true?:
            markArmed()
            return true
        case false?:
            return false
        case nil:
            // The store cannot be read just now: no first PIN until it can be.
            return true
        }
    }

    /// A deleted Poki leaves its PIN and set-up mark in the keychain; its history went with it. While
    /// the mark is another install's and this install's history is empty, they guard nothing, and the
    /// PIN may be long forgotten.
    private func forgetADeletedInstall() {
        guard case .present(let mark) = boundary.readKeychain(Self.armedAccount),
              boundary.defaults.string(forKey: Self.installKey).map({ Data($0.utf8) != mark }) ?? true,
              boundary.historyHoldsAnything() == false else { return }
        boundary.deleteKeychain(Self.pinAccount)
        boundary.deleteKeychain(Self.armedAccount)
    }

    // MARK: PIN storage

    private static func digest(_ pin: String, salt: Data) -> Data {
        var hash = Data(SHA256.hash(data: salt + Data(pin.utf8)))
        // Stretched, so the short PIN is slow to try from a copy of the stored value.
        for _ in 0..<20_000 { hash = Data(SHA256.hash(data: salt + hash)) }
        return hash
    }

    private static func seal(_ pin: String) -> Data? {
        var salt = Data(count: 16)
        guard salt.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }) == errSecSuccess else { return nil }
        return salt + digest(pin, salt: salt)
    }

    private static func matchesPIN(_ pin: String, stored value: Data) -> Bool {
        guard value.count > 16 else { return false }
        let salt = Data(value.prefix(16))
        return digest(pin, salt: salt) == value.dropFirst(16)
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
            evaluateBiometrics: { reason in
                let context = LAContext()
                // No "Enter Passcode" button: the iPhone's passcode does not open history.
                context.localizedFallbackTitle = ""
                return (try? await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)) ?? false
            },
            readKeychain: { account in
                let query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
                ]
                var item: CFTypeRef?
                switch SecItemCopyMatching(query as CFDictionary, &item) {
                case errSecSuccess: return (item as? Data).map { .present($0) } ?? .absent
                case errSecInteractionNotAllowed: return .inaccessibleWhileDeviceLocked
                default: return .absent
                }
            },
            writeKeychain: { account, value, accessible in
                let match: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
                SecItemDelete(match as CFDictionary)
                var add = match
                add[kSecValueData as String] = value
                add[kSecAttrAccessible as String] = accessible
                return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
            },
            deleteKeychain: { account in
                let match: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
                SecItemDelete(match as CFDictionary)
            },
            defaults: .standard,
            historyHoldsAnything: { HistoryStore.shared.holdsAnything() },
            now: { Date() }
        )
    }
}

/// Shows its content only while iPhone History is unlocked.
struct HistoryGate<Content: View>: View {
    @ObservedObject var lock = HistoryLock.shared
    @ObservedObject var capture = HistoryCapture.shared
    /// Open without an unlock while Screen History is off: for the page that turns it on.
    var whenOff = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        if lock.unlocked || (whenOff && !capture.enabled) { content() } else { HistoryLockedPage() }
    }
}

/// The lock on a page of its own.
private struct HistoryLockedPage: View {
    var body: some View {
        BacktapeLockScreen()
            .navigationTitle(AppLocalization.text("Screen History"))
            .navigationBarTitleDisplayMode(.inline)
    }
}

/// What Backtape shows before it is unlocked (the owner, 2026-11-15: a screen that says an unlock is
/// needed to view, with the Face ID prompt or a password pad). Face ID or Touch ID is asked for as the
/// page opens and again from its button; with a PIN, the pad is on the page. Nothing of the tape is
/// drawn behind it. An iPhone with neither yet gets the list that makes a PIN.
struct BacktapeLockScreen: View {
    @ObservedObject private var lock = HistoryLock.shared
    @State private var pin = ""
    @State private var wrong = 0
    @State private var now = Date()

    private var waiting: Bool { lock.blockedUntil.map { $0 > now } ?? false }

    var body: some View {
        if lock.needsSetup {
            List { HistoryUnlockSections() }.settingsPage()
        } else {
            ScrollView {
                VStack(spacing: 18) {
                    Image(systemName: lock.usesBiometrics ? (lock.biometricsName == "Touch ID" ? "touchid" : "faceid") : "lock.fill")
                        .font(.system(size: 44, weight: .regular))
                        .foregroundStyle(Tint.blue)
                        .padding(.top, 36)
                        .accessibilityHidden(true)
                    VStack(spacing: 6) {
                        Text("Screen History Is Locked").font(.title2.weight(.semibold))
                        Text("Unlock to view what Screen History kept on this iPhone.")
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 32)
                    if lock.usesBiometrics {
                        Button { Task { await lock.unlockWithBiometrics() } } label: {
                            Text(verbatim: String(format: AppLocalization.text("Unlock with %@"), lock.biometricsLabel))
                                .padding(.horizontal, 6)
                        }
                        .glassButton(prominent: true)
                        .controlSize(.large)
                    } else if lock.biometricsUnavailable, let url = URL(string: UIApplication.openSettingsURLString) {
                        Button { UIApplication.shared.open(url) } label: {
                            Text("Open Settings").padding(.horizontal, 6)
                        }
                        .glassButton(prominent: true)
                        .controlSize(.large)
                    }
                    if lock.hasPIN { pad }
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 24)
            }
            .scrollBounceBehavior(.basedOnSize)
            .background(Color(.systemGroupedBackground))
            .task { await lock.unlockWithBiometrics() }
            .task(id: lock.blockedUntil) {
                // The wait's end shows by itself.
                while let until = lock.blockedUntil, until > Date() {
                    try? await Task.sleep(for: .seconds(1))
                    now = Date()
                }
                now = Date()
            }
            .sensoryFeedback(.error, trigger: wrong)
        }
    }

    /// Poki's own PIN, 4 to 8 digits: the dots, then the keys.
    private var pad: some View {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                ForEach(0..<max(4, pin.count), id: \.self) { index in
                    Circle().fill(index < pin.count ? Color(.label) : Color(.tertiaryLabel).opacity(0.5)).frame(width: 11, height: 11)
                }
            }
            .frame(height: 20)
            .accessibilityLabel(Text("PIN"))
            .accessibilityValue(Text(verbatim: "\(pin.count)"))
            Group {
                if waiting, let until = lock.blockedUntil {
                    Text(verbatim: String(format: AppLocalization.text("Too many wrong tries. Try again at %@."), until.formatted(Date.FormatStyle(date: .omitted, time: .standard).locale(AppLocalization.locale))))
                } else if wrong > 0, pin.isEmpty {
                    Text("That PIN is not right.")
                } else {
                    Text(verbatim: " ")
                }
            }
            .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 32)
            Grid(horizontalSpacing: 22, verticalSpacing: 14) {
                ForEach(0..<3, id: \.self) { row in
                    GridRow {
                        ForEach(1..<4, id: \.self) { column in key("\(row * 3 + column)") }
                    }
                }
                GridRow {
                    symbolKey("delete.left", label: "Delete") { if !pin.isEmpty { pin.removeLast() } }
                    key("0")
                    symbolKey("arrow.right", label: "Unlock") { enter() }
                        .disabled(!HistoryLock.valid(pin))
                }
            }
            .disabled(waiting)
            .glassGroup(spacing: 8)
        }
        .padding(.top, 6)
    }

    private func key(_ digit: String) -> some View {
        Button {
            guard pin.count < 8 else { return }
            pin += digit
        } label: {
            Text(verbatim: digit).font(.title.weight(.regular)).frame(width: 72, height: 72).contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassSurface(in: Circle(), interactive: true)
        .sensoryFeedback(.selection, trigger: pin)
    }

    private func symbolKey(_ symbol: String, label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.title2).frame(width: 72, height: 72).contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
    }

    private func enter() {
        if !lock.unlock(pin: pin) { wrong += 1 }
        pin = ""
        now = Date()
    }
}

/// The way in, as sections of a list: Face ID or Touch ID, the PIN, or making a PIN when the iPhone
/// has neither set up.
struct HistoryUnlockSections: View {
    @ObservedObject private var lock = HistoryLock.shared
    @State private var pin = ""
    @State private var again = ""
    @State private var wrong = false
    @State private var now = Date()

    private var waiting: Bool { lock.blockedUntil.map { $0 > now } ?? false }

    var body: some View {
        Group {
            if lock.needsSetup {
                Section {
                    SecureField("New PIN", text: $pin).keyboardType(.numberPad).textContentType(.oneTimeCode)
                    SecureField("Repeat PIN", text: $again).keyboardType(.numberPad).textContentType(.oneTimeCode)
                    Button("Set PIN") {
                        wrong = !(pin == again && lock.setPIN(pin))
                        if wrong { again = "" }
                    }
                    .disabled(!HistoryLock.valid(pin) || again.isEmpty)
                } header: {
                    Text("Make a PIN for Screen History")
                } footer: {
                    Text(LocalizedStringKey(wrong ? "The two PINs did not match. Try again." : "Screen History is locked with a PIN of 4 to 8 digits that belongs to Poki alone. The iPhone's passcode does not open it."))
                }
            } else {
                if lock.usesBiometrics {
                    Section {
                        Button { Task { await lock.unlockWithBiometrics() } } label: {
                            Text(verbatim: String(format: AppLocalization.text("Unlock with %@"), lock.biometricsLabel))
                        }
                    } header: {
                        Text("Screen History Is Locked")
                    }
                } else if lock.biometricsUnavailable, let url = URL(string: UIApplication.openSettingsURLString) {
                    Section {
                        Button("Open Settings") { UIApplication.shared.open(url) }
                    } header: {
                        Text("Screen History Is Locked")
                    }
                }
                if lock.hasPIN {
                    Section {
                        SecureField("PIN", text: $pin).keyboardType(.numberPad).textContentType(.oneTimeCode)
                        Button("Unlock") {
                            wrong = !lock.unlock(pin: pin)
                            pin = ""
                            now = Date()
                        }
                        .disabled(pin.isEmpty || waiting)
                    } footer: {
                        if waiting, let until = lock.blockedUntil {
                            Text(verbatim: String(format: AppLocalization.text("Too many wrong tries. Try again at %@."), until.formatted(Date.FormatStyle(date: .omitted, time: .standard).locale(AppLocalization.locale))))
                        } else if wrong {
                            Text("That PIN is not right.")
                        }
                    }
                }
            }
        }
        .task { await lock.unlockWithBiometrics() }
        .task(id: lock.blockedUntil) {
            while let until = lock.blockedUntil, until > Date() {
                try? await Task.sleep(for: .seconds(1))
                now = Date()
            }
            now = Date()
        }
    }
}

/// History's lock settings: Face ID or Touch ID, and Poki's own PIN. One of the two always stays on.
struct HistoryLockSettings: View {
    @ObservedObject private var lock = HistoryLock.shared
    @State private var pin = ""
    @State private var again = ""
    @State private var mismatch = false

    var body: some View {
        List {
            if lock.biometricsReady {
                Section {
                    Toggle(isOn: Binding(get: { lock.biometricsOn }, set: { lock.setBiometrics($0) })) {
                        Text(verbatim: lock.biometricsLabel)
                    }
                    .disabled(lock.biometricsOn && !lock.hasPIN)
                } footer: {
                    Text("The iPhone's passcode never opens history. To turn this off, set a PIN first.")
                }
            }
            Section {
                SecureField(LocalizedStringKey(lock.hasPIN ? "New PIN" : "PIN"), text: $pin).keyboardType(.numberPad).textContentType(.oneTimeCode)
                SecureField("Repeat PIN", text: $again).keyboardType(.numberPad).textContentType(.oneTimeCode)
                Button(LocalizedStringKey(lock.hasPIN ? "Change PIN" : "Set PIN")) {
                    mismatch = !(pin == again && lock.setPIN(pin))
                    pin = ""
                    again = ""
                }
                .disabled(!HistoryLock.valid(pin) || again.isEmpty)
                if lock.hasPIN {
                    Button("Remove PIN", role: .destructive) { lock.removePIN() }.disabled(!lock.usesBiometrics)
                }
            } header: {
                Text("Poki PIN")
            } footer: {
                Text(LocalizedStringKey(mismatch ? "The two PINs did not match. Try again." : "A PIN of 4 to 8 digits that belongs to Poki alone. One of the two ways in always stays on."))
            }
        }
        .navigationTitle(AppLocalization.text("Screen History Lock"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
