import Foundation
import UIKit
import UserNotifications

/// Poki keeps its own signing, the way Poki Setup does on a computer (PokiLauncher's signer, which is
/// Poki Setup's Rust core): the Apple Account is signed in here, with anisette from a remote server,
/// the next build is signed ahead of time (the installed copy for a refresh, the chosen channel's
/// release for an update), and it is installed over the loopback only when the person taps Install
/// and no task is running, because iOS ends Poki when the new copy lands.
///
/// Secrets (the Apple session, the kept password, the team key, the anisette identity) live only in
/// the Keychain, after first unlock, on this device.
@MainActor
@Observable
final class SelfSigner {
    struct Channel: Decodable, Hashable, Identifiable {
        let id: String
        let title: String
    }

    struct Status: Decodable, Equatable {
        var signed_in: Bool
        var needs_reauth: Bool?
        var needs_code: Bool
        var rate_limited: Bool?
        var rate_limited_until: Int64?
        var resend_available_at: Int64?
        var apple_id: String?
        var name: String?
        var team_id: String?
        var keeps_password: Bool
        var anisette: String
        var channel: String
        var channels: [Channel]
    }

    struct Team: Decodable, Identifiable, Hashable {
        let team_id: String
        let name: String
        let kind: String
        let is_free: Bool
        var id: String { team_id }
    }

    struct Prepared: Decodable, Equatable {
        let kind: String
        let ipa: String
        let bundle_id: String
        let version: String
        let build: String
        let tag: String
        let team_name: String
        let team_is_free: Bool
        let profile_expires_at: Int64
        let prepared_at: Int64
        var expires: Date { Date(timeIntervalSince1970: TimeInterval(profile_expires_at)) }
        var title: String { kind == "update" ? "Poki \(version) (\(build))" : "Refreshed Poki \(version) (\(build))" }
    }

    struct Release: Decodable, Equatable {
        let tag: String
        let version: String
        let build: String
        let channel: String
        let source: String?
        let source_notice: String?
    }

    /// Prepare a fresh build when the installed profile has this many days left or fewer.
    static let refreshWithDaysLeft: Double = 3
    /// Home warns, and a notification reminds once a day, when the installed profile has this many days left.
    static let warnWithDaysLeft: Double = 2
    /// How often Poki looks after its signing by itself while it stays up. Without an Apple Account it
    /// only looks up the channel, and no more often than this: GitHub limits unsigned reads per hour.
    static let checkEvery: TimeInterval = 3 * 3600

    private(set) var status: Status?
    private(set) var teams: [Team] = []
    private(set) var ready: [String: Prepared] = [:]
    private(set) var latest: Release?
    private(set) var updateCheckError: String?
    /// What the signer is doing now, for the Setup page.
    private(set) var working: String?
    private(set) var fraction: Double?
    private(set) var lastError: String?
    private(set) var lastCheck: Date?
    /// When the installed Poki stops opening: its own profile's expiry. Nil when it has none (simulator).
    let expiry: Date? = SelfSigner.installedProfileExpiry() ?? SelfSigner.screenshotExpiry
    let installedVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    let installedBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""

    /// The phone's own services (10.7.0.1 and the pairing file), when the loopback answers.
    var phone: () -> [String: Any]? = { nil }
    /// Why `phone()` has nothing (ESP-448).
    var whyUnreachable: () -> Unreachable = { .loopback }
    enum Unreachable { case unpaired, loopback, cellular }
    /// No task is running, so Poki may be ended by an install.
    var isIdle: () -> Bool = { false }
    /// Why an install waits, for the message under the button.
    var busyReason: () -> String? = { nil }
    /// Stops runtime work before the confirmed update saves state and exits.
    var beforeExit: () async -> Void = {}

    enum InstallFinish: Equatable {
        case idle, installing, waitingForExit
        case needsReopen(installed: Bool)
    }
    private(set) var installFinish = InstallFinish.idle
    private var finishTimer: Timer?
    private var foregroundObserver: NSObjectProtocol?

