import SwiftUI
import TipKit

/// The one-time hint that Poki's picture opens its menu (models, approvals and outfits). Beta testers
/// did not find the menu: a picture reads as a picture, not as a button. The tip points at the picture
/// on the home page once the welcome is closed, shows once, and is done for good when the menu is
/// opened or the tip is closed. The name in the conversation keeps a small chevron for good
/// (`PokiHead`), as a title menu does in the system's apps.
struct PokiMenuTip: Tip {
    /// A welcome is up at this launch: the tip waits under it rather than floating over it.
    @Parameter(.transient) static var welcomeUp: Bool = false

    var title: Text { Text("Tap Poki") }
    var message: Text? { Text("Choose a model and how Poki asks before acting") }
    var image: Image? { Image(systemName: "hand.tap") }

    var rules: [Rule] { [#Rule(Self.$welcomeUp) { $0 == false }] }

    /// Shown once: a tap outside the tip closes it without counting as an action, and the menu's own
    /// tap is not always seen, so the count is what keeps it from coming back.
    var options: [any TipOption] { [Tips.MaxDisplayCount(1)] }

    /// The menu was opened, so the hint has done its work.
    static func menuOpened() {
        PokiMenuTip().invalidate(reason: .actionPerformed)
    }

    /// Once at launch, before any tip view is drawn.
    static func configure(welcomeUp: Bool) {
        Self.welcomeUp = welcomeUp
        guard !heldBack() else { return }
        #if DEBUG
        // `-pokiResetTips` shows the hint again on this launch, for the Simulator and screenshots.
        if UserDefaults.standard.bool(forKey: "pokiResetTips") { try? Tips.resetDatastore() }
        #endif
        try? Tips.configure([.displayFrequency(.immediate)])
    }

    /// Scripted launches (the in-app tests, the screenshot and check scripts, which all pass `-poki…`
    /// arguments) have nobody to close the hint, so TipKit stays off for them, as the welcome does.
    /// A popover over the home page would cover the screens and alerts they check. `-pokiResetTips`
    /// asks for it.
    nonisolated static func heldBack(environment: [String: String] = ProcessInfo.processInfo.environment,
                                     arguments: [String: Any] = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)) -> Bool {
        if environment["XCTestBundlePath"] != nil { return true }
        if (arguments["pokiResetTips"] as? String).map({ ["YES", "1", "true"].contains($0) }) == true { return false }
        return arguments.keys.contains { $0.hasPrefix("poki") }
    }
}
