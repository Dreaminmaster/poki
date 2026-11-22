import SwiftUI

/// Localized release-note text held inside the single What's New catalog so every release edits one file.
struct WhatsNewText: Equatable {
    let en: String
    let zhHans: String
    let zhHant: String

    func resolved(for language: String = AppLocalization.language) -> String {
        if language.hasPrefix("zh-Hant") || language.hasPrefix("zh-HK") || language.hasPrefix("zh-TW") {
            return zhHant
        }
        if language.hasPrefix("zh") {
            return zhHans
        }
        return en
    }
}

/// One highlighted change shown in the What's New card.
struct WhatsNewItem: Equatable, Identifiable {
    let id: String
    let symbol: String
    let title: WhatsNewText
    let summary: WhatsNewText
}

/// The release notes for one Poki version, shared between the post-update popup and Settings > About.
struct WhatsNewRelease: Equatable, Identifiable {
    var id: String { version }
    let version: String
    let items: [WhatsNewItem]
}

/// Single source of truth for What's New content. Update `current` on each release.
enum WhatsNewCatalog {
    static let current = WhatsNewRelease(
        version: "0.5.0",
        items: [
            WhatsNewItem(
                id: "chatgpt-sign-in",
                symbol: "person.crop.circle",
                title: WhatsNewText(
                    en: "Sign In with ChatGPT",
                    zhHans: "支持 ChatGPT 账号登录",
                    zhHant: "支援 ChatGPT 帳號登入"
                ),
                summary: WhatsNewText(
                    en: "No API keys needed, use Plus, Pro, or Codex for text and voice.",
                    zhHans: "免填 API 密钥，登录 Plus、Pro 或 Codex 账号即可使用文字和语音。",
                    zhHant: "免填 API 金鑰，登入 Plus、Pro 或 Codex 帳號即可使用文字與語音。"
                )
            ),
            WhatsNewItem(
                id: "faster-screens",
                symbol: "bolt",
                title: WhatsNewText(
                    en: "Direct Actions, Faster Screens",
                    zhHans: "执行少绕路，画面更快",
                    zhHant: "執行少繞路，畫面更快"
                ),
                summary: WhatsNewText(
                    en: "Apps open accurately without extra checks, and new screens appear faster after swiping.",
                    zhHans: "打开 App 更准、干完即停，滑动或打开后更快看到新画面。",
                    zhHant: "開啟 App 更準、做完即停，滑動或開啟後更快看到新畫面。"
                )
            ),
            WhatsNewItem(
                id: "fresh-tasks-mic",
                symbol: "mic",
                title: WhatsNewText(
                    en: "Fresh Tasks, Smooth Reset",
                    zhHans: "新任务清爽，收尾顺畅",
                    zhHant: "新任務清爽，收尾順暢"
                ),
                summary: WhatsNewText(
                    en: "New tasks start without old screenshots, and your mic recovers automatically after remote control.",
                    zhHans: "新任务不带上一轮旧截图，远程控制结束后麦克风自动恢复。",
                    zhHant: "新任務不帶上一輪舊截圖，遠端控制結束後麥克風自動恢復。"
                )
            ),
            WhatsNewItem(
                id: "cards-and-settings",
                symbol: "rectangle.grid.1x2",
                title: WhatsNewText(
                    en: "Clearer Cards and Settings",
                    zhHans: "车次清晰，设置好找",
                    zhHant: "車次清晰，設定好找"
                ),
                summary: WhatsNewText(
                    en: "12306 train cards read cleaner, with deduplicated settings and clearer menu names.",
                    zhHans: "12306 车次卡片排版更易读，设置页去重并优化了入口名称。",
                    zhHant: "12306 車次卡片排版更易讀，設定頁去重並最佳化了入口名稱。"
                )
            ),
            WhatsNewItem(
                id: "approvals-copy-launch",
                symbol: "checkmark.shield",
                title: WhatsNewText(
                    en: "Approvals, Copy, Steady Launch",
                    zhHans: "快捷操作与启动优化",
                    zhHant: "快捷操作與啟動最佳化"
                ),
                summary: WhatsNewText(
                    en: "Direct iPad Live Activity approvals, copyable browser instructions, and steadier iPhone 17 Pro startup.",
                    zhHans: "iPad 灵动岛操作确认直接生效，浏览器说明可复制，iPhone 17 Pro 启动更稳。",
                    zhHant: "iPad 動態島操作確認直接生效，瀏覽器說明可複製，iPhone 17 Pro 啟動更穩。"
                )
            ),
        ]
    )

