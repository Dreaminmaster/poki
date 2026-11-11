import PokiCore
import SwiftUI

// Poki's profile (ESP-326 board "09 Poki") opens from the bear, like a contact's page in Messages. It
// replaced ESP-174's details screen and its "More Settings" layer: every setting now sits under the
// part of Poki it is about (Brain, Hands, Voice, Memory, Rules, Guests, Health), one tap from here.

/// Poki's profile: the bear on its card with what it is doing; Pause, Voice and Activity; any problem
/// that keeps it from working; then the parts of Poki, each a system list row into its own page.
struct PokiDetailsView: View {
    @Environment(AppModel.self) private var model
    @Environment(ChatModel.self) private var chat
    @Environment(\.dismiss) private var dismiss
    var openVoice: () -> Void
    var openSetup: () -> Void
    /// Opens a run in the chat (from the Activity Log).
    var openSession: (String) -> Void = { _ in }
    @Binding var path: NavigationPath
    /// Bumped when the chosen model changes, so Brain's value redraws (ModelKeys is not observable).
    @State private var modelVersion = 0

    private var isSample: Bool { UserDefaults.standard.bool(forKey: "pokiDetailsSample") }

    var body: some View {
        let status = isSample ? PokiStatus(.ready) : PokiStatus.current(model: model, chat: chat)
        NavigationStack(path: $path) {
            List {
                Section {
                    PokiHero(status: status)
                        .listRowInsets(EdgeInsets())
                    tiles
                        .listRowInsets(EdgeInsets(top: 12, leading: 0, bottom: 0, trailing: 0))
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                if !isSample {
                    let issues = Issue.current(model)
                    if !issues.isEmpty {
                        Section {
                            ForEach(issues) { issue in
                                DetailsIssueRow(issue: issue, openSetup: { path.append(DetailsRoute.setup) })
                            }
                        }
                        .accessibilityIdentifier("details.issues")
                    }
                }

                Section {
                    NavigationLink(value: DetailsRoute.model) {
                        ProfileRow(title: "Brain", caption: "Models and accounts", symbol: "brain.head.profile", value: brainValue, warns: !hasModel)
                            .id(modelVersion)
                    }
                    .accessibilityIdentifier("details.accountsAndModels")
                    NavigationLink(value: DetailsRoute.hands) {
                        ProfileRow(title: "Hands", caption: "Phone control, pairing, typing", symbol: "hand.tap.fill", value: handsValue, warns: !setupDone)
                    }
                    .accessibilityIdentifier("details.hands")
                    NavigationLink(value: DetailsRoute.voice) {
                        ProfileRow(title: "Voice", caption: "Live voice and dictation", symbol: "waveform", value: voiceValue)
                    }
                    .accessibilityIdentifier("details.voice")
                    NavigationLink(value: SettingsRoute.memory) {
                        ProfileRow(title: "Memory", caption: "Routines and notes Poki keeps", symbol: "bookmark.fill", value: "\(isSample ? 10 : RoutineStore.shared.routines.count)")
                    }
                    .accessibilityIdentifier("moreSettings.memory")
                }

                Section {
                    NavigationLink(value: DetailsRoute.approvals) {
                        ProfileRow(title: "Rules", caption: "What Poki asks about first", symbol: "checkmark.shield.fill", value: model.approvalMode.title, tile: Tint.amber)
                    }
                    .accessibilityIdentifier("moreSettings.approvals")
                    NavigationLink(value: DetailsRoute.settings) {
                        ProfileRow(title: "Guests", caption: "Agents that use Poki’s hands", symbol: "person.2.fill", value: isSample ? nil : Health.relay(model).word,
                                   tile: Color(light: 0x11191C, dark: 0x2F3336))
                    }
                    .accessibilityIdentifier("moreSettings.agentsAndRelay")
                    NavigationLink(value: DetailsRoute.health) {
                        ProfileRow(title: "Health", caption: "Updates, notifications, diagnostics", symbol: "heart.text.square.fill", value: healthValue, warns: updateWaits, tile: Tint.green)
                    }
                    .accessibilityIdentifier("details.health")
                }
            }
            .listStyle(.insetGrouped)
            // The design sets its groups 16 points apart, the tiles from the first group too.
            .listSectionSpacing(16)
            .contentMargins(.top, 4, for: .scrollContent)
            .navigationTitle("Poki")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // The card says "Poki": the bar keeps the title for the pages' back buttons only.
                ToolbarItem(placement: .principal) { Color.clear.frame(width: 1, height: 1).accessibilityHidden(true) }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                        .accessibilityIdentifier("details.done")
                }
            }
            .navigationDestination(for: DetailsRoute.self) { route in
                switch route {
                case .model:
                    ModelSettingsView()
                case .history:
                    ActionLogView(openSession: { id in dismiss(); openSession(id) })
                case .voice:
                    VoiceView(embedded: true)
                case .hands:
                    HandsView()
                case .health:
                    HealthView()
                case .settings:
                    AgentsAndRelayView(path: $path)
                case .setup:
                    SetupLayer2View(path: $path)
                case .updates:
                    Form { SigningSection() }
                        .navigationTitle("Updates")
                        .navigationBarTitleDisplayMode(.inline)
                case .approvals:
                    ApprovalsSettingsView()
                }
            }
            .navigationDestination(for: SetupStep.self) { SetupStepPage(step: $0) }
            .navigationDestination(for: SettingsRoute.self) { route in
                SettingsDestination(route: route, push: { path.append($0) }, pop: { if !path.isEmpty { path.removeLast() } })
            }
            .onReceive(NotificationCenter.default.publisher(for: ModelKeys.changed)) { _ in modelVersion += 1 }
        }
    }

    /// Pause (or Resume, or Turn On), Voice and Activity: what you reach for most.
    private var tiles: some View {
        HStack(spacing: 10) {
            switch isSample ? PowerTile.pause : PowerTile(model: model, running: chat.running) {
            case .pause:
                ProfileTile(title: "Pause", caption: "Hands are on", symbol: "pause.fill") { chat.stop(); model.pauseRunner() }
                    .accessibilityIdentifier("details.pause")
            case .resume:
                ProfileTile(title: "Resume", caption: model.ownerPaused ? "Resting" : "Standing by", symbol: "play.fill") { model.wakeRunner() }
                    .accessibilityIdentifier("details.resume")
            case .turnOn:
                ProfileTile(title: "Turn On", caption: "Poki is off", symbol: "power") { model.startSession() }
                    .accessibilityIdentifier("details.turnOn")
            }
            ProfileTile(title: "Voice", caption: "Talk to Poki", symbol: "waveform") { dismiss(); openVoice() }
            ProfileTile(title: "Activity", caption: "What Poki did", symbol: "list.bullet.rectangle") { path.append(DetailsRoute.history) }
                .accessibilityIdentifier("details.activity")
        }
    }

    private var hasModel: Bool { isSample || ModelKeys.hasUsableKey }
    private var brainValue: String {
        if isSample { return "GPT-6.1 Terra" }
        return hasModel ? ModelKeys.selectedModelName : String(localized: "Add")
    }

    private var setupDone: Bool { isSample || model.setupComplete }
    private var handsValue: String {
        if isSample { return String(localized: "On") }
        if !model.setupComplete {
            let steps = SetupStep.shown
            return String(localized: "\(steps.filter(model.isDone).count) of \(steps.count)")
        }
        if !model.sessionOn { return String(localized: "Off") }
        return model.ownerPaused ? String(localized: "Resting") : String(localized: "On")
    }

    private var voiceValue: String {
        isSample || VoiceDirect.apiKey != nil || VoiceBridge.saved != nil ? String(localized: "Live Voice") : String(localized: "Dictation Only")
    }

    private var updateWaits: Bool { !isSample && (model.signer.updateNotReady || model.signer.next?.kind == "update") }
    private var healthValue: String? {
        if isSample { return nil }
        return updateWaits ? String(localized: "Update Available") : "\(model.signer.installedVersion) (\(model.signer.installedBuild))"
    }
}

