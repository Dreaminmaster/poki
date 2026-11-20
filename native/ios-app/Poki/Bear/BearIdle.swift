import RealityKit
import simd

/// Mouth expressions from PokiBear-expressions.usdz. The joy reaction uses the model's own mouth.
enum BearFace: Int, CaseIterable {
    case think, sad, ask, sleep, surprise

    var prefix: String {
        switch self {
        case .think: "Expr_Think"
        case .sad: "Expr_Sad"
        case .ask: "Expr_Ask"
        case .sleep: "Expr_Sleep"
        case .surprise: "Expr_Surp"
        }
    }
}

/// What the bear does by itself while it stands there, so that it is alive without a tap:
/// organic asymmetric breathing, slow non-repeating weight shifts between feet, quick eye
/// micro-saccades that return to the viewer, and randomized small gestures where the eyes lead
/// before the head follows. All angles are in radians and lengths in model metres.
struct BearIdle {
    struct Pose: Equatable {
        var bodyLift: Float = 0, bodyShiftX: Float = 0, bodyRoll: Float = 0, bodyYaw: Float = 0
        var headYaw: Float = 0, headPitch: Float = 0, headRoll: Float = 0
        var shoulders: Float = 0
        /// Where the pupils look, sideways and up.
        var gaze = SIMD2<Float>(0, 0)
        /// How far both arms are up, from 0 (down) to 1: a paw out beside each cheek.
        var arms: Float = 0
        /// How far the eyes have gone to the smile's arcs, from 0 (open) to 1 (smiling).
        var smile: Float = 0
        /// How far the right paw is up beside the cheek, from 0 to 1, and how it rubs there (-1 to 1).
        var scratch: Float = 0, rub: Float = 0
        /// The raised left paw bent in toward the head, and brought forward, from 0 to 1: with `raise`,
        /// at the chin, the ear or the top of the head.
        var bend: Float = 0, reach: Float = 0
        /// Both paws down and forward from where they rest, working, from 0 to 1, and their tapping
        /// (-1 to 1): one goes down as the other comes up.
        var work: Float = 0, tap: Float = 0
        /// How far the left paw is up, as at the top of the model's wave.
        var raise: Float = 0
        /// How far the resting paws are turned down, out of the way of a head that comes down on them:
        /// the left one and the right one, in radians.
        var lower = SIMD2<Float>(0, 0)
        /// How far the eyes are shut, as a line, from 0 (open) to 1.
        var shut: Float = 0
        /// How far the mouth is open (from a quarter on), and the sparkles out, from 0 to 1.
        var mouth: Float = 0, sparkles: Float = 0
        /// How far each face (`BearFace`) is drawn over the bear's own, from 0 (none) to 1.
        var faces = SIMD8<Float>(repeating: 0)
        subscript(face: BearFace) -> Float {
            get { faces[face.rawValue] }
            set { faces[face.rawValue] = newValue }
        }

        static func + (a: Pose, b: Pose) -> Pose {
            var p = Pose()
            p.bodyLift = a.bodyLift + b.bodyLift; p.bodyShiftX = a.bodyShiftX + b.bodyShiftX
            p.bodyRoll = a.bodyRoll + b.bodyRoll; p.bodyYaw = a.bodyYaw + b.bodyYaw
            p.headYaw = a.headYaw + b.headYaw; p.headPitch = a.headPitch + b.headPitch; p.headRoll = a.headRoll + b.headRoll
            p.shoulders = a.shoulders + b.shoulders; p.gaze = a.gaze + b.gaze
            p.arms = a.arms + b.arms; p.smile = a.smile + b.smile
            p.scratch = a.scratch + b.scratch; p.rub = a.rub + b.rub
            p.bend = a.bend + b.bend; p.reach = a.reach + b.reach; p.work = a.work + b.work; p.tap = a.tap + b.tap
            p.raise = a.raise + b.raise; p.lower = a.lower + b.lower; p.shut = a.shut + b.shut
            p.mouth = a.mouth + b.mouth; p.sparkles = a.sparkles + b.sparkles
            p.faces = a.faces + b.faces
            return p
        }

