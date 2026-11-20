import XCTest
import RealityKit
import simd
@testable import Poki

/// The bear standing on its own: breathes organically, shifts weight, darts eyes, and never clips
/// its pupils outside its white sclera.
final class BearIdleTests: XCTestCase {
    private func headTurn(_ pose: BearIdle.Pose) -> Float { max(abs(pose.headYaw), abs(pose.headPitch), abs(pose.headRoll)) }

    /// Thirty seconds without a touch, at the rate it is drawn: it breathes all along, shifts weight,
    /// and looks somewhere more than once.
    func testTheBearMovesByItselfWhileItStands() {
        var idle = BearIdle(now: 0)
        var lifts: [Float] = [], shifts: [Float] = [], looks = 0, looking = false
        for frame in 0..<900 {
            let pose = idle.pose(at: Double(frame) / 30)
            lifts.append(pose.bodyLift)
            shifts.append(pose.bodyShiftX)
            let turned = headTurn(pose) > 0.1
            if turned, !looking { looks += 1 }
            looking = turned
        }
        XCTAssertGreaterThan(lifts.max()! - lifts.min()!, 0.010, "it breathes")
        XCTAssertGreaterThan(shifts.max()! - shifts.min()!, 0.010, "it shifts weight")
        XCTAssertGreaterThanOrEqual(looks, 2, "it looks about")
    }

    /// A tap while it looks away: the head comes back before the hi.
    func testAHiBringsTheHeadBackFirst() throws {
        var idle = BearIdle(now: 0)
        var t = 0.0
        while headTurn(idle.pose(at: t)) < 0.12 {
            t += 1.0 / 30
            try XCTSkipIf(t > 30, "no look in thirty seconds")
        }
        idle.attend(at: t)
        let back = idle.pose(at: t + 0.35)
        XCTAssertLessThan(headTurn(back), 0.06)
    }

    /// Small gestures take turns: each once in every four, in a new order, never the same twice in a row.
    func testTheSmallThingsTakeTurns() {
        var idle = BearIdle(now: 0)
        let done = (0..<40).map { _ in idle.nextGesture() }
        for (a, b) in zip(done, done.dropFirst()) { XCTAssertNotEqual(a, b) }
        for start in stride(from: 0, to: 40, by: 4) {
            XCTAssertEqual(Set(done[start..<start + 4]), Set(BearIdle.Gesture.allCases), "turn from \(start)")
        }
    }

    func testNeutralGazePreservesTheAuthoredPupils() {
        let eyes = BearEyeBounds.transforms(desiredGaze: .zero, headYaw: 0, headPitch: 0)
        let identity = simd_quatf(angle: 0, axis: [0, 1, 0])
        for eye in [eyes.right, eyes.left] {
            XCTAssertEqual(eye.translation, .zero)
            XCTAssertEqual(eye.rotation, identity)
        }
    }

    func testPupilsNeverLeaveWhiteScleraAcrossHeadAngles() throws {
        let rig = try XCTUnwrap(BearIdleJoints(names: ["Body", "Head", "Eye_R", "Eye_L"]))
        let fixtures = [EyeFixture.right, .left]
        let rest = [Transform(), Transform()] + fixtures.map { Transform(translation: $0.bone) }
        let gazes: [SIMD2<Float>] = [
            SIMD2(0.011, 0.012), SIMD2(-0.011, 0.012),
            SIMD2(0.06, 0.06), SIMD2(-0.06, 0.06), SIMD2(0.06, -0.06), SIMD2(-0.06, -0.06),
            SIMD2(0.03, 0), SIMD2(-0.03, 0), SIMD2(0, 0.04), SIMD2(0, -0.04),
            BearStance.pose(.thinking).gaze,
        ]
        let yaws: [Float] = [-0.35, -0.20, 0, 0.20, 0.35]
        let pitches: [Float] = [-0.20, 0, 0.20]
        for yaw in yaws {
            for pitch in pitches {
                for gaze in gazes {
                    var pose = BearIdle.Pose()
                    pose.gaze = gaze
                    pose.headYaw = yaw
                    pose.headPitch = pitch
                    var joints = rest
                    rig.apply(pose, to: &joints)
                    let context = "gaze=\(gaze) yaw=\(yaw) pitch=\(pitch)"
                    let movements = zip(fixtures, joints.dropFirst(2)).map { eye, joint in
                        let worst = eye.rim.map { point in
                            let projected = eye.project(point, through: joint)
                            return simd_length((projected - eye.pad) / eye.padRadii)
                        }.max() ?? .infinity
                        XCTAssertLessThan(worst, 1, "pupil clips the white pad at \(context)")
                        let normal = joint.rotation.act(simd_normalize(eye.bone - EyeFixture.head))
                        let outward = simd_normalize(joint.translation - EyeFixture.head)
                        XCTAssertLessThan(simd_length(normal - outward), 0.001, "pupil tilts off the face at \(context)")
                        let movement = eye.project(eye.pupil, through: joint) - eye.pupil
                        XCTAssertGreaterThan(simd_dot(movement, gaze), 0, "pupil does not follow the gaze at \(context)")
                        return movement
                    }
                    XCTAssertLessThan(simd_distance(movements[0], movements[1]), 0.005, "eyes diverge at \(context)")
                }
            }
        }
    }