enum DetailsRoute: Hashable {
    case model, history, voice, hands, health, settings, setup, updates, approvals
}

// MARK: The card, the tiles and the rows

/// Poki on its card: the status, the name, what it is for, and the bear large. The card is the bear
/// image's own blue (the night blue asleep), so the picture has no edge. In dark a hairline keeps the
/// card's edge; nothing glows.
private struct PokiHero: View {
    var status: PokiStatus

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)
        VStack(spacing: 4) {
            HStack {
                Spacer()
                HStack(spacing: 5) {
                    // Poki's own blue would not show on the blue card: the dot is white there.
                    Circle().fill(status.mood.dot == Tint.blue ? Color.white : status.mood.dot).frame(width: 6, height: 6)
                    Text(verbatim: status.word).font(.footnote.weight(.semibold)).lineLimit(1)
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(.white.opacity(0.2), in: .capsule)
                .accessibilityElement(children: .combine)
            }
            Text(verbatim: "Poki").font(Prominent.font(.largeTitle, .semibold))
                .accessibilityAddTraits(.isHeader)
            Text("Taps and types on this iPhone for you").font(.subheadline).opacity(0.9)
                .multilineTextAlignment(.center)
            PokiBear(mood: status.mood)
                .frame(maxWidth: 210)
                // The picture's edges melt into the card, so no square shows around the bear.
                .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.14), .init(color: .black, location: 1)],
                                     startPoint: .top, endPoint: .bottom))
                .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.1),
                                             .init(color: .black, location: 0.9), .init(color: .clear, location: 1)],
                                     startPoint: .leading, endPoint: .trailing))
                .padding(.top, 2)
        }
        .foregroundStyle(.white)
        .padding(.top, 14).padding(.horizontal, 14)
        .frame(maxWidth: .infinity)
        .background(status.mood.ground)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Tint.ring, lineWidth: 1))
        .animation(.easeInOut(duration: 0.3), value: status.mood.ground)
    }
}