        static func * (a: Pose, w: Float) -> Pose {
            var p = Pose()
            p.bodyLift = a.bodyLift * w; p.bodyShiftX = a.bodyShiftX * w
            p.bodyRoll = a.bodyRoll * w; p.bodyYaw = a.bodyYaw * w
            p.headYaw = a.headYaw * w; p.headPitch = a.headPitch * w; p.headRoll = a.headRoll * w
            p.shoulders = a.shoulders * w; p.gaze = a.gaze * w
            p.arms = a.arms * w; p.smile = a.smile * w
            p.scratch = a.scratch * w; p.rub = a.rub * w
            p.bend = a.bend * w; p.reach = a.reach * w; p.work = a.work * w; p.tap = a.tap * w
            p.raise = a.raise * w; p.lower = a.lower * w; p.shut = a.shut * w
            p.mouth = a.mouth * w; p.sparkles = a.sparkles * w
            p.faces = a.faces * w
            return p
        }
    }

    /// The small things it does, which take turns.
    enum Gesture: CaseIterable { case look, stretch, bounce, hum }

    /// One small thing: it goes into it, holds, and comes back. For `.look`, the eyes lead ahead of
    /// the head turning and return slightly ahead of the head settling back.
    private struct Glance {
        var gesture: Gesture
        var start: TimeInterval, rise: TimeInterval, hold: TimeInterval, fall: TimeInterval
        var pose: Pose
        /// How far a hum rocks the head, and to which side first.
        var size: Float = 0
        /// When a hi cut it short: from then it goes back in 0.25 s.
        var stop: TimeInterval?
        var end: TimeInterval { min(start + rise + hold + fall, stop.map { $0 + 0.25 } ?? .infinity) }

        /// Head/body weight with a short eye-lead delay on `.look` so eyes dart first, then head follows.
        func weight(at t: TimeInterval) -> Float {
            let lead: TimeInterval = gesture == .look ? 0.11 : 0
            let x = t - (start + lead)
            if x <= 0 || t >= end { return 0 }
            let cut = stop.map { 1 - BearIdle.ease(Float((t - $0) / 0.25)) } ?? 1
            let bodyRise = max(rise - lead, 0.14)
            if x < bodyRise { return BearIdle.ease(Float(x / bodyRise)) * cut }
            if x < bodyRise + hold { return cut }
            return (1 - BearIdle.ease(Float((x - bodyRise - hold) / max(fall, 0.14)))) * cut
        }

        /// Gaze weight starts immediately and returns slightly before the head settles back. It never
        /// moves faster than the eyes can follow smoothly: at least 0.25 s to go and 0.3 s to come back.
        func gazeWeight(at t: TimeInterval) -> Float {
            let x = t - start
            if x <= 0 || t >= end { return 0 }
            let cut = stop.map { 1 - BearIdle.ease(Float((t - $0) / 0.25)) } ?? 1
            let eyeRise = max(rise * 0.85, 0.25)
            let eyeHold = max(rise + hold - eyeRise - 0.08, 0.15)
            let eyeFall = max(fall * 0.8, 0.30)
            if x < eyeRise { return BearIdle.ease(Float(x / eyeRise)) * cut }
            if x < eyeRise + eyeHold { return cut }
            return (1 - BearIdle.ease(Float((x - eyeRise - eyeHold) / eyeFall))) * cut
        }

        func progress(at t: TimeInterval) -> Double { min(max((t - start) / max(rise + hold + fall, 1e-4), 0), 1) }

        func turning(at t: TimeInterval) -> Bool {
            guard t > start, t < end else { return false }
            if gesture != .look { return true }
            let x = t - start
            return x < rise + 0.08 || x >= rise + hold - 0.08
        }
    }

