import PokiCore
import SwiftUI

// What the Memory page shows, in one shape for the three kinds the memory system plan names: memories,
// habits and skills. The page reads only this model, made from RoutineStore: notes are memories (under
// their app, or About You when they have none), routines are skills under their app (no app: Other),
// and the store's change log is Recent Updates. A note from before apps and conversations were kept has
// neither: it is in About You (used in every app, as before), and an agent's reads "No source".
//
// Habits come from Screen History's learned habits, which are not on main yet: until they are, the
// library has none, and the page shows no habit group. The sample library (`-pokiMemorySample YES`) is
// the design's "used for a week" data, for screenshots only.

enum MemoryKind: String, Hashable, CaseIterable {
    case memory, habit, skill
}

/// How an item came to be (GLOSSARY: Source).
enum MemorySource: Hashable {
    /// The owner said it in a conversation, in so many words.
    case said
    /// The owner wrote it on the Memory page.
    case wrote
    /// The owner changed it on the Memory page.
    case edited
    /// The owner changed it on a suggestion card.
    case card
    /// Poki noted it during a conversation.
    case chat
    /// Poki's overnight Dream added or changed it.
    case dream
    /// Poki saved it after a task that worked (skills).
    case task
    /// It came in with an imported memory file.
    case imported
    /// An agent kept it but no conversation was recorded with it: every memory from before the Memory
    /// page, and an outside agent's.
    case unknown

    /// The owner's own words or changes: shown in ink, Poki's in blue (the design's rule).
    var isOwners: Bool { [.said, .wrote, .edited, .card].contains(self) }

    var label: LocalizedStringKey {
        switch self {
        case .said: "You said"
        case .wrote: "You wrote"
        case .edited: "You edited"
        case .card: "Changed on a card"
        case .chat: "Noted in a conversation"
        case .dream: "Dream"
        case .task: "Saved by Poki after a task"
        case .imported: "Imported"
        case .unknown: "No source"
        }
    }

    var symbol: String {
        switch self {
        case .said: "person"
        case .wrote, .edited: "pencil"
        case .card: "rectangle.and.pencil.and.ellipsis"
        case .chat: "bubble.left"
        case .dream: "moon"
        case .task: "bolt"
        case .imported: "square.and.arrow.down"
        case .unknown: "circle.dashed"
        }
    }
}

/// One memory, habit or skill.
struct MemoryItem: Identifiable, Equatable {
    var id: String
    var kind: MemoryKind
    /// A memory's text, a habit's "what", a skill's name.
    var text: String
    /// A habit's time ("工作日中午 12 点前后"), a skill's description; written by the model, shown as is.
    var detail: String = ""
    /// The app it belongs to (a bundle ID). A memory without one is global (About You); a skill without
    /// one is under Other.
    var app: String?
    var source: MemorySource
    /// The conversation it was heard in, when the store kept it: Source links back to it (decided
    /// 2026-11-18).
    var heard: MemoryOrigin?
    var updated: Date
    var locked = false
    /// Habits only (GLOSSARY: Reason). Memories show their source, never a reason (decided 2026-11-18).
    var reason: String?
    /// A habit's skill and memory, by name and text.
    var linkedSkill: String?
    var linkedMemory: String?
    /// Skills: the record the current page shows.
    var steps = 0, ok = 0, runs = 0
    var lastMs: Int?
    var stale = false
    var stop: String?
    var params: [String] = []
    var otherApps: [String] = []
    var savedBy: String?
}

/// Where a memory was heard: the app the conversation was about, when, and the conversation itself.
struct MemoryOrigin: Hashable {
    var app: String?
    var at: Date
    /// A conversation in SessionStore.
    var session: String?
}

/// One line of Recent Updates.
struct MemoryChange: Identifiable, Equatable {
    enum Action: Hashable { case added, edited, forgot }
    enum Actor: Hashable { case poki, dream, owner }
    var id: String
    var at: Date
    var action: Action
    var actor: Actor
    /// The item as it is now, or as it was when it was forgotten.
    var item: MemoryItem
    /// The text before an edit.
    var previous: String?
    var undone = false

    /// Poki's and Dream's changes can be undone; of the owner's, only forgetting (decided 2026-11-18).
    var canUndo: Bool { !undone && (actor != .owner || action == .forgot) }
}