/// One of the three quick actions under the card.
private struct ProfileTile: View {
    var title: LocalizedStringKey
    var caption: LocalizedStringKey
    var symbol: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                // The board's tile: the symbol in a 36-point circle.
                Image(systemName: symbol).font(.subheadline.weight(.semibold)).foregroundStyle(Color(.label))
                    .frame(width: 36, height: 36)
                    .background(Color(.tertiarySystemFill), in: .circle)
                    .padding(.bottom, 8)
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Color(.label)).lineLimit(1).minimumScaleFactor(0.8)
                Text(caption).font(.caption).foregroundStyle(Color(.secondaryLabel)).lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 20, style: .continuous))
            .contentShape(.rect(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(PressedDimStyle())
    }
}

/// A plain button that dims while pressed, for tiles that draw their own surface.
struct PressedDimStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// A part of Poki as a list row: its icon on a tile of the design's colour (Poki's blue for what
/// Poki is made of; amber, ink and green for its rules, its guests and its health), its name with
/// where it stands beside it, and under them what is in there.
private struct ProfileRow: View {
    var title: LocalizedStringKey
    var caption: LocalizedStringKey
    var symbol: String
    var value: String? = nil
    /// The value needs you (no model, setup not finished, an update waiting): amber.
    var warns = false
    var tile: Color = Tint.blue
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(tile, in: .rect(cornerRadius: 9, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                // The value shares the name's line, so the caption keeps the row's width. At the
                // accessibility sizes it goes under the caption, as in Settings.
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title).font(.body.weight(.medium)).foregroundStyle(Color(.label))
                    Spacer(minLength: 0)
                    if !typeSize.isAccessibilitySize, let value { valueText(value).lineLimit(1) }
                }
                Text(caption).font(.footnote).foregroundStyle(Color(.secondaryLabel))
                if typeSize.isAccessibilitySize, let value { valueText(value) }
            }
        }
        .padding(.vertical, 2)
    }

    private func valueText(_ value: String) -> some View {
        Text(verbatim: value).font(.body).foregroundStyle(warns ? Tint.amberInk : Color(.secondaryLabel))
    }
}

// MARK: Hands

/// Hands: whether Poki may act on this iPhone, what the phone needs for it (Setup), how the runner
/// and typing behave, and turning Poki off altogether.
struct HandsView: View {
    @Environment(AppModel.self) private var model
    @Environment(ChatModel.self) private var chat