    var installMessage: String? {
        guard installFinish != .idle else { return nil }
        if exitRequest == .unconfirmed && !needsReopen {
            return AppLocalization.text(LocalizedStringResource("Installing the update. Features are unavailable until you reopen Poki."))
        }
        return AppLocalization.text(LocalizedStringResource("If the update has not finished after a few seconds, swipe up on Poki in the app switcher to close it, then open Poki again. Features are unavailable until you reopen Poki."))
    }

    var needsReopen: Bool {
        if case .needsReopen = installFinish { return true }
        return false
    }

    isolated deinit {
        finishTimer?.invalidate()
        if let foregroundObserver { NotificationCenter.default.removeObserver(foregroundObserver) }
    }

    private var started = false
    private var timer: Timer?
    private let log = AppLog.shared

    var signedIn: Bool { status?.signed_in == true || Self.screenshotSignedIn }
    var needsCode: Bool { status?.needs_code == true }
    /// Apple took a code but never opened the session: nothing signs in until the person does.
    var needsReauth: Bool { status?.needs_reauth == true }
    static let reauthMessage = "Apple verified the code, but did not finish opening the session. Sign in again to start a fresh session."
    var rateLimited: Bool { rateLimitRemainingSeconds() > 0 }
    var needsCodeSheet = false
    static let resendCooldown: TimeInterval = 60
    private var localResendAvailableAt: Date?
    private static let prepareRetryBackoff: TimeInterval = 15 * 60
    private var lastPrepareFailure: Date?
    private var teamsTask: Task<Void, Never>?
    typealias Transport = ([String: Any], (@Sendable ([String: Any]) -> Void)?) async throws -> Data
    var transport: Transport

    init(transport: @escaping Transport = SignerBridge.call) {
        self.transport = transport
    }

    @discardableResult
    private func call(_ request: [String: Any], progress: (@Sendable ([String: Any]) -> Void)? = nil) async throws -> Data {
        try await transport(request, progress)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ request: [String: Any], progress: (@Sendable ([String: Any]) -> Void)? = nil) async throws -> T {
        try SignerBridge.unwrap(type, from: try await transport(request, progress))
    }
    var daysLeft: Double? { expiry.map { $0.timeIntervalSinceNow / 86_400 } }
    /// The build Install would put on: an update when one is ready, else a refresh.
    var next: Prepared? { ready["update"] ?? ready["refresh"] }
    /// The channel has a newer Poki than the installed one.
    var updateAvailable: Bool { latest.map(isNewer) ?? false }
    /// A newer Poki is on the channel, but no signed copy of it is ready to install yet. Compared by
    /// version and build, not tag: the rolling releases (app-prealpha-latest, ios-prealpha-latest)
    /// keep one tag for every build, so a copy prepared from an earlier build has the same tag.
    var updateNotReady: Bool {
        guard updateAvailable, let latest else { return false }
        guard let u = ready["update"] else { return true }
        return u.version != latest.version || u.build != latest.build
    }
    /// Why Poki cannot download the update by itself, when it cannot. Nil when it can.
    var updateBlocker: String? {
        guard updateNotReady else { return nil }
        if !signedIn { return AppLocalization.text(LocalizedStringResource("To download updates by itself, Poki needs your Apple Account: sign in under Signing Options. Or update Poki from Poki Setup on your Mac.")) }
        if phone() == nil { return unreachable }
        return nil
    }
    /// How to get the channel's newer Poki from here, or nil when there is none.
    var updateStep: UpdateStep? { UpdateStep(updateAvailable: updateAvailable, copyReady: !updateNotReady, signedIn: signedIn) }
    var channelTitle: String { status?.channels.first { $0.id == status?.channel }?.title ?? status?.channel ?? "" }

    static var home: URL {
        let url = AppFiles.support.appendingPathComponent("signer", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Where Poki Setup leaves its team key for Poki (see the desktop core's signing-identity.json).
    static var handedIdentity: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("PokiSetup/signing-identity.json")
    }

    func start() {
        guard !started else { return }
        started = true
        SignerBridge.installVault()
        Task {
            do {
                _ = try await call(["op": "configure", "home": Self.home.path, "device_name": UIDevice.current.name])
                if let imported = try? await decode([String: AnyDecodable].self, ["op": "import_identity", "path": Self.handedIdentity.path]),
                   imported["imported"]?.value as? Bool == true {
                    log.add("signing", "took Poki Setup's signing key into the Keychain")
                }
                await reload()
                loadReady()
                maintain()
            } catch {
                lastError = error.localizedDescription
                log.add("signing", "signer did not start: \(error.localizedDescription)")
            }
        }
        // Poki stays up in the background while it is on; a check every three hours is plenty for
        // a 7-day profile.
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkEvery, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.maintain() }
        }
    }

