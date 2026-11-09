// The Live Activity's views. The structure (one card per surface drawn from one presentation, the
// expanded island's content under the camera, the approval buttons, the compact status) is ported
// from AgentLiveActivityWidget.swift in Clarklevis1995/dsh-mobile (commit ebe19764,
// AgentLiveActivityWidget/AgentLiveActivityWidget.swift), MIT License, Copyright (c) 2026 Chaofan Li.
// The approval countdown, counted by the system with `Text(timerInterval:countsDown:)`, follows
// ios/AgentActivity/AgentActivityWidget.swift in onehumanbeing/esp32-iphone-agent (commit cc966294),
// MIT License, Copyright (c) 2026 Henry Yuan. Interpolated text, the phase spring and margins kept
// concentric with the island's corners are from leepokai/Codync (commit 848070d,
// apps/ios/Widgets/CodyncWidgets.swift), Copyright 2026 Po Kai Lee, Apache License 2.0. Poki adds the
// step line, the pairing code, the setup steps, the thumbnail and the bear avatar from ESP-139's
// board 02 and ESP-171's final Dynamic Island / Lock Screen boards, with ESP-162's shorter words.
// See THIRD_PARTY_NOTICES.md.
import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// Sizes (HIG, iPhone): the Lock Screen card and the expanded island are 371 points wide and at most
/// 160 tall; anything taller is cut. Every view here draws one `ActivityFace`, so the four
/// presentations always say the same thing. The sizes follow ESP-139's final board 02 and ESP-171's
/// final Dynamic Island / Lock Screen boards, for two lines of words (ESP-162).
enum ActivityMetrics {
    /// The Lock Screen card's padding: 14 top and bottom, 20 leading, 14 trailing.
    static let lockInsets = EdgeInsets(top: 14, leading: 20, bottom: 14, trailing: 14)
    /// The card's corner as iOS draws it, for the concentric corners inside it.
    static let lockCorner: CGFloat = 24
    /// Inside the card's padding, the two cards with a screenshot beside the words: the step line's
    /// and the approval's. Fixed, so the card does not grow when the first screenshot arrives.
    static let lockProgressContent: CGFloat = 90
    static let lockApprovalContent: CGFloat = 108
    /// The status row's height (the bear's), the content line's, and the gap between them.
    static let statusRow: CGFloat = 20
    static let contentLine: CGFloat = 25
    static let lineGap: CGFloat = 6
    /// The expanded island's margins inside its 44 point corners.
    static let islandInsets = EdgeInsets(top: 11, leading: 14, bottom: 16, trailing: 14)
    static let islandCorner: CGFloat = 44
    static let islandGap: CGFloat = 6
    /// iOS clips the expanded island's content to the island inset by about 13 points, with corners
    /// about 36 points round (measured on the iPhone 17 Pro simulator). At the board's margins the
    /// corners cut the bear, the meta's last letters and the ends of the last row, so those move in.
    /// The row beside the camera: extra room on the outer side.
    static let islandRowInset: CGFloat = 14
    /// The last row: extra room below it, more for the content line alone than for a row under it,
    /// and the step line and the setup steps narrower as well (the step line's first dot was cut).
    static func islandBottomExtra(_ bottom: ActivityFace.Bottom) -> CGFloat {
        switch bottom {
        case .none: 18
        default: 8
        }
    }
    static let islandLastRowInset: CGFloat = 10

    static let avatar: CGFloat = 20
    static let compactAvatar: CGFloat = 22
    /// A small phone beside the words, as tall as they are.
    static let thumbnail = CGSize(width: 37, height: lockProgressContent)
    static let approvalThumbnail = CGSize(width: 50, height: lockApprovalContent)
    /// Concentric with the card: its corner less the inset.
    static let thumbnailCorner = lockCorner - lockInsets.top

    static func buttonHeight(_ surface: ActivitySurface) -> CGFloat { surface == .lockScreen ? 44 : 38 }
    static let denyWidth: CGFloat = 96
    /// Stop at the end of the step line: a round button with the stop symbol.
    static let stop: CGFloat = 30

    static let dot: CGFloat = 8
    static let missedDot: CGFloat = 10
    static let lastDot: CGFloat = 12
    static let currentDot: CGFloat = 13
    static let dotSlot: CGFloat = 22
    static let line: CGFloat = 3
}

// MARK: Lock Screen & Non-Dynamic Island Top Banner