    private var on: Bool { model.sessionOn && !model.ownerPaused }

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Toggle(isOn: Binding(get: { on }, set: set)) {
                    Label("Hands", systemImage: "hand.tap")
                }
                .accessibilityIdentifier("hands.on")
            } footer: {
                // Resting is not a lock: an agent's request, or a task you send, starts Poki again.
                Text(on ? "Poki can tap, type, and scroll on this iPhone."
                     : model.sessionOn ? "Poki is resting. It starts again when you send a task or an agent asks."
                     : "Poki is off. Agents can’t reach this iPhone.")
            }

            Section {
                NavigationLink(value: DetailsRoute.setup) {
                    let done = SetupStep.shown.filter(model.isDone).count
                    let total = SetupStep.shown.count
                    LabeledContent {
                        Text(model.setupComplete || done == total ? String(localized: "Done") : String(localized: "\(done) of \(total)"))
                            .foregroundStyle(model.setupComplete || done == total ? Color(.secondaryLabel) : Tint.amberInk)
                    } label: {
                        Label("Setup", systemImage: "checklist")
                    }
                }
                .accessibilityIdentifier("moreSettings.setup")
            } header: {
                Text("This iPhone")
            }

            if model.automationPath == .inProcess {
                Section {
                    Toggle("Hide Banner When Idle", isOn: $model.closeSessionWhenIdle)
                } header: {
                    Text("Automation")
                } footer: {
                    Text("Ends the automation session, and iOS’s banner with it, when the agent stops. Being tested. If the agent can’t see the screen after this, turn it off and open Poki again.")
                }
            }
            // Main's Runner section. The in-process path has no Poki Runner to start or stop (ESP-152).
            if model.automationPath == .runner {
                Section {
                    LabeledContent("Runner", value: Health.runner(model).word)
                    Picker("Stop When Idle For", selection: $model.idleStopSeconds) {
                        ForEach(SettingsHome.idleChoices, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    if model.runnerPaused {
                        Button("Start Now") { model.wakeRunner() }
                    } else {
                        Button("Stop Runner", role: .destructive) { model.pauseRunner() }.disabled(!model.approvals.isEmpty)
                    }
                } header: {
                    Text("Runner")
                } footer: {
                    Text("iOS shows the automation banner only while the runner is active. Poki starts it when needed and stops it when idle. Don’t close Poki Runner while an agent is working.")
                }
            }
            // Main #143's Setup › Advanced › Typing: the Poki keyboard by default, Paste only when chosen.

            // The off side of main's Poki switch: resting only stands by, this ends the session and the relay.
            if model.sessionOn {
                Section {
                    Button("Turn Off Poki", role: .destructive) { chat.stop(); model.stopSession() }
                        .accessibilityIdentifier("details.turnOff")
                } footer: {
                    Text("Ends the session and disconnects agents until you turn Poki on again.")
                }
            }
        }
        .navigationTitle("Hands")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func set(_ on: Bool) {
        if !on {
            chat.stop()
            model.pauseByOwner()
        } else if model.sessionOn {
            model.wakeRunner()
        } else {
            model.startSession()
        }
    }
}

// MARK: Health

/// Health: what keeps Poki from working, this build and its updates, notifications, and the tools
/// under the hood (diagnostics, the log, testing options).
struct HealthView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            Section {
                // Main's "Updates" (the version, a new build, signing until and Signing Options), by its own name.
                NavigationLink(value: DetailsRoute.updates) {
                    LabeledContent {
                        if model.signer.updateNotReady || model.signer.next?.kind == "update" {
                            Text("Update Available").foregroundStyle(Tint.amberInk)
                        } else {
                            Text(verbatim: "\(model.signer.installedVersion) (\(model.signer.installedBuild))")
                        }
                    } label: {
                        Label("Updates", systemImage: "arrow.down.circle")
                    }
                }
                .accessibilityIdentifier("moreSettings.updates")

