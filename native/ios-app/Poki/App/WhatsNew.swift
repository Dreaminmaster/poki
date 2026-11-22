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
                    zhHans: "ChatGPT 账号直接登录",
                    zhHant: "ChatGPT 帳號直接登入"
                ),
                summary: WhatsNewText(
                    en: "Skip the API key and sign in with your Plus, Pro, or Codex account to unlock text chat and live voice.",
                    zhHans: "免填 API 密钥，直接用你的 Plus、Pro 或 Codex 账号登录，即可开启文字对话与实时语音。",
                    zhHant: "免填 API 金鑰，直接用你的 Plus、Pro 或 Codex 帳號登入，即可開啟文字對話與即時語音。"
                )
            ),
            WhatsNewItem(
                id: "watch-and-ask",
                symbol: "play.rectangle",
                title: WhatsNewText(
                    en: "Ask While Watching Videos",
                    zhHans: "边看视频边问 Poki",
                    zhHant: "邊看影片邊問 Poki"
                ),
                summary: WhatsNewText(
                    en: "On iOS 27 or later, live voice hears audio and video from other apps during screen sharing, letting you watch and ask.",
                    zhHans: "在 iOS 27 及以上开启屏幕共享后，实时语音能同步听见其他 App 播放的音视频内容，随时边看边问。",
                    zhHant: "在 iOS 27 及以上開啟螢幕共享後，即時語音能同步聽見其他 App 播放的影音內容，隨時邊看邊問。"
                )
            ),
            WhatsNewItem(
                id: "smarter-live-voice",
                symbol: "waveform",
                title: WhatsNewText(
                    en: "Smarter, Smoother Live Voice",
                    zhHans: "实时语音全面升级",
                    zhHant: "即時語音全面升級"
                ),
                summary: WhatsNewText(
                    en: "Hold to talk records instantly, updating naturally without extra completion cards. Chat replies directly, actions check latest screens, and \"stop\" mutes voice, not tasks.",
                    zhHans: "按住即录不漏首句，播报更自然且不弹多余完成卡片。闲聊直接回，操作前核对最新画面，说「停」只静音不误停任务。",
                    zhHant: "按住即錄不漏首句，播報更自然且不彈多餘完成卡片。閒聊直接回，操作前核對最新畫面，說「停」只靜音不誤停任務。"
                )
            ),
            WhatsNewItem(
                id: "rich-result-cards",
                symbol: "rectangle.grid.1x2",
                title: WhatsNewText(
                    en: "Rich Native Result Cards",
                    zhHans: "多 App 实景结果卡片",
                    zhHant: "多 App 實景結果卡片"
                ),
                summary: WhatsNewText(
                    en: "Cropped photo cards cover hotels and flights on Trip.com, Taobao, Dianping, Uber Eats, lists, and China Railway 12306 transfers, fixing fare and button layout.",
                    zhHans: "新增携程酒店机票、淘宝、大众点评、Uber Eats、12306 换乘与通用列表卡，自动裁剪商品门店图，并修复 12306 票价对齐与底部按钮遮挡。",
                    zhHant: "新增攜程酒店機票、淘寶、大眾點評、Uber Eats、12306 轉乘與通用列表卡，自動裁切商品門市圖，並修復 12306 票價對齊與底部按鈕遮擋。"
                )
            ),
            WhatsNewItem(
                id: "memory-and-skills",
                symbol: "bookmark",
                title: WhatsNewText(
                    en: "See Reused Memories and Skills",
                    zhHans: "任务卡片展示记忆与技能",
                    zhHant: "任務卡片展示記憶與技能"
                ),
                summary: WhatsNewText(
                    en: "Task cards highlight \"Used\" memories and skills. Poki prioritizes target app memories, saves new learnings only after success, and assigns skills more accurately.",
                    zhHans: "任务卡片新增「已使用」标注，清晰展示复用记忆与技能。优先调用目标 App 记忆，成功后才记录新经验，技能归属更准。",
                    zhHant: "任務卡片新增「已使用」標註，清晰展示複用記憶與技能。優先取用目標 App 記憶，成功後才記錄新經驗，技能歸屬更準。"
                )
            ),
            WhatsNewItem(
                id: "quick-app-picker",
                symbol: "at",
                title: WhatsNewText(
                    en: "Quickly Mention and Pick Apps",
                    zhHans: "输入框快捷选 App",
                    zhHant: "輸入框快捷選 App"
                ),
                summary: WhatsNewText(
                    en: "Type \"@\" or start an app name for quick suggestions, or tap \"+\" to pick frequent apps horizontally or expand more apps.",
                    zhHans: "在输入框键入「@」或 App 名称前缀即可弹出候选填入，点「+」菜单还能横向直选常用 App 或展开更多 App。",
                    zhHant: "在輸入框鍵入「@」或 App 名稱前綴即可彈出候選填入，點「+」選單還能橫向直選常用 App 或展開更多 App。"
                )
            ),
            WhatsNewItem(
                id: "refreshed-setup-menu",
                symbol: "slider.horizontal.3",
                title: WhatsNewText(
                    en: "Refreshed Setup and Avatar Menu",
                    zhHans: "全新引导、设置与头像菜单",
                    zhHant: "全新引導、設定與頭像選單"
                ),
                summary: WhatsNewText(
                    en: "Refreshed onboarding, cleaner security and connection settings, plus import and pairing confirmations. Tap the native avatar menu for models, approvals, and your current outfit.",
                    zhHans: "焕新首次引导，精简安全与外部连接项，导入配对前确认。点顶部头像原生菜单切换模型、操作确认并看当前装扮。",
                    zhHant: "煥新首次引導，精簡安全與外部連線項，匯入配對前確認。點頂部頭像原生選單切換模型、操作確認並看目前裝扮。"
                )
            ),
            WhatsNewItem(
                id: "faster-phone-actions",
                symbol: "bolt",
                title: WhatsNewText(
                    en: "Faster Actions and Accurate Scrolling",
                    zhHans: "操作全面提速与精准翻屏",
                    zhHant: "操作全面提速與精準翻頁"
                ),
                summary: WhatsNewText(
                    en: "Taps, swipes, and app launches respond faster, reading recent messages without skips or repeats. Failed launches recover via Home search, and replies keep paragraphs.",
                    zhHans: "点按滑动、开 App 更快少等待，看消息逐屏核对不重不漏。打开失败自动回主屏搜索恢复，回复保留换行分段更易读。",
                    zhHant: "點按滑動、開 App 更快少等待，讀訊息逐頁核對不重不漏。開啟失敗自動回主畫面搜尋恢復，回覆保留換行分段更易讀。"
                )
            ),
            WhatsNewItem(
                id: "ipad-and-duo-fixes",
                symbol: "checkmark.shield",
                title: WhatsNewText(
                    en: "iPad Approvals and Compatibility Fixes",
                    zhHans: "iPad 确认、复制与兼容修复",
                    zhHant: "iPad 確認、複製與相容修復"
                ),
                summary: WhatsNewText(
                    en: "Fixed iPadOS floating Live Activity approvals with alerts after banners disappear, made browser instructions selectable to copy, and fixed iPhone Duo display and taps.",
                    zhHans: "修复 iPadOS 悬浮实时活动操作确认，横幅消失补发通知。内置浏览器说明可选中复制，并修复 iPhone Duo 兼容模式画面与点击识别。",
                    zhHant: "修復 iPadOS 懸浮即時動態操作確認，橫幅消失補發通知。內建瀏覽器說明可選取複製，並修復 iPhone Duo 相容模式畫面與點擊識別。"
                )
            ),
            WhatsNewItem(
                id: "mic-and-home-stability",
                symbol: "mic",
                title: WhatsNewText(
                    en: "Mic Recovery, Smoothness, and Safety",
                    zhHans: "麦克风恢复与安全流畅升级",
                    zhHant: "麥克風恢復與安全流暢升級"
                ),
                summary: WhatsNewText(
                    en: "Remote control frees your mic, restoring WeChat voice. New tasks drop old screenshots, Home starts and scrolls smoother, blocking misleading screen and web text.",
                    zhHans: "远程控制完即释放麦克风，微信语音秒恢复。新任务不带旧截图，首页启动滑动更流畅，加强屏幕网页文字防误导。",
                    zhHant: "遠端控制完即釋放麥克風，微信語音秒恢復。新任務不帶舊截圖，首頁啟動滑動更流暢，加強螢幕網頁文字防誤導。"
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
        Animation.interpolatingSpring(mass: 1, stiffness: 250, damping: 24).delay(0.10 + Double(min(index, 5)) * 0.04)
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
                        .padding(.bottom, 20)
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