/// What the page lists: the items, the changes, and what the page may do with them.
@MainActor @Observable
final class MemoryLibrary {
    static let shared = MemoryLibrary()
    nonisolated static let sampleKey = "pokiMemorySample"
    static let noteLimit = 300

    private(set) var items: [MemoryItem] = []
    private(set) var changes: [MemoryChange] = []
    /// Recent Updates has lines the owner has not opened yet (the dot on its button).
    var unread = false
    /// A forgotten item that the toast can still bring back.
    private(set) var lastForgotten: MemoryChange?
    /// What a notice from the Memory page says, such as an import's result.
    var message: String?

    @ObservationIgnored private let store: RoutineStore?

    var isSample: Bool { store == nil }
    /// When the owner last opened Recent Updates: Poki's changes after it light the dot.
    @ObservationIgnored private let seenKey = "memory.recentSeen"

    init(store: RoutineStore? = UserDefaults.standard.bool(forKey: MemoryLibrary.sampleKey) ? nil : .shared) {
        self.store = store
        if store == nil { loadSample(); return }
        reload()
        // What Poki keeps or forgets in a conversation shows up here while the page is open.
        store?.onChange = { Task { @MainActor in MemoryLibrary.shared.reload() } }
    }

    // MARK: Reading

    var about: [MemoryItem] { items.filter { $0.kind == .memory && $0.app == nil }.sorted { $0.updated > $1.updated } }

    func items(in app: String?, _ kind: MemoryKind) -> [MemoryItem] {
        items.filter { $0.kind == kind && $0.app == app && !(kind == .memory && app == nil) }.sorted { $0.updated > $1.updated }
    }

    /// The apps with anything in them, most recently changed first.
    var apps: [String] {
        let tagged = items.compactMap { item in item.app.map { ($0, item.updated) } }
        let latest = Dictionary(tagged, uniquingKeysWith: { max($0, $1) })
        // Ties (Dream changes several apps at the same minute) go by bundle id, so the order holds between launches.
        return latest.keys.sorted { latest[$0]! != latest[$1]! ? latest[$0]! > latest[$1]! : $0 < $1 }
    }

    /// Skills with no app, for the Other row.
    var other: [MemoryItem] { items(in: nil, .skill) }

    func item(_ id: String) -> MemoryItem? { items.first { $0.id == id } }

