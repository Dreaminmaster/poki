import SwiftUI

/// The Apple Account, optional and out of the way (ESP-222): Poki Setup on a Mac signs Poki, and
/// signed in here Poki can also renew itself with no computer. Sections of the Apple Account page's Form.
struct AccountPage: View {
    @Environment(AppModel.self) private var model
    @State private var appleID = ""
    @State private var password = ""
    @State private var keepPassword = true
    @State private var code = ""

    private var signer: SelfSigner { model.signer }

    var body: some View {
        if signer.signedIn {
            Section {
                LabeledContent("Apple Account", value: signer.status?.apple_id ?? "")
                if let name = signer.status?.name, name != signer.status?.apple_id { LabeledContent("Name", value: name) }
                if signer.teams.count > 1 {
                    Picker("Team", selection: Binding(get: { signer.status?.team_id ?? "" }, set: { id in
                        if let team = signer.teams.first(where: { $0.team_id == id }) { Task { await signer.choose(team: team) } }
                    })) {
                        ForEach(signer.teams) { team in Text(team.is_free ? "\(team.name) (Free)" : team.name).tag(team.team_id) }
                    }
                } else if let team = signer.teams.first {
                    LabeledContent("Team", value: team.is_free ? "\(team.name) (Free, 7-day signing)" : team.name)
                }
            } footer: {
                Text(signer.status?.keeps_password == true
                     ? "Poki keeps the password in this iPhone’s Keychain to sign itself again every week."
                     : "Poki signs in again when its signing is due, and asks you for the password then.")
            }
            .task { if signer.teams.isEmpty { await signer.loadTeams() } }
            Section { Button("Sign Out", role: .destructive) { Task { await signer.signOut() } } }
        } else if signer.needsCode {
            Section {
                TextField("Verification Code", text: $code)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                Button("Verify") { Task { await signer.finishSignIn(code: code); code = "" } }
                    .disabled(code.count != 6 || signer.working != nil)
            } footer: {
                Text("Apple sent a six-digit code to your trusted devices or phone number.")
            }
        } else {
            Section {
                TextField("Apple ID", text: $appleID)
                    .textContentType(.username)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Password", text: $password)
                    .textContentType(.password)
                Toggle("Keep Me Signed In", isOn: $keepPassword)
            } footer: {
                Text("A free Apple Account works: Poki signs itself for 7 days at a time and gets ready to sign again before then. Your Apple ID and password go only to Apple. The anisette server Poki asks for its device headers never sees them.")
            }
            Section {
                Button("Sign In") { Task { await signer.signIn(appleID: appleID, password: password, keepPassword: keepPassword); password = "" } }
                    .disabled(appleID.isEmpty || password.isEmpty || signer.working != nil)
            }
        }
        SignerActivityRows(signer: signer)
    }
}

/// What the signer is doing, or why it stopped.
struct SignerActivityRows: View {
    let signer: SelfSigner
    var body: some View {
        if let working = signer.working {
            Section {
                if let f = signer.fraction { ProgressView(value: f) { Text(working) } } else { LabeledContent { ProgressView() } label: { Text(working) } }
            }
        }
        if let error = signer.lastError {
            Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
        }
    }
}

/// The Setup page's signing section: when Poki stops opening, the build that is ready, and Install.
struct SigningSection: View {
    @Environment(AppModel.self) private var model
    private var signer: SelfSigner { model.signer }

