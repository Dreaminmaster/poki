import SwiftUI
#if canImport(FoundationModels)
import FoundationModels
#endif

// The welcome panel's rows for parts of Poki that other branches are reworking (Nov 20 2026): the
// cellular loopback shortcut (dev/screen-history-always-on), local models and the Apple Intelligence
// check (dev/models-one-list) and Senses (dev/senses-habits). Each row opens that part's own page, so
// the panel never holds a copy of it. This is the test builds' version (dev/test-build-nov19-3): the
// shortcut and the Screen History gate are here, local models are not yet.

/// The Poki Loopback shortcut, which keeps the loopback on cellular: the loopback page's own section
/// (optional but strongly encouraged, and needed for Screen History, the owner, 2026-11-19).
struct WelcomeCellularSection: View {
    var body: some View { CellularShortcutSection() }
}

/// Local models. Main has only Apple's own model, which Screen History's notes use where the iPhone has it.
struct WelcomeLocalModels: View {
    var body: some View {
        SettingsRow(title: "Apple Intelligence", symbol: "apple.intelligence", value: Self.status)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("firstRun.appleIntelligence")
    }

    private static var status: String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return AppLocalization.text("On This iPhone")
            case .unavailable(.appleIntelligenceNotEnabled): return AppLocalization.text("Turned Off")
            case .unavailable(.modelNotReady): return AppLocalization.text("Getting Ready")
            case .unavailable: break
            }
        }
        #endif
        return AppLocalization.text("Not on This iPhone")
    }
}

/// Screen History, the page Settings has, which turns on only once the shortcut has run.
struct WelcomeSensesRow: View {
    @ObservedObject private var history = HistoryCapture.shared
    @ObservedObject private var reconnect = HistoryReconnect.shared

    var body: some View {
        NavigationLink(value: DetailsRoute.screenHistory) {
            SettingsRow(title: "Screen History",
                        caption: history.enabled || reconnect.isSetUp ? "Experimental Feature" : "Needs the Poki Loopback shortcut",
                        symbol: "rectangle.stack",
                        value: AppLocalization.text(LocalizedStringResource(history.enabled ? "On" : "Off")))
        }
        .accessibilityIdentifier("firstRun.screenHistory")
    }
}
