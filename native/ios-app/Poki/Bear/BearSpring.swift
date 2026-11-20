import Foundation
import simd

/// Parameters for a second-order damped spring with initial-response control (t3ssel8r formulation):
/// `frequency` sets responsiveness in Hz, `damping` < 1 adds elastic overshoot, and `response` < 0
/// adds subtle anticipation before moving toward a new target.
struct BearSpringParams: Equatable {
    var frequency: Float
    var damping: Float
    var response: Float

    static let body = BearSpringParams(frequency: 1.75, damping: 0.60, response: -0.80)
    static let head = BearSpringParams(frequency: 2.45, damping: 0.54, response: -1.20)
    static let arms = BearSpringParams(frequency: 2.75, damping: 0.52, response: -1.45)
    /// Critically damped and without anticipation: the eyes glide to wherever they look and settle
    /// there, never snapping, overshooting or twitching, whatever the target does.
    static let gaze = BearSpringParams(frequency: 2.6, damping: 1.0, response: 0)
    static let face = BearSpringParams(frequency: 4.50, damping: 0.76, response: 0.0)
}

/// Scalar second-order spring integrated with fixed-cap semi-implicit Euler substeps so variable
/// display rates (10–120 Hz) and state interruptions stay smooth and unconditionally stable.
struct SecondOrderSpring: Equatable {
    private static let maxSubstep: Float = 1.0 / 120.0
    private static let maxTargetVelocity: Float = 12.0

    let params: BearSpringParams
    private let k1: Float
    private let k2: Float
    private let k3: Float

    private var prevTarget: Float
    private(set) var value: Float
    private(set) var velocity: Float = 0

    init(_ params: BearSpringParams, initial: Float = 0) {
        self.params = params
        let f = max(params.frequency, 0.1)
        let omega = 2 * Float.pi * f
        k1 = 2 * params.damping / omega
        k2 = 1 / (omega * omega)
        k3 = params.response * params.damping / omega
        prevTarget = initial
        value = initial
    }

    var settled: Bool {
        abs(value - prevTarget) < 5e-4 && abs(velocity) < 5e-4
    }

    mutating func snap(to target: Float) {
        prevTarget = target
        value = target
        velocity = 0
    }

    @discardableResult
    mutating func step(dt: TimeInterval, target: Float) -> Float {
        guard dt > 1e-6 else { return value }
        let clampedDt = Float(min(dt, 0.25))
        let rawXd = (target - prevTarget) / clampedDt
        let xd = min(max(rawXd, -Self.maxTargetVelocity), Self.maxTargetVelocity)
        let startTarget = prevTarget
        prevTarget = target

        let steps = max(1, Int(ceil(clampedDt / Self.maxSubstep)))
        let h = clampedDt / Float(steps)
        let k2Stable = max(k2, h * h / 2 + h * k1 / 2, h * k1)

        for i in 1...steps {
            let frac = Float(i) / Float(steps)
            let x = startTarget + (target - startTarget) * frac
            value += h * velocity
            let accel = (x + k3 * xd - value - k1 * velocity) / k2Stable
            velocity += h * accel
        }
        return value
    }
}

/// Filters a target `BearIdle.Pose` through grouped second-order springs so eyes lead, the head and
/// paws show subtle anticipation and soft overshoot, and body weight follows through naturally.
struct BearPoseFilter {
    private var bodyLift = SecondOrderSpring(.body)
    private var bodyShiftX = SecondOrderSpring(.body)
    private var bodyRoll = SecondOrderSpring(.body)
    private var bodyYaw = SecondOrderSpring(.body)

    private var headYaw = SecondOrderSpring(.head)
    private var headPitch = SecondOrderSpring(.head)
    private var headRoll = SecondOrderSpring(.head)

    private var gazeX = SecondOrderSpring(.gaze)
    private var gazeY = SecondOrderSpring(.gaze)

    private var shoulders = SecondOrderSpring(.arms)
    private var arms = SecondOrderSpring(.arms)
    private var scratch = SecondOrderSpring(.arms)
    private var rub = SecondOrderSpring(.arms)
    private var bend = SecondOrderSpring(.arms)
    private var reach = SecondOrderSpring(.arms)
    private var work = SecondOrderSpring(.arms)
    private var tap = SecondOrderSpring(.arms)
    private var raise = SecondOrderSpring(.arms)
    private var lowerL = SecondOrderSpring(.arms)
    private var lowerR = SecondOrderSpring(.arms)

