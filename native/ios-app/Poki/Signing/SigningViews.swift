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
        if signer.needsCode {
            Section {
                TextField("Verification Code", text: $code)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .onChange(of: code) { _, new in
                        let digits = String(new.filter(\.isNumber).prefix(6))
                        if digits != new { code = digits }
                    }
                Button("Verify") { Task { await signer.finishSignIn(code: code); code = "" } }
                    .disabled(code.count != 6 || signer.working != nil)
            } footer: {
                Text("Apple sent a six-digit code to your trusted devices or phone number.")
            }
            VerificationCodeRecoverySection(signer: signer, clearCode: { code = "" })
        } else if signer.signedIn, !signer.sessionExpired {
            Section {
                LabeledContent("Apple Account", value: signer.status?.apple_id ?? "")
                if let name = signer.status?.name, name != signer.status?.apple_id { LabeledContent("Name", value: name) }
                if signer.teams.count > 1 {
                    Picker("Team", selection: Binding(get: { signer.status?.team_id ?? "" }, set: { id in
                        if let team = signer.teams.first(where: { $0.team_id == id }) { Task { await signer.choose(team: team) } }
                    })) {
                        ForEach(signer.teams) { team in
                            Text(verbatim: team.is_free ? AppLocalization.text(LocalizedStringResource("\(team.name) (Free)")) : team.name).tag(team.team_id)
                        }
                    }
                } else if let team = signer.teams.first {
                    LabeledContent("Team", value: team.is_free ? AppLocalization.text(LocalizedStringResource("\(team.name) (Free, 7-day signing)")) : team.name)
                }
            } footer: {
                Text(signer.status?.keeps_password == true
                     ? "Poki keeps the password in this iPhone’s Keychain to sign itself again every week."
                     : "Poki signs in again when its signing is due, and asks you for the password then.")
            }
            .task { if signer.teams.isEmpty, signer.working == nil, !signer.needsCode, !signer.rateLimited { await signer.loadTeams() } }
            Section { Button("Sign Out", role: .destructive) { Task { await signer.signOut() } } }
        } else {
            if signer.needsReauth, signer.lastError != SelfSigner.reauthMessage {
                Section { Label(SelfSigner.localizedErrorText(SelfSigner.reauthMessage), systemImage: "exclamationmark.triangle").foregroundStyle(Tint.amberInk) }
            }
            if signer.sessionExpired {
                Section { SessionExpiredLabel() }
                    // Apple may take the sign-in again by now (its developer service turned one token
                    // away, then took the next). Opening the page checks once, as it does when signed in.
                    .task { if signer.working == nil, !signer.needsCode, !signer.rateLimited { await signer.loadTeams() } }
            }
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
                Text("You can use a free Apple Account. Signing lasts 7 days, and Poki automatically prepares a renewal before it expires. Your Apple Account and password are sent only to Apple.")
            }
            Section {
                Button("Sign In") { Task { await signer.signIn(appleID: appleID, password: password, keepPassword: keepPassword); password = "" } }
                    .disabled(appleID.isEmpty || password.isEmpty || signer.working != nil)
            }
            // Signing in again is for the same account, so its Apple ID is already there.
            .onAppear { if appleID.isEmpty, signer.sessionExpired { appleID = signer.status?.apple_id ?? "" } }
            // The account is still stored, so it can be signed out here as when its sign-in works.
            if signer.sessionExpired, signer.signedIn {
                Section { Button("Sign Out", role: .destructive) { Task { await signer.signOut() } } }
            }
        }
        SignerActivityRows(signer: signer, offersSignIn: false)
    }
}

/// Why Poki needs the Apple Account again, in the owner's language.
struct SessionExpiredLabel: View {
    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text("Apple Sign-In Expired").font(Prominent.font(.headline, .semibold))
                Text("Poki signs itself with your Apple Account to renew and update without a Mac. Sign in again to keep that working.")
                    .font(.subheadline).foregroundStyle(Color(.secondaryLabel))
            }
        } icon: {
            Image(systemName: "person.crop.circle.badge.exclamationmark").foregroundStyle(.orange)
        }
    }
}

/// The Apple Account as a page of its own under Signing & Updates.
struct AppleAccountPage: View {
    var body: some View {
        Form { AccountPage() }
            .navigationTitle(AppLocalization.text("Apple Account"))
            .navigationBarTitleDisplayMode(.inline)
            .settingsPage()
    }
}

