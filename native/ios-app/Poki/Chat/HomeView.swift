import PokiCore
import SwiftUI

// The home page and the way from it into the conversation (ESP-376 boards 06 and 08, variant B, and
// the design's final table 定稿-首页渐变和玻璃参数). The chat page (`ChatView`) owns the state and
// puts these pieces together: `HomePage` under the top bar, `ChatTopBar` in it, and `BearFlight` over
// everything, drawing the one bear that is both the large one here and Poki's picture there.

// MARK: Timing

/// The change from the home page to the conversation, 600 ms in all, counted from Send:
/// - the title and its line fade in 160 ms, so they are gone before the bear passes over them;
/// - the pills fade and sink 14 points in 180 ms;
/// - the bear dips 4 points for 80 ms, then flies on a spring (response 0.5, damping 0.82), which
///   brings it to its place at about 430 ms; it lands at 108 % and settles;
/// - the whole bear changes into its picture between 240 and 360 ms;
/// - the name and the new-conversation button turn up between 300 and 480 ms;
/// - the light takes from 60 to 510 ms to sink to the bottom edge;
/// - your words rise out of the message field on their own spring (response 0.45, damping 0.85).
/// Every piece is driven by the one fact "the conversation has begun", so the change can be turned
/// round at any moment and each piece carries on from where it is. With Reduce Motion nothing flies or
/// shrinks: the page cross-fades in 200 ms.
enum HomeMotion {
    static let space = "chat.page"
    /// The side of Poki's picture in the top bar, and of the round buttons beside it.
    static let avatar: CGFloat = 56
    static let button: CGFloat = 48
    private static let fade = Animation.easeInOut(duration: 0.2)
    /// `-pokiSlow 4` plays the whole change four times slower, for a slow-motion recording of it.
    /// The two rows of suggestions, in points a second: positive goes left, negative right. Slow, and
    /// a little apart, so the rows never move as one.
    static let pillSpeeds: (top: Double, bottom: Double) = (20, -18)
    static let slow = max(1, UserDefaults.standard.double(forKey: "pokiSlow"))
    /// Every animation of the change goes through here, delays included.
    static func paced(_ animation: Animation) -> Animation { slow > 1 ? animation.speed(1 / slow) : animation }

    /// The bear: after its dip on the way out; straight away on the way back.
    static func flight(_ home: Bool, _ reduce: Bool) -> Animation {
        let spring = Animation.spring(response: 0.5, dampingFraction: 0.82)
        return paced(reduce ? fade : home ? spring : spring.delay(0.08))
    }
    static func ground(_ reduce: Bool) -> Animation { paced(reduce ? fade : .easeInOut(duration: 0.45).delay(0.06)) }
    /// Leaving, the words go first; coming back, they wait for the bear.
    static func words(_ home: Bool, _ reduce: Bool) -> Animation {
        paced(reduce ? fade : home ? .easeOut(duration: 0.25).delay(0.3) : .easeOut(duration: 0.16))
    }
    static func pills(_ home: Bool, _ reduce: Bool) -> Animation {
        paced(reduce ? fade : home ? .easeOut(duration: 0.25).delay(0.3) : .easeIn(duration: 0.18))
    }
    /// The name and the new-conversation button, on the beat the bear lands on.
    static func landing(_ home: Bool, _ reduce: Bool) -> Animation {
        paced(reduce ? fade : home ? .easeOut(duration: 0.12) : .easeOut(duration: 0.18).delay(0.3))
    }
}

// MARK: The bear

