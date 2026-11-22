import Foundation

/// The apps on this iPhone and their bundle ids, for the chat's agent (`find_app`). A model that
/// recalls a bundle id guesses: a tester's 淘宝 and 美团 tasks (Nov 13 2026) were refused as "no app
/// with that bundle id is installed" and the agent told the owner to install apps they had.
///
/// Sources, most reliable first: the phone's own list from installation_proxy (the signer's `apps`
/// request over the loopback, the lookup Poki Runner used), the names Poki knows (KnownApps), and
/// the App Store's public search as the backup, which also gives the link of an app that is not
/// installed.
///
/// Only a list read in the last five minutes can say an app is missing. An older list, iOS's icons
/// and the App Store can only say an app is there: a failed read, a missing icon or a store that did
/// not answer is no evidence that it is not.
///
/// The shared finder also gives the list to the app's names, icons and capsules (DynamicApps) and keeps
/// it in a file (`cacheFile`). What leaves the phone: nothing from that file. The App Store fallbacks
/// do send something to itunes.apple.com, one request at a time: find_app's search sends the name or
/// purpose asked for, and an icon the phone lacks is looked up by its one bundle id (AppIconStore).
@MainActor
final class InstalledApps {
    static let shared = InstalledApps()

    struct App: Equatable, Codable {
        var id: String
        var name: String?
        var bundleName: String?
        /// installation_proxy's ApplicationType: "User" or "System" (nil from an older answer).
        var type: String? = nil
        enum CodingKeys: String, CodingKey { case id, name, bundleName = "bundle_name", type }
    }

