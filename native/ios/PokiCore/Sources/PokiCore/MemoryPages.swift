import Foundation

// Memory as pages (the owner, Nov 20 2026, after how Claude and ChatGPT keep memory now): one page
// per area, About You for what holds everywhere and one page per app, read whole at the start of a
// task instead of a list of loose notes. A page is written text whose lines keep their own id, author,
// time, lock and where they were heard, so a task still reports which lines it used (finish_task's
// memory ids) and the Memory page still says where each came from. An agent may write a whole page
// at once (`writePage`); it never drops or rewords a line the owner locked. Each app's skills belong
// to that app's page: the tool's page view lists them under it.

/// One area's page.
public struct MemoryPage: Codable, Equatable, Sendable {
    /// The app it is about (a bundle id); nil is About You.
    public var app: String?
    /// One line for the index, written by an agent or the owner ("Orders: grande oat latte, pickup").
    public var summary: String?
    /// The page's lines, in order.
    public var lines: [MemoryNote]
    /// Locked by the owner: no agent writes the page.
    public var locked: Bool?
    public var updated: Date

    public var isLocked: Bool { locked == true }

    public init(app: String?, summary: String? = nil, lines: [MemoryNote], locked: Bool? = nil, updated: Date = Date()) {
        self.app = app
        self.summary = summary
        self.lines = lines
        self.locked = locked
        self.updated = updated
    }

    /// The page as text: its lines, one to a line.
    public var text: String { lines.map(\.text).joined(separator: "\n") }

    /// "About You", or the app's bundle id.
    public var title: String { app ?? "About You" }

    static func sameArea(_ a: String?, _ b: String?) -> Bool {
        switch (a, b) {
        case (nil, nil): true
        case let (a?, b?): a.caseInsensitiveCompare(b) == .orderedSame
        default: false
        }
    }

    /// Files `notes` under their app's page, in order, keeping the pages in `old` (their order,
    /// summary and lock). About You comes first; a page left with no lines and no summary goes.
    static func regroup(_ notes: [MemoryNote], into old: [MemoryPage]) -> [MemoryPage] {
        var out = old.map { page -> MemoryPage in var p = page; p.lines = []; return p }
        if !out.contains(where: { $0.app == nil }), notes.contains(where: { $0.app == nil }) {
            out.insert(MemoryPage(app: nil, lines: [], updated: .distantPast), at: 0)
        }
        for note in notes {
            if let i = out.firstIndex(where: { sameArea($0.app, note.app) }) {
                out[i].lines.append(note)
            } else {
                out.append(MemoryPage(app: note.app, lines: [note], updated: .distantPast))
            }
        }
        for i in out.indices {
            let latest = out[i].lines.map { $0.edited ?? $0.at }.max() ?? .distantPast
            out[i].updated = max(out[i].updated, latest)
        }
        return out.filter { !$0.lines.isEmpty || $0.summary != nil }
    }

    /// The lines of a page's text: one fact a line, list marks taken off, blanks and repeats dropped.
    static func lines(of text: String, limit: Int) -> [String] {
        var seen = Set<String>()
        return text.split(whereSeparator: \.isNewline).compactMap { raw in
            var line = raw.trimmingCharacters(in: .whitespaces)
            for mark in ["- ", "* ", "• ", "· "] where line.hasPrefix(mark) { line = String(line.dropFirst(mark.count)) }
            line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, seen.insert(line.lowercased()).inserted else { return nil }
            return String(line.prefix(limit))
        }
    }
}

extension SkillStore {
    /// Every page, About You first.
    public var pages: [MemoryPage] { withFile { $0.pages } }

    /// The page of `app` (nil: About You), when it has anything.
    public func page(_ app: String?) -> MemoryPage? {
        withFile { f in f.pages.first { MemoryPage.sameArea($0.app, app) } }
    }

    /// What a page write did.
    public enum PageWrite: Equatable, Sendable {
        /// Written; `kept` lines the owner locked stayed although the text left them out.
        case written(MemoryPage, kept: Int)
        /// The owner locked the page.
        case locked
    }

