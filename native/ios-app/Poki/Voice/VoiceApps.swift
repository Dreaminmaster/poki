import Foundation

/// open_app, the live voice's way into an app: the name the user said, matched as Poki's chat matches
/// app names (`KnownApps`), launched by its bundle id through PokiCore's do. The model never has to
/// know a bundle id, so it no longer searches the Home Screen for an app Poki can name.
@MainActor
enum VoiceApps {
    private enum Match {
        /// The app's bundle ids, its own first, then its other editions'.
        case app([String])
        /// The words name several apps ("微信和支付宝").
        case several([String])
        case unknown
    }

    private static func match(_ name: String) -> Match {
        if let app = KnownApps.find(name) { return .app(app.ids) }
        let named = AppIconStore.bundleIDs(namedIn: name)
        if named.count == 1 { return .app(KnownApps.find(named[0])?.ids ?? named) }
        if named.count > 1 { return .several(named) }
        if let id = AppIconStore.bundleID(name) { return .app([id]) }
        return .unknown
    }

    /// Settings pages open_app goes straight to, and their routes in Settings' own links (the Mac's
    /// open_settings uses the same routes, `src/platform.mjs`).
    nonisolated static let settingsPages: [String: String] = [
        "wifi": "WIFI", "bluetooth": "Bluetooth", "cellular": "MOBILE_DATA_SETTINGS_ID", "personal_hotspot": "INTERNET_TETHERING", "vpn": "VPN",
        "notifications": "NOTIFICATIONS_ID", "sounds": "Sounds", "focus": "DO_NOT_DISTURB", "screen_time": "SCREEN_TIME", "general": "General",
        "about": "General&path=About", "software_update": "General&path=SOFTWARE_UPDATE_LINK", "keyboard": "General&path=Keyboard",
        "language_region": "General&path=INTERNATIONAL", "date_time": "General&path=DATE_AND_TIME",
        "display": "DISPLAY", "accessibility": "ACCESSIBILITY", "wallpaper": "Wallpaper", "siri": "SIRI", "control_center": "ControlCenter",
        "camera": "CAMERA", "battery": "BATTERY_USAGE", "safari": "SAFARI", "privacy": "Privacy", "location": "Privacy&path=LOCATION",
    ]

    private static let settingsID = "com.apple.Preferences"

    /// Runs open_app. `tool` is PokiCore's look and do; `openLink` opens a Settings link from Poki and
    /// says whether iOS took it (only while Poki is in front).
    static func open(_ arguments: String, tool: (String, String) async -> PhoneAnswer, openLink: (URL) async -> Bool) async -> PhoneAnswer {
        let args = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any] ?? [:]
        let name = (args["app"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let ids: [String]
        switch match(name) {
        case .app(let found): ids = found
        case .several(let found):
            return ("not_sent: “\(name)” could be any of \(found.joined(separator: ", ")). Ask the user which app, or call open_app with its full name.", true, nil)
        case .unknown:
            return ("not_sent: Poki does not know an app called “\(name)”. Search the Home Screen for it: go home ({button: \"home\"}), swipe down, type its name and tap it.", true, nil)
        }
        var note = ""
        if let page = args["page"] as? String, let route = settingsPages[page] {
            if ids.first == settingsID, let link = URL(string: "App-prefs:\(route)"), await openLink(link) {
                // Settings slides the page in; read it once it holds still.
                let read = await tool("do", #"{"actions":[{"wait_until":{"settled":true,"ms":2500}}]}"#)
                // The link can land on Settings' first page when iOS no longer knows the route.
                return ("opened Settings by the link to its \(page) page. If the screen is not that page, tap it in Settings.\n" + read.text, read.failed, read.screen)
            }
            note = ids.first == settingsID
                ? "The \(page) page could not be opened by its link (Poki opens links only while it is in front); Settings is open: tap the page, using scroll_to when it is not listed.\n"
                : "page is for Settings only; \(name) is open.\n"
        }
        var answer: PhoneAnswer = ("", true, nil)
        for id in ids {
            answer = await tool("do", #"{"actions":[{"launch":{"bundle":"\#(id)"}}]}"#)
            guard answer.failed, answer.text.contains(notInstalled) else { break }
        }
        if answer.failed, answer.text.contains(notInstalled) {
            return ("not_sent: \(name) (\(ids.joined(separator: ", "))) is not installed on this iPhone. Search the Home Screen for it before telling the user: go home ({button: \"home\"}), swipe down, type its name and tap it.", true, nil)
        }
        return (note + answer.text, answer.failed, answer.screen)
    }

    /// PokiCore's words for a launch of a bundle id this iPhone does not have.
    private static let notInstalled = "no app with that bundle id is installed"
}