/// The Lock Screen (and non-Dynamic Island top banner) card, with its padding and the glass edge.
/// The widget adds the blue background tint.
struct LockScreenCard: View {
    var face: ActivityFace
    @Environment(\.isLuminanceReduced) private var dimmed
    private let theme = ActivityTheme.current

    var body: some View {
        content(face)
            .padding(ActivityMetrics.lockInsets)
            .foregroundStyle(theme.lock.text)
            .overlay { GlassEdge() }
            .environment(\.colorScheme, .dark)
            .animation(dimmed ? nil : ActivityMotion.phase, value: face)
            .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func content(_ face: ActivityFace) -> some View {
        switch face.bottom {
        case .approval, .progress:
            let approval = face.bottom.isApproval
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 0) {
                    StatusRow(face: face)
                    ContentLine(face: face, surface: .lockScreen)
                        .padding(.top, ActivityMetrics.lineGap)
                    Spacer(minLength: 8)
                    BottomControl(face: face, surface: .lockScreen)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if face.thumbnail {
                    Thumbnail(size: approval ? ActivityMetrics.approvalThumbnail : ActivityMetrics.thumbnail, corner: ActivityMetrics.thumbnailCorner)
                }
            }
            .frame(height: approval ? ActivityMetrics.lockApprovalContent : ActivityMetrics.lockProgressContent)
        default:
            VStack(alignment: .leading, spacing: ActivityMetrics.lineGap) {
                StatusRow(face: face)
                ContentLine(face: face, surface: .lockScreen)
                if face.bottom != .none {
                    BottomControl(face: face, surface: .lockScreen).padding(.top, 6)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 6)
        }
    }
}

/// The 1 point glass line around the blue card, brighter along the top, as on the website's cards.
private struct GlassEdge: View {
    private let theme = ActivityTheme.current
    var body: some View {
        ContainerRelativeShape()
            .strokeBorder(
                LinearGradient(colors: [theme.glassHighlight, theme.glassEdge, theme.glassEdge], startPoint: .top, endPoint: .bottom),
                lineWidth: 1)
            .allowsHitTesting(false)
    }
}

/// The Lock Screen's top row: the bear, the status word and the meta value (plus the caller badge).
private struct StatusRow: View {
    var face: ActivityFace
    private let theme = ActivityTheme.current
    var body: some View {
        HStack(spacing: 6) {
            BearMark(size: ActivityMetrics.avatar, ringed: true)
            Text(face.status)
                .font(theme.status)
                .foregroundStyle(theme.lock.color(face.tone))
                .lineLimit(1)
                .contentTransition(.interpolate)
            Spacer(minLength: 8)
            MetaView(meta: face.meta, surface: .lockScreen)
            if let caller = face.caller { CallerBadge(name: caller, size: 18) }
        }
        .frame(height: ActivityMetrics.avatar)
    }
}

/// The content line: the one thing in the large size, on one line.
private struct ContentLine: View {
    var face: ActivityFace
    var surface: ActivitySurface
    private let theme = ActivityTheme.current
    var body: some View {
        Text(face.content)
            .font(face.contentIsCode ? theme.content.monospacedDigit() : theme.content)
            .tracking(theme.contentTracking)
            .foregroundStyle(theme.palette(surface).text.opacity(face.stale ? 0.72 : 1))
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .frame(height: ActivityMetrics.contentLine)
            .contentTransition(face.contentIsCode ? .numericText() : .interpolate)
    }
}

extension ActivityFace.Bottom {
    var isApproval: Bool { if case .approval = self { true } else { false } }
}

// MARK: Dynamic Island, expanded

/// Beside the camera, left: the bear and the short status word.
struct IslandLeading: View {
    var face: ActivityFace
    @Environment(\.isLuminanceReduced) private var dimmed
    private let theme = ActivityTheme.current
    var body: some View {
        HStack(spacing: 6) {
            BearMark(size: ActivityMetrics.avatar)
            Text(face.shortStatus)
                .font(theme.status)
                .foregroundStyle(theme.island.color(face.tone))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .contentTransition(.interpolate)
        }
        .padding(.leading, ActivityMetrics.islandRowInset)
        .frame(maxHeight: .infinity, alignment: .center)
        .environment(\.colorScheme, .dark)
        .animation(dimmed ? nil : ActivityMotion.phase, value: face)
    }
}

/// Beside the camera, right: the meta value (and caller badge when an outside agent drives the phone).
struct IslandTrailing: View {
    var face: ActivityFace
    @Environment(\.isLuminanceReduced) private var dimmed
    var body: some View {
        HStack(spacing: 6) {
            MetaView(meta: face.meta, surface: .island)
            if let caller = face.caller { CallerBadge(name: caller, size: 18) }
        }
        .padding(.trailing, ActivityMetrics.islandRowInset)
        .frame(maxHeight: .infinity, alignment: .center)
        .environment(\.colorScheme, .dark)
        .animation(dimmed ? nil : ActivityMotion.phase, value: face)
    }
}

/// Under the camera: the content line and the step line, the setup steps, Handoff Done, or the approval's buttons.
struct IslandBottom: View {
    var face: ActivityFace
    @Environment(\.isLuminanceReduced) private var dimmed
    var body: some View {
        VStack(alignment: .leading, spacing: ActivityMetrics.islandGap) {
            ContentLine(face: face, surface: .island)
            BottomControl(face: face, surface: .island)
        }
        .padding(.bottom, ActivityMetrics.islandBottomExtra(face.bottom))
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(ActivityTheme.current.island.text)
        .environment(\.colorScheme, .dark)
        .animation(dimmed ? nil : ActivityMotion.phase, value: face)
    }
}

// MARK: Dynamic Island, compact and minimal

struct CompactLeading: View {
    var face: ActivityFace
    var body: some View {
        BearMark(size: ActivityMetrics.compactAvatar)
            .environment(\.colorScheme, .dark)
    }
}

/// A short value rather than a sentence, so it never truncates.
struct CompactTrailing: View {
    var face: ActivityFace
    private let theme = ActivityTheme.current
    var body: some View {
        let palette = theme.island
        Group {
            switch face.compact {
            case .text(let text, let tone):
                Text(text).font(theme.compact).foregroundStyle(palette.color(tone))
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .contentTransition(.numericText())
            case .code(let code):
                Text(code).font(theme.compactCode).foregroundStyle(palette.accent)
                    .lineLimit(1).minimumScaleFactor(0.8)
            case .countdown(let until):
                CountdownText(until: until, color: palette.approval, width: 42)
            case .elapsed(let since):
                ElapsedText(since: since, color: palette.approval, width: 42)
            case .symbol(let name, let tone):
                Image(systemName: name)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(palette.color(tone))
                    .contentTransition(.symbolEffect(.replace))
            }
        }
        .padding(.trailing, 4)
        .environment(\.colorScheme, .dark)
    }
}

/// Another app's activity shares the island: the one thing that matters, around the bear.
struct MinimalView: View {
    var face: ActivityFace
    private let theme = ActivityTheme.current
    var body: some View {
        Group {
            switch face.minimal {
            case .avatar:
                BearMark(size: ActivityMetrics.avatar)
            case .ring(let progress):
                ZStack {
                    Circle().stroke(theme.island.track, lineWidth: 2)
                    Circle().trim(from: 0, to: max(0.04, min(1, progress)))
                        .stroke(theme.island.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    BearMark(size: 16)
                }
                .frame(width: 24, height: 24)
            case .approval:
                ZStack {
                    Circle().strokeBorder(theme.approvalOutline, lineWidth: 2)
                    BearMark(size: 16)
                }
                .frame(width: 24, height: 24)
            case .problem:
                Image(systemName: "exclamationmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(theme.island.problem)
            }
        }
        .environment(\.colorScheme, .dark)
    }
}

// MARK: Pieces

/// The top-right value: text, the approval's countdown, a time of day, or elapsed handoff wait.
private struct MetaView: View {
    var meta: ActivityFace.Meta
    var surface: ActivitySurface
    private let theme = ActivityTheme.current
    var body: some View {
        let palette = theme.palette(surface)
        switch meta {
        case .none:
            EmptyView()
        case .text(let text):
            Text(text).font(theme.meta).foregroundStyle(palette.quiet)
                .lineLimit(1).minimumScaleFactor(0.8)
                .contentTransition(.numericText())
        case .countdown(let until):
            CountdownText(until: until, color: palette.approval, width: 46)
        case .clock(let date):
            Text(date, style: .time).font(theme.meta).foregroundStyle(palette.quiet)
                .lineLimit(1)
        case .elapsed(let since):
            ElapsedText(since: since, color: palette.approval, width: 46)
        }
    }
}

/// What sits at the bottom of a card: the step line, the approval's buttons, Handoff Done, or the setup steps.
private struct BottomControl: View {
    var face: ActivityFace
    var surface: ActivitySurface
    private let theme = ActivityTheme.current

    var body: some View {
        let palette = theme.palette(surface)
        switch face.bottom {
        case .none:
            EmptyView()
        case .progress(let outcomes, let current, let finished, let stop):
            HStack(spacing: 8) {
                // As many dots as fit beside the Lock Screen's thumbnail, or across the island.
                StepLine(outcomes: outcomes, current: current, finished: finished,
                         capacity: (surface == .lockScreen ? 12 : 14) - (stop ? 2 : 0), palette: palette)
                Spacer(minLength: 0)
                if stop { StopButton(surface: surface).transition(.opacity) }
            }
            // Stop's height whether or not it shows, so the card keeps its size when the run ends.
            .frame(height: ActivityMetrics.stop)
            .padding(.horizontal, surface == .island ? ActivityMetrics.islandLastRowInset : 0)
            .transition(.activityRow)
        case .approval(let id):
            ApprovalButtons(approvalID: id, surface: surface)
                .transition(.activityRow)
        case .handoff(let id):
            HandoffDoneButton(handoffID: id, surface: surface)
                .transition(.activityRow)
        case .segments(let number, let count):
            HStack(spacing: 4) {
                ForEach(1...max(1, count), id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(index < number ? palette.segmentDone : index == number ? palette.text : palette.track)
                        .frame(height: 4)
                }
            }
            .padding(.horizontal, surface == .island ? ActivityMetrics.islandLastRowInset : 0)
            .transition(.activityRow)
        }
    }
}

/// One dot per step on a 3 point line: plain when the step went through, larger and red when it did
/// not, the current step hollow. A finished run turns the line green and ends on a larger dot. The
/// newest steps are kept when they do not all fit.
private struct StepLine: View {
    var outcomes: [Bool]
    var current: Bool
    var finished: Bool
    var capacity: Int
    var palette: ActivityPalette
    private let theme = ActivityTheme.current

    var body: some View {
        let shown = Array(outcomes.suffix(max(0, capacity - (current ? 1 : 0))).enumerated())
        let slots = shown.count + (current ? 1 : 0)
        let slot = ActivityMetrics.dotSlot
        let line = finished ? palette.finished : theme.stepLine
        ZStack(alignment: .leading) {
            if slots > 1 {
                Capsule().fill(line)
                    .frame(width: CGFloat(slots - 1) * slot, height: ActivityMetrics.line)
                    .padding(.leading, slot / 2)
            }
            HStack(spacing: 0) {
                ForEach(shown, id: \.offset) { index, ok in
                    let last = finished && index == shown.count - 1 && ok
                    let size = last ? ActivityMetrics.lastDot : ok ? ActivityMetrics.dot : ActivityMetrics.missedDot
                    Circle()
                        .fill(ok ? line : theme.stepMissed)
                        .frame(width: size, height: size)
                        .frame(width: slot)
                }
                if current {
                    ZStack {
                        Circle().fill(theme.stepLine)
                        Circle().fill(theme.stepHole).padding(ActivityMetrics.line)
                    }
                    .frame(width: ActivityMetrics.currentDot, height: ActivityMetrics.currentDot)
                    .frame(width: slot)
                    .transition(.opacity)
                }
            }
        }
        .frame(height: 16)
        // The first dot's edge, not its slot, lines up with the text above.
        .padding(.leading, -(slot - ActivityMetrics.dot) / 2)
        .animation(ActivityMotion.phase, value: outcomes)
    }
}

/// Don’t Allow and Allow (ESP-171 and ESP-139 final boards). Allow asks for Face ID first (see
/// ApproveActionIntent), so it carries the Face ID glyph.
struct ApprovalButtons: View {
    var approvalID: String
    var surface: ActivitySurface
    private let theme = ActivityTheme.current

    var body: some View {
        let palette = theme.palette(surface)
        let height = ActivityMetrics.buttonHeight(surface)
        HStack(spacing: 8) {
            Button(intent: DenyActionIntent(approvalID: approvalID)) {
                Text(String(activity: "Don’t Allow"))
                    .font(theme.button)
                    .foregroundStyle(palette.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .frame(width: ActivityMetrics.denyWidth, height: height)
                    .background(palette.buttonFill, in: .capsule)
            }
            .buttonStyle(.plain)
            Button(intent: ApproveActionIntent(approvalID: approvalID)) {
                HStack(spacing: 6) {
                    Image(systemName: "faceid").font(.system(size: 16, weight: .medium)).foregroundStyle(theme.primaryIcon)
                    Text(String(activity: "Allow")).font(theme.button).foregroundStyle(palette.primaryText)
                }
                .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
                .background(palette.primaryFill, in: .capsule)
            }
            .buttonStyle(.plain)
        }
    }
}

/// The one button on the "Your turn" card: the person finished what the agent could not do, and the
/// agent carries on (HandoffDoneIntent).
struct HandoffDoneButton: View {
    var handoffID: String
    var surface: ActivitySurface
    private let theme = ActivityTheme.current

    var body: some View {
        let palette = theme.palette(surface)
        let height = ActivityMetrics.buttonHeight(surface)
        Button(intent: HandoffDoneIntent(handoffID: handoffID)) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark").font(.system(size: 14, weight: .bold)).foregroundStyle(palette.primaryText)
                Text(String(activity: "Done, carry on"))
                    .font(theme.button)
                    .foregroundStyle(palette.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
            .background(palette.primaryFill, in: .capsule)
        }
        .buttonStyle(.plain)
    }
}

/// Stop runner: stops the runner, and with it iOS's automation banner, until the agent's next request.
/// The stop symbol, no word; VoiceOver reads "Stop".
struct StopButton: View {
    var surface: ActivitySurface
    private let theme = ActivityTheme.current
    var body: some View {
        let palette = theme.palette(surface)
        Button(intent: StopRunnerIntent()) {
            Image(systemName: "stop.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(palette.text)
                .frame(width: ActivityMetrics.stop, height: ActivityMetrics.stop)
                .background(palette.buttonFill, in: .circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(activity: "Stop"))
    }
}

extension View {
    /// Liquid Glass on iOS 26 and later in the app process; WidgetKit's remote view archiver drops
    /// `glassEffect` subtrees in Live Activity extensions, so the widget uses the design board's
    /// translucent glass fill directly.
    @ViewBuilder func activityGlassSurface<S: Shape>(fill: Color, in shape: S) -> some View {
        #if POKI_APP
        if #available(iOS 26.0, *) {
            self.background(fill, in: shape)
                .glassEffect(.clear, in: shape)
        } else {
            self.background(fill, in: shape)
        }
        #else
        self.background(fill, in: shape)
        #endif
    }
}

/// An approval's time left, counted down by the system between updates.
private struct CountdownText: View {
    var until: Date
    var color: Color
    var width: CGFloat
    var body: some View {
        // No fixedSize on timer text: it blanks the whole card on iOS 26.
        Text(timerInterval: Countdown.range(until), countsDown: true)
            .font(ActivityTheme.current.countdown).foregroundStyle(color)
            .multilineTextAlignment(.trailing)
            .frame(width: width, alignment: .trailing)
    }
}

/// How long the agent has waited for the person, counted up by the system.
private struct ElapsedText: View {
    var since: Date
    var color: Color
    var width: CGFloat
    var body: some View {
        Text(timerInterval: since...since.addingTimeInterval(12 * 3600), countsDown: false)
            .font(ActivityTheme.current.countdown).foregroundStyle(color)
            .multilineTextAlignment(.trailing)
            .frame(width: width, alignment: .trailing)
    }
}

enum Countdown {
    /// Counting down to `until`. The start is fixed just under an hour before it (not "now", which the
    /// system may take at another moment than it draws), so the remaining time is always `until - now`.
    static func range(_ until: Date) -> ClosedRange<Date> { until.addingTimeInterval(-3599)...until }
}

/// The bear, round, like the website's avatar. On the blue Lock Screen card it carries a 1.5 point
/// white ring so the blue top of the avatar stands out from the card.
struct BearMark: View {
    var size: CGFloat
    var ringed: Bool = false
    var body: some View {
        Image("Bear").resizable().scaledToFill()
            .frame(width: size, height: size)
            .clipShape(.circle)
            .overlay {
                if ringed {
                    Circle().stroke(.white, lineWidth: 1.5)
                }
            }
            .accessibilityHidden(true)
    }
}

/// The latest screenshot, read from the App Group container and drawn like a small phone. The view is
/// drawn again with every update, so a new file shows in place, without a fade. Without a file it
/// draws a white tile of the same size, so the layout never jumps.
struct Thumbnail: View {
    /// The app's own previews draw this when there is no file (the widget never sets it).
    @MainActor static var previewImage: UIImage?
    var size: CGSize
    var corner: CGFloat
    private let theme = ActivityTheme.current
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        Group {
            if let image = (SharedContainer.thumbnailURL.flatMap { UIImage(contentsOfFile: $0.path) }) ?? Self.previewImage {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Color.white
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(shape)
        .overlay(shape.strokeBorder(theme.glassEdge, lineWidth: 1))
    }
}
