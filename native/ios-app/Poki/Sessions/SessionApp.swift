import SwiftUI

// Each conversation in the drawer shows the icon of the app it worked in (the owner's examples: Notes,
// Starbucks, WeChat), found by AppIconStore.

extension SavedSession {
    /// The app the conversation last worked in: the app its last task ended in, or the app an outside
    /// agent's last step ran in. Nil before any step in an app, for the home screen, and for
    /// conversations saved before steps kept their app.
    var app: String? {
        for entry in entries.reversed() {
            guard let app = entry.app?.trimmingCharacters(in: .whitespaces), !app.isEmpty else { continue }
            // PokiCore names the home screen, the App Switcher and system alerts "Home screen (…)".
            if app.hasPrefix("Home screen") || app == "unknown" || app == "com.apple.springboard" { continue }
            return app
        }
        return nil
    }
}
