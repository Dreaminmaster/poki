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
            let parsed = try StaticTextElements(source)
            XCTAssertEqual(parsed.labels(for: "taskCard.skillUse"), [item.expected],
                           "[\(item.language)] expected skillUse label \(item.expected) in XML:\n\(source)")
            XCTAssertTrue(parsed.labels(for: "taskCard.memoryUse").isEmpty,
                          "[\(item.language)] skill-only card must not render memoryUse row:\n\(source)")
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
        let skillOnly = try StaticTextElements(skillOnlyXML)
        XCTAssertEqual(skillOnly.labels(for: "taskCard.skillUse"), ["Using skill - Order usual"])
        XCTAssertTrue(skillOnly.labels(for: "taskCard.memoryUse").isEmpty)
        XCTAssertFalse(skillOnlyXML.contains("Used:"), skillOnlyXML)

        // 2. Memory only
        let memoryOnlyXML = try await renderTaskCardXML(
            state: .done,
            memoryUse: TaskMemoryUse(notes: [noteRef], skills: []),
            containerID: "taskcard.sep.memoryOnly"
        )
        let memoryOnly = try StaticTextElements(memoryOnlyXML)
        XCTAssertTrue(memoryOnly.labels(for: "taskCard.skillUse").isEmpty)
        XCTAssertEqual(memoryOnly.labels(for: "taskCard.memoryUse"), ["Used: \(noteText)"])
        XCTAssertFalse(memoryOnlyXML.contains("Using skill -"), memoryOnlyXML)

        // 3. Skill + Memory together (English)
        let bothEnXML = try await renderTaskCardXML(
            state: .done,
            memoryUse: TaskMemoryUse(notes: [noteRef], skills: ["Order usual"]),
            containerID: "taskcard.sep.bothEn"
        )
        let bothEn = try StaticTextElements(bothEnXML)
        XCTAssertEqual(bothEn.labels(for: "taskCard.skillUse"), ["Using skill - Order usual"])
        XCTAssertEqual(bothEn.labels(for: "taskCard.memoryUse"), ["Used: \(noteText)"])
        XCTAssertFalse(bothEnXML.contains("Used: Order usual"), "Skill must not leak into memory row:\n\(bothEnXML)")
        XCTAssertFalse(bothEnXML.contains("Order usual and \(noteText)"), "Skill and memory must not mix:\n\(bothEnXML)")

        // 4. Skill + Memory together (Simplified Chinese, running blue card)
        AppLocalization.shared.preference = "zh-Hans"
        let bothZhXML = try await renderTaskCardXML(
            state: .running,
            memoryUse: TaskMemoryUse(notes: [noteRef], skills: ["点常点的那家"]),
            containerID: "taskcard.sep.bothZh"
        )
        let bothZh = try StaticTextElements(bothZhXML)
        XCTAssertEqual(bothZh.labels(for: "taskCard.skillUse"), ["使用技能 - 点常点的那家"])
        XCTAssertEqual(bothZh.labels(for: "taskCard.memoryUse"), ["用到了：\(noteText)"])
        XCTAssertFalse(bothZhXML.contains("用到了：点常点的那家"), "Skill must not leak into Chinese memory row:\n\(bothZhXML)")
        XCTAssertTrue(bothZhXML.contains("技能：点常点的那家"), "Expanded running card still shows skill detail")
        XCTAssertTrue(bothZhXML.contains("Poki 报告使用的记忆：\(noteText)"), "Expanded running card still shows memory detail")
    }

    func testRainbowPaletteSelectionAndExactStops() {
        let expectedDark: [TaskCardSkillRainbow.Stop] = [
            .init(hex: 0xFF6B6B, location: 0.00),
            .init(hex: 0xFFB347, location: 0.20),
            .init(hex: 0xF7E26B, location: 0.38),
            .init(hex: 0x6EE7A0, location: 0.56),
            .init(hex: 0x5AA9FF, location: 0.76),
            .init(hex: 0xB48CFF, location: 1.00),
        ]
        let expectedLight: [TaskCardSkillRainbow.Stop] = [
            .init(hex: 0xE5484D, location: 0.00),
            .init(hex: 0xF76B15, location: 0.20),
            .init(hex: 0xD6A000, location: 0.38),
            .init(hex: 0x30A46C, location: 0.56),
            .init(hex: 0x0090FF, location: 0.76),
            .init(hex: 0x8E4EC6, location: 1.00),
        ]

        XCTAssertEqual(TaskCardSkillRainbow.palette(onBlue: false, colorScheme: .dark), .darkSurface)
        XCTAssertEqual(TaskCardSkillRainbow.palette(onBlue: true, colorScheme: .light), .darkSurface)
        XCTAssertEqual(TaskCardSkillRainbow.palette(onBlue: true, colorScheme: .dark), .darkSurface)
        XCTAssertEqual(TaskCardSkillRainbow.palette(onBlue: false, colorScheme: .light), .lightSurface)

        XCTAssertEqual(TaskCardSkillRainbow.stops(onBlue: false, colorScheme: .dark), expectedDark)
        XCTAssertEqual(TaskCardSkillRainbow.stops(onBlue: true, colorScheme: .light), expectedDark)
        XCTAssertEqual(TaskCardSkillRainbow.stops(onBlue: true, colorScheme: .dark), expectedDark)
        XCTAssertEqual(TaskCardSkillRainbow.stops(onBlue: false, colorScheme: .light), expectedLight)

        XCTAssertEqual(TaskCardSkillRainbow.flowDuration, 2.5, accuracy: 0.001)
        XCTAssertTrue(TaskCardSkillRainbow.shouldAnimateFlow(reduceMotion: false))
        XCTAssertFalse(TaskCardSkillRainbow.shouldAnimateFlow(reduceMotion: true))

        let flowing = TaskCardSkillRainbow.flowingStops(from: expectedDark)
        XCTAssertEqual(flowing.count, 12)
        XCTAssertEqual(flowing.first?.hex, 0xFF6B6B)
        XCTAssertEqual(flowing.first?.location ?? -1, 0.0, accuracy: 0.0001)
        XCTAssertEqual(flowing.last?.hex, 0xB48CFF)
        XCTAssertEqual(flowing.last?.location ?? -1, 1.0, accuracy: 0.0001)
    }

    func testVisualComparisonCapturesLightDarkAndBlueCards() async throws {
        let library = MemoryLibrary.shared
        let noteText = "咖啡要冰美式，少冰"
        library.add(noteText, app: nil)
        let item = try XCTUnwrap(library.items.first { $0.kind == .memory && $0.text == noteText })
        defer { library.forget(item.id) }
        let noteRef = TaskMemoryUse.Note(id: item.id, updatedAtSeconds: Int64(item.updated.timeIntervalSince1970))

        let output = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TaskCardSkillEvidence")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        AppLocalization.shared.preference = "zh-Hans"
        let end = Date()

        let scenes: [(filename: String, scheme: UIUserInterfaceStyle, cards: [AnyView])] = [
            (
                "light-cards.png",
                .light,
                [
                    AnyView(TaskCard(
                        title: "点一杯冰美式",
                        steps: [PlanStep("打开星巴克", state: .done)],
                        state: .done,
                        app: "com.starbucks.mystarbucks",
                        started: end.addingTimeInterval(-14),
                        ended: end,
                        memoryUse: TaskMemoryUse(notes: [], skills: ["点常点的那家"])
                    )),
                    AnyView(TaskCard(
                        title: "查天气并发给家人",
                        steps: [PlanStep("查今天天气", state: .done)],
                        state: .done,
                        app: "com.tencent.xin",
                        started: end.addingTimeInterval(-22),
                        ended: end,
                        memoryUse: TaskMemoryUse(notes: [noteRef], skills: ["查天气", "发消息"])
                    )),
                    AnyView(TaskCard(
                        title: "只用记忆的任务",
                        steps: [PlanStep("备注要求", state: .done)],
                        state: .done,
                        app: "com.starbucks.mystarbucks",
                        started: end.addingTimeInterval(-8),
                        ended: end,
                        memoryUse: TaskMemoryUse(notes: [noteRef], skills: [])
                    )),
                ]
            ),
            (
                "dark-cards.png",
                .dark,
                [
                    AnyView(TaskCard(
                        title: "点一杯冰美式",
                        steps: [PlanStep("打开星巴克", state: .done)],
                        state: .done,
                        app: "com.starbucks.mystarbucks",
                        started: end.addingTimeInterval(-14),
                        ended: end,
                        memoryUse: TaskMemoryUse(notes: [], skills: ["点常点的那家"])
                    )),
                    AnyView(TaskCard(
                        title: "查天气并发给家人",
                        steps: [PlanStep("查今天天气", state: .done)],
                        state: .done,
                        app: "com.tencent.xin",
                        started: end.addingTimeInterval(-22),
                        ended: end,
                        memoryUse: TaskMemoryUse(notes: [noteRef], skills: ["查天气", "发消息"])
                    )),
                ]
            ),
            (
                "blue-running-cards.png",
                .light,
                [
                    AnyView(TaskCard(
                        title: "正在执行技能任务",
                        steps: [PlanStep("打开星巴克并选常点门店", state: .current)],
                        state: .running,
                        app: "com.starbucks.mystarbucks",
                        started: end.addingTimeInterval(-9),
                        memoryUse: TaskMemoryUse(notes: [noteRef], skills: ["点常点的那家"])
                    )),
                    AnyView(TaskCard(
                        title: "Order usual coffee",
                        steps: [PlanStep("Open Starbucks", state: .current)],
                        state: .running,
                        app: "com.starbucks.mystarbucks",
                        started: end.addingTimeInterval(-9),
                        memoryUse: TaskMemoryUse(notes: [], skills: ["Order usual", "Check ETA"])
                    ).environment(\.locale, Locale(identifier: "en"))),
                ]
            ),
        ]

        let windowScene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let covered = windowScene.windows.filter { !$0.accessibilityElementsHidden }
        covered.forEach { $0.accessibilityElementsHidden = true }
        let window = UIWindow(windowScene: windowScene)
        window.frame = windowScene.screen.bounds
        defer {
            window.isHidden = true
            covered.forEach { $0.accessibilityElementsHidden = false }
        }

        for scene in scenes {
            window.overrideUserInterfaceStyle = scene.scheme
            let host = UIHostingController(rootView:
                VStack(spacing: 16) {
                    ForEach(Array(scene.cards.enumerated()), id: \.offset) { _, card in card }
                    Spacer(minLength: 0)
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(Color(.systemGroupedBackground))
                .environment(\.locale, AppLocalization.locale)
            )
            window.rootViewController = host
            window.makeKeyAndVisible()
            window.layoutIfNeeded()
            CATransaction.flush()
            try await Task.sleep(for: .milliseconds(250))

            let png = UIGraphicsImageRenderer(bounds: window.bounds).pngData { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            XCTAssertGreaterThan(png.count, 1000, "Screenshot \(scene.filename) must not be empty")
            try png.write(to: output.appendingPathComponent(scene.filename))
        }
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

private final class StaticTextElements: NSObject, XMLParserDelegate {
    private var entries: [(name: String, label: String)] = []

    convenience init(_ xml: String) throws {
        self.init()
        let parser = XMLParser(data: Data(xml.utf8))
        parser.delegate = self
        guard parser.parse() else {
            throw parser.parserError ?? NSError(domain: "TaskCardSkillTests", code: 1)
        }
    }

    func labels(for name: String) -> [String] {
        entries.filter { $0.name == name }.map(\.label)
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String]
    ) {
        if elementName == "XCUIElementTypeStaticText",
           let name = attributes["name"],
           let label = attributes["label"] {
            entries.append((name, label))
        }
    }
}