    func reload() async {
        do { status = try await decode(Status.self, ["op": "status"]) } catch { lastError = error.localizedDescription }
    }

    // MARK: Account

    func signIn(appleID: String, password: String, keepPassword: Bool) async {
        lastPrepareFailure = nil
        await run("Signing in") {
            _ = try await self.call(["op": "sign_in", "apple_id": appleID, "password": password, "keep_password": keepPassword])
        }
        await reload()
        if signedIn, !needsCode, !rateLimited { await loadTeams() }
    }

    func finishSignIn(code: String) async {
        lastPrepareFailure = nil
        await run("Checking the code") { _ = try await self.call(["op": "finish_sign_in", "code": code]) }
        await reload()
        if !needsCode { needsCodeSheet = false }
        if signedIn, !needsCode, !rateLimited { await loadTeams() }
    }

    func presentCodeSheet() {
        if needsCode { needsCodeSheet = true }
    }

    func dismissCodeSheet() {
        needsCodeSheet = false
    }

    func resendCooldownSeconds(at now: Date = .now) -> Int {
        var until = status?.resend_available_at.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        if let localResendAvailableAt, until == nil || localResendAvailableAt > until! {
            until = localResendAvailableAt
        }
        guard let until else { return 0 }
        return max(0, Int(ceil(until.timeIntervalSince(now))))
    }

    func rateLimitRemainingSeconds(at now: Date = .now) -> Int {
        if let until = status?.rate_limited_until {
            return max(0, Int(ceil(TimeInterval(until) - now.timeIntervalSince1970)))
        }
        return status?.rate_limited == true ? 3600 : 0
    }

    func canResendCode(at now: Date = .now) -> Bool {
        needsCode && working == nil && rateLimitRemainingSeconds(at: now) == 0 && resendCooldownSeconds(at: now) == 0
    }

    func resendButtonTitle(at now: Date = .now) -> String {
        let rateWait = rateLimitRemainingSeconds(at: now)
        if rateWait >= 60 {
            let minutes = (rateWait + 59) / 60
            return AppLocalization.text(LocalizedStringResource("Resend Verification Code (wait \(minutes) min)"))
        }
        if rateWait > 0 {
            return AppLocalization.text(LocalizedStringResource("Resend Verification Code (wait \(rateWait) s)"))
        }
        let cooldown = resendCooldownSeconds(at: now)
        if cooldown > 0 {
            return AppLocalization.text(LocalizedStringResource("Resend Verification Code (\(cooldown) s)"))
        }
        return AppLocalization.text(LocalizedStringResource("Resend Verification Code"))
    }

    static func localizedErrorText(_ error: String) -> String {
        AppLocalization.bundle.localizedString(forKey: error, value: error, table: nil)
    }

    func resendCode(now: Date = .now) async {
        guard needsCode, working == nil, rateLimitRemainingSeconds(at: now) == 0, resendCooldownSeconds(at: now) == 0 else { return }
        localResendAvailableAt = now.addingTimeInterval(Self.resendCooldown)
        await run("Sending a new code") { _ = try await self.call(["op": "resend_code"]) }
        await reload()
    }

    func cancelSignIn() async {
        needsCodeSheet = false
        localResendAvailableAt = nil
        await run("Cancelling sign-in") { _ = try await self.call(["op": "cancel_sign_in"]) }
        lastError = nil
        await reload()
    }

    func signOut() async {
        needsCodeSheet = false
        localResendAvailableAt = nil
        await run("Signing out") { _ = try await self.call(["op": "sign_out"]) }
        teams = []
        await reload()
    }