    /// Brief independent eye glance away from the viewer and back without turning the whole head. The
    /// eyes ease out and back over a third of a second or more, never faster, so they never twitch.
    private struct EyeDart {
        static let rise: TimeInterval = 0.30, fall: TimeInterval = 0.40
        var target: SIMD2<Float>
        var start: TimeInterval
        var hold: TimeInterval
        /// When something else took over: where the eyes were then, from which they ease back.
        var released: (at: TimeInterval, from: SIMD2<Float>)?
        var end: TimeInterval { released.map { $0.at + Self.fall } ?? start + Self.rise + hold + Self.fall }

        func offset(at t: TimeInterval) -> SIMD2<Float> {
            if let (at, from) = released {
                let x = t - at
                if x <= 0 { return from }
                return x >= Self.fall ? .zero : from * (1 - BearIdle.ease(Float(x / Self.fall)))
            }
            let x = t - start
            if x <= 0 || t >= end { return .zero }
            if x < Self.rise { return target * BearIdle.ease(Float(x / Self.rise)) }
            if x < Self.rise + hold { return target }
            return target * (1 - BearIdle.ease(Float((x - Self.rise - hold) / Self.fall)))
        }
    }

    /// Slow organic weight shift from one foot to the other on randomized intervals.
    private struct WeightShift {
        var from: Float = 0
        var to: Float = 0
        var start: TimeInterval
        var duration: TimeInterval = 1.6
        var nextChange: TimeInterval

        init(now: TimeInterval) {
            start = now
            nextChange = now + .random(in: 1.8...3.6)
        }

        mutating func value(at t: TimeInterval) -> Float {
            if t >= nextChange {
                from = current(at: t)
                let candidates: [Float] = [-1.0, -0.5, 0.0, 0.5, 1.0].filter { abs($0 - from) >= 0.45 }
                to = candidates.randomElement() ?? -from
                start = t
                duration = .random(in: 1.3...2.3)
                nextChange = t + duration + .random(in: 1.6...4.0)
            }
            return current(at: t)
        }

        private func current(at t: TimeInterval) -> Float {
            let w = BearIdle.ease(Float((t - start) / max(duration, 0.1)))
            return from + (to - from) * w
        }
    }

    private var glance: Glance?
    private var eyeDart: EyeDart?
    private var weightShift: WeightShift
    /// While the bear plays a state other than ready, it starts none of its small idle gestures.
    var calm = false
    private var nextGlance: TimeInterval
    private var nextEyeDart: TimeInterval
    private var breath: Double = 0, breathAt: TimeInterval, breathLength: TimeInterval = 3.4
    private var breathDepth: Float = 1.0
    private var lastSide: Float = Bool.random() ? 1 : -1
    /// The gestures still to come in this turn, each once; then a new turn in a new order.
    private var turn: [Gesture] = []
    private var lastGesture: Gesture?

    init(now: TimeInterval) {
        nextGlance = now + .random(in: 1.4...3.0)
        nextEyeDart = now + .random(in: 0.9...2.1)
        weightShift = WeightShift(now: now)
        breathAt = now
    }

    /// How far a resting paw is turned down for each radian the head tilts to its side, by itself: the
    /// left paw, the right paw. The paws rest a finger under the chin, the left one nearer: tilted onto
    /// one, the head went into it. These are the least that keep them out.
    static let tilt: (left: Float, right: Float) = (2, 0.4)

    static func ease(_ x: Float) -> Float { let x = min(max(x, 0), 1); return x * x * (3 - 2 * x) }

    /// Asymmetric organic breathing phase curve: fuller inhale (38%), gentle peak pause (8%),
    /// relaxed longer exhale (44%), soft rest at bottom (10%).
    static func breathCurve(_ phase: Double) -> Float {
        let p = phase.truncatingRemainder(dividingBy: 1)
        let u = p < 0 ? p + 1 : p
        if u < 0.38 {
            return ease(Float(u / 0.38))
        }
        if u < 0.46 {
            return 1
        }
        if u < 0.90 {
            return 1 - ease(Float((u - 0.46) / 0.44))
        }
        return 0
    }

