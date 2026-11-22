import XCTest

/// True black-box verification of the Memory → Recent Updates → Source path.
/// Unlike a hosted XCTest/UIView walk, XCUIApplication sees SwiftUI's virtual
/// accessibility controls and taps the same navigation links as the owner.
final class MemorySourceNavigationUITests: XCTestCase {
    private let marker = "Synthetic saved source transcript"
    private let draft = "Synthetic unsent composer draft"

    private func launchFixture(liveTask: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-pokiUITestMemorySource", "YES", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if liveTask { app.launchArguments += ["-pokiUITestLiveTask", "YES"] }
        app.launch()
        return app
    }

    private func screenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func openSource(_ app: XCUIApplication) {
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "memory.openChange.")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "Recent Updates must show the synthetic memory row")
        XCTAssertTrue(row.isHittable, "The real Recent Updates row must be available for a tap")
        screenshot(app, name: "Memory Recent Updates before opening row")
        row.tap()

        let source = app.buttons["memory.source.conversation"]
        XCTAssertTrue(source.waitForExistence(timeout: 10), "The actual Memory Source link must appear on the item")
        for _ in 0..<6 where !source.isHittable { app.swipeUp() }
        XCTAssertTrue(source.isHittable, "The owner must be able to tap the actual Source link")
        source.tap()

        let target = app.staticTexts[marker]
        XCTAssertTrue(target.waitForExistence(timeout: 12), "Opening Source must reveal the saved message, not merely its title")
        screenshot(app, name: "Memory Source actual saved transcript")
        XCTAssertTrue(target.exists)
    }

    private func verifyDraftAfterClosing(_ app: XCUIApplication, expectRunning: Bool) {
        let close = app.buttons["details.done"]
        // The read-only source preview is pushed on Settings' own stack.
        // Return through real back buttons until its Close button is exposed;
        // don't assume a root-only toolbar stays visible on a pushed page.
        for _ in 0..<6 where !close.isHittable {
            // SwiftUI may expose its navigation BackButton in the global
            // accessibility tree, not as a child of a UIKit navigationBar
            // (observed on iPhone after opening the saved transcript).
            let back = app.buttons["BackButton"]
            guard back.exists && back.isHittable else { break }
            back.tap()
        }
        XCTAssertTrue(close.waitForExistence(timeout: 10), "Settings must stay presented until the owner closes it")
        XCTAssertTrue(close.isHittable, "The source preview must let the owner return and close Settings")
        close.tap()
        let original = app.staticTexts["Active synthetic chat"]
        XCTAssertTrue(original.waitForExistence(timeout: 12), "The active chat must remain after the source preview")
        let editor = app.textViews.matching(NSPredicate(format: "value CONTAINS %@", draft)).firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10), "The unsent draft must survive the Memory navigation")
        XCTAssertTrue(editor.value as? String == draft)
        // The narrow preview must not cancel the *genuine* held model task.
        // A wide idle view must not spuriously start one either.
        XCTAssertEqual(app.buttons["composer.main"].label, expectRunning ? "Stop" : "Send")
    }


    /// End-to-end search: use the real Settings row, system search field, and
    /// search-result button. No direct navigation or test-only scroll invocation.
    private func searchForMessage(_ phrase: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-pokiUITestConversationSearch", "YES",
                                "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let conversations = app.descendants(matching: .any)["details.searchConversations"]
        XCTAssertTrue(conversations.waitForExistence(timeout: 20), "Settings must show Conversations")
        conversations.tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10), "Conversations must provide native search")
        search.tap()
        search.typeText(phrase)
        let result = app.buttons["search.message"].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 20), "A full-text matching message must be listed")
        screenshot(app, name: "Conversation search matching result")
        result.tap()
        let target = app.staticTexts[phrase]
        XCTAssertTrue(target.waitForExistence(timeout: 15), "Search must open the matching transcript message")
        XCTAssertTrue(target.isHittable, "The exact matching message must settle within the viewport")
        screenshot(app, name: "Conversation search exact message in viewport")
        return app
    }

    func testConversationSearchOpensNormalMessageAtExactHit() throws {
        let app = searchForMessage("Synthetic ordinary search needle")
        defer { app.terminate() }
        XCTAssertFalse(app.staticTexts["Synthetic unrelated approval greeting"].exists,
                       "An ordinary result must not expose the hidden opening greeting")
    }

    func testConversationSearchRevealsSelectedGreetingOnly() throws {
        let app = searchForMessage("Synthetic greeting search needle")
        defer { app.terminate() }
        XCTAssertFalse(app.staticTexts["Synthetic unrelated approval greeting"].exists,
                       "Selecting an opening greeting must not expose unrelated opening content")
    }

    func testNarrowMemorySourceOpensActualTranscriptWithoutReplacingDraft() throws {
        // Starts a genuine ChatModel.send using a held HTTP fixture request.
        // A narrow idle chat intentionally restores the saved conversation
        // instead, so using an idle fixture here would test the wrong policy.
        let app = launchFixture(liveTask: true)
        defer { app.terminate() }
        try XCTSkipUnless(app.frame.width < 750, "Run on an iPhone-size simulator")
        let composer = app.buttons["composer.main"]
        XCTAssertTrue(composer.waitForExistence(timeout: 15), "The real chat composer must be loaded")
        XCTAssertEqual(composer.label, "Stop", "The fixture must start a real in-flight chat before any Memory navigation")
        openSource(app)
        verifyDraftAfterClosing(app, expectRunning: true)
    }

    func testWideMemorySourceOpensActualTranscriptWithoutReplacingDraft() throws {
        let app = launchFixture()
        defer { app.terminate() }
        try XCTSkipUnless(app.frame.width >= 750, "Run on an iPad-size simulator")
        openSource(app)
        verifyDraftAfterClosing(app, expectRunning: false)
    }
}
