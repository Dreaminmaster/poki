import ObjectiveC
import OSLog
import SwiftUI
import UIKit

// The real icon of an app, by its bundle ID or the name Poki saw on screen ("Notes", "备忘录", "WeChat"),
// for anything that names an app: the conversations list, the home page's shortcuts. One file with no
// other dependency than the asset catalog, so any screen can use it.
//
// Where an icon comes from, in this order:
// 1. The icon installed on this iPhone, through UIKit's private
//    `+[UIImage _applicationIconImageForBundleIdentifier:format:scale:]`. Poki is not distributed through
//    the App Store, so it may call it. It is looked up at run time and called only when it exists, so an
//    iOS that drops it only loses this source. For an app that is not installed (or that the sandbox
//    hides) iOS draws its generic icon; that picture is recognised and skipped, and so is an empty
//    picture. An app with several editions is looked up by each edition's bundle ID (KnownApps).
//    `-pokiSystemIcons off` turns this source off, to compare. When it has nothing for an app Poki
//    carries an icon for, the log says so (category "icons"), and the carried icon shows: on 0.3.1
//    (863) Taobao was installed and still showed the placeholder.
// 2. The App Store artwork Poki carries for common apps (Poki/AppIcons, see AppIcons.md).
// 3. An icon fetched earlier from the App Store and kept in Caches/AppIcons.
// 4. The App Store's public lookup by bundle ID (itunes.apple.com/lookup), on a view's `.task`. The
//    request carries the bundle ID and the store's country only. A miss the store answered is remembered
//    for a day; a lookup that could not reach the store is asked again.
// Without any of these the view draws Poki's carried bear icon.

/// Icons of apps, found once and kept for the app's run.
@MainActor @Observable
final class AppIconStore {
    static let shared = AppIconStore()

    /// Bumped when a fetched icon arrives or the installed apps change, so views that asked before
    /// draw again. `changed` is posted with it, for what is not a SwiftUI view (the message field's
    /// capsules are pictures).
    private(set) var arrivals = 0
    static let changed = Notification.Name("nz.zheha.poki.appIconsChanged")
    /// The installed apps (DynamicApps.version) the kept answers were found with.
    @ObservationIgnored private var directory = DynamicApps.version
    @ObservationIgnored private var memory: [String: UIImage] = [:]
    @ObservationIgnored private var unknown: Set<String> = []
    @ObservationIgnored private var fetching: Set<String> = []
    /// The installed icon of a bundle ID in the light or dark look; the iPhone's own unless a test says.
    @ObservationIgnored private let installedIcon: (String, Bool) -> UIImage?
    private static let log = Logger(subsystem: "nz.zheha.poki", category: "icons")

    init(installed: ((String, Bool) -> UIImage?)? = nil) {
        installedIcon = installed ?? { SystemIcons.icon($0, dark: $1) }
    }

    /// The icon of `app` (a bundle ID, or an app's name in English or Chinese) from this iPhone, the
    /// app's own bundle or the disk cache; nil when only the App Store could have it, or nothing can.
    /// `dark`: the iPhone's own icons come in its dark style in dark mode, so each look is kept apart.
    func icon(_ app: String, dark: Bool = false) -> UIImage? {
        _ = arrivals
        followDirectory()
        guard let key = Self.key(app) else { return nil }
        let look = key + (dark ? "|dark" : "|light")
        if let hit = memory[look] ?? memory[key] { return hit }
        if unknown.contains(key) { return nil }
        let id = Self.bundleID(app)
        let ids = id.map { KnownApps.byID[$0.lowercased()]?.ids ?? [$0] } ?? []
        if let installed = ids.lazy.compactMap({ self.installedIcon($0, dark) }).first(where: Self.isVisible) {
            memory[look] = installed
            return installed
        }
        let carried = Self.bundled(id)
        if let carried, let id { Self.log.info("No installed icon for \(id, privacy: .public); showing the carried one") }
        let found = carried ?? id.flatMap(DiskCache.read)
        if let found { memory[key] = found } else if id == nil { unknown.insert(key) }
        return found
    }