    /// Turning its head somewhere, so worth drawing at the full rate. A blink due then waits for it
    /// to stop; the eyes darting do not hold one back.
    func busy(at t: TimeInterval) -> Bool { glance?.turning(at: t) ?? false }

    /// The eyes moving to or from a dart, worth drawing at the full rate too.
    func darting(at t: TimeInterval) -> Bool {
        guard let dart = eyeDart, t > dart.start, t < dart.end else { return false }
        return t < dart.start + EyeDart.rise || t >= dart.end - EyeDart.fall
    }

    /// Whatever the eyes were doing eases back to the middle instead of stopping where they were.
    private mutating func releaseDart(at t: TimeInterval) {
        guard var dart = eyeDart else { return }
        if t >= dart.end { eyeDart = nil; return }
        if dart.released == nil { dart.released = (t, dart.offset(at: t)) }
        eyeDart = dart
    }

    /// Something else plays until `t`: nothing of its own starts before then, and not at once after.
    mutating func rest(until t: TimeInterval) {
        nextGlance = max(nextGlance, t + .random(in: 1.0...2.0))
        nextEyeDart = max(nextEyeDart, t + .random(in: 0.8...1.6))
    }

    /// A hi is coming: whatever it is doing, it comes back now, quickly.
    mutating func attend(at t: TimeInterval) {
        releaseDart(at: t)
        guard var g = glance, t < g.end else { return }
        if g.stop == nil { g.stop = t }
        glance = g
        nextGlance = max(nextGlance, t + 3)
    }

    /// `blinking`: a look somewhere does not start while the bear blinks; it waits for the eyes to open.
    mutating func pose(at t: TimeInterval, blinking: Bool = false) -> Pose {
        breath += (t - breathAt) / breathLength
        breathAt = t
        if breath >= 1 {
            breath = breath.truncatingRemainder(dividingBy: 1)
            breathLength = .random(in: 2.9...4.3)
            breathDepth = .random(in: 0.86...1.16)
        }
        let inhale = Self.breathCurve(breath) * breathDepth
        var p = Pose()
        p.bodyLift = 0.015 * inhale
        p.shoulders = 0.068 * inhale
        p.headPitch = -0.030 * inhale

        // Slow non-repeating weight shift between feet + subtle organic sway.
        let shift = weightShift.value(at: t)
        let sway = Float(sin(t * 0.79) * 0.55 + sin(t * 0.33 + 1.4) * 0.45)
        p.bodyShiftX = 0.015 * shift + 0.004 * sway
        p.bodyRoll = -0.028 * shift + 0.014 * sway
        p.bodyYaw = 0.024 * Float(sin(t * 0.27 + 0.4))
        // Subtle counter-roll keeps the face balanced and alive as body weight shifts.
        p.headRoll = 0.016 * shift
        p.headYaw = 0.028 * Float(sin(t * 0.39 + 2.1))

        if calm, glance.map({ t >= $0.end }) ?? true {
            nextGlance = max(nextGlance, t + .random(in: 1.0...2.0))
            releaseDart(at: t)
        }

        // Independent micro-saccade eye darts when not already in a full head gesture.
        let gestureActive = glance.map { t < $0.end } ?? false
        if !blinking, !calm, !gestureActive, t >= nextEyeDart, eyeDart.map({ t >= $0.end }) ?? true {
            let side: Float = Bool.random() ? 1 : -1
            let gx = side * Float.random(in: 0.010...0.015)
            let gy = Float.random(in: -0.008...0.014)
            let dart = EyeDart(target: SIMD2(gx, gy), start: t, hold: .random(in: 0.55...1.45))
            eyeDart = dart
            nextEyeDart = dart.end + .random(in: 1.2...3.2)
        }
        if let dart = eyeDart {
            p.gaze += dart.offset(at: t)
        }

        if !blinking, !calm, t >= nextGlance, !gestureActive {
            releaseDart(at: t)
            let g = makeGlance(at: t)
            glance = g
            nextGlance = g.end + .random(in: 1.4...4.2)
            nextEyeDart = max(nextEyeDart, g.end + .random(in: 0.8...1.8))
        }
        if let g = glance {
            let w = g.weight(at: t)
            let gw = g.gazeWeight(at: t)
            p.headYaw += g.pose.headYaw * w
            p.headPitch += g.pose.headPitch * w
            p.headRoll += g.pose.headRoll * w
            p.bodyYaw += g.pose.bodyYaw * w
            p.bodyShiftX += g.pose.bodyShiftX * w
            p.gaze += g.pose.gaze * gw
            p.arms += g.pose.arms * w
            p.lower += g.pose.lower * w
            // The eyes smile once the arms are most of the way up, and open before they come down.
            p.smile += g.pose.smile * Self.ease((w - 0.35) / 0.5)
            let x = g.progress(at: t)
            switch g.gesture {
            case .bounce:
                // Two little elastic bounces, the second lighter.
                let hop = Float(abs(sin(2 * .pi * x))) * (x < 0.5 ? 1 : 0.68)
                p.bodyLift += 0.032 * hop * w
                p.shoulders += 0.13 * hop * w
            case .hum:
                // The head rocks side to side twice, the body follows a beat behind.
                let swell = Float(sin(.pi * x))
                let rock = g.size * Float(sin(4 * .pi * x)) * swell * w
                p.headRoll += rock
                p.lower.x += Self.tilt.left * max(-rock, 0)
                p.bodyRoll += 0.032 * Float(sin(4 * .pi * x - 0.65)) * swell * w
            case .look, .stretch:
                break
            }
        }
        return p
    }

