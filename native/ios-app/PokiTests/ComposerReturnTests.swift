import SwiftUI
import UIKit
import XCTest
@testable import Poki

@MainActor
final class ComposerReturnTests: XCTestCase {
    private var window: UIWindow?
    private var draft: Draft?

    override func tearDown() {
        window?.isHidden = true
        window = nil
        draft = nil
    }

    func testReturnSendsTheMessageAndAnEmptyFieldSendsNothing() throws {
        let (field, draft) = try composer()
        XCTAssertFalse(try pressReturn(field))
        XCTAssertEqual(draft.sent, [])
        XCTAssertEqual(field.plainText, "")

        type("Open Settings", into: field)
        settle { draft.text == "Open Settings" }
        XCTAssertFalse(try pressReturn(field))
        XCTAssertEqual(draft.sent, ["Open Settings"])
        settle { field.plainText.isEmpty }
        XCTAssertEqual(field.plainText, "")

        type("I dont", into: field)
        let start = try XCTUnwrap(field.position(from: field.endOfDocument, offset: -4))
        field.replace(try XCTUnwrap(field.textRange(from: start, to: field.endOfDocument)), withText: "don’t")
        field.delegate?.textViewDidChange?(field)
        XCTAssertFalse(try pressReturn(field))
        XCTAssertEqual(draft.sent, ["Open Settings", "I don’t"])
    }

    func testReturnDuringCompositionKeepsTheDraft() throws {
        let (field, draft) = try composer()
        field.setMarkedText("nihao", selectedRange: NSRange(location: 5, length: 0))
        field.delegate?.textViewDidChange?(field)
        settle { draft.text == "nihao" }
        XCTAssertNotNil(field.markedTextRange)
        _ = try pressReturn(field)
        XCTAssertEqual(draft.sent, [])
        XCTAssertEqual(field.plainText, "nihao")
        field.unmarkText()
        field.delegate?.textViewDidChange?(field)
        XCTAssertFalse(try pressReturn(field))
        XCTAssertEqual(draft.sent, ["nihao"])
        settle { field.plainText.isEmpty }
    }

    func testPastingTextThatEndsInANewLineKeepsTheDraft() throws {
        let (field, draft) = try composer()
        let previous = UIPasteboard.general.items
        defer { UIPasteboard.general.items = previous }
        type("Draft", into: field)
        settle { draft.text == "Draft" }
        field.selectedTextRange = field.textRange(from: field.beginningOfDocument, to: field.endOfDocument)
        UIPasteboard.general.string = "Draft\n"
        field.paste(nil)
        settle { draft.text == "Draft\n" }
        XCTAssertEqual(draft.sent, [])
        XCTAssertEqual(field.plainText, "Draft\n")

        UIPasteboard.general.string = "\n"
        field.selectedTextRange = field.textRange(from: field.endOfDocument, to: field.endOfDocument)
        field.paste(nil)
        settle { draft.text == "Draft\n\n" }
        XCTAssertEqual(draft.sent, [])
        XCTAssertEqual(field.plainText, "Draft\n\n")
    }

    func testShiftReturnInsertsANewLineWithoutSending() throws {
        let (field, draft) = try composer()
        type("First line", into: field)
        settle { draft.text == "First line" }
        let command = try XCTUnwrap(field.keyCommands?.first {
            $0.input == "\r" && $0.modifierFlags == .shift
        })
        XCTAssertTrue(UIApplication.shared.sendAction(try XCTUnwrap(command.action), to: field, from: command, for: nil))
        settle { draft.text == "First line\n" }
        XCTAssertEqual(draft.sent, [])
    }

    func testChangingFocusAndSizeKeepsTheSameEditorAndDraft() throws {
        let (field, draft) = try composer()
        type("Keep my draft", into: field)
        settle { draft.text == "Keep my draft" }
        draft.focused = false
        settle { !field.isFirstResponder }
        window?.frame.size.width = 240
        window?.layoutIfNeeded()
        settle { field.bounds.width > 180 }
        draft.typeSize = .accessibility5
        settle { (field.font?.pointSize ?? 0) > 40 }
        draft.focused = true
        settle { field.isFirstResponder }
        XCTAssertTrue(Self.textView(in: try XCTUnwrap(window)) === field)
        XCTAssertEqual(field.plainText, "Keep my draft")
        XCTAssertEqual(draft.text, "Keep my draft")
        XCTAssertEqual(draft.sent, [])
    }

    private func pressReturn(_ field: CapsuleTextView) throws -> Bool {
        try XCTUnwrap(field.delegate?.textView?(field, shouldChangeTextIn: field.selectedRange, replacementText: "\n"))
    }

    private func type(_ text: String, into field: CapsuleTextView) {
        field.insertText(text)
        field.delegate?.textViewDidChange?(field)
    }

    private func composer() throws -> (CapsuleTextView, Draft) {
        let draft = Draft()
        self.draft = draft
        let app = AppModel(launcher: FakeLauncher(), pairer: FakePairing())
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 200)
        window.rootViewController = UIHostingController(rootView: Host(draft: draft).environment(app))
        window.makeKeyAndVisible()
        self.window = window
        settle { Self.textView(in: window) != nil }
        let field = try XCTUnwrap(Self.textView(in: window))
        field.becomeFirstResponder()
        settle { field.isFirstResponder }
        return (field, draft)
    }

    private func settle(until done: () -> Bool) {
        let end = Date().addingTimeInterval(2)
        while !done(), Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(done())
    }

    private static func textView(in view: UIView) -> CapsuleTextView? {
        if let text = view as? CapsuleTextView { return text }
        for child in view.subviews { if let found = textView(in: child) { return found } }
        return nil
    }

    private final class Draft: ObservableObject {
        @Published var text = ""
        @Published var focused = true
        @Published var typeSize: DynamicTypeSize = .large
        var sent: [String] = []
    }

    private struct Host: View {
        @ObservedObject var draft: Draft
        var body: some View {
            ComposerInputView(input: $draft.text, focused: $draft.focused, running: false,
                              send: { text, _ in draft.sent.append(text) }, stop: {}, openVoice: {})
                .dynamicTypeSize(draft.typeSize)
        }
    }
}
