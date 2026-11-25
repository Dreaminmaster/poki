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
}