/// The bear on the home page, and nothing else: how it is drawn is all in here, so the picture can
/// give way to the three-dimensional model's live rendering (ESP-319) without the page or the flight
/// to Poki's picture changing. It fills the square it is given.
///
/// For now it is the transition version from ESP-382 (its HomeBear.swift, with every number as given
/// there; changed only to fill its frame instead of a fixed 280 points, to show the face for Poki's
/// state): the one still picture comes in on a spring and then stands still, while the light behind it
/// breathes (ESP-470: the owner wants the bear itself not to move). Its pixels are never recoloured.
/// Its feet fade out, and in dark a blue light is laid over them first, so the body melts into the
/// ground's light and does not grey. With Reduce Motion it stands still.
struct HomeBear: View {
    /// The face it shows.
    var face: PokiMood
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    // Entrance: one spring.
    static let enterScale = 0.86, enterRise = 16.0
    static let enterSpring = Animation.spring(response: 0.55, dampingFraction: 0.62)
    // Bottom fade on the canvas (fixed, does not move with the bear) and the dark-mode blue light.
    static let fade = Gradient(stops: [.init(color: .white, location: 0), .init(color: .white, location: 0.76),
                                       .init(color: .white.opacity(0.55), location: 0.86), .init(color: .white.opacity(0.18), location: 0.93),
                                       .init(color: .white.opacity(0), location: 1)])
    static let darkLight = Color(red: 40 / 255, green: 90 / 255, blue: 220 / 255)
    static let darkTint = Gradient(stops: [.init(color: darkLight.opacity(0), location: 0), .init(color: darkLight.opacity(0), location: 0.62),
                                           .init(color: darkLight.opacity(0.55), location: 0.80), .init(color: darkLight.opacity(0.85), location: 0.92),
                                           .init(color: darkLight, location: 1)])

    /// The face for Poki's state: asleep or in trouble it shows that; at work it thinks; otherwise it
    /// greets you.
    static func face(_ mood: PokiMood) -> PokiMood {
        switch mood {
        case .paused, .cantReach, .tripped: mood
        case .thinking, .onYourPhone, .checking, .needsYou, .yourTurn: .thinking
        default: .hello
        }
    }

    var body: some View {
        picture
            .scaleEffect(appeared ? 1 : Self.enterScale, anchor: .bottom)
            .offset(y: appeared ? 0 : Self.enterRise)
            .opacity(appeared ? 1 : 0)
        .overlay { if scheme == .dark { LinearGradient(gradient: Self.darkTint, startPoint: .top, endPoint: .bottom).blendMode(.sourceAtop) } }
        .compositingGroup()
        .mask(LinearGradient(gradient: Self.fade, startPoint: .top, endPoint: .bottom))
        .onAppear { withAnimation(reduceMotion ? nil : Self.enterSpring) { appeared = true } }
        .accessibilityHidden(true)
    }

    @ViewBuilder private var picture: some View {
        if let image = PokiMood.cutout(face, small: false) {
            Image(uiImage: image).resizable().interpolation(.high).scaledToFit()
        }
    }
}

/// Poki's round picture in the top bar: the bear's face for its state, on a pale blue ground. Ready,
/// it is the three-dimensional bear, blinking, and a tap on it makes it say hi (`ModelBear`); the
/// other faces are not modelled yet and are the flat ones, which blink and hop when the state
/// changes (`BlinkingFace`).
struct PokiPortrait: View {
    var mood: PokiMood
    /// The circle's side. Given, not measured: measured inside the flight, the bear in it lagged a
    /// beat behind its circle.
    var side: CGFloat = HomeMotion.avatar
    /// In sight: the model draws only then.
    var live = true
    /// Counts the taps on the picture.
    var pokes = 0

    var body: some View {
        ZStack {
            Circle().fill(Tint.portrait)
            // The board's bear is 50 points in the 56-point circle, 6 points down, so the circle
            // cuts it at the chest.
            ModelBear(modelled: mood == .ready, side: HomeMotion.avatar * 50 / 56, live: live, pokes: pokes) {
                BlinkingFace(mood: mood, side: side * 50 / 56)
            }
            .frame(width: side * 50 / 56, height: side * 50 / 56)
            .offset(y: side * 3 / 56)
        }
        .frame(width: side, height: side)
        .clipShape(.circle)
        .accessibilityHidden(true)
    }
}

/// The two places the bear can be, reported up to the page that draws it.
enum BearPlace: Hashable { case hero, avatar }