                Button {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    LabeledContent {
                        Image(systemName: "arrow.up.forward").font(.footnote.weight(.semibold)).foregroundStyle(Color(.tertiaryLabel))
                    } label: {
                        Label("Notifications", systemImage: "bell.badge")
                    }
                }
                .foregroundStyle(Color(.label))
                .accessibilityIdentifier("moreSettings.notifications")
            } header: {
                Text("This iPhone")
            }

            Section {
                NavigationLink(value: SettingsRoute.diagnostics) {
                    Label("Diagnostics", systemImage: "stethoscope")
                }
                .accessibilityIdentifier("moreSettings.diagnostics")

                NavigationLink(value: SettingsRoute.log) {
                    Label("Log", systemImage: "doc.text")
                }
                .accessibilityIdentifier("moreSettings.log")

                NavigationLink { TestingOptionsView() } label: {
                    Label("Testing Options", systemImage: "testtube.2")
                }
                .accessibilityIdentifier("moreSettings.testingOptions")
            } header: {
                Text("Debugging")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Health")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Rules: when Poki asks you before a sensitive step (main's Agents › Safety › Approvals, the same
/// sections), and what the phone does when a task ends (main #150's Setup › Advanced › Chat).
struct ApprovalsSettingsView: View {

    var body: some View {
        Form {
            // Main's Approvals page, as it is there: how Poki asks, and the sensitivity slider.
            ApprovalsSections()


        }
        .navigationTitle("Rules")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Guests: the outside agents that use Poki's hands (list, add, revoke, each one's QR code and address)
/// and the MCP relay they come through (its switch and address). The runner's settings are in Hands.
struct AgentsAndRelayView: View {
    @Environment(AppModel.self) private var model
    @Binding var path: NavigationPath

    private var relayLine: String {
        if model.relayAddress == nil { return String(localized: "Set an address first") }
        if !model.relayEnabled { return String(localized: "Off, agents can’t reach this iPhone") }
        if !model.sessionOn { return String(localized: "Waiting for Poki, turn Poki on and agents can connect") }
        return Health.relay(model).word
    }

    var body: some View {
        @Bindable var model = model
        List {
            Section {
                ForEach(model.identity.secrets) { secret in
                    let last = SessionStore.shared.sessions(for: secret, among: model.identity.secrets).first
                    NavigationLink(value: SettingsRoute.connector(secret)) {
                        LabeledContent {
                            Text(last.map { ChatTime.row($0.updated) } ?? String(localized: "Not Used Yet"))
                        } label: {
                            Label {
                                Text(verbatim: secret.name)
                            } icon: {
                                if let client = secret.agent ?? last?.client {
                                    AgentBadge(name: client, size: 28)
                                } else {
                                    Image(systemName: "point.3.connected.trianglepath.dotted")
                                }
                            }
                        }
                    }
                    .swipeActions { Button("Revoke", role: .destructive) { model.revoke(secret) } }
                }
                Button(action: add) {
                    Label {
                        Text("Add Agent")
                    } icon: {
                        Image(systemName: "plus.circle.fill").foregroundStyle(.blue)
                    }
                }
                .disabled(model.relayAddress == nil)
            } header: {
                Text("External Agents")
            } footer: {
                Text(model.relayAddress == nil
                     ? "Set your relay first. Each agent gets its own MCP address on it."
                     : "Each agent gets its own MCP address. Add it as a remote MCP server in Claude, Codex or any MCP client. It takes the agent’s name and icon when the agent first connects, unless you renamed it. Swipe to revoke.")
            }

            Section {
                Toggle(isOn: Binding(get: { model.relayEnabled && model.relayAddress != nil }, set: { model.setRelayEnabled($0) })) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("MCP Relay")
                            Text(relayLine)
                                .font(.footnote).foregroundStyle(Color(.secondaryLabel))
                        }
                    } icon: {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                    }
                }
                .disabled(model.relayAddress == nil || !model.sessionOn)

                NavigationLink(value: SettingsRoute.relay) {
                    LabeledContent {
                        Text(model.relayAddress.map { $0.origin.host() ?? $0.origin.absoluteString } ?? String(localized: "Not Set"))
                            .foregroundStyle(model.relayAddress == nil ? Color.orange : Color.secondary)
                    } label: {
                        Label("Address", systemImage: "network")
                    }
                }
            } header: {
                Text("MCP Relay")
            } footer: {
                Text("The relay forwards agents’ requests to this iPhone while Poki is open or in the background. It stores nothing.")
            }

        }
        .listStyle(.insetGrouped)
        .navigationTitle("Guests")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func add() {
        guard model.relayAddress != nil else { return }
        let secret = model.addConnector(name: "")
        path.append(SettingsRoute.connector(secret))
    }
}

