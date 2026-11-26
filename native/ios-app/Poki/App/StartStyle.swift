import SwiftUI

/// How the start flow (the hello, the setup list and every page it opens) draws itself, apart from the
/// settings pages: on the system's grouped ground, with the system's own rows and buttons (the owner,
/// Nov 21 2026: the start pages had a white plate behind the bear, home-made buttons and captions
/// wrapped inside rows). Two directions are kept side by side until the owner picks one; Debug builds
/// switch with `-startDesign tiles`.
enum StartDesign: String {
    /// Centered hello on the grouped ground; rows with a tinted symbol and no ground under it.
    case plain
    /// Hello with the title at the leading edge over the home page's light; rows with the symbol on a
    /// coloured rounded square, as the Settings app draws them.
    case tiles

    static var current: StartDesign {
        UserDefaults.standard.string(forKey: "startDesign").flatMap(StartDesign.init(rawValue:)) ?? .plain
    }
}

extension EnvironmentValues {
    /// Set over the start flow only: nil on the settings pages, which keep their own rows.
    @Entry var startDesign: StartDesign? = nil
}

/// A row's symbol in the start flow: Poki's blue (orange while it needs you), alone or on a tile.
struct StartIcon<Icon: View>: View {
    var design: StartDesign
    var warns = false
    @ViewBuilder var icon: Icon
    @ScaledMetric(relativeTo: .body) private var tile = 29
    @ScaledMetric(relativeTo: .body) private var glyph = 16

    var body: some View {
        let tint = warns ? Color(.systemOrange) : Color(.systemBlue)
        switch design {
        case .plain:
            icon
                .font(.system(size: min(glyph * 1.15, 26), weight: .medium))
                .foregroundStyle(tint)
                .frame(width: min(tile, 40))
                .accessibilityHidden(true)
        case .tiles:
            icon
                .font(.system(size: min(glyph, 22), weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: min(tile, 40), height: min(tile, 40))
                .background(tint.gradient, in: .rect(cornerRadius: min(tile, 40) * 0.24, style: .continuous))
                .accessibilityHidden(true)
        }
    }
}

/// The start flow's ground: Poki's blue (the owner, Nov 21 2026: blue for the setup guidance pages),
/// a deep night blue in Dark Mode, with the rows as cards on it. The tiles hello keeps the home light.
struct StartGround: View {
    var design: StartDesign
    var hello = false
    /// Poki blue, #2084FD, and the docs site's night blue in Dark Mode.
    static let blue = Color(light: 0x2084FD, dark: 0x0A2F6B)
    /// Words straight on the blue: white, and white at reduced opacity for the quieter lines.
    static let ink = Color.white
    static let quietInk = Color.white.opacity(0.82)

    var body: some View {
        if design == .tiles && hello {
            HomeBackdrop(home: true, working: false, frozen: true).ignoresSafeArea()
        } else {
            Self.blue.ignoresSafeArea()
        }
    }
}

extension View {
    /// A sheet opened from the start flow draws on the system's ground, so it leaves the flow's look.
    func outsideStartFlow() -> some View { environment(\.startDesign, nil) }
}

/// The start flow's main button: the system's prominent glass on iOS 26, bordered prominent before, white
/// with Poki blue words on the blue ground,
/// the width of the page's text, with a text button under it when there is a second choice.
struct StartButtons: View {
    var primary: LocalizedStringKey
    var action: () -> Void
    var secondary: LocalizedStringKey? = nil
    var secondaryAction: () -> Void = {}
    var primaryID = "firstRun.next"
    var secondaryID = "firstRun.finishLater"
    /// The page's own action is on the page (a form's Sign In), so the bar's only button is the
    /// secondary kind and never outshines it.
    var quiet = false
    @Environment(\.startPrimaryDisabled) private var primaryDisabled

