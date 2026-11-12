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
}
