// Fork-only verification: compile the actual refreshMatches method with a small
// synthetic store, and mirror its SwiftUI task identity and revision signal.
// This is not a simulator test, and does not benchmark the real search index.
import { readFile, mkdtemp, writeFile, rm } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import assert from 'node:assert/strict';

const [sourcePath, expected] = process.argv.slice(2);
assert.ok(sourcePath && ['coalesced', 'restart'].includes(expected));
const source = await readFile(sourcePath, 'utf8');
const start = source.indexOf('    @MainActor private func refreshMatches(for ');
const end = source.indexOf('\n    /// A static resource key', start);
assert.ok(start >= 0 && end > start, 'actual refresh method must be present');
const method = source.slice(start, end).trimEnd();
const coalesced = expected === 'coalesced';
assert.ok(method.includes(coalesced ? 'for request: SearchRequest' : 'for key: SearchKey'));
assert.ok(source.includes(coalesced ? '.task(id: key.request)' : '.task(id: key)'));
if (coalesced) assert.ok(source.includes('.onChange(of: key.revision) { _, _ in refreshSignal?.yield(()) }'));

const swift = `
import Foundation

enum ConversationSearchIndex {
    typealias IndexedSession = UInt64
    struct Match: Sendable {
        let revision: UInt64
        let query: String
    }
    static func snapshot(in sessions: [UInt64]) -> [UInt64] { sessions }
    static func search(_ source: [UInt64], query: String) -> [Match] {
        Thread.sleep(forTimeInterval: 0.025)
        guard !Task.isCancelled else { return [] }
        return source.map { Match(revision: $0, query: query) }
    }
    static func resolve(_ hits: [Match], in sessions: [UInt64]) -> [Match] { hits }
}
typealias ConversationSearchHit = ConversationSearchIndex.Match

@MainActor final class Store {
    var searchRevision: UInt64 = 0
    var sessions: [UInt64] { [searchRevision] }
    var ordered: [UInt64] { sessions }
}

@MainActor final class Harness {
    let store = Store()
    var query = "museum"
    var locale = "en"
    var matches: [ConversationSearchIndex.Match] = []
    var resolvedMatches: [ConversationSearchHit] = []
    var cachedSnapshot: [ConversationSearchIndex.IndexedSession] = []
    var cachedRevision: UInt64?
    var cachedLocale: String?
    var refreshSignal: AsyncStream<Void>.Continuation?
    struct SearchRequest: Equatable {
        let query: String
        let locale: String
    }
    struct SearchKey: Equatable {
        let query: String
        let revision: UInt64
        let locale: String
        var request: SearchRequest { SearchRequest(query: query, locale: locale) }
    }
    var publications: [SearchKey] = []
    var publishedKey: SearchKey? {
        didSet {
            if let key = publishedKey { publications.append(key) }
        }
    }
    var searchKey: SearchKey {
        SearchKey(query: query, revision: store.searchRevision, locale: locale)
    }
    var task: Task<Void, Never>?
    func restart() {
        task?.cancel()
        let key = searchKey
        task = Task { await refreshMatches(for: ${coalesced ? 'key.request' : 'key'}) }
    }
    func revise() {
        store.searchRevision += 1
        ${coalesced ? 'refreshSignal?.yield(())' : 'restart()'}
    }

${method}

    func stop() async {
        task?.cancel()
        await task?.value
    }
    func eventually(_ predicate: () -> Bool, _ message: String) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !predicate() && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        check(predicate(), message)
    }
    func check(_ ok: Bool, _ message: String) {
        if !ok {
            print("FAIL: " + message)
            exit(1)
        }
    }

    func run() async {
        restart()
        for _ in 0..<24 {
            try? await Task.sleep(for: .milliseconds(50))
            revise()
        }
        let during = publications.count
        print("PUBLICATIONS_DURING_UPDATES=\\(during)")
        check(${coalesced ? 'during > 0' : 'during == 0'}, "unexpected publication count during continuous updates")
        await eventually({ self.publishedKey == self.searchKey }, "latest revision never arrived")
        check(matches.first?.revision == store.searchRevision, "latest result is stale")
        check(zip(publications, publications.dropFirst()).allSatisfy { $0.0.revision <= $0.1.revision }, "revision regressed")
        print("PASS: continuous updates and latest revision")

        // Switch before the previous worker's debounce can finish.
        let boundary = publications.count
        revise()
        query = "lighthouse"
        restart()
        await eventually({ self.publishedKey == self.searchKey }, "new query never arrived")
        check(matches.first?.query == query, "wrong query results")
        check(publications.dropFirst(boundary).allSatisfy { $0.query == self.query }, "old query published after switch")
        print("PASS: query switch")

        locale = "zh-Hans"
        restart()
        await eventually({ self.publishedKey == self.searchKey }, "locale refresh never arrived")
        check(cachedLocale == locale, "index locale was not refreshed")
        print("PASS: locale switch")

        query = ""
        restart()
        await eventually({ self.publishedKey == self.searchKey }, "empty query never published")
        check(matches.isEmpty && resolvedMatches.isEmpty, "cleared query retained old results")
        print("PASS: clear query")
        await stop()
    }
}

@main struct Runner {
    @MainActor static func main() async {
        await Harness().run()
    }
}
`;
const dir = await mkdtemp(join(tmpdir(), 'poki-search-refresh-'));
try {
    const input = join(dir, 'main.swift');
    const executable = join(dir, 'check');
    await writeFile(input, swift);
    execFileSync('swiftc', ['-swift-version', '6', '-parse-as-library', input, '-o', executable], {stdio: 'inherit'});
    execFileSync(executable, [], {stdio: 'inherit', timeout: 60_000});
} finally {
    await rm(dir, {recursive: true, force: true});
}
