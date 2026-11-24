import Foundation

/// High-level grouping for browsing apps in the composer's full app picker.
enum KnownAppCategory: String, CaseIterable, Hashable, Identifiable {
    case lifestyle
    case social
    case system

    var id: String { rawValue }
}

/// An app Poki knows by name: its bundle ID, the icon Poki carries for it, and its names as the
/// iPhone shows them. The one list behind the app icons (`AppIconStore`), the home page's pills and
/// the message field's app capsules (`AppCapsule`).
struct KnownApp: Hashable {
    let id: String
    /// `Poki/AppIcons/<icon>.png`, the App Store artwork Poki carries (AppIcons.md); nil when only
    /// the iPhone's own icon or the App Store's lookup can show it.
    let icon: String?
    let english: String
    let simplified: String
    let traditional: String
    /// Other names people write for it: an older name, a short one, the maker's English name.
    let aliases: [String]
    /// The bundle IDs of its other editions, which an iPhone may have instead (Bilibili's international one).
    let otherIDs: [String]
    let category: KnownAppCategory

    init(_ id: String, icon: String?, _ english: String, _ simplified: String? = nil, _ traditional: String? = nil,
         aliases: [String] = [], otherIDs: [String] = [], category: KnownAppCategory = .system) {
        self.id = id
        self.otherIDs = otherIDs
        self.icon = icon
        self.english = english
        self.simplified = simplified ?? english
        self.traditional = traditional ?? simplified ?? english
        self.aliases = aliases
        self.category = category
    }

    /// Its own bundle ID, then its other editions'.
    var ids: [String] { [id] + otherIDs }

    /// Every name that means this app, each once.
    var names: [String] {
        var out: [String] = []
        for name in [english, simplified, traditional] + aliases where !out.contains(name) { out.append(name) }
        return out
    }

    /// Its name on an iPhone in `language`.
    func name(in language: AppLanguage) -> String {
        switch language {
        case .english: english
        case .simplifiedChinese: simplified
        case .traditionalChinese: traditional
        }
    }
}

enum KnownApps {
    private static let netEaseCloudMusicID = "com.netease.cloudmusic"
    private static let netEaseCloudMusicAliases: Set<String> = ["网易云", "網易雲"]
    private static let otherNetEaseProductPrefixes = ["课堂", "課堂", "信", "游戏", "遊戲", "阅读", "閱讀"]

    /// 网易云 also starts the names of Cloud Classroom, Yunxin, Cloud Gaming and Cloud Reading.
    /// Keep the short Cloud Music aliases out of those product names when the next word is direct.
    static func allowsNameMatch<Following: Collection>(
        _ name: String, appID: String, followedBy suffix: Following
    ) -> Bool where Following.Element == Character {
        guard appID.caseInsensitiveCompare(netEaseCloudMusicID) == .orderedSame,
              netEaseCloudMusicAliases.contains(name) else { return true }
        return !otherNetEaseProductPrefixes.contains { suffix.starts(with: $0) }
    }

    /// One identity lookup for app text, icons and the file passed to the widget.
    static func find(_ value: String) -> KnownApp? {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return byID[key] ?? byName[key].flatMap { byID[$0.lowercased()] }
    }

    /// Apple's apps, the apps people in mainland China use every day, and the apps the English home
    /// page's pills name and their common neighbours. Icons fetched on Nov 11 to 13 2026 (AppIcons.md).
    static let all: [KnownApp] = apple + china + english

