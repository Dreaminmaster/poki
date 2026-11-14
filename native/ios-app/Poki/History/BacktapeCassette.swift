import SwiftUI
import UIKit

// Backtape's cassette (the owner, 2026-11-14, after an HTML sketch): one clear Liquid Glass shell,
// tinted by the colours of the apps used in the block under the playhead. It carries the time and the
// day in its top corners, the apps' icons between the reels, and pause, rewind, fast forward and now in
// its base. Nothing on the glass is glass itself: the wells, discs and hubs are plain fills.

/// Where the cassette's buttons send the playhead.
enum BacktapeMove {
    case back, forward, now
    case day(Date)
}

// MARK: Tint

/// The shell's colours: each app's own vivid colour, laid left to right in the order the apps were
/// used, each as wide as its share of the block. Colours between two apps follow the colour wheel, so
/// the mix never passes through grey.
@MainActor
enum BacktapeTint {
    private static var hues: [String: Double] = [:]

    /// The hue of an app's icon, weighted towards its colourful pixels. Without an icon, or for a
    /// grey one, a hue made from the app's name.
    static func hue(_ app: String) -> Double {
        if let hit = hues[app] { return hit }
        if let image = AppIconStore.shared.icon(app), let found = vivid(image) {
            hues[app] = found
            return found
        }
        var sum: UInt32 = 7
        for scalar in app.unicodeScalars { sum = sum &* 31 &+ scalar.value }
        return Double(sum % 360) / 360
    }

    private static func vivid(_ image: UIImage) -> Double? {
        guard let picture = image.cgImage else { return nil }
        let side = 16
        var data = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = data.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(picture, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }
        var red = 0.0, green = 0.0, blue = 0.0, total = 0.0
        for offset in stride(from: 0, to: data.count, by: 4) {
            let r = Double(data[offset]) / 255, g = Double(data[offset + 1]) / 255, b = Double(data[offset + 2]) / 255
            let weight = (max(r, g, b) - min(r, g, b)) * max(r, g, b)
            red += r * weight
            green += g * weight
            blue += b * weight
            total += weight
        }
        // Too little colour in the icon (black, white, grey) to name a hue.
        guard total > 6 else { return nil }
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        guard UIColor(red: red / total, green: green / total, blue: blue / total, alpha: 1)
            .getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha), saturation > 0.15 else { return nil }
        return Double(hue)
    }

    static func color(_ hue: Double) -> Color { Color(hue: hue - floor(hue), saturation: 0.74, brightness: 1) }

    /// A hue between two hues, the short way round the wheel.
    private static func between(_ a: Double, _ b: Double, _ t: Double) -> Double {
        var gap = b - a
        if gap > 0.5 { gap -= 1 }
        if gap < -0.5 { gap += 1 }
        return a + gap * t
    }

    /// The gradient of a block. Apps in the order they were first used, each with its share of reads.
    static func gradient(_ block: HistorySpan?) -> Gradient {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for entry in (block?.entries ?? []).reversed() where !entry.app.isEmpty {
            if counts[entry.app] == nil { order.append(entry.app) }
            counts[entry.app, default: 0] += 1
        }
        let apps = Array(order.prefix(4))
        guard let first = apps.first else {
            return Gradient(colors: [color(0.58), color(0.62)])
        }
        if apps.count == 1 {
            let hue = self.hue(first)
            return Gradient(colors: [color(hue - 0.04), color(hue), color(hue + 0.05)])
        }
        let total = Double(apps.reduce(0) { $0 + (counts[$1] ?? 0) })
        var centres: [Double] = []
        var passed = 0.0
        for app in apps {
            let share = Double(counts[app] ?? 0) / max(1, total)
            centres.append(passed + share / 2)
            passed += share
        }
        var stops: [Gradient.Stop] = []
        for (offset, app) in apps.enumerated() {
            let here = hue(app)
            stops.append(Gradient.Stop(color: color(here), location: centres[offset]))
            guard offset + 1 < apps.count else { continue }
            let next = hue(apps[offset + 1])
            for step in 1...4 {
                let t = Double(step) / 5
                stops.append(Gradient.Stop(color: color(between(here, next, t)), location: centres[offset] + (centres[offset + 1] - centres[offset]) * t))
            }
        }
        return Gradient(stops: stops)
    }

    /// The hue the hubs' teeth take: the block's first app.
    static func lead(_ block: HistorySpan?) -> Double {
        guard let app = block?.entries.last?.app, !app.isEmpty else { return 0.6 }
        return hue(app)
    }
}

// MARK: The cassette

struct BacktapeCassette: View {
    /// The block under the playhead, nil while nothing is kept.
    var block: HistorySpan?
    var index: Int
    /// 0 at the oldest block, 1 at the newest.
    var progress: Double
    /// Days on the tape, newest first.
    var days: [Date]
    var move: (BacktapeMove) -> Void
    @ObservedObject private var capture = HistoryCapture.shared

