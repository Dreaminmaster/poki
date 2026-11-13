import RealityKit
import simd

/// What the bear does by itself while it stands there, so that it is alive without a tap: it breathes
/// (a breath every 3 to 4 seconds, each a little different), sways slowly, and every few seconds
/// looks to one side, tilts its head or looks up, then comes back. The waits, the sides and the sizes
/// are drawn at random, so it never runs as a loop. It moves the bear's own joints on top of the
/// model's standing pose: the body, the head, the shoulders and the pupils, never the whole model.
/// Angles are in radians and lengths in the model's metres.
struct BearIdle {
    struct Pose {
        var bodyLift: Float = 0, bodyRoll: Float = 0, bodyYaw: Float = 0
        var headYaw: Float = 0, headPitch: Float = 0, headRoll: Float = 0
        var shoulders: Float = 0
        /// Where the pupils look, sideways and up.
        var gaze = SIMD2<Float>(0, 0)
    }

    /// One look somewhere: it turns there, holds, and turns back.
    private struct Glance {
        var start: TimeInterval, rise: TimeInterval, hold: TimeInterval, fall: TimeInterval
        var pose: Pose
        var end: TimeInterval { start + rise + hold + fall }

        func weight(at t: TimeInterval) -> Float {
            let x = t - start
            if x <= 0 || x >= rise + hold + fall { return 0 }
            if x < rise { return BearIdle.ease(Float(x / rise)) }
            if x < rise + hold { return 1 }
            return 1 - BearIdle.ease(Float((x - rise - hold) / fall))
        }

        /// Turning, not holding still.
        func turning(at t: TimeInterval) -> Bool {
            let x = t - start
            return (0..<rise).contains(x) || (rise + hold..<rise + hold + fall).contains(x)
        }
    }

    private var glance: Glance?
    private var nextGlance: TimeInterval
    private var breath: Double = 0, breathAt: TimeInterval, breathLength: TimeInterval = 3.4
    private var lastSide: Float = Bool.random() ? 1 : -1

    init(now: TimeInterval) {
        nextGlance = now + .random(in: 1.5...3.5)
        breathAt = now
    }

    static func ease(_ x: Float) -> Float { let x = min(max(x, 0), 1); return x * x * (3 - 2 * x) }

    /// Turning its head somewhere, so worth drawing at the full rate; breathing and swaying alone are slow enough for a third of it.
    func busy(at t: TimeInterval) -> Bool { glance?.turning(at: t) ?? false }

    /// A hi is coming: whatever it is looking at, it turns back now, quickly.
    mutating func attend(at t: TimeInterval) {
        guard var g = glance, t < g.end else { return }
        let w = g.weight(at: t)
        g.pose = Self.scaled(g.pose, w)
        g.start = t - 0.0001; g.rise = 0.0001; g.hold = 0; g.fall = 0.3
        glance = g
        nextGlance = max(nextGlance, t + 3)
    }

    /// `blinking`: a look somewhere does not start while the bear blinks; it waits for the eyes to open.
    mutating func pose(at t: TimeInterval, blinking: Bool = false) -> Pose {
        breath += (t - breathAt) / breathLength
        breathAt = t
        if breath >= 1 { breath = breath.truncatingRemainder(dividingBy: 1); breathLength = .random(in: 3.0...4.2) }
        let inhale = Float(0.5 - 0.5 * cos(2 * .pi * breath))
        var p = Pose()
        p.bodyLift = 0.010 * inhale
        p.shoulders = 0.05 * inhale
        p.headPitch = -0.025 * inhale
        // A slow sway that never lines up with itself.
        p.bodyRoll = 0.020 * Float(sin(t * 0.83) * 0.6 + sin(t * 0.37 + 1.3) * 0.4)
        p.bodyYaw = 0.025 * Float(sin(t * 0.29 + 0.4))
        p.headYaw = 0.03 * Float(sin(t * 0.41 + 2.1))
        if !blinking, t >= nextGlance, glance.map({ t >= $0.end }) ?? true {
            let g = makeGlance(at: t)
            glance = g
            nextGlance = g.end + .random(in: 1.2...4.5)
        }
        if let g = glance {
            let w = g.weight(at: t)
            p.headYaw += g.pose.headYaw * w
            p.headPitch += g.pose.headPitch * w
            p.headRoll += g.pose.headRoll * w
            p.bodyYaw += g.pose.bodyYaw * w
            p.gaze += g.pose.gaze * w
        }
        return p
    }