    var body: some View {
        VStack(spacing: 8) {
            if quiet {
                Button(action: action) {
                    Text(primary).font(.allo(.body)).foregroundStyle(StartGround.ink).frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderless)
                .disabled(primaryDisabled)
                .accessibilityIdentifier(primaryID)
            } else {
                Button(action: action) {
                    // Poki blue on a white button: the prominent glass takes the white tint on the blue ground.
                    Text(primary).font(.allo(.body, .semibold)).foregroundStyle(StartGround.blue).frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonBorderShape(.capsule)
                .glassButton(prominent: true)
                .tint(.white)
                .disabled(primaryDisabled)
                .accessibilityIdentifier(primaryID)
            }
            if let secondary {
                Button(action: secondaryAction) {
                    Text(secondary).font(.allo(.body)).foregroundStyle(StartGround.ink).frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier(secondaryID)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity)
        // The page's own ground under the buttons, fading in above them, so no row shows through a
        // button (a disabled glass button is see-through).
        .background {
            VStack(spacing: 0) {
                LinearGradient(colors: [StartGround.blue.opacity(0), StartGround.blue],
                               startPoint: .top, endPoint: .bottom).frame(height: 24)
                StartGround.blue
            }
            .padding(.top, -24)
            .ignoresSafeArea(edges: .bottom)
        }
    }
}

/// The hello: Poki's bear with no ground under it, a large title, one line, and the button at the
/// bottom. It comes in once the launch screen has faded onto it (`LaunchCurtain`'s hand over).
struct StartHello: View {
    var design: StartDesign
    var kind: FirstRun.Kind
    var replay = false
    var shown: Bool
    var setUp: () -> Void
    var later: () -> Void
    @Environment(\.verticalSizeClass) private var verticalSize
    @ScaledMetric(relativeTo: .largeTitle) private var bearSide: CGFloat = 168

    var body: some View {
        VStack(spacing: 0) {
            switch design {
            case .plain:
                Spacer(minLength: 24)
                bear(side: min(bearSide, verticalSize == .compact ? 96 : 200))
                words(alignment: .center).padding(.top, 20)
                Spacer(minLength: 24)
            case .tiles:
                words(alignment: .leading).padding(.top, 56)
                Spacer(minLength: 16)
                bear(side: min(bearSide * 1.5, verticalSize == .compact ? 120 : 280))
                    .frame(maxWidth: .infinity)
                Spacer(minLength: 16)
            }
            StartButtons(primary: kind == .firstRun ? "Set Up Poki" : "Check Setup", action: setUp,
                         secondary: kind == .firstRun && !replay ? nil : "Not Now", secondaryAction: later,
                         primaryID: "firstRun.primary", secondaryID: "firstRun.later")
                .padding(.bottom, 8)
        }
        .padding(.horizontal, design == .tiles ? 8 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(shown ? 1 : 0)
        .offset(y: shown ? 0 : 12)
        .allowsHitTesting(shown)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }

    /// The calm, smiling bear (the Live Activity's Ready picture), cut out on a clear ground: no
    /// plate, no ring, no wave. The picture ends at the chest, so its lower edge fades into the page.
    private func bear(side: CGFloat) -> some View {
        Group {
            if let path = Bundle.main.path(forResource: "ActivityBear-ready", ofType: "png"),
               let picture = UIImage(contentsOfFile: path) {
                Image(uiImage: picture).resizable().scaledToFit()
            } else {
                BlinkingFace(mood: .ready, side: side)
            }
        }
        .frame(width: side, height: side)
        .mask {
            LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.8),
                                   .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom)
        }
        .accessibilityHidden(true)
    }

    private func words(alignment: HorizontalAlignment) -> some View {
        let text: TextAlignment = alignment == .center ? .center : .leading
        return VStack(alignment: alignment, spacing: 10) {
            Text(verbatim: headline)
                .font(.alloRounded(.largeTitle, .bold))
                .foregroundStyle(design == .plain ? StartGround.ink : Color(.label))
                .accessibilityAddTraits(.isHeader)
            Text(verbatim: line)
                .font(.allo(.body))
                .foregroundStyle(design == .plain ? StartGround.quietInk : Color(.secondaryLabel))
        }
        .multilineTextAlignment(text)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 440, alignment: Alignment(horizontal: alignment, vertical: .center))
        .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .center))
        .padding(.horizontal, 32)
    }

