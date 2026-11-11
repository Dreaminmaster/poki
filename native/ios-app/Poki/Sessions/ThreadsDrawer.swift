import SwiftUI
import UIKit

/// The conversations as a drawer from the leading edge of the chat (iPhone): it follows the finger,
/// the chat dims behind it, and a tap or a drag on the dimmed chat closes it. iOS has no drawer of its
/// own on iPhone, so this one is drawn; what is inside it is a system List.
///
/// A drag opens it only while the chat itself is in front (`enabled`): with a page pushed over the
/// chat, the leading edge belongs to the system's swipe back. The drawer's own rows keep their swipe
/// actions, so a drag closes it from the dimmed chat, not from the list.
struct ThreadsDrawer<Drawer: View>: ViewModifier {
    @Binding var isOpen: Bool
    var enabled: Bool
    @ViewBuilder var drawer: () -> Drawer

    @GestureState(resetTransaction: Transaction(animation: ThreadsDrawerMotion.settle)) private var pull: CGFloat?
    @State private var width: CGFloat = 320
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Where the content scrolls sideways by itself (`scrollsSideways`), in screen coordinates.
    @State private var sideways: [CGRect] = []
    /// How much of the drawer shows, 0 to its width.
    private var shown: CGFloat {
        min(width, max(0, (isOpen ? width : 0) + (pull ?? 0)))
    }

    func body(content: Content) -> some View {
        content
            .accessibilityHidden(isOpen)
            .simultaneousGesture(drag, including: enabled && !isOpen ? .all : .subviews)
            .onPreferenceChange(SidewaysScrollAreas.self) { sideways = $0 }
            .overlay {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Color.black.opacity(0.4 * shown / max(width, 1))
                            .ignoresSafeArea()
                            .contentShape(.rect)
                            .onTapGesture { set(false) }
                            .gesture(drag)
                            .allowsHitTesting(isOpen)
                            .accessibilityHidden(true)
                        drawer()
                            .frame(width: width)
                            .background(Color(.systemBackground).ignoresSafeArea())
                            // The drawer's edge against the chat: a hairline down its trailing side.
                            .overlay(alignment: .trailing) { Rectangle().fill(Color(.separator)).frame(width: 0.5).ignoresSafeArea() }
                            .offset(x: shown - width)
                            .accessibilityHidden(!isOpen)
                            .accessibilityAddTraits(.isModal)
                            .accessibilityAction(.escape) { set(false) }
                    }
                    .onAppear { width = Self.width(in: geometry.size.width) }
                    .onChange(of: geometry.size.width) { _, new in width = Self.width(in: new) }
                }
            }
            .sensoryFeedback(.impact(weight: .light), trigger: isOpen)
            .onChange(of: isOpen) { _, open in
                // The keyboard belongs to the chat's message field, not to the list over it.
                if open { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
            }
    }

    /// Most of the screen, with a strip of the chat left to tap; no wider than a comfortable list.
    private static func width(in screen: CGFloat) -> CGFloat { max(240, min(screen - 56, 360)) }

    private func set(_ open: Bool) {
        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : ThreadsDrawerMotion.settle) { isOpen = open }
    }

    /// The drag began on something that scrolls sideways itself (the home page's suggestion rows),
    /// and not at the screen's very edge: it is that row's, not the drawer's.
    private func scrolls(_ value: DragGesture.Value) -> Bool {
        !isOpen && value.startLocation.x > 24 && sideways.contains { $0.contains(value.startLocation) }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 16, coordinateSpace: .global)
            .updating($pull) { value, state, _ in
                let dx = value.translation.width
                if state == nil {
                    // A mostly sideways drag in the drawer's direction; an up or down one belongs to the scroll view.
                    guard abs(dx) > abs(value.translation.height) * 1.5, isOpen ? dx < 0 : dx > 0, !scrolls(value) else { return }
                }
                state = dx
            }
            .onEnded { value in
                let dx = value.translation.width
                guard abs(dx) > abs(value.translation.height) * 1.2, !scrolls(value) else { return }
                let thrown = value.predictedEndTranslation.width
                if isOpen {
                    if dx < -width * 0.3 || thrown < -width * 0.5 { set(false) }
                } else if dx > width * 0.3 || thrown > width * 0.5 {
                    set(true)
                }
            }
    }
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

enum ThreadsDrawerMotion {
    /// The spring the drawer settles with, whether let go or opened by its button.
    static let settle = Animation.snappy(duration: 0.32, extraBounce: 0)
}

extension View {
    func threadsDrawer<Drawer: View>(isOpen: Binding<Bool>, enabled: Bool, @ViewBuilder drawer: @escaping () -> Drawer) -> some View {
        modifier(ThreadsDrawer(isOpen: isOpen, enabled: enabled, drawer: drawer))
    }
}