    func loadTeams() async {
        if let teamsTask {
            await teamsTask.value
            return
        }
        guard !needsCode, !rateLimited, !needsReauth else { return }
        let task = Task { @MainActor in
            do {
                teams = try await decode([Team].self, ["op": "teams"])
            } catch {
                lastError = error.localizedDescription
                if (error as? SignerError)?.code == "needs_code" {
                    await reload()
                    if needsCode { needsCodeSheet = true }
                    return
                }
            }
            await reload()
        }
        teamsTask = task
        defer { teamsTask = nil }
        await task.value
    }

    func choose(team: Team) async {
        await run("Choosing the team") { _ = try await self.call(["op": "choose_team", "team_id": team.team_id]) }
        await reload()
    }

    func setChannel(_ id: String) async {
        await run(nil) { _ = try await self.call(["op": "set_channel", "channel": id]) }
        await reload()
        latest = nil
        await checkLatest()
    }

    func setAnisette(_ url: String) async {
        await run(nil) { _ = try await self.call(["op": "set_anisette", "url": url]) }
        await reload()
    }

    // MARK: Builds

    private func loadReady() {
        var found: [String: Prepared] = [:]
        for kind in ["refresh", "update"] {
            let url = Self.home.appendingPathComponent("ready/\(kind)/manifest.json")
            if let data = try? Data(contentsOf: url), let p = try? JSONDecoder().decode(Prepared.self, from: data), FileManager.default.fileExists(atPath: p.ipa) {
                found[kind] = p
            }
        }
        // A build that is already on, or older than what is on (Poki Setup installed a newer one
        // meanwhile), has nothing left to give.
        if let u = found["update"], !isNewer(version: u.version, build: u.build) { found["update"] = nil }
        if let r = found["refresh"], let expiry, r.expires <= expiry.addingTimeInterval(3600) { found["refresh"] = nil }
        ready = found
    }

    static func shouldAllowAutoPrepare(canPrepare: Bool, needsCode: Bool, rateLimited: Bool, working: String?, lastFailure: Date?, now: Date = .now) -> Bool {
        guard canPrepare, !needsCode, !rateLimited, working == nil else { return false }
        if let lastFailure, now.timeIntervalSince(lastFailure) < prepareRetryBackoff { return false }
        return true
    }

    static func isMaintainThrottled(lastCheck: Date?, now: Date = .now) -> Bool {
        guard let lastCheck else { return false }
        return now.timeIntervalSince(lastCheck) < checkEvery - 60
    }

    /// At launch, back in front and every few hours: looks up the channel's newest build, so Home and
    /// Signing can say an update is out, and prepares what is due. Throttled across foreground and
    /// loopback transitions, and paused while a 2FA code or rate-limit cooldown is active.
    func maintain() {
        guard installFinish == .idle else { return }
        // Not before start() has the signer configured (it calls this itself once it has).
        guard status != nil, !needsCode, !rateLimited else { return }
        if Self.isMaintainThrottled(lastCheck: lastCheck) {
            if canPrepare { Task { await prepareDue() } }
            return
        }
        Task { await checkLatest() }
    }

    /// Looks up the newest build on the Beta channel, then prepares what is due. Works without an
    /// Apple Account, and the Signing page calls it when it opens. False when the lookup failed.
    @discardableResult
    func checkLatest() async -> Bool {
        let found = await lookUp()
        await prepareDue()
        return found
    }

    /// One lookup at a time: a caller that comes while one runs gets its answer.
    private var lookup: Task<Bool, Never>?

    private func lookUp() async -> Bool {
        if let lookup { return await lookup.value }
        let task = Task { () -> Bool in
            do {
                var found = Self.screenshotRelease(installedVersion: installedVersion, installedBuild: installedBuild)
                if found == nil { found = try await self.decode(Release.self, ["op": "check_update"]) }
                guard let rel = found else { return false }
                if rel != latest { log.add("signing", "newest on the channel: \(rel.version) (\(rel.build)), \(rel.channel)") }
                latest = rel
                lastCheck = Date()
                updateCheckError = nil
                return true
            } catch {
                latest = nil
                updateCheckError = error.localizedDescription
                return false
            }
        }
        lookup = task
        defer { lookup = nil }
        return await task.value
    }

    private var canPrepare: Bool { installFinish == .idle && signedIn && phone() != nil }

