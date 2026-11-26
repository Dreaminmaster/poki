import SwiftUI

// What an app is called on the pages of Screen History, and whether a bundle id is an app at all.
//
// A name comes from the apps Poki knows, then from iOS for an installed app, then from the App
// Store, kept once fetched. Only when all three have nothing is a name made from the bundle id, so
// a row never shows "com.agilebits.onepassword-ios" (the owner, 2026-11-18).

enum HistoryAppNames {
    private static let key = "history.appNames"
    private static let missedKey = "history.appNamesMissed"

    /// Names the App Store gave, by lowercased bundle id.
    private static var fetched: [String: String] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
    }

    static func name(_ id: String) -> String {
        if let known = KnownApps.find(id)?.name(in: .current) { return known }
        if let installed = installed(id) { return installed }
        if let kept = fetched[id.lowercased()] { return kept }
        return made(id)
    }

    /// Whether a real name is at hand, not one made from the bundle id.
    static func isNamed(_ id: String) -> Bool {
        KnownApps.find(id) != nil || installed(id) != nil || fetched[id.lowercased()] != nil
    }

    /// The name iOS shows under an installed app's icon.
    static func installed(_ id: String) -> String? {
        guard let proxyClass = NSClassFromString("LSApplicationProxy") as? NSObject.Type else { return nil }
        let factory = NSSelectorFromString("applicationProxyForIdentifier:")
        let nameSelector = NSSelectorFromString("localizedName")
        guard proxyClass.responds(to: factory),
              let proxy = proxyClass.perform(factory, with: id)?.takeUnretainedValue() as? NSObject,
              proxy.responds(to: nameSelector),
              let raw = proxy.perform(nameSelector)?.takeUnretainedValue() as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.caseInsensitiveCompare(id) != .orderedSame else { return nil }
        return trimmed
    }

    /// "com.agilebits.onepassword-ios" as "Onepassword": the last part that says something.
    static func made(_ id: String) -> String {
        let generic: Set<String> = ["ios", "iphone", "ipad", "mobile", "app", "client"]
        let segments = id.split(separator: ".").map(String.init)
        guard segments.count >= 2 else { return id }
        let chosen = segments.dropFirst().reversed().first(where: { !generic.contains($0.lowercased()) }) ?? segments.last ?? id
        let words = chosen.split(whereSeparator: { $0 == "-" || $0 == "_" }).map(String.init).filter { !generic.contains($0.lowercased()) }
        let spaced = words.isEmpty ? chosen : words.joined(separator: " ")
        guard let first = spaced.first else { return id }
        return first.uppercased() + spaced.dropFirst()
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 6
        return URLSession(configuration: configuration)
    }()

    /// Asks the App Store for the name of an app nothing on this iPhone names, once a day at most.
    /// The one bundle id is all that is sent, as for an icon the phone lacks (AppIconStore).
    /// Returns whether a name arrived.
    @discardableResult
    static func load(_ id: String) async -> Bool {
        let low = id.lowercased()
        guard !isNamed(id), !low.hasPrefix("com.apple."), id.split(separator: ".").count >= 2 else { return false }
        var missed = UserDefaults.standard.dictionary(forKey: missedKey) as? [String: Double] ?? [:]
        if let at = missed[low], Date().timeIntervalSince1970 - at < 86_400 { return false }
        let country = (Locale.current.region?.identifier ?? "US").lowercased()
        for store in country == "us" ? ["us"] : [country, "us"] {
            var lookup = URLComponents(string: "https://itunes.apple.com/lookup")!
            lookup.queryItems = [URLQueryItem(name: "bundleId", value: id), URLQueryItem(name: "country", value: store)]
            // Read the one field by pattern: the answer's descriptions carry raw control characters.
            guard let url = lookup.url, let (data, _) = try? await session.data(from: url),
                  let text = String(data: data, encoding: .utf8),
                  let match = text.firstMatch(of: #/"trackName"\s*:\s*"((?:[^"\\]|\\.)+)"/#) else { continue }
            // "1Password: Password Manager" and "Notion - Notes, Docs" are the name and a slogan.
            var name = String(match.1).replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\/", with: "/")
            for cut in [": ", "：", " - ", " – ", " — ", " | "] {
                if let range = name.range(of: cut) { name = String(name[..<range.lowerBound]) }
            }
            name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            var kept = fetched
            kept[low] = name
            UserDefaults.standard.set(kept, forKey: key)
            return true
        }
        missed[low] = Date().timeIntervalSince1970
        UserDefaults.standard.set(missed, forKey: missedKey)
        return false
    }

    /// Apple's processes that put something on screen and are no app: the sheet that asks for a
    /// passcode (UserAuthentication), a widget's renderer, a view service. An app of Apple's has an
    /// icon on the Home Screen or is one Poki knows. Anything else under com.apple is a process.
    @MainActor
    static func isProcess(_ id: String) -> Bool {
        if HistoryCapture.isNoise(id) { return true }
        let low = id.lowercased()
        guard low.hasPrefix("com.apple."), KnownApps.byID[low] == nil else { return false }
        if let known = verdicts[low] { return known }
        // An app iOS names under an icon is an app, whether or not its icon is at hand.
        if installed(id) != nil { verdicts[low] = false; return false }
        // Without iOS's own icons there is nothing to tell an app by, so nothing more is left out.
        guard UserDefaults.standard.string(forKey: "pokiSystemIcons") != "off", AppIconStore.shared.icon("com.apple.Preferences") != nil else { return false }
        let process = AppIconStore.shared.icon(id) == nil
        verdicts[low] = process
        return process
    }

    @MainActor private static var verdicts: [String: Bool] = [:]
}

/// An app's name on a row, replaced by the App Store's when nothing on the iPhone had one.
struct HistoryAppName: View {
    var app: String
    @State private var arrived = 0

    var body: some View {
        Text(verbatim: HistoryAppNames.name(app))
            .id(arrived)
            .task(id: app) { if await HistoryAppNames.load(app) { arrived += 1 } }
    }
}