    func search(_ query: String) -> [MemoryKind: [MemoryItem]] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [:] }
        let hits = items.filter { item in
            [item.text, item.detail, item.app.flatMap(AppIconStore.name) ?? ""].contains { $0.localizedCaseInsensitiveContains(q) }
        }
        return Dictionary(grouping: hits, by: \.kind)
    }

    // MARK: Changing

    /// Adds a memory the owner wrote; locked from the start unless the editor's switch left it open.
    func add(_ text: String, app: String?, locked: Bool = true) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= Self.noteLimit else { return }
        if let store {
            store.remember(clean, by: RoutineStore.owner, app: app, locked: locked)
            reload()
            return
        }
        let item = MemoryItem(id: UUID().uuidString, kind: .memory, text: clean, app: app, source: .wrote, updated: Date(), locked: locked)
        items.append(item)
        log(.added, .owner, item)
    }

    /// Saves the owner's change. A change of words or app locks the item, as the store does, unless the
    /// editor's switch says Poki may still change it; the switch alone can lock or unlock it too.
    func edit(_ id: String, text: String, app: String?, locked: Bool = true) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= Self.noteLimit, let i = items.firstIndex(where: { $0.id == id }) else { return }
        let before = items[i]
        // Saving the same words again changes nothing (a skill keeps its name; a memory its app too).
        let changed = clean != before.text || (before.kind == .memory && app != before.app)
        if let store {
            if changed {
                switch before.kind {
                case .memory: store.editNote(id, text: clean, app: .some(app))
                case .skill: store.rename(before.text, to: clean, by: RoutineStore.owner)
                case .habit: break
                }
            }
            // The store locked what it changed; the switch has the last word.
            let lockedNow = changed ? true : before.locked
            // A skill is found by its name, which the rename may just have changed.
            if lockedNow != locked { store.setLocked(before.kind == .skill ? (changed ? clean : before.text) : id, locked) }
            reload()
            return
        }
        if changed {
            items[i].text = clean
            items[i].app = app
            items[i].source = .edited
            // What you wrote or changed was not heard in a conversation: no link back to one.
            items[i].heard = nil
            items[i].updated = Date()
            log(.edited, .owner, items[i], previous: before.text == clean ? nil : before.text)
        }
        items[i].locked = locked
    }

    func setLocked(_ id: String, _ locked: Bool) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        if let store {
            store.setLocked(items[i].kind == .skill ? items[i].text : id, locked)
            reload()
            return
        }
        items[i].locked = locked
    }

    /// Forgets an item. It can come back from the toast, and from Recent Updates.
    func forget(_ id: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        if let store {
            let item = items[i]
            let done = switch item.kind {
            case .memory: store.forgetNote(item.id, by: RoutineStore.owner)
            case .skill: store.forget(item.text, by: RoutineStore.owner)
            case .habit: false
            }
            reload()
            // The toast undoes the store's own entry for this forget.
            if done, let change = changes.first, change.action == .forgot, change.item.id == item.id { lastForgotten = change }
            return
        }
        let item = items.remove(at: i)
        lastForgotten = MemoryChange(id: UUID().uuidString, at: Date(), action: .forgot, actor: .owner, item: item)
        if let change = lastForgotten { changes.insert(change, at: 0) }
    }

    /// Puts back what a change took away or changed. Undoing Poki's or Dream's change locks the item,
    /// so it is not made again; what you forgot comes back as it was.
    func undo(_ change: MemoryChange) {
        if lastForgotten?.id == change.id { lastForgotten = nil }
        if let store {
            store.undo(change.id)
            reload()
            return
        }
        if let i = changes.firstIndex(where: { $0.id == change.id }) { changes[i].undone = true }
        let locks = change.actor != .owner
        var back = change.item
        if locks { back.locked = true }
        switch change.action {
        case .forgot:
            items.append(back)
        case .added:
            items.removeAll { $0.id == change.item.id }
        case .edited:
            guard let i = items.firstIndex(where: { $0.id == change.item.id }) else { return }
            if let previous = change.previous { items[i].text = previous }
            if locks { items[i].locked = true }
        }
    }

    /// Lets the toast's item go: it stays forgotten.
    func settleForgotten() { lastForgotten = nil }

    /// Recent Updates was opened: its dot goes out until Poki changes something again.
    func markSeen() {
        unread = false
        UserDefaults.standard.set(Date(), forKey: seenKey)
    }

    func clearAll() {
        store?.clearAll()
        if store == nil { items = []; changes = [] }
        reload()
    }

    func importFile(_ url: URL) {
        guard let store else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            message = try store.importData(try Data(contentsOf: url), by: "import")
        } catch {
            message = AppLocalization.text(LocalizedStringResource("That file could not be imported: \(String(describing: error))"))
        }
        reload()
    }

    /// The export for the share sheet, written to tmp.
    func exportFile() -> URL? {
        guard let store, let data = try? store.exportData() else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(RoutineStore.backupName)
        return (try? data.write(to: url, options: .atomic)) != nil ? url : nil
    }

    private func log(_ action: MemoryChange.Action, _ actor: MemoryChange.Actor, _ item: MemoryItem, previous: String? = nil) {
        changes.insert(MemoryChange(id: UUID().uuidString, at: Date(), action: action, actor: actor, item: item, previous: previous), at: 0)
    }

    // MARK: The store

    /// Reads the store again.
    func reload() {
        guard let store else { return }
        let routines = store.routines
        var next: [MemoryItem] = store.notes.map(Self.item)
        next += routines.map(Self.item)
        next += Self.habits()
        items = next
        changes = store.changes.compactMap { Self.change($0, routines: routines) }
        let seen = UserDefaults.standard.object(forKey: seenKey) as? Date ?? .distantPast
        unread = changes.contains { $0.actor != .owner && $0.at > seen && !$0.undone }
    }

    /// Screen History's learned habits go here once they are on main; until then there are none.
    private static func habits() -> [MemoryItem] { [] }

    private static func item(_ note: MemoryNote) -> MemoryItem {
        MemoryItem(id: note.id, kind: .memory, text: note.text, app: note.app,
                   source: note.edited != nil ? .edited : source(note.by, heard: note.heard != nil),
                   heard: note.heard.map { MemoryOrigin(app: $0.app, at: note.at, session: $0.session) },
                   updated: note.edited ?? note.at, locked: note.isLocked)
    }

    private static func item(_ routine: Routine) -> MemoryItem {
        MemoryItem(
            id: "routine:" + routine.name, kind: .skill, text: routine.name, detail: routine.description, app: routine.app,
            source: .task, updated: routine.updated, locked: routine.isLocked, steps: routine.steps.count, ok: routine.ok, runs: routine.runs,
            lastMs: routine.lastMs, stale: routine.stale,
            stop: routine.lastStop.map { AppLocalization.text(LocalizedStringResource("Step \($0.step): \($0.why)")) },
            params: routine.params.keys.sorted(), otherApps: routine.otherApps, savedBy: routine.savedBy)
    }

    /// A line of Recent Updates from the store's log. The item is the one on the page when it is
    /// still there, so a tap opens it as it is now.
    private static func change(_ record: MemoryChangeRecord, routines: [Routine]) -> MemoryChange? {
        let action: MemoryChange.Action
        switch record.action {
        case MemoryChangeRecord.added: action = .added
        case MemoryChangeRecord.edited: action = .edited
        case MemoryChangeRecord.forgot: action = .forgot
        default: return nil
        }
        let item: MemoryItem
        if let note = record.note {
            item = Self.item(note)
        } else if let name = record.routineName {
            item = routines.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }.map(Self.item)
                ?? record.routine.map(Self.item).map { var i = $0; i.id = "routine:" + name; i.text = name; return i }
                ?? MemoryItem(id: "routine:" + name, kind: .skill, text: name, app: record.routineApp, source: .task, updated: record.at)
        } else {
            return nil
        }
        return MemoryChange(id: record.id, at: record.at, action: action, actor: actor(record.by), item: item,
                            previous: record.previous, undone: record.undone == true)
    }

    private static func actor(_ by: String) -> MemoryChange.Actor {
        switch by {
        case RoutineStore.owner, "import", "restore": .owner
        case "Dream": .dream
        default: .poki
        }
    }

    /// The note's `by`: "owner" from this page, "import" and "restore" from a file, "Dream" for the
    /// overnight pass, an agent's name otherwise.
    /// An agent's note is "noted in a conversation" only when that conversation was recorded with it.
    private static func source(_ by: String, heard: Bool) -> MemorySource {
        switch by {
        case RoutineStore.owner: .wrote
        case "import", "restore": .imported
        case "Dream": .dream
        default: heard ? .chat : .unknown
        }
    }
}