    private var headline: String {
        switch kind {
        case .firstRun: AppLocalization.text(LocalizedStringResource("Hello, I’m Poki"))
        case .update(let version): AppLocalization.text(LocalizedStringResource("Poki \(version) Is Here"))
        }
    }

    private var line: String {
        switch kind {
        case .firstRun: AppLocalization.text(LocalizedStringResource("I do what you ask, right on your iPhone."))
        case .update: AppLocalization.text(LocalizedStringResource("See what is set up and what is new."))
        }
    }
}

/// The top of a start flow page: the step's symbol large, its name as a large title and one line,
/// on the page's own ground, with a tick once it is done.
struct StartHero: View {
    var symbol: String
    var title: LocalizedStringKey
    var line: LocalizedStringKey
    var done = false
    @ScaledMetric(relativeTo: .largeTitle) private var glyph: CGFloat = 56

    var body: some View {
        Section {
            VStack(spacing: 12) {
                Image(systemName: done ? "checkmark.circle.fill" : symbol)
                    .font(.system(size: min(glyph, 80), weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(StartGround.ink)
                    .contentTransition(.symbolEffect(.replace))
                    .accessibilityHidden(true)
                Text(title)
                    .font(.alloRounded(.largeTitle, .bold))
                    .foregroundStyle(StartGround.ink)
                    .accessibilityAddTraits(.isHeader)
                Text(line)
                    .font(.allo(.body))
                    .foregroundStyle(StartGround.quietInk)
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
            .padding(.bottom, 8)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
        }
    }
}

/// The start flow, one pushed page at a time (the owner, Nov 21 2026: walked through step by step,
/// as the system's own setup is): each item of the setup list (`SetupItem`) on its own page, and the
/// list itself at the end.
enum StartRoute: Hashable {
    case item(SetupItem)
    case summary

    static var order: [StartRoute] { SetupItem.all.map(StartRoute.item) + [.summary] }

    var next: StartRoute? {
        let all = Self.order
        return all.firstIndex(of: self).flatMap { all.indices.contains($0 + 1) ? all[$0 + 1] : nil }
    }
}

/// A page of the start flow with its buttons: Continue once the page is done (on a step iOS cannot
/// check, Open Settings until then) and Set Up Later to go on without it.
struct StartFlowPage: View {
    @Environment(AppModel.self) private var model
    var route: StartRoute
    var kind: FirstRun.Kind
    @Binding var path: NavigationPath
    var finish: () -> Void

    var body: some View {
        switch route {
        case .item(.step(let step)):
            SetupStepPage(step: step, hero: true)
                .settingsPage()
                .bottomBar(softEdge: true) { stepButtons(step) }
        case .item(.shortcut):
            StartShortcutPage(goOn: goOn)
        case .item(.models):
            StartModelsPage(goOn: goOn)
        case .item(.features):
            Form {
                StartHero(symbol: "square.stack.3d.up", title: "Features",
                          line: "All optional. Each can be changed later in Settings.")
                WelcomeFeaturesSection(onItsPage: true, openSenses: { path.append(DetailsRoute.screenHistory) })
                Section {
                    NavigationLink(value: DetailsRoute.agents) {
                        SettingsRow(title: "External Connections", symbol: "chevron.left.forwardslash.chevron.right")
                    }
                    .accessibilityIdentifier("firstRun.agents")
                } footer: {
                    Group {
                        Text("Let Claude, ChatGPT and other agents use this iPhone")
                    }
                    .settingsFooter()
                }
            }
            .navigationTitle(Text(verbatim: ""))
            .navigationBarTitleDisplayMode(.inline)
            .settingsPage()
            .bottomBar(softEdge: true) { StartButtons(primary: "Continue", action: goOn) }
        case .item(.appleAccount):
            StartAppleAccountPage(goOn: goOn)
        case .summary:
            WelcomePanel(kind: kind, path: $path, finish: finish)
        }
    }

    @ViewBuilder private func stepButtons(_ step: SetupStep) -> some View {
        let done = model.stepReadyForUse(step)
        let checkedByHand = [SetupStep.runner, .developerMode, .automation].contains(step)
        if done {
            StartButtons(primary: "Continue", action: goOn)
        } else if step == .background {
            // One button: iOS's request first, Settings once iOS answered short of Always.
            if model.background.authorization == .notDetermined {
                StartButtons(primary: "Allow Location", action: { model.background.requestPermission() },
                             secondary: "Set Up Later", secondaryAction: goOn)
            } else {
                StartButtons(primary: "Open Settings", action: { openSettings(model, for: step) },
                             secondary: "Set Up Later", secondaryAction: goOn)
            }
        } else if checkedByHand {
            StartButtons(primary: "Open Settings", action: { openSettings(model, for: step) },
                         secondary: "Set Up Later", secondaryAction: goOn)
        } else {
            StartButtons(primary: "Continue", action: goOn, secondary: "Set Up Later", secondaryAction: goOn)
                .disabledPrimary()
        }
    }

    private func goOn() {
        if let next = route.next { path.append(next) } else { finish() }
    }
}

private struct DisabledPrimaryKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var startPrimaryDisabled: Bool {
        get { self[DisabledPrimaryKey.self] }
        set { self[DisabledPrimaryKey.self] = newValue }
    }
}
extension View {
    /// The primary button waits until the page's step is done; Set Up Later goes on without it.
    func disabledPrimary() -> some View { environment(\.startPrimaryDisabled, true) }
}

/// The start flow's page for the Poki Loopback Shortcut: what it does in one line, then the steps.
struct StartShortcutPage: View {
    var goOn: () -> Void
    @ObservedObject private var reconnect = HistoryReconnect.shared

    var body: some View {
        Form {
            StartHero(symbol: "square.2.layers.3d", title: "Poki Loopback Shortcut",
                      line: "If the loopback stops, this shortcut turns it back on by itself. Set it up once.",
                      done: reconnect.isSetUp && reconnect.lastWorked)
            LoopbackShortcutSteps()
        }
        .navigationTitle(Text(verbatim: ""))
        .navigationBarTitleDisplayMode(.inline)
        .settingsPage()
        .bottomBar(softEdge: true) {
            StartButtons(primary: "Continue", action: goOn, secondary: reconnect.isSetUp ? nil : "Set Up Later", secondaryAction: goOn)
        }
    }
}

/// The start flow's models page: Settings' Models page itself (its In Use pickers, the local model,
/// the providers and Add Provider) under the page's hero (the owner, Nov 21 2026: the same options
/// and features as the Models page).
struct StartModelsPage: View {
    var goOn: () -> Void
    @State private var hasModel = ModelKeys.hasUsableKey

    var body: some View {
        Form {
            StartHero(symbol: "sparkles", title: "Connect a Model",
                      line: "Poki needs an AI account to think. Add one provider below. One is enough.",
                      done: hasModel)
            ModelSettingsSections()
        }
        .navigationTitle(Text(verbatim: ""))
        .navigationBarTitleDisplayMode(.inline)
        .settingsPage()
        .onReceive(NotificationCenter.default.publisher(for: ModelKeys.changed)) { _ in hasModel = ModelKeys.hasUsableKey }
        .onAppear { hasModel = ModelKeys.hasUsableKey }
        .bottomBar(softEdge: true) {
            StartButtons(primary: "Continue", action: goOn, secondary: hasModel ? nil : "Set Up Later", secondaryAction: goOn)
        }
    }
}