    var body: some View {
        Section {
            LabeledContent {
                Text(verbatim: signer.installedTitle)
            } label: {
                Label("Poki Version", systemImage: "info.circle")
            }
            LabeledContent {
                if let expiry = signer.expiry {
                    // One line: the date, and how long is left in the warning colour when it is close.
                    (Text(expiry, format: .dateTime.month(.abbreviated).day().year()) + Text(verbatim: " · ") + Text(expiry, style: .relative).foregroundStyle(countdownColor))
                        .lineLimit(1).minimumScaleFactor(0.8)
                } else {
                    Text("No Profile").foregroundStyle(Color(.secondaryLabel))
                }
            } label: {
                Label("Signed Until", systemImage: "signature")
            }
            // A newer build that isn't downloaded yet shows even when a refresh (or an older update) is
            // ready, so it is never hidden behind it.
            if signer.updateNotReady, let latest = signer.latest {
                LabeledContent { Text(verbatim: SelfSigner.title(version: latest.version, build: latest.build, pr: latest.preview_pr)) } label: { Label("Update Available", systemImage: "sparkles") }
            } else if let next = signer.next {
                LabeledContent {
                    Text(next.kind == "update" ? SelfSigner.title(version: next.version, build: next.build, pr: next.preview_pr) : "Until \(next.expires.formatted(.dateTime.month(.abbreviated).day().year()))").lineLimit(1)
                } label: {
                    Label(next.kind == "update" ? "Update Ready" : "Refresh Ready", systemImage: "checkmark.seal")
                }
            }
            NavigationLink { SigningOptionsPage() } label: {
                Label("Build Options", systemImage: "slider.horizontal.3")
            }
            // The actions last, under what they act on. A newer build not yet downloaded comes first:
            // one tap downloads and installs it (or, without an Apple Account, opens the sign-in).
            if signer.updateNotReady {
                if signer.signedIn {
                    Button("Download and Install Update", systemImage: "arrow.down.circle") { Task { await signer.downloadAndInstallUpdate() } }
                        .disabled(signer.working != nil)
                } else {
                    NavigationLink {
                        Form { AccountPage() }
                            .navigationTitle("Apple Account")
                            .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        Label("Sign In to Download the Update", systemImage: "person.crop.circle.badge.plus")
                    }
                }
            } else if let next = signer.next {
                // Idle is partly time (a minute since the last agent step), which nothing observes, so
                // the row looks again every few seconds instead of staying as it was first drawn.
                TimelineView(.periodic(from: .now, by: 5)) { _ in
                    Button(next.kind == "update" ? "Install Update" : "Install Refresh", systemImage: "arrow.down.app") { Task { await signer.install() } }
                        .disabled(signer.working != nil)
                }
            }
            if signer.signedIn {
                Button("Prepare Refresh Now", systemImage: "arrow.clockwise") { Task { await signer.prepare(kind: "refresh") } }
                    .disabled(signer.working != nil)
            }
        } header: {
            Text("Signing")
        } footer: {
            Text(footer)
        }
        SignerActivityRows(signer: signer)
    }

    private var countdownColor: Color {
        guard let days = signer.daysLeft else { return .secondary }
        return days <= 1 ? .red : days <= SelfSigner.refreshWithDaysLeft ? .orange : .secondary
    }

    private var footer: String {
        if let blocker = signer.updateBlocker { return blocker }
        if !signer.signedIn { return String(localized: "Poki Setup on your Mac renews Poki when this iPhone is connected.") }
        if signer.next != nil {
            return model.signingIdle
                ? String(localized: "Installing closes Poki for a moment. Your chats and setup stay.")
                : (model.signingBusyReason ?? "") + " " + String(localized: "Install is available when Poki isn’t running a task.")
        }
        return String(localized: "Poki gets the next build ready by itself, \(Int(SelfSigner.refreshWithDaysLeft)) days before it expires or when your channel has an update. It installs only when you tap Install.")
    }
}

/// Home's warning that the installed Poki stops opening soon (ESP-222). Renewing happens on the Mac:
/// it installs a build with a new profile, so a renewed Poki has a later expiry and no warning.
struct ExpiryWarning {
    let expiry: Date

    init?(expiry: Date?, now: Date = .now) {
        guard let expiry, expiry.timeIntervalSince(now) <= SelfSigner.warnWithDaysLeft * 86_400 else { return nil }
        self.expiry = expiry
    }

    var message: String {
        let when = expiry.formatted(date: .abbreviated, time: .shortened)
        return String(localized: "Poki stops opening after \(when). Connect this iPhone to your Mac and ask your agent to renew it.")
    }
}