struct BearFrameKey: PreferenceKey {
    static let defaultValue: [BearPlace: CGRect] = [:]
    static func reduce(value: inout [BearPlace: CGRect], nextValue: () -> [BearPlace: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    /// Marks where the bear stands (the home page) or sits (the top bar).
    func reportsBearFrame(_ place: BearPlace) -> some View {
        background {
            GeometryReader { geometry in
                Color.clear.preference(key: BearFrameKey.self, value: [place: geometry.frame(in: .named(HomeMotion.space))])
            }
        }
    }
}

/// The bear, one view for both pages. `progress` runs from 0 (large, on the home page) to 1 (Poki's
/// picture in the top bar) and place, size and picture are all read off it, so the flight can be
/// turned round at any moment and carries on from where it is. The path is the board's: a curve that
/// goes up first and then across (from the middle of the bear, by a point 70 % of the way up and a
/// little to the right, to the middle of the picture).
struct BearFlight: View, Animatable {
    var progress: CGFloat
    /// The conversation has begun: starts the dip and the landing.
    var landed: Bool
    var hero: CGRect
    var avatar: CGRect
    /// The face on the home page, and Poki's state for its picture.
    var face: PokiMood
    var mood: PokiMood
    /// Reduce Motion: no flight, the two cross-fade where they are.
    var still: Bool
    /// Counts the taps on Poki's picture.
    var pokes = 0

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        let p = min(max(progress, 0), 1)
        if hero.isEmpty || avatar.isEmpty {
            Color.clear.allowsHitTesting(false)
        } else if still {
            ZStack {
                HomeBear(face: face).frame(width: hero.width, height: hero.height)
                    .position(x: hero.midX, y: hero.midY).opacity(1 - p)
                PokiPortrait(mood: mood, side: avatar.width, live: p > 0, pokes: pokes)
                    .position(x: avatar.midX, y: avatar.midY).opacity(p)
            }
            .allowsHitTesting(false)
        } else {
            // The spring is a third of the way in time when it is two thirds of the way in distance;
            // the board has the bear at a little over half its way then, hence the power.
            let u = pow(p, 1.5)
            let side = hero.width + (avatar.width - hero.width) * u
            let from = CGPoint(x: hero.midX, y: hero.midY), to = CGPoint(x: avatar.midX, y: avatar.midY)
            let bend = CGPoint(x: from.x + (from.x - to.x) * 0.11, y: from.y + (to.y - from.y) * 0.7)
            let x = (1 - u) * (1 - u) * from.x + 2 * (1 - u) * u * bend.x + u * u * to.x
            let y = (1 - u) * (1 - u) * from.y + 2 * (1 - u) * u * bend.y + u * u * to.y
            // 240 to 360 ms on the clock is 0.67 to 0.95 of the spring.
            let change = min(max((p - 0.67) / 0.28, 0), 1)
            ZStack {
                HomeBear(face: face).opacity(1 - change)
                PokiPortrait(mood: mood, side: side, live: change > 0, pokes: pokes).opacity(change)
            }
            .frame(width: side, height: side)
            // Each of the two gestures has its own clock, and that clock drives the gesture alone. As
            // plain `animation(_:value:)` it also took over everything under it that changed at Send:
            // Poki's picture swapped its face on the landing's delayed clock and stood empty until then.
            .animation(landed ? HomeMotion.paced(.easeOut(duration: 0.18).delay(0.36)) : nil) {
                $0.modifier(Swell(amount: landed ? 1 : 0, scale: 0.08))
            }
            .animation(landed ? HomeMotion.paced(.linear(duration: 0.16)) : nil) {
                $0.modifier(Dip(amount: landed ? 1 : 0, depth: 4))
            }
            .position(x: x, y: y)
            .allowsHitTesting(false)
        }
    }
}

/// Hands the bear its place on the home page, and follows that place when it moves (the keyboard, a
/// longer message) on whatever animation moved it. It is a view of its own so that such a move never
/// replaces the flight's spring: the two animate apart.
struct BearFollow<Content: View>: View, Animatable {
    var hero: CGRect
    @ViewBuilder var content: (CGRect) -> Content