/// What the signer is doing, or why it stopped.
struct SignerActivityRows: View {
    let signer: SelfSigner
    /// Off where the sign-in form is already on screen, or would be a step away from a sheet.
    var offersSignIn = true
    var body: some View {
        if let working = signer.working {
            Section {
                if let f = signer.fraction { ProgressView(value: f) { Text(verbatim: local(working)) } } else { LabeledContent { ProgressView() } label: { Text(verbatim: local(working)) } }
            }
        }
        // Apple's sign-in ran out: say so plainly, with the way back right under it. Where the sign-in
        // form is already on screen, the page says this above the form instead.
        if signer.sessionExpired, offersSignIn {
            Section {
                SessionExpiredLabel()
                NavigationLink { AppleAccountPage() } label: {
                    SettingsLabel("Sign In Again", systemImage: "person.crop.circle.badge.checkmark")
                }
                .disabled(signer.working != nil)
            }
        }
        // Every failure but Apple's expired sentence itself, which the row above or the form says.
        if let error = signer.shownError {
            // The signer's words are English; those the strings table knows are shown in the owner's language.
            Section { problem(Text(verbatim: local(error))) }
        }
        // The core's own sentences name its servers. They are in the log; the page says what to do.
        if signer.updateCheckError != nil {
            Section { problem(Text("Poki couldn’t check for updates. Check your internet connection and try again.")) }
        } else if signer.latest?.source_notice != nil {
            Section {
                Label { Text("The primary download server is unavailable. Poki is using a backup server for this update.") } icon: { Image(systemName: "info.circle") }
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(Color(.secondaryLabel))
            }
        }
    }

    /// The signer's words are English; those the strings table knows are shown in Poki's language.
    private func local(_ text: String) -> String { SelfSigner.localizedErrorText(text) }

    private func problem(_ text: Text) -> some View {
        Label { text } icon: { Image(systemName: "exclamationmark.triangle") }
            .labelStyle(.titleAndIcon)
            .foregroundStyle(Tint.red)
    }
}

/// Settings › Signing & Updates: the installed Poki and the newest one, when its signing ends, the
/// update or the renewal to install, and the way to the Apple Account and to Advanced.
struct SigningUpdatesPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List { SigningSection() }
            .navigationTitle(AppLocalization.text("Signing & Updates"))
            .navigationBarTitleDisplayMode(.inline)
            // The page says what the newest Poki is, so it looks it up when it opens. It only looks:
            // downloading starts from the button, or from the signer's own rounds.
            .task {
                let signer = model.signer
                if signer.latest != nil, let last = signer.lastCheck, Date().timeIntervalSince(last) < 60 { return }
                await signer.lookUp()
            }
    }
}

/// The rows of Signing & Updates. Setup's checklist shows them too.
struct SigningSection: View {
    @Environment(AppModel.self) private var model
    private var signer: SelfSigner { model.signer }

    var body: some View {
        Section {
            SettingsRow(title: "Version", symbol: "info", value: "\(signer.installedVersion) (\(signer.installedBuild))")
            if let latest = signer.latest {
                let newer = signer.isNewer(latest)
                SettingsRow(title: "Latest Version", symbol: "sparkles",
                            value: newer ? "\(latest.version) (\(latest.build))" : AppLocalization.text(LocalizedStringResource("Up to Date")), warns: newer)
            } else if signer.lookingUp {
                SettingsRow(title: "Latest Version", symbol: "sparkles", value: AppLocalization.text(LocalizedStringResource("Checking…")))
            } else if signer.updateCheckError != nil {
                SettingsRow(title: "Latest Version", symbol: "sparkles", value: AppLocalization.text(LocalizedStringResource("Unable to Check")))
            }
            SignedUntilRow(expiry: signer.expiry, countdownColor: countdownColor)
            if !signer.updateNotReady, let next = signer.next {
                SettingsRow(title: next.kind == "update" ? "Update Ready" : "Renewal Ready", symbol: "checkmark.seal",
                            value: next.kind == "update" ? "\(next.version) (\(next.build))"
                                : AppLocalization.text(LocalizedStringResource("Until \(next.expires.formatted(.dateTime.month(.abbreviated).day().year().locale(AppLocalization.locale)))")))
            }
        }

        // The actions under what they act on. A newer build not yet downloaded comes first: one tap
        // downloads and installs it (or, without an Apple Account, opens the sign-in).
        Section {
            switch signer.updateStep {
            case .download:
                SignerAction(signer: signer, title: "Download and Install Update", systemImage: "arrow.down") { await signer.downloadAndInstallUpdate() }
            case .signIn:
                NavigationLink { AppleAccountPage() } label: {
                    SettingsLabel("Sign In to Download the Update", systemImage: "person.badge.plus")
                }
            case .install, nil:
                if let next = signer.next {
                    // Idle is partly time (a minute since the last agent step), which nothing observes, so
                    // the row looks again every few seconds instead of staying as it was first drawn.
                    TimelineView(.periodic(from: .now, by: 5)) { _ in
                        SignerAction(signer: signer, title: next.kind == "update" ? "Install Update" : "Install Renewal", systemImage: "arrow.down.app") { await signer.install() }
                    }
                }
            }
            if signer.needsCode {
                Button {
                    signer.presentCodeSheet()
                } label: {
                    SettingsLabel("Enter Verification Code…", systemImage: "lock.shield")
                }
            }
            if signer.signedIn {
                SignerAction(signer: signer, title: "Prepare Renewal Now", systemImage: "arrow.clockwise") { await signer.prepare(kind: "refresh") }
            }
        } footer: {
            Text(footer)
        }

        Section {
            NavigationLink { AppleAccountPage() } label: {
                SettingsRow(title: "Apple Account", symbol: "person",
                            value: signer.signedIn ? signer.status?.apple_id : AppLocalization.text(LocalizedStringResource("Not Signed In")))
            }
            NavigationLink { SigningOptionsPage() } label: {
                SettingsRow(title: "Advanced", symbol: "slider.horizontal.3")
            }
        } footer: {
            Text("Optional. To renew Poki without a Mac, sign in to your Apple Account here.")
        }
        SignerActivityRows(signer: signer)
    }

