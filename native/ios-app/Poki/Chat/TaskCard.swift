import SwiftUI

// The task card, the approval card and the "Your turn" card (ESP-326 boards "03 Chat: Back in Poki
// mid-task", "04 Chat: Needs you", "05 Chat: Your turn"). They take plain values, so the chat, an outside
// agent's session and the screenshots' sample scenes draw the same thing.

/// How a task's card reads: Poki has the phone (blue), it waits for you (amber), or it is over.
enum TaskCardState: Equatable {
    case running, needsYou, yourTurn, done, failed, stopped

    /// From a plan's steps: `live` is the task under way; `waiting` and `handedOver` are what holds it.
    init(steps: [PlanStep], live: Bool, waiting: Bool, handedOver: Bool) {
        if live {
            if handedOver { self = .yourTurn }
            else if waiting || steps.contains(where: { $0.state == .waiting }) { self = .needsYou }
            else { self = .running }
        } else if steps.contains(where: { $0.state == .failed }) { self = .failed }
        else if steps.allSatisfy({ $0.state == .done }) { self = .done }
        else { self = .stopped }
    }
}

/// One task's steps. While Poki has the phone it is the blue card: the only large blue block in the
/// chat. Waiting for you or over, it folds to one row that opens on a tap.
struct TaskCard: View {
    var title: String
    var steps: [PlanStep]
    var state: TaskCardState
    /// The steps still to come, when the model published its whole plan.
    var upcoming: [String] = []
    /// The outside agent that asked; nil when you did.
    var asker: String? = nil
    var app: String? = nil
    var started: Date
    /// Nil until you fold or unfold it: a task that tripped starts unfolded, so the step it tripped on shows.
    @State private var open: Bool?
    @Environment(\.dynamicTypeSize) private var typeSize

    private var total: Int { steps.count + upcoming.count }
    private var finished: Int { steps.filter { $0.state == .done }.count }

    var body: some View {
        if state == .running { running } else { folded }
    }

    // MARK: Poki has the phone