    private mutating func makeGlance(at t: TimeInterval) -> Glance {
        // Mostly the other way from the last time.
        let side: Float = Int.random(in: 0..<4) == 0 ? lastSide : -lastSide
        lastSide = side
        var pose = Pose()
        switch Int.random(in: 0..<10) {
        case 0..<5: // a look to the side
            pose.headYaw = side * .random(in: 0.18...0.30)
            pose.bodyYaw = side * 0.05
            pose.headPitch = .random(in: -0.06...0.04)
            pose.gaze = SIMD2(side * 0.009, .random(in: -0.002...0.004))
        case 5..<8: // the head tilted, curious
            pose.headRoll = side * .random(in: 0.10...0.15)
            pose.headYaw = side * 0.06
            pose.gaze = SIMD2(side * 0.004, 0.003)
        default: // a look up
            pose.headPitch = -.random(in: 0.12...0.18)
            pose.headYaw = side * 0.08
            pose.gaze = SIMD2(side * 0.005, 0.008)
        }
        return Glance(start: t, rise: .random(in: 0.35...0.55), hold: .random(in: 0.8...2.0), fall: .random(in: 0.45...0.7), pose: pose)
    }

    /// The farthest a look to the side goes, `side` of the way toward one side (-1 to 1), with the
    /// sway's own turn on top, and nothing else.
    static func farthest(_ side: Float) -> Pose {
        var p = Pose()
        p.headYaw = side * (0.30 + 0.03)
        p.bodyYaw = side * (0.05 + 0.025)
        p.gaze = SIMD2(side * 0.009, 0)
        return p
    }

    private static func scaled(_ p: Pose, _ w: Float) -> Pose {
        var q = Pose()
        q.headYaw = p.headYaw * w; q.headPitch = p.headPitch * w; q.headRoll = p.headRoll * w
        q.bodyYaw = p.bodyYaw * w; q.gaze = p.gaze * w
        return q
    }
}

/// The joints `BearIdle` moves, found by name in the model's skeleton. A model without them stands still.
struct BearIdleJoints {
    let body: Int, head: Int
    let shoulders: (right: Int, left: Int)?
    /// The pupils and the smile's arcs, which look with them.
    let eyes: [Int]
    let pupils: [Int], arcs: [Int]

    init?(names: [String]) {
        func joint(_ name: String) -> Int? { names.firstIndex { $0 == name || $0.hasSuffix("/" + name) } }
        guard let body = joint("Body"), let head = joint("Head") else { return nil }
        self.body = body
        self.head = head
        if let right = joint("Shoulder_R"), let left = joint("Shoulder_L") { shoulders = (right, left) } else { shoulders = nil }
        pupils = ["Eye_R", "Eye_L"].compactMap(joint)
        arcs = ["SmileEye_R", "SmileEye_L"].compactMap(joint)
        eyes = pupils + arcs
    }

    /// How far a pupil moves for `gaze`: across and up the face, and forward as much as across, so
    /// that it stays in front of the face's curve and its white.
    static func shift(_ gaze: SIMD2<Float>) -> SIMD3<Float> { SIMD3(gaze.x, gaze.y, abs(gaze.x)) }

    /// The pupils' or the arcs' height where the blink is.
    func shut(_ blink: BearBlink.Moment, in joints: inout [Transform]) {
        if let height = blink.pupils { for joint in pupils where joint < joints.count { joints[joint].scale.y = height } }
        if let height = blink.arcs { for joint in arcs where joint < joints.count { joints[joint].scale.y = height } }
    }

    /// `pose` laid on the model's standing pose. In the model's joints y is up, z forward and x across.
    func apply(_ pose: BearIdle.Pose, to joints: inout [Transform]) {
        guard joints.count > max(body, head) else { return }
        joints[body].translation.y += pose.bodyLift
        joints[body].rotation *= simd_quatf(angle: pose.bodyYaw, axis: [0, 1, 0]) * simd_quatf(angle: pose.bodyRoll, axis: [0, 0, 1])
        joints[head].rotation *= simd_quatf(angle: pose.headYaw, axis: [0, 1, 0]) * simd_quatf(angle: pose.headPitch, axis: [1, 0, 0])
            * simd_quatf(angle: pose.headRoll, axis: [0, 0, 1])
        if let (right, left) = shoulders, joints.count > max(right, left) {
            joints[right].rotation *= simd_quatf(angle: -pose.shoulders, axis: [0, 0, 1])
            joints[left].rotation *= simd_quatf(angle: pose.shoulders, axis: [0, 0, 1])
        }
        let shift = Self.shift(pose.gaze)
        for eye in eyes where eye < joints.count { joints[eye].translation += shift }
    }
}