    /// Prepares what is due, by itself: an update when the channel has a newer Poki, a refresh when
    /// the installed profile is close to expiring. Never installs.
    private func prepareDue() async {
        guard Self.shouldAllowAutoPrepare(canPrepare: canPrepare, needsCode: needsCode, rateLimited: rateLimited, working: working, lastFailure: lastPrepareFailure) else { return }
        if updateNotReady {
            await prepare(kind: "update", automatic: true)
            return
        }
        if let days = daysLeft, days <= Self.refreshWithDaysLeft, ready["refresh"] == nil, ready["update"] == nil {
            await prepare(kind: "refresh", automatic: true)
        }
        remindIfExpiring()
    }

    /// Download and Install Update, in one tap: gets the newest build and signs it, then installs it.
    /// install() still checks that Poki is idle: with a task running it waits and says why, and the
    /// downloaded build stays ready for Install Update.
    func downloadAndInstallUpdate() async {
        if updateNotReady { await prepare(kind: "update") }
        guard !updateNotReady, ready["update"] != nil, lastError == nil else { return }
        await install()
    }

    func isNewer(_ rel: Release) -> Bool { isNewer(version: rel.version, build: rel.build) }

    func isNewer(version: String, build: String) -> Bool {
        let installed = (installedVersion, Int(installedBuild) ?? 0)
        switch version.compare(installed.0, options: .numeric) {
        case .orderedDescending: return true
        case .orderedAscending: return false
        case .orderedSame: return (Int(build) ?? 0) > installed.1
        }
    }

    func prepare(kind: String, automatic: Bool = false) async {
        guard var request = phone() else {
            lastError = unreachable
            return
        }
        request["op"] = "prepare"
        request["kind"] = kind
        request["automatic"] = automatic
        request["app_path"] = Bundle.main.bundlePath
        request["device_name"] = UIDevice.current.name
        await run(kind == "update" ? "Preparing the update" : "Preparing a refresh") {
            let p = try await self.decode(Prepared.self, request) { [weak self] progress in
                Task { @MainActor in self?.show(progress) }
            }
            self.lastPrepareFailure = nil
            self.ready[kind] = p
            self.log.add("signing", "prepared \(kind): \(p.version) (\(p.build)), profile until \(p.expires)")
            self.notify(title: kind == "update" ? AppLocalization.text(LocalizedStringResource("Poki Update Ready")) : AppLocalization.text(LocalizedStringResource("Poki Refresh Ready")),
                        body: AppLocalization.text(LocalizedStringResource("Open Settings > Connection > Signing & Updates and install the prepared build when Poki isn't running a task.")))
        }
        if lastError != nil, automatic || needsCode || rateLimited {
            lastPrepareFailure = Date()
        }
    }

