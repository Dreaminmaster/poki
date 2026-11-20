import Foundation
#if canImport(NaturalLanguage)
import NaturalLanguage
#endif

// Skills and notes: the agent's memory library, kept on the phone and shared by every agent that
// drives it (Poki's own chat and any MCP client over the relay).
//
// A task's `do` actions are recorded as they are sent, each target as what it is (role, label,
// identifier, and where it was) rather than its number, which changes from read to read. A recorded
// task saved under a name is a skill; `do {run: "name"}` replays it in one call. Each step waits for
// its target to be on screen, acts only on a single match, and stops at the first screen that differs,
// so a skill never taps the wrong thing: the agent goes on from the read the stop answers with.
// A skill keeps its runs, so one that keeps stopping is marked stale and no longer offered.
//
// Notes are short facts the agent or the owner saves ("Mom is the contact Mama"). Both live in one
// JSON file in the app's own storage; a copy in Documents/AgentBackup is what Poki Setup backs up.
// Typed text is a parameter of the skill; text typed into a password field is never stored.
//
// The owner can lock a note or a skill on the Memory page: no agent changes, replaces or forgets a
// locked one, and the caps never drop it. Every addition, change and forget is logged (the page's
// Recent Updates), and a change can be undone; a forgotten item is kept in its log entry so undo puts
// it back exactly. Fields added after the first release are optional, so a file written before them
// opens with everything in it.

/// What a step acts on, as it was found when the step was recorded.
public struct SkillTarget: Codable, Equatable, Sendable {
    public var type: String
    public var label: String?
    public var identifier: String?
    /// The element's centre when recorded: picks one of several matches that are otherwise alike.
    public var x: Double
    public var y: Double

    /// A path's target: any element that reads `label`, whatever its type.
    static let anyType = "*"

    /// A target named by its text alone (a path's step): no recorded place.
    init(type: String, label: String) {
        self.type = type
        self.label = label
        identifier = nil
        x = -1
        y = -1
    }

    /// A target the agent described and did not name ({tap: {find: "the newest message"}}): no text
    /// matches it, and the decider picks the element that fits from the screen.
    static let describedType = "?"
    init(described: String) { self.init(type: Self.describedType, label: described) }
    var isDescribed: Bool { type == Self.describedType }

    /// Whether the target was recorded at a place on the screen.
    var hasPlace: Bool { x >= 0 && y >= 0 }

    init(_ e: Element) {
        type = e.type
        label = e.label.flatMap { $0.isEmpty ? nil : $0 }
        identifier = e.identifier.flatMap { $0.isEmpty ? nil : $0 }
        let c = e.frame.centre
        x = (c.x * 10).rounded() / 10
        y = (c.y * 10).rounded() / 10
    }

    public init(type: String, label: String? = nil, identifier: String? = nil, x: Double, y: Double) {
        self.type = type
        self.label = label
        self.identifier = identifier
        self.x = x
        self.y = y
    }

    public var describe: String { isDescribed ? "the element described as \"\(label ?? "")\"" : type == Self.anyType ? "\"\(label ?? identifier ?? "")\"" : "\(type) \"\(label ?? identifier ?? "")\"" }

    func matches(_ e: Element) -> Bool {
        if isDescribed { return false }
        if type == Self.anyType {
            // By its text, as written or in another case; a container is never the thing to tap.
            guard !e.fromPicture, !Computer.containers.contains(e.type), let label, !label.isEmpty else { return false }
            return e.label?.caseInsensitiveCompare(label) == .orderedSame || e.identifier?.caseInsensitiveCompare(label) == .orderedSame
        }
        guard !e.fromPicture, e.type == type else { return false }
        if let identifier, e.identifier == identifier { return label == nil || e.label == label }
        return (e.label.flatMap { $0.isEmpty ? nil : $0 }) == label && (identifier == nil || e.identifier == nil || e.identifier == identifier)
    }
}

public typealias RoutineTarget = SkillTarget

/// One recorded action. `action` is the `do` action with its element number taken out; `target` is
/// what the number pointed at. A type's text is `{{name}}` of a parameter.
public struct SkillStep: Codable, Equatable, Sendable {
    public var action: JSON
    public var target: SkillTarget?
    /// The app in front when the step was sent.
    public var app: String?
    /// A type into a password field: the text was not kept, so a run stops here for the agent.
    public var secret: Bool?
    /// Why the step is taken, in the agent's words ({tap: 4, intent: "open the About page"}): what a
    /// fix is decided from when the target is not where it was.
    public var intent: String? = nil
    /// Other forms the target took in a run that worked (a renamed button): matched like the target.
    public var also: [RoutineTarget]? = nil
    /// What was in the way of this step before and was closed (a prompt's Not Now): when the target is
    /// missing and one of these is on screen alone, it is closed again without asking anything.
    public var clears: [RoutineTarget]? = nil
    /// What should be true of the screen once the step is done ({tap: "Wi-Fi", check: "the Wi-Fi page
    /// is open"}): the decider answers yes or no, and a clear no stops the run there.
    public var check: String? = nil
    /// Texts that must be on screen once the step is done ({tap: "Wi-Fi", expect: "Networks"}): read
    /// from the tree with no model; the run stops there when one does not appear.
    public var expect: [String]? = nil
    /// A step for something that is only sometimes there ({tap: "Not Now", optional: true}): when its
    /// target is not on a screen that holds still, the step is left out and the run goes on.
    public var optional: Bool? = nil

    public init(action: JSON, target: SkillTarget? = nil, app: String? = nil, secret: Bool? = nil, intent: String? = nil, check: String? = nil, expect: [String]? = nil, optional: Bool? = nil) {
        self.intent = intent
        self.check = check
        self.action = action
        self.target = target
        self.app = app
        self.secret = secret
        self.expect = expect
        self.optional = optional
    }
}

public typealias RoutineStep = SkillStep

public struct SkillStop: Codable, Equatable, Sendable {
    public var step: Int
    public var why: String
    public var at: Date

    public init(step: Int, why: String, at: Date) {
        self.step = step
        self.why = why
        self.at = at
    }
}

public typealias RoutineStop = SkillStop

public struct Skill: Codable, Equatable, Sendable {
    public var name: String
    public var description: String
    /// The last app operated by the skill, used to group it in Memory.
    public var app: String?
    public var steps: [SkillStep]
    /// Parameters and the values they were recorded with: `{{text_1}}` in a type.
    public var params: [String: String]
    /// Texts that must be on screen when the skill has run (its end check).
    public var expect: [String]
    /// Labels whose values the run reads off the last screen (a learned readout).
    public var read: [String]
    public var runs: Int
    public var ok: Int
    /// Runs that stopped in a row; two or more mark the skill stale.
    public var failuresInARow: Int
    public var lastStop: SkillStop?
    public var lastMs: Int?
    /// Steps fixed on the way in all its runs (a popup closed, a renamed target found).
    public var fixes: Int? = nil
    /// Texts of controls that may be closed when they are in the way of a step (a path's
    /// dismiss: ["Not Now", "Later"]): written ahead by the agent, applied with no model.
    public var dismiss: [String]? = nil
    public var savedBy: String
    public var created: Date
    public var updated: Date
    /// Locked by the owner: no agent saves over it, edits, renames or forgets it.
    public var locked: Bool? = nil

    public init(
        name: String,
        description: String,
        app: String?,
        steps: [SkillStep],
        params: [String: String],
        expect: [String],
        read: [String],
        runs: Int,
        ok: Int,
        failuresInARow: Int,
        lastStop: SkillStop?,
        lastMs: Int?,
        dismiss: [String]? = nil,
        savedBy: String,
        created: Date,
        updated: Date,
        locked: Bool? = nil
    ) {
        self.name = name
        self.description = description
        self.app = app
        self.steps = steps
        self.params = params
        self.expect = expect
        self.read = read
        self.runs = runs
        self.ok = ok
        self.failuresInARow = failuresInARow
        self.lastStop = lastStop
        self.lastMs = lastMs
        self.dismiss = dismiss
        self.savedBy = savedBy
        self.created = created
        self.updated = updated
        self.locked = locked
    }

    public var stale: Bool { failuresInARow >= 2 }
    public var isLocked: Bool { locked == true }
    public var summary: String {
        "\(name): \(description.isEmpty ? "" : description + "; ")\(app.map { "in \($0), " } ?? "")\(steps.count) steps, \(runs) runs, \(ok) ok\((fixes ?? 0) > 0 ? ", \(fixes ?? 0) fixed on the way" : "")\(stale ? ", STALE (stopped \(failuresInARow) times in a row\(lastStop.map { " at step \($0.step): \($0.why)" } ?? ""))" : "")\(params.isEmpty ? "" : ", with: " + params.keys.sorted().map { "\($0) (recorded \"\(params[$0]!.prefix(30))\")" }.joined(separator: ", "))"
    }

    var briefLine: String {
        let detail = description.isEmpty ? "" : ": \(description)"
        let inApp = app.map { description.isEmpty ? ": in \($0)" : " (in \($0))" } ?? ""
        let withParams = params.isEmpty ? "" : ", with: " + params.keys.sorted().map { "\($0) (recorded \"\(params[$0]!.prefix(30))\")" }.joined(separator: ", ")
        return "\(name)\(detail)\(inApp)\(withParams)"
    }

    func migrated() -> Skill {
        var copy = self
        copy.app = Self.inferredApp(from: steps) ?? Self.normalizedApp(app)
        return copy
    }

    public var otherApps: [String] {
        var seen = Set<String>()
        return steps.compactMap(Self.operatedApp).filter { $0 != app && seen.insert($0).inserted }
    }

    var startingApp: String? { Self.normalizedApp(steps.first?.app) ?? app }

    private static func normalizedApp(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              trimmed.caseInsensitiveCompare("com.apple.springboard") != .orderedSame,
              !CoreConfig().isPoki(Foreground(bundleID: trimmed, name: nil)) else {
            return nil
        }
        return trimmed
    }

    static func inferredApp(from steps: [SkillStep]) -> String? {
        steps.reversed().lazy.compactMap(operatedApp).first
    }

    private static func operatedApp(_ step: SkillStep) -> String? {
        if step.action["launch"] != nil {
            let launched = step.action["launch"]?.string ?? step.action["launch"]?["bundle"]?.string
            return normalizedApp(launched)
        }
        guard step.action["wait"] == nil, step.action["wait_until"] == nil,
              step.action["button"]?.string != "home" else { return nil }
        return normalizedApp(step.app)
    }
}

public typealias Routine = Skill

public struct MemoryNote: Codable, Equatable, Sendable {
    public var id: String
    public var text: String
    public var by: String
    public var at: Date
    /// Locked by the owner: no agent changes or forgets it.
    public var locked: Bool? = nil
    /// The app it is about (the Memory page's Used In); nil: no one app.
    public var app: String? = nil
    /// The conversation Poki's chat heard it in.
    public var heard: NoteOrigin? = nil
    /// When the owner last changed it.
    public var edited: Date? = nil

    public var isLocked: Bool { locked == true }
}

/// Where a note was heard: a saved conversation, and the app in front then.
public struct NoteOrigin: Codable, Equatable, Sendable {
    public var session: String
    public var app: String?
    public init(session: String, app: String?) { self.session = session; self.app = app }
}

/// One addition, change or forget, for Recent Updates and undo.
public struct MemoryChangeRecord: Codable, Equatable, Sendable {
    /// "added", "edited" or "forgot" (a string, so a later kind never makes the file unreadable).
    public var action: String
    public var id: String
    public var at: Date
    /// "owner", or the agent's name ("Poki", an MCP client's).
    public var by: String
    /// The note after the change, or as it was when forgotten.
    public var note: MemoryNote?
    /// A routine's name after the change (and `app`); `routine` is the whole routine as it was before
    /// a forget or a change, to put back.
    public var routineName: String?
    public var routineApp: String?
    public var routine: Skill?
    /// An edit's text, or a rename's name, before.
    public var previous: String?
    /// The note as it was before an edit (its app, source and lock too), to put back.
    public var before: MemoryNote?
    /// A whole page written at once (`writePage`): the page after, and as it was before (nil: it is new).
    public var page: MemoryPage?
    public var pageBefore: MemoryPage?
    public var undone: Bool?

