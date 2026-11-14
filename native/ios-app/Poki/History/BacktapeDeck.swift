import SwiftUI

// Backtape's deck (the owner, 2026-11-14: "use a slider ui for history. go creative and beautiful
// with liquid glass"). A tape of 10 minute blocks runs under a fixed playhead. Dragging it rewinds:
// the reels turn, the tape moves from one reel to the other, and the card above shows the block
// under the playhead. Tapping the card opens that block's reads.
//
// The deck is a control, so it is glass (see Glass.swift). What sits inside a glass surface is a
// plain fill or a tint, never more glass.

struct BacktapeDeck: View {
    /// Blocks of 10 minutes, oldest first.
    var blocks: [HistorySpan]
    /// The block to open, pushed by the page that owns the list.
    @Binding var opened: HistorySpan?
    @State private var selected: Date?

    private var index: Int {
        guard let selected, let found = blocks.firstIndex(where: { $0.id == selected }) else { return max(0, blocks.count - 1) }
        return found
    }

    private var current: HistorySpan? { blocks.indices.contains(index) ? blocks[index] : nil }

    /// How far along the tape the playhead is, 0 at the oldest block and 1 at the newest.
    private var progress: Double { blocks.count > 1 ? Double(index) / Double(blocks.count - 1) : 1 }

    /// The tallest bar stands for this many reads.
    private var peak: Int { min(60, max(1, blocks.map(\.entries.count).max() ?? 1)) }

    /// The first block of each hour, which carries the hour under its bar.
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

    /// Days on the tape, newest first.
    private var days: [Date] {
        var found: [Date] = []
        for block in blocks.reversed() {
            let day = Calendar.current.startOfDay(for: block.start)
            if found.last != day { found.append(day) }
        }
        return found
    }

    var body: some View {
        VStack(spacing: 12) {
            if let current { card(current) }
            tape
            controls
        }
        .glassGroup(spacing: 6)
        .padding(.vertical, 4)
        .sensoryFeedback(.selection, trigger: selected)
        .onAppear { settle() }
        .onChange(of: blocks.count) { _, _ in settle() }
    }

    /// Puts the playhead on the newest block when it is on none.
    private func settle() {
        if let selected, blocks.contains(where: { $0.id == selected }) { return }
        selected = blocks.last?.id
    }

    // MARK: The card