struct ExpiryWarningSection: View {
    let warning: ExpiryWarning

    var body: some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Poki’s signing ends soon").font(Prominent.font(.headline, .semibold))
                    Text(warning.message).font(.subheadline).foregroundStyle(Color(.secondaryLabel))
                }
            } icon: {
                Image(systemName: "clock.badge.exclamationmark.fill").foregroundStyle(.orange)
            }
        }
    }
}

/// The release channel, the anisette server, and the optional Apple Account.
struct SigningOptionsPage: View {
    @Environment(AppModel.self) private var model
    @State private var anisette = ""
    /// The channel's newest build has been looked up (found or not) since the page opened.
    @State private var checked = false
    private var signer: SelfSigner { model.signer }

    /// Shown most stable first, as the person reads them.
    private var channels: [SelfSigner.Channel] {
        let order = ["stable", "beta", "alpha", "pre-alpha"]
        return (signer.status?.channels ?? []).sorted { (order.firstIndex(of: $0.id) ?? 9) < (order.firstIndex(of: $1.id) ?? 9) }
    }

    var body: some View {
        Form {
            Section {
                Picker("Release Channel", selection: Binding(get: { signer.status?.channel ?? "stable" }, set: { id in Task { await signer.setChannel(id) } })) {
                    ForEach(channels) { Text($0.title).tag($0.id) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("Release Channel")
            } footer: {
                // Pre-alpha is offered, and so named, only to people signed in to GitHub.
                Text(signer.githubSignedIn
                     ? "Poki downloads and signs updates from this channel ahead of time, the same way Poki Setup does. Stable gets full releases only; Beta, Alpha and Pre-alpha get earlier builds."
                     : "Poki downloads and signs updates from this channel ahead of time, the same way Poki Setup does. Stable gets full releases only; Beta and Alpha get earlier builds.")
            }
            if signer.previewsEnabled { PreviewBuildsSection(signer: signer) }
            Section {
                LabeledContent("Installed") { Text(verbatim: signer.installedTitle) }
                LabeledContent {
                    if let latest = signer.latest {
                        Text(verbatim: SelfSigner.title(version: latest.version, build: latest.build, pr: latest.preview_pr))
                    } else {
                        (checked ? Text("Not Found") : Text("Checking…")).foregroundStyle(Color(.secondaryLabel))
                    }
                } label: {
                    signer.status?.preview == nil ? Text("Newest on This Channel") : Text("Newest Preview Build")
                }
                if let latest = signer.latest {
                    LabeledContent("Status") { signer.isNewer(latest) ? Text("Update Available") : Text("Up to Date") }
                }
            } header: {
                Text("Version")
            } footer: {
                Text("Poki looks on GitHub for the newest build on the chosen channel.")
            }
            .task(id: "\(signer.status?.channel ?? "") \(signer.status?.preview ?? 0)") {
                checked = false
                await signer.checkLatest()
                checked = true
            }
            Section {
                TextField("https://new.ani.sidestore.io", text: $anisette)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit { Task { await signer.setAnisette(anisette) } }
                Button("Use Default Server") { anisette = ""; Task { await signer.setAnisette("") } }
            } header: {
                Text("Anisette Server")
            } footer: {
                Text("Apple’s sign-in needs device headers that only Apple hardware makes. Poki gets them from this anisette server. It never sees your Apple ID or password.")
            }
            Section {
                NavigationLink {
                    Form { AccountPage() }
                        .navigationTitle("Apple Account")
                        .navigationBarTitleDisplayMode(.inline)
                } label: {
                    LabeledContent {
                        if signer.signedIn { Text(verbatim: signer.status?.apple_id ?? "") }
                        else { Text("Optional").foregroundStyle(Color(.secondaryLabel)) }
                    } label: {
                        Label("Apple Account", systemImage: "person.crop.circle")
                    }
                }
                NavigationLink {
                    GitHubAccountPage()
                } label: {
                    LabeledContent {
                        if signer.githubSignedIn { Text(verbatim: signer.status?.github_login ?? "") }
                        else { Text("Optional").foregroundStyle(Color(.secondaryLabel)) }
                    } label: {
                        Label("GitHub Account", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                }
            } footer: {
                Text("Optional. To renew Poki without a Mac, sign in to your Apple Account here. A GitHub Account is only for people developing Poki.")
            }
            SignerActivityRows(signer: signer)
        }
        .navigationTitle("Build Options")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { anisette = signer.status?.anisette ?? "" }
    }
}

/// The GitHub Account, under the Apple Account in Build Options: GitHub's device sign-in, and
/// the Preview Builds switch, which is there only while signed in. With the switch on, Build
/// Options lists the preview builds under the release channels.
struct GitHubAccountPage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var copied = false
    private var signer: SelfSigner { model.signer }

    var body: some View {
        Form {
            if signer.githubSignedIn {
                Section {
                    LabeledContent("GitHub Account") {
                        if let login = signer.status?.github_login, !login.isEmpty { Text(verbatim: login) } else { Text("Signed In") }
                    }
                }
                Section {
                    Toggle("Preview Builds", isOn: Binding(get: { signer.previewsEnabled }, set: { on in Task { await signer.setPreviewsEnabled(on) } }))
                } footer: {
                    Text("Preview builds come from pull requests that are not merged, for testing a change before it reaches any channel. Choose one under the release channels in Build Options.")
                }
                Section { Button("Sign Out", role: .destructive) { Task { await signer.signOutOfGitHub() } } }
            } else if let code = signer.githubCode {
                Section {
                    LabeledContent("Code") { Text(verbatim: code.user_code).font(.title3.monospaced().weight(.semibold)).textSelection(.enabled) }
                    Button(copied ? "Copied" : "Copy Code and Open GitHub") {
                        UIPasteboard.general.string = code.user_code
                        copied = true
                        if let url = URL(string: code.verification_uri) { openURL(url) }
                    }
                    LabeledContent { ProgressView() } label: { Text("Waiting for GitHub") }
                } footer: {
                    Text("Enter this code on GitHub, then come back to Poki.")
                }
                Section { Button("Cancel", role: .cancel) { signer.cancelGitHubSignIn() } }
            } else {
                Section {
                    Button("Sign In with GitHub") { copied = false; Task { await signer.signInToGitHub() } }
                } footer: {
                    Text("For people developing Poki. Poki asks GitHub for no permissions, and the sign-in stays in this iPhone’s Keychain.")
                }
            }
            if let error = signer.githubError {
                Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
            }
        }
        .navigationTitle("GitHub Account")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Preview builds of pull requests, shown in Build Options while Preview Builds is on (the
/// switch on the GitHub Account page). A preview build is on no channel: choosing one makes Poki follow that pull
/// request's builds, and None goes back to the release channel.
struct PreviewBuildsSection: View {
    let signer: SelfSigner
    @State private var loaded = false

    var body: some View {
        Section {
            Picker("Preview Build", selection: Binding(get: { signer.status?.preview ?? 0 }, set: { pr in Task { await signer.setPreview(pr == 0 ? nil : pr) } })) {
                Text("None").tag(0)
                ForEach(signer.previews, id: \.tag) { build in
                    if let pr = build.preview_pr {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: SelfSigner.title(version: build.version, build: build.build, pr: pr))
                            if let title = build.title, !title.isEmpty {
                                Text(verbatim: title).font(.footnote).foregroundStyle(Color(.secondaryLabel)).lineLimit(2)
                            }
                        }
                        .tag(pr)
                    }
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            if signer.previews.isEmpty {
                (loaded ? Text("No Preview Builds") : Text("Checking…")).foregroundStyle(Color(.secondaryLabel))
            }
        } header: {
            Text("Preview Build")
        } footer: {
            Text("A preview build comes from a pull request that is not merged. It is not on any channel and it can break. Choose None to go back to your release channel.")
        }
        .task {
            await signer.loadPreviews()
            loaded = true
        }
    }
}
