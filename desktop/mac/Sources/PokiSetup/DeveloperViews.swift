import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: GitHub Account

/// Developer > GitHub Account: the sign-in that lists and downloads test builds. GitHub's device
/// sign-in, the GitHub CLI's sign-in on this Mac, or a token pasted by hand.
struct GitHubAccountView: View {
    @EnvironmentObject var model: AppModel
    @State private var token = ""
    @State private var savingToken = false
    @State private var confirmSignOut = false

    var body: some View {
        Form {
            HeroSection {
                PageHero(symbol: "person.badge.key", title: localized("GitHub Account"), subtitle: localized("Optional, for people developing Poki. Signed in, Poki Setup lists the test builds GitHub Actions makes and installs them."))
            }
            if model.dev.signedIn {
                signedIn
            } else {
                signIn
            }
            if let error = model.githubError {
                Section { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            }
        }
        .pokiPage()
        .task { await model.refreshDev() }
    }

    @ViewBuilder private var signedIn: some View {
        Section(localized("Account")) {
            LabeledContent(localized("Signed In As")) { Text(model.dev.login ?? "GitHub").foregroundStyle(.secondary).textSelection(.enabled) }
            LabeledContent(localized("Signed In With")) { Text(sourceTitle).foregroundStyle(.secondary) }
            LabeledContent(localized("Repository")) {
                if let url = URL(string: "https://github.com/\(model.dev.repo)") {
                    Link(model.dev.repo, destination: url)
                }
            }
        }
        Section {
            HStack {
                Button(localized("Sign Out…"), role: .destructive) { confirmSignOut = true }
                Spacer()
                Button(localized("Open Test Builds")) { model.page = .testBuilds }
                    .pokiProminentButton()
            }
        } footer: {
            Text(localized("Poki Setup keeps the GitHub sign-in in your Keychain and uses it only to read this repository's builds and pull requests."))
                .font(.footnote).foregroundStyle(.secondary)
        }
        .confirmationDialog(localized("Sign out of GitHub?"), isPresented: $confirmSignOut) {
            Button(localized("Sign Out"), role: .destructive) { Task { await model.signOutOfGitHub() } }
        } message: {
            Text(localized("Test builds stay on your devices. Renewals keep signing them while they are downloaded."))
        }
    }

    private var sourceTitle: String {
        switch model.dev.source {
        case "cli": localized("GitHub CLI on this Mac")
        case "token": localized("Token")
        default: localized("GitHub sign-in")
        }
    }

    @ViewBuilder private var signIn: some View {
        Section {
            if let code = model.githubCode {
                LabeledContent(localized("Code")) {
                    Text(code.userCode).font(.system(.title3, design: .monospaced).weight(.semibold)).textSelection(.enabled)
                }
                LabeledContent(localized("Enter the code on GitHub")) {
                    HStack {
                        ProgressView().controlSize(.small)
                        Button(localized("Copy Code and Open GitHub")) {
                            copyToPasteboard(code.userCode)
                            if let url = URL(string: code.verificationUri) { NSWorkspace.shared.open(url) }
                        }
                        Button(localized("Cancel")) { model.cancelGitHubSignIn() }
                    }
                }
            } else {
                LabeledContent {
                    Button(localized("Sign In with GitHub")) { Task { await model.signInToGitHub() } }
                        .pokiProminentButton()
                        .disabled(!model.dev.canSignIn)
                } label: {
                    Text("GitHub")
                    Text(localized("Opens github.com to confirm a code"))
                }
                if model.dev.cliAvailable {
                    LabeledContent {
                        Button(localized("Use GitHub CLI")) { Task { await model.useGitHubCLI() } }
                    } label: {
                        Text("GitHub CLI")
                        Text(localized("Uses the account gh is signed in to on this Mac"))
                    }
                }
            }
        } header: {
            Text(localized("Sign In"))
        } footer: {
            Text(localized("The GitHub sign-in runs through Poki Preview Sign-in, a GitHub app that can only read the builds and pull requests of the Poki repository."))
                .font(.footnote).foregroundStyle(.secondary)
        }
        Section {
            SecureField(localized("Token"), text: $token, prompt: Text("github_pat_"))
            HStack {
                Spacer()
                if savingToken { ProgressView().controlSize(.small) }
                Button(localized("Use Token")) {
                    Task {
                        savingToken = true
                        if await model.useGitHubToken(token) { token = "" }
                        savingToken = false
                    }
                }
                .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty || savingToken)
            }
        } header: {
            Text(localized("Or Use a Token"))
        } footer: {
            Text(localized("A fine-grained token with read access to Actions on the Poki repository is enough."))
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}

// MARK: Test Builds

/// Developer > Test Builds: the IPAs GitHub Actions runs leave as artifacts, numbered by run, with
/// their branch, commit and pull request. Install signs one with the Apple Account and installs it
/// like a release. Also installs an IPA file from this Mac.
struct TestBuildsView: View {
    @EnvironmentObject var model: AppModel
    @State private var search = ""
    @State private var choosingIPA = false
    @State private var failed: SetupMessage?
    @State private var confirmDelete = false

    private var installing: Bool { model.busyJobs.contains("install") }
    private var downloading: Bool { model.busyJobs.contains("download") }

    var body: some View {
        Form {
            HeroSection {
                PageHero(symbol: "hammer", title: localized("Test Builds"), subtitle: localized("Builds of Poki from GitHub Actions, newest first. Install one on a device the way Install Poki installs a release."))
            }
            TestBuildTarget()
            if let steps = model.steps["install"], !steps.isEmpty, installing || failedStep(steps) {
                Section(localized("Installing")) {
                    JobProgress(steps: steps, running: installing, weights: JobProgress.install, doneTitle: localized("Poki is installed"))
                }
            }
            if let steps = model.steps["download"], !steps.isEmpty, downloading {
                Section(localized("Downloading")) { JobProgress(steps: steps, running: downloading, doneTitle: localized("Downloaded")) }
            }
            if let failed {
                Section { Text(failed.text).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            }
            TestBuildFilters(search: $search)
            buildsSection
            TestBuildSync()
            downloadsSection
        }
        .pokiPage()
        .task {
            await model.refreshDev()
            await model.refreshTestBuilds()
        }
        .task(id: model.page) {
            // While the page is open, the list follows GitHub every minute.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                if model.page == .testBuilds { await model.refreshTestBuilds(fresh: true) }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    choosingIPA = true
                } label: {
                    Label(localized("Install IPA File"), systemImage: "doc.badge.arrow.up")
                }
                .help(localized("Sign an IPA file from this Mac and install it on the device"))
                .disabled(installing || model.selectedPhone?.facts == nil || model.account?.signedIn != true)
                Button {
                    Task { await model.refreshTestBuilds(fresh: true) }
                } label: {
                    Label(localized("Refresh"), systemImage: "arrow.clockwise")
                }
                .help(localized("Look for new builds on GitHub"))
                .keyboardShortcut("r")
                .disabled(model.loadingTestBuilds)
            }
        }
        .fileImporter(isPresented: $choosingIPA, allowedContentTypes: [UTType(filenameExtension: "ipa") ?? .data]) { r in
            if case .success(let url) = r { Task { await installFile(url) } }
        }
        .confirmationDialog(localized("Delete downloaded test builds?"), isPresented: $confirmDelete) {
            Button(localized("Delete"), role: .destructive) { Task { await model.deleteTestBuildDownloads() } }
        } message: {
            Text(localized("Installed builds stay on your devices. A renewal downloads its build again while GitHub still has it."))
        }
    }

    private func failedStep(_ steps: [StepItem]) -> Bool { steps.contains { $0.state == .failed } }

    private var filtered: [TestBuild] {
        let all = model.testBuilds?.builds ?? []
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        return all.filter { b in
            let hay = [b.title, b.branch, b.sha, b.workflow, b.actor ?? "", String(b.runNumber), b.pr.map { "\($0.number) \($0.title)" } ?? ""].joined(separator: " ").lowercased()
            return hay.contains(q)
        }
    }

    @ViewBuilder private var buildsSection: some View {
        Section {
            if model.testBuilds == nil, model.loadingTestBuilds {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(localized("Asking GitHub for builds")).foregroundStyle(.secondary)
                }
            } else if let error = model.testBuildsError, model.testBuilds == nil {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            } else if filtered.isEmpty {
                Text(model.testBuilds?.total ?? 0 > 0 ? localized("No build matches the filters.") : localized("GitHub has no test builds right now."))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(filtered) { b in
                    TestBuildRow(build: b, install: { await install(b) }, download: { await download(b) })
                }
            }
        } header: {
            HStack {
                Text(localized("Builds"))
                Spacer()
                if model.loadingTestBuilds { ProgressView().controlSize(.mini) }
                if let l = model.testBuilds {
                    let checkedAt = Date(timeIntervalSince1970: TimeInterval(l.checkedAt))
                    let time = checkedAt.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(SetupLocalization.shared.locale))
                    Text(localized("\(filtered.count) of \(l.total), checked \(time)"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private var downloadsSection: some View {
        Section(localized("Downloads")) {
            LabeledContent(localized("Downloaded Builds")) {
                HStack {
                    Text(model.dev.downloadsBytes, format: .byteCount(style: .file)).foregroundStyle(.secondary)
                    Button(localized("Show in Finder")) {
                        if let d = model.info?.dataDir {
                            let url = URL(fileURLWithPath: d).appendingPathComponent("cache/test-builds")
                            NSWorkspace.shared.open(FileManager.default.fileExists(atPath: url.path) ? url : URL(fileURLWithPath: d))
                        }
                    }
                    Button(localized("Delete…"), role: .destructive) { confirmDelete = true }
                        .disabled(model.dev.downloadsBytes == 0)
                }
            }
        }
    }

    private func install(_ b: TestBuild) async {
        failed = nil
        guard let target = model.selectedPhone, target.facts != nil else {
            failed = .copy("Connect the device to install on, and choose it above.")
            return
        }
        do {
            let r = try await model.installTestBuild(b, udid: target.id)
            model.banner = .copy("Test build \(b.runNumber) is on \(r.record.phoneName). Open Poki to try it.")
        } catch {
            failed = .verbatim(error.localizedDescription)
        }
    }

    private func download(_ b: TestBuild) async {
        failed = nil
        do { try await model.downloadTestBuild(b) } catch { failed = .verbatim(error.localizedDescription) }
    }

    private func installFile(_ url: URL) async {
        failed = nil
        guard let target = model.selectedPhone, target.facts != nil else {
            failed = .copy("Connect the device to install on, and choose it above.")
            return
        }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let r = try await model.install(udid: target.id, ipa: url, handOff: false)
            model.banner = .copy("\(url.lastPathComponent) is on \(r.record.phoneName).")
        } catch {
            failed = .verbatim(error.localizedDescription)
        }
    }
}

/// The device test builds go on, and what it has now.
private struct TestBuildTarget: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Section(localized("Install On")) {
            if model.phones.isEmpty {
                Label(localized("Connect an iPhone or iPad with a cable to install a build."), systemImage: "cable.connector")
                    .foregroundStyle(.secondary)
            } else {
                Picker(localized("Device"), selection: Binding(get: { model.selectedPhone?.id ?? "" }, set: { model.selectedUDID = $0 })) {
                    ForEach(model.phones) { Text($0.title).tag($0.id) }
                }
                if let row = model.selectedPhone {
                    LabeledContent(localized("Has Now")) { Text(current(row)).foregroundStyle(.secondary) }
                }
            }
            if model.account?.signedIn != true {
                LabeledContent(localized("Sign in with the Apple Account that signs Poki")) {
                    Button(localized("Sign In…")) { model.page = .account }
                }
            }
        }
    }

    private func current(_ row: PhoneRow) -> String {
        guard let r = row.record ?? model.records.first(where: { $0.udid == row.id }) else { return localized("No Poki from this Mac") }
        if let t = r.testBuild { return localized("Test build \(t.runNumber) from \(t.branch), \(String(t.sha.prefix(7)))") }
        return "Poki \(r.version) (\(r.build))"
    }
}

/// Which builds the list shows. The automatic sync follows the same filters.
private struct TestBuildFilters: View {
    @EnvironmentObject var model: AppModel
    @Binding var search: String

    var body: some View {
        Section(localized("Filters")) {
            Toggle(isOn: pref(\.onlyMine)) {
                Text(localized("Only Builds I Started"))
                if let login = model.dev.login { Text(localized("Runs started by \(login)")) }
            }
            Picker(localized("Branch"), selection: Binding(get: { model.dev.prefs.branch ?? "" }, set: { v in
                var p = model.dev.prefs
                p.branch = v.isEmpty ? nil : v
                Task { await model.setDevPrefs(p) }
            })) {
                Text(localized("All Branches")).tag("")
                ForEach(branches, id: \.self) { Text(verbatim: $0).tag($0) }
            }
            Toggle(localized("Only Builds with a Pull Request"), isOn: pref(\.withPrOnly))
            TextField(localized("Search"), text: $search, prompt: Text(localized("Commit, branch, pull request or build number")))
        }
    }

    private var branches: [String] {
        var list = model.testBuilds?.branches ?? []
        if let b = model.dev.prefs.branch, !b.isEmpty, !list.contains(b) { list.append(b) }
        return list
    }

    private func pref(_ key: WritableKeyPath<DevPrefs, Bool>) -> Binding<Bool> {
        Binding(get: { model.dev.prefs[keyPath: key] }, set: { v in
            var p = model.dev.prefs
            p[keyPath: key] = v
            Task { await model.setDevPrefs(p) }
        })
    }
}

/// The automatic sync: download, and install on a chosen device, each new build that matches.
private struct TestBuildSync: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Section {
            Toggle(isOn: pref(\.autoDownload)) {
                Text(localized("Download New Builds"))
                Text(localized("As soon as GitHub has them, so installing takes less time"))
            }
            Toggle(isOn: pref(\.autoInstall)) {
                Text(localized("Install New Builds"))
                Text(localized("On the device below whenever it is connected"))
            }
            if model.dev.prefs.autoInstall {
                Picker(localized("Device"), selection: Binding(get: { model.dev.prefs.autoInstallUdid ?? "" }, set: { v in
                    var p = model.dev.prefs
                    p.autoInstallUdid = v.isEmpty ? nil : v
                    Task { await model.setDevPrefs(p) }
                })) {
                    Text(localized("Choose")).tag("")
                    ForEach(devices) { Text(verbatim: $0.name).tag($0.id) }
                }
            }
            Toggle(isOn: pref(\.closeWithoutAsking)) {
                Text(localized("Close Poki Without Asking"))
                Text(localized("When Poki is open on the device and an install or renewal replaces it"))
            }
            Toggle(isOn: pref(\.keepOnRenew)) {
                Text(localized("Renewals Keep the Test Build"))
                Text(localized("Otherwise renewing a device installs the release again"))
            }
        } header: {
            Text(localized("Automatic"))
        } footer: {
            Text(footer).font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var footer: String {
        guard model.dev.prefs.syncing else { return localized("Poki Setup checks GitHub every two minutes while it is open or in the menu bar.") }
        if let n = model.dev.syncedRun, let b = model.testBuilds?.builds.first(where: { $0.runId == n }) {
            return localized("Poki Setup checks GitHub every two minutes and takes builds newer than build \(b.runNumber) that match the filters.")
        }
        return localized("Poki Setup checks GitHub every two minutes and takes new builds that match the filters.")
    }

    struct Choice: Identifiable, Hashable {
        var id: String
        var name: String
    }

    /// Connected devices and the ones this Mac set up before.
    private var devices: [Choice] {
        var out = model.phones.map { Choice(id: $0.id, name: $0.title) }
        for r in model.records where !out.contains(where: { $0.id == r.udid }) { out.append(Choice(id: r.udid, name: r.phoneName)) }
        if let id = model.dev.prefs.autoInstallUdid, !out.contains(where: { $0.id == id }) { out.append(Choice(id: id, name: localized("Device not connected"))) }
        return out
    }

    private func pref(_ key: WritableKeyPath<DevPrefs, Bool>) -> Binding<Bool> {
        Binding(get: { model.dev.prefs[keyPath: key] }, set: { v in
            var p = model.dev.prefs
            p[keyPath: key] = v
            if key == \DevPrefs.autoInstall, v, p.autoInstallUdid == nil { p.autoInstallUdid = model.selectedPhone?.id }
            Task { await model.setDevPrefs(p) }
        })
    }
}

/// One build: its number, the commit, where it came from, and Install.
private struct TestBuildRow: View {
    @EnvironmentObject var model: AppModel
    var build: TestBuild
    var install: () async -> Void
    var download: () async -> Void

    private var onDevice: Bool {
        guard let id = model.selectedPhone?.id, let r = model.records.first(where: { $0.udid == id }), let t = r.testBuild else { return false }
        return t.artifactId == build.artifactId
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            number
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(build.title.isEmpty ? build.branch : build.title).font(.body.weight(.medium)).lineLimit(1)
                    if onDevice { Badge(text: localized("On Device"), color: .green) }
                    if build.isBuilding { Badge(text: localized("Building"), color: .orange) }
                    if build.state == "expired" { Badge(text: localized("Expired"), color: .secondary) }
                    if build.downloaded, !onDevice { Badge(text: localized("Downloaded"), color: Color.pokiBlue) }
                }
                facts
                if let pr = build.pr, let url = URL(string: pr.url) {
                    Link(destination: url) {
                        Label { Text(verbatim: "#\(pr.number) \(pr.title)").lineLimit(1) } icon: { Image(systemName: "arrow.triangle.pull") }
                    }
                    .font(.callout)
                }
            }
            Spacer(minLength: 8)
            actions
        }
        .padding(.vertical, 3)
        .contextMenu { menuItems }
    }

    private var number: some View {
        VStack(spacing: 0) {
            Text(verbatim: "\(build.runNumber)").font(.system(.title3, design: .rounded).weight(.semibold)).monospacedDigit()
            if build.runAttempt > 1 { Text(localized("try \(build.runAttempt)")).font(.caption2).foregroundStyle(.secondary) }
        }
        .frame(minWidth: 44)
        .padding(.vertical, 4)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .help(localized("Run \(build.runNumber) of \(build.workflow)"))
    }

    private var facts: some View {
        HStack(spacing: 10) {
            Label { Text(verbatim: build.branch).lineLimit(1) } icon: { Image(systemName: "arrow.triangle.branch") }
            Label { Text(verbatim: build.shortSha).monospaced() } icon: { Image(systemName: "number") }
            if let a = build.actor { Label { Text(verbatim: a) } icon: { Image(systemName: "person") } }
            if let d = build.created { Label { Text(d, format: .relative(presentation: .named)) } icon: { Image(systemName: "clock") } }
            if build.size > 0 { Text(build.size, format: .byteCount(style: .file)) }
            if build.workflow != "iOS IPA" { Text(verbatim: build.workflow) }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .labelStyle(CompactLabel())
    }

    @ViewBuilder private var actions: some View {
        if build.isReady {
            HStack(spacing: 6) {
                Menu {
                    menuItems
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                Button(onDevice ? localized("Reinstall") : localized("Install")) { Task { await install() } }
                    .disabled(model.busyJobs.contains("install") || model.selectedPhone?.facts == nil || model.account?.signedIn != true)
            }
        } else if build.isBuilding {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                if let u = URL(string: build.runUrl) { Link(localized("View Run"), destination: u).font(.callout) }
            }
        } else if let u = URL(string: build.runUrl) {
            Link(localized("View Run"), destination: u).font(.callout)
        }
    }

    @ViewBuilder private var menuItems: some View {
        if build.isReady, !build.downloaded {
            Button(localized("Download Only")) { Task { await download() } }
                .disabled(model.busyJobs.contains("download"))
        }
        if let u = URL(string: build.runUrl) {
            Button(localized("Open Run on GitHub")) { NSWorkspace.shared.open(u) }
        }
        if let pr = build.pr, let u = URL(string: pr.url) {
            Button(localized("Open Pull Request \(pr.number)")) { NSWorkspace.shared.open(u) }
        }
        if let u = URL(string: "https://github.com/\(model.dev.repo)/commit/\(build.sha)") {
            Button(localized("Open Commit")) { NSWorkspace.shared.open(u) }
        }
        Divider()
        Button(localized("Copy Commit")) { copyToPasteboard(build.sha) }
        Button(localized("Copy Branch")) { copyToPasteboard(build.branch) }
        Button(localized("Copy Build Details")) { copyToPasteboard(details) }
    }

    /// For a bug report or a message to whoever made the build.
    private var details: String {
        var lines = [localized("Build \(build.runNumber) (\(build.workflow))"), localized("Branch \(build.branch)"), localized("Commit \(build.sha)"), build.runUrl]
        if let pr = build.pr { lines.insert(localized("Pull request \(pr.number) \(pr.title)"), at: 3) }
        return lines.joined(separator: "\n")
    }
}

/// A small coloured capsule, like ExpiryBadge.
private struct Badge: View {
    var text: String
    var color: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 1)
            .foregroundStyle(color)
            .background(color.opacity(0.14), in: Capsule())
    }
}

/// An icon and its text close together, for the small facts under a build.
private struct CompactLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon
            configuration.title
        }
    }
}
