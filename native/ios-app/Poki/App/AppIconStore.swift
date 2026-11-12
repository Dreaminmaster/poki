import ObjectiveC
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
//    hides) iOS draws its generic icon; that picture is recognised and skipped. `-pokiSystemIcons off`
//    turns this source off, to compare.
// 2. The App Store artwork Poki carries for common apps (Poki/AppIcons, see AppIcons.md).
// 3. An icon fetched earlier from the App Store and kept in Caches/AppIcons.
// 4. The App Store's public lookup by bundle ID (itunes.apple.com/lookup), on a view's `.task`. The
//    request carries the bundle ID and the store's country only. A miss is remembered for a day.
// Without any of these the view draws one placeholder: a grey tile in the icon's shape with an app glyph.

/// The language the iPhone names apps in, from its first preferred language: Simplified or Traditional
/// Chinese, or English for any other. Apps' names (`AppIconStore.name`) and the home page's default
/// quick actions (`HomeIdea`) follow it.
enum AppLanguage {
    case english, simplifiedChinese, traditionalChinese

    static var current: AppLanguage {
        let language = Locale.preferredLanguages.first ?? "en"
        if language.hasPrefix("zh-Hant") || language.hasPrefix("zh-TW") || language.hasPrefix("zh-HK") { return .traditionalChinese }
        return language.hasPrefix("zh") ? .simplifiedChinese : .english
    }
}

/// Icons of apps, found once and kept for the app's run.
@MainActor @Observable
final class AppIconStore {
    static let shared = AppIconStore()

    /// Bumped when a fetched icon arrives, so views that asked before it came draw again.
    private(set) var arrivals = 0
    @ObservationIgnored private var memory: [String: UIImage] = [:]
    @ObservationIgnored private var unknown: Set<String> = []
    @ObservationIgnored private var fetching: Set<String> = []

    /// The icon of `app` (a bundle ID, or an app's name in English or Chinese) from this iPhone, the
    /// app's own bundle or the disk cache; nil when only the App Store could have it, or nothing can.
    /// `dark`: the iPhone's own icons come in its dark style in dark mode, so each look is kept apart.
    func icon(_ app: String, dark: Bool = false) -> UIImage? {
        _ = arrivals
        guard let key = Self.key(app) else { return nil }
        let look = key + (dark ? "|dark" : "|light")
        if let hit = memory[look] ?? memory[key] { return hit }
        if unknown.contains(key) { return nil }
        let id = Self.bundleID(app)
        if let installed = id.flatMap({ SystemIcons.icon($0, dark: dark) }) {
            memory[look] = installed
            return installed
        }
        let found = Self.bundled(id) ?? id.flatMap(DiskCache.read)
        if let found { memory[key] = found } else if id == nil { unknown.insert(key) }
        return found
    }

    /// Fetches the App Store's icon for `app` when nothing nearer has one, and keeps it. Returns when it
    /// has arrived or failed.
    func load(_ app: String) async {
        guard let key = Self.key(app), memory[key] == nil, !unknown.contains(key), let id = Self.bundleID(app),
              !fetching.contains(id), !DiskCache.missedRecently(id) else { return }
        fetching.insert(id)
        defer { fetching.remove(id) }
        if let image = await AppStoreLookup.icon(id) {
            DiskCache.write(image, id)
            memory[key] = image
            arrivals += 1
        } else {
            DiskCache.missed(id)
        }
    }

    // MARK: Names

    private static func key(_ app: String) -> String? {
        let key = app.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return key.isEmpty ? nil : key
    }

    /// The bundle ID for an app's name, or `app` itself when it already is one.
    static func bundleID(_ app: String) -> String? {
        let name = app.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = byName[name.lowercased()] { return id }
        // "com.tencent.xin": a reverse-DNS name with no spaces.
        if !name.contains(" "), name.split(separator: ".").count >= 3 { return name }
        return nil
    }

    /// The name an app goes by on this iPhone, in its first language (English, Simplified or
    /// Traditional Chinese), from a bundle ID or any of its names; nil for an app not listed here.
    static func name(_ app: String) -> String? {
        guard let id = bundleID(app), let names = apps.first(where: { $0.id == id })?.names else { return nil }
        switch AppLanguage.current {
        case .traditionalChinese: return names.count > 2 ? names[2] : names.last
        case .simplifiedChinese: return names.count > 1 ? names[1] : names[0]
        case .english: return names[0]
        }
    }

