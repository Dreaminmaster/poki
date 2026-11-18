import AppKit
import Foundation
import SwiftUI

enum Page: String, CaseIterable, Identifiable {
    case setup, phones, account, relay, debug, testBuilds, github
    var id: String { rawValue }
    var title: String {
        switch self {
        case .setup: "Set Up"
        case .phones: "Devices"
        case .account: "Apple Account"
        case .relay: "Relay"
        case .debug: "Diagnostics"
        case .testBuilds: "Test Builds"
        case .github: "GitHub Account"
        }
    }
    var symbol: String {
        switch self {
        case .setup: "sparkles"
        case .phones: "ipad.and.iphone"
        case .account: "person.crop.circle"
        case .relay: "point.3.connected.trianglepath.dotted"
        case .debug: "stethoscope"
        case .testBuilds: "hammer"
        case .github: "person.badge.key"
        }
    }
}

/// Everything the windows show. All calls go through the bridge; nothing here talks to Apple.
@MainActor
final class AppModel: ObservableObject {
    @Published var page: Page = .setup
    @Published var info: AppInfo?
    @Published var account: AccountState?
    @Published var accountError: CoreError?
    @Published var teams: [Team] = []
    @Published var phones: [PhoneRow] = []
    @Published var phonesError: CoreError?
    @Published var selectedUDID: String?
    @Published var records: [Record] = []
    @Published var relay: Deployed?
    @Published var latest: Release?
    /// What the channel offers for Poki Setup itself; checked at launch and every six hours.
    @Published var update: UpdateInfo?
    @Published var installingUpdate = false
    /// The newer version the person was asked about (asked once per version).
    @Published var updatePrompt: String?
    private var updateTask: Task<Void, Never>?
    private var askedAbout: String?
    @Published var latestError: String?
    @Published var channels: [ChannelInfo] = []

    // Developer: the GitHub sign-in and test builds from GitHub Actions.
    @Published var dev = DevState()
    /// The code GitHub is waiting for, while a GitHub sign-in is under way.
    @Published var githubCode: GithubSignIn?
    @Published var githubError: String?
    @Published var testBuilds: TestBuildListing?
    @Published var testBuildsError: String?
    @Published var loadingTestBuilds = false
    private var syncTask: Task<Void, Never>?

    // Sign-in
    @Published var needsCode = false
    @Published var codeVia: String?

    // Jobs
    @Published var steps: [String: [StepItem]] = [:]
    @Published var busyJobs: Set<String> = []
    @Published var logLines: [String] = []

    /// A short message at the bottom of the window.
    @Published var banner: String?

    let bridge = Bridge.shared
    private var started = false
    private var pollTask: Task<Void, Never>?
    private var keeperTask: Task<Void, Never>?
    let demo = ProcessInfo.processInfo.environment["POKI_SETUP_DEMO"] == "1"

    /// The one model, for the CI snapshot walk.
    static weak var current: AppModel?

    init() {
        AppModel.current = self
        bridge.onProgress = { [weak self] e in self?.apply(e) }
        bridge.onLogLines = { [weak self] lines in
            guard let self else { return }
            self.logLines.append(contentsOf: lines)
            if self.logLines.count > 5000 { self.logLines.removeFirst(self.logLines.count - 5000) }
        }
        bridge.onNeedsCode = { [weak self] in
            Task { @MainActor in await self?.promptForCode() }
        }
        bridge.onAccountChanged = { [weak self] in
            Task { @MainActor in await self?.accountChanged() }
        }
    }

    var selectedPhone: PhoneRow? {
        if let id = selectedUDID, let row = phones.first(where: { $0.id == id }) { return row }
        return phones.first
    }

    var isRateLimited: Bool { account?.isRateLimited() == true }