    public static let added = "added", edited = "edited", forgot = "forgot"
}

/// One skill run, for the maintainers' log bundle.
public struct SkillRunLog: Codable, Equatable, Sendable {
    public var skill: String
    public var at: Date
    public var ms: Int
    public var outcome: String
    public var steps: [String]
    /// What was fixed on the way, when anything was.
    public var fixes: [String]? = nil

    public var routine: String {
        get { skill }
        set { skill = newValue }
    }

    public init(skill: String, at: Date, ms: Int, outcome: String, steps: [String], fixes: [String]? = nil) {
        self.skill = skill
        self.at = at
        self.ms = ms
        self.outcome = outcome
        self.steps = steps
        self.fixes = fixes
    }

    public init(routine: String, at: Date, ms: Int, outcome: String, steps: [String]) {
        self.init(skill: routine, at: at, ms: ms, outcome: outcome, steps: steps)
    }

    private enum CodingKeys: String, CodingKey {
        case skill, routine, at, ms, outcome, steps, fixes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        skill = try c.decodeIfPresent(String.self, forKey: .skill) ?? c.decode(String.self, forKey: .routine)
        at = try c.decode(Date.self, forKey: .at)
        ms = try c.decode(Int.self, forKey: .ms)
        outcome = try c.decode(String.self, forKey: .outcome)
        steps = try c.decode([String].self, forKey: .steps)
        fixes = try c.decodeIfPresent([String].self, forKey: .fixes)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(skill, forKey: .skill)
        try c.encode(at, forKey: .at)
        try c.encode(ms, forKey: .ms)
        try c.encode(outcome, forKey: .outcome)
        try c.encode(steps, forKey: .steps)
        try c.encodeIfPresent(fixes, forKey: .fixes)
    }
}

public typealias RoutineRunLog = SkillRunLog

/// The file: skills, memory pages and the latest runs. Reads both v1 (`routines`) and v2 (`skills`),
/// and a file from before pages (a flat `notes` list), whose notes become the lines of their pages.
struct MemoryFile: Codable {
    var schema = SkillStore.schema
    var exported: Date?
    var skills: [Skill] = []
    /// The memory: one page per area, About You (no app) and each app.
    var pages: [MemoryPage] = []
    /// Every page's lines in page order: what the notes were. Changing it files each line under its
    /// app's page, keeping the pages' own summary, order and lock.
    var notes: [MemoryNote] {
        get { pages.flatMap(\.lines) }
        set { pages = MemoryPage.regroup(newValue, into: pages) }
    }
    var runs: [SkillRunLog] = []
    /// What the app adds to a backup (its saved sessions), opaque here.
    var extras: [String: JSON]?
    /// The latest changes, newest first. Kept on the phone only: an export leaves them out, since a
    /// forgotten note's text lives on in its entry until it falls off the end.
    var changes: [MemoryChangeRecord]? = nil

    init(
        schema: String = SkillStore.schema,
        exported: Date? = nil,
        skills: [Skill] = [],
        notes: [MemoryNote] = [],
        runs: [SkillRunLog] = [],
        extras: [String: JSON]? = nil,
        changes: [MemoryChangeRecord]? = nil
    ) {
        self.schema = schema
        self.exported = exported
        self.skills = skills
        self.pages = MemoryPage.regroup(notes, into: [])
        self.runs = runs
        self.extras = extras
        self.changes = changes
    }

    private enum CodingKeys: String, CodingKey {
        case schema, exported, skills, routines, pages, notes, runs, extras, changes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decodeIfPresent(String.self, forKey: .schema) ?? SkillStore.schema
        exported = try c.decodeIfPresent(Date.self, forKey: .exported)
        let loaded = try c.decodeIfPresent([Skill].self, forKey: .skills)
            ?? c.decodeIfPresent([Skill].self, forKey: .routines)
            ?? []
        skills = loaded.map { $0.migrated() }
        if let saved = try c.decodeIfPresent([MemoryPage].self, forKey: .pages) {
            pages = saved
        } else {
            pages = MemoryPage.regroup(try c.decodeIfPresent([MemoryNote].self, forKey: .notes) ?? [], into: [])
        }
        runs = try c.decodeIfPresent([SkillRunLog].self, forKey: .runs) ?? []
        extras = try c.decodeIfPresent([String: JSON].self, forKey: .extras)
        changes = try c.decodeIfPresent([MemoryChangeRecord].self, forKey: .changes)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schema, forKey: .schema)
        try c.encodeIfPresent(exported, forKey: .exported)
        try c.encode(skills, forKey: .skills)
        try c.encode(pages, forKey: .pages)
        // The flat list too, for a Poki or Poki Setup from before pages: it still reads every line.
        try c.encode(notes, forKey: .notes)
        try c.encode(runs, forKey: .runs)
        try c.encodeIfPresent(extras, forKey: .extras)
        try c.encodeIfPresent(changes, forKey: .changes)
    }
}

/// The agent's memory library: thread-safe, saved to one file after every change.
public final class SkillStore: @unchecked Sendable {
    public static let schema = "poki.agent-backup/2"
    static let supportedSchemas: Set<String> = ["poki.agent-backup/1", "poki.agent-backup/2"]
    public static let backupName = "poki-agent-backup.json"
    static let maxNotes = 50, maxSkills = 200, maxRuns = 50, maxNoteLength = 300, maxChanges = 100
    /// Who the Memory page writes as.
    public static let owner = "owner"
    /// The names that are not an agent's: the owner, a file the owner imported or restored, and Dream.
    static func isReserved(_ name: String) -> Bool { [owner, "import", "restore", "dream"].contains(name.lowercased()) }

    private let lock = NSLock()
    private var file = MemoryFile()
    /// Where the memory is kept (nil: in memory only, as in tests).
    public let url: URL?
    /// Where a copy goes after every change, for Poki Setup's backup (Documents/AgentBackup).
    public let backupDirectory: URL?
    private var lastBackupHash: String?

