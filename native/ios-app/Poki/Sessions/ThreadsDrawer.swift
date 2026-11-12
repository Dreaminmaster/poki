import SwiftUI
import UIKit

// The drawer's motion follows OpenBot's app drawer (OpenBot, apps/mobile/src/features/servers/components/
// app-drawer-shell.tsx, PolyForm Noncommercial License 1.0.0), moved from React Native to SwiftUI:
// one progress value from 0 (closed) to 1 (open) that the finger moves directly; on release the
// progress plus a sixth of a second of the finger's speed decides open or closed, past 0.45 when opening
// and 0.55 when closing; the spring starts at the finger's speed; the uncovered chat gets a dim and a
// light blur. Changed from OpenBot: there the chat slides away and the drawer lies under it, here the
// panel is Liquid Glass and floats over the chat so the chat's colours show through it; the spring
// bounces a little (OpenBot clamps its overshoot); a drag past fully open stretches with resistance.

/// The conversations as a drawer from the leading edge of the chat (iPhone): a floating Liquid Glass
/// panel that follows the finger, while the chat behind it dims and moves back a little. A tap or a
/// drag on the uncovered chat closes it. iOS has no drawer of its own on iPhone, so this one is drawn;
/// what is inside it is a system List.
///
/// A drag opens it only while the chat itself is in front (`enabled`): with a page pushed over the
/// chat, the leading edge belongs to the system's swipe back. The drawer's own rows keep their swipe
/// actions, so a drag closes it from the uncovered chat, not from the list.
///
/// Reduce Motion: the panel fades in and out where it rests, and the chat stays put. Reduce
/// Transparency: the panel is the opaque system background instead of glass.
struct ThreadsDrawer<Drawer: View>: ViewModifier {
    @Binding var isOpen: Bool
    var enabled: Bool
    @ViewBuilder var drawer: () -> Drawer

    /// How far open the drawer is: 0 closed, 1 open, a little past either while the spring settles.
    @State private var progress: CGFloat = 0
    /// The progress when the drawer's current drag began; nil while none is under way.
    @State private var dragStart: CGFloat?
    /// True while a drag is under way, so a drag the system cancels (no `onEnded`) still settles.
    @GestureState private var dragging = false
    @State private var screen = CGSize(width: 402, height: 874)
    @State private var insets = EdgeInsets()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var scheme

    /// Where the content scrolls sideways by itself (`scrollsSideways`), in screen coordinates.
    @State private var sideways: [CGRect] = []

    private var layout: ThreadsDrawerLayout { ThreadsDrawerLayout(screen: screen, insets: insets) }
    /// The progress for what is drawn: never below closed, and while it bounces, not far past open.
    private var shown: CGFloat { min(max(progress, 0), 1.08) }
    private var settled: CGFloat { min(shown, 1) }

