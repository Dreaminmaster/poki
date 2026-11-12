import Foundation
import Observation
import PokiCore

/// One quick action on the home page: an app and what to do in it, as its pill shows them (the app's
/// icon, its name, the action), and what a tap puts in the message field.
struct HomeShortcut: Identifiable, Equatable {
    /// The normalized request. Similar requests share it, and Forget stores it.
    var key: String
    /// The app's bundle ID, which its icon comes by (`AppIconView`).
    var app: String
    /// The app's name as this iPhone shows it.
    var appName: String
    /// What to do in the app, without its name.
    var text: String
    var prompt: String
    var id: String { key }
}

/// The app a quick action works in, found from what Poki has: a routine's recorded app, or the name
/// a request starts with. Only apps `AppIconStore` knows by name: a pill always shows an app's icon
/// and name, so an action without a known app is not a pill.
@MainActor
enum ShortcutApp {
    /// A bundle ID or an app's name.
    static func named(_ app: String?) -> (id: String, name: String)? {
        guard let app, let id = AppIconStore.bundleID(app), let name = AppIconStore.name(id) else { return nil }
        return (id, name)
    }

    /// The app a request names first and what it asks there: "打开设置看看电池" is Settings and
    /// "看看电池", "Open Notes, add milk" is Notes and "add milk". Nil when it names no app first, or
    /// nothing is left to do.
    static func leading(_ words: String) -> (id: String, name: String, action: String)? {
        var s = words.trimmingCharacters(in: .whitespacesAndNewlines)
        for lead in [openings, verbs] {
            if let hit = lead.first(where: { s.lowercased().hasPrefix($0) }) { s = String(s.dropFirst(hit.count)).trimmingCharacters(in: .whitespaces) }
        }
        for candidate in candidates(s) {
            guard let app = named(candidate) else { continue }
            // "notes" or "home" in lower case is a word, not the app.
            if AppCapsule.everydayWords.contains(where: { $0.caseInsensitiveCompare(candidate) == .orderedSame }),
               candidate.first?.isUppercase != true { continue }
            var action = String(s.dropFirst(candidate.count))
            action = action.trimmingCharacters(in: CharacterSet.whitespaces.union(.punctuationCharacters))
            for joint in joints where action.lowercased().hasPrefix(joint) {
                action = String(action.dropFirst(joint.count)).trimmingCharacters(in: CharacterSet.whitespaces.union(.punctuationCharacters))
            }
            return action.isEmpty ? nil : (app.id, app.name, action)
        }
        return nil
    }

    /// The beginnings that could be an app's name, longest first: up to three words, or up to eight
    /// characters when it begins in Chinese.
    private static func candidates(_ s: String) -> [String] {
        let words = s.split(separator: " ", omittingEmptySubsequences: true)
        var out: [String] = []
        if s.unicodeScalars.first?.isASCII == true {
            for n in stride(from: min(3, words.count), through: 1, by: -1) {
                out.append(words.prefix(n).joined(separator: " ").trimmingCharacters(in: .punctuationCharacters))
            }
        }
        if s.unicodeScalars.first.map({ !$0.isASCII }) == true {
            for n in stride(from: min(8, s.count), through: 2, by: -1) { out.append(String(s.prefix(n))) }
        }
        return out.filter { !$0.isEmpty }
    }

    private static let openings = ["please ", "can you ", "could you ", "help me ", "请帮我", "帮我", "麻烦", "请"]
    private static let verbs = ["open ", "go to ", "in ", "打开", "去", "在", "用"]
    private static let joints = ["and ", "then ", "to ", "里", "上", "中", "然后"]
}

/// The home page's quick actions, worked out on this iPhone from what the owner did before. Nothing
/// is uploaded and no model is asked. In order: the routines Poki remembered (their description, or
/// their name, and the app they were recorded in), then requests the owner made at least twice
/// (similar wordings counted as one) that begin with an app, then the default examples. Each is an app
/// and an action; a routine or request without both is left out.
@MainActor
enum HomeShortcuts {
    struct Request: Equatable { var text: String; var at: Date }
    struct Remembered: Equatable { var text: String; var app: String?; var runs: Int; var at: Date }

    /// At least this many, and as many as there are default examples.
    static let shown = 6