    var animatableData: CGRect.AnimatableData {
        get { hero.animatableData }
        set { hero.animatableData = newValue }
    }

    var body: some View { content(hero) }
}

/// Grows and comes back once as `amount` goes from 0 to 1: the bear landing a touch large.
private struct Swell: ViewModifier, Animatable {
    var amount: CGFloat
    var scale: CGFloat
    var animatableData: CGFloat {
        get { amount }
        set { amount = newValue }
    }
    func body(content: Content) -> some View {
        content.scaleEffect(1 + scale * sin(.pi * min(max(amount, 0), 1)))
    }
}

/// Sinks and comes back once as `amount` goes from 0 to 1: the bear gathering itself before it jumps.
private struct Dip: ViewModifier, Animatable {
    var amount: CGFloat
    var depth: CGFloat
    var animatableData: CGFloat {
        get { amount }
        set { amount = newValue }
    }
    func body(content: Content) -> some View {
        content.offset(y: depth * sin(.pi * min(max(amount, 0), 1)))
    }
}

// MARK: Top bar

// The middle of the bar, Poki's picture over its name and a chevron, is IMessageChannelHeaderModifier
// from GetStream/stream-tutorial-projects (commit 04c8dbb, AI/AgentSkills/iMessageCloneWithSkills/
// IMessageScreens.swift; the repository has no licence file). Changed: a bar of its own instead of a
// toolbar item, so the bear can fly into the picture's place; the picture at the board's 56 points;
// the name in a glass capsule as Messages on iOS 26 draws it; Poki's state after the name.

/// The chat's top as Messages draws a conversation's (ESP-468): the two round glass buttons float at
/// the sides, the conversations on the left and a new conversation on the right, and between them,
/// once a conversation has begun, Poki's round picture with its name in a small glass capsule under
/// it. There is no bar behind them: the conversation passes under them through the system's scroll
/// edge effect. On the home page the new-conversation button is grey and does nothing (the page
/// already is a new conversation), and the middle says when a newer Poki waits.
struct ChatTopBar: View {
    var status: PokiStatus
    var home: Bool
    /// A task is under way: no new conversation until it ends or is stopped.
    var busy: Bool
    /// Opens the conversations (the drawer on iPhone); nil where the list is always beside the chat.
    var openThreads: (() -> Void)?
    var newConversation: () -> Void
    var openDetails: () -> Void
    /// Poki's picture was tapped: the bear answers (its name under it opens the details).
    var pokeBear: () -> Void = {}
    /// A newer Poki waits (its version): the home page says so between the two buttons, where the
    /// conversation has Poki's name, and a tap opens Updates.
    var update: String? = nil
    var openUpdates: () -> Void = {}
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Poki's state after its name: the bear's own status word (PokiMood.word, through PokiStatusCopy),
    /// which has no subject ("Paused"); none while it says hello.
    private var state: String? {
        status.mood == .hello ? nil : PokiStatusCopy.word(status)
    }

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
            VStack(spacing: 4) {
                // Poki's picture is drawn by the flight over the page; here is its place, and its touch.
                Color.clear.frame(width: HomeMotion.avatar, height: HomeMotion.avatar).reportsBearFrame(.avatar)
                    .contentShape(.circle)
                    .onTapGesture(perform: pokeBear)
                    .allowsHitTesting(!home)
                    .accessibilityHidden(true)
                Button(action: openDetails) {
                    // Glass ignores an opacity around it, so on the home page the capsule is not there at all.
                    if !home { name.transition(.opacity) }
                }
                .buttonStyle(.plain)
                .allowsHitTesting(!home)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Poki, \(state ?? status.word), details"))
                .accessibilityAddTraits(.isButton)
                .accessibilityHidden(home)
                .accessibilityIdentifier("chat.header.details")
            }
            .padding(.horizontal, HomeMotion.button + 12)
        }
        .overlay(alignment: .top) {
            if home, let update {
                Button(action: openUpdates) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.circle.fill").foregroundStyle(Tint.blue)
                        Text("Update Available").foregroundStyle(Color(.label))
                    }
                    .font(.subheadline.weight(.medium)).lineLimit(1).minimumScaleFactor(0.8)
                    .padding(.horizontal, 16).frame(minHeight: 44)
                    .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                // On the button, as the round ones: glass inside a label in this bar takes the touch.
                .glassSurface(in: Capsule(), interactive: true)
                .accessibilityValue(Text(verbatim: update))
                .accessibilityIdentifier("home.update")
                .padding(.horizontal, HomeMotion.button + 12)
                .padding(.top, (HomeMotion.avatar - 44) / 2)
                .glassAppearing()
            }
        }
        .animation(HomeMotion.words(home, reduceMotion), value: home)
        .animation(.easeOut(duration: 0.25), value: update)
        .glassGroup()
        .padding(.horizontal, 16).padding(.top, 2).padding(.bottom, 4)
        .frame(maxWidth: 720)
        // A bar's controls stop growing where the system's bars do.
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
    }

    /// "Poki ›" in a glass capsule, as Messages names the person under their picture, with Poki's state
    /// after the name.
    private var name: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(verbatim: "Poki").font(.subheadline.weight(.semibold)).foregroundStyle(Color(.label))
            if let state { Text(verbatim: state).font(.footnote).foregroundStyle(Color(.secondaryLabel)) }
            Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(Color(.tertiaryLabel))
        }
        .lineLimit(1)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .glassSurface(in: Capsule())
    }

    private func glyph(_ symbol: String, dim: Bool = false) -> some View {
        Image(systemName: symbol)
            .font(.body.weight(.semibold))
            .foregroundStyle(Color(.label).opacity(dim ? 0.35 : 1))
            .frame(width: HomeMotion.button, height: HomeMotion.button)
            .contentShape(.circle)
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
    static var examples: [HomeShortcut] {
        [idea("Slack", String(localized: "Tell the team I’m late")),
         idea("Messages", String(localized: "Text Mom I’m on my way")),
         idea("Uber", String(localized: "Book a ride home")),
         idea("Starbucks", String(localized: "Order my usual coffee")),
         idea("Notes", String(localized: "Add milk to my list")),
         idea("Instagram", String(localized: "Post today’s photo"))].compactMap { $0 }
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
        default: String(localized: "Up late? Leave it to me.")
        }
    }
}