    /// Writes `app`'s page (nil: About You) from `text`, one line a fact. A line whose words are already
    /// on the page keeps its id, author and lock; a new one is `by`'s. An agent cannot write a locked
    /// page, and a locked line it left out stays. The owner's lines come locked, as their notes did.
    /// Empty text leaves only the locked lines (for an agent) or clears the page (for the owner).
    @discardableResult
    public func writePage(app: String?, text: String, summary: String? = nil, by: String, heard: NoteOrigin? = nil) -> PageWrite {
        withFile(true) { f in
            let owner = by == Self.owner
            let index = f.pages.firstIndex { MemoryPage.sameArea($0.app, app) }
            let before = index.map { f.pages[$0] }
            if let before, before.isLocked, !owner { return .locked }
            let old = before?.lines ?? []
            let now = Date()
            var lines: [MemoryNote] = []
            for words in MemoryPage.lines(of: text, limit: Self.maxNoteLength) {
                if let same = old.first(where: { $0.text.caseInsensitiveCompare(words) == .orderedSame }) {
                    lines.append(same)
                } else {
                    lines.append(MemoryNote(id: String(UUID().uuidString.prefix(8)).lowercased(), text: words, by: by, at: now,
                                            locked: owner ? true : nil, app: app, heard: owner ? nil : heard))
                }
            }
            var kept = 0
            if !owner {
                for line in old where line.isLocked && !lines.contains(where: { $0.id == line.id }) {
                    lines.append(line)
                    kept += 1
                }
            }
            // An id another page already uses would make forgetting or undoing by id reach the wrong line.
            let elsewhere = Set(f.pages.enumerated().filter { $0.offset != index }.flatMap { $0.element.lines.map(\.id) })
            for i in lines.indices where elsewhere.contains(lines[i].id) { lines[i].id = String(UUID().uuidString.prefix(8)).lowercased() }
            var page = before ?? MemoryPage(app: app, lines: [])
            page.lines = lines
            if let summary { page.summary = summary.isEmpty ? nil : String(summary.prefix(160)) }
            page.updated = now
            if let index { f.pages[index] = page } else if app == nil { f.pages.insert(page, at: 0) } else { f.pages.append(page) }
            f.pages.removeAll { $0.lines.isEmpty && $0.summary == nil }
            Self.log(&f, MemoryChangeRecord(action: before == nil ? MemoryChangeRecord.added : MemoryChangeRecord.edited, id: Self.newID(), at: now, by: by,
                                            page: page, pageBefore: before))
            return .written(page, kept: kept)
        }
    }

    /// Locks or unlocks a whole page. Only the Memory page calls it.
    public func setPageLocked(_ app: String?, _ locked: Bool) {
        withFile(true) { f in
            guard let i = f.pages.firstIndex(where: { MemoryPage.sameArea($0.app, app) }) else { return }
            f.pages[i].locked = locked ? true : nil
        }
    }

    /// Puts a page back as it was before a write, or takes away a page the write made.
    static func undoPage(_ change: MemoryChangeRecord, in f: inout MemoryFile) -> Bool {
        let app = change.page?.app ?? change.pageBefore?.app
        let i = f.pages.firstIndex { MemoryPage.sameArea($0.app, app) }
        if let before = change.pageBefore {
            if let i { f.pages[i] = before } else if before.app == nil { f.pages.insert(before, at: 0) } else { f.pages.append(before) }
        } else {
            guard let i else { return false }
            f.pages.remove(at: i)
        }
        return true
    }

    /// The index: a line per page, for the brief and the tool. "About You, 4 lines" or
    /// "com.tencent.xin, 3 lines: Mom is Mama".
    public var pageIndex: [String] {
        pages.map { page in
            let count = "\(page.lines.count) line\(page.lines.count == 1 ? "" : "s")"
            return "\(page.title), \(count)\(page.summary.map { ": \($0)" } ?? "")\(page.isLocked ? " (locked)" : "")"
        }
    }

    /// A page as the tool shows it: its lines with their ids, then the app's skills (how Poki does
    /// things there), so a skill's blanks can be filled from what the page says.
    public func pageText(_ app: String?) -> String {
        let page = page(app)
        var out = ["page: \(app ?? "About You")\(page?.isLocked == true ? " (locked by the owner)" : "")"]
        if let summary = page?.summary { out.append("summary: \(summary)") }
        let lines = page?.lines ?? []
        out += lines.isEmpty ? ["(nothing on it yet)"] : lines.map { "- [\($0.id)] \($0.text)\($0.isLocked ? " (locked)" : "")" }
        if let app {
            let skills = usableSkills.filter { $0.app?.caseInsensitiveCompare(app) == .orderedSame }
            if !skills.isEmpty {
                out.append("how Poki does things here (skills; fill a skill's blanks from the page above):")
                out += skills.map { "- \($0.briefLine)" }
            }
        }
        return out.joined(separator: "\n")
    }
}
