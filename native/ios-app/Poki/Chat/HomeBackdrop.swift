import SwiftUI

/// The light behind the chat (ESP-376, the owner's pick "fog blue"), two layers one over the other.
/// The conversation's ground is always there: a clean pale page with a faint brand-blue glow behind
/// the message field, under a quarter of the screen high, still unless Poki is at work. Over it, on the
/// home page, lies the home's light: paper white above, blue rising from the bottom edge, drifting
/// very slowly. Your first message makes the home's light sink 260 points and fade, so it seems to draw
/// back to the glow and stop there.
///
/// Points, colours, grain, bright edge and drift are the design's final table
/// (定稿-首页渐变和玻璃参数, sections 1 to 4, 9 and 10). The system's mesh was laid beside the
/// design's own rendering of the same table before anything was moved, and the table's points are
/// used as they are. Nothing in here may be wider than the page: a stack takes the width of its
/// widest layer and stretches the meshes to it, which is how the bright edge, laid in the stack at
/// its own 797 points, once showed only the middle half of the light. With Reduce Motion nothing
/// drifts or sinks; the change between the two is a fade.
struct HomeBackdrop: View {
    /// The home page is in front.
    var home: Bool
    /// Poki is at work in the conversation: its glow drifts.
    var working: Bool
    /// Stands still at rest, for laying a screenshot beside the design (`-pokiChat backdrop`).
    var frozen = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let dark = scheme == .dark
        let still = reduceMotion || frozen
        ZStack(alignment: .bottom) {
            Tint.page
            // Starting or stopping, the drift eases in and out over 600 ms; it never jumps back.
            DriftingMesh(mesh: .chat, dark: dark, drift: working && !home && !still ? 1 : 0)
                .animation(.easeInOut(duration: 0.6), value: working)
            DriftingMesh(mesh: .home, dark: dark, drift: home && !still ? 1 : 0)
                .overlay(alignment: .bottom) { EdgeLight(dark: dark) }
                .offset(y: home || reduceMotion ? 0 : 260)
                .opacity(home ? 1 : 0)
                .animation(HomeMotion.ground(reduceMotion), value: home)
        }
        .overlay { Grain.image.resizable(resizingMode: .tile).opacity(0.03).blendMode(.overlay) }
        .compositingGroup()
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// One of the two grids of the design's final table: four points across, five down.
struct LightMesh {
    /// Each row's height at its four points, from the top.
    var rows: [[Float]]
    /// How much lower the two middle rows sit in dark.
    var darkDrop: Float
    var light: [UInt32]
    var dark: [UInt32]

    static let columns = 4
    /// Where the points stand across the page: the two middle rows are a little out of line on
    /// purpose, so the edge of the light is not a regular arc.
    private static let across: [[Float]] = [[0, 0.34, 0.67, 1], [0, 0.34, 0.67, 1], [0, 0.32, 0.70, 1], [0, 0.36, 0.67, 1], [0, 0.34, 0.67, 1]]
    /// The four points that move (the middle of the third and fourth rows) and where in its turn each
    /// one starts, so the light does not sway as one piece.
    private static let moving: [(index: Int, phase: Double)] = [(9, 0), (10, .pi / 2), (13, .pi), (14, 3 * .pi / 2)]

    /// The home page (sections 1 and 4).
    static let home = LightMesh(
        rows: [[0, 0, 0, 0], [0.42, 0.44, 0.41, 0.43], [0.56, 0.60, 0.55, 0.59], [0.76, 0.80, 0.75, 0.81], [1, 1, 1, 1]], darkDrop: 0.02,
        light: [0xF5F7FA, 0xF5F7FA, 0xF5F7FA, 0xF5F7FA,
                0xF5F7FA, 0xF5F7FA, 0xF5F7FA, 0xF5F7FA,
                0xE4F0FC, 0xEDF3FB, 0xEAEEFB, 0xF0F2FA,
                0xA6D6FA, 0xB2D1FD, 0xB6C4FB, 0xC6CCF8,
                0x4AB2F7, 0x3A8CFE, 0x4878F6, 0x6C80F0],
        dark: [0x05070D, 0x05070D, 0x05070D, 0x05070D,
               0x05070D, 0x05070D, 0x05070D, 0x05070D,
               0x06101F, 0x071226, 0x08102A, 0x070C1C,
               0x0B3C8A, 0x0C4FC0, 0x173FB0, 0x14286E,
               0x1260D8, 0x1A6FF0, 0x2056E0, 0x2440B8])