    static func rank(routines: [Remembered], requests: [Request], examples: [HomeShortcut], forgotten: Set<String>,
                     now: Date) -> [HomeShortcut] {
        var out: [HomeShortcut] = []
        func taken(_ key: String) -> Bool {
            key.isEmpty || forgotten.contains { similar($0, key) } || out.contains { similar($0.key, key) }
        }

        let remembered = routines.filter { !isPrivate($0.text) }
            .map { (routine: $0, key: normalize($0.text), score: frecency(Double(max($0.runs, 1)), last: $0.at, now: now)) }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.routine.at > $1.routine.at }
        for r in remembered where !taken(r.key) {
            guard let pill = routinePill(r.key, r.routine) else { continue }
            out.append(pill)
        }

        for group in groups(requests, now: now) where group.count >= 2 && !taken(group.key) {
            guard let pill = requestPill(group.key, group.latest) else { continue }
            out.append(pill)
        }

        for example in examples where !taken(example.key) { out.append(example) }
        return Array(out.prefix(max(shown, examples.count)))
    }

    /// A routine's app is the one it was recorded in; its words lose the app's name if they begin with it.
    private static func routinePill(_ key: String, _ routine: Remembered) -> HomeShortcut? {
        guard let app = ShortcutApp.named(routine.app) else { return nil }
        let action = ShortcutApp.leading(routine.text).flatMap { $0.id == app.id ? $0.action : nil } ?? routine.text
        return HomeShortcut(key: key, app: app.id, appName: app.name, text: action, prompt: routine.text)
    }

    /// A request is a pill only when it begins with an app, as a quick action from the home page does.
    private static func requestPill(_ key: String, _ words: String) -> HomeShortcut? {
        guard let found = ShortcutApp.leading(words) else { return nil }
        return HomeShortcut(key: key, app: found.id, appName: found.name, text: found.action, prompt: words)
    }

    /// Requests that normalize to the same or a similar key, most used first: the count weighed by how
    /// recently it was last made, and shown in its latest wording.
    static func groups(_ requests: [Request], now: Date) -> [(key: String, latest: String, count: Int, last: Date)] {
        var groups: [(key: String, latest: String, count: Int, last: Date)] = []
        for request in requests.sorted(by: { $0.at < $1.at }) where !isPrivate(request.text) {
            let key = normalize(request.text)
            guard !key.isEmpty else { continue }
            let words = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let i = groups.firstIndex(where: { similar($0.key, key) }) {
                groups[i].count += 1; groups[i].latest = words; groups[i].last = request.at
            } else {
                groups.append((key, words, 1, request.at))
            }
        }
        return groups.sorted { a, b in
            let (sa, sb) = (frecency(Double(a.count), last: a.last, now: now), frecency(Double(b.count), last: b.last, now: now))
            return sa != sb ? sa > sb : a.last > b.last
        }
    }

    /// zoxide's frecency (src/db/dir.rs, `Dir::score`, MIT, Copyright 2020 Ajeet D'Souza): the count,
    /// times 4 within the hour, 2 within the day, 0.5 within the week, 0.25 after.
    static func frecency(_ rank: Double, last: Date, now: Date) -> Double {
        let age = now.timeIntervalSince(last)
        if age < 3600 { return rank * 4 }
        if age < 86_400 { return rank * 2 }
        if age < 604_800 { return rank * 0.5 }
        return rank * 0.25
    }

    /// Case, punctuation and spaces, numbers, dates and times, and polite openings dropped.
    static func normalize(_ text: String) -> String {
        var s = text.lowercased()
        for pattern in variable { s = s.replacingOccurrences(of: pattern, with: " ", options: .regularExpression) }
        s = String(s.unicodeScalars.filter { CharacterSet.letters.contains($0) }.map(Character.init))
        for opening in openings where s.hasPrefix(opening) { s.removeFirst(opening.count) }
        for filler in fillers { s = s.replacingOccurrences(of: filler, with: "") }
        return s
    }

    /// The same request in other words: equal, or at least 80% of their pairs of letters shared (Dice).
    static func similar(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let (x, y) = (pairs(a), pairs(b))
        guard !x.isEmpty, !y.isEmpty else { return false }
        var rest = y, shared = 0
        for pair in x { if let i = rest.firstIndex(of: pair) { rest.remove(at: i); shared += 1 } }
        return Double(2 * shared) / Double(x.count + y.count) >= 0.8
    }

    /// Never a pill: money, codes, passwords, contacts and message text. Better missed than shown.
    static func isPrivate(_ text: String) -> Bool {
        let s = text.lowercased()
        return privateMarks.contains { s.range(of: $0, options: .regularExpression) != nil }
    }

    private static func pairs(_ s: String) -> [String] {
        let c = Array(s)
        return c.count < 2 ? c.map(String.init) : (0..<c.count - 1).map { String(c[$0...($0 + 1)]) }
    }

    private static let variable = [
        #"\d+([:./\-年月日号点时分]\d*)*"#,
        #"[零一二两三四五六七八九十百]+(点|号|日|月|分钟|小时)"#,
        #"(今天|明天|后天|昨天|今晚|明早|早上|上午|中午|下午|晚上|周[一二三四五六日天]|星期[一二三四五六日天])"#,
        #"\b(today|tomorrow|tonight|yesterday|morning|afternoon|evening|monday|tuesday|wednesday|thursday|friday|saturday|sunday|am|pm)\b"#,
    ]
    private static let openings = ["please", "canyou", "couldyou", "helpme", "请帮我", "帮我", "麻烦", "请"]
    private static let fillers = ["一下", "的", "了", "吧", "呢"]
    private static let privateMarks = [
        #"[$¥€£₩]"#, #"\d+(\.\d+)?\s*(元|块|美元|刀|dollars?|usd|rmb|yuan|bucks)"#,
        #"(付款|支付|转账|汇款|收款|红包|金额|余额|\bpay\b|payment|transfer|venmo|paypal)"#,
        #"(验证码|校验码|动态码|\bcode\b|\botp\b|2fa|one-time|verification)"#, #"\d{4,}"#,
        #"(密码|口令|密钥|password|passcode|\bpin\b|token)"#,
        #"(消息|短信|信息|微信|回复|告诉|说一?声|跟.+说|对.+说|打电话|通话|联系|邮件)"#,
        #"\b(text|message|tell|reply|call|email|e-mail|dm|say|send)\b"#,
        #"[“”\"「」『』‘’@]"#,
    ]
}

