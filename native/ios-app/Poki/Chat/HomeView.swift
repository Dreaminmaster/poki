import PokiCore
import SwiftUI

// The home page and the way from it into the conversation (ESP-376, and the owner's home of
// 2026-11-12: no large bear, Poki's picture at the top as in the conversation). The chat page
// (`ChatView`) owns the state and puts these pieces together: `HomePage` under the top bar and
// `ChatTopBar` in it, the same on both pages.

// MARK: Timing

/// The change from the home page to the conversation, counted from Send: the greeting fades in
/// 160 ms, the pills fade and sink 14 points in 180 ms, the light takes from 60 to 510 ms to sink to
/// the bottom edge, the new-conversation button turns up on 300 to 480 ms, and your words rise out of
/// the message field on their own spring (response 0.45, damping 0.85). Every piece is driven by the
/// one fact "the conversation has begun", so the change can be turned round at any moment. With
/// Reduce Motion the page cross-fades in 200 ms.
enum HomeMotion {
    /// The side of Poki's picture in the top bar, and of the round buttons beside it.
    static let avatar: CGFloat = 56
    static let button: CGFloat = 48
    private static let fade = Animation.easeInOut(duration: 0.2)
    /// The two rows of suggestions, in points a second: positive goes left, negative right. Slow, and
    /// a little apart, so the rows never move as one.
    static let pillSpeeds: (top: Double, bottom: Double) = (20, -18)
    /// `-pokiSlow 4` plays the whole change four times slower, for a slow-motion recording of it.
    static let slow = max(1, UserDefaults.standard.double(forKey: "pokiSlow"))
    /// Every animation of the change goes through here, delays included.
    static func paced(_ animation: Animation) -> Animation { slow > 1 ? animation.speed(1 / slow) : animation }

    static func ground(_ reduce: Bool) -> Animation { paced(reduce ? fade : .easeInOut(duration: 0.45).delay(0.06)) }
    /// Leaving, the words go first; coming back, they wait a beat.
    static func words(_ home: Bool, _ reduce: Bool) -> Animation {
        paced(reduce ? fade : home ? .easeOut(duration: 0.25).delay(0.3) : .easeOut(duration: 0.16))
    }
    static func pills(_ home: Bool, _ reduce: Bool) -> Animation {
        paced(reduce ? fade : home ? .easeOut(duration: 0.25).delay(0.3) : .easeIn(duration: 0.18))
    }
    /// The new-conversation button, once the conversation has begun.
    static func landing(_ home: Bool, _ reduce: Bool) -> Animation {
        paced(reduce ? fade : home ? .easeOut(duration: 0.12) : .easeOut(duration: 0.18).delay(0.3))
    }
}

// MARK: Poki's picture

/// Poki's round picture in the top bar: the bear's face for its state, on a pale blue ground. The
/// face blinks and hops when the state changes (`BlinkingFace`).
struct PokiPortrait: View {
    var mood: PokiMood
    var side: CGFloat = HomeMotion.avatar

    var body: some View {
        ZStack {
            Circle().fill(Tint.portrait)
            // The board's bear is 50 points in the 56-point circle, 6 points down, so the circle
            // cuts it at the chest.
            BlinkingFace(mood: mood, side: side * 50 / 56)
                .offset(y: side * 3 / 56)
        }
        .frame(width: side, height: side)
        .clipShape(.circle)
        .accessibilityHidden(true)
    }
}

/// Poki at the top of the home page and of the conversation (board 定稿 07): its picture in a white
/// ring with a soft blue shadow, and under it a dot and the word for where it stands. The picture
/// inside the ring is the one place the three-dimensional bear takes over.
struct PokiHead: View {
    var status: PokiStatus
    @Environment(\.colorScheme) private var scheme

    /// The status word, from the one table (StatusWord).
    private var word: String { PokiStatusCopy.word(status) }

    var body: some View {
        let dark = scheme == .dark
        VStack(spacing: 5) {
            PokiPortrait(mood: status.mood)
                .overlay(Circle().strokeBorder(Color.white.opacity(dark ? 0.85 : 1), lineWidth: 2))
                .shadow(color: dark ? Color(hex: 0x3C8DFF).opacity(0.35) : Color(hex: 0x0177FD).opacity(0.18), radius: dark ? 8 : 7, y: 4)
            HStack(spacing: 5) {
                // Ready is green here (the board), as Done is.
                Circle().fill(status.mood == .ready ? Tint.green : status.mood.dot).frame(width: 6, height: 6)
                Text(verbatim: word)
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(dark ? Color(hex: 0xC7CCD6) : Color(hex: 0x5F676C))
                    .lineLimit(1)
            }
        }
    }
}