    /// Amber when the next build is due, red on the last day.
    private var countdownColor: Color {
        guard let days = signer.daysLeft else { return Color(.secondaryLabel) }
        return days <= 1 ? Tint.red : days <= SelfSigner.refreshWithDaysLeft ? Tint.amberInk : Color(.secondaryLabel)
    }

    private var footer: String {
        if let blocker = signer.updateBlocker { return blocker }
        if !signer.signedIn { return AppLocalization.text(LocalizedStringResource("Poki Setup on your Mac renews Poki when this iPhone is connected.")) }
        if signer.next != nil {
            return model.signingIdle
                ? AppLocalization.text(LocalizedStringResource("Installing closes Poki for a moment. Your chats and setup stay."))
                : (model.signingBusyReason ?? "") + " " + AppLocalization.text(LocalizedStringResource("Install is available when Poki isn’t running a task."))
        }
        return AppLocalization.text(LocalizedStringResource("Poki automatically prepares a renewal \(Int(SelfSigner.refreshWithDaysLeft)) days before signing expires, or prepares an update when one is available. Nothing is installed until you tap Install."))
    }
}

/// When the installed Poki stops opening: the date under the row's name and the time left where the
/// other rows have their value (under the date at the accessibility sizes, as in `SettingsRow`).
private struct SignedUntilRow: View {
    var expiry: Date?
    var countdownColor: Color
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var iconSpacing = SettingsRowMetrics.iconSpacing

    var body: some View {
        HStack(spacing: min(18, iconSpacing)) {
            SettingsIcon(symbol: "signature")
                .padding(.vertical, SettingsRowMetrics.iconLineInset)
            VStack(alignment: .leading, spacing: 2) {
                Text("Signed Until").font(.body).foregroundStyle(Color(.label))
                if let expiry {
                    Text(expiry, format: .dateTime.month(.abbreviated).day().year())
                        .font(.footnote).foregroundStyle(Color(.secondaryLabel))
                }
                if typeSize.isAccessibilitySize { left }
            }
            Spacer(minLength: 8)
            if !typeSize.isAccessibilitySize { left.lineLimit(1).layoutPriority(1) }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var left: some View {
        if let expiry {
            Text(expiry, style: .relative).font(.subheadline).monospacedDigit().foregroundStyle(countdownColor)
        } else {
            Text("Unknown").font(.subheadline).foregroundStyle(Color(.secondaryLabel))
        }
    }
}

/// What the Signing & Updates page offers when there is a newer Poki.
enum UpdateStep: Equatable {
    /// One tap downloads it, signs it and installs it.
    case download
    /// A signed copy of it is ready.
    case install
    /// No Apple Account: sign in here, or install it with Poki Setup on a Mac.
    case signIn

    init?(updateAvailable: Bool, copyReady: Bool, signedIn: Bool) {
        guard updateAvailable else { return nil }
        self = copyReady ? .install : signedIn ? .download : .signIn
    }
}

/// One signer action row, disabled while the signer works.
struct SignerAction: View {
    let signer: SelfSigner
    let title: LocalizedStringKey
    let systemImage: String
    let work: () async -> Void

    var body: some View {
        Button { Task { await work() } } label: { SettingsLabel(title, systemImage: systemImage) }
            .disabled(signer.working != nil)
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
        let when = expiry.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(AppLocalization.locale))
        return AppLocalization.text(LocalizedStringResource("Poki stops opening after \(when). Connect this iPhone to your Mac and ask your agent to renew it."))
    }
}

/// Signing & Updates › Advanced: the release channel Poki follows, and the server that helps Poki
/// sign in to the Apple Account (the core's anisette server). Poki's own server is used until the
/// person names another.
struct SigningOptionsPage: View {
    @Environment(AppModel.self) private var model
    @State private var address = ""
    /// Custom was tapped, so the address field shows before the signer has an address to keep.
    @State private var entering = false
    /// The address last handed to the signer, so leaving the page does not hand it over twice.
    @State private var sent: String?
    @FocusState private var typing: Bool
    private var signer: SelfSigner { model.signer }
    private var saved: String? { signer.customSignInServer }

