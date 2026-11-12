import XCTest
@testable import PokiCore

/// ESP-465: sending a message in a chat app, as the owner's phone log showed it (build 800, where
/// Approvals were off, so nothing here waits for the owner).
final class ChatSendTests: XCTestCase {
    func number(of type: String, in text: String) -> Int? {
        for line in text.split(separator: "\n") where line.contains(type) {
            let digits = line.drop(while: { !$0.isNumber }).prefix(while: \.isNumber)
            if let n = Int(digits) { return n }
        }
        return nil
    }

    /// The model tapped the message field between typing and Return (3 of 6 sends in the log). A
    /// routine saved from that task replayed the tap every time; it is now left out of the routine.
    func testARoutineLeavesOutATapOnTheFieldBetweenTypingAndReturn() async {
        let store = RoutineStore(url: nil)
        let chat = ChatApp()
        let wda = FakeWDA()
        chat.install(wda)
        let (core, _, _) = makeCore(wda) { $0.memory = store; $0.sensitive.enabled = false }
        _ = await core.call("look", [:])
        // The empty field has no name and is not listed: the model taps where it is, then types.
        let typed = await core.call("do", ["actions": [["tap": [190, 468]], ["type": "收到"]]])
        guard let again = number(of: "TextView", in: typed.text) else { return XCTFail(typed.text) }
        _ = await core.call("do", ["actions": [["tap": .number(Double(again))], ["key": "return"]]])
        XCTAssertEqual(chat.messages.value.last, "收到")
        _ = await core.call("routines", ["action": "save", "name": "reply", "description": "reply in the chat"])
        let steps = store.routine(named: "reply")?.steps ?? []
        XCTAssertEqual(steps.count, 3, "the tap that focused the field, the type and the Return, without the second tap: \(steps.map { $0.action.serialized() })")
        XCTAssertNotNil(steps[1].action["type"])
        XCTAssertEqual(steps.last?.action["key"]?.string, "return")
    }

    /// A tap on the field before anything was typed focuses it, and stays in the routine.
    func testATapOnTheFieldBeforeTypingStays() async {
        let store = RoutineStore(url: nil)
        let chat = ChatApp()
        let wda = FakeWDA()
        chat.install(wda)
        let (core, _, _) = makeCore(wda) { $0.memory = store; $0.sensitive.enabled = false }
        _ = await core.call("look", [:])
        _ = await core.call("do", ["actions": [["tap": [190, 468]], ["type": "收到"], ["key": "return"]]])
        _ = await core.call("routines", ["action": "save", "name": "reply", "description": "reply in the chat"])
        XCTAssertEqual(store.routine(named: "reply")?.steps.count, 3)
    }

    func chat(_ app: ChatApp = ChatApp()) -> (PokiCore, ChatApp) {
        let wda = FakeWDA()
        app.install(wda)
        let (core, _, _) = makeCore(wda) { $0.sensitive.enabled = false }
        return (core, app)
    }

    /// After Return the model looked again, or spent a turn, to see whether the message went (the gap
    /// from Return to done was 14 to 26 s in the log). The Return answer now says so from its own read.
    func testTheReturnAnswerSaysTheMessageWasSent() async {
        let (core, app) = chat()
        _ = await core.call("look", [:])
        _ = await core.call("do", ["actions": [["tap": [190, 468]], ["type": "收到"]]])
        let sent = await core.call("do", ["actions": [["key": "return"]]])
        XCTAssertEqual(app.messages.value.last, "收到")
        XCTAssertTrue(sent.text.contains("send check: sent"), sent.text)
        XCTAssertTrue(sent.text.contains("\"收到\""), sent.text)
    }

    func testTypeAndReturnInOneCallAreCheckedToo() async {
        let (core, _) = chat()
        _ = await core.call("look", [:])
        let sent = await core.call("do", ["actions": [["tap": [190, 468]], ["type": "收到"], ["key": "return"]]])
        XCTAssertTrue(sent.text.contains("send check: sent"), sent.text)
    }

    /// The send key did nothing: the text is still in the field, and the answer says the send is not
    /// confirmed, so the model looks before it reports.
    func testAReturnThatSentNothingIsNotConfirmed() async {
        let app = ChatApp()
        app.sends.value = false
        let (core, _) = chat(app)
        _ = await core.call("look", [:])
        _ = await core.call("do", ["actions": [["tap": [190, 468]], ["type": "收到"]]])
        let tried = await core.call("do", ["actions": [["key": "return"]]])
        XCTAssertTrue(tried.text.contains("send check: not confirmed"), tried.text)
        XCTAssertTrue(tried.text.contains("the message field still holds the text"), tried.text)
    }

    /// The field emptied but the last message is another one: not confirmed either.
    func testAnEmptiedFieldWithAnotherLastMessageIsNotConfirmed() async {
        let app = ChatApp()
        let (core, _) = chat(app)
        _ = await core.call("look", [:])
        _ = await core.call("do", ["actions": [["tap": [190, 468]], ["type": "收到"]]])
        app.sends.value = false
        app.field.value = ""
        let tried = await core.call("do", ["actions": [["key": "return"]]])
        XCTAssertTrue(tried.text.contains("send check: not confirmed"), tried.text)
        XCTAssertTrue(tried.text.contains("the last message on screen reads \"明天见\""), tried.text)
    }
}
