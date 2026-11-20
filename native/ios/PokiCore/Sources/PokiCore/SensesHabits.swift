import Foundation

/// Provisional memories about the owner's habits, worked out on the iPhone from Screen History
/// (Senses): which app was in front, and when. No screen text or title is read here, and no model is
/// asked: the counting is plain and cheap, so it can run whenever Poki is opened.
///
/// Three kinds:
/// - `usual`: the app the owner picks for one kind of thing (music, maps, a ride), the way the usual
///   music app worked before (ScreenHabit on dev/screen-history-memory), now for every kind below.
/// - `routine`: an app the owner opens at one time of day on many days.
/// - `daily`: an app the owner opens almost every day.
///
/// They are provisional: the owner's own words and notes always come first, and the app shows them
/// apart from notes, where the owner can forget them or save one as a note.

// MARK: Kinds of apps

public enum SensesCategory: String, CaseIterable, Codable, Sendable {
    case music, maps, browser, video, ride, food, shopping, mail, messaging, notes, podcasts

    /// Bundle IDs of the apps of this kind, as the iPhone names them.
    public var apps: [String] {
        switch self {
        case .music:
            ["com.apple.Music", "com.netease.cloudmusic", "com.tencent.QQMusic", "com.spotify.client", "com.kugou.kugou1002",
             "com.yeelion.kwplayer", "com.luna.music", "com.google.ios.youtubemusic", "com.apple.Classical", "cmccwm.mobilemusic"]
        case .maps:
            ["com.apple.Maps", "com.google.Maps", "com.autonavi.amap", "com.baidu.map", "com.waze.iphone"]
        case .browser:
            ["com.apple.mobilesafari", "com.google.chrome.ios", "org.mozilla.ios.Firefox", "com.microsoft.msedge", "com.brave.ios.browser"]
        case .video:
            ["com.google.ios.youtube", "com.netflix.Netflix", "tv.danmaku.bilianime", "com.tencent.live4iphone", "com.qiyi.iphone",
             "com.disney.disneyplus", "com.ss.iphone.ugc.Aweme", "com.zhiliaoapp.musically", "com.jiangjia.gif"]
        case .ride:
            ["com.ubercab.UberClient", "com.zimride.instant", "com.xiaojukeji.didi"]
        case .food:
            ["doordash.DoorDashConsumer", "com.ubercab.UberEats", "com.meituan.itakeaway", "me.ele.ios.eleme", "com.grubhub.search"]
        case .shopping:
            ["com.amazon.Amazon", "com.taobao.taobao4iphone", "com.360buy.jdmobile", "com.xunmeng.pinduoduo"]
        case .mail:
            ["com.apple.mobilemail", "com.google.Gmail", "com.microsoft.Office.Outlook"]
        case .messaging:
            ["com.apple.MobileSMS", "com.tencent.xin", "net.whatsapp.WhatsApp", "ph.telegra.Telegraph", "com.facebook.Messenger",
             "com.tencent.mqq", "com.hammerandchisel.discord", "jp.naver.line"]
        case .notes:
            ["com.apple.mobilenotes", "net.shinyfrog.bear", "md.obsidian", "notion.id", "com.evernote.iPhone.Evernote"]
        case .podcasts:
            ["com.apple.podcasts", "fm.overcast.overcast", "au.com.shiftyjelly.podcasts"]
        }
    }

    /// Words that make a request about this kind of thing, in the languages Poki speaks. A request
    /// with one of them and no app of this kind named may use the usual app.
    public var words: [String] {
        switch self {
        case .music: ["歌", "音乐", "音樂", "专辑", "專輯", "听", "聽", "music", "song", "track", "album", "playlist"]
        case .maps: ["导航", "導航", "路线", "路線", "怎么走", "怎麼走", "地图", "地圖", "directions", "navigate", "route to", "how far", "map"]
        case .browser: ["网页", "網頁", "网站", "網站", "浏览器", "瀏覽器", "browser", "website", "web page"]
        case .video: ["视频", "影片", "视频号", "看剧", "追剧", "video", "watch", "episode", "show me a clip"]
        case .ride: ["打车", "叫车", "叫車", "网约车", "a ride", "ride to", "taxi", "cab"]
        case .food: ["外卖", "外賣", "点餐", "點餐", "delivery", "order food", "takeout", "take-out"]
        case .shopping: ["购物", "購物", "买", "買", "下单", "下單", "shop", "buy", "order a", "shopping"]
        case .mail: ["邮件", "郵件", "email", "e-mail", "inbox"]
        case .messaging: ["发消息", "發訊息", "短信", "message", "text "]
        case .notes: ["笔记", "筆記", "备忘", "備忘", "note down", "jot", "write down", "notes"]
        case .podcasts: ["播客", "podcast"]
        }
    }

    private static let byApp: [String: SensesCategory] = {
        var map: [String: SensesCategory] = [:]
        for category in allCases { for app in category.apps where map[app.lowercased()] == nil { map[app.lowercased()] = category } }
        return map
    }()