    private static let apple: [KnownApp] = [
        KnownApp("com.apple.MobileSMS", icon: "messages", "Messages", "信息", "訊息"),
        KnownApp("com.apple.mobilephone", icon: "phone", "Phone", "电话", "電話"),
        KnownApp("com.apple.mobilenotes", icon: "notes", "Notes", "备忘录", "備忘錄"),
        KnownApp("com.apple.reminders", icon: "reminders", "Reminders", "提醒事项", "提醒事項"),
        KnownApp("com.apple.mobilecal", icon: "calendar", "Calendar", "日历", "行事曆"),
        KnownApp("com.apple.Maps", icon: "maps", "Maps", "地图", "地圖"),
        KnownApp("com.apple.camera", icon: "camera", "Camera", "相机", "相機"),
        KnownApp("com.apple.mobileslideshow", icon: "photos", "Photos", "照片"),
        KnownApp("com.apple.mobilemail", icon: "mail", "Mail", "邮件", "郵件"),
        KnownApp("com.apple.mobilesafari", icon: "safari", "Safari", "Safari浏览器", "Safari瀏覽器",
                 aliases: ["Safari 浏览器", "Safari 瀏覽器"]),
        KnownApp("com.apple.weather", icon: "weather", "Weather", "天气", "天氣"),
        KnownApp("com.apple.mobiletimer", icon: "clock", "Clock", "时钟", "時鐘"),
        KnownApp("com.apple.calculator", icon: "calculator", "Calculator", "计算器", "計算機"),
        KnownApp("com.apple.Music", icon: "music", "Music", "音乐", "音樂"),
        KnownApp("com.apple.shortcuts", icon: "shortcuts", "Shortcuts", "快捷指令", "捷徑"),
        KnownApp("com.apple.DocumentsApp", icon: "files", "Files", "文件", "檔案"),
        KnownApp("com.apple.TestFlight", icon: "testflight", "TestFlight"),
        // No App Store listing, so no artwork to carry: only this iPhone's own icon can show them.
        KnownApp("com.apple.Preferences", icon: nil, "Settings", "设置", "設定"),
        KnownApp("com.apple.AppStore", icon: nil, "App Store"),
        KnownApp("com.apple.MobileAddressBook", icon: nil, "Contacts", "通讯录", "聯絡人"),
        KnownApp("com.apple.Health", icon: nil, "Health", "健康"),
        KnownApp("com.apple.Passbook", icon: nil, "Wallet", "钱包", "錢包"),
        KnownApp("com.apple.findmy", icon: nil, "Find My", "查找", "尋找"),
        KnownApp("com.apple.facetime", icon: nil, "FaceTime"),
        KnownApp("com.apple.Passwords", icon: nil, "Passwords", "密码", "密碼"),
        // On the App Store; fetched by the lookup on first use.
        KnownApp("com.apple.podcasts", icon: nil, "Podcasts", "播客", "Podcast"),
        KnownApp("com.apple.VoiceMemos", icon: nil, "Voice Memos", "语音备忘录", "語音備忘錄"),
        KnownApp("com.apple.Translate", icon: nil, "Translate", "翻译", "翻譯"),
        KnownApp("com.apple.freeform", icon: nil, "Freeform", "无边记", "無邊記"),
        KnownApp("com.apple.Fitness", icon: nil, "Fitness", "健身"),
        KnownApp("com.apple.stocks", icon: nil, "Stocks", "股市"),
        KnownApp("com.apple.Home", icon: nil, "Home", "家庭"),
    ]

