import Observation
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

        // 1. Memory only
        AppLocalization.shared.preference = "en"
        let memoryOnlyXML = try await renderTaskCardXML(
            state: .done,
            memoryUse: TaskMemoryUse(notes: [noteRef], skills: []),
            containerID: "taskcard.sep.memoryOnly"
        )
        let memoryOnly = try StaticTextElements(memoryOnlyXML)
        XCTAssertTrue(memoryOnly.labels(for: "taskCard.skillUse").isEmpty)
        XCTAssertEqual(memoryOnly.labels(for: "taskCard.memoryUse"), ["Used: \(noteText)"])
        XCTAssertFalse(memoryOnlyXML.contains("Using skill -"), memoryOnlyXML)

        // 2. Skill + Memory together (English)
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

        // 3. Skill + Memory together (Simplified Chinese, running blue card + expanded details)
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

        XCTAssertEqual(TaskCardSkillRainbow.stops(onBlue: false, colorScheme: .dark), expectedDark)
        XCTAssertEqual(TaskCardSkillRainbow.stops(onBlue: true, colorScheme: .light), expectedDark)
        XCTAssertEqual(TaskCardSkillRainbow.stops(onBlue: true, colorScheme: .dark), expectedDark)
        XCTAssertEqual(TaskCardSkillRainbow.stops(onBlue: false, colorScheme: .light), expectedLight)
        XCTAssertEqual(TaskCardSkillRainbow.flowDuration, 2.5, accuracy: 0.001)
    }

    func testSkillRowRendersMultiColorRainbowAndReadableBlueCardContrast() async throws {
        let library = MemoryLibrary.shared
        let noteText = "咖啡要冰美式，少冰"
        library.add(noteText, app: nil)
        let item = try XCTUnwrap(library.items.first { $0.kind == .memory && $0.text == noteText })
        defer { library.forget(item.id) }
        let noteRef = TaskMemoryUse.Note(id: item.id, updatedAtSeconds: Int64(item.updated.timeIntervalSince1970))

        let output = try evidenceDirectory()
        AppLocalization.shared.preference = "zh-Hans"
        let end = Date()

        let scenes: [(filename: String, scheme: UIUserInterfaceStyle, isBlue: Bool, containerID: String, cards: [AnyView])] = [
            (
                "light-cards.png",
                .light,
                false,
                "taskcard.visual.light",
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
                false,
                "taskcard.visual.dark",
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
                true,
                "taskcard.visual.blue",
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

        let (window, cleanup) = try makeTestWindow()
        defer { cleanup() }

        for scene in scenes {
            window.overrideUserInterfaceStyle = scene.scheme
            window.rootViewController = UIHostingController(rootView:
                VStack(spacing: 16) {
                    ForEach(Array(scene.cards.enumerated()), id: \.offset) { _, card in card }
                    Spacer(minLength: 0)
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(Color(.systemGroupedBackground))
                .environment(\.locale, AppLocalization.locale)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(scene.containerID)
            )
            window.makeKeyAndVisible()
            window.layoutIfNeeded()
            CATransaction.flush()

            // Wait until the initial 2.5s sweep settles so the rendered frame reflects the final 6-stop rainbow.
            let xml = try await waitForXML(containing: scene.containerID)
            if !UIAccessibility.isReduceMotionEnabled {
                try await Task.sleep(for: .milliseconds(2700))
                window.layoutIfNeeded()
                CATransaction.flush()
            }

            let image = captureWindow(window)
            try XCTUnwrap(image.pngData()).write(to: output.appendingPathComponent(scene.filename))

            let parsed = try StaticTextElements(xml)
            let skillRect = try XCTUnwrap(parsed.frames(for: "taskCard.skillUse").first,
                                          "Missing taskCard.skillUse frame in \(scene.filename)")
            let sample = try SkillRowPixels.analyze(image: image, rect: skillRect)
            assertMultiColorRainbow(sample, context: scene.filename)

            if scene.isBlue {
                XCTAssertGreaterThanOrEqual(
                    sample.rightContrast,
                    4.5,
                    "Blue running card trailing rainbow glyphs must have >= 4.5:1 contrast against immediate backing (got \(String(format: "%.2f", sample.rightContrast)):1, fg=\(sample.rightColor), bg=\(sample.backgroundColor))"
                )
                XCTAssertGreaterThanOrEqual(
                    sample.leftContrast,
                    4.5,
                    "Blue running card leading rainbow glyphs must have >= 4.5:1 contrast (got \(String(format: "%.2f", sample.leftContrast)):1)"
                )
                XCTAssertGreaterThanOrEqual(
                    sample.midContrast,
                    4.5,
                    "Blue running card middle rainbow glyphs must have >= 4.5:1 contrast (got \(String(format: "%.2f", sample.midContrast)):1)"
                )
            }
        }
    }

    func testSkillRowFlowsOnAppearAndSkillChange() async throws {
        try XCTSkipIf(UIAccessibility.isReduceMotionEnabled, "Requires Reduce Motion disabled to verify rainbow sweep")

        let model = LiveSkillCardModel(skills: ["点常点的那家"])
        let (window, cleanup) = try makeTestWindow()
        defer { cleanup() }

        AppLocalization.shared.preference = "zh-Hans"
        window.overrideUserInterfaceStyle = .dark
        window.rootViewController = UIHostingController(rootView:
            LiveSkillCardHost(model: model, containerID: "taskcard.flow.live")
        )
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        CATransaction.flush()

        let initialXML = try await waitForXML(containing: "taskcard.flow.live")
        let initialRect = try XCTUnwrap(try StaticTextElements(initialXML).frames(for: "taskCard.skillUse").first)

        // 1. On initial appearance, pixels inside the skill row shift during the 2.5s sweep.
        try await Task.sleep(for: .milliseconds(300))
        let appearFrame1 = captureWindow(window)
        try await Task.sleep(for: .milliseconds(800))
        let appearFrame2 = captureWindow(window)
        let appearDiff = try SkillRowPixels.meanForegroundDifference(appearFrame1, appearFrame2, rect: initialRect)
        XCTAssertGreaterThan(appearDiff, 0.05,
                             "Initial skill row appearance must visibly flow across the 2.5s sweep (diff=\(appearDiff))")

        // 2. After the 2.5s sweep completes, consecutive frames stay steady on the static 6-stop rainbow.
        try await Task.sleep(for: .milliseconds(1750))
        let settledFrame1 = captureWindow(window)
        try await Task.sleep(for: .milliseconds(300))
        let settledFrame2 = captureWindow(window)
        let settledDiff = try SkillRowPixels.meanForegroundDifference(settledFrame1, settledFrame2, rect: initialRect)
        XCTAssertLessThan(settledDiff, 0.015,
                          "Skill row must settle to a static rainbow after 2.5s (diff=\(settledDiff))")
        assertMultiColorRainbow(try SkillRowPixels.analyze(image: settledFrame2, rect: initialRect),
                                context: "settled after initial flow")

        // 3. Updating the skill list refreshes the label and replays the 2.5s sweep.
        model.skills = ["查天气", "发消息"]
        let updatedXML = try await waitForXML(containing: "使用技能 - 查天气和发消息")
        let updatedRect = try XCTUnwrap(try StaticTextElements(updatedXML).frames(for: "taskCard.skillUse").first)

        try await Task.sleep(for: .milliseconds(300))
        let changeFrame1 = captureWindow(window)
        try await Task.sleep(for: .milliseconds(800))
        let changeFrame2 = captureWindow(window)
        let changeDiff = try SkillRowPixels.meanForegroundDifference(changeFrame1, changeFrame2, rect: updatedRect)
        XCTAssertGreaterThan(changeDiff, 0.05,
                             "Changing the skill list must replay the rainbow sweep (diff=\(changeDiff))")

        let output = try evidenceDirectory()
        try XCTUnwrap(appearFrame1.pngData()).write(to: output.appendingPathComponent("flow-appear-t1.png"))
        try XCTUnwrap(appearFrame2.pngData()).write(to: output.appendingPathComponent("flow-appear-t2.png"))
        try XCTUnwrap(settledFrame2.pngData()).write(to: output.appendingPathComponent("flow-settled.png"))
        try XCTUnwrap(changeFrame2.pngData()).write(to: output.appendingPathComponent("flow-changed-t2.png"))
    }

    func testSkillRowStaysStaticWhenSystemReduceMotionIsEnabled() async throws {
        try XCTSkipUnless(UIAccessibility.isReduceMotionEnabled,
                          "Enable Reduce Motion in simulator Accessibility defaults to verify static rainbow fallback")

        let model = LiveSkillCardModel(skills: ["点常点的那家"])
        let (window, cleanup) = try makeTestWindow()
        defer { cleanup() }

        AppLocalization.shared.preference = "zh-Hans"
        window.overrideUserInterfaceStyle = .dark
        window.rootViewController = UIHostingController(rootView:
            LiveSkillCardHost(model: model, containerID: "taskcard.reduceMotion.live")
        )
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        CATransaction.flush()

        let xml = try await waitForXML(containing: "taskcard.reduceMotion.live")
        let rect = try XCTUnwrap(try StaticTextElements(xml).frames(for: "taskCard.skillUse").first)

        try await Task.sleep(for: .milliseconds(150))
        let frame1 = captureWindow(window)
        try await Task.sleep(for: .milliseconds(850))
        let frame2 = captureWindow(window)

        let diff = try SkillRowPixels.meanForegroundDifference(frame1, frame2, rect: rect)
        XCTAssertLessThan(diff, 0.01,
                          "Under system Reduce Motion, the skill row must stay static without sweeping (diff=\(diff))")
        assertMultiColorRainbow(try SkillRowPixels.analyze(image: frame1, rect: rect),
                                context: "reduceMotion static rainbow")

        let output = try evidenceDirectory()
        try XCTUnwrap(frame1.pngData()).write(to: output.appendingPathComponent("reduce-motion-static.png"))
    }

    // MARK: - Helpers

    private func assertMultiColorRainbow(_ sample: SkillRowPixels.Sample, context: String) {
        XCTAssertGreaterThan(sample.leftColor.r - sample.leftColor.b, 0.15,
                             "[\(context)] leading glyphs should be warm red/orange (got \(sample.leftColor))")
        XCTAssertGreaterThan(sample.midColor.g - sample.midColor.b, 0.12,
                             "[\(context)] middle glyphs should be yellow/green (got \(sample.midColor))")
        XCTAssertGreaterThan(sample.rightColor.b - sample.rightColor.r, 0.15,
                             "[\(context)] trailing glyphs should be blue/purple (got \(sample.rightColor))")
    }

    private func evidenceDirectory() throws -> URL {
        let output = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TaskCardSkillEvidence")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        return output
    }

    private func makeTestWindow() throws -> (UIWindow, () -> Void) {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let covered = scene.windows.filter { !$0.accessibilityElementsHidden }
        covered.forEach { $0.accessibilityElementsHidden = true }
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        return (window, {
            window.isHidden = true
            covered.forEach { $0.accessibilityElementsHidden = false }
        })
    }

    private func captureWindow(_ window: UIWindow) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = window.screen.scale
        format.opaque = true
        return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }

    private func waitForXML(containing token: String) async throws -> String {
        var source = ""
        let deadline = CACurrentMediaTime() + 15
        repeat {
            source = await Task.detached {
                var code: NSString?
                return PKInProcess.shared().sourceXML(nil, code: &code) ?? ""
            }.value
            if source.contains(token) { break }
            try await Task.sleep(for: .milliseconds(50))
        } while CACurrentMediaTime() < deadline
        XCTAssertTrue(source.contains(token), "Expected \(token) in accessibility tree")
        return source
    }

    private func renderTaskCardXML(
        state: TaskCardState,
        memoryUse: TaskMemoryUse?,
        containerID: String
    ) async throws -> String {
        let (window, cleanup) = try makeTestWindow()
        defer { cleanup() }

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
        return try await waitForXML(containing: containerID)
    }
}

@MainActor
@Observable
private final class LiveSkillCardModel {
    var skills: [String]
    init(skills: [String]) { self.skills = skills }
}

private struct LiveSkillCardHost: View {
    var model: LiveSkillCardModel
    var containerID: String
    private let end = Date()

    var body: some View {
        VStack(spacing: 16) {
            TaskCard(
                title: "点一杯冰美式",
                steps: [PlanStep("打开星巴克", state: .done)],
                state: .done,
                app: "com.starbucks.mystarbucks",
                started: end.addingTimeInterval(-14),
                ended: end,
                memoryUse: TaskMemoryUse(notes: [], skills: model.skills)
            )
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(.systemGroupedBackground))
        .environment(\.locale, AppLocalization.locale)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(containerID)
    }
}

private enum SkillRowPixels {
    struct RGB: CustomStringConvertible {
        var r: Double
        var g: Double
        var b: Double
        var description: String {
            String(format: "(%.2f, %.2f, %.2f)", r, g, b)
        }

        func distance(to other: RGB) -> Double {
            let dr = r - other.r, dg = g - other.g, db = b - other.b
            return sqrt(dr * dr + dg * dg + db * db)
        }

        var luminance: Double {
            func linear(_ c: Double) -> Double {
                c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
        }

        func contrast(with other: RGB) -> Double {
            let l1 = luminance, l2 = other.luminance
            return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
        }
    }

    struct Sample {
        var backgroundColor: RGB
        var leftColor: RGB
        var midColor: RGB
        var rightColor: RGB
        var leftContrast: Double
        var midContrast: Double
        var rightContrast: Double
    }

    private struct Buffer {
        var width: Int
        var height: Int
        var bytes: [UInt8]

        func rgb(x: Int, y: Int) -> RGB {
            let idx = (y * width + x) * 4
            return RGB(
                r: Double(bytes[idx]) / 255.0,
                g: Double(bytes[idx + 1]) / 255.0,
                b: Double(bytes[idx + 2]) / 255.0
            )
        }
    }

    static func analyze(image: UIImage, rect: CGRect) throws -> Sample {
        let buf = try cropBuffer(image: image, rect: rect)
        let bg = borderBackground(buf)
        let left = try dominantForeground(buf, bg: bg, xRange: 0.06..<0.32)
        let mid = try dominantForeground(buf, bg: bg, xRange: 0.36..<0.64)
        let right = try dominantForeground(buf, bg: bg, xRange: 0.68..<0.94)
        return Sample(
            backgroundColor: bg,
            leftColor: left,
            midColor: mid,
            rightColor: right,
            leftContrast: left.contrast(with: bg),
            midContrast: mid.contrast(with: bg),
            rightContrast: right.contrast(with: bg)
        )
    }

    static func meanForegroundDifference(_ first: UIImage, _ second: UIImage, rect: CGRect) throws -> Double {
        let a = try cropBuffer(image: first, rect: rect)
        let b = try cropBuffer(image: second, rect: rect)
        guard a.width == b.width, a.height == b.height else {
            throw NSError(domain: "SkillRowPixels", code: 2)
        }
        let bg = borderBackground(a)
        var total = 0.0
        var count = 0
        for y in 1..<max(1, a.height - 1) {
            for x in 1..<max(1, a.width - 1) {
                let ca = a.rgb(x: x, y: y)
                let cb = b.rgb(x: x, y: y)
                if ca.distance(to: bg) >= 0.16 || cb.distance(to: bg) >= 0.16 {
                    total += (abs(ca.r - cb.r) + abs(ca.g - cb.g) + abs(ca.b - cb.b)) / 3.0
                    count += 1
                }
            }
        }
        guard count > 0 else {
            throw NSError(domain: "SkillRowPixels", code: 3, userInfo: [NSLocalizedDescriptionKey: "No foreground pixels found in skill row rect"])
        }
        return total / Double(count)
    }

    private static func cropBuffer(image: UIImage, rect: CGRect) throws -> Buffer {
        guard let cgImage = image.cgImage else {
            throw NSError(domain: "SkillRowPixels", code: 1)
        }
        let scale = image.scale
        let pixelRect = CGRect(
            x: max(0, floor(rect.minX * scale)),
            y: max(0, floor(rect.minY * scale)),
            width: min(CGFloat(cgImage.width) - max(0, floor(rect.minX * scale)), ceil(rect.width * scale)),
            height: min(CGFloat(cgImage.height) - max(0, floor(rect.minY * scale)), ceil(rect.height * scale))
        )
        guard let cropped = cgImage.cropping(to: pixelRect), cropped.width > 4, cropped.height > 4 else {
            throw NSError(domain: "SkillRowPixels", code: 4)
        }
        let w = cropped.width, h = cropped.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &bytes,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else {
            throw NSError(domain: "SkillRowPixels", code: 5)
        }
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: w, height: h))
        return Buffer(width: w, height: h, bytes: bytes)
    }

    private static func borderBackground(_ buf: Buffer) -> RGB {
        var samples: [RGB] = []
        let topY = min(1, buf.height - 1)
        let bottomY = max(0, buf.height - 2)
        for x in 1..<max(1, buf.width - 1) {
            samples.append(buf.rgb(x: x, y: topY))
            samples.append(buf.rgb(x: x, y: bottomY))
        }
        let rs = samples.map(\.r).sorted()
        let gs = samples.map(\.g).sorted()
        let bs = samples.map(\.b).sorted()
        let mid = samples.count / 2
        return RGB(r: rs[mid], g: gs[mid], b: bs[mid])
    }

    private static func dominantForeground(_ buf: Buffer, bg: RGB, xRange: Range<Double>) throws -> RGB {
        let minX = max(1, Int(Double(buf.width) * xRange.lowerBound))
        let maxX = min(buf.width - 1, Int(Double(buf.width) * xRange.upperBound))
        var candidates: [(rgb: RGB, dist: Double)] = []
        for y in 1..<max(1, buf.height - 1) {
            for x in minX..<max(minX, maxX) {
                let c = buf.rgb(x: x, y: y)
                let d = c.distance(to: bg)
                if d >= 0.14 {
                    candidates.append((c, d))
                }
            }
        }
        guard !candidates.isEmpty else {
            throw NSError(domain: "SkillRowPixels", code: 6, userInfo: [NSLocalizedDescriptionKey: "No visible glyph pixels in segment \(xRange)"])
        }
        candidates.sort { $0.dist > $1.dist }
        let topCount = max(1, candidates.count / 3)
        let top = candidates.prefix(topCount)
        let r = top.map(\.rgb.r).reduce(0, +) / Double(topCount)
        let g = top.map(\.rgb.g).reduce(0, +) / Double(topCount)
        let b = top.map(\.rgb.b).reduce(0, +) / Double(topCount)
        return RGB(r: r, g: g, b: b)
    }
}

private final class StaticTextElements: NSObject, XMLParserDelegate {
    private var entries: [(name: String, label: String, frame: CGRect)] = []

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

    func frames(for name: String) -> [CGRect] {
        entries.filter { $0.name == name }.map(\.frame)
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
            let x = Double(attributes["x"] ?? "") ?? 0
            let y = Double(attributes["y"] ?? "") ?? 0
            let w = Double(attributes["width"] ?? "") ?? 0
            let h = Double(attributes["height"] ?? "") ?? 0
            entries.append((name, label, CGRect(x: x, y: y, width: w, height: h)))
        }
    }
}