    /// The kind of app a bundle ID is, or nil for any other app.
    public static func of(_ bundleID: String) -> SensesCategory? { byApp[bundleID.lowercased()] }

    /// The bundle ID as this catalog spells it.
    public static func canonical(_ bundleID: String) -> String {
        let lower = bundleID.lowercased()
        return allCases.lazy.flatMap(\.apps).first { $0.lowercased() == lower } ?? bundleID
    }

    /// Whether `text` is about this kind of thing.
    public func isAbout(_ text: String) -> Bool {
        let lower = text.lowercased()
        return words.contains { lower.contains($0) }
    }
}

// MARK: Inputs

/// One read kept by Screen History: when, and which app was in front. Agent-made reads are left out
/// by the caller (or here, through `agentSpans`).
public struct SensesSighting: Equatable, Sendable {
    public var at: Date
    public var app: String

    public init(at: Date, app: String) {
        self.at = at
        self.app = app
    }
}

/// A time an agent (Poki or an outside one) worked in an app: reads of that app then are not the owner's.
public struct SensesAgentSpan: Equatable, Sendable {
    public var app: String
    public var from: Date
    public var to: Date

    public init(app: String, from: Date, to: Date) {
        self.app = app
        self.from = from
        self.to = to
    }
}

public enum SensesPartOfDay: String, CaseIterable, Codable, Sendable {
    case morning, afternoon, evening, night

    public static func of(_ date: Date, calendar: Calendar = .current) -> SensesPartOfDay {
        switch calendar.component(.hour, from: date) {
        case 5..<12: .morning
        case 12..<18: .afternoon
        case 18..<23: .evening
        default: .night
        }
    }
}

// MARK: Habits

public struct SensesHabit: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: Codable, Equatable, Sendable {
        case usual(SensesCategory)
        case routine(SensesPartOfDay)
        case daily
    }

    public var kind: Kind
    public var app: String
    /// Uses that make it, in the window it was counted over.
    public var uses: Int
    /// Days with at least one such use.
    public var days: Int
    public var lastUse: Date

    /// Stays the same while the habit holds, so Forget can name it.
    public var id: String {
        switch kind {
        case .usual(let category): "usual.\(category.rawValue).\(app.lowercased())"
        case .routine(let part): "routine.\(part.rawValue).\(app.lowercased())"
        case .daily: "daily.\(app.lowercased())"
        }
    }

    public init(kind: Kind, app: String, uses: Int, days: Int, lastUse: Date) {
        self.kind = kind
        self.app = app
        self.uses = uses
        self.days = days
        self.lastUse = lastUse
    }

    /// The habit's line for a model's instructions, in English. `name` is the app's name.
    public func line(name: String) -> String {
        switch kind {
        case .usual(let category):
            "Usual \(category.rawValue) app: \(name) (bundle id \(app)), \(uses) uses on \(days) days in the past week."
        case .routine(let part):
            "Often uses \(name) (bundle id \(app)) in the \(part.rawValue): on \(days) days in the past two weeks."
        case .daily:
            "Uses \(name) (bundle id \(app)) almost every day: on \(days) of the past 7 days."
        }
    }
}

public enum SensesHabits {
    /// Reads of the same app this close together are one use.
    public static let sameUseGap: TimeInterval = 30 * 60
    /// A use needs this many reads: the collector reads an app about a second after it comes to the
    /// front and again about 4 s later, so a glance or a mistaken tap leaves one read and is no use.
    public static let minReads = 2
    /// A read of an app within this long after an agent worked in it is the agent's, not the owner's.
    public static let agentShadow: TimeInterval = 10 * 60
    public static let week: TimeInterval = 7 * 86_400
    public static let twoWeeks: TimeInterval = 14 * 86_400

    /// The fewest uses in a week for a usual app, and on how many days at least.
    public static let usualUses = 3
    public static let usualDays = 2
    /// The fewest days a time of day must hold an app for a routine.
    public static let routineDays = 3
    /// The fewest days of the past week for a daily app.
    public static let dailyDays = 5
    /// At most this many routine and daily habits are kept, the strongest first.
    public static let maxPatterns = 6

    /// Each app's uses (the first read of each run of reads), oldest first. Reads after `floor`, the
    /// owner's own (not in an agent's span), of apps `keeps` allows.
    public static func uses(
        _ sightings: [SensesSighting],
        agentSpans: [SensesAgentSpan] = [],
        floor: Date = .distantPast,
        now: Date = Date(),
        keeps: (String) -> Bool = { _ in true }
    ) -> [String: [Date]] {
        var last: [String: Date] = [:]
        // The run under way for each app: when it started and how many reads it has.
        var runs: [String: (start: Date, reads: Int)] = [:]
        var out: [String: [Date]] = [:]
        func close(_ app: String) {
            if let run = runs[app], run.reads >= minReads { out[app, default: []].append(run.start) }
            runs[app] = nil
        }
        for sighting in sightings.sorted(by: { $0.at < $1.at }) {
            guard sighting.at > floor, sighting.at <= now, !sighting.app.isEmpty, keeps(sighting.app) else { continue }
            let app = SensesCategory.canonical(sighting.app)
            let lower = app.lowercased()
            if agentSpans.contains(where: { $0.app.lowercased() == lower && sighting.at >= $0.from && sighting.at <= $0.to.addingTimeInterval(agentShadow) }) {
                continue
            }
            if let previous = last[app], sighting.at.timeIntervalSince(previous) <= sameUseGap {
                last[app] = sighting.at
                runs[app]?.reads += 1
                continue
            }
            close(app)
            last[app] = sighting.at
            runs[app] = (sighting.at, 1)
        }
        for app in Array(runs.keys) { close(app) }
        for app in out.keys { out[app]?.sort() }
        return out
    }