    /// China store artwork.
    private static let china: [KnownApp] = [
        KnownApp("com.tencent.xin", icon: "wechat", "WeChat", "微信", category: .social),
        KnownApp("com.alipay.iphoneclient", icon: "alipay", "Alipay", "支付宝", "支付寶", category: .lifestyle),
        KnownApp("com.taobao.taobao4iphone", icon: "taobao", "Taobao", "淘宝", "淘寶", category: .lifestyle),
        KnownApp("com.360buy.jdmobile", icon: "jd", "JD", "京东", "京東", category: .lifestyle),
        KnownApp("com.xunmeng.pinduoduo", icon: "pinduoduo", "Pinduoduo", "拼多多", category: .lifestyle),
        KnownApp("com.meituan.imeituan", icon: "meituan", "Meituan", "美团", "美團", category: .lifestyle),
        KnownApp("com.meituan.itakeaway", icon: "meituan-waimai", "Meituan Waimai", "美团外卖", "美團外賣", category: .lifestyle),
        // The App Store lists Ele.me as 淘宝闪购 (Nov 2026); people still say 饿了么.
        KnownApp("me.ele.ios.eleme", icon: "eleme", "Ele.me", "饿了么", "餓了麼", aliases: ["淘宝闪购", "淘寶閃購"], category: .lifestyle),
        KnownApp("com.dianping.dpscope", icon: "dianping", "Dianping", "大众点评", "大眾點評", category: .lifestyle),
        KnownApp("com.xingin.discover", icon: "xiaohongshu", "Xiaohongshu", "小红书", "小紅書", aliases: ["RED", "rednote"], category: .social),
        KnownApp("com.ss.iphone.ugc.Aweme", icon: "douyin", "Douyin", "抖音", category: .social),
        KnownApp("com.jiangjia.gif", icon: "kuaishou", "Kuaishou", "快手", category: .social),
        KnownApp("tv.danmaku.bilianime", icon: "bilibili", "Bilibili", "哔哩哔哩", "嗶哩嗶哩", aliases: ["B站"],
                 otherIDs: ["com.bilibili.inter"], category: .social),
        KnownApp("com.sina.weibo", icon: "weibo", "Weibo", "微博", category: .social),
        KnownApp("com.zhihu.ios", icon: "zhihu", "Zhihu", "知乎", category: .social),
        KnownApp("com.taobao.fleamarket", icon: "xianyu", "Xianyu", "闲鱼", "閒魚", category: .lifestyle),
        KnownApp("com.autonavi.amap", icon: "amap", "Amap", "高德地图", "高德地圖", category: .lifestyle),
        KnownApp("com.baidu.map", icon: "baidu-maps", "Baidu Maps", "百度地图", "百度地圖", category: .lifestyle),
        KnownApp("com.xiaojukeji.didi", icon: "didi", "DiDi", "滴滴出行", aliases: ["滴滴"], category: .lifestyle),
        KnownApp("cn.12306.rails12306", icon: "rails12306", "Railway 12306", "铁路12306", "鐵路12306", aliases: ["12306", "Railway12306"], category: .lifestyle),
        KnownApp("ctrip.com", icon: "ctrip", "Trip.com", "携程旅行", "攜程旅行", aliases: ["携程", "攜程", "Ctrip"], category: .lifestyle),
        KnownApp("com.netease.cloudmusic", icon: "netease-music", "NetEase Cloud Music", "网易云音乐", "網易雲音樂",
                 aliases: ["网易云", "網易雲"], category: .social),
        KnownApp("com.tencent.QQMusic", icon: "qq-music", "QQ Music", "QQ音乐", "QQ音樂", aliases: ["QQ 音乐", "QQ 音樂"], category: .social),
        KnownApp("com.tencent.mqq", icon: "qq", "QQ", category: .social),
        KnownApp("com.laiwang.DingTalk", icon: "dingtalk", "DingTalk", "钉钉", "釘釘", category: .social),
        KnownApp("com.bytedance.ee.lark", icon: "feishu", "Feishu", "飞书", "飛書", aliases: ["Lark"], category: .social),
        KnownApp("com.tencent.ww", icon: "wecom", "WeCom", "企业微信", "企業微信", category: .social),
        KnownApp("com.baidu.BaiduMobile", icon: "baidu", "Baidu", "百度", category: .system),
        KnownApp("com.tencent.live4iphone", icon: "tencent-video", "Tencent Video", "腾讯视频", "騰訊視頻", category: .social),
        KnownApp("com.qiyi.iphone", icon: "iqiyi", "iQIYI", "爱奇艺", "愛奇藝", category: .social),
    ]

