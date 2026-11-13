import SwiftUI
import XCTest
@testable import Poki

@MainActor
final class AppNamePresentationTests: XCTestCase {
    private var weChat: String {
        switch AppLanguage.current {
        case .english: "WeChat"
        case .simplifiedChinese: "微信"
        case .traditionalChinese: "微信"
        }
    }

    func testTaskCardsShowNamesAndOmitUnknownIdentifiers() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let covered = scene.windows.filter { !$0.accessibilityElementsHidden }
        covered.forEach { $0.accessibilityElementsHidden = true }
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        defer {
            window.isHidden = true
            covered.forEach { $0.accessibilityElementsHidden = false }
        }
        let output = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AppNameEvidence")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let end = Date()
        for (index, state) in [TaskCardState.done, .failed, .stopped, .running, .needsYou, .yourTurn].enumerated() {
            window.rootViewController = UIHostingController(rootView:
                VStack(spacing: 20) {
                    TaskCard(title: "打开微信", steps: [], state: state, app: "com.tencent.xin",
                             started: end.addingTimeInterval(-13), ended: end)
                    TaskCard(title: "打开应用", steps: [], state: state, app: "org.example.unlisted",
                             started: end.addingTimeInterval(-13), ended: end)
                }.padding().frame(maxHeight: .infinity).background(Color(.systemGroupedBackground))
                    .accessibilityElement(children: .contain).accessibilityIdentifier("app.names.\(index)"))
            window.makeKeyAndVisible()
            window.layoutIfNeeded()
            CATransaction.flush()
            var source = ""
            let deadline = CACurrentMediaTime() + 30
            repeat {
                source = await Task.detached {
                    var code: NSString?
                    return PKInProcess.shared().sourceXML(nil, code: &code) ?? ""
                }.value
                if source.contains("app.names.\(index)") { break }
            } while CACurrentMediaTime() < deadline
            XCTAssertTrue(source.contains("app.names.\(index)"), "The task cards must be on screen")
            try source.write(to: output.appendingPathComponent("cards-\(index).xml"), atomically: true, encoding: .utf8)
            if state == .done {
                let data = await Task.detached {
                    var code: NSString?
                    return PKInProcess.shared().screenshot(&code)
                }.value
                try XCTUnwrap(UIImage(data: try XCTUnwrap(data))?.pngData()).write(to: output.appendingPathComponent("task-cards.png"))
                XCTAssertTrue(source.contains("0:13"), "Omitting an app must retain its elapsed time")
            }
            XCTAssertFalse(source.contains("com.tencent.xin") || source.contains("org.example.unlisted"), "An internal identifier reached a task card: \(source)")
            if state != .needsYou { XCTAssertTrue(source.contains(weChat), "The known app must have a name") }
        }
    }

    func testActivityPresentationDoesNotExposeAppIdentifiers() {
        for (app, expected) in [("com.tencent.xin", Optional(weChat)), ("org.example.unlisted", nil), ("My Reader", "My Reader")] {
            var state = PokiState(phase: .working, headline: "Thinking", thumbnailVersion: 0)
            state.app = app
            XCTAssertEqual(state.face.kicker, expected)
            state.event = .init(kind: .app, text: app)
            XCTAssertEqual(state.face.event, expected)
            state.phase = .done
            XCTAssertFalse(state.face.content.contains(app) && app.contains("."))
            if let expected { XCTAssertTrue(state.face.content.contains(expected)) }
            state.app = nil
            state.headline = "Finished in \(app)"
            XCTAssertFalse(state.doneTitle.contains(app) && app.contains("."))
            XCTAssertFalse(ActivityWords.label("Open \(app)").contains(app) && app.contains("."))
            XCTAssertFalse(ActivityWords.reason("input in \(app)").contains(app) && app.contains("."))
        }
    }

    func testNewTaskWithAnUnreadableScreenDoesNotInheritThePreviousApp() {
        let activity = ActivityController()
        var task = TaskApps()
        task.step(in: "Notes")
        activity.update { $0.phase = .working }
        activity.update { $0.app = task.target(request: "Open Notes") }
        activity.finishNow(alert: false)
        XCTAssertEqual(activity.state.app, "com.apple.mobilenotes")

        task = TaskApps()
        activity.update { $0.phase = .working; $0.headline = "Open WeChat" }
        task.step(in: nil)
        activity.record(step: "Look at the screen", ok: false)
        XCTAssertNil(task.target(request: "Open WeChat"), "The new card has no observed app")
        XCTAssertNil(activity.state.app, "The new island must not carry Notes from the previous task")

        task.launch("com.tencent.xin")
        task.step(in: nil)
        XCTAssertEqual(task.target(request: "Open WeChat"), "com.tencent.xin", "The intended launch still identifies this task when its screen cannot be read")
    }
}