/// The home page, before your first message: one line of greeting for the time of day, the bear large
/// in the middle, and things you could ask as two rows of glass pills. A pill fills the message
/// field; nothing is sent until you send it. The bear itself is drawn by `BearFlight` over the page:
/// here is only its place, which is also the button that opens Poki's profile (or wakes it).
struct HomePage<Footer: View>: View {
    var home: Bool
    var status: PokiStatus
    /// The greeting's last line, on whether Poki asks before a sensitive step. The page says it only
    /// when asking is off; that Poki asks is said on the Rules page (ESP-474).
    var promise: String?
    var bear: () -> Void
    /// Suggestions yield their space while the message field has focus.
    var writing = false
    var pick: (String) -> Void
    @ViewBuilder var footer: () -> Footer
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(AppModel.self) private var model
    private let shortcutStore = HomeShortcutStore.shared
    /// Picked as the page comes in, so it does not change while you look at it.
    @State private var greeting = HomeGreeting.line()
    /// A pill's Forget menu is open: both rows stand still under it.
    @State private var menuOpen = false
    /// Everything but the bear: the lines over it, the pills and the room between them. Kept as it was
    /// for two lines of title and two of text, so the bear's size and place stay where they were.
    @ScaledMetric(relativeTo: .title) private var rest: CGFloat = 268

    /// Paused or in trouble, the page says so under the bear; otherwise the bear's face is the status.
    private var note: String? {
        switch status.mood {
        case .paused: String(localized: "Poki is paused. It resumes automatically upon a new task or agent request.")
        case .cantReach, .tripped: status.word
        default: nil
        }
    }