    init(block: HistorySpan?, index: Int, progress: Double, days: [Date], move: @escaping (BacktapeMove) -> Void) {
        self.block = block
        self.index = index
        self.progress = progress
        self.days = days
        self.move = move
    }

    private var paused: Bool { capture.isPaused || !capture.enabled }

    var body: some View {
        GeometryReader { box in
            let unit = box.size.width / 340
            let shape = RoundedRectangle(cornerRadius: 17 * unit, style: .continuous)
            ZStack {
                tint.clipShape(shape)
                reel(x: 108, fill: progress, unit: unit)
                reel(x: 232, fill: 1 - progress, unit: unit)
                icons(unit).position(x: 170 * unit, y: 100 * unit)
                base(unit)
                top(unit)
            }
            .frame(width: box.size.width, height: box.size.height)
            .foregroundStyle(.white)
            .glassSurface(in: shape, fallback: .card)
        }
        .aspectRatio(340.0 / 216.0, contentMode: .fit)
        .animation(.easeInOut(duration: 0.35), value: block?.id)
        .animation(.easeInOut(duration: 0.4), value: paused)
    }

    /// The colour in the glass. Paused, the cassette loses most of it.
    private var tint: some View {
        LinearGradient(gradient: BacktapeTint.gradient(block), startPoint: UnitPoint(x: 0, y: 0.25), endPoint: UnitPoint(x: 1, y: 0.75))
            .overlay(LinearGradient(colors: [.white.opacity(0.28), .white.opacity(0)], startPoint: .top, endPoint: .center))
            .saturation(paused ? 0.15 : 1)
            .opacity(paused ? 0.35 : 0.66)
            .id(block?.id)
            .transition(.opacity)
    }

    private func reel(x: CGFloat, fill: Double, unit: CGFloat) -> some View {
        let pack = (30 + 28 * CGFloat(min(1, max(0, fill)))) * unit
        let ink = Color(hue: BacktapeTint.lead(block), saturation: paused ? 0.1 : 0.6, brightness: 0.72)
        return ZStack {
            Circle().fill(.white.opacity(0.16)).overlay(Circle().strokeBorder(.white.opacity(0.45), lineWidth: 1))
                .frame(width: pack * 2, height: pack * 2)
            Circle().fill(.white.opacity(0.14)).overlay(Circle().strokeBorder(.white.opacity(0.6), lineWidth: 1.2))
                .frame(width: 54 * unit, height: 54 * unit)
            Circle().fill(.white.opacity(0.95)).frame(width: 32 * unit, height: 32 * unit)
            ForEach(0..<6, id: \.self) { tooth in
                Capsule().fill(ink)
                    .frame(width: 3.6 * unit, height: 6 * unit)
                    .offset(y: -11.5 * unit)
                    .rotationEffect(.degrees(Double(tooth) * 60 + Double(index) * 40))
            }
            Circle().fill(ink.opacity(0.5)).frame(width: 13 * unit, height: 13 * unit)
        }
        .position(x: x * unit, y: 100 * unit)
        .animation(.spring(duration: 0.4), value: index)
        .accessibilityHidden(true)
    }

    /// The apps of the block in one row between the reels, over the tape where they are wide.
    private func icons(_ unit: CGFloat) -> some View {
        HStack(spacing: 6 * unit) {
            ForEach(Array((block?.apps ?? []).prefix(4)), id: \.self) { app in
                AppIconView(app: app, size: 34 * unit)
                    .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
                    .contextMenu {
                        Text(verbatim: HistoryNames.app(app))
                        Button("Exclude from Backtape") { capture.exclude(app) }
                        Button("Delete This App's History", role: .destructive) { Task { await capture.clear(app: app) } }
                    }
            }
        }
    }