    /// The next gesture: each once a turn, in a new order every turn, never the same twice in a row.
    mutating func nextGesture() -> Gesture {
        if turn.isEmpty {
            turn = Gesture.allCases.shuffled()
            if turn.first == lastGesture { turn.swapAt(0, turn.count - 1) }
        }
        let next = turn.removeFirst()
        lastGesture = next
        return next
    }

    private mutating func makeGlance(at t: TimeInterval) -> Glance {
        let side: Float = Int.random(in: 0..<4) == 0 ? lastSide : -lastSide
        lastSide = side
        var pose = Pose()
        switch nextGesture() {
        case .stretch:
            pose.arms = 1
            pose.smile = 1
            pose.headPitch = -0.14
            return Glance(gesture: .stretch, start: t, rise: .random(in: 0.55...0.75), hold: .random(in: 0.75...1.15), fall: .random(in: 0.55...0.75), pose: pose)
        case .bounce:
            return Glance(gesture: .bounce, start: t, rise: 0, hold: .random(in: 0.8...1.0), fall: 0, pose: pose)
        case .hum:
            return Glance(gesture: .hum, start: t, rise: 0, hold: .random(in: 2.0...2.6), fall: 0, pose: pose, size: side * .random(in: 0.085...0.115))
        case .look:
            break
        }
        switch Int.random(in: 0..<10) {
        case 0..<5: // a look to the side (eyes dart first, then head follows)
            pose.headYaw = side * .random(in: 0.16...0.28)
            pose.bodyYaw = side * 0.055
            pose.bodyShiftX = side * 0.010
            pose.headPitch = .random(in: -0.05...0.04)
            pose.gaze = SIMD2(side * 0.014, .random(in: -0.004...0.008))
        case 5..<8: // curious head tilt
            pose.headRoll = side * .random(in: 0.10...0.15)
            pose.lower = SIMD2(Self.tilt.left * max(-pose.headRoll, 0), Self.tilt.right * max(pose.headRoll, 0))
            pose.headYaw = side * 0.07
            pose.gaze = SIMD2(side * 0.014, 0.006)
        default: // a look up
            pose.headPitch = -.random(in: 0.11...0.17)
            pose.headYaw = side * 0.08
            pose.gaze = SIMD2(side * 0.014, 0.016)
        }
        return Glance(gesture: .look, start: t, rise: .random(in: 0.30...0.48), hold: .random(in: 0.8...1.8), fall: .random(in: 0.38...0.60), pose: pose)
    }