    func start() {
        guard !started else { return }
        started = true
        if demo {
            loadDemo()
            return
        }
        Task {
            info = try? await bridge.call("app_info")
            await refreshAccount()
            await refreshRecords()
            await refreshLatest()
            await refreshChannels()
            relay = try? await bridge.call("relay_state", as: Deployed?.self) ?? nil
            await refreshDev()
        }
        // Test builds: with the automatic sync on, look for a new one every two minutes.
        syncTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            while !Task.isCancelled {
                await self?.syncTestBuilds()
                try? await Task.sleep(for: .seconds(120))
            }
        }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshPhones()
                try? await Task.sleep(for: .seconds(3))
            }
        }
        // Poki Setup's own updates: at launch and every six hours.
        updateTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            while !Task.isCancelled {
                await self?.checkForUpdate(prompt: true)
                try? await Task.sleep(for: .seconds(6 * 3600))
            }
        }
        // Keep Poki signed: every six hours, renew what is due (needs the kept password).
        keeperTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            while !Task.isCancelled {
                await self?.renewDue()
                try? await Task.sleep(for: .seconds(6 * 3600))
            }
        }
    }

    // MARK: Poki Setup updates

    func checkForUpdate(prompt: Bool = false) async {
        if demo { return }
        guard let u: UpdateInfo = try? await bridge.call("check_update") else { return }
        update = u
        if prompt, u.newer, let v = u.latest, askedAbout != v {
            askedAbout = v
            updatePrompt = v
        }
    }

    /// Downloads the update, checks it, puts it in place of this app and quits; the new one opens
    /// by itself. When that is not possible the disk image opens in Finder instead.
    func installUpdate() async throws {
        installingUpdate = true
        defer { installingUpdate = false }
        let done: Installed = try await bridge.call("install_update")
        if done.relaunching {
            NSApp.terminate(nil)
        } else {
            banner = "Poki Setup could not replace itself here, so its update is open in Finder. Quit Poki Setup, then drag the new one into Applications."
        }
    }

    // MARK: Refresh

    func refreshAccount() async {
        if demo { return }
        do {
            let state: AccountState = try await bridge.call("account")
            account = state
            accountError = nil
            if state.pendingFactor != nil {
                codeVia = state.pendingFactor
                needsCode = true
            }
            if state.signedIn, state.pendingFactor == nil, !state.isRateLimited(), teams.isEmpty {
                do {
                    teams = try await bridge.call("teams")
                } catch let e as CoreError where e.kind == "needs_code" {
                    await promptForCode()
                } catch {}
            }
        } catch let e as CoreError {
            accountError = e
        } catch {
            accountError = CoreError(kind: "error", message: error.localizedDescription)
        }
    }

    /// Another client saved the account: show what it stored now, without asking Apple for anything.
    func accountChanged() async {
        guard !demo, let state: AccountState = try? await bridge.call("account") else { return }
        account = state
        accountError = nil
        if state.needsReauth == true, state.pendingFactor == nil {
            needsCode = false
            codeVia = nil
            teams = []
        }
    }

    func promptForCode() async {
        guard !demo else { return }
        if let state: AccountState = try? await bridge.call("account") {
            account = state
            accountError = nil
            codeVia = state.pendingFactor
        }
        needsCode = true
    }

    func refreshPhones() async {
        if demo { return }
        if busyJobs.contains("install") || busyJobs.contains("pair") || busyJobs.contains("devmode") { return }
        do {
            let rows: [PhoneRow] = try await bridge.call("phones")
            if rows.map(\.id) != phones.map(\.id) || rows.map(\.facts) != phones.map(\.facts) {
                phones = rows
            }
            phonesError = nil
            if let id = selectedUDID, !rows.contains(where: { $0.id == id }) { selectedUDID = nil }
        } catch let e as CoreError {
            phonesError = e
            phones = []
        } catch {}
    }

    func refreshRecords() async {
        if demo { return }
        records = (try? await bridge.call("records")) ?? []
    }

    func refreshLatest() async {
        if demo { return }
        do {
            latest = try await bridge.call("latest_release")
            latestError = nil
        } catch {
            latest = nil
            latestError = error.localizedDescription
        }
    }

    var channel: ChannelInfo? { channels.first(where: \.selected) }

    func refreshChannels() async {
        if demo { return }
        if let c: [ChannelInfo] = try? await bridge.call("channels") { channels = c }
    }

    /// Saves the channel; installs, renewals and update checks follow it from now on.
    func setChannel(_ id: String) async throws {
        channels = try await bridge.call("set_channel", ["channel": id])
        await refreshLatest()
    }

    // MARK: Developer

    func refreshDev() async {
        if demo { return }
        if let s: DevState = try? await bridge.call("dev_state") { dev = s }
    }

    /// GitHub's device sign-in: shows a code to enter on github.com, then waits until GitHub says
    /// it was entered.
    func signInToGitHub() async {
        githubError = nil
        var started = ""
        do {
            let code: GithubSignIn = try await bridge.call("github_sign_in_start")
            started = code.deviceCode
            githubCode = code
            dev = try await bridge.call("github_sign_in_finish", ["pending": code.wire])
            await refreshTestBuilds(fresh: true)
        } catch {
            // A cancelled sign-in, or one a newer one replaced, ends here with nothing to say.
            if started.isEmpty || githubCode?.deviceCode == started { githubError = error.localizedDescription }
        }
        if githubCode?.deviceCode == started { githubCode = nil }
    }

    func cancelGitHubSignIn() {
        githubCode = nil
        Task { let _: DevState? = try? await bridge.call("github_sign_in_cancel") }
    }

    /// Uses the account the GitHub CLI (gh) is signed in to on this Mac.
    func useGitHubCLI() async {
        githubError = nil
        do {
            dev = try await bridge.call("github_use_cli")
            await refreshTestBuilds(fresh: true)
        } catch { githubError = error.localizedDescription }
    }

    func useGitHubToken(_ token: String) async -> Bool {
        githubError = nil
        do {
            dev = try await bridge.call("github_use_token", ["token": token])
            await refreshTestBuilds(fresh: true)
            return true
        } catch {
            githubError = error.localizedDescription
            return false
        }
    }

    func signOutOfGitHub() async {
        githubCode = nil
        do {
            dev = try await bridge.call("github_sign_out")
            testBuilds = nil
            if page == .testBuilds { page = .github }
        } catch { githubError = error.localizedDescription }
    }

    func setDevPrefs(_ prefs: DevPrefs) async {
        dev.prefs = prefs
        do {
            dev = try await bridge.call("dev_set_prefs", ["prefs": prefs.wire])
            await refreshTestBuilds()
        } catch { testBuildsError = error.localizedDescription }
    }

    func refreshTestBuilds(fresh: Bool = false) async {
        guard !demo, dev.signedIn else { return }
        loadingTestBuilds = true
        defer { loadingTestBuilds = false }
        do {
            testBuilds = try await bridge.call("test_builds", ["fresh": fresh])
            testBuildsError = nil
        } catch { testBuildsError = error.localizedDescription }
    }

    /// Downloads a test build into the cache without installing it.
    func downloadTestBuild(_ b: TestBuild) async throws {
        guard let id = b.artifactId else { return }
        struct Got: Decodable { var ipa: String }
        let _: Got = try await job("download") { try await bridge.call("test_build_download", ["artifact_id": id]) }
        await refreshTestBuilds()
        await refreshDev()
    }

    /// Signs a test build with the Apple Account and installs it, like Install Poki does with the
    /// release. The device's record keeps the build, so renewals sign it again.
    func installTestBuild(_ b: TestBuild, udid: String) async throws -> InstallAnswer {
        guard let ref = b.ref else { throw CoreError(kind: "error", message: "This build is not ready yet.") }
        let answer = try await installClosingPoki(udid: udid, ["udid": udid, "test_build": ref, "hand_off": false])
        await refreshRecords()
        await refreshPhones()
        await refreshTestBuilds()
        await refreshDev()
        return answer
    }

    /// The automatic sync: the newest build the filters let through, once, when it is newer than
    /// the last one handled. Installs it on the chosen device when that one is connected.
    func syncTestBuilds() async {
        guard !demo, dev.signedIn, dev.prefs.syncing else { return }
        if busyJobs.contains("install") || busyJobs.contains("download") { return }
        guard let next = try? await bridge.call("test_build_next", as: TestBuild?.self) else { return }
        let p = dev.prefs
        let target = p.autoInstallUdid.flatMap { id in phones.first(where: { $0.id == id && $0.facts != nil }) }
        if p.autoInstall, let target, account?.signedIn == true {
            do {
                _ = try await installTestBuild(next, udid: target.id)
                banner = "Installed test build \(next.runNumber) on \(target.title)."
            } catch {
                banner = "Test build \(next.runNumber) did not install on \(target.title). \(error.localizedDescription)"
            }
            dev = (try? await bridge.call("test_build_synced", ["run_id": next.runId])) ?? dev
            return
        }
        if p.autoDownload, !next.downloaded {
            do { try await downloadTestBuild(next) } catch {
                banner = "Test build \(next.runNumber) did not download. \(error.localizedDescription)"
                dev = (try? await bridge.call("test_build_synced", ["run_id": next.runId])) ?? dev
                return
            }
        }
        // Waiting for the device: the build stays next until it is plugged in.
        if !p.autoInstall {
            dev = (try? await bridge.call("test_build_synced", ["run_id": next.runId])) ?? dev
        }
    }

    func deleteTestBuildDownloads() async {
        do {
            dev = try await bridge.call("test_builds_delete_downloads")
            await refreshTestBuilds()
        } catch { report(error) }
    }

    // MARK: Account

    func signIn(appleID: String, password: String, keep: Bool) async throws {
        let answer: SignInAnswer = try await bridge.call("sign_in", ["apple_id": appleID, "password": password, "keep_password": keep])
        if answer.needsCode {
            codeVia = answer.via
            needsCode = true
        } else {
            needsCode = false
            teams = []
            await refreshAccount()
        }
    }

    func finishSignIn(code: String) async throws {
        try await bridge.run("finish_sign_in", ["code": code])
        needsCode = false
        teams = []
        await refreshAccount()
    }

    func signOut() async {
        do {
            try await bridge.run("sign_out")
            teams = []
            needsCode = false
            await refreshAccount()
        } catch { report(error) }
    }

    func chooseTeam(_ team: Team) async {
        do {
            try await bridge.run("choose_team", ["team_id": team.teamId])
            await refreshAccount()
        } catch { report(error) }
    }

    func setAnisette(_ source: AnisetteSource) async throws {
        try await bridge.run("set_anisette", ["source": source.wire])
        await refreshAccount()
    }

    // MARK: Jobs

    private func apply(_ e: ProgressEvent) {
        var list = steps[e.job] ?? []
        func index() -> Int? { list.firstIndex(where: { $0.id == e.id }) }
        switch e.kind {
        case "step":
            for i in list.indices where list[i].state == .running || list[i].state == .waiting { list[i].state = .done }
            if let i = index() {
                list[i].state = .running
                list[i].title = e.title ?? list[i].title
            } else {
                list.append(StepItem(id: e.id, title: e.title ?? e.id))
            }
        case "part":
            if let i = index() {
                list[i].fraction = e.fraction
                if let d = e.detail { list[i].detail = d }
            }
        case "note":
            if let i = index(), let t = e.text { list[i].notes.append(t) }
        case "waiting":
            if let i = index() {
                list[i].state = .waiting
                list[i].detail = e.text
            } else {
                list.append(StepItem(id: e.id, title: e.text ?? e.id, state: .waiting))
            }
        case "done":
            if let i = index() {
                list[i].state = .done
                list[i].fraction = nil
                if let d = e.detail { list[i].detail = d }
            }
        default:
            break
        }
        steps[e.job] = list
    }

    /// Runs a long job: clears its steps, marks it busy, and marks the running step failed on error.
    func job<T>(_ name: String, _ body: () async throws -> T) async throws -> T {
        steps[name] = []
        busyJobs.insert(name)
        defer { busyJobs.remove(name) }
        do {
            let value = try await body()
            // The core ends with "all" done; the last step it named is done with it.
            if var list = steps[name] {
                for i in list.indices where list[i].state == .running || list[i].state == .waiting { list[i].state = .done }
                steps[name] = list
            }
            return value
        } catch {
            if var list = steps[name], let i = list.lastIndex(where: { $0.state != .done }) {
                list[i].state = .failed
                list[i].detail = error.localizedDescription
                steps[name] = list
            }
            throw error
        }
    }

    func install(udid: String, ipa: URL?, handOff: Bool) async throws -> InstallAnswer {
        let answer = try await installClosingPoki(udid: udid, ["udid": udid, "ipa": ipa?.path, "hand_off": handOff])
        await refreshRecords()
        await refreshPhones()
        return answer
    }

    // MARK: Closing Poki before an update

    /// The question on screen: Poki is open on this device, close it?
    @Published var closeAsk: CloseAsk?
    private var closeAnswer: CheckedContinuation<Bool, Never>?

    struct CloseAsk: Identifiable {
        let id = UUID()
        var name: String
    }

    private func deviceName(_ udid: String) -> String {
        phones.first(where: { $0.id == udid })?.title ?? records.first(where: { $0.udid == udid })?.phoneName ?? "the device"
    }

    /// Asks whether to close Poki on the device, and waits for the answer.
    func askToClosePoki(udid: String) async -> Bool {
        if dev.prefs.closeWithoutAsking { return true }
        closeAnswer?.resume(returning: false)
        return await withCheckedContinuation { c in
            closeAnswer = c
            closeAsk = CloseAsk(name: deviceName(udid))
        }
    }

    func answerClose(_ yes: Bool) {
        let c = closeAnswer
        closeAnswer = nil
        closeAsk = nil
        c?.resume(returning: yes)
    }

    /// Before an update replaces Poki: when Poki is running on the device, asks to close it (or
    /// closes it without asking when Developer says so). True means go on and close Poki; the
    /// core still checks right before it installs.
    func okToReplacePoki(udid: String) async -> Bool {
        let installed = records.contains(where: { $0.udid == udid }) || phones.first(where: { $0.id == udid })?.record != nil
        guard installed, !dev.prefs.closeWithoutAsking else { return true }
        let running = try? await bridge.call("poki_running", ["udid": udid], as: Bool?.self)
        guard running == .some(.some(true)) else { return true }
        return await askToClosePoki(udid: udid)
    }

    /// Runs an install that may replace a running Poki: asks first, and asks again if Poki was
    /// opened while Poki Setup signed it.
    func installClosingPoki(udid: String, _ args: [String: Any?]) async throws -> InstallAnswer {
        guard await okToReplacePoki(udid: udid) else {
            throw CoreError(kind: "cancelled", message: "Nothing was installed. Poki is still open on \(deviceName(udid)).")
        }
        var withClose = args
        withClose["close_poki"] = true
        do {
            return try await job("install") { try await bridge.call("install", withClose) }
        } catch let e as CoreError where e.kind == "poki_running" {
            guard await askToClosePoki(udid: udid) else { throw e }
            return try await job("install") { try await bridge.call("install", withClose) }
        }
    }

    func pair(udid: String) async throws {
        try await job("pair") { try await bridge.run("pair", ["udid": udid]) }
        await refreshPhones()
    }

    func enableDeveloperMode(udid: String) async throws {
        try await job("devmode") { try await bridge.run("devmode", ["udid": udid]) }
        await refreshPhones()
    }

    func renew(udid: String) async throws {
        // A renewal closes Poki before it installs; asked first when Poki is open.
        guard await okToReplacePoki(udid: udid) else { return }
        let _: Record = try await job("renew") { try await bridge.call("renew", ["udid": udid]) }
        await refreshRecords()
    }

    func renewDue() async {
        guard !demo, !needsCode, !isRateLimited, account?.passwordKept == true else { return }
        if let state: AccountState = try? await bridge.call("account") {
            account = state
            if state.pendingFactor != nil {
                codeVia = state.pendingFactor
                needsCode = true
                return
            }
            if state.isRateLimited() || !state.passwordKept { return }
        }
        let results = (try? await bridge.call("renew_due", as: [RenewResult].self)) ?? []
        if results.contains(where: { $0.kind == "needs_code" }) {
            await promptForCode()
        } else if results.contains(where: { !$0.ok }), let state: AccountState = try? await bridge.call("account") {
            account = state
        }
        await refreshRecords()
    }

    struct RenewResult: Decodable { var udid: String; var ok: Bool; var error: String?; var kind: String? }

    struct AgentPrompt: Decodable { var prompt: String }

    /// Puts the instructions for an agent on this Mac (Claude Code, Codex and the like) on the
    /// pasteboard; they name the command line tool inside this app.
    func copyAgentPrompt() async {
        do {
            let p: AgentPrompt = try await bridge.call("agent_prompt")
            copyToPasteboard(p.prompt)
            banner = "Copied. Paste it into your agent (Claude Code, Codex or another one that runs on this Mac)."
        } catch { report(error) }
    }

    /// The person chose Replace Certificate: the next install revokes the certificate the core
    /// named, and only that one.
    func approveCertificateReplacement() async throws {
        try await bridge.run("approve_certificate_replacement")
    }

    func forget(udid: String) async {
        do {
            try await bridge.run("forget_phone", ["udid": udid])
            await refreshRecords()
        } catch { report(error) }
    }

    func report(_ error: Error) {
        banner = error.localizedDescription
    }

    // MARK: Demo data (screenshots only: POKI_SETUP_DEMO=1)

    private func loadDemo() {
        info = AppInfo(version: "0.2.0", os: "macos", arch: "aarch64", dataDir: "~/Library/Application Support/nz.zheha.poki.setup", canUseSystemAnisette: true, defaultAnisette: "https://new.ani.sidestore.io", anisetteServers: ["https://new.ani.sidestore.io", "https://mac-ani.jkcoxson.com", "https://ani2.stikstore.app"])
        account = AccountState(signedIn: true, appleId: "jane.appleseed@icloud.com", name: "Jane Appleseed", teamId: "A1B2C3D4E5", passwordKept: true, anisette: .remote("https://new.ani.sidestore.io"), pendingFactor: nil)
        teams = [Team(teamId: "A1B2C3D4E5", name: "Jane Appleseed (Personal Team)", kind: "Individual", isFree: true)]
        let facts = Facts(udid: "00008150-000829EA2183C01C", name: "Jane's iPhone", productType: "iPhone18,1", ios: "26.1", build: "23B85", developerMode: true, pairedWithThisComputer: true, canPairOnDevice: false, wifiAddress: "192.168.1.23")
        let now = Int(Date().timeIntervalSince1970)
        let rec = Record(udid: facts.udid, phoneName: facts.name, ios: facts.ios, appleId: "jane.appleseed@icloud.com", teamId: "A1B2C3D4E5", teamName: "Jane Appleseed (Personal Team)", teamIsFree: true, bundleId: "nz.zheha.poki.A1B2C3D4E5", appGroup: "group.nz.zheha.poki.A1B2C3D4E5", version: "0.2.8", build: "64", releaseTag: "local:Poki-0.2.8-external-unsigned.ipa", signedAt: now - 2 * 86_400, profileExpiresAt: now + 5 * 86_400, lastCheckedAt: now - 3600, lastError: nil, wifiAddress: "192.168.1.23", pairingHandedOff: false)
        phones = [PhoneRow(phone: PhoneRef(udid: facts.udid), facts: facts, error: nil, record: rec)]
        records = [rec]
        relay = Deployed(accountId: "abc", accountName: "Jane's account", address: "https://poki-relay.jane.workers.dev", firstDeploy: false, deployedAt: now - 86_400, phoneLink: "poki://setup?relay=https://poki-relay.jane.workers.dev")
        latest = Release(tag: "ios-v0.2.8", version: "0.2.8", build: "64", ipaName: "Poki-external-0.2.8-64.ipa", channel: "beta")
        channels = [
            ChannelInfo(id: "stable", title: "Stable", selected: true, latest: nil),
            ChannelInfo(id: "beta", title: "Beta", selected: false, latest: latest),
            ChannelInfo(id: "alpha", title: "Alpha", selected: false, latest: Release(tag: "ios-alpha-0.2.8-110", version: "0.2.8", build: "110", ipaName: "Poki-external-0.2.8-110.ipa", channel: "alpha")),
            ChannelInfo(id: "pre-alpha", title: "Pre-alpha", selected: false, latest: Release(tag: "ios-prealpha-0.2.8-260", version: "0.2.8", build: "260", ipaName: "Poki-external-0.2.8-260.ipa", channel: "pre-alpha")),
        ]
        dev = DevState(signedIn: true, login: "janeappleseed", source: "github", cliAvailable: true, canSignIn: true, prefs: DevPrefs(), syncedRun: 101, downloadsBytes: 48_000_000, repo: "JosssphZhou/poki")
        let iso = ISO8601DateFormatter()
        let pr = PullRef(number: 360, title: "Record the iPhone history on the device", url: "https://github.com/JosssphZhou/poki/pull/360", state: "open", draft: true)
        testBuilds = TestBuildListing(builds: [
            TestBuild(state: "building", runId: 103, runNumber: 21, runAttempt: 1, workflow: "iOS IPA", branch: "dev/iphone-history", sha: "c0ffee1234567890", title: "Keep the timeline on the device", actor: "janeappleseed", event: "workflow_dispatch", runUrl: "https://github.com/JosssphZhou/poki/actions/runs/103", createdAt: iso.string(from: Date().addingTimeInterval(-240)), pr: pr, artifactId: nil, artifactName: nil, size: 0, expiresAt: nil, downloaded: false),
            TestBuild(state: "ready", runId: 102, runNumber: 20, runAttempt: 1, workflow: "iOS IPA", branch: "dev/iphone-history", sha: "aa47ce4144abe014", title: "Read the tree from the screen centre", actor: "janeappleseed", event: "workflow_dispatch", runUrl: "https://github.com/JosssphZhou/poki/actions/runs/102", createdAt: iso.string(from: Date().addingTimeInterval(-3_600)), pr: pr, artifactId: 9002, artifactName: "Poki-unsigned", size: 48_482_371, expiresAt: nil, downloaded: true),
            TestBuild(state: "ready", runId: 101, runNumber: 19, runAttempt: 2, workflow: "iOS IPA", branch: "dev/automation-session-rebind", sha: "99c3948abcdef012", title: "Stop automation when Poki opens", actor: "janeappleseed", event: "workflow_dispatch", runUrl: "https://github.com/JosssphZhou/poki/actions/runs/101", createdAt: iso.string(from: Date().addingTimeInterval(-86_400)), pr: nil, artifactId: 9001, artifactName: "Poki-unsigned", size: 48_472_575, expiresAt: nil, downloaded: false),
        ], total: 3, branches: ["dev/automation-session-rebind", "dev/iphone-history"], login: "janeappleseed", checkedAt: now)
        steps["install"] = [
            StepItem(id: "phone", title: "Finding the iPhone", state: .done, detail: facts.name),
            StepItem(id: "pair", title: "Pairing with the iPhone", state: .done),
            StepItem(id: "account", title: "Checking the Apple Account", state: .done, detail: "Personal Team"),
            StepItem(id: "sign", title: "Signing Poki for Jane Appleseed", state: .running, fraction: 0.62, detail: "Signing PokiWidgets.appex"),
        ]
    }
}
