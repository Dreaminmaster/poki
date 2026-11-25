import SwiftUI

/// The Apple Account sign-in a free account's install asks for right after setup (issue #740): a
/// free Apple Account signs Poki for 7 days, and Poki renews itself on the phone only while it is
/// signed in here. Poki Setup hands over the team key and the Apple ID, never the Apple session, so
/// the person signs in once on the iPhone. The start flow has it as its last page; when the welcome
/// closes without that page, or Poki Setup just installed Poki and no welcome is due, the same
/// sign-in comes up as a sheet, once for each installed profile.
enum RenewSignIn {
    /// The profile's expiry the sign-in was last asked for. A new install (a new profile) asks again.
    static let askedKey = "renewSignIn.askedFor"

    /// Whether to ask now. `afterSetup`: the welcome just closed, or Poki Setup put Poki here at this launch.
    nonisolated static func shouldAsk(freeSigning: Bool, needsAccount: Bool, statusKnown: Bool, afterSetup: Bool,
                                      expiry: Date?, askedFor: Double?) -> Bool {
        guard freeSigning, needsAccount, statusKnown, afterSetup else { return false }
        guard let askedFor else { return true }
        return askedFor != (expiry?.timeIntervalSince1970 ?? 0)
    }

    static func askedFor(_ defaults: UserDefaults = .standard) -> Double? {
        defaults.object(forKey: askedKey) as? Double
    }

    static func markAsked(expiry: Date?, defaults: UserDefaults = .standard) {
        defaults.set(expiry?.timeIntervalSince1970 ?? 0, forKey: askedKey)
    }
}

/// The page's hero and the Apple Account form, for the start flow's page and the sheet.
private struct RenewSignInForm: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let done = !model.signer.needsAppleAccountForRenewal
        Form {
            // The 7 days are in the form's own footer, so the line does not say them again.
            StartHero(symbol: "person.crop.circle.badge.clock", title: "Keep Poki Opening",
                      line: done ? "Poki renews itself before its signing ends." : "Poki was signed with a free Apple Account. Sign in so Poki can renew itself before it stops opening.",
                      done: done)
            AccountPage()
        }
        .navigationTitle(Text(verbatim: ""))
        .navigationBarTitleDisplayMode(.inline)
        .settingsPage()
        .onAppear { RenewSignIn.markAsked(expiry: model.signer.expiry) }
    }
}

/// The start flow's Apple Account page, shown when a free account signed Poki.
struct StartAppleAccountPage: View {
    @Environment(AppModel.self) private var model
    var goOn: () -> Void

    var body: some View {
        let done = !model.signer.needsAppleAccountForRenewal
        RenewSignInForm()
            .bottomBar(softEdge: true) {
                // Before the sign-in, the form's Sign In is the action, so the bar offers only to go on without it.
                StartButtons(primary: done ? "Continue" : "Set Up Later", action: goOn, quiet: !done)
            }
            .accessibilityIdentifier("firstRun.appleAccount")
    }
}

/// The same sign-in as a sheet, in the start flow's look, right after setup.
struct RenewSignInSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let done = !model.signer.needsAppleAccountForRenewal
        NavigationStack {
            RenewSignInForm()
                .bottomBar(softEdge: true) {
                    StartButtons(primary: done ? "Continue" : "Not Now", action: { dismiss() }, quiet: !done)
                }
        }
        .environment(\.startDesign, StartDesign.current)
        .interactiveDismissDisabled(!done)
        .accessibilityIdentifier("renewSignIn.sheet")
    }
}
