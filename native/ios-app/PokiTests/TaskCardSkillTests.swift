import SwiftUI
import UIKit
import XCTest
@testable import Poki

@MainActor
final class TaskCardSkillTests: XCTestCase {
    private var savedLanguage = AppLocalization.system

    override func setUp() async throws {
        savedLanguage = AppLocalization.shared.preference
    }

    override func tearDown() async throws {
        AppLocalization.shared.preference = savedLanguage
    }

    func testSkillRowUsesDedicatedPrefixWithoutEmDashAcrossLanguages() async throws {
        let cases: [(language: String, skills: [String], expected: String, forbidden: [String])] = [
            ("zh-Hans", ["点常点的那家"], "使用技能 - 点常点的那家", ["用到了：", "—", "——"]),
            ("zh-Hant", ["點常點的那家"], "使用技能 - 點常點的那家", ["用到了：", "—", "——"]),
            ("en", ["Order usual"], "Using skill - Order usual", ["Used:", "—", "——"]),
            ("zh-Hans", ["查天气", "发消息"], "使用技能 - 查天气和发消息", ["用到了：", "—", "——"]),
            ("en", ["Order usual", "Check ETA"], "Using skill - Order usual and Check ETA", ["Used:", "—", "——"]),
        ]

        for (index, item) in cases.enumerated() {
            AppLocalization.shared.preference = item.language
            let source = try await renderTaskCardXML(
                state: .done,
                memoryUse: TaskMemoryUse(notes: [], skills: item.skills),
                containerID: "taskcard.skill.lang.\(index)"
            )
            XCTAssertTrue(source.contains(item.expected),
                          "[\(item.language)] expected \(item.expected) in XML:\n\(source)")
            for banned in item.forbidden {
                XCTAssertFalse(source.contains(banned),
                               "[\(item.language)] unexpected \(banned) in XML:\n\(source)")
            }
        }
    }

    func testSkillAndMemoryRenderOnSeparateRowsWithoutMixing() async throws {
        let library = MemoryLibrary.shared
        let noteText = "Espresso with less ice \(UUID().uuidString.prefix(6))"
        library.add(noteText, app: nil)
        let item = try XCTUnwrap(library.items.first { $0.kind == .memory && $0.text == noteText })
        defer { library.forget(item.id) }
        let noteRef = TaskMemoryUse.Note(id: item.id, updatedAtSeconds: Int64(item.updated.timeIntervalSince1970))

        // 1. Skill only
        AppLocalization.shared.preference = "en"
        let skillOnlyXML = try await renderTaskCardXML(
            state: .done,
            memoryUse: TaskMemoryUse(notes: [], skills: ["Order usual"]),
            containerID: "taskcard.sep.skillOnly"
        )
        XCTAssertTrue(skillOnlyXML.contains("Using skill - Order usual"), skillOnlyXML)
        XCTAssertFalse(skillOnlyXML.contains("Used:"), skillOnlyXML)

        // 2. Memory only
        let memoryOnlyXML = try await renderTaskCardXML(
            state: .done,
            memoryUse: TaskMemoryUse(notes: [noteRef], skills: []),
            containerID: "taskcard.sep.memoryOnly"
        )
        XCTAssertTrue(memoryOnlyXML.contains("Used: \(noteText)"), memoryOnlyXML)
        XCTAssertFalse(memoryOnlyXML.contains("Using skill -"), memoryOnlyXML)

        // 3. Skill + Memory together (English)
        let bothEnXML = try await renderTaskCardXML(
            state: .done,
            memoryUse: TaskMemoryUse(notes: [noteRef], skills: ["Order usual"]),
            containerID: "taskcard.sep.bothEn"
        )
        XCTAssertTrue(bothEnXML.contains("Using skill - Order usual"), bothEnXML)
        XCTAssertTrue(bothEnXML.contains("Used: \(noteText)"), bothEnXML)
        XCTAssertFalse(bothEnXML.contains("Used: Order usual"), "Skill must not leak into memory row:\n\(bothEnXML)")
        XCTAssertFalse(bothEnXML.contains("Order usual and \(noteText)"), "Skill and memory must not mix:\n\(bothEnXML)")

        // 4. Skill + Memory together (Simplified Chinese, running blue card)
        AppLocalization.shared.preference = "zh-Hans"
        let bothZhXML = try await renderTaskCardXML(
            state: .running,
            memoryUse: TaskMemoryUse(notes: [noteRef], skills: ["点常点的那家"]),
            containerID: "taskcard.sep.bothZh"
        )
        XCTAssertTrue(bothZhXML.contains("使用技能 - 点常点的那家"), bothZhXML)
        XCTAssertTrue(bothZhXML.contains("用到了：\(noteText)"), bothZhXML)
        XCTAssertFalse(bothZhXML.contains("用到了：点常点的那家"), "Skill must not leak into Chinese memory row:\n\(bothZhXML)")
    }

    // MARK: - Helpers

    private func renderTaskCardXML(
        state: TaskCardState,
        memoryUse: TaskMemoryUse?,
        containerID: String
    ) async throws -> String {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let covered = scene.windows.filter { !$0.accessibilityElementsHidden }
        covered.forEach { $0.accessibilityElementsHidden = true }
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        defer {
            window.isHidden = true
            covered.forEach { $0.accessibilityElementsHidden = false }
        }

        let end = Date()
        let rootView = VStack(spacing: 16) {
            TaskCard(
                title: "Order coffee",
                steps: [PlanStep("Open app", state: state == .running ? .current : .done)],
                state: state,
                app: "com.starbucks.mystarbucks",
                started: end.addingTimeInterval(-12),
                ended: state == .running ? nil : end,
                memoryUse: memoryUse
            )
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
        .environment(\.locale, AppLocalization.locale)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(containerID)

        window.rootViewController = UIHostingController(rootView: rootView)
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        CATransaction.flush()

        var source = ""
        let deadline = CACurrentMediaTime() + 15
        repeat {
            source = await Task.detached {
                var code: NSString?
                return PKInProcess.shared().sourceXML(nil, code: &code) ?? ""
            }.value
            if source.contains(containerID) { break }
            try await Task.sleep(for: .milliseconds(50))
        } while CACurrentMediaTime() < deadline
        XCTAssertTrue(source.contains(containerID), "TaskCard did not appear in accessibility tree")
        return source
    }
}