    public init(url: URL?, backupDirectory: URL? = nil) {
        self.url = url
        self.backupDirectory = backupDirectory
        if let url, let data = try? Data(contentsOf: url) {
            if let saved = try? Self.decoder.decode(MemoryFile.self, from: data) {
                file = saved
            } else {
                // A file this version cannot read is set aside, not written over with an empty memory.
                let aside = url.deletingPathExtension().appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970)).json")
                try? FileManager.default.copyItem(at: url, to: aside)
            }
        }
        if let backupDirectory { lastBackupHash = try? String(contentsOf: backupDirectory.appendingPathComponent(".last-written"), encoding: .utf8) }
    }

    /// The shared memory of the app (Application Support/Poki/agent-memory.json, and its backup copy
    /// in Documents/AgentBackup). The app may replace it before PokiCore starts.
    public static var shared: SkillStore = {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("Poki", isDirectory: true)
        let documents = fm.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("AgentBackup", isDirectory: true)
        #if os(iOS)
        return SkillStore(url: support?.appendingPathComponent("agent-memory.json"), backupDirectory: documents)
        #else
        return SkillStore(url: nil)
        #endif
    }()

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    func withFile<T>(_ change: Bool = false, _ body: (inout MemoryFile) throws -> T) rethrows -> T {
        lock.lock()
        let result: T
        do { result = try body(&file) } catch { lock.unlock(); throw error }
        if change { try? persist(file) }
        lock.unlock()
        if change { onChange?() }
        return result
    }

    /// Notified after every change (the app's Memory page).
    public var onChange: (@Sendable () -> Void)?

    private func persist(_ snapshot: MemoryFile) throws {
        if let url {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            var diskSnapshot = snapshot
            diskSnapshot.schema = Self.schema
            try Self.encoder.encode(diskSnapshot).write(to: url, options: .atomic)
        }
        if let backupDirectory, let data = try? Self.backupData(snapshot) {
            try? FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
            let target = backupDirectory.appendingPathComponent(Self.backupName)
            try? data.write(to: target, options: .atomic)
            let hash = Self.hash(data)
            lastBackupHash = hash
            try? hash.write(to: backupDirectory.appendingPathComponent(".last-written"), atomically: true, encoding: .utf8)
        }
    }

    func saveTaskMemories(_ writes: [TaskMemoryWrite], apply: (SkillStore, TaskMemoryWrite) -> Bool) -> [Int] {
        var committed = false
        let unsaved = withFile { file in
            let staged = SkillStore(url: nil)
            staged.file = file
            let rejected = writes.indices.filter { !apply(staged, writes[$0]) }
            guard !rejected.contains(where: { !writes[$0].optional }) else { return Array(writes.indices) }
            guard rejected.count < writes.count else { return rejected }
            do {
                try persist(staged.file)
            } catch {
                return Array(writes.indices)
            }
            file = staged.file
            committed = true
            return rejected
        }
        if committed { onChange?() }
        return unsaved
    }

    static func hash(_ data: Data) -> String {
        // FNV-1a: only to tell our own copy from one put there by Poki Setup.
        var h: UInt64 = 0xcbf29ce484222325
        for b in data { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(h, radix: 16)
    }

    /// A backup file Poki Setup put in Documents/AgentBackup since the app last wrote it is merged in.
    /// Returns what was imported, or nil when there was nothing new.
    @discardableResult
    public func importRestoredBackup() -> String? {
        guard let backupDirectory else { return nil }
        let target = backupDirectory.appendingPathComponent(Self.backupName)
        let restored: Data? = withFile { _ in
            guard let data = try? Data(contentsOf: target), Self.hash(data) != lastBackupHash else { return nil }
            return data
        }
        guard let data = restored else { return nil }
        return try? importData(data, by: "restore")
    }

    // MARK: Reading

    public var skills: [Skill] { withFile { $0.skills } }
    public var usableSkills: [Skill] { skills.filter { !$0.stale } }
    public var routines: [Skill] { skills }
    public var notes: [MemoryNote] { withFile { $0.notes } }
    /// The latest changes, newest first.
    public var changes: [MemoryChangeRecord] { withFile { $0.changes ?? [] } }
    public func note(_ idOrText: String) -> MemoryNote? {
        withFile { f in f.notes.first { $0.id == idOrText || $0.text.caseInsensitiveCompare(idOrText) == .orderedSame } }
    }
    public var runLog: [SkillRunLog] { withFile { $0.runs } }

    public func skill(named name: String) -> Skill? {
        withFile { f in f.skills.first { $0.name.caseInsensitiveCompare(name) == .orderedSame } }
    }

    public func routine(named name: String) -> Skill? { skill(named: name) }

    // MARK: Changing

    /// Saves a skill, over one with the same name unless that one is locked and this is not the
    /// owner's. False when it was not saved.
    @discardableResult
    public func save(_ skill: Skill) -> Bool {
        withFile(true) { f in
            var s = skill.migrated()
            if let i = f.skills.firstIndex(where: { $0.name.caseInsensitiveCompare(s.name) == .orderedSame }) {
                let old = f.skills[i]
                guard !old.isLocked || skill.savedBy == Self.owner else { return false }
                s.created = old.created
                s.locked = old.locked
                if s.app == nil { s.app = old.app }
                // A skill saved again after it stopped is the path that worked: its record starts over.
                if old.steps == s.steps, !old.stale { s.runs = old.runs; s.ok = old.ok; s.failuresInARow = old.failuresInARow; s.lastStop = old.lastStop }
                f.skills[i] = s
                Self.log(&f, MemoryChangeRecord(action: MemoryChangeRecord.edited, id: Self.newID(), at: Date(), by: skill.savedBy,
                                                routineName: s.name, routineApp: s.app, routine: old))
            } else {
                f.skills.append(s)
                Self.trim(&f.skills, to: Self.maxSkills, keeping: \.isLocked)
                Self.log(&f, MemoryChangeRecord(action: MemoryChangeRecord.added, id: Self.newID(), at: Date(), by: skill.savedBy,
                                                routineName: s.name, routineApp: s.app))
            }
            return true
        }
    }

    /// Forgets a routine; an agent cannot forget a locked one. The log keeps it for undo.
    @discardableResult
    public func forget(_ name: String, by: String = SkillStore.owner) -> Bool {
        withFile(true) { f in
            guard let i = f.skills.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }),
                  !f.skills[i].isLocked || by == Self.owner else { return false }
            let old = f.skills.remove(at: i)
            Self.log(&f, MemoryChangeRecord(action: MemoryChangeRecord.forgot, id: Self.newID(), at: Date(), by: by,
                                            routineName: old.name, routineApp: old.app, routine: old))
            return true
        }
    }

    /// Renames a routine; an agent cannot rename a locked one, and the owner's rename locks it.
    @discardableResult
    public func rename(_ name: String, to new: String, by: String = SkillStore.owner) -> Bool {
        withFile(true) { f in
            guard let i = f.skills.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }),
                  !f.skills[i].isLocked || by == Self.owner,
                  // Not onto another routine's name, which would hide that one.
                  !f.skills.indices.contains(where: { $0 != i && f.skills[$0].name.caseInsensitiveCompare(new) == .orderedSame }) else { return false }
            let old = f.skills[i]
            f.skills[i].name = new
            f.skills[i].updated = Date()
            if by == Self.owner { f.skills[i].locked = true }
            Self.log(&f, MemoryChangeRecord(action: MemoryChangeRecord.edited, id: Self.newID(), at: Date(), by: by,
                                            routineName: new, routineApp: old.app, routine: old, previous: old.name))
            return true
        }
    }

    /// Changes a routine in place. With `by`, it is an edit: logged, and refused for an agent when
    /// the routine is locked. Without, it is the run's own bookkeeping (counts, the last stop).
    @discardableResult
    public func update(_ name: String, by: String? = nil, _ change: (inout Skill) -> Void) -> Bool {
        withFile(true) { f in
            guard let i = f.skills.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { return false }
            guard let by else { change(&f.skills[i]); return true }
            guard !f.skills[i].isLocked || by == Self.owner else { return false }
            let old = f.skills[i]
            change(&f.skills[i])
            Self.log(&f, MemoryChangeRecord(action: MemoryChangeRecord.edited, id: Self.newID(), at: Date(), by: by,
                                            routineName: f.skills[i].name, routineApp: f.skills[i].app, routine: old))
            return true
        }
    }

    /// Locks or unlocks a note (by id) or a routine (by name). Only the Memory page calls it.
    public func setLocked(_ idOrName: String, _ locked: Bool) {
        withFile(true) { f in
            if let i = f.notes.firstIndex(where: { $0.id == idOrName }) { f.notes[i].locked = locked ? true : nil }
            else if let i = f.skills.firstIndex(where: { $0.name.caseInsensitiveCompare(idOrName) == .orderedSame }) { f.skills[i].locked = locked ? true : nil }
        }
    }

    /// Keeps a note. The same text again answers the note already kept. `heard` is the conversation
    /// it came up in; the owner's own notes come locked.
    @discardableResult
    public func remember(_ text: String, by: String, app: String? = nil, heard: NoteOrigin? = nil, locked: Bool = false) -> MemoryNote? {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        return withFile(true) { f in
            if let same = f.notes.first(where: { $0.text.caseInsensitiveCompare(clean) == .orderedSame }) { return same }
            let note = MemoryNote(id: String(UUID().uuidString.prefix(8)).lowercased(), text: String(clean.prefix(Self.maxNoteLength)), by: by, at: Date(),
                                  locked: locked ? true : nil, app: app, heard: heard)
            f.notes.append(note)
            Self.trim(&f.notes, to: Self.maxNotes, keeping: \.isLocked)
            Self.log(&f, MemoryChangeRecord(action: MemoryChangeRecord.added, id: Self.newID(), at: Date(), by: by, note: note))
            return note
        }
    }

    /// Forgets a note; an agent cannot forget a locked one. The log keeps it for undo.
    @discardableResult
    public func forgetNote(_ idOrText: String, by: String = SkillStore.owner) -> Bool {
        withFile(true) { f in
            guard let i = f.notes.firstIndex(where: { $0.id == idOrText || $0.text.caseInsensitiveCompare(idOrText) == .orderedSame }),
                  !f.notes[i].isLocked || by == Self.owner else { return false }
            let old = f.notes.remove(at: i)
            Self.log(&f, MemoryChangeRecord(action: MemoryChangeRecord.forgot, id: Self.newID(), at: Date(), by: by, note: old))
            return true
        }
    }

    /// The owner's change to a note: its text and app. It locks, and no longer links to where it was
    /// heard, since the words are now the owner's.
    public func editNote(_ id: String, text: String, app: String?? = .none) {
        withFile(true) { f in
            guard let i = f.notes.firstIndex(where: { $0.id == id }) else { return }
            let old = f.notes[i]
            f.notes[i].text = String(text.prefix(Self.maxNoteLength))
            if case .some(let app) = app { f.notes[i].app = app }
            f.notes[i].locked = true
            f.notes[i].heard = nil
            f.notes[i].edited = Date()
            Self.log(&f, MemoryChangeRecord(action: MemoryChangeRecord.edited, id: Self.newID(), at: Date(), by: Self.owner, note: f.notes[i],
                                            previous: old.text == f.notes[i].text ? nil : old.text, before: old))
        }
    }

    /// Puts back what a change took away or changed, and marks it undone. Undoing an agent's change
    /// locks the item, so the agent does not make it again. False when there is nothing to put back
    /// (already undone, or the item is gone or its place taken).
    @discardableResult
    public func undo(_ changeID: String) -> Bool {
        withFile(true) { f in
            guard var changes = f.changes, let c = changes.firstIndex(where: { $0.id == changeID }), changes[c].undone != true else { return false }
            let change = changes[c]
            let locks: Bool? = change.by == Self.owner ? nil : true
            func routineIndex(_ name: String?) -> Int? { name.flatMap { n in f.skills.firstIndex { $0.name.caseInsensitiveCompare(n) == .orderedSame } } }
            if change.page != nil || change.pageBefore != nil {
                guard Self.undoPage(change, in: &f) else { return false }
                changes[c].undone = true
                f.changes = changes
                return true
            }
            switch (change.action, change.note, change.routine) {
            case (MemoryChangeRecord.forgot, var note?, _):
                guard !f.notes.contains(where: { $0.id == note.id || $0.text.caseInsensitiveCompare(note.text) == .orderedSame }) else { return false }
                if let locks { note.locked = locks }
                f.notes.append(note)
            case (MemoryChangeRecord.forgot, nil, var routine?):
                guard routineIndex(routine.name) == nil else { return false }
                if let locks { routine.locked = locks }
                f.skills.append(routine.migrated())
            case (MemoryChangeRecord.added, let note?, _):
                guard let i = f.notes.firstIndex(where: { $0.id == note.id }) else { return false }
                f.notes.remove(at: i)
            case (MemoryChangeRecord.added, nil, _):
                guard let i = routineIndex(change.routineName) else { return false }
                f.skills.remove(at: i)
            case (MemoryChangeRecord.edited, let note?, _):
                guard let i = f.notes.firstIndex(where: { $0.id == note.id }) else { return false }
                if var old = change.before {
                    if let locks { old.locked = locks }
                    f.notes[i] = old
                } else {
                    // An entry with only the text before (an agent's edit).
                    guard let previous = change.previous else { return false }
                    f.notes[i].text = previous
                    if let locks { f.notes[i].locked = locks }
                }
            case (MemoryChangeRecord.edited, nil, var routine?):
                guard let i = routineIndex(change.routineName) else { return false }
                routine.locked = locks ?? f.skills[i].locked
                f.skills[i] = routine.migrated()
            default:
                return false
            }
            changes[c].undone = true
            f.changes = changes
            return true
        }
    }

    static func log(_ f: inout MemoryFile, _ change: MemoryChangeRecord) {
        var changes = f.changes ?? []
        changes.insert(change, at: 0)
        if changes.count > maxChanges { changes.removeLast(changes.count - maxChanges) }
        f.changes = changes
    }

    static func newID() -> String { UUID().uuidString.lowercased() }

    /// Drops the oldest unlocked items over the cap; locked ones are never dropped.
    private static func trim<T>(_ items: inout [T], to cap: Int, keeping kept: (T) -> Bool) {
        while items.count > cap, let i = items.firstIndex(where: { !kept($0) }) { items.remove(at: i) }
    }

    func logRun(_ log: SkillRunLog) {
        withFile(true) { f in
            f.runs.append(log)
            if f.runs.count > Self.maxRuns { f.runs.removeFirst(f.runs.count - Self.maxRuns) }
        }
    }

    public func clearAll() { withFile(true) { $0 = MemoryFile() } }

    // MARK: Export and import

    /// What the app adds to a backup and takes back from one (its saved chat sessions). Off unless set.
    public var extrasProvider: (@Sendable () -> [String: JSON])?
    public var extrasRestorer: (@Sendable ([String: JSON]) -> Void)?

    /// The backup file: skills, notes and the run log; with `includeExtras`, what the app adds.
    public func exportData(includeExtras: Bool = false) throws -> Data {
        let snapshot = withFile { $0 }
        return try Self.backupData(snapshot, extras: includeExtras ? extrasProvider?() : nil)
    }

    private static func backupData(_ file: MemoryFile, extras: [String: JSON]? = nil) throws -> Data {
        var snapshot = file
        snapshot.schema = Self.schema
        snapshot.exported = Date()
        snapshot.extras = extras
        snapshot.changes = nil
        return try Self.encoder.encode(snapshot)
    }

    /// Merges a backup in: a skill with the same name is replaced when the incoming one is newer;
    /// notes are added unless the same text is there. Accepts both v1 and v2 backups.
    @discardableResult
    public func importData(_ data: Data, by: String) throws -> String {
        let incoming: MemoryFile
        do { incoming = try Self.decoder.decode(MemoryFile.self, from: data) }
        catch { throw ImportError("not a Poki agent backup: \(error)") }
        guard incoming.schema.hasPrefix("poki.agent-backup/") else { throw ImportError("not a Poki agent backup (schema \(incoming.schema))") }
        guard Self.supportedSchemas.contains(incoming.schema) else { throw ImportError("a backup of a newer Poki (\(incoming.schema)); update Poki to import it") }
        var added = 0, replaced = 0, kept = 0, notes = 0
        // An agent's import brings what it says, but not the owner's say: nothing comes locked, and
        // nothing claims to be the owner's, an import's or Dream's. A note's "edited" and "heard"
        // are the owner's change and one of our own conversations, so they are not carried either.
        let agent = !Self.isReserved(by)
        withFile(true) { f in
            for var r in incoming.skills where !r.name.isEmpty {
                r = r.migrated()
                if agent { r.locked = nil; if Self.isReserved(r.savedBy) { r.savedBy = by } }
                if let i = f.skills.firstIndex(where: { $0.name.caseInsensitiveCompare(r.name) == .orderedSame }) {
                    // The owner locked ours: a newer copy from elsewhere does not replace it.
                    if r.updated > f.skills[i].updated, !f.skills[i].isLocked { f.skills[i] = r; replaced += 1 } else { kept += 1 }
                } else { f.skills.append(r); added += 1 }
            }
            for var n in incoming.notes where !f.notes.contains(where: { $0.text.caseInsensitiveCompare(n.text) == .orderedSame }) {
                if agent { n.locked = nil; n.edited = nil; n.heard = nil; if Self.isReserved(n.by) { n.by = by } }
                // Another note's id would make forgetting or undoing by id reach the wrong one.
                if f.notes.contains(where: { $0.id == n.id }) { n.id = String(UUID().uuidString.prefix(8)).lowercased() }
                f.notes.append(n); notes += 1
            }
            Self.trim(&f.notes, to: Self.maxNotes, keeping: \.isLocked)
        }
        if let extras = incoming.extras, !extras.isEmpty { extrasRestorer?(extras) }
        return "imported: \(added) skills added, \(replaced) replaced by newer ones, \(kept) kept (ours were newer), \(notes) notes added\(incoming.extras?.isEmpty == false ? ", and the app's saved sessions" : "")"
    }

    public struct ImportError: Error, CustomStringConvertible {
        public let description: String
        init(_ d: String) { description = d }
    }

    /// The maintainers' bundle: every skill with its record, the latest runs and the notes' count.
    /// No screenshots and no typed text beyond what the skills keep as parameters.
    public func debugBundle(extra: [String: JSON] = [:]) -> Data {
        let snapshot = withFile { $0 }
        var bundle: [String: JSON] = extra
        bundle["schema"] = "poki.agent-debug/2"
        bundle["made"] = .string(ISO8601DateFormatter().string(from: Date()))
        bundle["skills"] = .array(snapshot.skills.map { r in
            ["name": .string(r.name), "app": r.app.map(JSON.string) ?? .null, "steps": .array(r.steps.map { s in
                ["action": s.action, "target": s.target.map { .string($0.describe) } ?? .null, "app": s.app.map(JSON.string) ?? .null] }),
             "runs": .number(Double(r.runs)), "ok": .number(Double(r.ok)), "stale": .bool(r.stale),
             "last_stop": r.lastStop.map { ["step": .number(Double($0.step)), "why": .string($0.why), "at": .string(ISO8601DateFormatter().string(from: $0.at))] } ?? .null,
             "last_ms": r.lastMs.map { .number(Double($0)) } ?? .null]
        })
        bundle["runs"] = .array(snapshot.runs.map { l in
            ["skill": .string(l.skill), "at": .string(ISO8601DateFormatter().string(from: l.at)), "ms": .number(Double(l.ms)), "outcome": .string(l.outcome), "steps": .array(l.steps.map(JSON.string))]
        })
        bundle["notes"] = .number(Double(snapshot.notes.count))
        return JSON.object(bundle).data()
    }

    // MARK: For the agent

    /// The brief goes into every task's prompt, so it stays this short (in characters); the skills
    /// tool lists the rest.
    static let maxBriefLength = 4000

    /// Non-stale skills ranked by current app and task terms. Unrelated skills (score 0) are omitted.
    public func matchingSkills(for task: String, apps: [String] = [], limit: Int = 12) -> [Skill] {
        rankedSkills(in: withFile { $0.skills }, terms: Self.tokens(task), apps: Self.appIDs(apps))
            .prefix(limit).map(\.skill)
    }

    private static func appIDs(_ apps: [String]) -> Set<String> {
        Set(apps.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty })
    }

    private func rankedSkills(in skills: [Skill], terms: Set<String>, apps: Set<String>) -> [(skill: Skill, score: Int)] {
        skills.filter { !$0.stale }.compactMap { skill -> (skill: Skill, score: Int)? in
            let skillTokens = Self.tokens(skill.name + " " + skill.description)
            let termScore = skillTokens.intersection(terms).count * 3
            let appScore = (skill.app.map { apps.contains($0.lowercased()) } ?? false) ? 4 : 0
            let score = termScore + appScore
            return score > 0 ? (skill, score) : nil
        }.sorted { $0.score != $1.score ? $0.score > $1.score : $0.skill.updated > $1.skill.updated }
    }

    private static func inferredMemoryApp(terms: Set<String>, skills: [(skill: Skill, score: Int)], notes: [MemoryNote]) -> String? {
        var scores: [String: Int] = [:]
        func consider(_ app: String, score: Int) {
            guard score > 0 else { return }
            let id = app.lowercased()
            scores[id] = max(scores[id, default: 0], score)
        }
        for (skill, score) in skills {
            if let app = skill.app { consider(app, score: score) }
        }
        for note in notes {
            if let app = note.app { consider(app, score: tokens(note.text).intersection(terms).count * 3) }
        }
        guard let best = scores.values.max() else { return nil }
        let candidates = scores.filter { $0.value == best }
        return candidates.count == 1 ? candidates.first?.key : nil
    }

    public func brief(for task: String, app: String? = nil, apps: [String] = [], limit: Int = 12) -> String {
        taskBrief(for: task, apps: apps + (app.map { [$0] } ?? []), limit: limit).text
    }

    /// The prompt and the exact notes that fit in it.
    public struct TaskBrief: Sendable {
        public let text: String
        public let notes: [MemoryNote]
    }

    public func taskBrief(for task: String, apps: [String], limit: Int = 12) -> TaskBrief {
        let (skills, notes, pages) = withFile { ($0.skills, $0.notes, $0.pages) }
        let targetApps = Self.appIDs(apps)
        let terms = Self.tokens(task)
        let ranked = rankedSkills(in: skills, terms: terms, apps: targetApps)
        let fit = ranked.prefix(limit).map(\.skill)
        var memoryApps = targetApps
        if memoryApps.isEmpty, let inferred = Self.inferredMemoryApp(terms: terms, skills: ranked, notes: notes) {
            memoryApps.insert(inferred)
        }
        let eligible = notes.reversed().filter { note in
            note.app.map { memoryApps.contains($0.lowercased()) } ?? true
        }.prefix(20)
        var room = Self.maxBriefLength
        func section<Item>(_ header: String, _ items: [Item], within limit: Int, line: (Item) -> String) -> ([String], [Item]) {
            var left = min(room, limit) - header.count - 1
            var lines: [String] = []
            var taken: [Item] = []
            for item in items {
                let text = line(item)
                guard text.count + 1 <= left else { continue }
                lines.append(text)
                taken.append(item)
                left -= text.count + 1
            }
            guard !taken.isEmpty else { return ([], []) }
            room -= ([header] + lines).reduce(0) { $0 + $1.count + 1 }
            return ([header] + lines, taken)
        }
        let (skillLines, _) = section(
            "Saved skills: do {run: \"name\"} replays one in a single call and stops cleanly at a screen that differs, so try a skill that fits before stepping by hand (with: {text_1: \"…\"} changes what it types). The skills tool lists, shows, edits and saves them:",
            fit,
            within: Self.maxBriefLength / 2
        ) { "- \($0.briefLine)" }
        // Room for the pages' headings and the index of the other pages.
        let header = "Saved memory, one page per area (About You holds everywhere, an app's page holds in that app). Apply what is relevant and report only the IDs of lines that affected this task in finish_task:"
        let (picked, includedNotes) = section(header, Array(eligible), within: max(0, room - 400)) { "- [\($0.id)] \($0.text)" }
        var noteLines: [String] = []
        if !picked.isEmpty {
            noteLines.append(header)
            let ids = Set(includedNotes.map(\.id))
            for page in pages {
                let shown = page.lines.filter { ids.contains($0.id) }
                guard !shown.isEmpty else { continue }
                noteLines.append("\(page.title)\(page.summary.map { " (\($0))" } ?? ""):")
                noteLines += shown.map { "- [\($0.id)] \($0.text)" }
            }
        }
        let shownPages = Set(includedNotes.map { $0.app?.lowercased() ?? "" })
        let others = pages.filter { !shownPages.contains($0.app?.lowercased() ?? "") }.prefix(12)
        if !others.isEmpty {
            noteLines.append("Other memory pages (skills {action: \"page\", app} reads one): " + others.map { $0.title + ($0.summary.map { " (\($0))" } ?? "") }.joined(separator: "; "))
        }
        return TaskBrief(text: (noteLines + skillLines).joined(separator: "\n"), notes: includedNotes)
    }

    func appMemoryBrief(for app: String) -> TaskBrief {
        let notes = withFile { file in
            Array(file.notes.reversed().lazy.filter { $0.app?.lowercased() == app }.prefix(8))
        }
        let lines = notes.map { "- [\($0.id)] \($0.text)" }
        let header = "Saved memories for this app. Apply relevant memories and report IDs that affected this task in finish_task:"
        return TaskBrief(text: ([header] + lines).joined(separator: "\n"), notes: notes)
    }

    private static let englishStopwords: Set<String> = [
        "an", "and", "are", "as", "at", "be", "by", "can", "do", "for", "from", "get", "go",
        "he", "how", "if", "in", "into", "is", "it", "its", "let", "me", "my", "no", "of",
        "on", "open", "or", "our", "out", "please", "read", "run", "see", "show", "so",
        "the", "their", "them", "then", "this", "that", "to", "up", "use", "view", "we",
        "what", "when", "where", "which", "who", "with", "you", "your",
    ]

    private static let chineseStopwords: Set<String> = [
        "一下", "一个", "一些", "帮我", "给我", "替我", "看看", "看下", "查看", "查下", "查询",
        "打开", "开启", "进入", "使用", "点击", "怎么", "可以", "能否", "能不能", "现在", "今天",
        "手机", "里面", "请问", "想要", "我要", "去看看", "帮我看", "看一看",
    ]

    static func tokens(_ text: String) -> Set<String> {
        let lower = text.lowercased()
        var out: Set<String> = []

        var latin = ""
        var cjk: [Character] = []

        func flushLatin() {
            guard !latin.isEmpty else { return }
            if latin.count >= 2, !englishStopwords.contains(latin) {
                out.insert(latin)
            }
            latin.removeAll(keepingCapacity: true)
        }

        func flushCJK() {
            guard !cjk.isEmpty else { return }
            if cjk.count >= 2 {
                for i in 0..<(cjk.count - 1) {
                    let bigram = String(cjk[i...i + 1])
                    if !chineseStopwords.contains(bigram) {
                        out.insert(bigram)
                    }
                }
            }
            cjk.removeAll(keepingCapacity: true)
        }

        for ch in lower {
            let isIdeograph = ch.unicodeScalars.contains { $0.properties.isIdeographic }
            if isIdeograph {
                flushLatin()
                cjk.append(ch)
            } else if ch.isLetter || ch.isNumber {
                flushCJK()
                latin.append(ch)
            } else {
                flushLatin()
                flushCJK()
            }
        }
        flushLatin()
        flushCJK()

        #if canImport(NaturalLanguage)
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = lower
        tokenizer.enumerateTokens(in: lower.startIndex..<lower.endIndex) { range, _ in
            let word = String(lower[range])
            guard word.count >= 2 else { return true }
            let hasIdeograph = word.unicodeScalars.contains { $0.properties.isIdeographic }
            if hasIdeograph {
                if !chineseStopwords.contains(word) { out.insert(word) }
            } else if !englishStopwords.contains(word) {
                out.insert(word)
            }
            return true
        }
        #endif

        return out
    }
}

