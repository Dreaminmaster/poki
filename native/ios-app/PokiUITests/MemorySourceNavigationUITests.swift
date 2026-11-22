import XCTest

/// True black-box verification of the Memory → Recent Updates → Source path.
/// Unlike a hosted XCTest/UIView walk, XCUIApplication sees SwiftUI's virtual
/// accessibility controls and taps the same navigation links as the owner.
final class MemorySourceNavigationUITests: XCTestCase {
    private let marker = "Synthetic saved source transcript"
    private let draft = "Synthetic unsent composer draft"

    private func launchFixture() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-pokiUITestMemorySource", "YES", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
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

    private func verifyDraftAfterClosing(_ app: XCUIApplication) {
        let close = app.buttons["details.done"]
        // The read-only source preview is pushed on Settings' own stack.
        // Return through real back buttons until its Close button is exposed;
        // don't assume a root-only toolbar stays visible on a pushed page.
        for _ in 0..<6 where !close.isHittable {
            let back = app.navigationBars.buttons
                .matching(NSPredicate(format: "identifier == %@ OR label BEGINSWITH[c] %@", "BackButton", "Back")).firstMatch
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
    }

    func testNarrowMemorySourceOpensActualTranscriptWithoutReplacingDraft() throws {
        let app = launchFixture()
        defer { app.terminate() }
        try XCTSkipUnless(app.frame.width < 750, "Run on an iPhone-size simulator")
        openSource(app)
        verifyDraftAfterClosing(app)
    }

    func testWideMemorySourceOpensActualTranscriptWithoutReplacingDraft() throws {
        let app = launchFixture()
        defer { app.terminate() }
        try XCTSkipUnless(app.frame.width >= 750, "Run on an iPad-size simulator")
        openSource(app)
        verifyDraftAfterClosing(app)
    }
}