    /// The farthest a look to the side goes, `side` of the way toward one side (-1 to 1), with the
    /// sway's own turn on top, and nothing else.
    static func farthest(_ side: Float) -> Pose {
        var p = Pose()
        p.headYaw = side * (0.28 + 0.03)
        p.bodyYaw = side * (0.055 + 0.024)
        p.gaze = SIMD2(side * 0.014, 0)
        return p
    }
}

/// The joints `BearIdle` moves, found by name in the model's skeleton. A model without them stands still.
struct BearIdleJoints {
    let body: Int, head: Int
    let shoulders: (right: Int, left: Int)?
    /// The pupils and the smile's arcs, separated by side for independent sclera containment.
    let pupilR: Int?, pupilL: Int?
    let arcR: Int?, arcL: Int?
    let eyes: [Int]
    let pupils: [Int], arcs: [Int]
    /// The closed mouth and the open one, and the three sparkles.
    let mouths: [Int], sparkles: [Int]
    /// The upper arms and forearms, right and left.
    let arms: (upper: (right: Int, left: Int), fore: (right: Int, left: Int))?

    init?(names: [String]) {
        func joint(_ name: String) -> Int? { names.firstIndex { $0 == name || $0.hasSuffix("/" + name) } }
        guard let body = joint("Body"), let head = joint("Head") else { return nil }
        self.body = body
        self.head = head
        if let right = joint("Shoulder_R"), let left = joint("Shoulder_L") { shoulders = (right, left) } else { shoulders = nil }
        pupilR = joint("Eye_R")
        pupilL = joint("Eye_L")
        arcR = joint("SmileEye_R")
        arcL = joint("SmileEye_L")
        pupils = [pupilR, pupilL].compactMap { $0 }
        arcs = [arcR, arcL].compactMap { $0 }
        eyes = pupils + arcs
        mouths = ["Mouth", "MouthOpen"].compactMap(joint)
        sparkles = ["Spark_1", "Spark_2", "Spark_3"].compactMap(joint)
        if let ur = joint("UpperArm_R"), let ul = joint("UpperArm_L"), let fr = joint("Forearm_R"), let fl = joint("Forearm_L") {
            arms = ((ur, ul), (fr, fl))
        } else {
            arms = nil
        }
    }

    /// How far back the model's own blink puts the pupils, and forward the arcs, to swap them.
    static let swap: Float = 0.22
    /// How far the forearms turn down for work, and how far each way from there as the paws tap: they
    /// only ever go down from where they rest, so they stay out of the head and in sight under it.
    static let work: (down: Float, tap: Float, nod: Float) = (0.2, 0.2, 2)
    /// Both arms up, `arms` at 1: how far each goes along the model's wave, and how far its paw then
    /// comes in toward the cheek, as `bend` and `reach` bring it.
    static let cheer: (raise: Float, bend: Float, reach: Float) = (0.8, 0.2, 0.3)
    /// The right paw rubbing (`scratch` at 1): how far it goes along the wave, to beside the cheek, and
    /// how far its forearm turns each way as it rubs.
    static let scratch: (raise: Float, rub: Float) = (0.5, 0.12)