    /// The conversation (section 10): the home's bottom colours taken 85 % of the way back to the
    /// page, starting three quarters of the way down.
    static let chat = LightMesh(
        rows: [[0, 0, 0, 0], [0.75, 0.76, 0.75, 0.76], [0.84, 0.86, 0.83, 0.85], [0.93, 0.94, 0.92, 0.94], [1, 1, 1, 1]], darkDrop: 0,
        light: [0xF5F8FC, 0xF5F8FC, 0xF5F8FC, 0xF5F8FC,
                0xF5F8FC, 0xF5F8FC, 0xF5F8FC, 0xF5F8FC,
                0xE8F3FC, 0xE7F0FC, 0xE8EEFC, 0xEBEFFB,
                0xDFEFFB, 0xDDEAFC, 0xDFE8FB, 0xE4E9FA,
                0xDBEEFB, 0xD9E8FC, 0xDBE5FB, 0xE0E6FA],
        dark: [0x05070D, 0x05070D, 0x05070D, 0x05070D,
               0x05070D, 0x05070D, 0x05070D, 0x05070D,
               0x060E1C, 0x070F1E, 0x070D1D, 0x070B1A,
               0x071227, 0x08142A, 0x081128, 0x090E23,
               0x07142B, 0x08172F, 0x09132D, 0x0A1027])

    /// The grid at time `t`: each moving point goes round a small ellipse about its own place, 3 % of
    /// the page at full `drift`, once in 14 seconds. The top and the bottom edge never move.
    func points(at t: TimeInterval, drift: Double, dark: Bool) -> [SIMD2<Float>] {
        var points: [SIMD2<Float>] = []
        for (r, row) in rows.enumerated() {
            let drop = dark && (r == 2 || r == 3) ? darkDrop : 0
            for (c, y) in row.enumerated() { points.append(SIMD2(Self.across[r][c], y + drop)) }
        }
        guard drift > 0 else { return points }
        let turn = 2 * Double.pi / 14
        for (index, phase) in Self.moving {
            points[index].x += Float(0.03 * drift * sin(t * turn + phase))
            points[index].y += Float(0.03 * drift * cos(t * turn * 0.8 + phase))
        }
        return points
    }
}

/// A mesh that drifts as far as `drift` says (0 still, 1 the full 3 %). `drift` animates, so the
/// light eases into its movement and back to rest; at rest the clock stops.
private struct DriftingMesh: View, Animatable {
    var mesh: LightMesh
    var dark: Bool
    var drift: Double
    var animatableData: Double {
        get { drift }
        set { drift = newValue }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: drift <= 0)) { context in
            MeshGradient(width: LightMesh.columns, height: mesh.rows.count,
                         points: mesh.points(at: context.date.timeIntervalSinceReferenceDate, drift: drift, dark: dark),
                         colors: (dark ? mesh.dark : mesh.light).map { Color(hex: $0) },
                         smoothsColors: true, colorSpace: .perceptual)
        }
    }
}

/// The design's soft falloff for its two lights: a Gaussian read off at these distances from the
/// centre, as shares of the centre's strength, gone at 1.2 times the radius.
enum SoftLight {
    static func stops(_ colour: Color, strength: Double) -> [Gradient.Stop] {
        [(0.0, 1.0), (0.25, 0.85), (0.5, 0.52), (0.75, 0.23), (1.0, 0.07), (1.2, 0.0)].map { at, share in
            Gradient.Stop(color: colour.opacity(strength * share), location: at / 1.2)
        }
    }
}

/// A bright line along the bottom edge of the home page: a flat ellipse of light, 332 by 33 points
/// about the middle of the edge.
private struct EdgeLight: View {
    var dark: Bool
    var body: some View {
        let colour = dark ? Color(hex: 0x9FD0FF) : .white
        EllipticalGradient(stops: SoftLight.stops(colour, strength: dark ? 0.45 : 0.40), center: .center,
                           startRadiusFraction: 0, endRadiusFraction: 0.5)
            .frame(width: 332 * 2.4, height: 33 * 2.4)
            .offset(y: 33 * 1.2)
            .allowsHitTesting(false)
    }
}

/// A tile of grey noise, made once: laid over a wide, pale gradient at 3 % it breaks up the bands
/// that eight bits per channel would show.
enum Grain {
    static let image: Image = {
        let side = 256
        var bytes = [UInt8](repeating: 0, count: side * side)
        var state: UInt64 = 0x9E3779B97F4A7C15
        for i in bytes.indices {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            bytes[i] = UInt8(truncatingIfNeeded: state >> 33)
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)
        let cg = provider.flatMap {
            CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: side,
                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                    provider: $0, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        }
        return cg.map { Image(decorative: $0, scale: 1) } ?? Image(systemName: "square")
    }()
}