public typealias RoutineStore = SkillStore

// MARK: Recording and replay in `do`

/// A step as recorded while the task ran, with what the screen held before it (for the end check).
struct RecordedStep {
    var step: SkillStep
    var typed: String?
    var keysBefore: Set<String>
}

extension Computer {
    /// The `do` action as a skill step: element numbers become targets. nil for what is not kept
    /// (a handoff, a run, which records its own steps).
    func recordable(_ action: JSON) -> RecordedStep? {
        guard case .object(var o) = action, o["handoff"] == nil, o["run"] == nil, o["path"] == nil else { return nil }
        // Why the step is taken is kept beside it, not in the action a run sends.
        let intent = o["intent"]?.string.flatMap { $0.isEmpty ? nil : String($0.prefix(160)) }
        o["intent"] = nil
        var target: SkillTarget?
        var typed: String?
        var secret: Bool?
        func element(_ spec: JSON?) -> Element? {
            guard let spec else { return nil }
            if let n = spec.int, spec.array == nil, case .number = spec { return refs[n] }
            if case .string = spec, let n = spec.int { return refs[n] }
            if let n = spec["ref"]?.int { return refs[n] }
            return nil
        }
        func point(_ e: Element) -> JSON { let c = e.frame.centre; return [.number(c.x.rounded()), .number(c.y.rounded())] }
        for key in ["tap", "long_press"] {
            if let spec = o[key], let e = element(spec) {
                target = SkillTarget(e)
                if case .object(var inner) = spec { inner["ref"] = "@"; o[key] = .object(inner) } else { o[key] = "@" }
            }
        }
        if let text = o["type"]?.text {
            if let e = element(o["ref"]) { target = SkillTarget(e); o["ref"] = "@" }
            let hidden = describe(action).hasSuffix("(hidden)")
            if hidden { secret = true; o["type"] = "" } else { typed = text }
        }
        if case .object(var s) = o["scroll_to"], let e = element(s["ref"]) {
            s["ref"] = nil
            s["text"] = .string(e.label ?? e.text)
            o["scroll_to"] = .object(s)
        }
        if case .object(var s) = o["scroll_to"], s["in"] != nil { s["in"] = nil; o["scroll_to"] = .object(s) }
        if case .object(var s) = o["swipe"], s["in"] != nil { s["in"] = nil; o["swipe"] = .object(s) }
        if case .object(var d) = o["drag"] {
            for k in ["from", "to"] { if let e = element(d[k]) { d[k] = point(e) } }
            o["drag"] = .object(d)
        }
        if case .object(var p) = o["pinch"], let e = element(.object(p)) { p["ref"] = nil; let c = e.frame.centre; p["x"] = .number(c.x.rounded()); p["y"] = .number(c.y.rounded()); o["pinch"] = .object(p) }
        let keys = Set(listed.map(\.element.key))
        return RecordedStep(step: SkillStep(action: .object(o), target: target, app: lastForeground?.bundleID, secret: secret, intent: intent), typed: typed, keysBefore: keys)
    }

