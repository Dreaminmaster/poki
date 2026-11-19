import Foundation

// The shapes the core answers with (snake_case on the wire, camelCase here).

struct AppInfo: Decodable {
    var version: String
    var os: String
    var arch: String
    var dataDir: String
    var canUseSystemAnisette: Bool
    var defaultAnisette: String
    var anisetteServers: [String]
}

struct AnisetteSource: Codable, Equatable {
    var kind: String
    var url: String?

    static func remote(_ url: String) -> AnisetteSource { AnisetteSource(kind: "remote", url: url) }
    static let system = AnisetteSource(kind: "system", url: nil)

    var wire: [String: Any] {
        var d: [String: Any] = ["kind": kind]
        if let url { d["url"] = url }
        return d
    }
}

struct AccountState: Decodable {
    var signedIn: Bool
    var needsReauth: Bool? = nil
    var appleId: String?
    var name: String?
    var teamId: String?
    var passwordKept: Bool
    var anisette: AnisetteSource
    var pendingFactor: String?
    var rateLimited: Bool? = nil
    var rateLimitedUntil: Int? = nil

    func isRateLimited(at now: Date = .now) -> Bool {
        if let until = rateLimitedUntil {
            return now.timeIntervalSince1970 < TimeInterval(until)
        }
        return rateLimited == true
    }
}

struct SignInAnswer: Decodable {
    var needsCode: Bool
    var via: String?
}

struct Team: Decodable, Identifiable, Hashable {
    var teamId: String
    var name: String
    var kind: String
    var isFree: Bool
    var id: String { teamId }
}

struct PhoneRef: Decodable {
    var udid: String
}

struct Facts: Decodable, Equatable {
    var udid: String
    var name: String
    var productType: String
    var ios: String
    var build: String
    var developerMode: Bool?
    var pairedWithThisComputer: Bool
    var canPairOnDevice: Bool
    var wifiAddress: String?
}

struct Record: Decodable, Identifiable, Equatable {
    var udid: String
    var phoneName: String
    var ios: String
    var appleId: String
    var teamId: String
    var teamName: String
    var teamIsFree: Bool
    var bundleId: String
    var appGroup: String
    var version: String
    var build: String
    var releaseTag: String
    var signedAt: Int
    var profileExpiresAt: Int
    var lastCheckedAt: Int?
    var lastError: String?
    var wifiAddress: String?
    var pairingHandedOff: Bool
    /// Set when the device has a test build from GitHub Actions.
    var testBuild: BuildRef? = nil
    var id: String { udid }

    var expires: Date { Date(timeIntervalSince1970: TimeInterval(profileExpiresAt)) }
    var daysLeft: Int { Int(floor(expires.timeIntervalSinceNow / 86_400)) }
    var isExpired: Bool { expires <= Date() }
}

struct PhoneRow: Decodable, Identifiable {
    var phone: PhoneRef
    var facts: Facts?
    var error: String?
    var record: Record?
    var id: String { phone.udid }
    var title: String { facts?.name ?? localized("Device") }
}

struct Handoff: Decodable, Equatable {
    var link: String
    var inlineLink: String
    var url: String
    var host: String
    var port: Int
}

struct InstallAnswer: Decodable {
    var record: Record
    var notes: [String]
    var handoff: Handoff?
}

struct Deployed: Decodable, Equatable {
    var accountId: String
    var accountName: String
    var address: String
    var firstDeploy: Bool
    var deployedAt: Int
    var phoneLink: String
    var workerSha256: String? = nil
    var workerSource: String? = nil
}

/// Which relay Poki Setup deploys now, and whether yours is older (`relay_worker`).
struct WorkerStatus: Decodable {
    var source: String
    var downloadUrl: String
    var guideUrl: String
    var sha256: String
    var deployedSha256: String?
    var updateAvailable: Bool
}

struct CloudflareAccount: Decodable, Identifiable, Hashable {
    var id: String
    var name: String
}

struct Check: Decodable, Equatable {
    var at: Int
    var ok: Bool
    var relayOk: Bool
    var phoneOnline: Bool
    var tools: [String]
    var detail: String
}

struct Connector: Decodable, Identifiable, Equatable {
    var name: String
    var url: String
    var addedAt: Int
    var lastCheck: Check?
    var id: String { url }
}

struct Snippet: Decodable, Identifiable {
    var name: String
    var text: String
    var id: String { name }
}

struct UpdateInfo: Decodable {
    var current: String
    var latest: String?
    var url: String?
    var newer: Bool
}

struct Installed: Decodable {
    var path: String
    var relaunching: Bool
}

struct Release: Decodable {
    var tag: String
    var version: String
    var build: String
    var ipaName: String
    /// "stable", "beta", "alpha" or "pre-alpha".
    var channel: String? = nil
}

/// A release channel and its newest release (`channels`, `set_channel`).
struct ChannelInfo: Decodable, Identifiable, Hashable {
    var id: String
    var title: String
    var selected: Bool
    var latest: Release?

    var displayTitle: String {
        switch id {
        case "stable": localized("Stable")
        case "beta": localized("Beta")
        case "alpha": localized("Alpha")
        case "pre-alpha": localized("Pre-alpha")
        default: title
        }
    }