    /// Returns the release notes only when they match the running app's actual version.
    nonisolated static func release(
        for installedVersion: String = WhatsNew.installedVersion,
        catalog: WhatsNewRelease = current
    ) -> WhatsNewRelease? {
        let normalized = installedVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized == catalog.version else { return nil }
        return catalog
    }
}

/// Coordinates deferred post-launch presentation of What's New so temporary blockers
/// postpone presentation instead of dropping it for the session.
struct WhatsNewLaunchGate: Equatable {
    private(set) var scheduled = false
    private(set) var presented = false

    struct Context: Equatable {
        var firstFrameDisplayed: Bool
        var curtainUp: Bool
        var sceneActive: Bool
        var welcoming: Bool
        var detailsOpen: Bool
        var installMessageActive: Bool
        var pairingUnderWay: Bool
        var whatsNewOpen: Bool
    }

    mutating func beginSchedulingIfReady(context: Context, isDue: () -> Bool) -> Bool {
        guard !scheduled, !presented, canPresentNow(context: context), isDue() else { return false }
        scheduled = true
        return true
    }

    mutating func commitIfStillReady(context: Context, isDue: () -> Bool) -> Bool {
        guard scheduled, !presented else { return false }
        scheduled = false
        guard canPresentNow(context: context), isDue() else { return false }
        presented = true
        return true
    }

    private func canPresentNow(context: Context) -> Bool {
        context.firstFrameDisplayed
            && !context.curtainUp
            && context.sceneActive
            && !context.welcoming
            && !context.detailsOpen
            && !context.installMessageActive
            && !context.pairingUnderWay
            && !context.whatsNewOpen
    }
}

/// Decides whether What's New should appear once after an update, and never on a fresh install.
enum WhatsNew {
    static let seenVersionKey = "pokiWhatsNewSeenVersion"

    nonisolated static var installedVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Call at launch right after `FirstRun.decide(...)`, passing the prior `FirstRun.key` value
    /// read before `FirstRun.decide(...)` ran.
    /// Only a true fresh install (no restored/existing seen version, no prior FirstRun record, and
    /// no earlier-version traces) marks the installed version as seen so fresh installs skip What's New.
    nonisolated static func decide(
        installedVersion: String = WhatsNew.installedVersion,
        priorFirstRun: String? = nil,
        defaults: UserDefaults = .standard,
        sessionsFolder: URL = SessionStore.defaultFolder
    ) {
        let normalized = installedVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        guard defaults.string(forKey: seenVersionKey) == nil else { return }
        guard priorFirstRun == nil else { return }
        let isFreshInstall: Bool
        if let firstRun = defaults.string(forKey: FirstRun.key) {
            isFreshInstall = firstRun == FirstRun.Record.due.rawValue
        } else {
            isFreshInstall = !EarlierVersion.leftTraces(defaults: defaults, sessionsFolder: sessionsFolder)
        }
        if isFreshInstall {
            defaults.set(normalized, forKey: seenVersionKey)
        }
    }

    /// Pure decision based on persisted state (used by `isDueAtLaunch` and unit tests).
    nonisolated static func shouldPresent(
        installedVersion: String = WhatsNew.installedVersion,
        catalog: WhatsNewRelease = WhatsNewCatalog.current,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard let release = WhatsNewCatalog.release(for: installedVersion, catalog: catalog) else { return false }
        if defaults.string(forKey: FirstRun.key) == FirstRun.Record.due.rawValue { return false }
        return defaults.string(forKey: seenVersionKey) != release.version
    }

    /// Launch-time gate that respects scripted `-poki…` launches and XCTest runs.
    static func isDueAtLaunch(
        installedVersion: String = WhatsNew.installedVersion,
        catalog: WhatsNewRelease = WhatsNewCatalog.current,
        defaults: UserDefaults = .standard
    ) -> Bool {
        let arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        if arguments["pokiScreen"] as? String == "whatsNew" { return true }
        if ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil { return false }
        if arguments.keys.contains(where: { $0.hasPrefix("poki") }) { return false }
        return shouldPresent(installedVersion: installedVersion, catalog: catalog, defaults: defaults)
    }

    nonisolated static func markSeen(
        version: String = WhatsNew.installedVersion,
        catalog: WhatsNewRelease = WhatsNewCatalog.current,
        defaults: UserDefaults = .standard
    ) {
        guard let release = WhatsNewCatalog.release(for: version, catalog: catalog) else { return }
        defaults.set(release.version, forKey: seenVersionKey)
        if defaults === UserDefaults.standard { SettingsVault.save() }
    }
}