    private var smile = SecondOrderSpring(.face)
    private var shut = SecondOrderSpring(.face)
    private var mouth = SecondOrderSpring(.face)
    private var sparkles = SecondOrderSpring(.face)
    private var faces = Array(repeating: SecondOrderSpring(.face), count: 8)

    private var lastTime: TimeInterval?

    var active: Bool {
        !(bodyLift.settled && bodyShiftX.settled && bodyRoll.settled && bodyYaw.settled
          && headYaw.settled && headPitch.settled && headRoll.settled
          && gazeX.settled && gazeY.settled
          && shoulders.settled && arms.settled && raise.settled
          && bend.settled && reach.settled && faces.allSatisfy(\.settled))
    }

    mutating func reset(to pose: BearIdle.Pose, at now: TimeInterval) {
        lastTime = now
        bodyLift.snap(to: pose.bodyLift)
        bodyShiftX.snap(to: pose.bodyShiftX)
        bodyRoll.snap(to: pose.bodyRoll)
        bodyYaw.snap(to: pose.bodyYaw)
        headYaw.snap(to: pose.headYaw)
        headPitch.snap(to: pose.headPitch)
        headRoll.snap(to: pose.headRoll)
        gazeX.snap(to: pose.gaze.x)
        gazeY.snap(to: pose.gaze.y)
        shoulders.snap(to: pose.shoulders)
        arms.snap(to: pose.arms)
        scratch.snap(to: pose.scratch)
        rub.snap(to: pose.rub)
        bend.snap(to: pose.bend)
        reach.snap(to: pose.reach)
        work.snap(to: pose.work)
        tap.snap(to: pose.tap)
        raise.snap(to: pose.raise)
        lowerL.snap(to: pose.lower.x)
        lowerR.snap(to: pose.lower.y)
        smile.snap(to: pose.smile)
        shut.snap(to: pose.shut)
        mouth.snap(to: pose.mouth)
        sparkles.snap(to: pose.sparkles)
        for i in 0..<8 { faces[i].snap(to: pose.faces[i]) }
    }

    mutating func filter(_ target: BearIdle.Pose, at now: TimeInterval) -> BearIdle.Pose {
        guard let prev = lastTime else {
            reset(to: target, at: now)
            return target
        }
        let dt = now - prev
        lastTime = now
        if dt > 0.6 {
            reset(to: target, at: now)
            return target
        }
        var out = BearIdle.Pose()
        out.bodyLift = bodyLift.step(dt: dt, target: target.bodyLift)
        out.bodyShiftX = bodyShiftX.step(dt: dt, target: target.bodyShiftX)
        out.bodyRoll = bodyRoll.step(dt: dt, target: target.bodyRoll)
        out.bodyYaw = bodyYaw.step(dt: dt, target: target.bodyYaw)

        out.headYaw = headYaw.step(dt: dt, target: target.headYaw)
        out.headPitch = headPitch.step(dt: dt, target: target.headPitch)
        out.headRoll = headRoll.step(dt: dt, target: target.headRoll)

        out.gaze = SIMD2(
            gazeX.step(dt: dt, target: target.gaze.x),
            gazeY.step(dt: dt, target: target.gaze.y)
        )

        out.shoulders = shoulders.step(dt: dt, target: target.shoulders)
        out.arms = min(max(arms.step(dt: dt, target: target.arms), 0), 1.08)
        out.scratch = min(max(scratch.step(dt: dt, target: target.scratch), 0), 1.05)
        out.rub = rub.step(dt: dt, target: target.rub)
        out.bend = bend.step(dt: dt, target: target.bend)
        out.reach = reach.step(dt: dt, target: target.reach)
        out.work = min(max(work.step(dt: dt, target: target.work), 0), 1.05)
        out.tap = tap.step(dt: dt, target: target.tap)
        out.raise = min(max(raise.step(dt: dt, target: target.raise), -0.04), 1.06)
        out.lower = SIMD2(
            max(lowerL.step(dt: dt, target: target.lower.x), 0),
            max(lowerR.step(dt: dt, target: target.lower.y), 0)
        )

        out.smile = min(max(smile.step(dt: dt, target: target.smile), 0), 1)
        out.shut = min(max(shut.step(dt: dt, target: target.shut), 0), 1)
        out.mouth = min(max(mouth.step(dt: dt, target: target.mouth), 0), 1)
        out.sparkles = min(max(sparkles.step(dt: dt, target: target.sparkles), 0), 1)
        for i in 0..<8 { out.faces[i] = min(max(faces[i].step(dt: dt, target: target.faces[i]), 0), 1) }
        return out
    }
}
