import XCTest

final class ComposerTaskSettingsUITests: XCTestCase {
    func testModelButtonExpandsAndReturnsToDraft() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-pokiChat", "empty", "-pokiDraft", "Draft for Poki", "-pokiComposerModelPreview",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US"
        ]
        app.launch()

        let editor = app.textViews["capsule.field"]
        let plus = app.buttons["composer.plus"]
        let model = app.buttons["composer.settings.model"]
        let close = app.buttons["composer.settings.close"]
        let addModel = app.buttons["composer.model.setup"]
        let chatGPT = app.buttons["composer.model.chatgpt.gpt-6.1-terra"]
        let deepSeek = app.buttons["composer.model.deepseek.deepseek-flash"]
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        let compactOffset = plus.frame.midY - editor.frame.midY

        // Writing moves the text above a row with plus, the model, and the voice buttons.
        editor.tap()
        XCTAssertTrue(model.waitForExistence(timeout: 5))
        XCTAssertTrue(model.isHittable)
        XCTAssertGreaterThan(plus.frame.midY - editor.frame.midY, compactOffset + 20)
        XCTAssertEqual(plus.frame.midY, model.frame.midY, accuracy: 2)
        XCTAssertLessThan(plus.frame.midX, model.frame.midX)
        XCTAssertEqual(editor.value as? String, "Draft for Poki")

        // Picking a model closes the sheet and gives the draft its keyboard back.
        model.tap()
        XCTAssertTrue(chatGPT.waitForExistence(timeout: 5))
        XCTAssertTrue(chatGPT.isSelected)
        if !deepSeek.isHittable { app.swipeUp() }
        deepSeek.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 5))
        XCTAssertTrue(model.waitForExistence(timeout: 5))
        // The keyboard comes back on the draft; where the caret lands is up to UIKit.
        editor.typeText(".")
        let edited = editor.value as? String
        XCTAssertEqual(edited?.count, "Draft for Poki.".count)
        XCTAssertEqual(edited?.replacingOccurrences(of: ".", with: ""), "Draft for Poki")

        model.tap()
        XCTAssertTrue(deepSeek.waitForExistence(timeout: 5))
        XCTAssertTrue(deepSeek.isSelected)

        // The approval modes sit below the models in the same sheet; each pick closes it.
        let options = ["reply", "confirm", "off"].map { app.buttons["composer.approval.\($0)"] }
        if !options[0].isHittable { app.swipeUp() }
        let originallySelected = options.first { $0.isSelected }
        XCTAssertNotNil(originallySelected)
        for option in options {
            if !option.isHittable { app.swipeUp() }
            XCTAssertTrue(option.isHittable)
            option.tap()
            XCTAssertTrue(close.waitForNonExistence(timeout: 5))
            model.tap()
            XCTAssertTrue(option.waitForExistence(timeout: 5))
            XCTAssertTrue(option.isSelected)
        }
        if let originallySelected {
            if !originallySelected.isHittable { app.swipeUp() }
            originallySelected.tap()
        }
        XCTAssertTrue(close.waitForNonExistence(timeout: 5))
        XCTAssertEqual(editor.value as? String, edited)

        model.tap()
        XCTAssertTrue(addModel.waitForExistence(timeout: 5))
        if !addModel.isHittable { app.swipeUp() }
        addModel.tap()
        XCTAssertTrue(app.navigationBars.matching(NSPredicate(format: "identifier IN %@", ["Models", "模型"])).firstMatch.waitForExistence(timeout: 5))
    }

    func testModelButtonReadsAddModelWithoutAnAccount() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-pokiChat", "empty", "-pokiDraft", "Draft for Poki", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()

        let editor = app.textViews["capsule.field"]
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        editor.tap()
        let model = app.buttons["composer.settings.model"]
        XCTAssertTrue(model.waitForExistence(timeout: 5))
        // The button names a model only when an account is set up; without one it says Add Model on screen.
        if let name = model.value as? String, !name.isEmpty {
            throw XCTSkip("This simulator has a model account (\(name)).")
        }
        XCTAssertEqual(model.label, "Add Model")
    }

    func testInputFieldPreviewStaysOnOneRowWithTheModelButtonOff() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-pokiScreen", "composer", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()

        let toggle = app.switches["composer.preference.model"]
        let plus = app.buttons["composer.preview.plus"]
        let main = app.buttons["composer.preview.main"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 15))
        XCTAssertTrue(plus.waitForExistence(timeout: 5))
        if (toggle.value as? String) != "1" { toggle.switches.firstMatch.tap() }
        wait(for: [expectation(for: NSPredicate(format: "value == '1'"), evaluatedWith: toggle)], timeout: 5)
        let expandedHeight = main.frame.maxY - toggle.frame.maxY

        toggle.switches.firstMatch.tap()
        wait(for: [expectation(for: NSPredicate(format: "value == '0'"), evaluatedWith: toggle)], timeout: 5)
        // With the model button off the preview is the one-row field: plus and the field share a row.
        let collapsed = NSPredicate { _, _ in main.frame.maxY - toggle.frame.maxY < expandedHeight - 20 }
        wait(for: [expectation(for: collapsed, evaluatedWith: nil)], timeout: 5)

        toggle.switches.firstMatch.tap()
        wait(for: [expectation(for: NSPredicate(format: "value == '1'"), evaluatedWith: toggle)], timeout: 5)
    }
}