    private func top(_ unit: CGFloat) -> some View {
        VStack {
            HStack(spacing: 7 * unit) {
                Circle()
                    .fill(capture.status == .reading ? Color.red : Color.white.opacity(0.5))
                    .overlay(Circle().strokeBorder(.white.opacity(0.85), lineWidth: 1.5))
                    .frame(width: 9 * unit, height: 9 * unit)
                    .accessibilityLabel(Text(LocalizedStringKey(HistoryNames.status(capture.status))))
                Text(verbatim: (block?.start ?? Date()).formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(AppLocalization.locale)))
                    .font(.system(size: 19 * unit, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Spacer(minLength: 0)
                Menu {
                    ForEach(days, id: \.self) { day in
                        Button { move(.day(day)) } label: { Text(verbatim: Self.name(day)) }
                    }
                } label: {
                    HStack(spacing: 4 * unit) {
                        Text(verbatim: Self.name(block?.start ?? Date()))
                        Image(systemName: "chevron.down").font(.system(size: 10 * unit, weight: .bold))
                    }
                    .font(.system(size: 13 * unit, weight: .semibold))
                    .foregroundStyle(.white)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(days.isEmpty)
            }
            .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
            .padding(.horizontal, 17 * unit)
            .padding(.top, 14 * unit)
            Spacer(minLength: 0)
        }
    }

    private func base(_ unit: CGFloat) -> some View {
        ZStack {
            BacktapeBase().fill(.white.opacity(0.14))
            BacktapeBase().stroke(.white.opacity(0.4), lineWidth: 1)
            HStack(spacing: 8 * unit) {
                well(paused ? "play.fill" : "pause.fill", paused ? "Resume" : "Pause", unit) {
                    if !capture.enabled { return }
                    if capture.isPaused { capture.resume() } else { capture.pause(until: .distantFuture) }
                }
                well("backward.fill", "Rewind", unit) { move(.back) }.buttonRepeatBehavior(.enabled)
                well("forward.fill", "Fast Forward", unit) { move(.forward) }.buttonRepeatBehavior(.enabled)
                well("forward.end.fill", "Now", unit) { move(.now) }
            }
            .frame(width: 232 * unit)
            .position(x: 170 * unit, y: 181 * unit)
        }
    }

    private func well(_ symbol: String, _ name: String, _ unit: CGFloat, _ action: @escaping () -> Void) -> some View {
        let shape = RoundedRectangle(cornerRadius: 11 * unit, style: .continuous)
        return Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17 * unit, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
                .frame(maxWidth: .infinity)
                .frame(height: 42 * unit)
                .background(shape.fill(.white.opacity(0.2)))
                .overlay(shape.strokeBorder(.white.opacity(0.3), lineWidth: 1))
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(LocalizedStringKey(name)))
    }

    static func name(_ date: Date) -> String {
        date.formatted(Date.FormatStyle().weekday(.abbreviated).month(.abbreviated).day().locale(AppLocalization.locale))
    }
}

/// The trapezoid at the foot of a cassette, drawn on the cassette's own 340 by 216 grid.
private struct BacktapeBase: Shape {
    func path(in rect: CGRect) -> Path {
        let unit = rect.width / 340
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * unit, y: rect.minY + y * unit) }
        var path = Path()
        path.move(to: point(34, 216))
        path.addLine(to: point(47, 152))
        path.addQuadCurve(to: point(56, 145), control: point(48.5, 145))
        path.addLine(to: point(284, 145))
        path.addQuadCurve(to: point(293, 152), control: point(291.5, 145))
        path.addLine(to: point(306, 216))
        path.closeSubpath()
        return path
    }
}

// MARK: The tape

/// The slider: a tape of 10 minute blocks that runs under a fixed playhead. Each bar is as tall as its
/// block was busy, and the first block of each hour carries the hour.
struct BacktapeTape: View {
    /// Oldest first.
    var blocks: [HistorySpan]
    @Binding var selected: Date?

    private var peak: Int { min(60, max(1, blocks.map(\.entries.count).max() ?? 1)) }

    private var marks: Set<Date> {
        var found: Set<Date> = []
        var last = -1
        for block in blocks {
            let hour = Int(block.start.timeIntervalSince1970) / 3600
            if hour != last { found.insert(block.id) }
            last = hour
        }
        return found
    }

    var body: some View {
        let marks = self.marks
        let peak = self.peak
        GeometryReader { box in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .bottom, spacing: 0) {
                    ForEach(blocks) { block in
                        BacktapeCell(block: block, on: block.id == selected, peak: peak,
                                     label: marks.contains(block.id) ? block.start.formatted(Date.FormatStyle().hour().locale(AppLocalization.locale)) : nil)
                            .contentShape(Rectangle())
                            .onTapGesture { withAnimation(.snappy) { selected = block.id } }
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, max(0, box.size.width / 2 - BacktapeCell.width / 2), for: .scrollContent)
            .scrollPosition(id: $selected, anchor: .center)
            .scrollTargetBehavior(.viewAligned)
            .defaultScrollAnchor(.trailing)
            .mask(LinearGradient(stops: [
                .init(color: .clear, location: 0), .init(color: .black, location: 0.12),
                .init(color: .black, location: 0.88), .init(color: .clear, location: 1),
            ], startPoint: .leading, endPoint: .trailing))
        }
        .frame(height: 62)
        .padding(.top, 10)
    }
}

private struct BacktapeCell: View {
    static let width: CGFloat = 14
    var block: HistorySpan
    var on: Bool
    var peak: Int
    var label: String?

    var body: some View {
        VStack(spacing: 4) {
            Capsule()
                .fill(on ? Color.accentColor : Color.primary.opacity(0.26))
                .frame(width: on ? 5 : 3, height: 10 + 34 * CGFloat(min(block.entries.count, peak)) / CGFloat(peak))
                .frame(height: 44, alignment: .bottom)
            Color.clear.frame(height: 12).overlay(alignment: .leading) {
                if let label {
                    Text(verbatim: label).font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary).fixedSize()
                }
            }
        }
        .frame(width: Self.width)
        .animation(.snappy(duration: 0.2), value: on)
        .accessibilityElement()
        .accessibilityLabel(Text(verbatim: block.start.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(AppLocalization.locale))))
    }
}