    /// Fetches the App Store's icon for `app` when nothing nearer has one, and keeps it. Returns when it
    /// has arrived or failed.
    func load(_ app: String) async {
        followDirectory()
        guard let key = Self.key(app), memory[key] == nil, !unknown.contains(key), let id = Self.bundleID(app),
              !fetching.contains(id), !DiskCache.missedRecently(id) else { return }
        fetching.insert(id)
        defer { fetching.remove(id) }
        switch await AppStoreLookup.icon(id) {
        case .found(let image):
            DiskCache.write(image, id)
            memory[key] = image
            announce()
        case .absent:
            DiskCache.missed(id)
        case .unreachable:
            // Offline or a store that did not answer: nothing is remembered, so the next view asks again.
            break
        }
    }

    // MARK: Names

    private static func key(_ app: String) -> String? {
        let key = app.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return key.isEmpty ? nil : key
    }

    /// The bundle ID for an app's name, or `app` itself when it already is one. Past KnownApps, any app
    /// installed on this iPhone is found by its Home Screen name (DynamicApps, from the phone's list).
    static func bundleID(_ app: String) -> String? {
        let name = app.trimmingCharacters(in: .whitespacesAndNewlines)
        if let known = KnownApps.find(name) { return known.id }
        if DynamicApps.name(forID: name) != nil { return name }
        // An installed app's name comes before the shape of an id: an app called "A.B.C" is that app.
        if let installed = DynamicApps.id(forName: name) { return installed }
        return looksLikeBundleID(name) ? name : nil
    }

    /// "com.tencent.xin": reverse-DNS, three parts or more, each of ASCII letters, digits or hyphens
    /// and at least one longer than a letter, so initials with dots ("A.B.C", "U.S.A") are not ids.
    static func looksLikeBundleID(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count >= 3 && text.count <= 155 && parts.contains { $0.count > 1 }
            && parts.allSatisfy { !$0.isEmpty && $0.unicodeScalars.allSatisfy { ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || $0 == "-" } }
    }

    /// The name an app goes by on this iPhone, in its first language (English, Simplified or
    /// Traditional Chinese), from a bundle ID or any of its names; for an app not listed here, its
    /// Home Screen name when it is installed.
    static func name(_ app: String) -> String? {
        KnownApps.find(app)?.name(in: .current) ?? DynamicApps.name(forID: app)
    }

    /// The phone's app list was read (InstalledApps): when it changed, names that found no app may find
    /// one now and a name that changed hands must not keep its old icon, so what was kept is dropped
    /// and the views draw again.
    func directoryChanged() {
        guard followDirectory() else { return }
        announce()
    }

    /// Drops the kept icons and misses when the installed apps are no longer the ones they were found
    /// with. Every read does this first, so a stale answer is never given even before the views are told.
    @discardableResult
    private func followDirectory() -> Bool {
        let version = DynamicApps.version
        guard version != directory else { return false }
        directory = version
        memory.removeAll()
        unknown.removeAll()
        return true
    }

    private func announce() {
        arrivals += 1
        NotificationCenter.default.post(name: Self.changed, object: self)
    }

    /// true when iOS has a Home Screen icon for `id`, so the app is installed; InstalledApps' check
    /// without a current app list. Never false: with the iPhone's icons off (`-pokiSystemIcons off`)
    /// there is nothing to read, and iOS draws its generic icon for some installed apps too (build 863
    /// showed it for Taobao), so a missing icon proves nothing.
    static func installedOnPhone(_ id: String) -> Bool? {
        guard SystemIcons.enabled, SystemIcons.icon(id, dark: false) != nil else { return nil }
        return true
    }