/// Motion-equivalent SwiftUI spring timings for the What's New sheet.
private enum WhatsNewMotion {
    static let headerSpring = Animation.interpolatingSpring(mass: 1, stiffness: 260, damping: 22)
    static let cardSpring = Animation.interpolatingSpring(mass: 1, stiffness: 240, damping: 24).delay(0.06)
    static let buttonSpring = Animation.interpolatingSpring(mass: 1, stiffness: 240, damping: 24).delay(0.16)
    static func rowSpring(index: Int) -> Animation {
        Animation.interpolatingSpring(mass: 1, stiffness: 250, damping: 24).delay(0.10 + Double(index) * 0.04)
    }
    static let pressSpring = Animation.spring(duration: 0.22, bounce: 0.2)
}

/// Full-screen post-update highlights card featuring Poki, the release badge, and a grouped list of changes.
struct WhatsNewView: View {
    var release: WhatsNewRelease = WhatsNewCatalog.current
    var onContinue: () -> Void

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .title) private var titleSize: CGFloat = 30
    @ScaledMetric(relativeTo: .body) private var iconCircleSize: CGFloat = 38
    @State private var appeared = false

    private var dark: Bool { scheme == .dark }
    private var isChinese: Bool { AppLocalization.language.hasPrefix("zh") }

    private static let primaryInk = Color(light: 0x11191C, dark: 0xF2F4F7)
    private static let secondaryInk = Color(light: 0x5F676C, dark: 0x9BA5B4)

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    header
                        .padding(.top, 14)
                        .padding(.bottom, 24)
                        .padding(.horizontal, 24)
                        .opacity(appeared || reduceMotion ? 1 : 0)
                        .scaleEffect(appeared || reduceMotion ? 1 : 0.94)
                        .offset(y: appeared || reduceMotion ? 0 : 10)
                        .animation(reduceMotion ? nil : WhatsNewMotion.headerSpring, value: appeared)

                    card
                        .padding(.horizontal, 16)
                        .padding(.bottom, 14)
                        .opacity(appeared || reduceMotion ? 1 : 0)
                        .offset(y: appeared || reduceMotion ? 0 : 16)
                        .animation(reduceMotion ? nil : WhatsNewMotion.cardSpring, value: appeared)
                }
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)

            continueBar
                .opacity(appeared || reduceMotion ? 1 : 0)
                .offset(y: appeared || reduceMotion ? 0 : 12)
                .animation(reduceMotion ? nil : WhatsNewMotion.buttonSpring, value: appeared)
        }
        .background { backdrop }
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("whatsNew.screen")
        .onAppear {
            if reduceMotion {
                appeared = true
            } else {
                appeared = true
            }
        }
    }

    private var backdrop: some View {
        LinearGradient(
            stops: dark
                ? [
                    .init(color: Color(hex: 0x0D2C68), location: 0.0),
                    .init(color: Color(hex: 0x081736), location: 0.28),
                    .init(color: Tint.page, location: 0.56),
                    .init(color: Tint.page, location: 1.0),
                ]
                : [
                    .init(color: Color(hex: 0xDCEBFF), location: 0.0),
                    .init(color: Color(hex: 0xEDF4FE), location: 0.26),
                    .init(color: Tint.page, location: 0.54),
                    .init(color: Tint.page, location: 1.0),
                ],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }

    private var header: some View {
        VStack(spacing: 8) {
            ZStack {
                if dark {
                    RadialGradient(
                        stops: [
                            .init(color: Color(hex: 0x4C9DFF).opacity(0.34), location: 0.0),
                            .init(color: Tint.blue.opacity(0.14), location: 0.36),
                            .init(color: Tint.blue.opacity(0.0), location: 0.68),
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: 56
                    )
                    .frame(width: 112, height: 112)
                } else {
                    RadialGradient(
                        stops: [
                            .init(color: Color.white.opacity(0.92), location: 0.0),
                            .init(color: Color(hex: 0xE3EEFF).opacity(0.42), location: 0.38),
                            .init(color: Color(hex: 0xE3EEFF).opacity(0.0), location: 0.70),
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: 54
                    )
                    .frame(width: 108, height: 108)
                }

                if let image = PokiMood.cutout(.ready, small: true) {
                    Image(uiImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: 88, height: 88)
                        .mask(
                            LinearGradient(
                                stops: [
                                    .init(color: .black, location: 0.0),
                                    .init(color: .black, location: 0.78),
                                    .init(color: .clear, location: 1.0),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                }
            }
            .frame(width: 92, height: 92)
            .accessibilityHidden(true)

            VStack(spacing: 6) {
                let effectiveTitleSize = min(titleSize, 40)
                Text(verbatim: AppLocalization.text(LocalizedStringResource("What’s New")))
                    .font(.system(size: effectiveTitleSize, weight: isChinese ? .semibold : .bold))
                    .tracking(-0.02 * effectiveTitleSize)
                    .foregroundStyle(Self.primaryInk)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("whatsNew.title")

                Text(verbatim: "Poki \(release.version)")
                    .font(.footnote.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(Tint.blueText)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 12)
                    .background(
                        Capsule().fill(dark ? Color.white.opacity(0.10) : Color.white.opacity(0.76))
                    )
                    .overlay(
                        Capsule().strokeBorder(
                            dark ? Color.white.opacity(0.16) : Color.white.opacity(0.92),
                            lineWidth: 1
                        )
                    )
                    .shadow(
                        color: dark ? .clear : Color(hex: 0x183878).opacity(0.07),
                        radius: 5,
                        y: 2
                    )
                    .accessibilityIdentifier("whatsNew.version")
            }
        }
    }

    private var card: some View {
        let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
        let circle = min(48, max(36, iconCircleSize))
        let dividerLeading = 16 + circle + 13
        let language = AppLocalization.language

        return VStack(spacing: 0) {
            ForEach(Array(release.items.enumerated()), id: \.element.id) { index, item in
                if index > 0 {
                    Rectangle()
                        .fill(dark ? Color.white.opacity(0.09) : Color(hex: 0xEEF2F7))
                        .frame(height: 1)
                        .padding(.leading, dividerLeading)
                        .padding(.trailing, 16)
                }

                HStack(alignment: .top, spacing: 13) {
                    Image(systemName: item.symbol)
                        .font(.system(size: circle * 0.41, weight: .medium))
                        .foregroundStyle(Tint.blueText)
                        .frame(width: circle, height: circle)
                        .background(Tint.blueSoft, in: .circle)
                        .padding(.top, 1)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: item.title.resolved(for: language))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Self.primaryInk)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(verbatim: item.summary.resolved(for: language))
                            .font(.footnote)
                            .foregroundStyle(Self.secondaryInk)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 16)
                .padding(.horizontal, 16)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("whatsNew.item.\(item.id)")
                .opacity(appeared || reduceMotion ? 1 : 0)
                .offset(y: appeared || reduceMotion ? 0 : 8)
                .animation(reduceMotion ? nil : WhatsNewMotion.rowSpring(index: index), value: appeared)
            }
        }
        .padding(.vertical, 8)
        .background(
            shape.fill(dark ? Color(hex: 0x141B29).opacity(0.90) : Color.white.opacity(0.94))
        )
        .clipShape(shape)
        .overlay(
            shape.strokeBorder(dark ? Color.white.opacity(0.12) : Color.white, lineWidth: 1)
        )
        .shadow(
            color: dark ? Color.black.opacity(0.34) : Color(hex: 0x11191C).opacity(0.08),
            radius: dark ? 14 : 16,
            y: dark ? 8 : 5
        )
    }

    private var continueBar: some View {
        Button(action: onContinue) {
            Text(verbatim: AppLocalization.text(LocalizedStringResource("Continue")))
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 54)
                .background(
                    Capsule().fill(
                        LinearGradient(
                            colors: [Color(hex: 0x1E88FF), Tint.blue],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                )
                .overlay(
                    Capsule().strokeBorder(
                        Color.white.opacity(dark ? 0.22 : 0.32),
                        lineWidth: 1
                    )
                )
                .shadow(
                    color: dark ? .clear : Tint.blue.opacity(0.32),
                    radius: 14,
                    y: 8
                )
                .contentShape(.capsule)
        }
        .buttonStyle(WhatsNewContinueButtonStyle(reduceMotion: reduceMotion))
        .accessibilityIdentifier("whatsNew.continue")
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity)
    }
}

private struct WhatsNewContinueButtonStyle: ButtonStyle {
    var reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.92 : 1)
            .animation(reduceMotion ? nil : WhatsNewMotion.pressSpring, value: configuration.isPressed)
    }
}