    /// The task's recorded steps as a skill (nil and why, when they cannot make one).
    func skill(named name: String, description: String, read: [String], expect: [String]?, by: String) -> (Skill?, String) {
        let recorded = trace
        guard !recorded.isEmpty else { return (nil, "nothing was recorded in this task yet: a skill is made of the do actions sent since the task began (the first look or do after a finish)") }
        var params: [String: String] = [:]
        var steps: [SkillStep] = []
        for r in recorded {
            var s = r.step
            if let text = r.typed, case .object(var o) = s.action {
                let id = params.first(where: { $0.value == text })?.key ?? "text_\(params.count + 1)"
                params[id] = text
                o["type"] = .string("{{\(id)}}")
                s.action = .object(o)
            }
            steps.append(s)
        }
        steps = Self.withoutRefocusTaps(steps)
        var checks = expect ?? []
        if expect == nil, let last = recorded.last {
            let fresh = listed.map(\.element).filter { e in
                !e.fromPicture && !e.text.isEmpty && !Self.containers.contains(e.type) && !last.keysBefore.contains(e.key) && e.text.count <= 60
                    && listed.filter({ $0.element.key == e.key }).count == 1
            }
            let preferred = fresh.filter { ["NavigationBar", "StaticText", "Heading"].contains($0.type) } + fresh.filter { !["NavigationBar", "StaticText", "Heading"].contains($0.type) }
            checks = Array(preferred.prefix(3).map { $0.label ?? $0.text })
        }
        let app = Skill.inferredApp(from: steps)
        let now = Date()
        let skill = Skill(name: name, description: description, app: app, steps: steps, params: params, expect: checks.filter { !$0.isEmpty }, read: read,
                          runs: 0, ok: 0, failuresInARow: 0, lastStop: nil, lastMs: nil, savedBy: by, created: now, updated: now)
        var notes: [String] = []
        let points = steps.filter { s in s.target == nil && (s.action["tap"]?.array != nil || s.action["long_press"]?.array != nil) }.count
        if points > 0 { notes.append("\(points) step\(points == 1 ? "" : "s") tap a point, not an element: they replay at the same point whatever is there") }
        if steps.contains(where: { $0.secret == true }) { notes.append("a password typed in it was not kept: a run stops there for you to type it") }
        if skill.expect.isEmpty { notes.append("no end check could be chosen from the last screen; give expect: [\"text\"] to add one") }
        return (skill, notes.joined(separator: "; "))
    }

    func routine(named name: String, description: String, read: [String], expect: [String]?, by: String) -> (Skill?, String) {
        skill(named: name, description: description, read: read, expect: expect, by: by)
    }

    /// Drops a redundant tap on an already-focused text field right between typing and Return.
    static func withoutRefocusTaps(_ steps: [SkillStep]) -> [SkillStep] {
        steps.indices.compactMap { i in
            let step = steps[i]
            guard step.action["tap"] != nil, let target = step.target, fieldTypes.contains(target.type),
                  i > 0, steps[i - 1].action["type"] != nil, i + 1 < steps.count, isReturn(steps[i + 1].action) else { return step }
            let typedInto = steps[i - 1].target ?? (i > 1 && steps[i - 2].action["tap"] != nil ? steps[i - 2].target : nil)
            if let typedInto, typedInto.type != target.type || typedInto.label != target.label || typedInto.identifier != target.identifier { return step }
            return nil
        }
    }

    /// `{run: "name"}` or `{run: {name, with: {text_1: "…"}}}`: replays a saved skill's steps in order,
    /// waiting for each target on screen and stopping cleanly at the first screen that differs.
    func runSkill(_ spec: JSON, until: Double, onCompleted: (@Sendable (String) -> Void)? = nil) async throws -> String {
        let name = spec.string ?? spec["name"]?.string ?? spec["skill"]?.string ?? ""
        guard let store = memory, let skill = store.skill(named: name), !skill.stale else {
            let known = memory?.usableSkills.prefix(12).map { "\"\($0.name)\"" }.joined(separator: ", ") ?? ""
            throw ActionFailure(message: "no skill named \"\(name)\"\(known.isEmpty ? " (none are saved)" : "; saved: \(known)")", delivery: .notSent)
        }
        var params = skill.params
        if case .object(let given) = spec["with"] { for (k, v) in given { if let t = v.text { params[k] = t } } }
        return try await replay(skill, params: params, store: store, until: until, onCompleted: onCompleted)
    }

    /// `{path: {goal, steps: [...]}}`: steps the agent wrote ahead for screens it has not read yet, each
    /// target named by its text. They run as a routine does, without being saved.
    func runPath(_ spec: JSON, until: Double) async throws -> String {
        let routine = try Self.pathRoutine(spec)
        // A described target is the decider's to find: without one the step could only wait and stop.
        if config.decider() == nil, let i = routine.steps.firstIndex(where: { $0.target?.isDescribed == true }) {
            throw ActionFailure(message: "path: step \(i + 1) describes its target with find, which needs a fast decision model picked in Poki's settings (Models, Fast Decisions); name the target by the text it shows, or send the step after a look; nothing was sent", delivery: .notSent)
        }
        return try await replay(routine, params: [:], store: nil, until: until)
    }

    /// A path's steps as a routine with no name. A target is the text the element shows, or
    /// {label, type?}; a point stays a point. Numbers are refused: they are the latest read's, and a
    /// path is for the screens after it.
    static func pathRoutine(_ spec: JSON) throws -> Skill {
        func refuse(_ why: String) -> ActionFailure { ActionFailure(message: "path: \(why); nothing was sent", delivery: .notSent) }
        guard let given = spec["steps"]?.array ?? spec.array, !given.isEmpty else { throw refuse("give steps: [{tap: \"text\"}, …]") }
        guard given.count <= 20 else { throw refuse("at most 20 steps") }
        func target(_ spec: JSON) throws -> SkillTarget? {
            if spec.array != nil { return nil }
            if case .string(let label) = spec, Double(label) == nil, !label.isEmpty { return SkillTarget(type: SkillTarget.anyType, label: label) }
            if case .object = spec, let described = spec["find"]?.string, !described.isEmpty { return SkillTarget(described: String(described.prefix(200))) }
            if case .object = spec, let label = spec["label"]?.string ?? spec["text"]?.string, !label.isEmpty {
                return SkillTarget(type: spec["type"]?.string ?? SkillTarget.anyType, label: label)
            }
            if case .object = spec, spec["x"] != nil, spec["y"] != nil { return nil }
            throw refuse("a target in a path is the element's text, {label, type?}, {find: \"what it is\"} or a point [x, y], not a number from an earlier read")
        }
        var steps: [SkillStep] = []
        for (i, step) in given.enumerated() {
            guard case .object(var o) = step, let kind = ActionKind(step), kind != .run, kind != .path, kind != .handoff else { throw refuse("step \(i + 1) is not an action a path can hold") }
            let intent = o["intent"]?.string
            o["intent"] = nil
            let check = o["check"]?.string.flatMap { $0.isEmpty ? nil : String($0.prefix(200)) }
            o["check"] = nil
            let expect = (o["expect"]?.array?.compactMap(\.string) ?? o["expect"]?.string.map { [$0] })?.filter { !$0.isEmpty }
            o["expect"] = nil
            let optional = o["optional"]?.bool == true
            o["optional"] = nil
            var found: SkillTarget?
            switch kind {
            case .tap, .longPress:
                if let t = try target(o[kind.rawValue] ?? .null) {
                    found = t
                    if case .object(var inner) = o[kind.rawValue] { inner["label"] = nil; inner["text"] = nil; inner["type"] = nil; inner["find"] = nil; inner["ref"] = "@"; o[kind.rawValue] = .object(inner) } else { o[kind.rawValue] = "@" }
                }
            case .type:
                if o["ref"] != nil { throw refuse("step \(i + 1): name the field with into: \"its text\", not a number") }
                if let into = o["into"] {
                    guard let t = try target(into) else { throw refuse("step \(i + 1): into is the field's text") }
                    found = t
                    o["into"] = nil
                    o["ref"] = "@"
                }
            case .scrollTo:
                if o["scroll_to"]?["ref"] != nil || o["scroll_to"]?["in"] != nil { throw refuse("step \(i + 1): scroll_to takes the text to reach") }
            case .swipe:
                // in: n names a list of the latest read; a path's swipe goes in the biggest list on its own screen.
                if o["in"] != nil || o["swipe"]?["in"] != nil { throw refuse("step \(i + 1): a swipe in a path takes a direction and a distance, not in: a number from an earlier read") }
            case .drag, .pinch:
                if Computer.refs(in: step).isEmpty == false { throw refuse("step \(i + 1) uses a number from an earlier read") }
            default: break
            }
            steps.append(SkillStep(action: .object(o), target: found, app: nil, secret: nil, intent: intent, check: check, expect: expect?.isEmpty == false ? Array(expect!.prefix(4)) : nil, optional: optional ? true : nil))
            if optional, found == nil { throw refuse("step \(i + 1): optional needs a target named by its text") }
        }
        let now = Date()
        let dismiss = (spec["dismiss"]?.array?.compactMap(\.string) ?? []).filter { !$0.isEmpty }.prefix(6)
        return Skill(name: "", description: spec["goal"]?.string ?? "", app: nil, steps: steps, params: [:], expect: spec["expect"]?.array?.compactMap(\.string) ?? [],
                       read: Array((spec["read"]?.array?.compactMap(\.string) ?? []).prefix(6)),
                       runs: 0, ok: 0, failuresInARow: 0, lastStop: nil, lastMs: nil, dismiss: dismiss.isEmpty ? nil : Array(dismiss), savedBy: "", created: now, updated: now)
    }

    /// A step in words, for the decider and the log.
    static func words(for step: RoutineStep) -> String {
        let kind = ActionKind(step.action)?.rawValue ?? "step"
        var text = step.target.map { "\(kind) \($0.describe)" } ?? step.action.serialized()
        if let intent = step.intent, !intent.isEmpty { text += " (\(intent))" }
        return String(text.prefix(140))
    }