    /// The raised paws, the open mouth and the sparkles, as the model has them at the top of its wave
    /// (`hello`). Laid before `apply`, which turns the joints from where these leave them.
    func show(_ pose: BearIdle.Pose, from hello: [Transform], in joints: inout [Transform]) {
        func toward(_ joint: Int, _ b: Transform, _ w: Float) {
            guard joint < joints.count, w > 0 else { return }
            let a = joints[joint], w = min(w, 1)
            joints[joint] = Transform(scale: simd_mix(a.scale, b.scale, SIMD3(repeating: w)), rotation: simd_slerp(a.rotation, b.rotation, w),
                                      translation: simd_mix(a.translation, b.translation, SIMD3(repeating: w)))
        }
        for joint in sparkles where joint < hello.count { toward(joint, hello[joint], pose.sparkles) }
        var sides: [(left: Int, right: Int)] = []
        if let (right, left) = shoulders { sides.append((left, right)) }
        if let (upper, fore) = arms { sides += [(upper.left, upper.right), (fore.left, fore.right)] }
        for (left, right) in sides where max(left, right) < min(joints.count, hello.count) {
            let from = joints[left], to = hello[left], turn = to.rotation * from.rotation.inverse
            let mirrored = Transform(scale: joints[right].scale * to.scale / from.scale,
                                     rotation: simd_quatf(ix: turn.imag.x, iy: -turn.imag.y, iz: -turn.imag.z, r: turn.real) * joints[right].rotation,
                                     translation: joints[right].translation + (to.translation - from.translation) * SIMD3(-1, 1, 1))
            toward(left, to, max(pose.raise + Self.cheer.raise * pose.arms, 0))
            toward(right, mirrored, max(Self.cheer.raise * pose.arms + Self.scratch.raise * pose.scratch, 0))
        }
        if pose.mouth >= 0.25 {
            for joint in mouths where joint < joints.count && joint < hello.count { joints[joint] = hello[joint] }
            if let open = mouths.last, open < joints.count { joints[open].scale.y *= min(pose.mouth, 1) }
        }
    }

    /// The pupils' or the arcs' height where the blink is.
    func shut(_ blink: BearBlink.Moment, in joints: inout [Transform]) {
        if let height = blink.pupils { for joint in pupils where joint < joints.count { joints[joint].scale.y = height } }
        if let height = blink.arcs { for joint in arcs where joint < joints.count { joints[joint].scale.y = height } }
    }