    private func card(_ block: HistorySpan) -> some View {
        let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)
        return Button { opened = block } label: {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    BacktapeReel(turn: Double(index) * 32, fill: progress)
                    Text(verbatim: block.start.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(AppLocalization.locale)))
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .frame(maxWidth: .infinity)
                    BacktapeReel(turn: Double(index) * 32, fill: 1 - progress)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: block.title).font(.headline).lineLimit(1)
                    Text(verbatim: block.summary).font(.subheadline).foregroundStyle(.secondary).lineLimit(3, reservesSpace: true)
                }
                HStack(spacing: 8) {
                    HistoryIcons(apps: block.apps)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .glassSurface(in: shape, interactive: true, fallback: .card)
        .animation(.snappy(duration: 0.25), value: index)
    }

    // MARK: The tape

    private var tape: some View {
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
        let marks = self.marks
        let peak = self.peak
        return GeometryReader { box in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .bottom, spacing: 0) {
                    ForEach(blocks) { block in
                        BacktapeCell(block: block, on: block.id == selected, peak: peak,
                                     label: marks.contains(block.id) ? hour(block.start) : nil)
                            .contentShape(Rectangle())
                            .onTapGesture { move(block) }
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, max(0, box.size.width / 2 - BacktapeCell.width / 2), for: .scrollContent)
            .scrollPosition(id: $selected, anchor: .center)
            .scrollTargetBehavior(.viewAligned)
            .defaultScrollAnchor(.trailing)
            // The tape fades out at both ends, as if it ran on behind the glass.
            .mask(LinearGradient(stops: [
                .init(color: .clear, location: 0), .init(color: .black, location: 0.12),
                .init(color: .black, location: 0.88), .init(color: .clear, location: 1),
            ], startPoint: .leading, endPoint: .trailing))
        }
        .frame(height: 74)
        .padding(.top, 14)
        .padding(.bottom, 8)
        .overlay(alignment: .top) {
            Image(systemName: "arrowtriangle.down.fill")
                .font(.system(size: 9))
                .foregroundStyle(Color.accentColor)
                .padding(.top, 6)
                .accessibilityHidden(true)
        }
        .glassSurface(in: shape, fallback: .card)
    }

    private func hour(_ date: Date) -> String {
        date.formatted(Date.FormatStyle().hour().locale(AppLocalization.locale))
    }

    // MARK: The controls

    private var controls: some View {
        HStack(spacing: 10) {
            round("gobackward.60", "Back One Hour") { jump(-3600) }
            Menu {
                ForEach(days, id: \.self) { day in
                    Button { go(day) } label: { Text(verbatim: name(day)) }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(verbatim: current.map { name($0.start) } ?? "").font(.subheadline.weight(.semibold)).lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                }
                .foregroundStyle(Color.primary)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .glassSurface(in: Capsule(), interactive: true)
            round("goforward.60", "Forward One Hour") { jump(3600) }
            round("forward.end.fill", "Latest") { move(blocks.last) }
        }
    }

    private func round(_ symbol: String, _ name: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassSurface(in: Circle(), interactive: true)
        .accessibilityLabel(Text(LocalizedStringKey(name)))
    }

    private func name(_ date: Date) -> String {
        date.formatted(Date.FormatStyle().weekday(.abbreviated).month(.abbreviated).day().locale(AppLocalization.locale))
    }

    private func move(_ block: HistorySpan?) {
        guard let block else { return }
        withAnimation(.snappy) { selected = block.id }
    }

    /// Moves the playhead by about `seconds`, to the nearest block that has reads.
    private func jump(_ seconds: TimeInterval) {
        guard let current else { return }
        let target = current.start.addingTimeInterval(seconds)
        if seconds < 0 {
            move(blocks.last(where: { $0.start <= target }) ?? blocks.first)
        } else {
            move(blocks.first(where: { $0.start >= target }) ?? blocks.last)
        }
    }

    /// Moves the playhead to the newest block of `day`.
    private func go(_ day: Date) {
        move(blocks.last(where: { Calendar.current.startOfDay(for: $0.start) == day }))
    }
}

/// One block on the tape: a bar as tall as the block is busy, and the hour under the first of each.
private struct BacktapeCell: View {
    static let width: CGFloat = 16
    var block: HistorySpan
    var on: Bool
    var peak: Int
    var label: String?

    var body: some View {
        VStack(spacing: 4) {
            Capsule()
                .fill(on ? Color.accentColor : Color.primary.opacity(0.28))
                .frame(width: on ? 5 : 3, height: 10 + 32 * CGFloat(min(block.entries.count, peak)) / CGFloat(peak))
                .frame(height: 42, alignment: .bottom)
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

/// A tape reel. It turns with the playhead, and holds more tape the nearer `fill` is to 1.
private struct BacktapeReel: View {
    var turn: Double
    var fill: Double

    var body: some View {
        let tape = 24 + 22 * CGFloat(min(1, max(0, fill)))
        ZStack {
            Circle().fill(Color.primary.opacity(0.12)).frame(width: tape, height: tape)
            Circle().fill(Color.primary.opacity(0.18)).frame(width: 20, height: 20)
            ForEach(0..<3, id: \.self) { spoke in
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 3, height: 7)
                    .offset(y: -5)
                    .rotationEffect(.degrees(Double(spoke) * 120 + turn))
            }
        }
        .frame(width: 46, height: 46)
        .animation(.spring(duration: 0.35), value: turn)
        .animation(.spring(duration: 0.35), value: fill)
        .accessibilityHidden(true)
    }
}