// MARK: Top bar

// The middle of the bar, Poki's picture over its state, is IMessageChannelHeaderModifier from
// GetStream/stream-tutorial-projects (commit 04c8dbb, AI/AgentSkills/iMessageCloneWithSkills/
// IMessageScreens.swift; the repository has no licence file). Changed: a bar of its own instead of a
// toolbar item; the picture at the board's 56 points in a white ring; a dot and Poki's state under it
// (board 定稿 07).

/// The chat's top as Messages draws a conversation's (ESP-468): the two round glass buttons float at
/// the sides, the conversations on the left and a new conversation on the right, and between them
/// Poki's picture with its state, on the home page as in the conversation. A tap on Poki opens its
/// card. There is no bar behind them: the conversation passes under them through the system's scroll
/// edge effect. On the home page the new-conversation button is grey and does nothing (the page
/// already is a new conversation).
struct ChatTopBar: View {
    var status: PokiStatus
    var home: Bool
    /// A task is under way: no new conversation until it ends or is stopped.
    var busy: Bool
    /// Opens the conversations (the drawer on iPhone); nil where the list is always beside the chat.
    var openThreads: (() -> Void)?
    var newConversation: () -> Void
    var openDetails: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .top) {
            HStack {
                if let openThreads {
                    Button(action: openThreads) { glyph("line.3.horizontal") }
                        .buttonStyle(.plain)
                        .glassSurface(in: Circle(), interactive: true)
                        .accessibilityLabel(Text("Conversations"))
                        .accessibilityIdentifier("chat.threads")
                }
                Spacer(minLength: 8)
                Button(action: newConversation) {
                    glyph("square.and.pencil", dim: home || busy).animation(HomeMotion.landing(home, reduceMotion), value: home)
                }
                .buttonStyle(.plain)
                .glassSurface(in: Circle(), interactive: !home && !busy)
                .allowsHitTesting(!home && !busy)
                .accessibilityLabel(Text("New Conversation"))
                .accessibilityHidden(home)
                .accessibilityIdentifier("home.newChat")
            }
            .padding(.top, (HomeMotion.avatar - HomeMotion.button) / 2)
            Button(action: openDetails) {
                PokiHead(status: status).contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: "Poki, " + PokiStatusCopy.word(status)))
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("chat.header.details")
            .padding(.horizontal, HomeMotion.button + 12)
        }
        .glassGroup()
        .padding(.horizontal, 16).padding(.top, 2).padding(.bottom, 4)
        .frame(maxWidth: 720)
        // A bar's controls stop growing where the system's bars do.
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
    }

    private func glyph(_ symbol: String, dim: Bool = false) -> some View {
        Image(systemName: symbol)
            .font(.body.weight(.semibold))
            .foregroundStyle(Color(.label).opacity(dim ? 0.35 : 1))
            .frame(width: HomeMotion.button, height: HomeMotion.button)
            .contentShape(.circle)
    }
}

/// A newer Poki waits (its version): said on the home page under the greeting, and a tap opens Updates.
struct UpdatePill: View {
    var version: String
    var open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(Tint.blue)
                Text("Update Available").foregroundStyle(Color(.label))
            }
            .font(.subheadline.weight(.medium)).lineLimit(1).minimumScaleFactor(0.8)
            .padding(.horizontal, 16).frame(minHeight: 44)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassSurface(in: Capsule(), interactive: true)
        .accessibilityValue(Text(verbatim: version))
        .accessibilityIdentifier("home.update")
        .glassAppearing()
    }
}

// MARK: Home page

