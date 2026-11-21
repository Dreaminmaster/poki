import Foundation
import QuartzCore
import SwiftUI

enum StartupView: String {
    case topBar = "ChatTopBar"
    case composer = "ComposerInputView"
    case suggestions = "HomeSuggestions"
    case welcome = "FirstRunGuide"
}

extension EnvironmentValues {
    @Entry var startupLog: StartupLog? = nil
}

extension View {
    func logStartupAppearance(_ view: StartupView) -> some View {
        modifier(StartupAppearance(view: view))
    }
}

private struct StartupAppearance: ViewModifier {
    @Environment(\.startupLog) private var log
    let view: StartupView

    func body(content: Content) -> some View {
        content.onAppear { log?.appeared(view) }
    }
}

@MainActor
final class StartupLog {
    private static let recordedBuildKey = "pokiStartupLogBuild"
    private let build: String
    private let startedAt: CFTimeInterval
    private var views: [(StartupView, Int)] = []
    private var firstFrame: (milliseconds: Int, glassDeferred: Bool)?
    private var finished = false

    private init(build: String, startedAt: CFTimeInterval) {
        self.build = build
        self.startedAt = startedAt
    }

    static func begin() -> StartupLog? {
        let startedAt = CACurrentMediaTime()
        guard let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let number = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String else { return nil }
        let build = "\(version)-\(number)"
        guard UserDefaults.standard.string(forKey: recordedBuildKey) != build else { return nil }
        return StartupLog(build: build, startedAt: startedAt)
    }

    func appeared(_ view: StartupView) {
        guard !finished, !views.contains(where: { $0.0 == view }) else { return }
        views.append((view, milliseconds(sinceStart: CACurrentMediaTime())))
    }

    func frameDisplayed(at timestamp: CFTimeInterval, glassDeferred: Bool) {
        guard firstFrame == nil else { return }
        firstFrame = (milliseconds(sinceStart: timestamp), glassDeferred)
    }

    func finish() {
        guard !finished, let firstFrame else { return }
        finished = true
        let glass = firstFrame.glassDeferred ? "deferred" : "enabled"
        let appearances = views.map { "\($0.rawValue)@\($1)ms" }.joined(separator: ",")
        let line = "build=\(build) first_frame_ms=\(firstFrame.milliseconds) first_frame_custom_glass=\(glass) views=\(appearances)"
        AppLog.shared.add("startup", line)

        // Poki Setup includes .log files from this directory in its support bundle.
        let build = self.build
        let key = Self.recordedBuildKey
        Task.detached(priority: .utility) {
            let file = AppFiles.support.appendingPathComponent("startup.log")
            do {
                try (line + "\n").write(to: file, atomically: true, encoding: .utf8)
                UserDefaults.standard.set(build, forKey: key)
            } catch {
                await AppLog.shared.add("startup", "Could not save the startup log")
            }
        }
    }

    private func milliseconds(sinceStart timestamp: CFTimeInterval) -> Int {
        Int((timestamp - startedAt) * 1_000)
    }
}