    // Eye silhouettes and bone origins measured from the authored idle frame of PokiBear.usdz.
    private struct EyeFixture {
        static let head = SIMD3<Float>(-0.015, 0.895, 0.010)
        static let right = Self(pad: [-0.18083, 0.90705], padRadii: [0.13107, 0.14747],
                                pupil: [-0.13633, 0.91185], pupilRadii: [0.08486, 0.08862], bone: [-0.1833, 0.9107, 0.4224])
        static let left = Self(pad: [0.17619, 0.90072], padRadii: [0.13008, 0.14743],
                               pupil: [0.13239, 0.90876], pupilRadii: [0.08494, 0.08923], bone: [0.1787, 0.9054, 0.4075])

        let pad: SIMD2<Float>, padRadii: SIMD2<Float>
        let pupil: SIMD2<Float>, pupilRadii: SIMD2<Float>
        let bone: SIMD3<Float>

        var rim: [SIMD2<Float>] {
            (0..<72).map { sample in
                let angle = Float(sample) * .pi / 36
                return pupil + pupilRadii * SIMD2(cos(angle), sin(angle))
            }
        }

        func project(_ point: SIMD2<Float>, through joint: Transform) -> SIMD2<Float> {
            let radiusSquared = simd_length_squared(bone - Self.head)
            let xy = point - SIMD2(Self.head.x, Self.head.y)
            let z = Self.head.z + sqrt(radiusSquared - simd_length_squared(xy))
            let transformed = joint.translation + joint.rotation.act(SIMD3(point.x, point.y, z) - bone)
            return SIMD2(transformed.x, transformed.y)
        }
    }

    /// The pupils glide: standing at the home screen for ten minutes, neither pupil ever moves faster than
    /// 0.18 model units a second (the sclera's room is about 0.03), at the rate it is drawn when it
    /// moves (60 Hz) and when it is calm (30 Hz). Before, the eyes darted 0.03 across in 0.12 s and
    /// were cut off in a single frame when a look began: up to 0.45 a second, which is the twitch.
    func testThePupilsNeverTwitchWhileTheBearStands() {
        for rate in [60.0, 30.0] {
            var idle = BearIdle(now: 0)
            var filter = BearPoseFilter()
            var previous: (right: SIMD3<Float>, left: SIMD3<Float>)?
            var fastest: Float = 0
            for frame in 0..<Int(600 * rate) {
                let now = Double(frame) / rate
                let pose = filter.filter(idle.pose(at: now), at: now)
                let eyes = BearEyeBounds.transforms(desiredGaze: pose.gaze, headYaw: pose.headYaw, headPitch: pose.headPitch)
                if let before = previous {
                    let moved = max(simd_length(eyes.right.translation - before.right), simd_length(eyes.left.translation - before.left))
                    fastest = max(fastest, moved * Float(rate))
                }
                previous = (eyes.right.translation, eyes.left.translation)
            }
            XCTAssertLessThan(fastest, 0.18, "fastest pupil speed at \(rate) Hz, in model units a second")
        }
    }

    /// The eyes close for a state that shuts them (asleep, or its head down over its paws) even when
    /// the smile spring that played for a reaction has not settled at exactly zero: it leaves about a
    /// millionth, which used to count as a smile and kept the pupils open.
    func testTheEyesShutAfterASmileThatHasNotSettledToZero() throws {
        let joints = try XCTUnwrap(BearIdleJoints(names: ["Body", "Head", "Eye_R", "Eye_L", "SmileEye_R", "SmileEye_L"]))
        var transforms = Array(repeating: Transform(), count: 6)
        var pose = BearIdle.Pose()
        pose.shut = 1
        pose.smile = 1e-6
        joints.apply(pose, to: &transforms)
        XCTAssertEqual(transforms[joints.pupils[0]].scale.y, BearBlink.thin, accuracy: 1e-5, "the right pupil is flat")
        XCTAssertEqual(transforms[joints.pupils[1]].scale.y, BearBlink.thin, accuracy: 1e-5, "the left pupil is flat")
    }

    /// Second-order spring dynamics produce subtle anticipation and elastic overshoot on transitions
    /// without diverging or jumping across variable frame rates.
    func testSpringFilterProducesAnticipationAndOvershootWithoutJumping() {
        var spring = SecondOrderSpring(.arms, initial: 0)
        var minVal: Float = 0
        var maxVal: Float = 0
        let rampDuration = 0.24
        for step in 1...120 {
            let t = Double(step) / 60.0
            let target = BearIdle.ease(Float(t / rampDuration))
            let val = spring.step(dt: 1.0 / 60.0, target: target)
            minVal = min(minVal, val)
            maxVal = max(maxVal, val)
        }
        XCTAssertLessThan(minVal, -0.002, "expected subtle anticipation dip before rising")
        XCTAssertGreaterThan(maxVal, 1.04, "expected elastic overshoot past target")
        XCTAssertEqual(spring.value, 1.0, accuracy: 0.01, "expected spring to settle cleanly at target")
    }
}