    /// The last list read, so the app's icons and capsules know the installed apps from launch on,
    /// before the loopback is up. Each successful read replaces it; one older than 30 days is removed
    /// unread at launch; it goes with the app when the app is deleted. It is kept out of iCloud and
    /// computer backups, and never leaves the phone.
    static var cacheFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("installed-apps.json")
    }
    static let cacheMaxAge: TimeInterval = 30 * 86_400

    init() {
        if let saved = Self.savedList() { publish(saved, current: false) }
    }

    private static func savedList() -> [App]? {
        let file = cacheFile
        guard let written = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { return nil }
        guard Date().timeIntervalSince(written) < cacheMaxAge else { try? FileManager.default.removeItem(at: file); return nil }
        return (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([App].self, from: $0) }
    }

    /// The list goes to the names, icons and capsules (DynamicApps), and to the file when `save`.
    private func publish(_ list: [App], save: Bool = false, current: Bool = false) {
        DynamicApps.set(list.compactMap { app in
            (app.name ?? app.bundleName).map { DynamicApps.Entry(id: app.id, name: $0, user: app.type == "User") }
        }, current: current)
        AppIconStore.shared.directoryChanged()
        if save { Self.keep(list) }
    }

    /// Writes the list to the file, which is kept out of backups before it holds anything: the file is
    /// made empty, excluded, and only then filled in place (an atomic write would swap in a new file
    /// without the mark). If it cannot be excluded or filled, no file is left.
    private static func keep(_ list: [App]) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        var file = cacheFile
        let files = FileManager.default
        do {
            try files.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !files.fileExists(atPath: file.path) { try Data().write(to: file) }
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try file.setResourceValues(values)
            guard try file.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true else { throw CocoaError(.fileWriteUnknown) }
            try data.write(to: file)
        } catch {
            try? files.removeItem(at: file)
        }
    }

    /// Reads the list again in the background when it is older than five minutes (the loopback just
    /// came up, a chat task began).
    func refreshSoon() {
        guard !refreshing else { return }
        refreshing = true
        Task { _ = await list(); refreshing = false }
    }
    private var refreshing = false

    /// The phone's list as last read. `fresh` when it was read in the last five minutes; an older one
    /// misses any app installed since, so it only proves what it holds.
    struct Inventory: Equatable {
        var apps: [App]
        var fresh: Bool
        var readAt: Date
    }

    /// The signer's way to the phone (AppModel sets it with the signer's): nil while the loopback is down.
    var phone: () -> [String: Any]? = { nil }
    /// Sends one request to the signer and gives its answer as it came ({"v": value}).
    var call: ([String: Any]) async throws -> Data = { try await SignerBridge.call($0) }

    /// Reads the list over the phone's way: the signer's `apps` request.
    private func fetch(_ phone: [String: Any]) async throws -> [App] {
        var request = phone
        request["op"] = "apps"
        struct Answer: Decodable {
            struct Value: Decodable { let apps: [App] }
            let v: Value
        }
        return try JSONDecoder().decode(Answer.self, from: await call(request)).v.apps
    }
    /// true when iOS has an icon for an id, nil when it cannot say (never a confirmed no).
    var hasIcon: @MainActor (String) -> Bool? = { AppIconStore.installedOnPhone($0) }
    /// The App Store's search: nil when the store could not be reached or read.
    var search: (String) async -> [StoreApp]? = { await AppStoreSearch.apps($0) }
    /// The clock, so a list can grow old.
    var now: () -> Date = { Date() }

    private var last: (apps: [App], at: Date)?
    private(set) var lastProblem: String?
    private static let maxAge: TimeInterval = 300

    /// The phone's list, read again after five minutes. When that read fails, the older list comes
    /// back marked not fresh; nil when the list was never read.
    func list() async -> Inventory? {
        if let last, now().timeIntervalSince(last.at) < Self.maxAge { return Inventory(apps: last.apps, fresh: true, readAt: last.at) }
        if let request = phone() {
            do {
                let read = try await fetch(request)
                let at = now()
                last = (apps: read, at: at); lastProblem = nil
                publish(read, save: true, current: true)
                return Inventory(apps: read, fresh: true, readAt: at)
            } catch {
                lastProblem = error.localizedDescription
                DynamicApps.clearCurrent()
            }
        } else {
            lastProblem = "the loopback to the phone is not on"
            DynamicApps.clearCurrent()
        }
        return last.map { Inventory(apps: $0.apps, fresh: false, readAt: $0.at) }
    }

    /// Whether `id` is on this phone: true when the list holds it or iOS has its icon, false only when
    /// a fresh list lacks it, nil when nothing can say.
    func installed(_ id: String, in inventory: Inventory?) -> Bool? {
        if inventory?.apps.contains(where: { $0.id.caseInsensitiveCompare(id) == .orderedSame }) == true { return true }
        if inventory?.fresh == true { return false }
        return hasIcon(id) == true ? true : nil
    }

    // MARK: find_app

    struct StoreApp: Equatable {
        var id: String
        var name: String
        var url: String?
    }

    struct Match: Equatable {
        var id: String
        var name: String
        var installed: Bool?
        var url: String?
    }

    /// How well an installed app's names fit what the owner called it: 0 an id KnownApps gives that
    /// name, 1 the exact name, 2 a name that starts with it, 3 one that holds it; best first. 0 and 1
    /// both mean "this app goes by that name".
    static func ranked(_ name: String, in list: [App]) -> [(app: App, score: Int)] {
        let key = normalized(name)
        guard !key.isEmpty else { return [] }
        let known = KnownApps.find(name).map { Set($0.ids.map { $0.lowercased() }) } ?? []
        func score(_ app: App) -> Int? {
            if known.contains(app.id.lowercased()) { return 0 }
            let names = [app.name, app.bundleName].compactMap { $0 }.map(normalized).filter { !$0.isEmpty }
            if names.contains(key) { return 1 }
            if names.contains(where: { $0.hasPrefix(key) }) { return 2 }
            if key.count >= 2, names.contains(where: { $0.contains(key) || ($0.count >= 2 && key.contains($0)) }) { return 3 }
            return nil
        }
        let scored: [(app: App, score: Int)] = list.compactMap { app in score(app).map { (app: app, score: $0) } }
        return scored.sorted { $0.score != $1.score ? $0.score < $1.score : ($0.app.name ?? $0.app.id).count < ($1.app.name ?? $1.app.id).count }
    }

    /// Lower-cased, without spaces and punctuation: "WeChat" and "We Chat", "淘宝-万能的淘宝！" and "淘宝万能的淘宝".
    static func normalized(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// The answer to find_app: the installed apps by `name`, or for `purpose` the App Store's apps
    /// marked installed or not, with the store's link for the ones that are not.
    func find(name: String?, purpose: String?) async -> (text: String, isError: Bool) {
        let inventory = await list()
        let source = describe(inventory)
        if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            if let inventory {
                let hits = Self.ranked(name, in: inventory.apps)
                if let best = hits.first?.score {
                    // Every app that goes by the name, whether KnownApps or the phone says so: the
                    // system's Notes and another app called Notes are two.
                    let named = hits.filter { $0.score <= 1 }
                    let lines = hits.prefix(5).map { Self.line(Match(id: $0.app.id, name: $0.app.name ?? $0.app.bundleName ?? $0.app.id, installed: true)) }
                    // A name two apps share points at neither: launching one would be a guess.
                    if named.count > 1 {
                        return ("more than one installed app is named \"\(name)\" (from \(source)). Do not pick one: ask the owner which they mean, naming each.\n" + lines.joined(separator: "\n"), false)
                    }
                    if best <= 1 {
                        return ("the installed app named \"\(name)\" is the first below (from \(source)); launch it. The others only hold the name.\n" + lines.joined(separator: "\n"), false)
                    }
                    return ("no installed app is named exactly \"\(name)\"; these hold the name (from \(source)). Launch one only when it is clearly the app the owner means; when more than one could be, ask the owner which.\n" + lines.joined(separator: "\n"), false)
                }
            }
            if inventory?.fresh != true, let known = KnownApps.find(name),
               let id = known.ids.first(where: { hasIcon($0) == true }) {
                return ("the installed app named \"\(name)\" is below (from its icon on this iPhone; \(source)); launch it.\n" + Self.line(Match(id: id, name: known.name(in: .current), installed: true)), false)
            }
            // The App Store's names, kept to the ones on this phone: its own list may name an app in
            // another language than the owner did.
            let store = await search(name)
            // Every result is checked before any is dropped: the installed one may be the store's fourth.
            let all = (store ?? []).map { Match(id: $0.id, name: $0.name, installed: installed($0.id, in: inventory), url: $0.url) }
            let present = Array(all.filter { $0.installed == true }.prefix(3))
            let marked = Array(all.prefix(3))
            if !present.isEmpty {
                return ("installed apps the App Store calls \"\(name)\" (installed checked with \(source)). Launch one only when it is clearly the app the owner means; when more than one could be, ask the owner which.\n" + present.map(Self.line).joined(separator: "\n"), false)
            }
            // Missing only on a fresh list: an old list, the icons and the store can only say yes.
            guard inventory?.fresh == true else { return (Self.answer(unknown: name, offers: marked, storeFailed: store == nil, source: source), false) }
            return (Self.answer(missing: name, offers: marked, storeFailed: store == nil, source: source), false)
        }
        if let purpose = purpose?.trimmingCharacters(in: .whitespacesAndNewlines), !purpose.isEmpty {
            guard let store = await search(purpose) else {
                return ("could not search the App Store for \"\(purpose)\" (no answer): try again later, or do the task with installed apps or the built-in browser.", false)
            }
            guard !store.isEmpty else { return ("the App Store found no app for \"\(purpose)\".", false) }
            let marked = store.prefix(5).map { Match(id: $0.id, name: $0.name, installed: installed($0.id, in: inventory), url: $0.url) }
            let sorted = marked.filter { $0.installed == true } + marked.filter { $0.installed != true }
            return ("App Store apps for \"\(purpose)\", installed ones first (installed checked with \(source)):\n" + sorted.map(Self.line).joined(separator: "\n"), false)
        }
        return ("find_app takes name (an app's name) or purpose (what the app is for).", true)
    }

    private func describe(_ inventory: Inventory?) -> String {
        guard let inventory else { return "the app icons on this iPhone (its app list could not be read: \(lastProblem ?? "no answer"))" }
        if inventory.fresh { return "this iPhone's app list (\(inventory.apps.count) apps)" }
        let minutes = max(1, Int(now().timeIntervalSince(inventory.readAt) / 60))
        return "this iPhone's app list from \(minutes) min ago (\(inventory.apps.count) apps; reading it again failed: \(lastProblem ?? "no answer"))"
    }

    /// Nothing current could say whether the app is there.
    private static func answer(unknown name: String, offers: [Match], storeFailed: Bool, source: String) -> String {
        var text = "could not tell whether \"\(name)\" is installed: no current app list holds it and the icons could not settle it (checked \(source)). Do not tell the owner it is missing: go home ({button: \"home\"}), swipe down on the Home Screen to search, type its name and tap it."
        if storeFailed { text += " The App Store could not be searched either." }
        if !offers.isEmpty { text += " The App Store's matches, for their ids:\n" + offers.map(line).joined(separator: "\n") }
        return text
    }

    private static func answer(missing name: String, offers: [Match], storeFailed: Bool, source: String) -> String {
        var text = "no app named \"\(name)\" is installed (checked \(source))."
        if storeFailed { return text + " The App Store could not be searched for a link; try the Home Screen search before telling the owner." }
        if offers.isEmpty { return text + " The App Store found none either; try the Home Screen search before telling the owner." }
        text += " The App Store's matches, NOT installed (launch cannot open them; tell the owner and give the link when the task needs the app):\n"
        return text + offers.map(line).joined(separator: "\n")
    }

    private static func line(_ m: Match) -> String {
        let state = m.installed == true ? "installed" : m.installed == false ? "not installed" : "installed: unknown"
        return "- \(m.name): \(m.id) (\(state))" + (m.installed == true ? "" : m.url.map { " \($0)" } ?? "")
    }
}

