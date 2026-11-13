import RealityKit
import simd

/// What the three-dimensional bear plays for Poki's state, with its own joints and the faces the model
/// has (the closed eyes' arcs, the open mouth, the sparkles), on top of what it does by itself
/// (`BearIdle`). The model and its look are unchanged; each state means what its flat picture means.
enum BearAct: Equatable {
    /// Standing by itself: ready, and for now thinking and at work, as before.
    case ready
    /// A task is done: it is pleased for a moment, then stands by itself again.
    case done
    /// A task went wrong: it is sad for a moment, then stands by itself again.
    case failed
}

extension PokiMood {
    /// The bear's act for this state; nil for the faces the model does not play yet, which stay flat.
    var act: BearAct? {
        switch self {
        case .ready, .thinking, .onYourPhone, .checking: .ready
        case .done: .done
        case .tripped: .failed
        case .needsYou, .yourTurn, .paused, .cantReach, .listening, .speaking, .hello: nil
        }
    }

    /// The faces the three-dimensional bear plays. The others stay flat.
    var modelled: Bool { act != nil }
}

/// A reaction played once when the state changes, from wherever the bear is, and back to standing:
/// pleased when a task is done (its arms go up, its eyes smile as in a blink, its mouth opens, the
/// sparkles come out and it gives two little bounces), sad when one went wrong (as its flat picture: a
/// paw up at the side of its head, rubbing it, the head tilted and lowered, the eyes looking down). It comes in over a third of a second and goes over half a second, so a change of state is
/// never a jump.
struct BearReaction: Equatable {
    enum Kind: Equatable { case joy, sorrow }
    let kind: Kind
    let start: TimeInterval

    static let rise: TimeInterval = 0.35, fall: TimeInterval = 0.5
    var hold: TimeInterval { kind == .joy ? 1.0 : 1.4 }
    var length: TimeInterval { Self.rise + hold + Self.fall }
    var end: TimeInterval { start + length }

    init?(_ act: BearAct, at now: TimeInterval) {
        switch act {
        case .done: kind = .joy
        case .failed: kind = .sorrow
        case .ready: return nil
        }
        start = now
    }

    /// How far into it the bear is, from 0 (standing) to 1 (the reaction at its full).
    func weight(at t: TimeInterval) -> Float {
        let x = t - start
        if x <= 0 || x >= length { return 0 }
        if x < Self.rise { return BearIdle.ease(Float(x / Self.rise)) }
        if x < Self.rise + hold { return 1 }
        return 1 - BearIdle.ease(Float((x - Self.rise - hold) / Self.fall))
    }

    /// The pose laid on top of the standing one.
    func pose(at t: TimeInterval) -> BearIdle.Pose {
        let w = weight(at: t)
        var p = BearIdle.Pose()
        guard w > 0 else { return p }
        // Time into the hold, for what moves along while it is held.
        let held = max(t - start - Self.rise, 0)
        switch kind {
        case .joy:
            p.arms = 0.75 * w
            p.smile = BearIdle.ease((w - 0.3) / 0.5)
            p.headPitch = -0.1 * w
            let hop = held < 0.8 ? Float(abs(sin(2.5 * .pi * held))) : 0
            p.bodyLift = 0.03 * hop * w
            p.shoulders = 0.12 * hop * w
        case .sorrow:
            p.headPitch = 0.12 * w
            p.headRoll = 0.1 * w
            p.shoulders = -0.1 * w
            p.gaze = SIMD2(0, -0.006) * w
            p.scratch = w
            // The paw rubs the head, three times a second, while it is held.
            p.rub = held < hold ? Float(sin(2 * .pi * 3 * held)) : 0
        }
        return p
    }

    /// How far the mouth is open and the sparkles are out, from 0 to 1.
    func face(at t: TimeInterval) -> (mouth: Float, sparkles: Float) {
        guard kind == .joy else { return (0, 0) }
        let w = weight(at: t)
        return (w, w)
    }
}