    private var running: some View {
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                PokiBear(mood: .onYourPhone, small: true).frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: title).font(.headline).lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                    HStack(spacing: 0) {
                        if let app, !app.isEmpty { Text(verbatim: "\(app), ") }
                        Text(started, style: .timer).monospacedDigit()
                    }
                    .font(.footnote).opacity(0.85)
                }
                Spacer(minLength: 8)
                Text(verbatim: asker ?? String(localized: "You"))
                    .font(.caption.weight(.semibold)).lineLimit(1)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(.white.opacity(0.22), in: .capsule)
                    .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            }
            VStack(alignment: .leading, spacing: 9) {
                ForEach(steps) { step in
                    TaskStepRow(text: step.text, state: step.state, onBlue: true).transition(PlanMotion.stepTransition)
                }
                ForEach(Array(upcoming.enumerated()), id: \.offset) { _, text in
                    TaskStepRow(text: text, state: nil, onBlue: true)
                }
            }
            .animation(PlanMotion.enter, value: steps)
            if total > 1 {
                HStack(spacing: 12) {
                    ProgressView(value: Double(finished), total: Double(total)).tint(.white)
                        .animation(.easeInOut(duration: 0.4), value: finished)
                    Text("Step \(min(finished + 1, total)) of \(total)").font(.caption.weight(.medium)).monospacedDigit().opacity(0.9)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tint.blue, in: shape)
        // No shadow under the blue: in dark it reads as a glow. A hairline keeps the edge there.
        .overlay(shape.strokeBorder(Tint.ring, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    // MARK: Waiting for you, or over

    private var folded: some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        let waits = state == .needsYou || state == .yourTurn
        return DisclosureGroup(isExpanded: Binding(get: { open ?? (state == .failed) }, set: { open = $0 })) {
            VStack(alignment: .leading, spacing: 9) {
                ForEach(steps) { step in TaskStepRow(text: step.text, state: step.state, onBlue: false) }
                ForEach(Array(upcoming.enumerated()), id: \.offset) { _, text in
                    TaskStepRow(text: text, state: nil, onBlue: false)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 12)
        } label: {
            // At the accessibility text sizes the title wraps and the label goes under it.
            let big = typeSize.isAccessibilitySize
            HStack(spacing: 10) {
                mark
                VStack(alignment: .leading, spacing: big ? 4 : 1) {
                    Text(verbatim: title).font(.subheadline.weight(.semibold)).foregroundStyle(Color(.label)).lineLimit(big ? 3 : 1)
                    summary.font(.footnote).foregroundStyle(Color(.secondaryLabel)).lineLimit(big ? 2 : 1)
                    if waits, big { waitingLabel }
                }
                .multilineTextAlignment(.leading)
                Spacer(minLength: 6)
                if waits, !big { waitingLabel }
            }
        }
        .tint(Color(.tertiaryLabel))
        .padding(.vertical, 12).padding(.horizontal, 14)
        .background(Color(.secondarySystemGroupedBackground), in: shape)
        .overlay(shape.strokeBorder(waits ? Tint.amberLine : Color(.separator), lineWidth: 1))
    }

    private var waitingLabel: some View {
        Text(state == .yourTurn ? "Your turn" : "Needs you")
            .font(.caption.weight(.semibold)).foregroundStyle(Tint.amberInk).lineLimit(1)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Tint.amberSoft, in: .capsule)
    }

    @ViewBuilder private var mark: some View {
        switch state {
        case .needsYou: PokiAvatar(size: 36, mood: .needsYou)
        case .yourTurn: PokiAvatar(size: 36, mood: .yourTurn)
        case .failed: Image(systemName: "xmark.circle.fill").font(.title2).foregroundStyle(Tint.red)
        case .stopped: Image(systemName: "stop.circle.fill").font(.title2).foregroundStyle(Color(.tertiaryLabel))
        default: Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(Tint.green)
        }
    }

    private var summary: Text {
        let at = min(finished + 1, max(total, 1))
        switch state {
        case .done: return Text("Done in ^[\(steps.count) step](inflect: true)")
        case .failed: return Text("Tripped at step \(at)")
        case .stopped: return Text("Stopped at step \(at)")
        default: return total > 1 ? Text("Step \(at) of \(total)") : Text("Step \(at)")
        }
    }
}

/// One step of a task: a tick when done, a cross when it failed, a ring while under way, and a dimmer
/// ring for a step still to come (`state` nil).
private struct TaskStepRow: View {
    var text: String
    var state: PlanStep.State?
    var onBlue: Bool

    private var ink: Color { onBlue ? .white : Color(.label) }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            ZStack {
                switch state {
                case .done?:
                    if onBlue {
                        DrawingCheck(color: .white).frame(width: 13, height: 13).transition(PlanMotion.swapTransition)
                    } else {
                        Image(systemName: "checkmark").font(.footnote.weight(.bold)).foregroundStyle(Tint.green)
                    }
                case .failed?:
                    Image(systemName: "xmark").font(.footnote.weight(.bold)).foregroundStyle(onBlue ? .white : Tint.red)
                case .current?, .waiting?:
                    Image(systemName: "smallcircle.filled.circle").font(.footnote.weight(.semibold)).foregroundStyle(ink)
                        .transition(PlanMotion.swapTransition)
                case nil:
                    Image(systemName: "circle").font(.footnote).foregroundStyle(ink.opacity(0.5))
                }
            }
            .frame(width: 18)
            .animation(PlanMotion.swap, value: state)
            Text(verbatim: text)
                .font(state == .current || state == .waiting ? .subheadline.weight(.semibold) : .subheadline)
                .foregroundStyle(ink.opacity(state == nil ? 0.6 : state == .done ? 0.85 : 1))
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: Approval

/// A step waiting for your answer, above the message field: what is asked, where, the words or the
/// button it is about, how long it waits, and the two answers. Allow takes a hold, so a stray tap
/// never lets a step through.
struct ApprovalAskCard: View {
    var title: String
    var detail: String
    var quote: String
    var expires: Date?
    var answer: (Bool) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        // Side by side, or one above the other at the accessibility text sizes, as an alert's buttons.
        let answers = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                PokiAvatar(size: 44, mood: .needsYou)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(verbatim: title).font(.headline).foregroundStyle(Color(.label)).fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let expires, expires > Date() {
                            // The countdown keeps its own width, so the title does not jump each second.
                            Text(timerInterval: Date()...expires, countsDown: true)
                                .font(.footnote.weight(.semibold)).monospacedDigit().foregroundStyle(Tint.amberInk)
                                .multilineTextAlignment(.trailing)
                                .fixedSize()
                                .padding(.horizontal, 9).padding(.vertical, 4)
                                .background(Tint.amberSoft, in: .capsule)
                                .accessibilityLabel(Text("Time left"))
                        }
                    }
                    Text(verbatim: detail).font(.subheadline).foregroundStyle(Color(.secondaryLabel)).fixedSize(horizontal: false, vertical: true)
                }
            }
            if !quote.isEmpty {
                Text(verbatim: quote).font(.body).foregroundStyle(Color(.label))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10).padding(.horizontal, 12)
                    .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 14, style: .continuous))
            }
            answers {
                Button { answer(false) } label: {
                    Text("Don’t Allow").font(.body.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(QuietCapsuleButtonStyle())
                HoldToAllowButton { answer(true) }
            }
        }
        .padding(16)
        .cardGlass(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }
}