    /// Installs the prepared build. iOS ends Poki when it lands; a notification brings it back.
    func install() async {
        guard installFinish == .idle else { return }
        guard let p = next else { log.add("signing", "install tapped, but no build is ready"); return }
        log.add("signing", "install tapped: \(p.kind) \(p.version) (\(p.build))")
        guard isIdle() else {
            let why = busyReason() ?? ""
            lastError = AppLocalization.text(LocalizedStringResource("Poki is running a task. Install when it has finished.")) + (why.isEmpty ? "" : " " + why)
            log.add("signing", "install waits: \(why)")
            return
        }
        guard var request = phone() else {
            lastError = unreachable
            log.add("signing", "install: no loopback or pairing file")
            return
        }
        request["op"] = "install"
        request["manifest"] = Self.home.appendingPathComponent("ready/\(p.kind)/manifest.json").path
        let reopen = "nz.zheha.poki.signing.reopen"
        scheduleReopenNotice(id: reopen)
        installFinish = .installing
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.exitWaitEnded() }
        }
        steppedAside = false
        installFraction = nil
        // Keep the upload alive until installation_proxy has accepted the package.
        installBackground = UIApplication.shared.beginBackgroundTask(withName: "Poki update")
        let watch = Task { @MainActor [weak self] in
            var last: (fraction: Double, since: Date)?
            while !Task.isCancelled, let self, self.working != nil {
                try? await Task.sleep(for: .seconds(1))
                guard let f = self.installFraction else { continue }
                if last?.fraction != f { last = (f, Date()) }
                if f >= 0.9 || (f >= 0.4 && Date().timeIntervalSince(last!.since) > 5) { self.stepAside(); break }
            }
        }
        await run("Installing") {
            _ = try await self.call(request) { [weak self] progress in
                Task { @MainActor in self?.show(progress) }
            }
        }
        watch.cancel()
        endInstallBackground()
        if lastError != nil {
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [reopen])
            requireReopen()
        } else if needsReopen {
            installFinish = .needsReopen(installed: true)
            working = installMessage
        } else {
            installFinish = .waitingForExit
            if exitRequest != .closing {
                finishTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
                    Task { @MainActor in self?.exitWaitEnded() }
                }
            }
            if !steppedAside { stepAside() }
            working = installMessage
            exitIfReady()
        }
    }

    // MARK: Helpers

    private var unreachable: String {
        switch whyUnreachable() {
        case .unpaired: AppLocalization.text(LocalizedStringResource("Pair this iPhone first (Setup)."))
        case .cellular: LoopbackMonitor.needsWiFi
        case .loopback: AppLocalization.text(LocalizedStringResource("Poki can't reach this iPhone. Turn on the loopback, then try again."))
        }
    }

    private func run(_ title: String?, _ work: () async throws -> Void) async {
        working = title
        fraction = nil
        lastError = nil
        defer { working = installMessage; fraction = nil }
        do { try await work() } catch {
            let code = (error as? SignerError)?.code ?? ""
            lastError = whyUnreachable() == .cellular && ["loopback", "handshake", "unreachable"].contains(code) ? LoopbackMonitor.needsWiFi : error.localizedDescription
            log.add("signing", "\(title ?? "signer"): \(error.localizedDescription)")
            if code == "needs_code" {
                await reload()
                if needsCode { needsCodeSheet = true }
            }
        }
    }

    /// The upgrade's progress while it installs, for `install`'s watch.
    private var installFraction: Double?
    private var steppedAside = false
    private enum ExitRequest { case unconfirmed, stopping, stopped, closing }
    private var exitRequest = ExitRequest.unconfirmed
    private var installBackground: UIBackgroundTaskIdentifier = .invalid

    private func endInstallBackground() {
        guard installBackground != .invalid else { return }
        UIApplication.shared.endBackgroundTask(installBackground)
        installBackground = .invalid
    }

    /// Ask before ending the process. The install step can announce itself before upload finishes.
    private func stepAside() {
        guard !steppedAside else { return }
        log.add("signing", "the install's last step: telling the owner Poki will close to finish")
        steppedAside = true
        working = AppLocalization.text(LocalizedStringResource("Finishing the update: Poki will close to finish it"))
        finishNotice = true
        notify(title: AppLocalization.text(LocalizedStringResource("Poki Will Close to Finish the Update")),
               body: AppLocalization.text(LocalizedStringResource("Poki will close by itself. Open it again once the update is in.")))
    }
    /// The last install step's alert: Poki has to exit for the update to finish.
    var finishNotice = false
    func finishNoticeAnswered() {
        guard finishNotice else { return }
        finishNotice = false
        exitRequest = .stopping
        log.add("signing", "update confirmed: stopping runtime before installation progress")
        Task { @MainActor in
            await beforeExit()
            SessionStore.shared.flush()
            UserDefaults.standard.synchronize()
            exitRequest = .stopped
            guard !needsReopen else { return }
            log.add("signing", "update runtime stopped and state saved; moving to background")
            UIApplication.shared.perform(NSSelectorFromString("suspend"))
            exitIfReady()
        }
    }

    private func exitIfReady() {
        guard exitRequest == .stopped, !needsReopen,
              installFraction != nil || installFinish == .waitingForExit else { return }
        exitRequest = .closing
        finishTimer?.invalidate()
        finishTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.requireReopen() }
        }
        endInstallBackground()
        log.add("signing", "update accepted: runtime stopped and state saved; exiting normally")
        exit(0)
    }

    /// An install result is required before foreground return or the timer can claim success.
    private func exitWaitEnded() {
        guard installFinish == .waitingForExit || exitRequest == .closing else { return }
        requireReopen()
    }

    private func requireReopen() {
        guard installFinish != .idle, !needsReopen else { return }
        installFinish = .needsReopen(installed: installFinish == .waitingForExit)
        finishTimer?.invalidate()
        finishNotice = false
        fraction = nil
        working = installMessage
        log.add("signing", "old process still running: showing instructions to reopen Poki")
    }

    private func show(_ progress: [String: Any]) {
        guard !needsReopen else { return }
        switch progress["kind"] as? String {
        case "step":
            working = progress["title"] as? String ?? working; fraction = nil
            // This step precedes upload. Only part/install comes from the system upgrade callback.
            if progress["id"] as? String == "install" { stepAside() }
        case "part":
            fraction = progress["fraction"] as? Double
            if progress["id"] as? String == "install" {
                installFraction = fraction
                exitIfReady()
            }
            if let d = progress["detail"] as? String { working = d }
        case "note", "waiting": if let t = progress["text"] as? String { working = t }
        default: break
        }
    }

    private func notify(title: String, body: String, id: String = UUID().uuidString, after seconds: TimeInterval? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = ["poki_link": "poki://setup"]
        let trigger = seconds.map { UNTimeIntervalNotificationTrigger(timeInterval: $0, repeats: false) }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    private func scheduleReopenNotice(id: String) {
        notify(title: AppLocalization.text(LocalizedStringResource("Poki Was Updated")), body: AppLocalization.text(LocalizedStringResource("Tap to open Poki again.")), id: id, after: 20)
    }

    /// Once a day in the last two days: the build is ready (or can't be made) and nothing installed it.
    private func remindIfExpiring() {
        guard let days = daysLeft, days <= Self.warnWithDaysLeft else { return }
        let key = "signing.reminded"
        if let last = UserDefaults.standard.object(forKey: key) as? Date, Date().timeIntervalSince(last) < 20 * 3600 { return }
        UserDefaults.standard.set(Date(), forKey: key)
        let when = expiry.map { $0.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(AppLocalization.locale)) } ?? ""
        notify(title: AppLocalization.text(LocalizedStringResource("Poki Expires Soon")),
               body: next != nil ? AppLocalization.text(LocalizedStringResource("A refreshed Poki is ready. Open Setup and tap Install before \(when).")) : AppLocalization.text(LocalizedStringResource("Open Setup to refresh Poki before \(when).")))
    }

    /// `-pokiSigningDays 1`: a simulator has no profile, so a screenshot gives Poki one that ends then.
    nonisolated private static var screenshotExpiry: Date? {
        #if targetEnvironment(simulator)
        guard UserDefaults.standard.object(forKey: "pokiSigningDays") != nil else { return nil }
        return Date().addingTimeInterval(UserDefaults.standard.double(forKey: "pokiSigningDays") * 86_400)
        #else
        nil
        #endif
    }

    /// `-pokiLatest newer|same`: a simulator's screenshots and tests get a channel build one past the
    /// installed one, or the installed one, as the Beta channel's newest build instead of the network's.
    nonisolated private static func screenshotRelease(installedVersion: String, installedBuild: String) -> Release? {
        #if targetEnvironment(simulator)
        let build = Int(installedBuild) ?? 0
        switch UserDefaults.standard.string(forKey: "pokiLatest") {
        case "newer": return Release(tag: "app-\(installedVersion)-beta.\(build + 1)", version: installedVersion, build: String(build + 1), channel: "beta", source: nil, source_notice: nil)
        case "same": return Release(tag: "app-\(installedVersion)-beta.\(build)", version: installedVersion, build: installedBuild, channel: "beta", source: nil, source_notice: nil)
        default: return nil
        }
        #else
        nil
        #endif
    }

    /// `-pokiSignedIn YES`: a simulator's screenshots show the Signing page as it is with an Apple Account.
    nonisolated private static var screenshotSignedIn: Bool {
        #if targetEnvironment(simulator)
        UserDefaults.standard.bool(forKey: "pokiSignedIn")
        #else
        false
        #endif
    }

    /// The ExpirationDate of Poki's own embedded.mobileprovision (a CMS envelope around a plist).
    nonisolated static func installedProfileExpiry() -> Date? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex) else { return nil }
        let plist = data.subdata(in: start.lowerBound..<end.upperBound)
        let dict = (try? PropertyListSerialization.propertyList(from: plist, format: nil)) as? [String: Any]
        return dict?["ExpirationDate"] as? Date
    }
}

