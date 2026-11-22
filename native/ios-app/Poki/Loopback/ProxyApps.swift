import Foundation
import UIKit

/// The proxy apps that can provide the 10.7.0.1 loopback, so users
/// keep their own VPN. Detected with canOpenURL (their schemes are listed in LSApplicationQueriesSchemes).
/// The module files live in deploy/proxy-modules/.
struct ProxyApp: Identifiable, Hashable {
    enum Install: Hashable { case url(URL), toggle(String), snippet(String), appStore(URL) }
    let id: String
    let name: String
    let scheme: String
    let minimumVersion: String
    let install: Install
    let steps: [String]
    /// The setup comes from the app's own documentation (true), or from what users and other
    /// loopback tools report (false): the page says so, and the live check above the list is the proof.
    var documented = true

    var isInstalled: Bool {
        guard !scheme.isEmpty, let url = URL(string: "\(scheme)://") else { return false }
        return UIApplication.shared.canOpenURL(url)
    }
}

enum ProxyApps {
    /// Where the module files are served from: raw GitHub of the repository's main branch, which keeps
    /// these paths.
    static let modulesBase = URL(string: "https://raw.githubusercontent.com/JosssphZhou/poki/main/deploy/proxy-modules/")!

    static func encoded(_ url: URL) -> String {
        url.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? url.absoluteString
    }

    // Each app's steps are what a child could follow (the owner, Nov 21 2026): one thing per line,
    // the button under them named the way the first line names it, and "come back here" at the end.
    static let all: [ProxyApp] = [
        ProxyApp(id: "karing", name: "Karing", scheme: "karing", minimumVersion: "1.2.4.862",
                 install: .toggle("TUN > Loopback address > 10.7.0.1"),
                 steps: ["Tap Open Karing below.", "In Karing, go to Settings, then TUN.", "Set Loopback Address to 10.7.0.1.", "Turn Karing off and on again, then come back here."]),
        ProxyApp(id: "surge", name: "Surge", scheme: "surge", minimumVersion: "5.23.0",
                 install: .url(URL(string: "surge:///install-module?url=\(encoded(modulesBase.appendingPathComponent("poki-loopback.sgmodule")))")!),
                 steps: ["Tap Install Module below, then tap OK in Surge.", "In Surge, turn on the Poki Device Loopback module.", "Turn on Enhanced Mode, then come back here."]),
        ProxyApp(id: "loon", name: "Loon", scheme: "loon", minimumVersion: "3.5.3",
                 install: .url(URL(string: "loon://import?plugin=\(encoded(modulesBase.appendingPathComponent("poki-loopback.lpx")))")!),
                 steps: ["Tap Install Plugin below, then tap OK in Loon.", "Make sure the plugin is on and Loon is connected.", "Come back here."]),
        ProxyApp(id: "shadowrocket", name: "Shadowrocket", scheme: "shadowrocket", minimumVersion: "",
                 install: .toggle("Settings > Other > Include route 10.7.0.1/32"),
                 steps: ["Tap Open Shadowrocket below.", "Go to Settings, then Other.", "Turn on Include route 10.7.0.1/32. Update Shadowrocket if you do not see it.", "Make sure Shadowrocket is connected, then come back here."],
                 documented: false),
        ProxyApp(id: "stash", name: "Stash", scheme: "stash", minimumVersion: "",
                 install: .snippet("tun:\n  loopback-address:\n    - 10.7.0.1"),
                 steps: ["Tap Copy below.", "In Stash, go to Settings, then Overrides, and add a new override with what you copied.", "Turn the override on and reconnect Stash, then come back here."],
                 documented: false),
        ProxyApp(id: "quantumult-x", name: "Quantumult X", scheme: "quantumult-x", minimumVersion: "",
                 install: .snippet("reflected_routes = 10.7.0.1/32"),
                 steps: ["Tap Copy below.", "In Quantumult X, edit your profile, paste the line under [general] and save.", "Reconnect Quantumult X, then come back here."],
                 documented: false),
        ProxyApp(id: "clashmi", name: "Clash Mi", scheme: "clashmi", minimumVersion: "",
                 install: .snippet("tun:\n  loopback-address:\n    - 10.7.0.1"),
                 steps: ["Tap Copy below.", "In Clash Mi, paste the lines into the tun part of your profile and import it.", "Connect Clash Mi, then come back here."],
                 documented: false),
        ProxyApp(id: "sing-box", name: "sing-box", scheme: "sing-box", minimumVersion: "1.12.0",
                 install: .snippet("\"loopback_address\": [\"10.7.0.1\"]"),
                 steps: ["Tap Copy below.", "In sing-box, paste the line into the tun inbound of your profile and reload it.", "Keep IPv6 out of the tun addresses, then come back here."]),
    ]
}

/// What the loopback page offers: every proxy app, and LocalDevVPN for people who have none.
typealias LoopbackChoice = ProxyApp

extension ProxyApp {
    /// The free loopback app, for a person with no proxy app. Poki cannot see whether it is installed.
    static let free = ProxyApp(id: "localdevvpn", name: "LocalDevVPN", scheme: "", minimumVersion: "",
                               install: .appStore(URL(string: "https://apps.apple.com/app/id6755608044")!),
                               steps: ["Tap Get LocalDevVPN below and install it.", "Open LocalDevVPN and tap Connect. It may turn off another VPN app.", "Come back here."])

    /// LocalDevVPN first, then the proxy apps.
    static var all: [ProxyApp] { [free] + ProxyApps.all }

    static func chosen(_ id: String?) -> ProxyApp? { all.first { $0.id == id } }
}