    /// The bundle IDs of the apps `text` names, in any of their names: "打开美团外卖点下酒菜" names Meituan
    /// Waimai and not Meituan, as the longest name wins where one starts another. A Latin name counts
    /// only as a whole word, and one-letter names ("X") never. A name of digits ("12306") counts next to
    /// Chinese text ("打开12306查询") but not inside a longer run of Latin letters or digits.
    static func bundleIDs(namedIn text: String) -> [String] {
        let text = Array(text.lowercased())
        var found: [String] = []
        var i = 0
        while i < text.count {
            let hit = namesLongestFirst.first { name in
                let chars = Array(name)
                guard i + chars.count <= text.count, Array(text[i..<i + chars.count]) == chars else { return false }
                if name == "网易云" || name == "網易雲" {
                    guard let appID = KnownApps.byName[name],
                          KnownApps.allowsNameMatch(name, appID: appID, followedBy: text[(i + chars.count)...]) else { return false }
                }
                if AppCapsule.everydayChinese.contains(name) {
                    return CapsuleText.appGoes(after: String(text[..<i]))
                }
                if name == "phone" {
                    let before = text[..<i].reversed().drop(while: \.isWhitespace).prefix(while: \.isLetter)
                    let after = text[(i + chars.count)...].drop(while: \.isWhitespace).prefix(while: \.isLetter)
                    if ["this", "that", "my", "your", "our", "the"].contains(String(before.reversed())),
                       !after.elementsEqual("app") { return false }
                }
                guard chars.allSatisfy(\.isASCII) else { return true }
                // A Latin name stops at any letter; a number only at a Latin letter or a digit, as Chinese
                // characters are letters too and sit right against it.
                let numeric = chars.allSatisfy(\.isNumber)
                let joins: (Character) -> Bool = numeric ? { $0.isASCII && ($0.isLetter || $0.isNumber) } : { $0.isLetter }
                return (i == 0 || !joins(text[i - 1])) && (i + chars.count == text.count || !joins(text[i + chars.count]))
            }
            guard let hit, let id = KnownApps.byName[hit] else { i += 1; continue }
            if !found.contains(id) { found.append(id) }
            i += hit.count
            if id == CapsuleText.weChatID,
               let miniProgram = CapsuleText.weChatMiniProgramPrefix(in: String(text[i...].prefix(48))) {
                i += miniProgram.count
            }
        }
        return found
    }

    private static let namesLongestFirst: [String] = KnownApps.byName.keys.filter { $0.count >= 2 }.sorted { $0.count > $1.count }

    /// A picture with something in it: not empty, not fully transparent.
    private static func isVisible(_ image: UIImage) -> Bool {
        guard let cg = image.cgImage, cg.width > 0, cg.height > 0 else { return false }
        var pixels = [UInt8](repeating: 0, count: 8 * 8 * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: 8, height: 8))
            return true
        }
        return drawn && stride(from: 3, to: pixels.count, by: 4).contains { pixels[$0] > 8 }
    }

    /// The PNG itself, which the build copies into the app as it is. Not the asset catalog's copy: the
    /// catalog is generated (scripts/make-assets.sh), and a build from a catalog made before an icon was
    /// added shipped without it (Taobao on 0.3.1 (865)).
    private static func bundled(_ id: String?) -> UIImage? {
        id.flatMap { KnownApps.byID[$0.lowercased()]?.icon }.flatMap(carried)
    }

    /// One of the PNGs in Poki/AppIcons by its file name, at the Home Screen's 3x.
    static func carried(_ file: String) -> UIImage? {
        guard let path = Bundle.main.path(forResource: file, ofType: "png"), let image = UIImage(contentsOfFile: path)?.cgImage else { return nil }
        return UIImage(cgImage: image, scale: 3, orientation: .up)
    }
}

/// An app's icon in the Home Screen's shape at `size` points, or Poki's default icon.
struct AppIconView: View {
    var app: String
    var size: CGFloat
    /// The icon in its light look whatever the page's: the home page's pills (the owner: their icons
    /// should not change with dark mode).
    var alwaysLight = false
    /// A bundled PNG keeps the icon available even when its app is not installed.
    var carried: String?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
        let image = PerfSwitch.on(.iconsPlaceholder) ? nil
            : carried.flatMap(AppIconStore.carried) ?? AppIconStore.shared.icon(app, dark: !alwaysLight && scheme == .dark)
        Group {
            if let image {
                Image(uiImage: image).resizable().interpolation(.high).scaledToFill()
            } else {
                DefaultAppIcon(size: size)
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        // The edge of a white icon (Photos, Notes) on a light page.
        .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        .task(id: app) { if image == nil, !PerfSwitch.on(.iconsPlaceholder) { await AppIconStore.shared.load(app) } }
        .accessibilityHidden(true)
    }
}

/// This iPhone's own icons, through UIKit's private class method (see the top of the file).
@MainActor
private enum SystemIcons {
    static let enabled = UserDefaults.standard.string(forKey: "pokiSystemIcons") != "off"
    private static let selector = NSSelectorFromString("_applicationIconImageForBundleIdentifier:format:scale:")
    private typealias Call = @convention(c) (AnyClass, Selector, NSString, Int32, CGFloat) -> Unmanaged<UIImage>?