struct SignerError: LocalizedError {
    let message: String
    let code: String
    var errorDescription: String? { message }
}

/// A JSON value of any shape, for answers that need no struct.
struct AnyDecodable: Decodable {
    let value: Any
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { value = b }
        else if let n = try? c.decode(Double.self) { value = n }
        else if let s = try? c.decode(String.self) { value = s }
        else if let a = try? c.decode([AnyDecodable].self) { value = a.map(\.value) }
        else if let d = try? c.decode([String: AnyDecodable].self) { value = d.mapValues(\.value) }
        else { value = NSNull() }
    }
}

/// poki_signer_* through the C ABI.
enum SignerBridge {
    fileprivate static let prefix = "signer."

    /// The Keychain as the signer's vault (Keychain items are after-first-unlock, this device only).
    static func installVault() {
        _ = poki_signer_set_vault({ _, name in
            guard let name, let data = try? Keychain.read(SignerBridge.prefix + String(cString: name)) else { return nil }
            return strdup(data.base64EncodedString())
        }, { _, name, value in
            guard let name, let value, let data = Data(base64Encoded: String(cString: value)) else { return -1 }
            do { try Keychain.write(data, account: SignerBridge.prefix + String(cString: name)); return 0 } catch { return -2 }
        }, { _, name in
            guard let name else { return -1 }
            Keychain.delete(SignerBridge.prefix + String(cString: name))
            return 0
        }, nil)
    }

