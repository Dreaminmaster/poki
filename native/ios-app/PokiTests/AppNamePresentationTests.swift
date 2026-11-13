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
        var known = ChatEntry(.plan([]))
        known.title = "打开微信"
        known.app = "com.tencent.xin"
        var unknown = ChatEntry(.plan([]))
        unknown.title = "打开应用"
        unknown.app = "org.example.unlisted"
        let archive = try JSONEncoder().encode([known, unknown])
        let restored = try JSONDecoder().decode([ChatEntry].self, from: archive)
        let icons = AppIconStore(installed: { _, _ in nil })
        for identity in ["com.tencent.xin", " COM.TENCENT.XIN ", "微信", "WeChat"] {
            XCTAssertNotNil(icons.icon(identity), "WeChat must have its carried icon even without a system icon")
        }
        for (index, state) in [TaskCardState.done, .failed, .stopped, .running, .needsYou, .yourTurn].enumerated() {
            window.rootViewController = UIHostingController(rootView:
                VStack(spacing: 20) {
                    TaskCard(title: restored[0].title ?? "", steps: [], state: state, app: restored[0].app,
                             started: end.addingTimeInterval(-13), ended: end)
                    TaskCard(title: restored[1].title ?? "", steps: [], state: state, app: restored[1].app,
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
            if state != .needsYou { XCTAssertTrue(source.contains("\(weChat)，") || source.contains("\(weChat),"), "The subtitle must name the known app") }
        }
    }

    func testActivityPresentationDoesNotExposeAppIdentifiers() {
        for (app, expected) in [("com.tencent.xin", Optional(weChat)), ("org.example.unlisted", nil), ("My Reader", "My Reader")] {
            var state = PokiState(phase: .working, headline: "Thinking", thumbnailVersion: 0)
            state.app = app
            state.plan = .init(steps: ["Open the app"], current: 1, title: "Open the app")
            state.since = Date(timeIntervalSince1970: 0)
            state.endedAt = Date(timeIntervalSince1970: 13)
            XCTAssertEqual(state.face.kicker, expected)
            state.event = .init(kind: .app, text: app)
            XCTAssertNil(state.face.event, "App switches are already named by the kicker")
            state.phase = .done
            XCTAssertEqual(state.face.content, "Open the app", "The completed task keeps its title")
            XCTAssertTrue(state.face.subtitle?.contains("0:13") == true, "The duration stays visible with no app")
            if let expected { XCTAssertTrue(state.face.subtitle?.contains(expected) == true) }
            XCTAssertFalse(state.face.subtitle?.contains(app) == true && app.contains("."))
            state.app = nil
            state.headline = "Finished in \(app)"
            XCTAssertEqual(state.doneTitle, "Open the app")
            XCTAssertFalse(state.face.subtitle?.contains(app) == true)
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