    /// `pose` laid on the model's standing pose. In the model's joints y is up, z forward and x across.
    func apply(_ pose: BearIdle.Pose, to joints: inout [Transform]) {
        guard joints.count > max(body, head) else { return }
        joints[body].translation.x += pose.bodyShiftX
        joints[body].translation.y += pose.bodyLift
        joints[body].rotation *= simd_quatf(angle: pose.bodyYaw, axis: [0, 1, 0]) * simd_quatf(angle: pose.bodyRoll, axis: [0, 0, 1])
        joints[head].rotation *= simd_quatf(angle: pose.headYaw, axis: [0, 1, 0]) * simd_quatf(angle: pose.headPitch, axis: [1, 0, 0])
            * simd_quatf(angle: pose.headRoll, axis: [0, 0, 1])
        if let (right, left) = shoulders, joints.count > max(right, left) {
            joints[right].rotation *= simd_quatf(angle: -pose.shoulders, axis: [0, 0, 1])
            joints[left].rotation *= simd_quatf(angle: pose.shoulders, axis: [0, 0, 1])
        }

        // Keep the shared gaze inside both eyes as the pupils move over the curved face.
        let eyeTransforms = BearEyeBounds.transforms(
            desiredGaze: pose.gaze,
            headYaw: pose.headYaw,
            headPitch: pose.headPitch
        )
        if let idx = pupilR, idx < joints.count {
            joints[idx].translation += eyeTransforms.right.translation
            joints[idx].rotation = eyeTransforms.right.rotation * joints[idx].rotation
        }
        if let idx = pupilL, idx < joints.count {
            joints[idx].translation += eyeTransforms.left.translation
            joints[idx].rotation = eyeTransforms.left.rotation * joints[idx].rotation
        }
        // Closed-eye/smile arcs stay centered in the sockets, following only gently with the shared gaze.
        let arcRTransform = BearEyeBounds.spherical(side: .right, gazeDelta: eyeTransforms.right.gazeDelta * 0.25)
        let arcLTransform = BearEyeBounds.spherical(side: .left, gazeDelta: eyeTransforms.left.gazeDelta * 0.25)
        if let idx = arcR, idx < joints.count {
            joints[idx].translation += arcRTransform.translation
            joints[idx].rotation = arcRTransform.rotation * joints[idx].rotation
        }
        if let idx = arcL, idx < joints.count {
            joints[idx].translation += arcLTransform.translation
            joints[idx].rotation = arcLTransform.rotation * joints[idx].rotation
        }

        // Hide the default smile mouth while a face that draws its own mouth is shown. Done keeps the
        // model's open mouth, so it is not among them.
        if BearFace.allCases.contains(where: { pose[$0] > 0.35 }), pose.mouth < 0.25, let closedMouth = mouths.first, closedMouth < joints.count {
            joints[closedMouth].translation.z -= Self.swap
        }

        if let (upper, fore) = arms, joints.count > max(upper.right, upper.left, fore.right, fore.left) {
            let resting = max(1 - pose.arms, 0)
            joints[fore.left].rotation *= simd_quatf(angle: pose.lower.x * min(max(resting - max(pose.raise, 0), 0), 1), axis: [1, 0, 0])
            joints[fore.right].rotation *= simd_quatf(angle: pose.lower.y * min(resting, 1), axis: [1, 0, 0])
            let bend = Self.cheer.bend * pose.arms, reach = Self.cheer.reach * pose.arms
            joints[upper.left].rotation *= simd_quatf(angle: -0.6 * (pose.reach + reach), axis: [1, 0, 0])
            joints[fore.left].rotation *= simd_quatf(angle: -1.4 * (pose.bend + bend), axis: [0, 0, 1])
            joints[upper.right].rotation *= simd_quatf(angle: -0.6 * reach, axis: [1, 0, 0])
            joints[fore.right].rotation *= simd_quatf(angle: 1.4 * (bend + Self.scratch.rub * pose.rub), axis: [0, 0, 1])
            if pose.work > 0 {
                let down = Self.work.down + Self.work.nod * max(pose.headPitch, 0)
                joints[fore.right].rotation *= simd_quatf(angle: (down - Self.work.tap * pose.tap) * pose.work, axis: [1, 0, 0])
                joints[fore.left].rotation *= simd_quatf(angle: (down + Self.work.tap * pose.tap) * pose.work, axis: [1, 0, 0])
            }
        }
        // A spring that has played a smile leaves a sliver of it behind, which must not count as a smile and
        // keep the eyes open when the state shuts them.
        if pose.smile > 0.001 { smile(pose.smile, in: &joints) } else if pose.shut > 0.001 { smile(pose.shut, top: 0.2, in: &joints) }
    }

    /// The eyes going to the smile's arcs and back as a blink does: the pupils flatten to a line, are
    /// swapped for the arcs at that line, and the arcs curve up out of it.
    private func smile(_ amount: Float, top: Float = 1, in joints: inout [Transform]) {
        let thin = BearBlink.thin
        if amount < 0.5 {
            for joint in pupils where joint < joints.count { joints[joint].scale.y = 1 - (1 - thin) * BearIdle.ease(amount / 0.5) }
            return
        }
        for joint in pupils where joint < joints.count { joints[joint].translation.z -= Self.swap; joints[joint].scale.y = thin }
        for joint in arcs where joint < joints.count {
            joints[joint].translation.z += Self.swap
            joints[joint].scale.y = min(top, BearBlink.flat) + max(top - BearBlink.flat, 0) * BearIdle.ease((amount - 0.5) / 0.5)
        }
    }
}
