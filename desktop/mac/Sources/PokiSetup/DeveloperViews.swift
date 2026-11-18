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
                PageHero(symbol: "person.badge.key", title: "GitHub Account", subtitle: "Optional, for people developing Poki. Signed in, Poki Setup lists the test builds GitHub Actions makes and installs them.")
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
        Section("Account") {
            LabeledContent("Signed In As") { Text(model.dev.login ?? "GitHub").foregroundStyle(.secondary).textSelection(.enabled) }
            LabeledContent("Signed In With") { Text(sourceTitle).foregroundStyle(.secondary) }
            LabeledContent("Repository") {
                if let url = URL(string: "https://github.com/\(model.dev.repo)") {
                    Link(model.dev.repo, destination: url)
                }
            }
        }
        Section {
            HStack {
                Button("Sign Out…", role: .destructive) { confirmSignOut = true }
                Spacer()
                Button("Open Test Builds") { model.page = .testBuilds }
                    .pokiProminentButton()
            }
        } footer: {
            Text("Poki Setup keeps the GitHub sign-in in your Keychain and uses it only to read this repository's builds and pull requests.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .confirmationDialog("Sign out of GitHub?", isPresented: $confirmSignOut) {
            Button("Sign Out", role: .destructive) { Task { await model.signOutOfGitHub() } }
        } message: {
            Text("Test builds stay on your devices. Renewals keep signing them while they are downloaded.")
        }
    }

    private var sourceTitle: String {
        switch model.dev.source {
        case "cli": "GitHub CLI on this Mac"
        case "token": "Token"
        default: "GitHub sign-in"
        }
    }

    @ViewBuilder private var signIn: some View {
        Section {
            if let code = model.githubCode {
                LabeledContent("Code") {
                    Text(code.userCode).font(.system(.title3, design: .monospaced).weight(.semibold)).textSelection(.enabled)
                }
                LabeledContent("Enter the code on GitHub") {
                    HStack {
                        ProgressView().controlSize(.small)
                        Button("Copy Code and Open GitHub") {
                            copyToPasteboard(code.userCode)
                            if let url = URL(string: code.verificationUri) { NSWorkspace.shared.open(url) }
                        }
                        Button("Cancel") { model.cancelGitHubSignIn() }
                    }
                }
            } else {
                LabeledContent {
                    Button("Sign In with GitHub") { Task { await model.signInToGitHub() } }
                        .pokiProminentButton()
                        .disabled(!model.dev.canSignIn)
                } label: {
                    Text("GitHub")
                    Text("Opens github.com to confirm a code")
                }
                if model.dev.cliAvailable {
                    LabeledContent {
                        Button("Use GitHub CLI") { Task { await model.useGitHubCLI() } }
                    } label: {
                        Text("GitHub CLI")
                        Text("Uses the account gh is signed in to on this Mac")
                    }
                }
            }
        } header: {
            Text("Sign In")
        } footer: {
            Text("The GitHub sign-in runs through Poki Preview Sign-in, a GitHub app that can only read the builds and pull requests of the Poki repository.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        Section {
            SecureField("Token", text: $token, prompt: Text("github_pat_"))
            HStack {
                Spacer()
                if savingToken { ProgressView().controlSize(.small) }
                Button("Use Token") {
                    Task {
                        savingToken = true
                        if await model.useGitHubToken(token) { token = "" }
                        savingToken = false
                    }
                }
                .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty || savingToken)
            }
        } header: {
            Text("Or Use a Token")
        } footer: {
            Text("A fine-grained token with read access to Actions on the Poki repository is enough.")
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
    @State private var failed: String?
    @State private var confirmDelete = false

    private var installing: Bool { model.busyJobs.contains("install") }
    private var downloading: Bool { model.busyJobs.contains("download") }

    var body: some View {
        Form {
            HeroSection {
                PageHero(symbol: "hammer", title: "Test Builds", subtitle: "Builds of Poki from GitHub Actions, newest first. Install one on a device the way Install Poki installs a release.")
            }
            TestBuildTarget()
            if let steps = model.steps["install"], !steps.isEmpty, installing || failedStep(steps) {
                Section("Installing") {
                    JobProgress(steps: steps, running: installing, weights: JobProgress.install, doneTitle: "Poki is installed")
                }
            }
            if let steps = model.steps["download"], !steps.isEmpty, downloading {
                Section("Downloading") { JobProgress(steps: steps, running: downloading, doneTitle: "Downloaded") }
            }
            if let failed {
                Section { Text(failed).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
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
                    Label("Install IPA File", systemImage: "doc.badge.arrow.up")
                }
                .help("Sign an IPA file from this Mac and install it on the device")
                .disabled(installing || model.selectedPhone?.facts == nil || model.account?.signedIn != true)
                Button {
                    Task { await model.refreshTestBuilds(fresh: true) }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Look for new builds on GitHub")
                .keyboardShortcut("r")
                .disabled(model.loadingTestBuilds)
            }
        }
        .fileImporter(isPresented: $choosingIPA, allowedContentTypes: [UTType(filenameExtension: "ipa") ?? .data]) { r in
            if case .success(let url) = r { Task { await installFile(url) } }
        }
        .confirmationDialog("Delete downloaded test builds?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { Task { await model.deleteTestBuildDownloads() } }
        } message: {
            Text("Installed builds stay on your devices. A renewal downloads its build again while GitHub still has it.")
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
                    Text("Asking GitHub for builds").foregroundStyle(.secondary)
                }
            } else if let error = model.testBuildsError, model.testBuilds == nil {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            } else if filtered.isEmpty {
                Text(model.testBuilds?.total ?? 0 > 0 ? "No build matches the filters." : "GitHub has no test builds right now.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(filtered) { b in
                    TestBuildRow(build: b, install: { await install(b) }, download: { await download(b) })
                }
            }
        } header: {
            HStack {
                Text("Builds")
                Spacer()
                if model.loadingTestBuilds { ProgressView().controlSize(.mini) }
                if let l = model.testBuilds {
                    Text("\(filtered.count) of \(l.total), checked \(Date(timeIntervalSince1970: TimeInterval(l.checkedAt)).formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private var downloadsSection: some View {
        Section("Downloads") {
            LabeledContent("Downloaded Builds") {
                HStack {
                    Text(ByteCountFormatter.string(fromByteCount: model.dev.downloadsBytes, countStyle: .file)).foregroundStyle(.secondary)
                    Button("Show in Finder") {
                        if let d = model.info?.dataDir {
                            let url = URL(fileURLWithPath: d).appendingPathComponent("cache/test-builds")
                            NSWorkspace.shared.open(FileManager.default.fileExists(atPath: url.path) ? url : URL(fileURLWithPath: d))
                        }
                    }
                    Button("Delete…", role: .destructive) { confirmDelete = true }
                        .disabled(model.dev.downloadsBytes == 0)
                }
            }
        }
    }

    private func install(_ b: TestBuild) async {
        failed = nil
        guard let target = model.selectedPhone, target.facts != nil else {
            failed = "Connect the device to install on, and choose it above."
            return
        }
        do {
            let r = try await model.installTestBuild(b, udid: target.id)
            model.banner = "Test build \(b.runNumber) is on \(r.record.phoneName). Open Poki to try it."
        } catch {
            failed = error.localizedDescription
        }
    }

    private func download(_ b: TestBuild) async {
        failed = nil
        do { try await model.downloadTestBuild(b) } catch { failed = error.localizedDescription }
    }

    private func installFile(_ url: URL) async {
        failed = nil
        guard let target = model.selectedPhone, target.facts != nil else {
            failed = "Connect the device to install on, and choose it above."
            return
        }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let r = try await model.install(udid: target.id, ipa: url, handOff: false)
            model.banner = "\(url.lastPathComponent) is on \(r.record.phoneName)."
        } catch {
            failed = error.localizedDescription
        }
    }
}

/// The device test builds go on, and what it has now.
private struct TestBuildTarget: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Section("Install On") {
            if model.phones.isEmpty {
                Label("Connect an iPhone or iPad with a cable to install a build.", systemImage: "cable.connector")
                    .foregroundStyle(.secondary)
            } else {
                Picker("Device", selection: Binding(get: { model.selectedPhone?.id ?? "" }, set: { model.selectedUDID = $0 })) {
                    ForEach(model.phones) { Text($0.title).tag($0.id) }
                }
                if let row = model.selectedPhone {
                    LabeledContent("Has Now") { Text(current(row)).foregroundStyle(.secondary) }
                }
            }
            if model.account?.signedIn != true {
                LabeledContent("Sign in with the Apple Account that signs Poki") {
                    Button("Sign In…") { model.page = .account }
                }
            }
        }
    }

    private func current(_ row: PhoneRow) -> String {
        guard let r = row.record ?? model.records.first(where: { $0.udid == row.id }) else { return "No Poki from this Mac" }
        if let t = r.testBuild { return "Test build \(t.runNumber) from \(t.branch), \(String(t.sha.prefix(7)))" }
        return "Poki \(r.version) (\(r.build))"
    }
}

/// Which builds the list shows. The automatic sync follows the same filters.
private struct TestBuildFilters: View {
    @EnvironmentObject var model: AppModel
    @Binding var search: String

    var body: some View {
        Section("Filters") {
            Toggle(isOn: pref(\.onlyMine)) {
                Text("Only Builds I Started")
                if let login = model.dev.login { Text("Runs started by \(login)") }
            }
            Picker("Branch", selection: Binding(get: { model.dev.prefs.branch ?? "" }, set: { v in
                var p = model.dev.prefs
                p.branch = v.isEmpty ? nil : v
                Task { await model.setDevPrefs(p) }
            })) {
                Text("All Branches").tag("")
                ForEach(branches, id: \.self) { Text(verbatim: $0).tag($0) }
            }
            Toggle("Only Builds with a Pull Request", isOn: pref(\.withPrOnly))
            TextField("Search", text: $search, prompt: Text("Commit, branch, pull request or build number"))
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
                Text("Download New Builds")
                Text("As soon as GitHub has them, so installing takes less time")
            }
            Toggle(isOn: pref(\.autoInstall)) {
                Text("Install New Builds")
                Text("On the device below whenever it is connected")
            }
            if model.dev.prefs.autoInstall {
                Picker("Device", selection: Binding(get: { model.dev.prefs.autoInstallUdid ?? "" }, set: { v in
                    var p = model.dev.prefs
                    p.autoInstallUdid = v.isEmpty ? nil : v
                    Task { await model.setDevPrefs(p) }
                })) {
                    Text("Choose").tag("")
                    ForEach(devices) { Text(verbatim: $0.name).tag($0.id) }
                }
            }
            Toggle(isOn: pref(\.closeWithoutAsking)) {
                Text("Close Poki Without Asking")
                Text("When Poki is open on the device and an install or renewal replaces it")
            }
            Toggle(isOn: pref(\.keepOnRenew)) {
                Text("Renewals Keep the Test Build")
                Text("Otherwise renewing a device installs the release again")
            }
        } header: {
            Text("Automatic")
        } footer: {
            Text(footer).font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var footer: String {
        guard model.dev.prefs.syncing else { return "Poki Setup checks GitHub every two minutes while it is open or in the menu bar." }
        if let n = model.dev.syncedRun, let b = model.testBuilds?.builds.first(where: { $0.runId == n }) {
            return "Poki Setup checks GitHub every two minutes and takes builds newer than build \(b.runNumber) that match the filters."
        }
        return "Poki Setup checks GitHub every two minutes and takes new builds that match the filters."
    }

    struct Choice: Identifiable, Hashable {
        var id: String
        var name: String
    }

    /// Connected devices and the ones this Mac set up before.
    private var devices: [Choice] {
        var out = model.phones.map { Choice(id: $0.id, name: $0.title) }
        for r in model.records where !out.contains(where: { $0.id == r.udid }) { out.append(Choice(id: r.udid, name: r.phoneName)) }
        if let id = model.dev.prefs.autoInstallUdid, !out.contains(where: { $0.id == id }) { out.append(Choice(id: id, name: "Device not connected")) }
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
                    if onDevice { Badge(text: "On Device", color: .green) }
                    if build.isBuilding { Badge(text: "Building", color: .orange) }
                    if build.state == "expired" { Badge(text: "Expired", color: .secondary) }
                    if build.downloaded, !onDevice { Badge(text: "Downloaded", color: Color.pokiBlue) }
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
            if build.runAttempt > 1 { Text("try \(build.runAttempt)").font(.caption2).foregroundStyle(.secondary) }
        }
        .frame(minWidth: 44)
        .padding(.vertical, 4)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .help("Run \(build.runNumber) of \(build.workflow)")
    }

    private var facts: some View {
        HStack(spacing: 10) {
            Label { Text(verbatim: build.branch).lineLimit(1) } icon: { Image(systemName: "arrow.triangle.branch") }
            Label { Text(verbatim: build.shortSha).monospaced() } icon: { Image(systemName: "number") }
            if let a = build.actor { Label { Text(verbatim: a) } icon: { Image(systemName: "person") } }
            if let d = build.created { Label { Text(d, format: .relative(presentation: .named)) } icon: { Image(systemName: "clock") } }
            if build.size > 0 { Text(ByteCountFormatter.string(fromByteCount: build.size, countStyle: .file)) }
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
                Button(onDevice ? "Reinstall" : "Install") { Task { await install() } }
                    .disabled(model.busyJobs.contains("install") || model.selectedPhone?.facts == nil || model.account?.signedIn != true)
            }
        } else if build.isBuilding {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                if let u = URL(string: build.runUrl) { Link("View Run", destination: u).font(.callout) }
            }
        } else if let u = URL(string: build.runUrl) {
            Link("View Run", destination: u).font(.callout)
        }
    }

    @ViewBuilder private var menuItems: some View {
        if build.isReady, !build.downloaded {
            Button("Download Only") { Task { await download() } }
                .disabled(model.busyJobs.contains("download"))
        }
        if let u = URL(string: build.runUrl) {
            Button("Open Run on GitHub") { NSWorkspace.shared.open(u) }
        }
        if let pr = build.pr, let u = URL(string: pr.url) {
            Button("Open Pull Request \(pr.number)") { NSWorkspace.shared.open(u) }
        }
        if let u = URL(string: "https://github.com/\(model.dev.repo)/commit/\(build.sha)") {
            Button("Open Commit") { NSWorkspace.shared.open(u) }
        }
        Divider()
        Button("Copy Commit") { copyToPasteboard(build.sha) }
        Button("Copy Branch") { copyToPasteboard(build.branch) }
        Button("Copy Build Details") { copyToPasteboard(details) }
    }

    /// For a bug report or a message to whoever made the build.
    private var details: String {
        var lines = ["Build \(build.runNumber) (\(build.workflow))", "Branch \(build.branch)", "Commit \(build.sha)", build.runUrl]
        if let pr = build.pr { lines.insert("Pull request \(pr.number) \(pr.title)", at: 3) }
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
