import XCTest
@testable import Poki

@MainActor
final class SensesSuggestionsTests: XCTestCase {
    private let entries = [
        HistoryEntry(id: 1, at: Date(timeIntervalSince1970: 1), app: "com.apple.mobilenotes",
                     title: "Draft outline", text: "captured text marker one"),
        HistoryEntry(id: 2, at: Date(timeIntervalSince1970: 2), app: "com.apple.mobilesafari",
                     title: "Weekend plans", text: "captured text marker two"),
    ]

    func testOnlineFollowUpPromptKeepsTitlesAndOmitsCapturedScreenText() {
        let prompt = SensesSuggestions.followUpPrompt(from: entries, using: .chat)
        for entry in entries {
            XCTAssertTrue(prompt.contains(entry.title))
            XCTAssertFalse(prompt.contains(entry.text))
        }
    }

    func testOnDeviceFollowUpPromptKeepsCapturedScreenText() {
        let prompt = SensesSuggestions.followUpPrompt(from: entries, using: .onDevice)
        for entry in entries {
            XCTAssertTrue(prompt.contains(entry.title))
            XCTAssertTrue(prompt.contains(entry.text))
        }
    }
}