/// The default quick actions, until the owner's own take their place (`HomeShortcuts`): each an app
/// and what to do in it, the shape every pill on the home page has.
@MainActor
enum HomeIdea {
    private static func idea(_ app: String, _ text: String) -> HomeShortcut? {
        guard let capsule = AppCapsule.catalog.first(where: { $0.name == app }), let shown = ShortcutApp.named(capsule.id) else { return nil }
        return HomeShortcut(key: HomeShortcuts.normalize(text), app: shown.id, appName: shown.name, text: text,
                            prompt: CapsuleText.prefill(app: capsule, sentence: text))
    }
    /// An app by its bundle ID, the action its pill shows and the whole request a tap puts in the field.
    private static func idea(app: String, _ text: String, prompt: String) -> HomeShortcut? {
        guard let shown = ShortcutApp.named(app) else { return nil }
        return HomeShortcut(key: HomeShortcuts.normalize(prompt), app: shown.id, appName: shown.name, text: text, prompt: prompt)
    }

    static var examples: [HomeShortcut] { examples(for: .current) }

    static func examples(for language: AppLanguage) -> [HomeShortcut] {
        language == .simplifiedChinese ? simplifiedChinese : english
    }

    private static var english: [HomeShortcut] {
        [idea("Slack", String(localized: "Tell the team I’m late")),
         idea("Messages", String(localized: "Text Mom I’m on my way")),
         idea("Uber", String(localized: "Book a ride home")),
         idea("Starbucks", String(localized: "Order my usual coffee")),
         idea("Notes", String(localized: "Add milk to my list")),
         idea("Instagram", String(localized: "Post today’s photo"))].compactMap { $0 }
    }

    /// The apps people in mainland China use every day, written in Chinese rather than translated from
    /// the English set. A tap only fills the field and the caret lands at the end, so a request that
    /// needs a contact, a topic, a product or a place ends where that goes, for the owner to finish.
    private static var simplifiedChinese: [HomeShortcut] {
        [idea(app: "com.tencent.xin", "发消息", prompt: "用微信发一条消息给"),
         idea(app: "com.taobao.taobao4iphone", "查物流", prompt: "打开淘宝，看看我最近一单的物流到哪了"),
         idea(app: "com.dianping.dpscope", "找附近餐厅", prompt: "用大众点评找附近评分高的餐厅"),
         idea(app: "com.meituan.itakeaway", "点外卖", prompt: "打开美团外卖，帮我看看附近有什么好吃的"),
         idea(app: "com.xunmeng.pinduoduo", "查订单", prompt: "打开拼多多，看看我的订单到哪了"),
         idea(app: "com.xingin.discover", "搜攻略", prompt: "在小红书搜一下攻略："),
         idea(app: "com.taobao.fleamarket", "看我的闲置", prompt: "打开闲鱼，看看我发布的闲置有没有新消息"),
         idea(app: "com.360buy.jdmobile", "查价格", prompt: "在京东查一下价格："),
         idea(app: "com.baidu.map", "导航回家", prompt: "打开百度地图，导航回家"),
         idea(app: "com.autonavi.amap", "查路线", prompt: "打开高德地图，查一下路线，目的地是")].compactMap { $0 }
    }
}

/// The home page's one line for the time of day (ESP-474), as a chat app greets you: morning from 5,
/// afternoon from 11, evening from 18, late from 23.
enum HomeGreeting {
    static func line(at date: Date = .now, calendar: Calendar = .current) -> String {
        switch calendar.component(.hour, from: date) {
        case 5..<11: String(localized: "Good morning. Need a hand?")
        case 11..<18: String(localized: "Good afternoon. Need help?")
        case 18..<23: String(localized: "Good evening. Anything left?")
        default: String(localized: "Up late? Leave it to me")
        }
    }
}

