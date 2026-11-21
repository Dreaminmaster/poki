import Foundation
import UIKit

/// What the message field is writing at the caret that may be an app or a connector: the words, where
/// they stand in the plain text, and where the caret is on screen, for the list that follows it.
struct MentionQuery: Equatable {
    /// The text the list matches: the words before the caret, or the keyboard's pending text (Pinyin
    /// before it commits, kana, Hangul jamo).
    var text: String
    /// The words the picked name replaces, in the plain text (UTF-16).
    var range: NSRange
    /// The caret, in the field's own visible coordinates (its scroll taken off). The list is placed
    /// from the field's frame in the composer's own coordinate space: window and global coordinates
    /// do not line up inside the iOS 26 safe-area bar the composer sits in, and the list landed in
    /// the field or under the keyboard (the owner, Nov 20 2026).
    var caret: CGRect
    /// The keyboard is still composing.
    var pending: Bool
    /// Written after @: every app and connector is offered, also with nothing typed yet.
    var explicit: Bool
}

/// One row of the mention list.
struct MentionMatch: Identifiable, Equatable {
    let capsule: AppCapsule
    /// What goes in the message: the app's name, or "@Notion".
    let insert: String
    var id: String { capsule.id + "|" + insert }
    var isConnector: Bool { capsule.isConnector }
    /// The name the row shows.
    var title: String { isConnector ? String(insert.dropFirst()) : insert }
}

/// Finds the apps and connectors that fit what is being written. Pure text work: the field hands it
/// the text before the caret and where any pending composition starts.
enum MentionSearch {
    static let most = 6

    /// What the field is writing, and what fits it; nil when nothing does.
    static func query(before: String, pendingStart: Int?) -> (text: String, start: Int, explicit: Bool)? {
        let text = before as NSString
        let end = text.length
        guard end > 0 else { return nil }
        // Pending text: what the keyboard composes, as one query.
        if let pendingStart, pendingStart < end {
            let pending = text.substring(from: pendingStart)
            let explicit = pendingStart > 0 && text.character(at: pendingStart - 1) == 0x40 // "@"
            return (pending, explicit ? pendingStart - 1 : pendingStart, explicit)
        }
        // "@" and what follows it, up to the caret, with no space between.
        var i = end - 1
        while i >= 0, end - i <= 32 {
            let unit = text.character(at: i)
            if unit == 0x40 {
                let boundary = i == 0 || isBoundary(text.character(at: i - 1))
                if boundary { return (text.substring(from: i + 1), i, true) }
                break
            }
            if isBoundary(unit) { break }
            i -= 1
        }
        // A word of a spaced script ending at the caret.
        var start = end
        while start > 0, isLatin(text.character(at: start - 1)) { start -= 1 }
        if start < end {
            let word = text.substring(from: start)
            return word.count >= 3 ? (word, start, false) : nil
        }
        // A run of Chinese, Japanese or Korean: the longest end of it (at most 8 characters) that
        // starts a name, so "打开淘" asks about "淘".
        var run = end
        while run > 0, end - run < 8, isUnspaced(text.character(at: run - 1)) { run -= 1 }
        for from in run..<end {
            let tail = text.substring(from: from)
            if !matches(tail, pending: false, explicit: false).isEmpty { return (tail, from, false) }
        }
        return nil
    }