    private static let call: Call? = {
        guard let method = class_getClassMethod(UIImage.self, selector) else { return nil }
        return unsafeBitCast(method_getImplementation(method), to: Call.self)
    }()

    /// The generic icon iOS draws for an app it does not know, in each look: what a made-up bundle ID gets.
    private static let generic: [Bool: Data] = Dictionary(uniqueKeysWithValues: [false, true].compactMap { dark in
        raw("nz.zheha.poki.no-such-app", dark: dark)?.pngData().map { (dark, $0) }
    })

    /// The installed icon in the light or the dark look, whichever the page itself is in.
    static func icon(_ id: String, dark: Bool) -> UIImage? {
        guard enabled, let image = raw(id, dark: dark), let data = image.pngData() else { return nil }
        return data == generic[dark] ? nil : image
    }

    /// Format 2 is the Home Screen's 60-point icon. iOS draws it in the look of the current trait
    /// collection, so the call runs under the look asked for, not the app's.
    private static func raw(_ id: String, dark: Bool) -> UIImage? {
        var image: UIImage?
        UITraitCollection(userInterfaceStyle: dark ? .dark : .light).performAsCurrent {
            image = call?(UIImage.self, selector, id as NSString, 2, 3)?.takeUnretainedValue()
        }
        return image
    }
}

/// Icons fetched from the App Store, in Caches/AppIcons, and the misses of the last day.
private enum DiskCache {
    private static let folder: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let folder = base.appendingPathComponent("AppIcons", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }()

    private static func file(_ id: String, _ ext: String) -> URL {
        folder.appendingPathComponent(id.replacingOccurrences(of: "/", with: "_") + "." + ext)
    }

    static func read(_ id: String) -> UIImage? { UIImage(contentsOfFile: file(id, "png").path) }

    static func write(_ image: UIImage, _ id: String) {
        try? image.pngData()?.write(to: file(id, "png"), options: .atomic)
        try? FileManager.default.removeItem(at: file(id, "none"))
    }

    static func missed(_ id: String) { FileManager.default.createFile(atPath: file(id, "none").path, contents: Data()) }

    static func missedRecently(_ id: String) -> Bool {
        let date = (try? FileManager.default.attributesOfItem(atPath: file(id, "none").path))?[.modificationDate] as? Date
        return date.map { Date().timeIntervalSince($0) < 86_400 } ?? false
    }
}

/// The App Store's public lookup (iTunes Search API) by bundle ID, in the store of the phone's region.
private enum AppStoreLookup {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 6
        return URLSession(configuration: configuration)
    }()

    enum Answer {
        case found(UIImage)
        /// A store answered and has no app with this id.
        case absent
        /// No store could be reached or its picture did not arrive: worth asking again.
        case unreachable
    }

    static func icon(_ id: String) async -> Answer {
        let country = (Locale.current.region?.identifier ?? "US").lowercased()
        var unreachable = false
        for store in country == "us" ? ["us"] : [country, "us"] {
            var lookup = URLComponents(string: "https://itunes.apple.com/lookup")!
            lookup.queryItems = [URLQueryItem(name: "bundleId", value: id), URLQueryItem(name: "country", value: store)]
            guard let url = lookup.url, let (data, response) = try? await session.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200, let text = String(data: data, encoding: .utf8),
                  text.contains("\"resultCount\"") else { unreachable = true; continue }
            // Read the one field by pattern: the answer's descriptions carry raw control characters,
            // which a strict JSON parser refuses.
            guard let match = text.firstMatch(of: #/"artworkUrl100"\s*:\s*"([^"]+)"/#) else { continue }
            let art = String(match.1)
            // The artwork's address names its size; 180 pixels is the Home Screen's 60 points at 3x.
            guard let big = URL(string: art.replacingOccurrences(of: "100x100bb", with: "180x180bb")),
                  let (image, _) = try? await session.data(from: big), let icon = UIImage(data: image) else { unreachable = true; continue }
            return .found(icon)
        }
        return unreachable ? .unreachable : .absent
    }
}