/// The home page, before your first message (board 定稿 01): under Poki's picture at the top, one
/// line of greeting for the time of day a little above the middle, and things you could ask as two
/// rows of glass pills over the message field. A pill fills the message field; nothing is sent until
/// you send it.
struct HomePage<Footer: View>: View {
    var home: Bool
    /// Suggestions yield their space while the message field has focus.
    var writing = false
    var pick: (String) -> Void
    @ViewBuilder var footer: () -> Footer
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.coveredByDrawer) private var covered
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.colorScheme) private var scheme
    private let shortcutStore = HomeShortcutStore.shared
    /// Picked as the page comes in, so it does not change while you look at it.
    @State private var greeting = HomeGreeting.line()
    /// A pill's Forget menu is open: both rows stand still under it.
    @State private var menuOpen = false
    /// The board's greeting: PingFang Semibold 30 on 36, tracked in by 2 %, 184 points under the top bar.
    @ScaledMetric(relativeTo: .title) private var greetingSize: CGFloat = 30
    @ScaledMetric(relativeTo: .title) private var greetingLine: CGFloat = 36

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    VStack(spacing: 12) {
                        // One line in Chinese on the narrowest iPhone; English may take two.
                        Text(verbatim: greeting)
                            .font(.custom("PingFangSC-Semibold", size: greetingSize))
                            .tracking(-0.02 * greetingSize)
                            .lineSpacing(greetingLine - greetingSize * 1.2)
                            .foregroundStyle(scheme == .dark ? Color(hex: 0xF2F4F7) : Color(hex: 0x16181B))
                            .lineLimit(2).minimumScaleFactor(0.7)
                            .accessibilityAddTraits(.isHeader)
                        footer()
                    }
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.top, writing ? 24 : min(184, max(24, geometry.size.height * 0.29)))
                    .opacity(home ? 1 : 0)
                    .animation(HomeMotion.words(home, reduceMotion), value: home)
                    .onChange(of: home) { _, shown in if shown { greeting = HomeGreeting.line() } }

                    Spacer(minLength: 24)
                    if !writing {
                        VStack(spacing: 8) {
                            let shortcuts = shortcutStore.shortcuts
                            // Three on top, or the larger half of more than six.
                            let top = max(3, (shortcuts.count + 1) / 2)
                            row(Array(shortcuts.prefix(top)), at: 0, speed: HomeMotion.pillSpeeds.top, start: 64)
                            if shortcuts.count > top { row(Array(shortcuts.dropFirst(top)), at: 1, speed: HomeMotion.pillSpeeds.bottom, start: 0) }
                        }
                        .padding(.top, 2)
                        // A sideways drag on the rows scrolls them; it does not pull the drawer out.
                        .scrollsSideways(home)
                        .opacity(home ? 1 : 0)
                        .offset(y: home || reduceMotion ? 0 : 14)
                        .animation(HomeMotion.pills(home, reduceMotion), value: home)
                    }
                    Spacer().frame(height: 34)
                }
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
        }
        .animation(.snappy(duration: 0.3), value: writing)
        .task(id: SessionStore.shared.sessions.count) {
            shortcutStore.refresh(sessions: SessionStore.shared.sessions, routines: RoutineStore.shared.routines)
        }
    }

    /// A pill: the app's icon, its name and the action, the name and the action in one size and told
    /// apart by weight and shade (the owner: the name and the words after it did not match).
    private func pill(_ idea: HomeShortcut) -> some View {
        HStack(spacing: 8) {
            AppIconView(app: idea.app, size: 24, alwaysLight: true)
            HStack(spacing: 5) {
                Text(verbatim: idea.appName).font(.subheadline.weight(.semibold)).foregroundStyle(Color(.label))
                Text(verbatim: idea.text).font(.subheadline).foregroundStyle(Color(.label).opacity(0.7))
            }
            .lineLimit(1)
        }
        .padding(.leading, 12).padding(.trailing, 18).frame(minHeight: 48)
    }

    /// One row of pills that goes by on its own, slowly and without an end, and that a finger stops,
    /// moves and flicks (`Marquee`). It stands still with Reduce Motion and while the keyboard is up,
    /// and its clock stops when the page is not in front or the drawer is open. With VoiceOver it is a plain row, each pill
    /// once. The two ends fade out over 32 points, glass included. The first row starts a little way
    /// along, so the two rows do not line up.
    private func row(_ ideas: [HomeShortcut], at index: Int, speed: Double, start: CGFloat) -> some View {
        Marquee(speed: speed, spacing: 8, start: start, edgeFade: 32, running: !reduceMotion && !writing && !PerfSwitch.on(.pillsStill),
                active: home && scenePhase == .active && !covered, loops: !voiceOver, stopped: menuOpen) {
            ForEach(ideas) { idea in
                Button { pick(idea.prompt) } label: {
                    pill(idea).contentShape(.capsule)
                }
                .pillButtonStyle(row: index)
                // Under the glass: with the menu on the outside, the glass took the long press and the
                // pill fired as a tap. The lifted pill is drawn on its own, on a capsule of its own
                // size: a snapshot of the pill left its glass behind and stood still while the row
                // went on under it.
                .contentShape(.contextMenuPreview, Capsule())
                .contextMenu {
                    Button("Forget", systemImage: "eye.slash", role: .destructive) { shortcutStore.forget(idea) }
                } preview: {
                    pill(idea)
                        .background(.regularMaterial, in: Capsule())
                        .clipShape(.capsule)
                        .onAppear { menuOpen = true }
                        .onDisappear { menuOpen = false }
                }
                .livePillGlass()
                .accessibilityLabel(Text(verbatim: idea.appName + ", " + idea.text))
                .accessibilityHint(Text("Puts this in the message field"))
                .accessibilityIdentifier("home.idea." + idea.app)
                // Said here and not on the row: the pills live in the scroll view's own hosting view.
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            }
        }
    }
}

