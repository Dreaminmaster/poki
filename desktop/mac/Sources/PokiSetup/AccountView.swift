import SwiftUI

struct AccountView: View {
    @EnvironmentObject var model: AppModel
    @State private var appleID = ""
    @State private var password = ""
    @State private var keep = true
    @State private var working = false
    @State private var error: String?
    @State private var confirmSignOut = false

    var body: some View {
        Form {
            if let a = model.account, a.signedIn {
                signedIn(a)
            } else if let err = model.accountError {
                keychainError(err)
            } else {
                signInForm
            }
        }
        .pokiPage()
    }

    @ViewBuilder private func keychainError(_ err: CoreError) -> some View {
        HeroSection {
            PageHero(symbol: "key.slash", title: localized("Keychain Access Needed"), subtitle: localized("Poki Setup could not read your saved Apple Account from the macOS keychain. Your session was not signed out."))
        }
        Section {
            Text(localized("When macOS asks to access your keychain, enter your Mac login password and choose “Always Allow”, then click Retry."))
                .fixedSize(horizontal: false, vertical: true)
            Text(err.message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        Section {
            HStack {
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button(localized("Retry")) { Task { await retryAccount() } }
                    .pokiProminentButton()
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(working)
            }
        }
    }

    @ViewBuilder private func signedIn(_ a: AccountState) -> some View {
        HeroSection {
            HStack(spacing: 14) {
                AccountBadge(name: a.name, appleID: a.appleId, signedIn: true, size: PageHeroMetrics.icon)
                VStack(alignment: .leading, spacing: 2) {
                    Text(a.name ?? localized("Apple Account")).font(.title3.weight(.bold)).lineLimit(1)
                    Text(a.appleId ?? "").font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }
            .frame(minHeight: PageHeroMetrics.height)
        }
        Section(localized("Signing")) {
            if model.teams.isEmpty, let teamsError = model.teamsError {
                LabeledContent(localized("Team")) {
                    Text(teamsError.text)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
                HStack {
                    Spacer()
                    Button(localized("Try Again")) { Task { await model.refreshAccount() } }
                }
            } else if model.teams.isEmpty {
                LabeledContent(localized("Team")) { ProgressView().controlSize(.small) }
            } else {
                Picker(localized("Team"), selection: Binding(get: { a.teamId ?? model.teams.first?.teamId ?? "" }, set: { id in
                    if let t = model.teams.first(where: { $0.teamId == id }) { Task { await model.chooseTeam(t) } }
                })) {
                    ForEach(model.teams) { t in Text(t.name).tag(t.teamId) }
                }
                if let t = model.teams.first(where: { $0.teamId == (a.teamId ?? model.teams.first?.teamId) }) {
                    LabeledContent(localized("Kind")) {
                        Text(t.isFree ? localized("Free Personal Team: apps last 7 days, Poki Setup renews them") : localized("Apple Developer Program: apps last a year"))
                            .foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                    }
                }
            }
            StatusRow(title: localized("Automatic Renewal"), value: a.passwordKept ? localized("On") : localized("Off: sign in again with “Keep me signed in”"), tone: a.passwordKept ? .good : .warn)
        }
        Section {
            Button(localized("Sign Out…"), role: .destructive) { confirmSignOut = true }
                .confirmationDialog(localized("Sign out of \(a.appleId ?? localized("this Apple Account"))?"), isPresented: $confirmSignOut) {
                    Button(localized("Sign Out"), role: .destructive) { Task { await model.signOut() } }
                } message: {
                    Text(localized("Poki stays on your devices, but Poki Setup can't renew it until you sign in again."))
                }
        }
    }

    @ViewBuilder private var signInForm: some View {
        HeroSection {
            PageHero(symbol: "person.crop.circle", title: localized("Sign in with your Apple Account"), subtitle: localized("Poki Setup uses it the way Xcode does: to sign Poki for your iPhone or iPad. A free Apple Account works. Your password goes to Apple only."))
        }
        if model.account?.needsReauth == true {
            Section {
                Label(localized("Apple verified the code, but did not finish opening the session. Sign in again to start a fresh session."), systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
        }
        Section {
            TextField(localized("Email or Phone Number"), text: $appleID, prompt: Text("name@example.com"))
                .textContentType(.username)
            SecureField(localized("Password"), text: $password, prompt: Text(localized("Required")))
                .textContentType(.password)
                .onSubmit { Task { await signIn() } }
            Toggle(localized("Keep me signed in to renew Poki automatically"), isOn: $keep)
        } footer: {
            Text(localized("With a free account, apps stop opening after 7 days. Poki Setup renews Poki before then while this Mac is on, using the password kept in your keychain."))
                .font(.footnote).foregroundStyle(.secondary)
        }
        Section {
            HStack {
                if let error {
                    Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled)
                }
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button(localized("Sign In")) { Task { await signIn() } }
                    .pokiProminentButton()
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || appleID.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty)
            }
        }
    }

    private func signIn() async {
        guard !working else { return }
        working = true
        error = nil
        defer { working = false }
        do {
            try await model.signIn(appleID: appleID.trimmingCharacters(in: .whitespaces), password: password, keep: keep)
            password = ""
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func retryAccount() async {
        guard !working else { return }
        working = true
        defer { working = false }
        await model.refreshAccount()
    }
}
