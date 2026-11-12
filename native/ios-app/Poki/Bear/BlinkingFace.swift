import SwiftUI
import UIKit

/// The bear's face for Poki's state, alive: it blinks every few seconds, now and then twice, and
/// gives a small hop when its state changes (ESP-468). It fills the square it is given.
///
/// It is drawn from the bear's cutouts. Each face with open eyes has a copy with the pupils filled
/// with the eye's own white (PokiBearLids-<face>.png, made by scripts/make-bear-blink.py), and the
/// pupils of the cutout are laid back over it, so they can be squeezed shut. When the
/// three-dimensional bear arrives (ESP-319), its rendering takes the place of this view: Poki's
/// picture in the top bar and in the flight from the home page draw nothing else.
/// With Reduce Motion it neither blinks nor hops.
struct BlinkingFace: View {
    var mood: PokiMood
    /// The square's side. Given, not measured: measured inside the flight to the top bar, the bear
    /// lagged a beat behind its circle.
    var side: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 0 with the eyes open, 1 shut.
    @State private var shut = 0.0
    @State private var hop = 0

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let eyes = BearEyes.table[mood], !reduceMotion, let lids = BearEyes.lids(mood), let face = PokiMood.cutout(mood, small: true) {
                Image(uiImage: lids).resizable().interpolation(.high)
                ForEach(eyes.indices, id: \.self) { i in
                    let eye = eyes[i]
                    Image(uiImage: face).resizable().interpolation(.high)
                        .frame(width: side, height: side)
                        .mask(alignment: .topLeading) {
                            Ellipse().frame(width: eye.width * side, height: eye.height * side)
                                .offset(x: eye.minX * side, y: eye.minY * side)
                        }
                        // The lids close toward the lower part of the eye, as the sleeping face's do.
                        .scaleEffect(x: 1, y: 1 - 0.92 * shut, anchor: UnitPoint(x: eye.midX, y: eye.minY + eye.height * 0.62))
                }
            } else if let face = PokiMood.cutout(mood, small: true) {
                Image(uiImage: face).resizable().interpolation(.high)
            }
        }
        .frame(width: side, height: side)
        // A new face is just there: no animation around it may fade it in late.
        .animation(nil, value: mood)
        .keyframeAnimator(initialValue: 1.0, trigger: hop) { content, scale in
            content.scaleEffect(scale, anchor: .bottom)
        } keyframes: { _ in
            CubicKeyframe(0.9, duration: 0.09)
            SpringKeyframe(1.0, duration: 0.4, spring: .bouncy(duration: 0.4, extraBounce: 0.2))
        }
        .onChange(of: mood) { if !reduceMotion { hop += 1 } }
        .task(id: reduceMotion) { await blink() }
        .accessibilityHidden(true)
    }

    /// Blinks until the view goes: every 2.5 to 5.5 seconds, one time in four twice in a row.
    private func blink() async {
        guard !reduceMotion else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Double.random(in: 2.5...5.5)))
            for _ in 0..<(Int.random(in: 0..<4) == 0 ? 2 : 1) {
                guard !Task.isCancelled else { return }
                withAnimation(.easeIn(duration: 0.07)) { shut = 1 }
                try? await Task.sleep(for: .milliseconds(90))
                withAnimation(.easeOut(duration: 0.13)) { shut = 0 }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }
}

/// Where the pupils are on each face with open eyes, as fractions of the cutout's side, and the
/// pictures with them filled. The table is printed by scripts/make-bear-blink.py.
enum BearEyes {
    static func lids(_ mood: PokiMood) -> UIImage? { UIImage(named: "PokiBearLids-\(mood.rawValue)") }

    static let table: [PokiMood: [CGRect]] = [
        .hello: [CGRect(x: 0.2461, y: 0.4062, width: 0.1680, height: 0.1758), CGRect(x: 0.4883, y: 0.3867, width: 0.1641, height: 0.1758)],
        .ready: [CGRect(x: 0.2812, y: 0.3945, width: 0.1797, height: 0.1914), CGRect(x: 0.5352, y: 0.3945, width: 0.1797, height: 0.1914)],
        .thinking: [CGRect(x: 0.3125, y: 0.3086, width: 0.1562, height: 0.1719), CGRect(x: 0.6250, y: 0.3945, width: 0.1562, height: 0.1758)],
        .onYourPhone: [CGRect(x: 0.3047, y: 0.4570, width: 0.1562, height: 0.1523), CGRect(x: 0.5352, y: 0.4805, width: 0.1523, height: 0.1523)],
        .checking: [CGRect(x: 0.2930, y: 0.4141, width: 0.1797, height: 0.1875), CGRect(x: 0.5352, y: 0.4805, width: 0.1523, height: 0.1641)],
        .needsYou: [CGRect(x: 0.2500, y: 0.4219, width: 0.1602, height: 0.1719), CGRect(x: 0.4727, y: 0.4297, width: 0.1602, height: 0.1719)],
        .tripped: [CGRect(x: 0.3242, y: 0.4648, width: 0.1523, height: 0.1562), CGRect(x: 0.5820, y: 0.5000, width: 0.1523, height: 0.1562)],
        .cantReach: [CGRect(x: 0.3477, y: 0.4609, width: 0.1445, height: 0.1523), CGRect(x: 0.5977, y: 0.4258, width: 0.1406, height: 0.1484)],
        .listening: [CGRect(x: 0.2500, y: 0.3477, width: 0.1523, height: 0.1680), CGRect(x: 0.5117, y: 0.4297, width: 0.1562, height: 0.1719)],
        .speaking: [CGRect(x: 0.2773, y: 0.3789, width: 0.1719, height: 0.1836), CGRect(x: 0.5508, y: 0.3867, width: 0.1562, height: 0.1797)],
    ]
}