// MARK: Sample

extension MemoryLibrary {
    /// The design's "used for a week" library (17 items) with its Recent Updates, for screenshots and for
    /// trying the page before the store keeps app tags, locks, habits and changes.
    private func loadSample() {
        let now = Date()
        let cal = Calendar.current
        func day(_ back: Int, _ h: Int, _ m: Int) -> Date {
            let d = cal.date(byAdding: .day, value: -back, to: now) ?? now
            return cal.date(bySettingHour: h, minute: m, second: 0, of: d) ?? d
        }
        func memory(_ id: String, _ text: String, _ source: MemorySource, _ date: Date, app: String? = nil, heard: Date? = nil) -> MemoryItem {
            MemoryItem(id: id, kind: .memory, text: text, app: app, source: source, heard: heard.map { MemoryOrigin(app: app, at: $0, session: "sample-\(id)") },
                       updated: date, locked: source.isOwners)
        }
        func skill(_ id: String, _ name: String, _ about: String, app: String?, _ steps: Int, _ ok: Int, _ runs: Int, _ seconds: Int, _ date: Date,
                   stale: Bool = false, stop: String? = nil, params: [String] = []) -> MemoryItem {
            MemoryItem(id: id, kind: .skill, text: name, detail: about, app: app, source: .task, updated: date, steps: steps, ok: ok, runs: runs,
                       lastMs: seconds * 1000, stale: stale, stop: stop, params: params, savedBy: "Poki")
        }
        let starbucks = "com.starbucks.mystarbucks", meituan = "com.meituan.itakeaway", netease = "com.netease.cloudmusic"
        let didi = "com.xiaojukeji.didi", wechat = "com.tencent.xin"
        let lunch = memory("m-lunch", "午饭常点袁记云饺，鲜肉玉米口味", .dream, day(0, 2, 10), app: meituan, heard: day(1, 12, 6))
        let coffee = memory("m-coffee", "咖啡要冰美式，少冰", .chat, day(0, 14, 2), app: starbucks, heard: day(0, 14, 2))
        let music = memory("m-music", "听歌一般用网易云音乐", .dream, day(0, 2, 10), heard: day(1, 22, 31))
        let lunchHabit = MemoryItem(id: "h-lunch", kind: .habit, text: "点午饭", detail: "工作日中午 12 点前后", app: meituan, source: .dream,
                                    updated: day(0, 2, 10), reason: "5 个工作日里有 4 天在 12 点前后下单",
                                    linkedSkill: "点常点的那家", linkedMemory: lunch.text)
        let lunchSkill = skill("s-lunch", "点常点的那家", "打开店铺，选上次的套餐，停在付款前", app: meituan, 8, 3, 3, 41, day(1, 12, 21), params: ["店名"])
        items = [
            music,
            memory("m-pdd", "别用拼多多买东西", .said, day(2, 20, 48)),
            memory("m-cilantro", "不吃香菜", .chat, day(3, 12, 30), heard: day(3, 12, 30)),
            memory("m-office", "公司在徐汇滨江西岸智塔", .chat, day(4, 9, 15), heard: day(4, 9, 15)),
            memory("m-mama", "妈妈在通讯录里叫「Mama」", .wrote, day(6, 21, 40)),
            coffee,
            skill("s-coffee", "下单到付款前", "选门店和饮品，停在付款页", app: starbucks, 6, 2, 2, 28, day(0, 14, 1), params: ["饮品"]),
            lunch,
            memory("m-front", "外卖送到公司前台", .chat, day(4, 12, 5), app: meituan, heard: day(4, 12, 5)),
            lunchHabit,
            lunchSkill,
            skill("s-order", "查订单到哪了", "打开最近一单，读出骑手位置和预计时间", app: meituan, 4, 2, 2, 12, day(3, 12, 40)),
            MemoryItem(id: "h-bed", kind: .habit, text: "睡前听歌", detail: "每天晚上 10 点半左右", app: netease, source: .dream, updated: day(0, 2, 10),
                       reason: "过去 7 天里有 5 天在这个时间打开", linkedSkill: "播放某位歌手"),
            skill("s-singer", "播放某位歌手", "搜索歌手，播放热门歌曲", app: netease, 3, 5, 5, 11, day(2, 22, 31), params: ["歌手"]),
            memory("m-ride", "打车只叫快车，不拼车", .card, day(2, 21, 5), app: didi),
            skill("s-message", "给某人发消息", "在聊天列表里找到联系人，输入并发送", app: wechat, 5, 3, 6, 19, day(5, 19, 2), stale: true,
                  stop: "第 4 步：找不到「发送」按钮", params: ["联系人", "内容"]),
        ]
        let forward = skill("s-forward", "转发文章给自己", "", app: wechat, 4, 1, 1, 9, day(1, 19, 40))
        func change(_ id: String, _ at: Date, _ action: MemoryChange.Action, _ actor: MemoryChange.Actor, _ item: MemoryItem, previous: String? = nil) -> MemoryChange {
            MemoryChange(id: id, at: at, action: action, actor: actor, item: item, previous: previous)
        }
        changes = [
            change("c-coffee", day(0, 14, 2), .added, .poki, coffee),
            change("c-music", day(0, 2, 10), .added, .dream, music),
            change("c-lunch", day(0, 2, 10), .edited, .dream, lunch, previous: "午饭常点老乡鸡"),
            change("c-habit", day(0, 2, 10), .added, .dream, lunchHabit),
            change("c-forward", day(1, 19, 40), .forgot, .owner, forward),
            change("c-skill", day(1, 12, 21), .added, .poki, lunchSkill),
            change("c-temple", day(1, 2, 10), .forgot, .dream, memory("m-temple", "周末常去龙华寺", .dream, day(1, 2, 10))),
            change("c-ride", day(2, 21, 5), .edited, .owner, memory("m-ride", "打车只叫快车，不拼车", .card, day(2, 21, 5), app: didi), previous: "打车常选快车"),
            change("c-pdd", day(2, 20, 48), .added, .owner, memory("m-pdd", "别用拼多多买东西", .said, day(2, 20, 48))),
        ]
        unread = true
    }
}
