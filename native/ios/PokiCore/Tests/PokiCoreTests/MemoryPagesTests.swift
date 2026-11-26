import XCTest
@testable import PokiCore

/// Memory as pages: About You and one page per app, whose lines keep their ids.
final class MemoryPagesTests: XCTestCase {
    let wechat = "com.tencent.xin"

    func testNotesFromBeforePagesBecomeTheLinesOfTheirAppsPages() throws {
        let old = """
        {"schema":"poki.agent-backup/2","skills":[],"runs":[],"notes":[
         {"id":"a1","text":"Mom is Mama in Contacts","by":"owner","at":"2026-11-01T10:00:00Z","locked":true},
         {"id":"b2","text":"Sends voice notes to Mom","by":"Poki","at":"2026-11-02T10:00:00Z","app":"com.tencent.xin"},
         {"id":"c3","text":"Answers in English","by":"Poki","at":"2026-11-03T10:00:00Z"}]}
        """
        let file = try SkillStore.decoder.decode(MemoryFile.self, from: Data(old.utf8))
        XCTAssertEqual(file.pages.map(\.app), [nil, wechat])
        XCTAssertEqual(file.pages[0].lines.map(\.id), ["a1", "c3"])
        XCTAssertEqual(file.pages[1].lines.map(\.id), ["b2"])
        XCTAssertTrue(file.pages[0].lines[0].isLocked)
        // Written back, it carries the pages and still the flat list, for an older Poki or Poki Setup.
        let written = try JSONSerialization.jsonObject(with: SkillStore.encoder.encode(file)) as? [String: Any]
        XCTAssertEqual((written?["pages"] as? [Any])?.count, 2)
        XCTAssertEqual((written?["notes"] as? [Any])?.count, 3)
    }

    func testAnAgentWritesAWholePageAndKeepsTheLinesThatStillHold() {
        let store = SkillStore(url: nil)
        let kept = store.remember("Sends voice notes to Mom", by: "Poki", app: wechat)!
        store.remember("Pins the family group", by: "Poki", app: wechat)

        let result = store.writePage(app: wechat, text: "- Sends voice notes to Mom\n- Never calls after 10 pm", summary: "Family chats", by: "Poki")

        guard case .written(let page, let locked) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(locked, 0)
        XCTAssertEqual(page.lines.map(\.text), ["Sends voice notes to Mom", "Never calls after 10 pm"])
        XCTAssertEqual(page.lines[0].id, kept.id, "a line that still holds keeps its id for finish_task's memory ids")
        XCTAssertEqual(store.page(wechat)?.summary, "Family chats")
        XCTAssertEqual(store.notes.count, 2)
    }

    func testAnAgentCannotDropALockedLineOrWriteALockedPage() {
        let store = SkillStore(url: nil)
        store.remember("Mom is Mama in Contacts", by: SkillStore.owner, locked: true)
        store.remember("Prefers short answers", by: "Poki")

        guard case .written(let page, let kept) = store.writePage(app: nil, text: "Prefers short answers", by: "Poki") else { return XCTFail() }
        XCTAssertEqual(kept, 1)
        XCTAssertTrue(page.lines.contains { $0.text == "Mom is Mama in Contacts" })

        store.setPageLocked(nil, true)
        XCTAssertEqual(store.writePage(app: nil, text: "Something else", by: "Poki"), .locked)
        if case .locked = store.writePage(app: nil, text: "Only this", by: SkillStore.owner) { XCTFail("the owner writes a locked page") }
        XCTAssertEqual(store.page(nil)?.lines.map(\.text), ["Only this"])
    }

    func testUndoPutsAWrittenPageBack() throws {
        let store = SkillStore(url: nil)
        store.remember("Orders a grande oat latte", by: "Poki", app: "com.starbucks.mystarbucks")
        store.writePage(app: "com.starbucks.mystarbucks", text: "Orders a tall black coffee", by: "Dream")
        let change = try XCTUnwrap(store.changes.first)
        XCTAssertNotNil(change.page)

        XCTAssertTrue(store.undo(change.id))

        XCTAssertEqual(store.page("com.starbucks.mystarbucks")?.lines.map(\.text), ["Orders a grande oat latte"])
    }

    func testTheBriefShowsLinesUnderTheirPageAndNamesTheOtherPages() {
        let store = SkillStore(url: nil)
        let settings = "com.apple.Preferences"
        store.remember("Use concise answers.", by: SkillStore.owner)
        store.remember("Include the build number with the iOS version.", by: SkillStore.owner, app: settings)
        store.remember("Pins the family group", by: "Poki", app: wechat)

        let brief = store.taskBrief(for: "Find the iOS version in Settings", apps: [settings])

        XCTAssertTrue(brief.text.contains("About You:\n- ["), brief.text)
        XCTAssertTrue(brief.text.contains("\(settings):\n- ["), brief.text)
        XCTAssertFalse(brief.text.contains("Pins the family group"), brief.text)
        XCTAssertTrue(brief.text.contains("Other memory pages"), brief.text)
        XCTAssertTrue(brief.text.contains(wechat), brief.text)
        XCTAssertEqual(Set(brief.notes.map(\.text)), ["Use concise answers.", "Include the build number with the iOS version."])
    }

    func testTheToolReadsAPageWithItsAppsSkillsAndWritesIt() async {
        let store = SkillStore(url: nil)
        store.remember("Pins the family group", by: "Poki", app: wechat)
        let (core, _, _) = makeCore(FakeWDA()) { $0.memory = store }

        let page = await core.call("skills", ["action": "page", "app": .string(wechat)])
        XCTAssertTrue(page.text.contains("Pins the family group"), page.text)

        let wrote = await core.call("skills", ["action": "write_page", "app": .string(wechat), "text": "Pins the family group\nMutes work chats on weekends"])
        XCTAssertFalse(wrote.isError, wrote.text)
        XCTAssertEqual(store.page(wechat)?.lines.count, 2)

        let listed = await core.call("skills", ["action": "list"])
        XCTAssertTrue(listed.text.contains("\(wechat):\n- ["), listed.text)
    }
}
