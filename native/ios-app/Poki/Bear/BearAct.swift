import RealityKit
import simd

/// What the three-dimensional bear plays for Poki's state, with its own joints and the faces the model
/// has (the closed eyes' arcs, the open mouth, the sparkles, the raised paw of its wave, plus
/// mouth expressions), on top of what it does by itself (`BearIdle`).
enum BearAct: Equatable {
    /// Standing by itself, looking about and doing its small things.
    case ready
    /// A paw by its chin, a tilted head, and a wavy mouth.
    case thinking
    /// Its head down over its paws, which tap away under its chin.
    case working
    /// A paw up, asking for an Allow.
    case asking
    /// The phone is yours for a step: it turns its head away and shuts its eyes, not looking.
    case waiting
    /// A task is done: it is pleased for a moment, then stands by itself again.
    case done
    /// A task went wrong: it is sad for a moment, then stands by itself again.
    case failed
    /// Off: asleep, its head on one side, its eyes shut.
    case paused
    /// Poki cannot reach the phone: a paw up beside its head, rubbing there, looking up, puzzled.
    case lost
    /// A paw up beside its ear, its head tilted, nodding now and then.
    case listening
    /// Its mouth moving as it talks.
    case speaking
    /// Set-up: it waves, its mouth open, the sparkles out.
    case hello
}

extension PokiMood {
    /// The bear's act for this state.
    var act: BearAct? {
        switch self {
        case .ready: .ready
        case .thinking: .thinking
        case .onYourPhone, .checking: .working
        case .needsYou: .asking
        case .yourTurn: .waiting
        case .done: .done
        case .tripped: .failed
        case .paused: .paused
        case .cantReach: .lost
        case .listening: .listening
        case .speaking: .speaking
        case .hello: .hello
        }
    }

    /// The faces the three-dimensional bear plays: all of them.
    var modelled: Bool { act != nil }
}

/// How the bear stands for an act, and what moves while it holds it, laid on top of the standing pose.
enum BearStance {
    /// The pose it holds. Done and gone wrong react once (`BearReaction`) and then stand as when ready.
    static func pose(_ act: BearAct) -> BearIdle.Pose {
        var p = BearIdle.Pose()
        switch act {
        case .ready, .done, .failed:
            break
        case .thinking:
            p.headPitch = -0.065; p.headRoll = 0.085; p.headYaw = 0.04
            p.gaze = [0.017, -0.002]
            // Left paw lifted snugly to chin side in the thinking posture.
            p.raise = 0.54; p.bend = 0.45; p.reach = 0.68
            p[.think] = 1
        case .working:
            p.headPitch = 0.14
            p.gaze = [0, -0.012]
            p.work = 1
        case .asking:
            p.headRoll = 0.08
            p.gaze = [0.006, 0.006]
            p.raise = 0.9
            p[.ask] = 1
        case .waiting:
            p.headYaw = 0.35; p.headPitch = 0.1
            // The head is turned and lowered onto the left paw, which goes down from under it.
            p.lower = [0.1, 0]
            p.shut = 1
        case .paused:
            p.headPitch = 0.18; p.headRoll = 0.22
            // The head hangs onto the right paw, which goes down from under it.
            p.lower = [0, 0.5]
            p.shoulders = -0.1
            p.shut = 1
            p[.sleep] = 1
        case .lost:
            p.headPitch = -0.1; p.headRoll = -0.1
            p.gaze = [-0.012, 0.014]
            p.raise = 0.9; p.reach = 0.5
        case .listening:
            p.headRoll = -0.04
            p.gaze = [-0.010, 0.004]
            p.raise = 0.8; p.reach = 0.3
        case .speaking:
            p.headPitch = -0.05
            p.mouth = 1
        case .hello:
            // Delight uses the raised paw, the sparkles, and a round mouth.
            p.raise = 1
            p.sparkles = 1
            p[.surprise] = 1
        }
        return p
    }