    /// Every habit the uses hold, usual apps first, then routines and daily apps, strongest first.
    public static func habits(from uses: [String: [Date]], now: Date = Date(), calendar: Calendar = .current) -> [SensesHabit] {
        usual(uses, now: now, calendar: calendar) + patterns(uses, now: now, calendar: calendar)
    }

    /// For each kind of app: the one used at least `usualUses` times on `usualDays` days this week,
    /// and at least twice as often as the next app of its kind.
    static func usual(_ uses: [String: [Date]], now: Date, calendar: Calendar) -> [SensesHabit] {
        let since = now.addingTimeInterval(-week)
        var out: [SensesHabit] = []
        for category in SensesCategory.allCases {
            let ranked = uses.compactMap { app, times -> (app: String, times: [Date])? in
                guard SensesCategory.of(app) == category else { return nil }
                let recent = times.filter { $0 > since && $0 <= now }
                return recent.isEmpty ? nil : (app, recent)
            }.sorted { $0.times.count != $1.times.count ? $0.times.count > $1.times.count : $0.app < $1.app }
            guard let top = ranked.first, top.times.count >= usualUses else { continue }
            let days = Set(top.times.map { calendar.startOfDay(for: $0) }).count
            guard days >= usualDays else { continue }
            if ranked.count > 1, top.times.count < 2 * ranked[1].times.count { continue }
            out.append(SensesHabit(kind: .usual(category), app: top.app, uses: top.times.count, days: days, lastUse: top.times.max() ?? now))
        }
        return out
    }

    /// Routines and daily apps. An app whose use days mostly fall in one time of day is a routine for
    /// it; one used on most days of the week otherwise is daily.
    static func patterns(_ uses: [String: [Date]], now: Date, calendar: Calendar) -> [SensesHabit] {
        let since = now.addingTimeInterval(-twoWeeks)
        let weekAgo = now.addingTimeInterval(-week)
        var out: [SensesHabit] = []
        for (app, times) in uses {
            let recent = times.filter { $0 > since && $0 <= now }
            guard !recent.isEmpty else { continue }
            let allDays = Set(recent.map { calendar.startOfDay(for: $0) })
            var partDays: [SensesPartOfDay: Set<Date>] = [:]
            for time in recent { partDays[SensesPartOfDay.of(time, calendar: calendar), default: []].insert(calendar.startOfDay(for: time)) }
            let best = partDays.max { a, b in a.value.count != b.value.count ? a.value.count < b.value.count : a.key.rawValue > b.key.rawValue }
            if let best, best.value.count >= routineDays, Double(best.value.count) >= 0.6 * Double(allDays.count) {
                let inPart = recent.filter { SensesPartOfDay.of($0, calendar: calendar) == best.key }
                out.append(SensesHabit(kind: .routine(best.key), app: app, uses: inPart.count, days: best.value.count, lastUse: inPart.max() ?? now))
                continue
            }
            let weekTimes = recent.filter { $0 > weekAgo }
            let weekDays = Set(weekTimes.map { calendar.startOfDay(for: $0) }).count
            if weekDays >= dailyDays {
                out.append(SensesHabit(kind: .daily, app: app, uses: weekTimes.count, days: weekDays, lastUse: weekTimes.max() ?? now))
            }
        }
        return Array(out.sorted { $0.days != $1.days ? $0.days > $1.days : $0.uses != $1.uses ? $0.uses > $1.uses : $0.app < $1.app }.prefix(maxPatterns))
    }

    /// The usual app that may answer `task`: the task is about that kind of thing and names no app of
    /// that kind (`names` tells whether the task names an app), and no note of the owner's chooses one.
    public static func usualApp(
        for task: String,
        habits: [SensesHabit],
        names: (String, String) -> Bool,
        notes: [String] = []
    ) -> SensesHabit? {
        for habit in habits {
            guard case .usual(let category) = habit.kind, category.isAbout(task) else { continue }
            if category.apps.contains(where: { names(task, $0) }) { continue }
            // A note naming an app of this kind, or about this kind of thing and saying which app to use
            // ("以后都用某某放歌", "always use X for songs"), is the owner's choice and comes first.
            let chooses: (String) -> Bool = { note in
                category.apps.contains { names(note, $0) }
                    || (category.isAbout(note) && ["用", "app", "use"].contains { note.lowercased().contains($0) })
            }
            if notes.contains(where: chooses) { continue }
            return habit
        }
        return nil
    }
}