    static func == (a: ChannelInfo, b: ChannelInfo) -> Bool { a.id == b.id && a.selected == b.selected && a.latest?.tag == b.latest?.tag }
    func hash(into h: inout Hasher) { h.combine(id) }
}

/// One progress event from a long job (`install`, `pair`, `renew`, `relay`, ...).
struct ProgressEvent: Decodable {
    var job: String
    var kind: String
    var id: String
    var title: String?
    var fraction: Double?
    var detail: String?
    var text: String?
}

/// A step of a long job, as the UI shows it.
struct StepItem: Identifiable, Equatable {
    enum State: Equatable { case running, waiting, done, failed }
    var id: String
    var title: String
    var state: State = .running
    var fraction: Double?
    var detail: String?
    var notes: [String] = []

    // Only step headings have translations. Details and notes are the original diagnostic output.
    var displayTitle: String {
        let localization = SetupLocalization.shared
        if id == "sign", title.hasPrefix("Signing Poki for ") {
            let team = String(title.dropFirst("Signing Poki for ".count))
            return localization.text("Signing Poki for \(team)", table: "Progress")
        }
        if id == "release", title.hasPrefix("Downloading test build ") {
            let build = String(title.dropFirst("Downloading test build ".count))
            return localization.text("Downloading test build \(build)", table: "Progress")
        }
        return localization.text(String.LocalizationValue(stringLiteral: title), table: "Progress")
    }
}

/// The SF Symbol for a device: an iPad by its product type ("iPad16,3") or, without one, by name.
func deviceSymbol(_ productType: String?, name: String? = nil) -> String {
    if let p = productType { return p.hasPrefix("iPad") ? "ipad" : "iphone.gen3" }
    return name?.localizedCaseInsensitiveContains("iPad") == true ? "ipad" : "iphone.gen3"
}

// MARK: Developer (test builds from GitHub Actions)

/// The filters and the automatic sync (`dev_state`, `dev_set_prefs`).
struct DevPrefs: Decodable, Equatable {
    var onlyMine = true
    var branch: String?
    var withPrOnly = false
    var autoDownload = false
    var autoInstall = false
    var autoInstallUdid: String?
    var keepOnRenew = true
    var closeWithoutAsking = false

    var wire: [String: Any] {
        var d: [String: Any] = ["only_mine": onlyMine, "with_pr_only": withPrOnly, "auto_download": autoDownload, "auto_install": autoInstall, "keep_on_renew": keepOnRenew, "close_without_asking": closeWithoutAsking]
        if let branch, !branch.isEmpty { d["branch"] = branch }
        if let autoInstallUdid { d["auto_install_udid"] = autoInstallUdid }
        return d
    }

    var syncing: Bool { autoDownload || autoInstall }
}

/// The GitHub sign-in and the Developer choices.
struct DevState: Decodable {
    var signedIn = false
    var login: String?
    /// "github", "cli" or "token".
    var source: String?
    var cliAvailable = false
    var canSignIn = false
    var prefs = DevPrefs()
    var syncedRun: UInt64?
    var downloadsBytes: Int64 = 0
    var repo = "JosssphZhou/poki"
}

/// GitHub's device sign-in under way (`github_sign_in_start`).
struct GithubSignIn: Decodable, Equatable {
    var deviceCode: String
    var userCode: String
    var verificationUri: String
    var interval: Int
    var expiresIn: Int

    var wire: [String: Any] { ["device_code": deviceCode, "user_code": userCode, "verification_uri": verificationUri, "interval": interval, "expires_in": expiresIn] }
}

struct PullRef: Decodable, Hashable {
    var number: Int
    var title: String
    var url: String
    var state: String
    var draft: Bool
}

/// One test build, or a run still making one (`test_builds`).
struct TestBuild: Decodable, Identifiable, Hashable {
    /// "ready", "building" or "expired".
    var state: String
    var runId: UInt64
    var runNumber: Int
    var runAttempt: Int
    var workflow: String
    var branch: String
    var sha: String
    var title: String
    var actor: String?
    var event: String
    var runUrl: String
    var createdAt: String
    var pr: PullRef?
    var artifactId: UInt64?
    var artifactName: String?
    var size: Int64
    var expiresAt: String?
    var downloaded: Bool

    var id: UInt64 { runId }
    var shortSha: String { String(sha.prefix(7)) }
    var isReady: Bool { state == "ready" }
    var isBuilding: Bool { state == "building" }
    var created: Date? { ISO8601DateFormatter().date(from: createdAt) }
    var expires: Date? { expiresAt.flatMap { ISO8601DateFormatter().date(from: $0) } }

    /// What the install keeps in the device's record.
    var ref: [String: Any]? {
        guard let artifactId else { return nil }
        var d: [String: Any] = ["artifact_id": artifactId, "run_id": runId, "run_number": runNumber, "workflow": workflow, "branch": branch, "sha": sha]
        if let pr { d["pr"] = pr.number }
        return d
    }
}

struct TestBuildListing: Decodable {
    var builds: [TestBuild]
    var total: Int
    var branches: [String]
    var login: String?
    var checkedAt: Int
}

/// The test build a device has, from its record.
struct BuildRef: Decodable, Equatable {
    var artifactId: UInt64
    var runId: UInt64
    var runNumber: Int
    var workflow: String
    var branch: String
    var sha: String
    var pr: Int?
}