    /// What moves while it holds the act, `t` seconds into it.
    static func motion(_ act: BearAct, at t: TimeInterval) -> BearIdle.Pose {
        var p = BearIdle.Pose()
        switch act {
        case .ready, .done, .failed, .waiting:
            break
        case .thinking:
            // Non-repeating ponderous head tilt, trailing chin-paw micro-motion, and subtle synchronized gaze drift.
            p.headRoll = 0.036 * Float(sin(t * 1.35)) + 0.015 * Float(sin(t * 0.61 + 1.2))
            p.headPitch = 0.018 * Float(sin(t * 1.05 + 0.5))
            p.bend = 0.038 * Float(sin(t * 1.35 - 0.55))
            p.gaze = SIMD2(0.004 * Float(sin(t * 0.78)), 0.002 * Float(sin(t * 0.53 + 0.8)))
        case .working:
            p.tap = Float(sin(t * 2 * .pi * 2.5))
            p.headPitch = 0.02 * Float(sin(t * 2 * .pi * 1.25))
        case .asking:
            p.raise = 0.1 * Float(sin(t * 2 * .pi * 1.2))
        case .paused:
            p.headPitch = 0.03 * Float(sin(t * 2 * .pi / 4))
        case .lost:
            p.bend = 0.12 * Float(sin(t * 2 * .pi * 2))
        case .listening:
            let x = t.truncatingRemainder(dividingBy: 3.5)
            p.headPitch = x < 0.6 ? 0.06 * Float(sin(x / 0.6 * .pi)) : 0
        case .speaking:
            p.mouth = BearTalk.open(at: t) - 1
            p.headPitch = 0.02 * Float(sin(t * 7))
        case .hello:
            p.raise = 0.15 * Float(sin(t * 2 * .pi * 1.5)) - 0.15
        }
        return p
    }
}

/// The target ramp from one act's stance to the next: short continuous blend fed into `BearPoseFilter`
/// so the second-order springs add anticipation, elastic overshoot, and settle without jumping.
struct BearStanceChange {
    static let length: TimeInterval = 0.28
    private(set) var act: BearAct
    private var previous: BearAct
    private var since: TimeInterval
    private var from = BearIdle.Pose()

    init(_ act: BearAct, at now: TimeInterval) {
        self.act = act
        previous = act
        since = now - Self.length
    }

    mutating func go(to next: BearAct, at now: TimeInterval) {
        guard next != act else { return }
        from = pose(at: now)
        previous = act
        act = next
        since = now
    }

    func progress(at now: TimeInterval) -> Float { BearIdle.ease(Float((now - since) / Self.length)) }

    func changing(at now: TimeInterval) -> Bool { now - since < Self.length }

    func pose(at now: TimeInterval) -> BearIdle.Pose {
        let w = progress(at: now)
        let target = BearStance.pose(act) + BearStance.motion(act, at: now - since)
        if w >= 1 { return target }
        return from * (1 - w) + target * w
    }
}

/// How far the mouth is open as the bear talks, against open: syllables of uneven length and size, from
/// two slow waves that never line up.
enum BearTalk {
    static func open(at t: TimeInterval) -> Float {
        let a = abs(sin(t * 9.3)), b = 0.5 + 0.5 * sin(t * 2.3 + 0.7)
        return Float(0.3 + 0.7 * a * (0.55 + 0.45 * b))
    }
}

/// A reaction played once when the state changes, from wherever the bear is, and back to standing.
struct BearReaction: Equatable {
    enum Kind: Equatable { case joy, sorrow }
    let kind: Kind
    let start: TimeInterval

    static let rise: TimeInterval = 0.30, fall: TimeInterval = 0.45
    var hold: TimeInterval { kind == .joy ? 1.0 : 1.4 }
    var length: TimeInterval { Self.rise + hold + Self.fall }
    var end: TimeInterval { start + length }

    init?(_ act: BearAct, at now: TimeInterval) {
        switch act {
        case .done: kind = .joy
        case .failed: kind = .sorrow
        default: return nil
        }
        start = now
    }

    func weight(at t: TimeInterval) -> Float {
        let x = t - start
        if x <= 0 || x >= length { return 0 }
        if x < Self.rise { return BearIdle.ease(Float(x / Self.rise)) }
        if x < Self.rise + hold { return 1 }
        return 1 - BearIdle.ease(Float((x - Self.rise - hold) / Self.fall))
    }

    func pose(at t: TimeInterval) -> BearIdle.Pose {
        let w = weight(at: t)
        var p = BearIdle.Pose()
        guard w > 0 else { return p }
        let held = max(t - start - Self.rise, 0)
        switch kind {
        case .joy:
            p.arms = 0.75 * w
            p.smile = BearIdle.ease((w - 0.3) / 0.5)
            p.headPitch = -0.1 * w
            let hop = held < 0.8 ? Float(abs(sin(2.5 * .pi * held))) : 0
            p.bodyLift = 0.03 * hop * w
            p.shoulders = 0.12 * hop * w
            p.mouth = w
            p.sparkles = w
        case .sorrow:
            p.headPitch = 0.12 * w
            p.headRoll = 0.1 * w
            p.shoulders = -0.1 * w
            p.gaze = SIMD2(0, -0.010) * w
            p.scratch = w
            p.lower = [0.04 * w, 0]
            p.rub = held < hold ? Float(sin(2 * .pi * 3 * held)) : 0
            p[.sad] = w
        }
        return p
    }
}