    /// The bundle IDs of the apps `text` names, in any of their names: "打开美团外卖点下酒菜" names Meituan
    /// Waimai. A Latin name counts only as a whole word, and one-letter names ("X") never.
    static func bundleIDs(namedIn text: String) -> [String] {
        let lower = text.lowercased()
        guard !lower.isEmpty else { return [] }
        return apps.filter { app in
            app.names.contains { name in
                let name = name.lowercased()
                guard name.count >= 2, let range = lower.range(of: name) else { return false }
                guard name.unicodeScalars.allSatisfy(\.isASCII) else { return true }
                let before = range.lowerBound == lower.startIndex ? nil : lower[lower.index(before: range.lowerBound)]
                let after = range.upperBound == lower.endIndex ? nil : lower[range.upperBound]
                return !(before?.isLetter ?? false) && !(after?.isLetter ?? false)
            }
        }.map(\.id)
    }

    /// Apps Poki's tasks often work in: bundle ID, the asset Poki carries (if any), and their names as
    /// the iPhone shows them in English, Simplified and Traditional Chinese.
    private static let apps: [(id: String, asset: String?, names: [String])] = [
        ("com.apple.MobileSMS", "App-messages", ["Messages", "信息", "訊息"]),
        ("com.apple.mobilenotes", "App-notes", ["Notes", "备忘录", "備忘錄"]),
        ("com.tencent.xin", "App-wechat", ["WeChat", "微信"]),
        ("com.starbucks.mystarbucks", "App-starbucks", ["Starbucks", "星巴克"]),
        ("com.ubercab.UberClient", "App-uber", ["Uber"]),
        ("com.tinyspeck.chatlyio", "App-slack", ["Slack"]),
        ("com.burbn.instagram", "App-instagram", ["Instagram"]),
        ("com.apple.mobileslideshow", "App-photos", ["Photos", "照片"]),
        ("com.apple.mobilesafari", "App-safari", ["Safari", "Safari浏览器", "Safari 浏览器", "Safari瀏覽器", "Safari 瀏覽器"]),
        ("com.apple.mobilemail", "App-mail", ["Mail", "邮件", "郵件"]),
        ("com.apple.Maps", "App-maps", ["Maps", "地图", "地圖"]),
        ("com.apple.mobilecal", "App-calendar", ["Calendar", "日历", "行事曆"]),
        ("com.apple.reminders", "App-reminders", ["Reminders", "提醒事项", "提醒事項"]),
        ("com.apple.weather", "App-weather", ["Weather", "天气", "天氣"]),
        ("com.apple.mobiletimer", "App-clock", ["Clock", "时钟", "時鐘"]),
        ("com.apple.calculator", "App-calculator", ["Calculator", "计算器", "計算機"]),
        ("com.apple.Music", "App-music", ["Music", "音乐", "音樂"]),
        ("com.apple.shortcuts", "App-shortcuts", ["Shortcuts", "快捷指令", "捷徑"]),
        ("com.apple.DocumentsApp", "App-files", ["Files", "文件", "檔案"]),
        ("com.apple.TestFlight", "App-testflight", ["TestFlight"]),
        ("com.apple.mobilephone", "App-phone", ["Phone", "电话", "電話"]),
        ("com.apple.camera", "App-camera", ["Camera", "相机", "相機"]),
        // No App Store listing, so no artwork to carry: only this iPhone's own icon can show them.
        ("com.apple.Preferences", nil, ["Settings", "设置", "設定"]),
        ("com.apple.AppStore", nil, ["App Store"]),
        ("com.apple.MobileAddressBook", nil, ["Contacts", "通讯录", "聯絡人"]),
        ("com.apple.Health", nil, ["Health", "健康"]),
        ("com.apple.Passbook", nil, ["Wallet", "钱包", "錢包"]),
        ("com.apple.findmy", nil, ["Find My", "查找", "尋找"]),
        ("com.apple.facetime", nil, ["FaceTime"]),
        ("com.apple.Passwords", nil, ["Passwords", "密码", "密碼"]),
        // On the App Store; fetched by the lookup on first use.
        ("com.apple.podcasts", nil, ["Podcasts", "播客", "Podcast"]),
        ("com.apple.VoiceMemos", nil, ["Voice Memos", "语音备忘录", "語音備忘錄"]),
        ("com.apple.Translate", nil, ["Translate", "翻译", "翻譯"]),
        ("com.apple.freeform", nil, ["Freeform", "无边记", "無邊記"]),
        ("com.apple.Fitness", nil, ["Fitness", "健身"]),
        ("com.apple.stocks", nil, ["Stocks", "股市"]),
        ("com.apple.Home", nil, ["Home", "家庭"]),
        ("net.whatsapp.WhatsApp", nil, ["WhatsApp"]),
        ("ph.telegra.Telegraph", nil, ["Telegram"]),
        ("com.atebits.Tweetie2", nil, ["X"]),
        ("com.xingin.discover", "App-xiaohongshu", ["Xiaohongshu", "小红书", "小紅書", "RED"]),
        ("com.ss.iphone.ugc.Aweme", nil, ["Douyin", "抖音"]),
        ("com.zhiliaoapp.musically", nil, ["TikTok"]),
        ("com.google.ios.youtube", nil, ["YouTube"]),
        ("com.google.chrome.ios", nil, ["Chrome", "Google Chrome"]),
        ("com.spotify.client", nil, ["Spotify"]),
        ("com.taobao.taobao4iphone", "App-taobao", ["Taobao", "淘宝", "淘寶"]),
        ("com.alipay.iphoneclient", nil, ["Alipay", "支付宝", "支付寶"]),
        ("com.meituan.imeituan", nil, ["Meituan", "美团", "美團"]),
        // The home page's default quick actions in Simplified Chinese, with their China store artwork.
        ("com.dianping.dpscope", "App-dianping", ["Dianping", "大众点评", "大眾點評"]),
        ("com.meituan.itakeaway", "App-meituan-waimai", ["Meituan Waimai", "美团外卖", "美團外賣"]),
        ("com.xunmeng.pinduoduo", "App-pinduoduo", ["Pinduoduo", "拼多多"]),
        ("com.taobao.fleamarket", "App-xianyu", ["Xianyu", "闲鱼", "閒魚"]),
        ("com.360buy.jdmobile", "App-jd", ["JD", "京东", "京東"]),
        ("com.baidu.map", "App-baidu-maps", ["Baidu Maps", "百度地图", "百度地圖"]),
        ("com.autonavi.amap", "App-amap", ["Amap", "高德地图", "高德地圖"]),
    ]