/// The App Store's public search (iTunes Search API) in the store of the phone's region: names to
/// bundle ids and store links. A Chinese name is looked up in the China store too.
enum AppStoreSearch {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 6
        return URLSession(configuration: configuration)
    }()

    /// The apps for `term`; nil when no store could be reached or read, so a failure never reads as
    /// "the App Store has none".
    static func apps(_ term: String, limit: Int = 5) async -> [InstalledApps.StoreApp]? {
        let region = (Locale.current.region?.identifier ?? "US").lowercased()
        let han = term.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        var stores = [region]
        for extra in han ? ["cn"] : ["us"] where !stores.contains(extra) { stores.append(extra) }
        var answered = false
        for store in stores {
            var url = URLComponents(string: "https://itunes.apple.com/search")!
            url.queryItems = [URLQueryItem(name: "term", value: term), URLQueryItem(name: "country", value: store),
                              URLQueryItem(name: "entity", value: "software"), URLQueryItem(name: "limit", value: String(limit))]
            guard let address = url.url, let (data, response) = try? await session.data(from: address),
                  (response as? HTTPURLResponse)?.statusCode == 200, let found = parse(data) else { continue }
            answered = true
            if !found.isEmpty { return found }
        }
        return answered ? [] : nil
    }

    /// The search's results. Its descriptions carry raw control characters, which JSONSerialization
    /// refuses, so they become spaces first.
    /// nil when the answer is not the search's JSON.
    static func parse(_ data: Data) -> [InstalledApps.StoreApp]? {
        let text = String(decoding: data, as: UTF8.self).unicodeScalars.map { $0.value < 0x20 ? " " : String($0) }.joined()
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let results = object["results"] as? [[String: Any]] else { return nil }
        return results.compactMap { r in
            guard let id = r["bundleId"] as? String, !id.isEmpty else { return nil }
            let link = (r["trackViewUrl"] as? String).map { $0.components(separatedBy: "?").first ?? $0 }
            return InstalledApps.StoreApp(id: id, name: (r["trackName"] as? String) ?? id, url: link)
        }
    }
}