    func body(content: Content) -> some View {
        content
            // Under the panel's clear glass the chat itself blurs, so its colours and shapes show as soft outlines.
            .blur(radius: DrawerGlass.current == .soft && !reduceTransparency ? DrawerGlass.blur * settled : 0)
            // The chat moves back a little to the trailing side, as the panel comes in from the leading one.
            .offset(x: reduceMotion ? 0 : ThreadsDrawerMotion.chatShift * settled)
            .accessibilityHidden(isOpen)
            .simultaneousGesture(drag, including: enabled && !isOpen ? .all : .subviews)
            .onPreferenceChange(SidewaysScrollAreas.self) { sideways = $0 }
            // What shows where the chat has moved from: the chat's own page colour.
            .background(Tint.page.ignoresSafeArea())
            // The safe area, read where it is kept (a reader that ignores it reads none).
            .overlay {
                GeometryReader { geometry in
                    Color.clear
                        .onAppear { insets = geometry.safeAreaInsets }
                        .onChange(of: geometry.safeAreaInsets) { _, new in insets = new }
                }
                .ignoresSafeArea(.keyboard)
                .allowsHitTesting(false)
            }
            .overlay {
                GeometryReader { geometry in
                    ZStack(alignment: .topLeading) {
                        scrim
                        panel
                    }
                    .onAppear { screen = geometry.size }
                    .onChange(of: geometry.size) { _, new in screen = new }
                }
                .ignoresSafeArea()
            }
            .sensoryFeedback(.impact(weight: .light), trigger: isOpen)
            .onChange(of: isOpen) { _, open in
                // The keyboard belongs to the chat's message field, not to the list over it.
                if open { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
                // Opened or closed from elsewhere (the chat's button, a row, a launch argument): the same spring.
                if dragStart == nil, progress != (open ? 1 : 0) { settle(open, speed: 0) }
            }
            .onChange(of: dragging) { _, now in
                // The system took the drag away before it ended: go back to where it was.
                if !now, dragStart != nil { dragStart = nil; settle(isOpen, speed: 0) }
            }
            .onAppear { progress = isOpen ? 1 : 0 }
    }

    /// The uncovered chat: dimmed and lightly blurred, so its own buttons do not look like they can be
    /// tapped; a tap or a drag here closes the drawer. Everything but the panel, so the glass shows the
    /// chat's own colours rather than the dim.
    private var scrim: some View {
        let cutout = Rectangle().subtracting(layout.shape.offset(x: panelOffset).path(in: layout.panel))
        return ZStack {
            if reduceTransparency {
                // Without the blur (Reduce Transparency) the page's own colour covers most of the chat, so
                // the chat's buttons in the strip don't look tappable.
                Rectangle().fill(Color(.systemBackground).opacity(ThreadsDrawerMotion.cover * settled))
            } else {
                Rectangle().fill(.ultraThinMaterial).opacity(settled)
            }
            Rectangle().fill(Color.black.opacity((reduceTransparency ? ThreadsDrawerMotion.dimOpaque : ThreadsDrawerMotion.dim) * settled))
        }
        .mask(cutout)
        .contentShape(cutout)
        .onTapGesture { settle(false, speed: 0) }
        .gesture(drag)
        .allowsHitTesting(isOpen)
        .accessibilityHidden(true)
    }

    /// Where the panel is drawn, from its resting place: off to the leading side when closed.
    private var panelOffset: CGFloat {
        reduceMotion ? 0 : (shown - 1) * layout.travel
    }

    private var panel: some View {
        let shape = layout.shape
        return drawer()
            .environment(\.drawerOnGlass, true)
            .frame(width: layout.panel.width, height: layout.panel.height)
            .clipShape(shape)
            .background { panelSurface(shape) }
            .shadow(color: .black.opacity(0.12 * settled), radius: 24, x: 4, y: 8)
            .offset(x: panelOffset)
            // Placed with padding, not an offset, so the list inside gets the safe area of where it really is.
            .padding(.leading, layout.panel.minX).padding(.top, layout.panel.minY)
            .opacity(reduceMotion ? settled : (progress > 0.001 ? 1 : 0))
            .allowsHitTesting(isOpen)
            .accessibilityHidden(!isOpen)
            .accessibilityAddTraits(.isModal)
            .accessibilityAction(.escape) { settle(false, speed: 0) }
    }

    @ViewBuilder private func panelSurface(_ shape: RoundedRectangle) -> some View {
        if reduceTransparency {
            shape.fill(Color(.systemBackground)).overlay(shape.strokeBorder(Color(.separator), lineWidth: 0.5))
        } else if #available(iOS 26.0, *), DrawerGlass.current != .regular {
            // Clear glass, veiled a little in the page's colour so the list reads over any chat.
            Color.clear.glassEffect(DrawerGlass.current == .soft ? .clear.tint(Color(.systemBackground).opacity(DrawerGlass.veil(dark: scheme == .dark))) : .clear, in: shape)
        } else {
            Color.clear.glassSurface(in: shape, fallback: .card)
        }
    }

    /// Opens or closes with the drawer's spring, starting at `speed` (progress per second).
    private func settle(_ open: Bool, speed: CGFloat) {
        let target: CGFloat = open ? 1 : 0
        let animation = reduceMotion ? ThreadsDrawerMotion.fade : ThreadsDrawerMotion.spring(from: progress, to: target, speed: speed)
        withAnimation(animation) { progress = target }
        if isOpen != open { isOpen = open }
    }

    /// The drag began on something that scrolls sideways itself (the home page's suggestion rows),
    /// and not at the screen's very edge: it is that row's, not the drawer's.
    private func scrolls(_ value: DragGesture.Value) -> Bool {
        !isOpen && value.startLocation.x > 24 && sideways.contains { $0.contains(value.startLocation) }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 16, coordinateSpace: .global)
            .updating($dragging) { _, state, _ in state = true }
            .onChanged { value in
                let dx = value.translation.width
                if dragStart == nil {
                    // A mostly sideways drag in the drawer's direction; an up or down one belongs to the scroll view.
                    guard abs(dx) > abs(value.translation.height) * 1.5, isOpen ? dx < 0 : dx > 0, !scrolls(value) else { return }
                    dragStart = progress
                }
                guard let start = dragStart else { return }
                var next = start + dx / layout.travel
                // Past fully open the panel stretches with resistance.
                if next > 1 { next = 1 + (next - 1) * 0.12 }
                var instant = Transaction()
                instant.disablesAnimations = true
                withTransaction(instant) { progress = max(0, next) }
            }
            .onEnded { value in
                guard dragStart != nil else { return }
                dragStart = nil
                let speed = value.velocity.width / layout.travel
                let projected = min(progress, 1) + speed / 6
                settle(projected > (isOpen ? 0.55 : 0.45), speed: speed)
            }
    }
}