    /// US store artwork.
    private static let english: [KnownApp] = [
        KnownApp("com.asana.Asana", icon: "asana", "Asana", category: .system),
        KnownApp("com.tinyspeck.chatlyio", icon: "slack", "Slack", category: .social),
        KnownApp("com.ubercab.UberClient", icon: "uber", "Uber", category: .lifestyle),
        KnownApp("com.starbucks.mystarbucks", icon: "starbucks", "Starbucks", "星巴克", category: .lifestyle),
        KnownApp("com.burbn.instagram", icon: "instagram", "Instagram", category: .social),
        KnownApp("net.whatsapp.WhatsApp", icon: "whatsapp", "WhatsApp", category: .social),
        KnownApp("ph.telegra.Telegraph", icon: "telegram", "Telegram", category: .social),
        KnownApp("com.atebits.Tweetie2", icon: "x", "X", aliases: ["Twitter"], category: .social),
        KnownApp("com.google.ios.youtube", icon: "youtube", "YouTube", category: .social),
        KnownApp("com.google.chrome.ios", icon: "chrome", "Chrome", aliases: ["Google Chrome"], category: .system),
        KnownApp("com.spotify.client", icon: "spotify", "Spotify", category: .social),
        KnownApp("com.zhiliaoapp.musically", icon: "tiktok", "TikTok", category: .social),
        KnownApp("com.google.Gmail", icon: "gmail", "Gmail", category: .system),
        KnownApp("com.google.Maps", icon: "google-maps", "Google Maps", "Google 地图", "Google 地圖", category: .lifestyle),
        KnownApp("com.amazon.Amazon", icon: "amazon", "Amazon", category: .lifestyle),
        KnownApp("doordash.DoorDashConsumer", icon: "doordash", "DoorDash", category: .lifestyle),
        KnownApp("com.ubercab.UberEats", icon: "uber-eats", "Uber Eats", category: .lifestyle),
        KnownApp("com.zimride.instant", icon: "lyft", "Lyft", category: .lifestyle),
        KnownApp("com.airbnb.app", icon: "airbnb", "Airbnb", category: .lifestyle),
        KnownApp("com.netflix.Netflix", icon: "netflix", "Netflix", category: .social),
        KnownApp("com.facebook.Facebook", icon: "facebook", "Facebook", category: .social),
        KnownApp("com.facebook.Messenger", icon: "messenger", "Messenger", category: .social),
        KnownApp("com.linkedin.LinkedIn", icon: "linkedin", "LinkedIn", category: .social),
        KnownApp("com.reddit.Reddit", icon: "reddit", "Reddit", category: .social),
        KnownApp("com.hammerandchisel.discord", icon: "discord", "Discord", category: .social),
        KnownApp("us.zoom.videomeetings", icon: "zoom", "Zoom", aliases: ["Zoom Workplace"], category: .social),
        KnownApp("com.microsoft.skype.teams", icon: "teams", "Teams", aliases: ["Microsoft Teams"], category: .social),
        KnownApp("com.microsoft.Office.Outlook", icon: "outlook", "Outlook", aliases: ["Microsoft Outlook"], category: .system),
        KnownApp("com.yourcompany.PPClient", icon: "paypal", "PayPal", category: .lifestyle),
        KnownApp("com.instacart", icon: "instacart", "Instacart", category: .lifestyle),
        KnownApp("com.yelp.yelpiphone", icon: "yelp", "Yelp", category: .lifestyle),
        KnownApp("pinterest", icon: "pinterest", "Pinterest", category: .social),
        KnownApp("com.toyopagroup.picaboo", icon: "snapchat", "Snapchat", category: .social),
        KnownApp("com.burbn.barcelona", icon: "threads", "Threads", category: .social),
        KnownApp("com.contextoptional.OpenTable", icon: "opentable", "OpenTable", category: .lifestyle),
    ]

    /// Default quick-pick bundle IDs shown in the composer's `+` menu when no recent history exists.
    static func defaultQuickAppIDs(for language: AppLanguage) -> [String] {
        switch language {
        case .simplifiedChinese, .traditionalChinese:
            ["com.tencent.xin", "com.meituan.itakeaway", "com.xingin.discover"]
        case .english:
            ["com.apple.MobileSMS", "com.apple.mobilenotes", "com.apple.Maps"]
        }
    }

    /// Default recent bundle IDs shown in the "Recent" strip of the full app browser.
    static func defaultRecentAppIDs(for language: AppLanguage) -> [String] {
        switch language {
        case .simplifiedChinese, .traditionalChinese:
            [
                "com.tencent.xin",
                "com.xingin.discover",
                "com.meituan.itakeaway",
                "com.taobao.taobao4iphone",
                "com.autonavi.amap",
            ]
        case .english:
            [
                "com.apple.MobileSMS",
                "com.apple.mobilenotes",
                "com.apple.Maps",
                "com.ubercab.UberClient",
                "com.tinyspeck.chatlyio",
            ]
        }
    }

    /// By bundle ID, lower-cased.
    static let byID: [String: KnownApp] = Dictionary(
        all.flatMap { app in app.ids.map { ($0.lowercased(), app) } }, uniquingKeysWith: { first, _ in first })

    /// The bundle ID by each of an app's names, lower-cased.
    static let byName: [String: String] = Dictionary(
        all.flatMap { app in app.names.map { ($0.lowercased(), app.id) } }, uniquingKeysWith: { first, _ in first })
}