// MARK: Layer 2 - Setup (ESP-174 board "S1 Setup layer 2")

/// Setup, under Hands (ESP-174 board "S1 Setup layer 2"): 5 items that tick themselves, Signing (optional,
/// Apple Account not needed), and Continue Setup. Each row navigates to its existing step page.
struct SetupLayer2View: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Binding var path: NavigationPath
    @State private var guiding = false

    private var isSample: Bool { UserDefaults.standard.bool(forKey: "pokiSetupSample") }
    private var steps: [SetupStep] { SetupStep.shown }

    private func isStepDone(_ step: SetupStep) -> Bool {
        if isSample { return step != .automation }
        return model.isDone(step)
    }

    private var doneCount: Int {
        steps.filter(isStepDone).count
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("\(doneCount) of \(steps.count) done. Each item ticks itself when the iPhone can check it.")
                    .font(.subheadline)
                    .foregroundStyle(Color(.secondaryLabel))
                    .padding(.horizontal, 32)
                    .padding(.top, 8)

                VStack(spacing: 0) {
                    ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                        NavigationLink(value: step) {
                            HStack(spacing: 12) {
                                Image(systemName: step.symbol)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .frame(width: 29, height: 29)
                                    .background(tileColor(for: step), in: .rect(cornerRadius: 7, style: .continuous))

                                Text(step.rowTitle)
                                    .font(.system(size: 17))
                                    .foregroundStyle(Color(.label))
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                if isStepDone(step) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 22))
                                        .foregroundStyle(ChatColor.green)
                                } else {
                                    Text("Turn On ›")
                                        .font(.system(size: 17))
                                        .foregroundStyle(Site.blue)
                                }
                            }
                            .padding(.vertical, 12)
                            .padding(.horizontal, 16)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .rowDivider(index < steps.count - 1, leading: 57)
                    }
                }
                .groupCard()
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 20)

                VStack(alignment: .leading, spacing: 6) {
                    Text("SIGNING · OPTIONAL")
                        .font(.system(size: 13))
                        .foregroundStyle(Color(hex: 0x6D6D72))
                        .padding(.horizontal, 16)

                    VStack(spacing: 0) {
                        HStack {
                            Text("Signed Until")
                                .font(.system(size: 17))
                                .foregroundStyle(Color(.label))
                            Spacer()
                            Text(signedUntilText)
                                .font(.system(size: 17))
                                .foregroundStyle(ChatColor.secondary)
                        }
                        .padding(.vertical, 11)
                        .padding(.horizontal, 16)
                        .rowDivider()

                        // The Apple Account lives in Signing Options, under Updates.
                        NavigationLink { SigningOptionsPage() } label: {
                            HStack {
                                Text("Apple Account")
                                    .font(.system(size: 17))
                                    .foregroundStyle(Color(.label))
                                Spacer()
                                Text(appleAccountText)
                                    .font(.system(size: 17))
                                    .foregroundStyle(ChatColor.secondary)
                            }
                            .padding(.vertical, 11)
                            .padding(.horizontal, 16)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                    .groupCard()

                    Text("Your Mac renews Poki’s signature. Sign in here only if you want this iPhone to renew it on its own.")
                        .font(.system(size: 13))
                        .foregroundStyle(Color(hex: 0x6D6D72))
                        .padding(.horizontal, 16)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 20)

                Button {
                    guiding = true
                } label: {
                    Text("Continue Setup")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(Site.blue, in: .rect(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("Setup")
        .navigationBarTitleDisplayMode(.large)
        .onAppear { model.loopback.resume() }
        .sheet(isPresented: $guiding) {
            SetupGuide(start: SetupStep.shown.first { !model.isDone($0) })
        }
    }

    private func tileColor(for step: SetupStep) -> Color {
        switch step {
        case .developerMode: Color(hex: 0x8E8E93)
        case .loopback: Site.blue
        case .pairing: ChatColor.green
        case .automation: Color(hex: 0x5856D6)
        case .background: Color(hex: 0xFF9500)
        case .runner: Site.blue
        }
    }

    private var signedUntilText: String {
        if isSample { return "Nov 16" }
        if let expiry = model.signer.expiry {
            return expiry.formatted(.dateTime.month(.abbreviated).day())
        }
        return String(localized: "7 days")
    }

    private var appleAccountText: String {
        if isSample { return String(localized: "Not Needed") + " ›" }
        if let appleID = model.signer.status?.apple_id, !appleID.isEmpty {
            return appleID + " ›"
        }
        return String(localized: "Not Needed") + " ›"
    }
}

extension SetupStep {
    /// Short row title on the Setup Layer 2 page (ESP-174 board "S1 Setup layer 2").
    var rowTitle: LocalizedStringKey {
        switch self {
        case .developerMode: "Developer Mode"
        case .loopback: "Local Connection"
        case .pairing: "Pair This iPhone"
        case .automation: "UI Automation"
        case .background: "Stay On in Background"
        case .runner: "Poki Runner"
        }
    }
}

// MARK: Rows

/// A white group with 12 pt corners on the grouped grey (the boards' rows).
struct GroupCard: ViewModifier {
    func body(content: Content) -> some View {
        content.frame(maxWidth: .infinity).background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12, style: .continuous))
    }
}

extension View {
    func groupCard() -> some View { modifier(GroupCard()) }
    /// The 0.5 pt separator under a row, from the leading edge of the text.
    func rowDivider(_ show: Bool = true, leading: CGFloat = 16) -> some View {
        overlay(alignment: .bottom) {
            if show { ChatColor.separator.frame(height: 0.5).padding(.leading, leading) }
        }
    }
}

struct GroupedSection<Content: View>: View {
    var title: LocalizedStringKey
    var footer: LocalizedStringKey?
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 13)).foregroundStyle(Color(.secondaryLabel)).padding(.horizontal, 16)
            VStack(spacing: 0) { content }.groupCard()
            if let footer {
                Text(footer).font(.system(size: 13)).foregroundStyle(Color(.secondaryLabel)).padding(.horizontal, 16)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct Chevron: View {
    var body: some View { Text(verbatim: "›").font(.system(size: 17, weight: .semibold)).foregroundStyle(Color(.tertiaryLabel)) }
}

private struct DetailsIssueRow: View {
    @Environment(AppModel.self) private var model
    var issue: Issue
    var openSetup: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(issue.title, systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .symbolRenderingMode(.multicolor)
            Text(issue.text)
                .font(.subheadline)
                .foregroundStyle(Color(.secondaryLabel))
            if let button = issue.button {
                Button(button) { issue.act(model, openSetup: openSetup) }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Site.blue)
                    .buttonStyle(.borderless)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The first tile on Poki's details: main's Pause and Resume pair, and Turn On while Poki is off.
/// Standing by (right after Turn On, or after the idle minute) is Resume, as on main.
enum PowerTile: Equatable {
    case pause, resume, turnOn

    @MainActor init(model: AppModel, running: Bool) {
        if model.sessionOn && !model.runnerPaused || running { self = .pause }
        else if model.sessionOn { self = .resume }
        else { self = .turnOn }
    }
}

/// The provider's letter on its coloured tile.
struct ProviderTile: View {
    var provider: ModelProvider
    var size: CGFloat = 29
    var body: some View {
        Group {
            if let logo = provider.logo {
                Image(logo).renderingMode(.template).resizable().scaledToFit().padding(size * 0.2)
            } else {
                Image(systemName: "server.rack").font(.system(size: size * 0.45, weight: .semibold))
            }
        }
        .foregroundStyle(.white)
        .frame(width: size, height: size)
        .background(Color(hex: provider.tile), in: .rect(cornerRadius: size * 0.225, style: .continuous))
        .accessibilityHidden(true)
    }
}

extension ModelProvider {
    /// The provider's own logo in the asset catalog (Poki/ProviderIcons).
    var logo: String? {
        switch self {
        case .anthropic: "Provider-anthropic"
        case .openai, .chatgpt: "Provider-openai"
        case .gemini: "Provider-googlegemini"
        case .deepseek: "Provider-deepseek"
        case .openrouter: "Provider-openrouter"
        case .custom: nil
        }
    }
}