    private static let byName: [String: String] = Dictionary(
        apps.flatMap { app in app.names.map { ($0.lowercased(), app.id) } }, uniquingKeysWith: { first, _ in first })

    private static let assets: [String: String] = Dictionary(
        apps.compactMap { app in app.asset.map { (app.id.lowercased(), $0) } }, uniquingKeysWith: { first, _ in first })

    private static func bundled(_ id: String?) -> UIImage? {
        id.flatMap { assets[$0.lowercased()] }.flatMap { UIImage(named: $0) }
    }
}

/// An app's icon in the Home Screen's shape at `size` points, or the placeholder tile.
struct AppIconView: View {
    var app: String
    var size: CGFloat
    /// The icon in its light look whatever the page's: the home page's pills (the owner: their icons
    /// should not change with dark mode).
    var alwaysLight = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
        let image = PerfSwitch.on(.iconsPlaceholder) ? nil : AppIconStore.shared.icon(app, dark: !alwaysLight && scheme == .dark)
        Group {
            if let image {
                Image(uiImage: image).resizable().interpolation(.high).scaledToFill()
            } else {
                Image(systemName: "app.dashed").font(.system(size: size * 0.5)).foregroundStyle(Color(.secondaryLabel))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.tertiarySystemFill))
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

    static func icon(_ id: String) async -> UIImage? {
        let country = (Locale.current.region?.identifier ?? "US").lowercased()
        for store in country == "us" ? ["us"] : [country, "us"] {
            var lookup = URLComponents(string: "https://itunes.apple.com/lookup")!
            lookup.queryItems = [URLQueryItem(name: "bundleId", value: id), URLQueryItem(name: "country", value: store)]
            // Read the one field by pattern: the answer's descriptions carry raw control characters,
            // which a strict JSON parser refuses.
            guard let url = lookup.url, let (data, _) = try? await session.data(from: url),
                  let text = String(data: data, encoding: .utf8),
                  let match = text.firstMatch(of: #/"artworkUrl100"\s*:\s*"([^"]+)"/#) else { continue }
            let art = String(match.1)
            // The artwork's address names its size; 180 pixels is the Home Screen's 60 points at 3x.
            guard let big = URL(string: art.replacingOccurrences(of: "100x100bb", with: "180x180bb")),
                  let (image, _) = try? await session.data(from: big), let icon = UIImage(data: image) else { continue }
            return icon
        }
        return nil
    }
}