/// The quick actions the home page shows, worked out once and again only when the history, the
/// routines or the forgotten ones change.
@MainActor @Observable
final class HomeShortcutStore {
    static let shared = HomeShortcutStore()
    private(set) var shortcuts: [HomeShortcut] = HomeIdea.examples
    @ObservationIgnored private var basis: [String] = []
    @ObservationIgnored private var routes: [HomeShortcuts.Remembered] = []
    @ObservationIgnored private var requests: [HomeShortcuts.Request] = []
    @ObservationIgnored private let defaults = UserDefaults.standard
    private static let forgottenKey = "home.shortcuts.forgotten"

    var forgotten: Set<String> { Set(defaults.stringArray(forKey: Self.forgottenKey) ?? []) }

    func refresh(sessions: [SavedSession], routines: [Routine], now: Date = Date()) {
        let requests = sessions.compactMap { session -> HomeShortcuts.Request? in
            guard session.kind == .poki else { return nil }
            for entry in session.entries { if case .you(let text, _) = entry.kind { return .init(text: text, at: session.started) } }
            return nil
        }
        let routes = routines.map { HomeShortcuts.Remembered(text: $0.description.isEmpty ? $0.name : $0.description, app: $0.app, runs: $0.runs, at: $0.updated) }
        let basis = [requests.map { "\($0.at.timeIntervalSince1970)" }.joined(separator: ","),
                     routes.map { "\($0.text)\($0.runs)" }.joined(separator: ","), forgotten.sorted().joined(separator: ",")]
        guard basis != self.basis else { return }
        (self.basis, self.routes, self.requests) = (basis, routes, requests)
        rank(now: now)
    }

    /// Long press, Forget: gone from the home page, also after a restart.
    func forget(_ shortcut: HomeShortcut) {
        defaults.set(Array(forgotten.union([shortcut.key])).sorted(), forKey: Self.forgottenKey)
        basis = []
        rank(now: Date())
    }

    private func rank(now: Date) {
        shortcuts = HomeShortcuts.rank(routines: routes, requests: requests, examples: HomeIdea.examples, forgotten: forgotten, now: now)
    }
}