/// Touch and hold: the button fills from the leading edge and allows when it is full. VoiceOver and
/// Switch Control activate it directly, as they can't hold.
struct HoldToAllowButton: View {
    var action: () -> Void
    @State private var filled: CGFloat = 0
    @State private var pressing = false
    @State private var allowed = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Long enough to be meant, short enough not to drag.
    static let hold: Double = 0.7

    var body: some View {
        Text("Hold to Allow")
            .font(.body.weight(.semibold)).foregroundStyle(Tint.onSolid)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Tint.solid
                        Tint.onSolid.opacity(0.32).frame(width: geometry.size.width * filled)
                    }
                }
                .clipShape(.capsule)
            }
            .contentShape(.capsule)
            .scaleEffect(pressing && !reduceMotion ? 0.97 : 1)
            .animation(.snappy(duration: 0.2), value: pressing)
            .onLongPressGesture(minimumDuration: Self.hold, maximumDistance: 44) {
                allowed += 1
                action()
            } onPressingChanged: { down in
                pressing = down
                withAnimation(down ? .linear(duration: Self.hold) : .easeOut(duration: 0.2)) { filled = down ? 1 : 0 }
            }
            .sensoryFeedback(.success, trigger: allowed)
            .sensoryFeedback(.impact(weight: .light), trigger: pressing) { _, down in down }
            .accessibilityElement()
            .accessibilityLabel(Text("Allow"))
            .accessibilityHint(Text("Touch and hold to allow this step"))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { action() }
            .accessibilityIdentifier("approval.allow")
    }
}

// MARK: Your turn

/// Poki handed the phone back for something only you can do (a passcode, a password, Face ID): what
/// it asks, that it sends no input meanwhile, and the button that tells it to carry on.
struct TurnCard: View {
    var text: String
    var done: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                PokiAvatar(size: 44, mood: .yourTurn)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Your turn").font(.headline).foregroundStyle(Color(.label))
                    Text(verbatim: text).font(.subheadline).foregroundStyle(Color(.secondaryLabel)).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            // What the core keeps to while a step is handed over: no input is sent. It still reads the
            // screen (that is how it sees the step is over), so the card does not say it looks away.
            Label("I’m not tapping or typing while it’s your turn.", systemImage: "pause.circle")
                .font(.footnote).foregroundStyle(Tint.amberInk)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8).padding(.horizontal, 12)
                .background(Tint.amberSoft, in: .rect(cornerRadius: 12, style: .continuous))
            Button(action: done) { Text("Done, carry on") }
                .buttonStyle(SolidCapsuleButtonStyle())
                .accessibilityIdentifier("handoff.done")
        }
        .padding(16)
        .cardGlass(in: shape)
        .overlay(shape.strokeBorder(Tint.amberLine, lineWidth: 1))
    }
}

// MARK: Buttons and surfaces

/// Your own solid button: ink in light, white in dark. Blue stays Poki's.
struct SolidCapsuleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold)).foregroundStyle(Tint.onSolid)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(Tint.solid, in: .capsule)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

/// The quiet answer beside a solid one: a grey capsule.
struct QuietCapsuleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color(.label))
            .background(Color(.tertiarySystemFill), in: .capsule)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

extension View {
    /// A card floating over the conversation: Liquid Glass on iOS 26 and later, the regular material
    /// with a hairline before it.
    @ViewBuilder func cardGlass<S: InsettableShape>(in shape: S) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.regularMaterial, in: shape).overlay(shape.strokeBorder(Color(.separator), lineWidth: 0.5))
        }
    }
}