    /// The steps of a saved routine (`store` given) or of a path, in order. Each step waits for its
    /// target and acts only on a single match. A step whose target is missing is fixed on the way when
    /// that can be decided (see Repair.swift), and stops the run otherwise, with nothing sent for it;
    /// a path may first close what it said may be closed (its `dismiss`).
    func replay(_ skill: Skill, params: [String: String], store: SkillStore?, until: Double, onCompleted: (@Sendable (String) -> Void)? = nil) async throws -> String {
        let saved = store != nil
        let title = saved ? "run \"\(skill.name)\"" : "path"
        let started = now()
        var log: [String] = []
        var done = 0
        var fixes: [Fix] = []
        /// Fixes to keep in the routine: other forms a step's target took, and what was closed before it.
        var learnedForms: [Int: RoutineTarget] = [:]
        var learnedClears: [Int: [RoutineTarget]] = [:]
        let screen = size ?? ScreenSize(width: 10_000, height: 10_000)
        let policy = config.deciderPolicy
        let decider = config.decider()
        /// Checks the decider passed, and those it could not answer.
        var checksPassed = 0, checksOpen = 0
        /// Optional steps whose target was not there.
        var skipped = 0
        /// Fixes of a step that went wrong: a target the decider chose from a description is the step
        /// working as written, and does not use up the run's fixes.
        func repairs() -> Int { fixes.filter { $0.kind != .chosen }.count }
        func fixedNote() -> String {
            let chosen = fixes.filter { $0.kind == .chosen }, fixed = fixes.filter { $0.kind != .chosen }
            return (chosen.isEmpty ? "" : "; chosen by description: " + chosen.map(\.line).joined(separator: "; "))
                + (fixed.isEmpty ? "" : "; fixed on the way: " + fixed.map(\.line).joined(separator: "; "))
                + (skipped > 0 ? "; \(skipped) optional \(skipped == 1 ? "step was" : "steps were") left out" : "")
                + (checksPassed > 0 ? "; \(checksPassed) \(checksPassed == 1 ? "check" : "checks") passed" : "")
                + (checksOpen > 0 ? "; \(checksOpen) \(checksOpen == 1 ? "check was" : "checks were") not answered: look at the screen" : "")
        }
        func finish(_ outcome: String, stop: SkillStop?) {
            let ms = Int(((now() - started) * 1000).rounded())
            fixesMade += repairs()
            guard let store else { return }
            let madeFixes = repairs()
            let forms = stop == nil ? learnedForms : [:]
            let clears = learnedClears
            store.update(skill.name) { r in
                r.runs += 1
                r.lastMs = ms
                if let stop { r.failuresInARow += 1; r.lastStop = stop } else { r.ok += 1; r.failuresInARow = 0 }
                if madeFixes > 0 { r.fixes = (r.fixes ?? 0) + madeFixes }
                // What a fix found is kept, so the next run needs no decision: a target's other form
                // once the whole run worked, a thing that was in the way as soon as closing it helped.
                for (index, form) in forms where r.steps.indices.contains(index) && r.steps[index].target != form {
                    var also = r.steps[index].also ?? []
                    if !also.contains(form) { also.append(form) }
                    r.steps[index].also = Array(also.suffix(3))
                }
                for (index, closers) in clears where r.steps.indices.contains(index) {
                    var kept = r.steps[index].clears ?? []
                    for c in closers where !kept.contains(where: { $0.type == c.type && $0.label == c.label && $0.identifier == c.identifier }) { kept.append(c) }
                    r.steps[index].clears = Array(kept.suffix(4))
                }
            }
            store.logRun(SkillRunLog(skill: skill.name, at: Date(), ms: ms, outcome: outcome, steps: log, fixes: fixes.isEmpty ? nil : fixes.map(\.line)))
        }
        func stop(_ index: Int, _ why: String, _ delivery: Delivery = .notSent) -> ActionFailure {
            finish("stopped at step \(index + 1): \(why)", stop: SkillStop(step: index + 1, why: why, at: Date()))
            let sent = done == 0 ? "no step was sent" : "steps 1 to \(done) were sent"
            let after = saved ? "; when the task is done, skills {action: \"save\", name: \"\(skill.name)\"} saves the path that worked over this one" : ""
            return ActionFailure(message: "\(title) stopped at step \(index + 1) of \(skill.steps.count): \(why); \(sent)\(fixedNote()). Go on by hand from the screen below\(after)", delivery: delivery)
        }

        var front = lastForeground
        if let app = skill.startingApp, lastForeground?.bundleID != app, skill.steps.first?.action["launch"] == nil, !config.isPoki(Foreground(bundleID: app, name: nil)) {
            do {
                _ = try await perform(["launch": .string(app)], until: until)
                log.append("launched \(app)")
                front = Foreground(bundleID: app, name: nil)
            } catch { throw stop(0, "\(app) could not be launched (\(error))") }
        }

        /// No input goes into Poki, where the approval card and the approval settings are: a step that
        /// would send it there stops the run, as a do sending it there is refused.
        let inPoki = "Poki is in front, and \(CoreConfig.ownAppRefusal). Leave Poki first ({button: \"home\"} or {launch: \"bundle id\"})"

        var previous: String?
        /// What may be closed when it is in the way: what the step remembers, then what the path allows.
        let allowed = (skill.dismiss ?? []).map { SkillTarget(type: SkillTarget.anyType, label: $0) }
        steps: for (index, step) in skill.steps.enumerated() {
            if step.secret == true { throw stop(index, "it types into a password field, which a skill never keeps: type it yourself") }
            var action = step.action
            if let text = action["type"]?.string, case .object(var o) = action {
                o["type"] = .string(text.replacingParams(params))
                action = .object(o)
            }
            var scan: SensitiveScan?
            /// The screen this step lands on was read for it, so `front` is the app really in front.
            var read = false
            if let target = step.target {
                // Wait for the target, alone, on screen; after a step that changed nothing yet, give the
                // screen a moment to move on so the same label on the old screen is not taken for it.
                var stepEnds = min(until, now() + config.actionCap)
                var found: Element?
                let described = target.isDescribed
                var why = described ? "the step describes its target and does not name it: when it is on this screen, choose target and the element that fits" : "\(target.describe) is not on screen"
                var reads = 0
                var fixesHere = 0
                // The decider is asked at most once more after it said stop, wait or nothing useful:
                // then the step waits out its time as it always did, so a slow page loses nothing.
                var mayAsk = true
                /// What the decider said when it did not fix the step, for the stop's reason.
                var said: String?
                let forms = [target] + (step.also ?? [])
                let readStart = now()
                attempts: while true {
                    // The match and its frame in the read before: a target is tapped only once it holds still
                    // across two reads (a page sliding in moves its rows, and a tap then is lost), or after 1.5 s.
                    var candidate: String?
                    let attemptStart = now()
                    var stillSince = attemptStart
                    var lastSignature: String?
                    var elements: [Element] = []
                    var early = false
                    while now() < stepEnds - 0.2 {
                        // A read that fails (an app still launching, a runner busy with the last step) is
                        // tried again while the step has time: one missed read is not a screen that differs.
                        guard let tree = try? await runner.tree(timeout: min(config.readTimeout, max(0.3, stepEnds - now() - 0.1)), format: config.treeFormat) else {
                            why = "the screen could not be read"
                            await sleep(seconds: 0.25)
                            continue
                        }
                        if why == "the screen could not be read" { why = "\(target.describe) is not on screen" }
                        reads += 1
                        elements = listable(tree.elements, screen)
                        let signature = elements.map { "\($0.key)@\($0.frame.described)" }.joined(separator: ";")
                        let moved = previous == nil || signature != previous || now() - attemptStart > 0.8
                        if signature != lastSignature { stillSince = now(); lastSignature = signature }
                        lastAll = tree.elements
                        lastForeground = tree.foreground
                        var matches = elements.filter { e in forms.contains { $0.matches(e) } }
                        // An alert takes every touch: a target behind one is not there to tap yet (the
                        // tap would go nowhere, and the step after it would be the one to stop).
                        if !matches.isEmpty, let alert = tree.elements.last(where: { $0.type == "Alert" && !$0.frame.isEmpty }), !matches.contains(where: { alert.contains($0) }) {
                            matches = []
                            why = "\(target.describe) is behind an alert\(alert.text.isEmpty ? "" : " (\"\(alert.text.prefix(60))\")")"
                        }
                        if moved, !matches.isEmpty {
                            let layout = Layout(all: tree.elements, screen: screen)
                            let reachable = matches.filter { layout.touchPoint($0) != nil }
                            let (pick, reason) = Self.pick(among: reachable, for: target)
                            if let reason { why = reason }
                            if let pick {
                                let here = "\(pick.key)@\(pick.frame.described)"
                                if here == candidate || now() - attemptStart > 1.5 { found = pick; break }
                                candidate = here
                                why = "\(target.describe) was still moving"
                                continue
                            }
                        }
                        candidate = nil
                        // With a way to fix the step at hand, a screen that has held still without the
                        // target is asked about now, not after the step's whole time.
                        // A step for something only sometimes there does not wait for it on a still screen.
                        if step.optional == true, moved, now() - stillSince >= policy.askAfterStill { break }
                        let canFix = (decider != nil && mayAsk) || !(step.clears ?? []).isEmpty || !allowed.isEmpty
                        if canFix, moved, fixesHere < policy.maxFixesPerStep, described || repairs() < policy.maxFixesPerRun, now() - stillSince >= policy.askAfterStill { early = true; break }
                        await sleep(seconds: 0.12)
                    }
                    if found != nil || step.optional == true { break attempts }
                    guard fixesHere < policy.maxFixesPerStep, described || repairs() < policy.maxFixesPerRun, until - now() > 1.5, !elements.isEmpty else { break attempts }
                    let layout = Layout(all: lastAll, screen: screen)

                    // What was in the way of this step before, alone on screen again: closed as it was then.
                    var move: FixMove?
                    var remembered = false
                    var via: String?
                    var ms: Int?, confidence: Double?
                    for (i, closer) in ((step.clears ?? []) + allowed).enumerated() {
                        let there = elements.filter { closer.matches($0) && layout.touchPoint($0) != nil && Self.tappable.contains($0.type) }
                        if there.count == 1 { move = .clear(there[0]); remembered = true; via = i < (step.clears ?? []).count ? nil : "allowed by the path"; break }
                    }
                    if move == nil {
                        // No one to ask. Looked at early: the step still has its time, and a page that was only slow gets it.
                        guard let decider, mayAsk else { if early { continue attempts }; break attempts }
                        let want = StepWant(goal: [skill.name, skill.description].filter { !$0.isEmpty }.joined(separator: ": "), index: index, total: skill.steps.count,
                                            action: ActionKind(action)?.rawValue ?? "tap", target: target, intent: step.intent,
                                            done: skill.steps[..<index].map(Self.words(for:)), next: skill.steps.indices.contains(index + 1) ? Self.words(for: skill.steps[index + 1]) : nil, why: why)
                        let decided = await decideFix(want, decider: decider, all: lastAll, screen: screen, until: until)
                        (move, ms, confidence) = (decided.move, decided.ms, decided.confidence)
                    }
                    let signatureNow = elements.map { "\($0.key)@\($0.frame.described)" }.joined(separator: ";")
                    switch move! {
                    case .target(let element):
                        fixesHere += 1
                        fixes.append(Fix(step: index, kind: described ? .chosen : .renamed, text: "\(described ? "chose" : "used") \(element.type) \"\(element.text.prefix(40))\" for \(target.describe)", remembered: false, ms: ms, confidence: confidence))
                        learnedForms[index] = RoutineTarget(element)
                        found = element
                        break attempts
                    case .clear(let element):
                        if config.isPoki(lastForeground) { throw stop(index, "\(why); \(inPoki)") }
                        // Closing it is a tap like any other: what the owner must approve stays theirs.
                        refs[Self.runRef] = element
                        let tap: JSON = ["tap": .number(Double(Self.runRef))]
                        var closeScan = SensitiveScan(front: lastForeground, secureOnScreen: lastAll.contains(where: \.isSecure))
                        if let reason = sensitive(tap, &closeScan) {
                            refs[Self.runRef] = nil
                            throw stop(index, "\(why); \(element.type) \"\(element.text.prefix(40))\" is in the way and closing it needs the owner's approval (\(reason))")
                        }
                        do { _ = try await perform(tap, until: min(until, now() + config.actionCap)) }
                        catch let failure as ActionFailure { refs[Self.runRef] = nil; throw stop(index, "\(why); closing \(element.type) \"\(element.text.prefix(40))\" failed (\(failure.message))", failure.delivery) }
                        catch { refs[Self.runRef] = nil; throw stop(index, "\(why); closing what was in the way failed (\(error))", .unknown) }
                        refs[Self.runRef] = nil
                        fixesHere += 1
                        fixes.append(Fix(step: index, kind: .cleared, text: "closed \(element.type) \"\(element.text.prefix(40))\"", remembered: remembered, ms: ms, confidence: confidence, via: via))
                        log.append("fix before \(index + 1): closed \(element.type) \"\(element.text.prefix(40))\"")
                        if !remembered { learnedClears[index, default: []].append(RoutineTarget(element)) }
                        previous = signatureNow
                    case .scroll(let direction):
                        do { _ = try await perform(["swipe": .string(direction)], until: min(until, now() + config.actionCap)) }
                        catch { throw stop(index, "\(why); scrolling for it failed (\(error))", .unknown) }
                        fixesHere += 1
                        fixes.append(Fix(step: index, kind: .scrolled, text: "scrolled \(direction == "up" ? "down" : "up") for \(target.describe)", remembered: false, ms: ms, confidence: confidence))
                        previous = signatureNow
                    case .wait:
                        // A described target has no other way to be found: it is asked for once more
                        // after a moment. Otherwise waiting is what the step does anyway.
                        if described {
                            fixesHere += 1
                            said = "\(decider?.name ?? "the decider") saw a screen still loading"
                            await sleep(seconds: 0.6)
                            continue attempts
                        }
                        mayAsk = false
                        if !early { break attempts }
                        continue attempts
                    case .stop(let reason):
                        mayAsk = false
                        said = reason
                        // Asked early: the step still has its time, and a page that was only slow gets it.
                        // A described target that was not found will not be found by waiting.
                        if !early || described { break attempts }
                        continue attempts
                    }
                    // A fix changed the screen: the step gets its time again from here.
                    stepEnds = min(until, now() + config.actionCap)
                }
                // A thing closed for nothing is not worth remembering.
                if found == nil { learnedClears[index] = nil; learnedForms[index] = nil }
                if described, found == nil { why = "\(target.describe) was not found" }
                if found == nil, step.optional == true {
                    skipped += 1
                    log.append("\(index + 1) left out: \(target.describe) was not there")
                    done = index + 1
                    continue steps
                }
                guard let element = found else { throw stop(index, why + (said.map { "; \($0)" } ?? "") + " (\(reads) reads in \(Int(((now() - readStart) * 1000).rounded())) ms)") }
                refs[Self.runRef] = element
                action = Self.replacingTarget(action, with: Self.runRef)
                front = lastForeground
                read = true
                scan = SensitiveScan(front: lastForeground, secureOnScreen: lastAll.contains(where: \.isSecure))
            } else if config.sensitive.enabled, ActionKind(action)?.movesScreen == true {
                scan = SensitiveScan(front: front, read: false, secureOnScreen: false)
                if let tree = try? await runner.tree(timeout: min(config.readTimeout, max(0.3, until - now() - 0.1)), format: config.treeFormat) {
                    lastAll = tree.elements
                    lastForeground = tree.foreground
                    front = tree.foreground ?? front
                    read = true
                    let elements = listable(tree.elements, screen)
                    scan = SensitiveScan(front: front, secureOnScreen: elements.contains(where: \.isSecure), elements: elements)
                }
            }
            if ActionKind(action)?.movesScreen == true {
                // Not read for this step: a launch may not have opened what it named, so the runner says.
                if !read, let info = try? await runner.raw("GET", "/wda/activeAppInfo", timeout: 1.5, countsAsMiss: false), let bundle = info["bundleId"]?.string, !bundle.isEmpty {
                    front = Foreground(bundleID: bundle, name: info["name"]?.string)
                }
                if config.isPoki(front) {
                    refs[Self.runRef] = nil
                    throw stop(index, inPoki)
                }
            }
            if var scan, let reason = sensitive(action, &scan) {
                refs[Self.runRef] = nil
                throw stop(index, "it needs the owner's approval (\(reason)); send it as an ordinary do so the owner is asked")
            }
            let began = now()
            let kind: String, text: String
            do { (kind, text) = try await perform(action, until: min(until, now() + actionCap(action))) }
            catch let failure as ActionFailure {
                refs[Self.runRef] = nil
                throw stop(index, failure.message, failure.delivery)
            } catch {
                refs[Self.runRef] = nil
                throw stop(index, "\(error)", .unknown)
            }
            // The step is in this task's record too, so a task that goes on by hand saves whole. A
            // path's target is kept as the element it found, the way a step sent by hand is.
            var recorded = step
            if let element = refs[Self.runRef], step.target?.type == SkillTarget.anyType || step.target?.isDescribed == true || learnedForms[index] != nil { recorded.target = SkillTarget(element) }
            refs[Self.runRef] = nil
            if let spec = action["launch"] { front = Foreground(bundleID: spec.string ?? spec["bundle"]?.string, name: nil) }
            done = index + 1
            log.append("\(index + 1) \(text.prefix(80)) (\(Int(((now() - began) * 1000).rounded())) ms)")
            recorded.app = lastForeground?.bundleID ?? step.app
            recorded.also = nil
            recorded.clears = nil
            recorded.check = nil
            recorded.optional = nil
            // A path's typed text is what a saved skill's parameter is made of.
            trace.append(RecordedStep(step: recorded, typed: kind == "type" ? action["type"]?.string : nil, keysBefore: []))
            previous = listable(lastAll, screen).map { "\($0.key)@\($0.frame.described)" }.joined(separator: ";")
            if kind == "type" || kind == "key" { previous = nil }
            // What the step said must be there afterwards, read from the tree: no model is asked.
            if let wanted = step.expect, !wanted.isEmpty {
                let ends = min(until, now() + 3)
                var missing = wanted
                while true {
                    if let tree = try? await runner.tree(timeout: min(config.readTimeout, max(0.3, ends - now())), format: config.treeFormat) {
                        lastAll = tree.elements
                        lastForeground = tree.foreground
                        let texts = listable(tree.elements, screen)
                        missing = wanted.filter { want in !texts.contains { $0.text.localizedCaseInsensitiveContains(want) } }
                    }
                    if missing.isEmpty || now() >= ends - 0.2 { break }
                    await sleep(seconds: 0.12)
                }
                if !missing.isEmpty { throw stop(index, "the step was sent, but \(missing.map { "\"\($0)\"" }.joined(separator: ", ")) did not appear after it", .sent) }
                log.append("after \(index + 1): \(wanted.map { "\"\($0)\"" }.joined(separator: ", ")) on screen")
                previous = listable(lastAll, screen).map { "\($0.key)@\($0.frame.described)" }.joined(separator: ";")
            }
            // The step's own check: one yes or no on the screen it led to. A clear no stops the run
            // here, before the next step is sent on a screen that is not the one meant.
            if let check = step.check, let decider {
                let goal = [skill.name, skill.description].filter { !$0.isEmpty }.joined(separator: ": ")
                switch await decideCheck(check, goal: goal, step: Self.words(for: step), decider: decider, screen: screen, until: until) {
                case .holds(let ms, let p):
                    checksPassed += 1
                    log.append("check after \(index + 1) held (\(ms) ms at \(String(format: "%.2f", p)))")
                case .fails(let ms, let p):
                    throw stop(index, "the step was sent, but its check does not hold: \"\(check)\" (\(decider.name) in \(ms) ms, \(String(format: "%.2f", 1 - p)) sure it does not)", .sent)
                case .open(let reason):
                    checksOpen += 1
                    log.append("check after \(index + 1) not answered (\(reason))")
                }
                previous = listable(lastAll, screen).map { "\($0.key)@\($0.frame.described)" }.joined(separator: ";")
            }
        }