    final class Box: @unchecked Sendable {
        let progress: (@Sendable ([String: Any]) -> Void)?
        var continuation: CheckedContinuation<Data, Error>?
        init(progress: (@Sendable ([String: Any]) -> Void)?, continuation: CheckedContinuation<Data, Error>) {
            self.progress = progress
            self.continuation = continuation
        }
    }

    /// Runs one request; the answer's `value` as JSON (wrapped as {"v": value}).
    @discardableResult
    static func call(_ request: [String: Any], progress: (@Sendable ([String: Any]) -> Void)? = nil) async throws -> Data {
        let json = try JSONSerialization.data(withJSONObject: request)
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data, Error>) in
            let box = Unmanaged.passRetained(Box(progress: progress, continuation: c))
            let rc = String(decoding: json, as: UTF8.self).withCString { text in
                poki_signer_call(text, { context, event in
                    guard let context, let event else { return }
                    let unmanaged = Unmanaged<Box>.fromOpaque(context)
                    let box = unmanaged.takeUnretainedValue()
                    guard let object = (try? JSONSerialization.jsonObject(with: Data(String(cString: event).utf8))) as? [String: Any] else { return }
                    if object["event"] as? String == "result" {
                        if object["ok"] as? Bool == true {
                            let wrapped = (try? JSONSerialization.data(withJSONObject: ["v": object["value"] ?? NSNull()])) ?? Data("{\"v\":null}".utf8)
                            box.continuation?.resume(returning: wrapped)
                        } else {
                            box.continuation?.resume(throwing: SignerError(message: object["error"] as? String ?? "The signer failed.", code: object["code"] as? String ?? ""))
                        }
                        box.continuation = nil
                        unmanaged.release()
                    } else if object["event"] as? String == "log", let line = object["line"] as? String {
                        Task { @MainActor in AppLog.shared.add("signing", line) }
                    } else if let p = object["progress"] as? [String: Any] {
                        box.progress?(p)
                    }
                }, box.toOpaque())
            }
            if rc != 0 {
                box.takeUnretainedValue().continuation = nil
                box.release()
                c.resume(throwing: SignerError(message: "The signer did not take the request.", code: "config"))
            }
        }
    }

    private struct Wrapped<T: Decodable>: Decodable { let v: T }

    static func unwrap<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(Wrapped<T>.self, from: data).v
    }

    static func decode<T: Decodable>(_ type: T.Type, _ request: [String: Any], progress: (@Sendable ([String: Any]) -> Void)? = nil) async throws -> T {
        try unwrap(type, from: try await call(request, progress: progress))
    }
}