    var body: some View {
        List {
            if let status = signer.status, !status.channels.isEmpty {
                Section {
                    ForEach(status.channels) { channel in
                        ChoiceRow(title: Text(verbatim: channel.title), selected: channel.id == status.channel) {
                            if channel.id != status.channel { Task { await signer.setChannel(channel.id) } }
                        }
                    }
                } header: {
                    SettingsHeader("Release Channel")
                } footer: {
                    Text("Poki receives updates from the selected release channel.")
                }
            }
            Section {
                ChoiceRow(title: Text("Default"), selected: saved == nil) {
                    entering = false
                    address = ""
                    sent = nil
                    typing = false
                    if saved != nil { Task { await signer.setAnisette("") } }
                }
                // The tick moves to Custom once the signer has taken the address.
                ChoiceRow(title: Text("Custom"), selected: saved != nil) {
                    entering = true
                    typing = true
                }
                if entering || saved != nil {
                    TextField("Server Address", text: $address)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .focused($typing)
                        .onSubmit { save() }
                }
            } header: {
                SettingsHeader("Sign-In Server")
            } footer: {
                Text("Signing in to your Apple Account in Poki requires a sign-in server to verify this iPhone. The server never sees your Apple Account or password. Change this only if signing in continues to fail.")
            }
            SignerActivityRows(signer: signer)
        }
        .navigationTitle(AppLocalization.text("Advanced"))
        .navigationBarTitleDisplayMode(.inline)
        .settingsPage()
        // The signer's answer can come after the page opens, and it is what the field shows.
        .onChange(of: saved, initial: true) { _, saved in
            if let saved { address = saved }
        }
        // An address typed and left with Back is kept like one sent with Done.
        .onDisappear { save() }
    }

    private func save() {
        let url = address.trimmingCharacters(in: .whitespaces)
        guard !url.isEmpty, url != saved, url != sent else { return }
        sent = url
        Task { await signer.setAnisette(url) }
    }
}

/// One choice of a few, ticked when it is the one in use (the rows of Settings › Language).
private struct ChoiceRow: View {
    let title: Text
    let selected: Bool
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            HStack {
                title.foregroundStyle(Color(.label))
                Spacer()
                if selected {
                    Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Tint.blueText)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(.rect)
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

extension EnvironmentValues {
    @Entry var pokiDetailsOpen = false
}

/// Six-digit 2FA verification sheet shown when renewing a saved-password Apple session requires a code.
struct VerificationCodeSheet: View {
    @Environment(AppModel.self) private var model
    @State private var code = ""

    private var signer: SelfSigner { model.signer }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("6-Digit Code", text: $code)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .onChange(of: code) { _, new in
                            let digits = String(new.filter(\.isNumber).prefix(6))
                            if digits != new { code = digits }
                            if digits.count == 6, signer.working == nil {
                                submit()
                            }
                        }
                } header: {
                    Text("Two-Factor Authentication")
                } footer: {
                    Text("Enter the 6-digit verification code sent to your trusted devices or phone number.")
                }
                VerificationCodeRecoverySection(signer: signer, clearCode: { code = "" })
                SignerActivityRows(signer: signer, offersSignIn: false)
            }
            .navigationTitle(AppLocalization.text("Verification Code"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { signer.dismissCodeSheet() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Verify") { submit() }
                        .disabled(code.count != 6 || signer.working != nil)
                }
            }
        }
    }

    private func submit() {
        let entered = code
        code = ""
        Task { await signer.finishSignIn(code: entered) }
    }
}

struct VerificationCodeRecoverySection: View {
    let signer: SelfSigner
    let clearCode: () -> Void

    var body: some View {
        Section {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Button {
                    Task { await signer.resendCode(now: context.date) }
                } label: {
                    Text(signer.resendButtonTitle(at: context.date))
                }
                .disabled(!signer.canResendCode(at: context.date))
            }
            Button("Cancel Sign-In", role: .destructive) {
                clearCode()
                Task { await signer.cancelSignIn() }
            }
            .disabled(signer.working != nil)
        }
    }
}