/// Where the panel rests, from the screen's size and safe area: a floating panel inset from the
/// leading edge, below the status bar so it never runs through its icons, with a strip of the chat
/// left to tap; no wider than a comfortable list.
struct ThreadsDrawerLayout {
    var screen: CGSize
    var insets: EdgeInsets

    static let margin: CGFloat = 8
    /// The strip of the chat left uncovered, at least.
    static let strip: CGFloat = 52

    var panel: CGRect {
        let width = max(240, min(screen.width - Self.margin - Self.strip, 360))
        let top = max(insets.top, Self.margin)
        return CGRect(x: Self.margin, y: top, width: width, height: max(0, screen.height - top - Self.margin))
    }

    /// The panel's corners: as round as the iPhone's own where it has round corners.
    var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: insets.bottom > 0 ? 34 : 18, style: .continuous)
    }

    /// How far the finger moves the drawer from closed to open, and how far the panel moves with it: the
    /// same distance, so the panel stays under the finger. Closed, its trailing edge is at the screen's edge
    /// (its shadow fades out with it, and it is hidden there).
    var travel: CGFloat { max(panel.maxX, 1) }
}

enum ThreadsDrawerMotion {
    /// The spring the drawer settles with when opened or closed by a button or a tap.
    static let settle = Animation.interpolatingSpring(duration: 0.42, bounce: 0.16)
    /// With Reduce Motion: a plain fade.
    static let fade = Animation.easeInOut(duration: 0.22)
    /// The chat's dim at fully open, under the blur.
    static let dim: CGFloat = 0.22
    /// The dim with Reduce Transparency, where there is no blur.
    static let dimOpaque: CGFloat = 0.3
    /// How much of the page's colour covers the chat under Reduce Transparency.
    static let cover: CGFloat = 0.8
    /// How far the chat moves back to the trailing side at fully open.
    static let chatShift: CGFloat = 24

    /// The spring from `from` to `to`, starting at the finger's `speed` (progress per second).
    /// SwiftUI takes the starting speed as a share of the distance to go.
    static func spring(from: CGFloat, to: CGFloat, speed: CGFloat) -> Animation {
        let distance = to - from
        guard abs(distance) > 0.01, speed != 0 else { return settle }
        let share = max(-4, min(12, speed / distance))
        return .interpolatingSpring(duration: 0.42, bounce: 0.16, initialVelocity: share)
    }
}

/// The panel's glass. Soft: the system's clear glass, lightly veiled, over the chat blurred by the drawer
/// itself; the chat's colours and the bear's outline show through, softly. The regular glass frosts so
/// much that a pale page (the home page's bear) all but disappears behind it, though it is the system's
/// own choice for a sidebar. `-pokiDrawerGlass regular|clear` shows the others, to compare.
enum DrawerGlass: String {
    case soft, regular, clear

    static let current: DrawerGlass = {
        // Before iOS 26 there is no glass: the regular case draws the system's material.
        guard #available(iOS 26.0, *), !GlassSwitch.forcedOff else { return .regular }
        return UserDefaults.standard.string(forKey: "pokiDrawerGlass").flatMap(DrawerGlass.init(rawValue:)) ?? .soft
    }()
    /// How much the chat blurs under the soft glass when fully open, in points.
    static let blur: CGFloat = 8
    /// The page colour in the soft glass. Deeper in dark mode, where the list's light text would
    /// otherwise sit on a bright part of the chat (the home page's bear) with too little contrast; the
    /// chat's colours and outlines still show through.
    static func veil(dark: Bool) -> CGFloat { dark ? 0.6 : 0.26 }
}

extension EnvironmentValues {
    /// True inside the drawer's glass panel: the list and its bars draw no opaque ground of their own.
    @Entry var drawerOnGlass = false
}

/// Where on the screen a sideways drag belongs to the content: such a view says where it is, and the
/// drawer's swipe leaves drags that begin there alone.
struct SidewaysScrollAreas: PreferenceKey {
    static let defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) { value += nextValue() }
}

extension View {
    /// Marks this view as scrolling sideways by itself while `on`.
    func scrollsSideways(_ on: Bool = true) -> some View {
        background { GeometryReader { geometry in Color.clear.preference(key: SidewaysScrollAreas.self, value: on ? [geometry.frame(in: .global)] : []) } }
    }
}

extension View {
    func threadsDrawer<Drawer: View>(isOpen: Binding<Bool>, enabled: Bool, @ViewBuilder drawer: @escaping () -> Drawer) -> some View {
        modifier(ThreadsDrawer(isOpen: isOpen, enabled: enabled, drawer: drawer))
    }
}