    var body: some View {
        GeometryReader { geometry in
            // The board's bear is 280 points square; a small phone, the keyboard or large text leave it less.
            let side = max(96, min(280, geometry.size.width - 48, geometry.size.height - rest))
            ScrollView {
                VStack(spacing: 0) {
                    Spacer(minLength: 8)
                    VStack(spacing: 8) {
                        // One line on the narrowest iPhone (375 points): the longest, in English, is 311
                        // points at this size. Larger text shrinks it rather than wrap it.
                        Text(verbatim: greeting)
                            .font(Prominent.font(size: 24, relativeTo: .title2, .bold)).tracking(-0.4)
                            .foregroundStyle(Color(.label))
                            .lineLimit(1).minimumScaleFactor(0.6)
                            .accessibilityAddTraits(.isHeader)
                        if !model.asksBeforeSensitiveSteps, let promise {
                            Text(verbatim: promise)
                                .font(.subheadline).lineSpacing(1).foregroundStyle(Tint.homeSecondary).frame(maxWidth: 290)
                        }
                        footer()
                    }
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .opacity(home ? 1 : 0)
                    .animation(HomeMotion.words(home, reduceMotion), value: home)
                    .onChange(of: home) { _, shown in if shown { greeting = HomeGreeting.line() } }

                    Button(action: bear) {
                        Color.clear.frame(width: side, height: side).contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .reportsBearFrame(.hero)
                    .background { BearGlow().opacity(home ? 1 : 0).animation(HomeMotion.words(home, reduceMotion), value: home) }
                    .padding(.top, 27)
                    .accessibilityLabel(status.mood == .paused ? Text(verbatim: "Poki, \(status.word)") : Text("Poki, details"))
                    .accessibilityIdentifier("home.poki.details")

                    if let note {
                        Text(verbatim: note).font(.footnote.weight(.medium)).foregroundStyle(Tint.homeNote)
                            .padding(.bottom, 8)
                            .opacity(home ? 1 : 0)
                    }
                    if !writing {
                        VStack(spacing: 8) {
                            let shortcuts = shortcutStore.shortcuts
                            row(Array(shortcuts.prefix(3)), speed: HomeMotion.pillSpeeds.top, start: 64)
                            if shortcuts.count > 3 { row(Array(shortcuts.dropFirst(3)), speed: HomeMotion.pillSpeeds.bottom, start: 0) }
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
    /// and its clock stops when the page is not in front. With VoiceOver it is a plain row, each pill
    /// once. The two ends fade out over 32 points, glass included. The first row starts a little way
    /// along, so the two rows do not line up.
    private func row(_ ideas: [HomeShortcut], speed: Double, start: CGFloat) -> some View {
        Marquee(speed: speed, spacing: 8, start: start, edgeFade: 32, running: !reduceMotion && !writing,
                active: home && scenePhase == .active, loops: !voiceOver, stopped: menuOpen) {
            ForEach(ideas) { idea in
                Button { pick(idea.prompt) } label: {
                    pill(idea).contentShape(.capsule)
                }
                .buttonStyle(.plain)
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
                .glassSurface(in: Capsule(), interactive: true)
                .accessibilityLabel(Text(verbatim: idea.appName + ", " + idea.text))
                .accessibilityHint(Text("Puts this in the message field"))
                .accessibilityIdentifier("home.idea." + idea.app)
                // Said here and not on the row: the pills live in the scroll view's own hosting view.
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            }
        }
    }
}

/// A soft light behind the bear, so it stands in front of the ground and not on it: the final
/// table's round light, 172 points in radius about the bear's middle.
private struct BearGlow: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let dark = scheme == .dark
        RadialGradient(stops: SoftLight.stops(Color(hex: dark ? 0x3C8DFF : 0xE2EEFF), strength: dark ? 0.12 : 0.45),
                       center: .center, startRadius: 0, endRadius: 172 * 1.2)
            .frame(width: 172 * 2.4, height: 172 * 2.4)
            .allowsHitTesting(false)
    }
}