    /// The apps and connectors for a query, best first.
    static func matches(_ query: String, pending: Bool, explicit: Bool) -> [MentionMatch] {
        // The keyboard's syllable marks go: apostrophes, and every kind of space (Pinyin puts a six-per-em
        // space, U+2006, between syllables, so "tb" composing was "t b" and matched nothing).
        let typed = fold(String(String.UnicodeScalarView(query.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0) && $0 != "'" && $0 != "\u{2019}"
        })))
        // Latin letters the keyboard is still composing are Pinyin (Zhuyin, Cangjie and kana compose
        // in their own script): they spell a Chinese name, not a Latin one, so only the Pinyin keys of Chinese
        // names match until the keyboard commits ("tai" no longer offers Tailscale over 太平洋保险).
        let spelling = pending && !typed.isEmpty && typed.unicodeScalars.allSatisfy { $0.isASCII && CharacterSet.letters.contains($0) }
        var scored: [(score: Int, match: MentionMatch)] = []
        let connectors = ConnectorCapsules.current
        for capsule in connectors {
            for name in capsule.names {
                let bare = fold(String(name.dropFirst()))
                if typed.isEmpty { scored.append((50, MentionMatch(capsule: capsule, insert: name))); break }
                if spelling, !name.unicodeScalars.contains(where: CapsuleText.isUnspaced) { continue }
                // After @ a connector comes before an app of the same start.
                if let score = score(bare, typed) { scored.append((score + (explicit ? 25 : 5), MentionMatch(capsule: capsule, insert: name))); break }
            }
        }
        if typed.isEmpty {
            // Nothing typed after @: the recent ones, then the connectors.
            let recent = MentionRecents.apps.prefix(most).map { MentionMatch(capsule: $0, insert: $0.name) }
            return Array((scored.map(\.match) + recent).prefix(most))
        }
        for capsule in AppCapsule.catalog {
            var best: Int?
            // The name that matched, so 淘 typed in Chinese becomes 淘宝, not Taobao.
            var matched = capsule.name
            for name in capsule.names {
                let chinese = name.unicodeScalars.contains(where: CapsuleText.isUnspaced)
                if spelling, !chinese { continue }
                var keys = spelling ? [] : [fold(name)]
                if chinese { keys += Pinyin.keys(name) }
                for key in keys {
                    // A tie goes to the name in Poki's language: 大 is in 大众点评 and 大眾點評 alike, and
                    // with Poki in Traditional Chinese it is 大眾點評 that goes in, not the first listed.
                    guard let s = score(key, typed) else { continue }
                    if s > (best ?? -1) || (s == best && name == capsule.name) { best = s; matched = name }
                }
            }
            if let best {
                let recency = MentionRecents.rank(capsule.id).map { 20 - min($0, 19) } ?? 0
                // In the script it was typed in: the Chinese name for Chinese (or Pinyin) words, the
                // name shown in this language otherwise.
                let insert = matched.unicodeScalars.contains(where: CapsuleText.isUnspaced) ? matched : capsule.name
                scored.append((best + recency, MentionMatch(capsule: capsule, insert: insert)))
            }
        }
        var seen = Set<String>()
        return scored.sorted { $0.score > $1.score }.map(\.match).filter { seen.insert($0.capsule.id).inserted }.prefix(most).map { $0 }
    }

    /// 100 for the whole name, 80 for its start, 60 for the start of one of its words, 30 inside it.
    private static func score(_ key: String, _ typed: String) -> Int? {
        guard !typed.isEmpty, !key.isEmpty else { return nil }
        if key == typed { return 100 }
        if key.hasPrefix(typed) { return 80 }
        if key.split(separator: " ").dropFirst().contains(where: { $0.hasPrefix(typed) }) { return 60 }
        if typed.count >= 3, key.contains(typed) { return 30 }
        return nil
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    private static func isBoundary(_ unit: unichar) -> Bool {
        guard let scalar = UnicodeScalar(unit) else { return true }
        return CharacterSet.whitespacesAndNewlines.contains(scalar) || unit == 0xFFFC
    }

    private static func isLatin(_ unit: unichar) -> Bool {
        guard let scalar = UnicodeScalar(unit) else { return false }
        return CharacterSet.alphanumerics.contains(scalar) && !CapsuleText.isUnspaced(scalar)
    }

    private static func isUnspaced(_ unit: unichar) -> Bool {
        UnicodeScalar(unit).map(CapsuleText.isUnspaced) ?? false
    }
}

/// The Latin spellings a Chinese name is typed by on a Pinyin keyboard: whole ("taobao") and by
/// first letters ("tb"), so "taob" pending on the keyboard finds 淘宝 before it is chosen.
enum Pinyin {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: [String]] = [:]

    static func keys(_ name: String) -> [String] {
        if let hit = lock.withLock({ cache[name] }) { return hit }
        let latin = NSMutableString(string: name)
        CFStringTransform(latin as CFMutableString, nil, kCFStringTransformMandarinLatin, false)
        CFStringTransform(latin as CFMutableString, nil, kCFStringTransformStripCombiningMarks, false)
        let syllables = (latin as String).lowercased().split(separator: " ").map(String.init)
        let keys = [syllables.joined(), String(syllables.compactMap(\.first))]
        lock.withLock { cache[name] = keys }
        return keys
    }
}

/// The apps picked or written most recently, first: the attachment sheet's quick picks and the list
/// shown after a lone @.
enum MentionRecents {
    private static let key = "mentions.recent"
    static let most = 12

    static var ids: [String] { UserDefaults.standard.stringArray(forKey: key) ?? [] }

    static func rank(_ id: String) -> Int? { ids.firstIndex(of: id) }

    static func used(_ id: String) {
        var list = ids.filter { $0 != id }
        list.insert(id, at: 0)
        UserDefaults.standard.set(Array(list.prefix(most)), forKey: key)
    }

    /// Every app a sent message names.
    static func sent(_ text: String) {
        for case .app(let app, _) in CapsuleText.segments(text).reversed() where !app.isConnector { used(app.id) }
    }

    /// The recent apps that still make a capsule; with none yet, the first apps installed here that Poki knows.
    static var apps: [AppCapsule] {
        let catalog = AppCapsule.catalog
        let byID = Dictionary(catalog.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let recent = ids.compactMap { byID[$0] }
        if recent.count >= 4 { return recent }
        let installed = catalog.filter { app in !recent.contains(app) && DynamicApps.name(forID: app.id) != nil }
        return Array((recent + installed).prefix(most))
    }
}