/// The suggestion pills' surface. They go by over the home light, which is never still, so live glass
/// on them sampled and refracted a changing picture every frame they moved. Here the surface is drawn
/// as that glass looks over the light (a sheet of the light's own colour, a bright rim inside the edge) and it
/// samples nothing, so a pill that only moves is not drawn again. A press lifts the pill a little, as
/// the glass's own reaction to a touch did. Reduce Transparency makes the sheet opaque and Increase
/// Contrast gives it a firmer edge.
///
/// Not yet the default: laid beside the live glass it shows (the glass bends the light at a pill's ends
/// and, in dark mode, has a fine dark edge), so the owner chooses from the two side by side first. Until
/// then the pills stay live glass. `drawnByDefault` turns the drawn surface on for every build;
/// `-pokiPerf drawnPills` turns it on in a debug build, and `pillsNoGlass` draws no surface at all.
enum PillLook {
    static let drawnByDefault = false
    static var drawn: Bool { (drawnByDefault || PerfSwitch.on(.drawnPills)) && !PerfSwitch.on(.pillsNoGlass) }
    static var live: Bool { !drawn && !PerfSwitch.on(.pillsNoGlass) }
}

extension View {
    @ViewBuilder fileprivate func pillButtonStyle(row: Int) -> some View {
        if PillLook.drawn { buttonStyle(PillButtonStyle(row: row)) } else { buttonStyle(.plain) }
    }

    @ViewBuilder fileprivate func livePillGlass() -> some View {
        if PillLook.live { glassSurface(in: Capsule(), interactive: true) } else { self }
    }
}

private struct PillButtonStyle: ButtonStyle {
    /// 0 for the top row, 1 for the bottom one: they sit over different parts of the light.
    var row: Int

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background { PillSheet(row: row, pressed: configuration.isPressed) }
            .scaleEffect(configuration.isPressed ? PillSheet.pressScale : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.65), value: configuration.isPressed)
    }
}

/// The numbers are read off the live glass over the home light in the simulator (iOS 27, the light
/// held at one moment): the sheet as the colour and share that, laid over the light, gives the glass's
/// colour inside the pill; a bright rim three pixels wide inside the edge; in light mode a darker line
/// two pixels wide just outside it.
private struct PillSheet: View {
    var row: Int
    var pressed: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    static let pressScale: CGFloat = 1.04
    /// Light: one sheet for both rows. Dark: the glass brightens the deeper blue under the bottom row more.
    static let light = (sheet: Color(red: 221 / 255, green: 252 / 255, blue: 1), share: 0.55)
    static let dark = [(sheet: Color(red: 57 / 255, green: 134 / 255, blue: 1), share: 0.32),
                       (sheet: Color(red: 24 / 255, green: 109 / 255, blue: 1), share: 0.74)]
    static let rim = (light: Color.white.opacity(0.75), dark: Color(red: 80 / 255, green: 170 / 255, blue: 1).opacity(0.55))
    static let outline = Color.black.opacity(0.13)

    var body: some View {
        let dark = scheme == .dark, shape = Capsule()
        let tone = dark ? Self.dark[min(max(row, 0), 1)] : Self.light
        let share = min(1, tone.share + (pressed ? 0.15 : 0))
        ZStack {
            if reduceTransparency {
                shape.fill(Color(.secondarySystemBackground))
            } else {
                shape.fill(tone.sheet.opacity(share))
            }
            shape.strokeBorder(contrast == .increased ? Color(.separator) : dark ? Self.rim.dark : Self.rim.light, lineWidth: 1)
            if !dark { shape.inset(by: -1 / 3).stroke(Self.outline, lineWidth: 2 / 3) }
        }
    }
}