        if skill.steps.last?.expect?.isEmpty == false { runEndedOnARead = true }
        // The end check and the readout.
        var outcome = "\(skill.steps.count) steps in \(Self.seconds(now() - started)) s"
        if !skill.expect.isEmpty || !skill.read.isEmpty {
            let checkEnds = min(until, now() + 3)
            var missing = skill.expect
            var values: [String] = []
            while now() < checkEnds {
                guard let tree = try? await runner.tree(timeout: min(config.readTimeout, max(0.3, checkEnds - now())), format: config.treeFormat) else { break }
                let texts = listable(tree.elements, screen)
                missing = skill.expect.filter { want in !texts.contains { $0.text.localizedCaseInsensitiveContains(want) } }
                values = skill.read.compactMap { label in
                    guard let e = texts.first(where: { $0.label?.caseInsensitiveCompare(label) == .orderedSame && !($0.value ?? "").isEmpty })
                        ?? texts.first(where: { ($0.label ?? "").localizedCaseInsensitiveContains(label) && ($0.label ?? "").count > label.count }) else { return nil }
                    if let v = e.value, !v.isEmpty { return "\(label) = \(v)" }
                    let rest = (e.label ?? "").replacingOccurrences(of: label, with: "", options: .caseInsensitive).trimmingCharacters(in: CharacterSet(charactersIn: " :,"))
                    return rest.isEmpty ? nil : "\(label) = \(rest)"
                }
                if missing.isEmpty && values.count == skill.read.count { break }
                await sleep(seconds: 0.15)
            }
            if !missing.isEmpty {
                let why = "the end check did not pass: \(missing.map { "\"\($0)\"" }.joined(separator: ", ")) not on screen"
                finish("ran, end check failed", stop: SkillStop(step: skill.steps.count, why: why, at: Date()))
                return "\(title): \(outcome), but \(why)\(fixedNote()); look at the screen below before going on"
            }
            if !skill.expect.isEmpty || !values.isEmpty { runEndedOnARead = true }
            if !skill.expect.isEmpty { outcome += ", end check passed (\(skill.expect.map { "\"\($0)\"" }.joined(separator: ", ")) on screen)" }
            if !values.isEmpty { outcome += "; read: " + values.joined(separator: "; ") }
            else if !skill.read.isEmpty { outcome += "; the values to read (\(skill.read.joined(separator: ", "))) were not found: read them from the screen below" }
        }
        outcome += fixedNote()
        finish("ok", stop: nil)
        if saved {
            skillRanWhole = true
            onCompleted?(skill.name)
        }
        return "\(title): \(outcome)"
    }

    /// The one element a step acts on among those that match its target, or why none is taken: a
    /// single match, or the one clearly nearest to where the target was recorded.
    static func pick(among reachable: [Element], for target: SkillTarget) -> (Element?, String?) {
        guard !reachable.isEmpty else { return (nil, "\(target.describe) is listed but not where a tap reaches it") }
        if reachable.count == 1 { return (reachable[0], nil) }
        // A path names a target by its text alone: among several, the one that takes a tap.
        if !target.hasPlace {
            let controls = reachable.filter { tappable.contains($0.type) }
            if controls.count == 1 { return (controls[0], nil) }
            return (nil, "\(reachable.count) elements read \(target.describe) and none is clearly the one meant")
        }
        func distance(_ e: Element) -> Double { hypot(e.frame.centre.x - target.x, e.frame.centre.y - target.y) }
        let near = reachable.sorted { distance($0) < distance($1) }
        let d0 = distance(near[0]), d1 = distance(near[1])
        if d0 < 40, d1 > 2 * d0 + 20 { return (near[0], nil) }
        return (nil, "\(near.count) elements match \(target.describe) and none is clearly the recorded one")
    }

    /// The number a run gives the element it found, for the one action it sends.
    static let runRef = 900_001

    static func replacingTarget(_ action: JSON, with ref: Int) -> JSON {
        guard case .object(var o) = action else { return action }
        for key in ["tap", "long_press"] {
            if o[key]?.string == "@" { o[key] = .number(Double(ref)) }
            else if case .object(var inner) = o[key], inner["ref"]?.string == "@" { inner["ref"] = .number(Double(ref)); o[key] = .object(inner) }
        }
        if o["ref"]?.string == "@" { o["ref"] = .number(Double(ref)) }
        return .object(o)
    }

    /// A new task: its recording starts empty.
    func beginRecording(task: String? = nil) {
        recordingTask = task
        memoryAppsOffered.removeAll()
        trace = []
        skillRanWhole = false
    }

    /// The skills saved for the app in front, for the first look of a task (nil when none).
    func skillsLine() -> String? {
        guard let memory else { return nil }
        let app = lastForeground?.bundleID
        let all = memory.usableSkills
        guard !all.isEmpty else { return nil }
        let here = all.filter { $0.app == app }
        let onHome = app == nil || app == "com.apple.springboard"
        guard !here.isEmpty || onHome else { return nil }
        let pool = here.isEmpty ? all : here
        let shown = pool.sorted { $0.updated > $1.updated }.prefix(6)
        let names = shown.map { "\"\($0.name)\"\($0.description.isEmpty ? "" : " (\($0.description.prefix(60)))")" }.joined(separator: ", ")
        return "skills\(here.isEmpty ? "" : " for this app"): \(names)\(pool.count > shown.count ? ", and \(pool.count - shown.count) more (skills {action: \"list\"})" : ""); do {run: \"name\"} repeats one in a single call"
    }
}

extension String {
    /// `{{name}}` replaced by the parameter's value.
    func replacingParams(_ params: [String: String]) -> String {
        var out = self
        for (k, v) in params { out = out.replacingOccurrences(of: "{{\(k)}}", with: v) }
        return out
    }
}

// MARK: The skills tool

public struct TaskMemoryWrite: Sendable {
    let arguments: String
    public let optional: Bool

    public init(arguments: String, optional: Bool) {
        self.arguments = arguments
        self.optional = optional
    }
}

extension PokiCore {
    /// What a model should know at the start of a task about this phone's owner and saved skills:
    /// the notes, and the skills that fit `task` and `apps` best. "" when nothing is saved.
    public static func memoryBrief(for task: String, app: String? = nil, apps: [String] = []) -> String {
        SkillStore.shared.brief(for: task, app: app, apps: apps)
    }

    /// Commits a memory write once the chat has finished successfully. A skill may only
    /// use the steps recorded for that chat task.
    public func saveTaskMemory(arguments: String, conversation: String, task: String) -> Bool {
        guard let args = try? JSON.parse(arguments),
              let action = args["action"]?.string, ["save", "remember", "write_page"].contains(action) else { return false }
        return !skillsCall(args, session: nil, conversation: conversation, recordingTask: task).isError
    }

    static let skillsTool: JSON = [
        "name": "skills",
        "description": "The agent's memory library on this phone, shared by every agent that drives it. Skills are saved procedures in apps: the do actions of a task, each target kept as what it is (role and label), so do {run: \"name\"} replays it in one call, waits for each target, and stops cleanly at a screen that differs. Memory is kept as pages: About You for what holds everywhere, and one page per app (app: its bundle id), each line a fact with an id. action: list (the skills and every page) | page (one page whole with the app's skills; app, or none for About You) | write_page (rewrite one page: app, text with one fact a line, summary: one line for the index; keep what still holds, fold in what is new, drop what is no longer true; lines the owner locked stay) | show (one skill's steps, name) | save (the do actions sent since this task began, as name, with description; expect: texts that must be on screen at the end, chosen from the last screen when left out; read: labels whose values a run reports) | edit (name; rename, description, expect, read, steps as JSON to replace them) | forget (name) | remember (text: a fact worth keeping, never a password; app: the bundle id when it holds only in that app) | forget_note (id or text) | export (the whole memory as JSON, to review or move) | import (data: such JSON; newer skills win). Save a skill after an app task that worked and that someone may ask for again; save it again under the same name to fix one that stopped.",
        "inputSchema": ["type": "object", "properties": [
            "action": ["type": "string", "enum": ["list", "page", "write_page", "show", "save", "edit", "forget", "remember", "forget_note", "export", "import"]],
            "app": ["type": "string", "description": "A memory page's app (bundle id); left out, About You."],
            "summary": ["type": "string"],
            "name": ["type": "string"], "description": ["type": "string"], "rename": ["type": "string"],
            "text": ["type": "string"], "data": ["type": "string"],
            "expect": ["type": "array", "items": ["type": "string"]], "read": ["type": "array", "items": ["type": "string"]],
            "steps": ["type": "string"],
            "optional": ["type": "boolean", "description": "In Poki chat, true for an automatic save the owner did not request."],
        ], "required": ["action"], "additionalProperties": false],
    ]

    /// `conversation` is the app's saved conversation the call came from (Poki's own chat), kept with a
    /// note as where it was heard.
    func skillsCall(_ args: JSON, session: String?, conversation: String? = nil, recordingTask: String? = nil, store: SkillStore? = nil) -> ToolResult {
        guard let store = store ?? computer.memory else { return ToolResult(text: "skills: no memory on this phone", jpeg: nil, isError: true) }
        let action = args["action"]?.string ?? "list"
        let name = args["name"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // A client's own name never passes for the owner, an import or Dream: those are the app's own.
        let named = session.flatMap { clientNames.value[$0] }.flatMap { $0.isEmpty || SkillStore.isReserved($0) ? nil : $0 }
        let by = session == nil ? "Poki" : named ?? "an MCP client"
        func fail(_ text: String) -> ToolResult { ToolResult(text: "skills \(action): \(text)", jpeg: nil, isError: true) }
        let locked = "is locked by the owner: only they change or forget it, on Poki's Memory page"
        switch action {
        case "list":
            let skills = store.usableSkills, notes = store.notes
            var lines = ["skills (\(skills.count)):"] + skills.map { "- \($0.summary)\($0.isLocked ? " (locked)" : "")" }
            if skills.isEmpty { lines = ["skills: none saved yet. After a task that worked, skills {action: \"save\", name, description} keeps its steps so do {run: name} repeats them in one call."] }
            let pages = store.pages
            lines.append(pages.isEmpty ? "memory pages: none yet" : "memory pages (\(pages.count)):")
            for page in pages {
                lines.append("\(page.title)\(page.summary.map { " (\($0))" } ?? "")\(page.isLocked ? ", locked" : ""):")
                lines += page.lines.map { "- [\($0.id)] \($0.text) (by \($0.by)\($0.isLocked ? ", locked" : ""))" }
            }
            if !computer.trace.isEmpty { lines.append("this task has \(computer.trace.count) recorded steps so far (save keeps them)") }
            return ToolResult(text: lines.joined(separator: "\n"), jpeg: nil, offeredMemories: notes)
        case "page":
            let app = args["app"]?.string.flatMap { $0.isEmpty ? nil : $0 }
            return ToolResult(text: store.pageText(app), jpeg: nil, offeredMemories: store.page(app)?.lines ?? [])
        case "write_page":
            let app = args["app"]?.string.flatMap { $0.isEmpty ? nil : $0 }
            guard let text = args["text"]?.string else { return fail("give text: the whole page, one fact a line") }
            let front = computer.lastForeground.flatMap { f in computer.config.isPoki(f) || f.bundleID == "com.apple.springboard" ? nil : f.bundleID }
            switch store.writePage(app: app, text: text, summary: args["summary"]?.string, by: by, heard: conversation.map { NoteOrigin(session: $0, app: front) }) {
            case .locked:
                return fail("the page \(locked)")
            case .written(let page, let kept):
                return ToolResult(text: "skills: wrote the page \(page.title) (\(page.lines.count) lines\(kept > 0 ? "; \(kept) the owner locked stayed" : ""))", jpeg: nil)
            }
        case "show":
            guard let r = store.skill(named: name), !r.stale else { return fail("no skill named \"\(name)\"") }
            var lines = [r.summary]
            for (i, s) in r.steps.enumerated() {
                lines.append("\(i + 1). \(s.action.serialized())\(s.target.map { " on \($0.describe)\($0.hasPlace ? " at [\(Int($0.x)), \(Int($0.y))]" : "")" } ?? "")\(s.app.map { " in \($0)" } ?? "")\(s.intent.map { " (\($0))" } ?? "")\((s.clears ?? []).isEmpty ? "" : "; closes first when in the way: " + (s.clears ?? []).map(\.describe).joined(separator: ", "))\((s.also ?? []).isEmpty ? "" : "; also found as: " + (s.also ?? []).map(\.describe).joined(separator: ", "))")
            }
            if !r.expect.isEmpty { lines.append("end check: " + r.expect.map { "\"\($0)\"" }.joined(separator: ", ")) }
            if !r.read.isEmpty { lines.append("reads: " + r.read.joined(separator: ", ")) }
            let compact = JSONEncoder(); compact.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; compact.dateEncodingStrategy = .iso8601
            let steps = (try? String(decoding: compact.encode(r.steps), as: UTF8.self)) ?? "[]"
            lines.append("steps as JSON (edit takes this shape): \(steps)")
            return ToolResult(text: lines.joined(separator: "\n"), jpeg: nil)
        case "save":
            guard !name.isEmpty else { return fail("give the skill a name") }
            if let recordingTask, recordingTask != computer.recordingTask { return fail("this task has no recorded steps") }
            let expect = args["expect"]?.array?.compactMap(\.string)
            let read = args["read"]?.array?.compactMap(\.string) ?? store.skill(named: name)?.read ?? []
            let (skill, note) = computer.skill(named: name, description: args["description"]?.string ?? store.skill(named: name)?.description ?? "", read: read, expect: expect, by: by)
            guard let skill else { return fail(note) }
            let replacing = store.skill(named: name) != nil
            guard store.save(skill) else { return fail("\"\(name)\" \(locked); save this one under another name") }
            return ToolResult(text: "skills: \(replacing ? "saved over" : "saved") \"\(skill.name)\" (\(skill.steps.count) steps\(skill.app.map { " in \($0)" } ?? "")\(skill.params.isEmpty ? "" : "; it types " + skill.params.keys.sorted().joined(separator: ", ") + ", which with: changes")\(skill.expect.isEmpty ? "" : "; end check: " + skill.expect.map { "\"\($0)\"" }.joined(separator: ", "))). do {run: \"\(skill.name)\"} repeats it.\(note.isEmpty ? "" : " Note: \(note).")", jpeg: nil)
        case "edit":
            guard let current = store.skill(named: name) else { return fail("no skill named \"\(name)\"") }
            guard !current.isLocked else { return fail("\"\(name)\" \(locked)") }
            var newSteps: [SkillStep]?
            if let text = args["steps"]?.string {
                guard let steps = try? SkillStore.decoder.decode([SkillStep].self, from: Data(text.utf8)), !steps.isEmpty else { return fail("steps must be the JSON array show gives") }
                newSteps = steps
            }
            store.update(name, by: by) { r in
                if let d = args["description"]?.string { r.description = d }
                if let e = args["expect"]?.array { r.expect = e.compactMap(\.string) }
                if let e = args["read"]?.array { r.read = e.compactMap(\.string) }
                if let steps = newSteps {
                    r.steps = steps
                    r.app = Skill.inferredApp(from: steps) ?? r.app
                    r.failuresInARow = 0
                    r.lastStop = nil
                }
                r.updated = Date()
            }
            if let rename = args["rename"]?.string, !rename.isEmpty, !store.rename(name, to: rename, by: by) {
                return fail("edited \"\(name)\", but kept its name: \"\(rename)\" is another skill's")
            }
            return ToolResult(text: "skills: edited \"\(args["rename"]?.string ?? name)\"", jpeg: nil)
        case "forget":
            if store.skill(named: name)?.isLocked == true { return fail("\"\(name)\" \(locked)") }
            guard store.forget(name, by: by) else { return fail("no skill named \"\(name)\"") }
            return ToolResult(text: "skills: forgot \"\(name)\"", jpeg: nil)
        case "remember":
            let text = args["text"]?.string ?? ""
            // Heard in a conversation of Poki's own: kept with it, and with the app in front then.
            let front = computer.lastForeground.flatMap { f in computer.config.isPoki(f) || f.bundleID == "com.apple.springboard" ? nil : f.bundleID }
            let heard = conversation.map { NoteOrigin(session: $0, app: front) }
            let app = args["app"]?.string.flatMap { $0.isEmpty ? nil : $0 }
            if store.page(app)?.isLocked == true { return fail("the page \(app ?? "About You") \(locked)") }
            guard let note = store.remember(text, by: by, app: app, heard: heard) else { return fail("give the text to remember") }
            return ToolResult(text: "skills: remembered [\(note.id)] \(note.text)", jpeg: nil)
        case "forget_note":
            let which = args["text"]?.string ?? name
            if store.note(which)?.isLocked == true { return fail("that note \(locked)") }
            guard store.forgetNote(which, by: by) else { return fail("no such note") }
            return ToolResult(text: "skills: note forgotten", jpeg: nil)
        case "export":
            guard let data = try? store.exportData() else { return fail("could not be made") }
            let notes = (try? SkillStore.decoder.decode(MemoryFile.self, from: data))?.notes ?? []
            return ToolResult(text: String(decoding: data, as: UTF8.self), jpeg: nil, offeredMemories: notes)
        case "import":
            guard let text = args["data"]?.string else { return fail("give data: the JSON export gives") }
            do {
                let summary = try store.importData(Data(text.utf8), by: by)
                return ToolResult(text: "skills: \(summary)", jpeg: nil)
            } catch { return fail("\(error)") }
        default:
            return fail("unknown action; the actions are list, page, write_page, show, save, edit, forget, remember, forget_note, export, import")
        }
    }
}
