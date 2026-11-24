import SwiftUI
import TipKit

/// The one-time hint that Poki's picture opens its menu (models, approvals and outfits). Beta testers
/// did not find the menu: a picture reads as a picture, not as a button. The tip points at the picture
/// on the home page until the menu has been opened once, from the picture or from the name in the
/// conversation, and then never shows again. The name in the conversation keeps a small chevron for
/// good (`PokiHead`), as a title menu does in the system's apps.
struct PokiMenuTip: Tip {
    var title: Text { Text("Tap Poki") }
    var message: Text? { Text("Choose a model and how Poki asks before acting") }
    var image: Image? { Image(systemName: "hand.tap") }

    /// The menu was opened, so the hint has done its work.
    static func menuOpened() {
        PokiMenuTip().invalidate(reason: .actionPerformed)
    }

    /// Once at launch, before any tip view is drawn.
    static func configure() {
        #if DEBUG
        // `-pokiResetTips` shows the hint again on this launch, for the Simulator and screenshots.
        if UserDefaults.standard.bool(forKey: "pokiResetTips") { try? Tips.resetDatastore() }
        #endif
        try? Tips.configure([.displayFrequency(.immediate)])
    }
}
